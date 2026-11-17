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
  Exceptions and interrupts on AArch64.

  The vector table (ExceptionVectors.s) calls ArchHandleException with
  the trap frame and the kind of exception:

  - An IRQ is acknowledged at the interrupt controller (the HAL's
    acknowledger turns the GIC's INTID into the kernel's vector) and
    dispatched like any interrupt (Kernel.Interrupts).
  - An SVC from user mode is a system call (Kernel.Arch.SystemCallEntry).
  - Any other synchronous exception is classified by its syndrome (ESR)
    into one of the kernel's processor exception vectors below and
    dispatched; page faults go to the page fault resolver first.
  - SError, FIQ and exceptions the kernel never expects are fatal.

  Page faults are described to the resolver with the kernel's fault code,
  whose bits are the x86-64 page fault error code's (present, write, user,
  instruction fetch): made here from the data or instruction abort's
  syndrome.
}
unit Kernel.Arch.Exceptions;

{$mode objfpc}

interface

uses
  Kernel.Arch.TrapFrame;

const
  { The kernel's processor exception vectors on AArch64. }
  VectorUndefinedInstruction = 1;
  VectorBreakpoint = 2;
  VectorPageFault = 3;
  VectorAlignmentFault = 4;
  VectorFloatingPoint = 5;
  VectorPrivilegedOperation = 6;
  VectorExternalAbort = 7;
  VectorOtherSynchronous = 8;

  { The fault code's bits (as on x86-64). }
  PageFaultPresent = 1;
  PageFaultWrite = 2;
  PageFaultUser = 4;
  PageFaultInstructionFetch = 16;

type
  { Returns True if it made the faulting access valid (for example by
    providing a page on demand), so the instruction can be retried. }
  TPageFaultResolver = function(FaultAddress: QWord; ErrorCode: QWord): Boolean;
  { Deals with an exception raised by user mode code: changes Frame so
    the thread continues in the program's exception dispatcher, or ends
    the process. FaultAddress is the address a page fault could not
    access (0 for other exceptions). Called with interrupts disabled;
    returns with them disabled. }
  TUserExceptionHandler = procedure(Frame: PTrapFrame; Description: PChar; FaultAddress: QWord);
  { Acknowledges the pending interrupt and returns its vector. }
  TInterruptAcknowledger = function: Byte;

procedure SetPageFaultResolver(Resolver: TPageFaultResolver);
procedure SetUserExceptionHandler(Handler: TUserExceptionHandler);
{ Installed by the HAL once the interrupt controller works. }
procedure SetInterruptAcknowledger(Acknowledger: TInterruptAcknowledger);

function IsProcessorException(Vector: Byte): Boolean;
procedure HandleProcessorException(Frame: PTrapFrame);
procedure WriteTrapFrame(Frame: PTrapFrame);

{ Called by ExceptionVectors.s. }
procedure ArchHandleException(Frame: PTrapFrame; Kind: QWord);

implementation

uses
  Hal.InterruptVectors,
  Kernel.Arch.Cpu,
  Kernel.Arch.UserMode,
  Kernel.Arch.UserCopy,
  Kernel.Arch.SystemCallEntry,
  Kernel.Interrupts,
  Kernel.Panic,
  Debug.Output;

const
  KindSynchronous = 0;
  KindInterrupt = 1;
  KindFastInterrupt = 2;
  KindSystemError = 3;

  { Exception classes (ESR_EL1 bits 31-26). }
  ClassUnknown = $00;
  ClassFloatingPointAccess = $07;
  ClassIllegalState = $0E;
  ClassSupervisorCall = $15;
  ClassSystemRegister = $18;
  ClassInstructionAbortLower = $20;
  ClassInstructionAbortSame = $21;
  ClassProgramCounterAlignment = $22;
  ClassDataAbortLower = $24;
  ClassDataAbortSame = $25;
  ClassStackAlignment = $26;
  ClassFloatingPointException = $2C;
  ClassBreakpointInstruction = $3C;

  { Data and instruction abort syndrome fields. }
  AbortStatusMask = $3F;
  AbortWriteNotRead = QWord(1) shl 6;
  AbortCacheMaintenance = QWord(1) shl 8;
  StatusTranslationFault = $04;   { $04-$07, by level }
  StatusAccessFlagFault = $08;    { $08-$0B }
  StatusPermissionFault = $0C;    { $0C-$0F }
  StatusAlignmentFault = $21;
  StatusSynchronousExternal = $10;

  InstructionLength = 4;

  ExceptionNames: array[0..8] of PChar = (
    'exception 0',
    'undefined instruction',
    'breakpoint',
    'page fault',
    'alignment fault',
    'floating point exception',
    'privileged operation',
    'external abort',
    'synchronous exception');

var
  PageFaultResolver: TPageFaultResolver = nil;
  UserExceptionHandler: TUserExceptionHandler = nil;
  InterruptAcknowledger: TInterruptAcknowledger = nil;

procedure SetPageFaultResolver(Resolver: TPageFaultResolver);
begin
  PageFaultResolver := Resolver;
end;

procedure SetUserExceptionHandler(Handler: TUserExceptionHandler);
begin
  UserExceptionHandler := Handler;
end;

procedure SetInterruptAcknowledger(Acknowledger: TInterruptAcknowledger);
begin
  InterruptAcknowledger := Acknowledger;
end;

function IsProcessorException(Vector: Byte): Boolean;
begin
  Result := Vector < ProcessorExceptionVectorCount;
end;

function ExceptionName(Vector: Byte): PChar;
begin
  if Vector <= High(ExceptionNames) then
    Result := ExceptionNames[Vector]
  else
    Result := 'exception';
end;

function ExceptionClass(Frame: PTrapFrame): QWord;
begin
  Result := (Frame^.Esr shr 26) and $3F;
end;

procedure WriteRegister(Name: PChar; Value: QWord);
begin
  DebugWrite(Name);
  DebugWrite('=');
  DebugWriteHex(Value, 16);
  DebugWrite('  ');
end;

procedure WriteTrapFrame(Frame: PTrapFrame);
const
  Names: array[0..30] of PChar = (
    ' X0', ' X1', ' X2', ' X3', ' X4', ' X5', ' X6', ' X7', ' X8', ' X9', 'X10',
    'X11', 'X12', 'X13', 'X14', 'X15', 'X16', 'X17', 'X18', 'X19', 'X20', 'X21',
    'X22', 'X23', 'X24', 'X25', 'X26', 'X27', 'X28', ' FP', ' LR');
var
  Index: Integer;
begin
  DebugBeginMessage;
  for Index := 0 to 30 do
  begin
    WriteRegister(Names[Index], Frame^.X[Index]);
    if (Index mod 3) = 2 then
      DebugWriteLine('');
  end;
  WriteRegister(' SP', Frame^.Sp);
  DebugWriteLine('');
  WriteRegister(' PC', Frame^.Elr);
  WriteRegister('PSR', Frame^.Spsr);
  WriteRegister('ESR', Frame^.Esr);
  DebugWriteLine('');
  WriteRegister('FAR', Frame^.Far);
  WriteRegister('EL ', ReadCurrentExceptionLevel);
  DebugWriteLine('');
  DebugEndMessage;
end;

{ The kernel's fault code for a data or instruction abort. }
function PageFaultCode(Frame: PTrapFrame): QWord;
var
  ClassOfException: QWord;
  Status: QWord;
begin
  Result := 0;
  ClassOfException := ExceptionClass(Frame);
  Status := Frame^.Esr and AbortStatusMask;
  if (Status and $3C) <> StatusTranslationFault then
    Result := Result or PageFaultPresent;
  if (ClassOfException = ClassInstructionAbortLower) or (ClassOfException = ClassInstructionAbortSame) then
    Result := Result or PageFaultInstructionFetch
  else if ((Frame^.Esr and AbortWriteNotRead) <> 0) and ((Frame^.Esr and AbortCacheMaintenance) = 0) then
    Result := Result or PageFaultWrite;
  if ArchFrameIsFromUserMode(Frame) then
    Result := Result or PageFaultUser;
end;

function IsTranslationRelatedFault(Status: QWord): Boolean;
begin
  Result := ((Status and $3C) = StatusTranslationFault) or ((Status and $3C) = StatusAccessFlagFault) or
    ((Status and $3C) = StatusPermissionFault);
end;

{ The kernel's vector for a synchronous exception other than SVC. }
function ClassifySynchronousException(Frame: PTrapFrame): Byte;
var
  Status: QWord;
begin
  case ExceptionClass(Frame) of
    ClassUnknown, ClassIllegalState:
      Result := VectorUndefinedInstruction;
    ClassBreakpointInstruction:
      Result := VectorBreakpoint;
    ClassInstructionAbortLower, ClassInstructionAbortSame, ClassDataAbortLower, ClassDataAbortSame:
      begin
        Status := Frame^.Esr and AbortStatusMask;
        if IsTranslationRelatedFault(Status) then
          Result := VectorPageFault
        else if Status = StatusAlignmentFault then
          Result := VectorAlignmentFault
        else if Status = StatusSynchronousExternal then
          Result := VectorExternalAbort
        else
          Result := VectorOtherSynchronous;
      end;
    ClassProgramCounterAlignment, ClassStackAlignment:
      Result := VectorAlignmentFault;
    ClassFloatingPointException:
      Result := VectorFloatingPoint;
    ClassSystemRegister, ClassFloatingPointAccess, ClassSupervisorCall:
      Result := VectorPrivilegedOperation;
  else
    Result := VectorOtherSynchronous;
  end;
end;

procedure DescribePageFault(Frame: PTrapFrame);
var
  Code: QWord;
begin
  Code := Frame^.ErrorCode;
  DebugWrite('  ');
  if (Code and PageFaultInstructionFetch) <> 0 then
    DebugWrite('Instruction fetch from ')
  else if (Code and PageFaultWrite) <> 0 then
    DebugWrite('Write to ')
  else
    DebugWrite('Read from ');
  DebugWriteAddress(Frame^.Far);
  if (Code and PageFaultPresent) <> 0 then
    DebugWrite(' (protection violation')
  else
    DebugWrite(' (page not present');
  if (Code and PageFaultUser) <> 0 then
    DebugWrite(', user mode');
  DebugWriteLine(')');
end;

procedure ReportBreakpoint(Frame: PTrapFrame);
begin
  DebugBeginMessage;
  DebugWriteTag('exception');
  DebugWrite('Breakpoint at ');
  DebugWriteAddress(Frame^.Elr);
  DebugWriteLine(', continuing');
  DebugEndMessage;
end;

procedure HandleProcessorException(Frame: PTrapFrame);
var
  Vector: Byte;
  FaultAddress: QWord;
  Resolved: Boolean;
begin
  FaultAddress := 0;
  Vector := TrapFrameVector(Frame);

  if (Vector = VectorBreakpoint) and not ArchFrameIsFromUserMode(Frame) then
  begin
    ReportBreakpoint(Frame);
    Frame^.Elr := Frame^.Elr + InstructionLength;
    Exit;
  end;

  if Vector = VectorPageFault then
  begin
    FaultAddress := Frame^.Far;
    Frame^.ErrorCode := PageFaultCode(Frame);
    { Resolving may take spin locks whose holder waits for this
      processor to answer a TLB shootdown, which needs interrupts. }
    if (Frame^.Spsr and InterruptMaskBit) = 0 then
      EnableInterrupts;
    Resolved := Assigned(PageFaultResolver) and PageFaultResolver(FaultAddress, Frame^.ErrorCode);
    DisableInterrupts;
    if Resolved then
      Exit;
  end;

  { A system call copying from or to memory another thread just freed. }
  if (Vector = VectorPageFault) and not ArchFrameIsFromUserMode(Frame) and
     RecoverFromUserCopyFault(Frame, FaultAddress) then
    Exit;

  if ArchFrameIsFromUserMode(Frame) and Assigned(UserExceptionHandler) then
  begin
    if Vector <> VectorPageFault then
      FaultAddress := 0;
    { The program sees a breakpoint as it does on x86-64: at the
      instruction after it, so continuing there goes on. }
    if Vector = VectorBreakpoint then
      Frame^.Elr := Frame^.Elr + InstructionLength;
    UserExceptionHandler(Frame, ExceptionName(Vector), FaultAddress);
    Exit;
  end;

  BeginKernelPanic(PanicUnhandledProcessorException, 'unhandled processor exception');
  DebugWrite('  ');
  DebugWrite(ExceptionName(Vector));
  DebugWrite(' (vector ');
  DebugWriteDecimal(Vector);
  DebugWrite(', exception class 0x');
  DebugWriteHex(ExceptionClass(Frame), 2);
  DebugWriteLine(')');
  if Vector = VectorPageFault then
    DescribePageFault(Frame);
  DebugWriteLine('');
  WriteTrapFrame(Frame);
  FinishKernelPanic;
end;

procedure HandleFatalException(Frame: PTrapFrame; Kind: QWord);
begin
  { Another processor panicked and stops this one (Kernel.Panic sends
    the stop as an interrupt; see Hal.Platform). }
  BeginKernelPanic(PanicUnhandledProcessorException, 'unexpected exception');
  DebugWrite('  ');
  case Kind of
    KindFastInterrupt: DebugWriteLine('FIQ');
    KindSystemError: DebugWriteLine('SError (asynchronous abort)');
  else
    DebugWriteLine('exception from an unexpected state (EL1 with SP_EL0, or AArch32)');
  end;
  WriteTrapFrame(Frame);
  FinishKernelPanic;
end;

procedure HandleInterrupt(Frame: PTrapFrame);
begin
  if not Assigned(InterruptAcknowledger) then
    Exit;
  Frame^.Vector := InterruptAcknowledger();
  if IsSpuriousInterruptVector(Byte(Frame^.Vector)) then
    Exit;
  DispatchInterrupt(Frame);
end;

procedure ArchHandleException(Frame: PTrapFrame; Kind: QWord); [public, alias: 'ArchHandleException'];
begin
  case Kind of
    KindInterrupt:
      HandleInterrupt(Frame);
    KindSynchronous:
      if (ExceptionClass(Frame) = ClassSupervisorCall) and ArchFrameIsFromUserMode(Frame) then
        DispatchSystemCall(Frame)
      else
      begin
        Frame^.Vector := ClassifySynchronousException(Frame);
        DispatchInterrupt(Frame);
      end;
  else
    HandleFatalException(Frame, Kind);
  end;
end;

end.
