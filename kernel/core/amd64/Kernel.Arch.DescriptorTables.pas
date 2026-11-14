{
  Global descriptor table and task state segment for x86-64.

  In long mode segmentation is mostly unused, but the processor still
  needs code and data descriptors for each privilege level, and a task
  state segment that tells it which stacks to switch to on interrupts.

  Separate "interrupt stack table" stacks are set up for the double fault,
  non-maskable interrupt and machine check exceptions, so they can be
  handled even when the current kernel stack is unusable (for example
  after a stack overflow).
}
unit Kernel.Arch.DescriptorTables;

{$mode objfpc}
{$asmmode intel}

interface

const
  KernelCodeSelector = $08;
  KernelDataSelector = $10;
  UserDataSelector = $18 or 3;
  UserCodeSelector = $20 or 3;
  TaskStateSelector = $28;

  { Interrupt stack table slots (1-based, as the processor numbers them). }
  DoubleFaultStackIndex = 1;
  NonMaskableInterruptStackIndex = 2;
  MachineCheckStackIndex = 3;

procedure InitializeDescriptorTables;

{ Sets the stack the processor switches to when an interrupt arrives while
  running in user mode. }
procedure SetInterruptKernelStack(StackTop: QWord);

implementation

uses
  Runtime.Memory;

const
  { Access byte and flag bits are pre-combined into full descriptors:
    present, ring 0 or 3, code (execute/read, long mode) or data (read/write). }
  KernelCodeDescriptor = QWord($00AF9A000000FFFF);
  KernelDataDescriptor = QWord($00CF92000000FFFF);
  UserDataDescriptor = QWord($00CFF2000000FFFF);
  UserCodeDescriptor = QWord($00AFFA000000FFFF);

  TaskStateTypeAvailable = $89;

  GlobalDescriptorCount = 7; { null, 4 segments, TSS (two slots) }

  InterruptStackSize = 16 * 1024;

type
  TTaskStateSegment = packed record
    Reserved0: LongWord;
    Rsp0: QWord;
    Rsp1: QWord;
    Rsp2: QWord;
    Reserved1: QWord;
    InterruptStackTable: array[1..7] of QWord;
    Reserved2: QWord;
    Reserved3: Word;
    IoPermissionMapOffset: Word;
  end;

  TDescriptorTablePointer = packed record
    Limit: Word;
    Base: QWord;
  end;

  TInterruptStack = array[0..InterruptStackSize - 1] of Byte;

var
  GlobalDescriptors: array[0..GlobalDescriptorCount - 1] of QWord;
  TaskState: TTaskStateSegment;
  DoubleFaultStack: TInterruptStack;
  NonMaskableInterruptStack: TInterruptStack;
  MachineCheckStack: TInterruptStack;

function StackTopOf(var Stack: TInterruptStack): QWord;
begin
  { Keep the top 16-byte aligned as the ABI requires. }
  Result := (QWord(@Stack[High(Stack)]) + 1) and not QWord(15);
end;

procedure EncodeTaskStateDescriptor(Base: QWord; Limit: LongWord;
  out LowHalf: QWord; out HighHalf: QWord);
begin
  LowHalf := QWord(Limit and $FFFF) or
    ((Base and $FFFFFF) shl 16) or
    (QWord(TaskStateTypeAvailable) shl 40) or
    (QWord((Limit shr 16) and $F) shl 48) or
    (((Base shr 24) and $FF) shl 56);
  HighHalf := Base shr 32;
end;

procedure LoadGlobalDescriptorTable(TablePointer: Pointer); assembler; nostackframe;
asm
  lgdt [rdi]
end;

{ Reloads every segment register so the new table takes effect. CS can
  only be changed by a far control transfer, done here with a far return. }
procedure ReloadSegmentRegisters(CodeSelector: QWord; DataSelector: QWord); assembler; nostackframe;
asm
  mov ds, si
  mov es, si
  mov ss, si
  xor eax, eax
  mov fs, ax
  mov gs, ax
  push rdi
  lea rax, [rip + @AfterReload]
  push rax
  retfq
@AfterReload:
end;

procedure LoadTaskRegister(Selector: QWord); assembler; nostackframe;
asm
  ltr di
end;

procedure InitializeDescriptorTables;
var
  TablePointer: TDescriptorTablePointer;
  TaskStateLow: QWord;
  TaskStateHigh: QWord;
begin
  ZeroMemory(@TaskState, SizeOf(TaskState));
  TaskState.InterruptStackTable[DoubleFaultStackIndex] := StackTopOf(DoubleFaultStack);
  TaskState.InterruptStackTable[NonMaskableInterruptStackIndex] := StackTopOf(NonMaskableInterruptStack);
  TaskState.InterruptStackTable[MachineCheckStackIndex] := StackTopOf(MachineCheckStack);

  { An offset past the end of the segment means "no I/O permission map",
    so user mode can never access I/O ports directly. }
  TaskState.IoPermissionMapOffset := SizeOf(TTaskStateSegment);

  GlobalDescriptors[0] := 0;
  GlobalDescriptors[KernelCodeSelector shr 3] := KernelCodeDescriptor;
  GlobalDescriptors[KernelDataSelector shr 3] := KernelDataDescriptor;
  GlobalDescriptors[UserDataSelector shr 3] := UserDataDescriptor;
  GlobalDescriptors[UserCodeSelector shr 3] := UserCodeDescriptor;

  EncodeTaskStateDescriptor(QWord(@TaskState), SizeOf(TTaskStateSegment) - 1,
    TaskStateLow, TaskStateHigh);
  GlobalDescriptors[TaskStateSelector shr 3] := TaskStateLow;
  GlobalDescriptors[(TaskStateSelector shr 3) + 1] := TaskStateHigh;

  TablePointer.Limit := SizeOf(GlobalDescriptors) - 1;
  TablePointer.Base := QWord(@GlobalDescriptors[0]);

  LoadGlobalDescriptorTable(@TablePointer);
  ReloadSegmentRegisters(KernelCodeSelector, KernelDataSelector);
  LoadTaskRegister(TaskStateSelector);
end;

procedure SetInterruptKernelStack(StackTop: QWord);
begin
  TaskState.Rsp0 := StackTop;
end;

end.
