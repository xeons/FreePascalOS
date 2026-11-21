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
  Handling of x86-64 processor exceptions.

  Page faults go to the resolver first (demand paging, copy on write).
  An exception raised by user mode code goes to the user exception
  handler (Processes.UserProcess), which passes it to the program or ends
  it. Any other exception in the kernel is a kernel bug: the handler
  prints a description and a register dump, then stops the system;
  breakpoints are reported and execution continues.
}
unit Kernel.Arch.Exceptions;

{$mode objfpc}

interface

uses
  Kernel.Arch.TrapFrame;

const
  VectorPageFault = 14;

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
  Debug.Output,
  Kernel.Arch.UserCopy;

const
  VectorNonMaskableInterrupt = 2;
  VectorBreakpoint = 3;

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
  FaultAddress: QWord;
  Resolved: Boolean;
begin
  FaultAddress := 0;
  Vector := TrapFrameVector(Frame);

  if Vector = VectorBreakpoint then
  begin
    ReportBreakpoint(Frame);
    Exit;
  end;

  { Another processor panicked and stops this one (Kernel.Panic). }
  if (Vector = VectorNonMaskableInterrupt) and PanicIsInProgress then
    while True do
    begin
      DisableInterrupts;
      HaltProcessor;
    end;

  if Vector = VectorPageFault then
  begin
    FaultAddress := ReadControlRegister2;
    { Resolving may take spin locks whose holder waits for this
      processor to answer a TLB shootdown, which needs interrupts. }
    if (Frame^.Rflags and RflagsInterruptEnable) <> 0 then
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
    UserExceptionHandler(Frame, ExceptionNames[Vector], FaultAddress);
    Exit;
  end;

  SetPanicTraceStart(TrapFrameInstructionPointer(Frame), TrapFrameFramePointer(Frame));
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
