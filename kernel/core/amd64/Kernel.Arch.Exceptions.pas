{
  Handling of x86-64 processor exceptions.

  There is no user mode yet, so any exception other than a breakpoint is a
  kernel bug: the handler prints a description and a register dump, then
  stops the system. Breakpoints are reported and execution continues,
  which makes "int 3" a handy way to check that interrupts work.
}
unit Kernel.Arch.Exceptions;

{$mode objfpc}

interface

uses
  Kernel.Arch.TrapFrame;

type
  { Returns True if it made the faulting access valid (for example by
    providing a page on demand), so the instruction can be retried. }
  TPageFaultResolver = function(FaultAddress: QWord; ErrorCode: QWord): Boolean;

  { Deals with an exception raised by user mode code; normally ends the
    process. Must not return. }
  TUserExceptionHandler = procedure(Frame: PTrapFrame; Description: PChar);

procedure SetPageFaultResolver(Resolver: TPageFaultResolver);
procedure SetUserExceptionHandler(Handler: TUserExceptionHandler);

function IsProcessorException(Vector: Byte): Boolean;
procedure HandleProcessorException(Frame: PTrapFrame);

procedure WriteTrapFrame(Frame: PTrapFrame);

implementation

uses
  Hal.InterruptVectors,
  Kernel.Arch.Cpu,
  Kernel.Arch.UserMode,
  Kernel.Panic,
  Debug.Output;

const
  VectorBreakpoint = 3;
  VectorPageFault = 14;

  PageFaultPresent = 1;
  PageFaultWrite = 2;
  PageFaultUser = 4;
  PageFaultReservedBit = 8;
  PageFaultInstructionFetch = 16;

  ExceptionNames: array[0..31] of PChar = (
    'divide error',
    'debug',
    'non-maskable interrupt',
    'breakpoint',
    'overflow',
    'bound range exceeded',
    'invalid opcode',
    'device not available',
    'double fault',
    'coprocessor segment overrun',
    'invalid task state segment',
    'segment not present',
    'stack segment fault',
    'general protection fault',
    'page fault',
    'reserved (15)',
    'x87 floating point error',
    'alignment check',
    'machine check',
    'SIMD floating point error',
    'virtualization exception',
    'control protection exception',
    'reserved (22)',
    'reserved (23)',
    'reserved (24)',
    'reserved (25)',
    'reserved (26)',
    'reserved (27)',
    'hypervisor injection',
    'VMM communication',
    'security exception',
    'reserved (31)');

var
  PageFaultResolver: TPageFaultResolver = nil;
  UserExceptionHandler: TUserExceptionHandler = nil;

procedure SetPageFaultResolver(Resolver: TPageFaultResolver);
begin
  PageFaultResolver := Resolver;
end;

procedure SetUserExceptionHandler(Handler: TUserExceptionHandler);
begin
  UserExceptionHandler := Handler;
end;

function IsProcessorException(Vector: Byte): Boolean;
begin
  Result := Vector < ProcessorExceptionVectorCount;
end;

procedure WriteRegister(Name: PChar; Value: QWord);
begin
  DebugWrite(Name);
  DebugWrite('=');
  DebugWriteHex(Value, 16);
  DebugWrite('  ');
end;

procedure WriteTrapFrame(Frame: PTrapFrame);
begin
  DebugBeginMessage;
  WriteRegister('RAX', Frame^.Rax);
  WriteRegister('RBX', Frame^.Rbx);
  WriteRegister('RCX', Frame^.Rcx);
  DebugWriteLine('');
  WriteRegister('RDX', Frame^.Rdx);
  WriteRegister('RSI', Frame^.Rsi);
  WriteRegister('RDI', Frame^.Rdi);
  DebugWriteLine('');
  WriteRegister('RBP', Frame^.Rbp);
  WriteRegister('RSP', Frame^.Rsp);
  WriteRegister(' R8', Frame^.R8);
  DebugWriteLine('');
  WriteRegister(' R9', Frame^.R9);
  WriteRegister('R10', Frame^.R10);
  WriteRegister('R11', Frame^.R11);
  DebugWriteLine('');
  WriteRegister('R12', Frame^.R12);
  WriteRegister('R13', Frame^.R13);
  WriteRegister('R14', Frame^.R14);
  DebugWriteLine('');
  WriteRegister('R15', Frame^.R15);
  WriteRegister('RIP', Frame^.Rip);
  WriteRegister('RFL', Frame^.Rflags);
  DebugWriteLine('');
  WriteRegister(' CS', Frame^.Cs);
  WriteRegister(' SS', Frame^.Ss);
  WriteRegister('ERR', Frame^.ErrorCode);
  DebugWriteLine('');
  WriteRegister('CR2', ReadControlRegister2);
  WriteRegister('CR3', ReadControlRegister3);
  WriteRegister('CR8', ReadTaskPriority);
  DebugWriteLine('');
  DebugEndMessage;
end;

procedure DescribePageFault(Frame: PTrapFrame);
var
  ErrorCode: QWord;
begin
  ErrorCode := Frame^.ErrorCode;
  DebugWrite('  ');
  if (ErrorCode and PageFaultInstructionFetch) <> 0 then
    DebugWrite('Instruction fetch from ')
  else if (ErrorCode and PageFaultWrite) <> 0 then
    DebugWrite('Write to ')
  else
    DebugWrite('Read from ');
  DebugWriteAddress(ReadControlRegister2);

  if (ErrorCode and PageFaultPresent) <> 0 then
    DebugWrite(' (protection violation')
  else
    DebugWrite(' (page not present');
  if (ErrorCode and PageFaultUser) <> 0 then
    DebugWrite(', user mode');
  if (ErrorCode and PageFaultReservedBit) <> 0 then
    DebugWrite(', reserved bit set');
  DebugWriteLine(')');
end;

procedure ReportBreakpoint(Frame: PTrapFrame);
begin
  DebugBeginMessage;
  DebugWriteTag('exception');
  DebugWrite('Breakpoint at ');
  DebugWriteAddress(Frame^.Rip);
  DebugWriteLine(', continuing');
  DebugEndMessage;
end;

procedure HandleProcessorException(Frame: PTrapFrame);
var
  Vector: Byte;
begin
  Vector := TrapFrameVector(Frame);

  if Vector = VectorBreakpoint then
  begin
    ReportBreakpoint(Frame);
    Exit;
  end;

  if (Vector = VectorPageFault) and Assigned(PageFaultResolver) and
     PageFaultResolver(ReadControlRegister2, Frame^.ErrorCode) then
    Exit;

  if ArchFrameIsFromUserMode(Frame) and Assigned(UserExceptionHandler) then
  begin
    UserExceptionHandler(Frame, ExceptionNames[Vector]);
    Exit;
  end;

  BeginKernelPanic(PanicUnhandledProcessorException, 'unhandled processor exception');
  DebugWrite('  ');
  DebugWrite(ExceptionNames[Vector]);
  DebugWrite(' (vector ');
  DebugWriteDecimal(Vector);
  DebugWriteLine(')');
  if Vector = VectorPageFault then
    DescribePageFault(Frame);
  DebugWriteLine('');
  WriteTrapFrame(Frame);
  FinishKernelPanic;
end;

end.
