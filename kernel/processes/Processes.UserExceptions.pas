{
  FreePascalOS
  Copyright (C) 2026 Brandon Scott

  This program is free software: you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation, either version 3 of the License, or
  (at your option) any later version.

  This program is distributed in the hope that it will be useful,
  but WITHOUT ANY WARRANTY; without even the implied warranty of
  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
  GNU General Public License for more details.

  You should have received a copy of the GNU General Public License
  along with this program.  If not, see <https://www.gnu.org/licenses/>.
}

{
  Passing processor exceptions to the program.

  A program registers an exception dispatcher (CallSetExceptionDispatcher;
  the runtime's System unit does this at startup). When one of its threads
  raises a processor exception the kernel cannot resolve - an access
  violation, an integer division by zero, an invalid instruction, a
  floating point exception and so on - the kernel writes a
  TAbiExceptionRecord (what happened, and every register) onto the
  thread's stack below the red zone and lets the thread continue in the
  dispatcher, with the record's address as its argument (RDI; X0), as if
  the faulting instruction had called it (the register context and how
  the dispatcher starts are the architecture's: Processes.Arch.UserContext). The runtime turns the record into a Pascal
  exception (EAccessViolation, EDivByZero, ...) that try/except can catch.

  The dispatcher reports with CallExceptionDispatched once it has the
  record. A thread raising another exception before that - the
  dispatcher itself failed - ends the process, as does an exception with
  no dispatcher registered, one that is never passed on (a machine check)
  or a record that does not fit on the stack.

  A stack overflow - a touch of the reserve at the bottom of the thread's
  stack (Processes.AddressSpace) - is passed on as ExceptionStackOverflow
  (when the kernel touches it, copying a system call's data, the call
  completes and the overflow is raised as it returns). A frame larger
  than the reserve can jump past it; its first touch then lands below the
  stack region. Such a fault - in no region, at or above the stack
  pointer, not far below the stack - is a stack overflow too: the reserve
  is opened and the record goes at its top, since the stack pointer is
  outside the stack. The
  reserve is opened, so the record and the handling fit. It is armed
  again once the thread's stack pointer is well above it, which is
  checked at every system call, interrupt return and exception
  (RearmStackReserveIfClear). An overflow while the reserve is still
  open runs past it and ends the process.

  CallContinue (PerformContinue) lets a thread go on with a context of its
  choosing - typically an exception's, changed by a filter that dealt with
  the exception (skipped the instruction, fixed a register).
}
unit Processes.UserExceptions;

{$mode objfpc}

interface

uses
  Kernel.Arch.TrapFrame;

{ Changes Frame so the current thread continues in its process's
  exception dispatcher. Returns False if the exception cannot be passed
  on; the caller then ends the process. Called with interrupts disabled;
  returns with them disabled. }
function DispatchUserException(Frame: PTrapFrame; FaultAddress: QWord): Boolean;

{ True if a page fault at FaultAddress is most likely a stack overflow. }
function LooksLikeStackOverflow(Frame: PTrapFrame; FaultAddress: QWord): Boolean;

{ Arms the current thread's opened stack reserve again if its user stack
  pointer is far enough above it. Needs interrupts enabled. }
procedure RearmStackReserveIfClear(UserStackPointer: QWord);
{ True if the current thread has an opened stack reserve (a cheap test). }
function StackReserveIsOpen: Boolean;

{ For the page fault resolver: a fault of the kernel itself (copying a
  system call's data) at FaultAddress. If it lies in the armed reserve of
  the current thread's stack, opens the reserve - the call goes on - and
  notes a stack overflow, which is raised when the call returns; returns
  True. A buffer below the stack, in a frame that jumped past the
  reserve, also gets the overflow noted, but the copy fails (False). }
function NoteKernelAccessToStack(FaultAddress: QWord): Boolean;
{ At the end of a system call: raises a stack overflow noted during it,
  with the call's result in the context. }
procedure DeliverPendingStackOverflow(Frame: PTrapFrame);

{ CallContinue: replaces Frame (the system call's) with the context at
  ContextAddress. Returns ErrorNone, or an Abi error with Frame
  unchanged. }
function PerformContinue(Frame: PTrapFrame; ContextAddress: QWord): LongInt;

function PerformSetExceptionDispatcher(Address: QWord): Int64;
function PerformExceptionDispatched: Int64;

implementation

uses
  Runtime.Memory,
  Abi.SystemCalls,
  Memory.Layout,
  Kernel.Arch.Cpu,
  Memory.Arch.PageTables,
  Processes.Arch.UserContext,
  Processes.Process,
  Processes.Thread,
  Processes.AddressSpace,
  Processes.UserAccess,
  Processes.UserProcess,
  Debug.Output;

const
  { A stack access below the stack (a huge frame) is taken for one if it
    lands in the stack's guard. }
  LargeFrameReach = StackGuardSize;
  StackOverflowDistance = 64 * 1024;

function LooksLikeStackOverflow(Frame: PTrapFrame; FaultAddress: QWord): Boolean;
var
  StackPointer: QWord;
begin
  StackPointer := TrapFrameStackPointer(Frame);
  Result := FrameIsPageFault(Frame) and (FaultAddress < StackPointer + PageSize) and
    (FaultAddress + StackOverflowDistance > StackPointer);
end;

{ Writes the exception record for Frame onto the user stack and changes
  Frame so the thread continues in the dispatcher. Returns False if there
  is no dispatcher, the dispatcher failed or the record does not fit.
  Works with interrupts on or off and leaves them as they were. }
function DeliverException(Frame: PTrapFrame; Code, Access: LongWord; FaultAddress: QWord): Boolean;
var
  Process: PProcess;
  Thread: PThread;
  ExceptionRecord: TAbiExceptionRecord;
  RecordAddress: QWord;
  ReturnSlot: QWord;
  NoReturnAddress: QWord;
  Written: Boolean;
  WereEnabled: Boolean;
  RecordTop: QWord;
  ReserveTop: QWord;
  StackPointer: QWord;
begin
  Result := False;
  Process := CurrentProcess;
  Thread := CurrentThreadObject;
  if (Process^.ExceptionDispatcher = 0) or Thread^.IsDispatchingException then
    Exit;
  ZeroMemory(@ExceptionRecord, SizeOf(ExceptionRecord));
  ExceptionRecord.Code := Code;
  ExceptionRecord.Access := Access;
  ExceptionRecord.FaultAddress := FaultAddress;
  ExceptionRecord.Address := TrapFrameInstructionPointer(Frame);
  CaptureUserContext(Frame, ExceptionRecord.Context);

  { Below the red zone, 16-byte aligned, with a null return address under
    it, so the dispatcher starts as if called. A stack overflow's record
    goes no lower than the top of the opened reserve: a frame that jumped
    past the reserve leaves the stack pointer outside the stack. }
  StackPointer := TrapFrameStackPointer(Frame);
  RecordTop := StackPointer - UserStackRedZoneSize;
  if (Code = ExceptionStackOverflow) and (Thread^.OpenedStackReserve <> 0) then
  begin
    ReserveTop := StackReserveTop(Process^.AddressSpace, Thread^.OpenedStackReserve);
    if (ReserveTop <> 0) and
       (StackPointer < Thread^.OpenedStackReserve + UserStackRedZoneSize + 2 * SizeOf(ExceptionRecord)) then
      RecordTop := ReserveTop;
  end;
  RecordAddress := (RecordTop - SizeOf(ExceptionRecord)) and not QWord(15);
  ReturnSlot := RecordAddress - SizeOf(QWord);
  NoReturnAddress := 0;
  { Writing may fault (a stack page not yet touched), which needs
    interrupts. }
  WereEnabled := SaveAndDisableInterrupts;
  EnableInterrupts;
  Written := ((RecordAddress < StackPointer) or (Code = ExceptionStackOverflow)) and
    (CopyToUser(RecordAddress, @ExceptionRecord, SizeOf(ExceptionRecord)) = ErrorNone) and
    (CopyToUser(ReturnSlot, @NoReturnAddress, SizeOf(NoReturnAddress)) = ErrorNone);
  DisableInterrupts;
  RestoreInterrupts(WereEnabled);
  if not Written then
    Exit;

  EnterExceptionDispatcher(Frame, Process^.ExceptionDispatcher, RecordAddress, ReturnSlot);
  Thread^.IsDispatchingException := True;
  Result := True;
end;

{ Opens the armed reserve of the current thread's own stack if Address
  lies in it; True if it did. }
function OpenOwnStackReserve(Address: QWord): Boolean;
var
  Thread: PThread;
begin
  Thread := CurrentThreadObject;
  Result := Thread^.IsUserThread and (Thread^.OpenedStackReserve = 0) and
    OpenStackReserve(CurrentProcess^.AddressSpace, Address, Thread^.UserStackStart,
      Thread^.OpenedStackReserve);
end;

{ True if a fault at FaultAddress, with the stack pointer at
  StackPointer, is an access to a frame that jumped past the armed
  reserve of the current thread's stack: below the stack region, in no
  other region, and at or above the stack pointer (less the red zone), so
  not a stray pointer. Opens the reserve if so. }
function OpenReserveForLargeFrame(FaultAddress, StackPointer: QWord): Boolean;
var
  Thread: PThread;
  Space: PAddressSpace;
begin
  Result := False;
  Thread := CurrentThreadObject;
  if not Thread^.IsUserThread or (Thread^.OpenedStackReserve <> 0) or (Thread^.UserStackStart = 0) then
    Exit;
  Space := CurrentProcess^.AddressSpace;
  if (FaultAddress >= Thread^.UserStackStart) or
     (FaultAddress + LargeFrameReach < Thread^.UserStackStart) or
     (FaultAddress + UserStackRedZoneSize < StackPointer) or AddressIsInUsableRegion(Space, FaultAddress) then
    Exit;
  Result := OpenStackReserveOfRegion(Space, Thread^.UserStackStart);
  if Result then
    Thread^.OpenedStackReserve := Thread^.UserStackStart;
end;

function DispatchUserException(Frame: PTrapFrame; FaultAddress: QWord): Boolean;
var
  Code: LongWord;
  Access: LongWord;
begin
  Result := False;
  Code := ExceptionCodeOfFrame(Frame);
  if Code = 0 then
    Exit;
  Access := 0;
  EnableInterrupts;
  RearmStackReserveIfClear(TrapFrameStackPointer(Frame));
  if FrameIsPageFault(Frame) then
  begin
    Access := PageFaultAccessKind(Frame);
    if CurrentThreadObject^.GuardPageHit then
      Code := ExceptionGuardPage
    else if OpenOwnStackReserve(FaultAddress) or
       OpenReserveForLargeFrame(FaultAddress, TrapFrameStackPointer(Frame)) then
      Code := ExceptionStackOverflow;
    CurrentThreadObject^.GuardPageHit := False;
  end
  else
  begin
    Code := RefineExceptionCode(Frame, Code);
    FaultAddress := 0;
  end;
  DisableInterrupts;
  Result := DeliverException(Frame, Code, Access, FaultAddress);
end;

function NoteKernelAccessToStack(FaultAddress: QWord): Boolean;
var
  Thread: PThread;
  CallFrame: PTrapFrame;
begin
  Thread := CurrentThreadObject;
  Result := OpenOwnStackReserve(FaultAddress);
  { A buffer in a frame that jumped past the reserve: there is no memory
    there, so the copy fails, but the program learns why. }
  CallFrame := PTrapFrame(Thread^.SystemCallFrame);
  if not Result and (CallFrame <> nil) and
     OpenReserveForLargeFrame(FaultAddress, TrapFrameStackPointer(CallFrame)) then
  begin
    Thread^.StackOverflowPending := True;
    Thread^.PendingOverflowAddress := FaultAddress;
    Exit(False);
  end;
  if not Result then
    Exit;
  Thread^.StackOverflowPending := True;
  Thread^.PendingOverflowAddress := FaultAddress;
end;

procedure DeliverPendingStackOverflow(Frame: PTrapFrame);
var
  Thread: PThread;
begin
  Thread := CurrentThreadObject;
  if (Thread = nil) or not Thread^.StackOverflowPending then
    Exit;
  Thread^.StackOverflowPending := False;
  if DeliverException(Frame, ExceptionStackOverflow, AccessKindWrite, Thread^.PendingOverflowAddress) then
    Exit;
  { Nobody to pass it to, as for an overflow the program made itself. }
  DebugBeginMessage;
  DebugWriteTag('process');
  DebugWrite(@CurrentProcess^.Name[0]);
  DebugWriteLine(': stack overflow in a system call, terminated');
  DebugEndMessage;
  ExitCurrentProcess(ExitStatusException);
end;

function StackReserveIsOpen: Boolean;
var
  Thread: PThread;
begin
  Thread := CurrentThreadObject;
  Result := (Thread <> nil) and (Thread^.OpenedStackReserve <> 0);
end;

procedure RearmStackReserveIfClear(UserStackPointer: QWord);
var
  Thread: PThread;
begin
  Thread := CurrentThreadObject;
  if (Thread = nil) or (Thread^.OpenedStackReserve = 0) then
    Exit;
  if RearmStackReserve(CurrentProcess^.AddressSpace, Thread^.OpenedStackReserve, UserStackPointer) then
    Thread^.OpenedStackReserve := 0;
end;

function PerformContinue(Frame: PTrapFrame; ContextAddress: QWord): LongInt;
var
  Context: TAbiContext;
begin
  Result := CopyFromUser(@Context, ContextAddress, SizeOf(Context));
  if Result <> ErrorNone then
    Exit;
  Result := RestoreUserContext(Frame, Context);
end;

function PerformSetExceptionDispatcher(Address: QWord): Int64;
begin
  if Address >= UserSpaceLimit then
    Exit(-Int64(ErrorInvalidArgument));
  CurrentProcess^.ExceptionDispatcher := Address;
  Result := 0;
end;

function PerformExceptionDispatched: Int64;
begin
  CurrentThreadObject^.IsDispatchingException := False;
  Result := 0;
end;

end.
