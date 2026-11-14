{
  Interrupt descriptor table for x86-64.

  Every vector that has an entry stub gets an interrupt gate. Interrupt
  gates clear the interrupt flag on entry; the dispatcher re-enables
  interrupts once it has raised the priority level, so higher priority
  interrupts can still nest.
}
unit Kernel.Arch.InterruptTable;

{$mode objfpc}
{$asmmode intel}

interface

procedure InitializeInterruptTable;
{ Loads the (shared) table on a secondary processor. }
procedure LoadInterruptTableOnThisProcessor;

implementation

uses
  Runtime.Memory,
  Hal.InterruptVectors,
  Kernel.Arch.DescriptorTables,
  Kernel.Arch.ExceptionStubs,
  Kernel.Arch.DeviceInterruptStubs;

const
  InterruptVectorCount = 256;

  GateTypeInterrupt = $0E;
  GatePresent = $80;
  GatePrivilegeKernel = $00;
  GatePrivilegeUser = $60;

  VectorNonMaskableInterrupt = 2;
  VectorBreakpoint = 3;
  VectorDoubleFault = 8;
  VectorMachineCheck = 18;

type
  TInterruptGate = packed record
    OffsetLow: Word;
    Selector: Word;
    InterruptStackIndex: Byte;
    TypeAndAttributes: Byte;
    OffsetMiddle: Word;
    OffsetHigh: LongWord;
    Reserved: LongWord;
  end;

  TDescriptorTablePointer = packed record
    Limit: Word;
    Base: QWord;
  end;

var
  InterruptGates: array[0..InterruptVectorCount - 1] of TInterruptGate;

procedure SetInterruptGate(Vector: Byte; Handler: Pointer; StackIndex: Byte;
  Privilege: Byte);
var
  HandlerAddress: QWord;
begin
  HandlerAddress := QWord(Handler);
  InterruptGates[Vector].OffsetLow := Word(HandlerAddress and $FFFF);
  InterruptGates[Vector].Selector := KernelCodeSelector;
  InterruptGates[Vector].InterruptStackIndex := StackIndex;
  InterruptGates[Vector].TypeAndAttributes := GatePresent or Privilege or GateTypeInterrupt;
  InterruptGates[Vector].OffsetMiddle := Word((HandlerAddress shr 16) and $FFFF);
  InterruptGates[Vector].OffsetHigh := LongWord(HandlerAddress shr 32);
  InterruptGates[Vector].Reserved := 0;
end;

function StackIndexForVector(Vector: Byte): Byte;
begin
  case Vector of
    VectorDoubleFault: Result := DoubleFaultStackIndex;
    VectorNonMaskableInterrupt: Result := NonMaskableInterruptStackIndex;
    VectorMachineCheck: Result := MachineCheckStackIndex;
  else
    Result := 0;
  end;
end;

procedure LoadInterruptDescriptorTable(TablePointer: Pointer); assembler; nostackframe;
asm
  lidt [rdi]
end;

procedure InitializeInterruptTable;
var
  Vector: Integer;
  Stub: Pointer;
  Privilege: Byte;
begin
  ZeroMemory(@InterruptGates, SizeOf(InterruptGates));

  for Vector := 0 to ProcessorExceptionVectorCount - 1 do
  begin
    { Allow the breakpoint instruction from user mode, for debuggers. }
    if Vector = VectorBreakpoint then
      Privilege := GatePrivilegeUser
    else
      Privilege := GatePrivilegeKernel;
    SetInterruptGate(Vector, ExceptionStubAddress(Vector), StackIndexForVector(Vector), Privilege);
  end;

  for Vector := ProcessorExceptionVectorCount to InterruptVectorCount - 1 do
  begin
    Stub := DeviceInterruptStubAddress(Vector);
    if Stub <> nil then
      SetInterruptGate(Vector, Stub, 0, GatePrivilegeKernel);
  end;

  LoadInterruptTableOnThisProcessor;
end;

procedure LoadInterruptTableOnThisProcessor;
var
  TablePointer: TDescriptorTablePointer;
begin
  TablePointer.Limit := SizeOf(InterruptGates) - 1;
  TablePointer.Base := QWord(@InterruptGates[0]);
  LoadInterruptDescriptorTable(@TablePointer);
end;

end.
