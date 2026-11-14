{
  Passing processor exceptions to the program.

  A program registers an exception dispatcher (CallSetExceptionDispatcher;
  the runtime's System unit does this at startup). When one of its threads
  raises a processor exception the kernel cannot resolve - an access
  violation, an integer division by zero, an invalid instruction, a
  floating point exception and so on - the kernel writes a
  TAbiExceptionRecord (what happened, and every register) onto the
  thread's stack below the red zone and lets the thread continue in the
  dispatcher, with RDI pointing at the record, as if the faulting
  instruction had called it. The runtime turns the record into a Pascal
  exception (EAccessViolation, EDivByZero, ...) that try/except can catch.

  The dispatcher reports with CallExceptionDispatched once it has the
  record. A thread raising another exception before that - the
  dispatcher itself failed - ends the process, as does an exception with
  no dispatcher registered, one that is never passed on (a machine check)
  or a record that does not fit on the stack (a stack overflow).
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

function PerformSetExceptionDispatcher(Address: QWord): Int64;
function PerformExceptionDispatched: Int64;

implementation

uses
  Runtime.Memory,
  Abi.SystemCalls,
  Memory.Layout,
  Kernel.Arch.Cpu,
  Memory.Arch.PageTables,
  Processes.Process,
  Processes.Thread,
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

  RedZoneSize = 128;
  { Flags the dispatcher must not start with: trap, direction, alignment
    check. Interrupts stay enabled. }
  RflagsTrap = QWord(1) shl 8;
  RflagsDirection = QWord(1) shl 10;
  RflagsAlignmentCheck = QWord(1) shl 18;
  RflagsInterruptEnable = QWord(1) shl 9;
  StackOverflowDistance = 64 * 1024;

{ The Abi code for an exception vector, 0 for one not passed on. }
function ExceptionCode(Vector: Byte): LongWord;
begin
  case Vector of
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

procedure CaptureContext(Frame: PTrapFrame; out Context: TAbiContext);
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

function AccessKindOf(ErrorCode: QWord): LongWord;
begin
  if (ErrorCode and PageFaultInstructionFetch) <> 0 then
    Result := AccessKindExecute
  else if (ErrorCode and PageFaultWrite) <> 0 then
    Result := AccessKindWrite
  else
    Result := AccessKindRead;
end;

function LooksLikeStackOverflow(Frame: PTrapFrame; FaultAddress: QWord): Boolean;
begin
  Result := (TrapFrameVector(Frame) = VectorPageFault) and (FaultAddress < Frame^.Rsp + PageSize) and
    (FaultAddress + StackOverflowDistance > Frame^.Rsp);
end;

function DispatchUserException(Frame: PTrapFrame; FaultAddress: QWord): Boolean;
var
  Process: PProcess;
  Thread: PThread;
  ExceptionRecord: TAbiExceptionRecord;
  RecordAddress: QWord;
  ReturnSlot: QWord;
  NoReturnAddress: QWord;
  Written: Boolean;
begin
  Result := False;
  Process := CurrentProcess;
  Thread := CurrentThreadObject;
  if (Process^.ExceptionDispatcher = 0) or Thread^.IsDispatchingException then
    Exit;
  ZeroMemory(@ExceptionRecord, SizeOf(ExceptionRecord));
  ExceptionRecord.Code := ExceptionCode(TrapFrameVector(Frame));
  if ExceptionRecord.Code = 0 then
    Exit;
  if TrapFrameVector(Frame) = VectorPageFault then
  begin
    ExceptionRecord.Access := AccessKindOf(Frame^.ErrorCode);
    ExceptionRecord.FaultAddress := FaultAddress;
  end;
  ExceptionRecord.Address := Frame^.Rip;
  CaptureContext(Frame, ExceptionRecord.Context);

  { Below the red zone, 16-byte aligned, with a null return address under
    it, so the dispatcher starts as if called. }
  RecordAddress := (Frame^.Rsp - RedZoneSize - SizeOf(ExceptionRecord)) and not QWord(15);
  ReturnSlot := RecordAddress - SizeOf(QWord);
  NoReturnAddress := 0;
  { Writing may fault (a stack page not yet touched), which needs
    interrupts. }
  EnableInterrupts;
  Written := (RecordAddress < Frame^.Rsp) and
    (CopyToUser(RecordAddress, @ExceptionRecord, SizeOf(ExceptionRecord)) = ErrorNone) and
    (CopyToUser(ReturnSlot, @NoReturnAddress, SizeOf(NoReturnAddress)) = ErrorNone);
  DisableInterrupts;
  if not Written then
    Exit;

  Frame^.Rsp := ReturnSlot;
  Frame^.Rip := Process^.ExceptionDispatcher;
  Frame^.Rdi := RecordAddress;
  Frame^.Rflags := (Frame^.Rflags and not (RflagsTrap or RflagsDirection or RflagsAlignmentCheck)) or
    RflagsInterruptEnable;
  Thread^.IsDispatchingException := True;
  Result := True;
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
