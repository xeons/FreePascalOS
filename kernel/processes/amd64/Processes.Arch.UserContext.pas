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
  A program's register context on x86-64, for passing processor
  exceptions to it (Processes.UserExceptions): which exceptions are
  passed on and as what, the context in the exception record, starting
  the program's dispatcher, and continuing at a context (CallContinue).
}
unit Processes.Arch.UserContext;

{$mode objfpc}

interface

uses
  Abi.SystemCalls,
  Kernel.Arch.TrapFrame;

const
  { Below the stack pointer, the System V red zone is the program's. }
  UserStackRedZoneSize = 128;

{ The Abi code for a frame's exception vector, 0 for one not passed on. }
function ExceptionCodeOfFrame(Frame: PTrapFrame): LongWord;
{ The final code, once interrupts are enabled: a general protection fault
  is a privileged instruction only if the instruction is one, else an
  access violation (reading the instruction may fault its page in). }
function RefineExceptionCode(Frame: PTrapFrame; Code: LongWord): LongWord;

function FrameIsPageFault(Frame: PTrapFrame): Boolean;
{ AccessKind* of a page fault. }
function PageFaultAccessKind(Frame: PTrapFrame): LongWord;

procedure CaptureUserContext(Frame: PTrapFrame; out Context: TAbiContext);
{ Replaces Frame's registers with Context; ErrorInvalidArgument (Frame
  unchanged) if it does not lead back into user memory. }
function RestoreUserContext(Frame: PTrapFrame; const Context: TAbiContext): LongInt;

{ Makes the thread continue in Dispatcher with the record's address as
  its argument and the stack pointer at ReturnSlot (holding a null
  return address), as if called. }
procedure EnterExceptionDispatcher(Frame: PTrapFrame; Dispatcher, RecordAddress, ReturnSlot: QWord);

implementation

uses
  Memory.Arch.PageTables,
  Kernel.Arch.PrivilegedInstructions,
  Processes.UserAccess;

const
  VectorDivideError = 0;
  VectorBreakpoint = 3;
  VectorOverflow = 4;
  VectorBoundRange = 5;
  VectorInvalidOpcode = 6;
  VectorSegmentNotPresent = 11;
  VectorStackSegmentFault = 12;
  VectorGeneralProtection = 13;
  VectorPageFault = 14;
  VectorFloatingPoint = 16;
  VectorAlignmentCheck = 17;
  VectorSimdFloatingPoint = 19;

  PageFaultWrite = 2;
  PageFaultInstructionFetch = 16;

  { Flags the dispatcher must not start with: trap, direction, alignment
    check. Interrupts stay enabled. }
  RflagsTrap = QWord(1) shl 8;
  RflagsDirection = QWord(1) shl 10;
  RflagsAlignmentCheck = QWord(1) shl 18;
  RflagsInterruptEnable = QWord(1) shl 9;
  { The flags a context may set: carry, parity, adjust, zero, sign,
    direction, overflow. Bit 1 is always set. }
  RflagsUserSettable = $0CD5;
  RflagsAlwaysOne = $0002;

function ExceptionCodeOfFrame(Frame: PTrapFrame): LongWord;
begin
  case TrapFrameVector(Frame) of
    VectorDivideError: Result := ExceptionIntegerDivide;
    VectorBreakpoint: Result := ExceptionBreakpoint;
    VectorOverflow: Result := ExceptionIntegerOverflow;
    VectorBoundRange: Result := ExceptionBoundRange;
    VectorInvalidOpcode: Result := ExceptionIllegalInstruction;
    VectorSegmentNotPresent, VectorStackSegmentFault, VectorPageFault: Result := ExceptionAccessViolation;
    VectorGeneralProtection: Result := ExceptionPrivilegedOperation;
    VectorFloatingPoint: Result := ExceptionFloatingPoint;
    VectorAlignmentCheck: Result := ExceptionAlignment;
    VectorSimdFloatingPoint: Result := ExceptionSimdFloatingPoint;
  else
    Result := 0;
  end;
end;

function GeneralProtectionCode(Frame: PTrapFrame): LongWord;
var
  Instruction: array[0..LongestInstruction - 1] of Byte;
  Count: Integer;
begin
  { The instruction may end before the end of its page; read less until
    the read works. }
  Count := LongestInstruction;
  while (Count > 0) and (CopyFromUser(@Instruction[0], Frame^.Rip, QWord(Count)) <> ErrorNone) do
    Dec(Count);
  if IsPrivilegedInstruction(@Instruction[0], Count) then
    Result := ExceptionPrivilegedOperation
  else
    Result := ExceptionAccessViolation;
end;

function RefineExceptionCode(Frame: PTrapFrame; Code: LongWord): LongWord;
begin
  if TrapFrameVector(Frame) = VectorGeneralProtection then
    Result := GeneralProtectionCode(Frame)
  else
    Result := Code;
end;

function FrameIsPageFault(Frame: PTrapFrame): Boolean;
begin
  Result := TrapFrameVector(Frame) = VectorPageFault;
end;

function PageFaultAccessKind(Frame: PTrapFrame): LongWord;
begin
  if (Frame^.ErrorCode and PageFaultInstructionFetch) <> 0 then
    Result := AccessKindExecute
  else if (Frame^.ErrorCode and PageFaultWrite) <> 0 then
    Result := AccessKindWrite
  else
    Result := AccessKindRead;
end;

procedure CaptureUserContext(Frame: PTrapFrame; out Context: TAbiContext);
begin
  Context.Rax := Frame^.Rax;
  Context.Rbx := Frame^.Rbx;
  Context.Rcx := Frame^.Rcx;
  Context.Rdx := Frame^.Rdx;
  Context.Rsi := Frame^.Rsi;
  Context.Rdi := Frame^.Rdi;
  Context.Rbp := Frame^.Rbp;
  Context.Rsp := Frame^.Rsp;
  Context.R8 := Frame^.R8;
  Context.R9 := Frame^.R9;
  Context.R10 := Frame^.R10;
  Context.R11 := Frame^.R11;
  Context.R12 := Frame^.R12;
  Context.R13 := Frame^.R13;
  Context.R14 := Frame^.R14;
  Context.R15 := Frame^.R15;
  Context.Rip := Frame^.Rip;
  Context.Rflags := Frame^.Rflags;
end;

function RestoreUserContext(Frame: PTrapFrame; const Context: TAbiContext): LongInt;
begin
  if (Context.Rip >= UserSpaceLimit) or (Context.Rsp >= UserSpaceLimit) or (Context.Rsp = 0) then
    Exit(ErrorInvalidArgument);
  Frame^.Rax := Context.Rax;
  Frame^.Rbx := Context.Rbx;
  Frame^.Rcx := Context.Rcx;
  Frame^.Rdx := Context.Rdx;
  Frame^.Rsi := Context.Rsi;
  Frame^.Rdi := Context.Rdi;
  Frame^.Rbp := Context.Rbp;
  Frame^.Rsp := Context.Rsp;
  Frame^.R8 := Context.R8;
  Frame^.R9 := Context.R9;
  Frame^.R10 := Context.R10;
  Frame^.R11 := Context.R11;
  Frame^.R12 := Context.R12;
  Frame^.R13 := Context.R13;
  Frame^.R14 := Context.R14;
  Frame^.R15 := Context.R15;
  Frame^.Rip := Context.Rip;
  Frame^.Rflags := (Context.Rflags and RflagsUserSettable) or RflagsAlwaysOne or RflagsInterruptEnable;
  { The selectors stay the user ones the system call frame holds. }
  Result := ErrorNone;
end;

procedure EnterExceptionDispatcher(Frame: PTrapFrame; Dispatcher, RecordAddress, ReturnSlot: QWord);
begin
  Frame^.Rsp := ReturnSlot;
  Frame^.Rip := Dispatcher;
  Frame^.Rdi := RecordAddress;
  Frame^.Rflags := (Frame^.Rflags and not (RflagsTrap or RflagsDirection or RflagsAlignmentCheck)) or
    RflagsInterruptEnable;
end;

end.
