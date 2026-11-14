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

const
  GlobalDescriptorCount = 7; { null, 4 segments, TSS (two slots) }
  InterruptStackSize = 16 * 1024;
  { The double fault, NMI and machine check stacks of one processor. }
  InterruptStackAreaSize = 3 * InterruptStackSize;

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

  { Every processor has its own GDT and TSS (the TSS holds the stacks the
    processor switches to, which differ per processor). }
  TProcessorDescriptorTables = record
    GlobalDescriptors: array[0..GlobalDescriptorCount - 1] of QWord;
    TaskState: TTaskStateSegment;
  end;

{ Builds and loads the boot processor's tables, with static interrupt
  stacks (there is no heap yet). }
procedure InitializeBootDescriptorTables(var Tables: TProcessorDescriptorTables);
{ Builds and loads another processor's tables; StackArea holds
  InterruptStackAreaSize bytes for its interrupt stacks. }
procedure InitializeDescriptorTables(var Tables: TProcessorDescriptorTables; StackArea: Pointer);

{ Sets the stack the current processor switches to when an interrupt
  arrives while running in user mode. }
procedure SetInterruptKernelStack(StackTop: QWord);

implementation

uses
  Runtime.Memory,
  Kernel.Processors;

const
  { Access byte and flag bits are pre-combined into full descriptors:
    present, ring 0 or 3, code (execute/read, long mode) or data (read/write). }
  KernelCodeDescriptor = QWord($00AF9A000000FFFF);
  KernelDataDescriptor = QWord($00CF92000000FFFF);
  UserDataDescriptor = QWord($00CFF2000000FFFF);
  UserCodeDescriptor = QWord($00AFFA000000FFFF);

  TaskStateTypeAvailable = $89;

type
  TDescriptorTablePointer = packed record
    Limit: Word;
    Base: QWord;
  end;

  TInterruptStack = array[0..InterruptStackSize - 1] of Byte;

var
  BootDoubleFaultStack: TInterruptStack;
  BootNonMaskableInterruptStack: TInterruptStack;
  BootMachineCheckStack: TInterruptStack;


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

function AlignedStackTop(StackBase: Pointer; Size: QWord): QWord;
begin
  { Keep the top 16-byte aligned as the ABI requires. }
  Result := (QWord(StackBase) + Size) and not QWord(15);
end;

procedure BuildAndLoadTables(var Tables: TProcessorDescriptorTables;
  DoubleFaultTop, NonMaskableTop, MachineCheckTop: QWord);
var
  TablePointer: TDescriptorTablePointer;
  TaskStateLow: QWord;
  TaskStateHigh: QWord;
begin
  ZeroMemory(@Tables.TaskState, SizeOf(Tables.TaskState));
  Tables.TaskState.InterruptStackTable[DoubleFaultStackIndex] := DoubleFaultTop;
  Tables.TaskState.InterruptStackTable[NonMaskableInterruptStackIndex] := NonMaskableTop;
  Tables.TaskState.InterruptStackTable[MachineCheckStackIndex] := MachineCheckTop;

  { An offset past the end of the segment means "no I/O permission map",
    so user mode can never access I/O ports directly. }
  Tables.TaskState.IoPermissionMapOffset := SizeOf(TTaskStateSegment);

  Tables.GlobalDescriptors[0] := 0;
  Tables.GlobalDescriptors[KernelCodeSelector shr 3] := KernelCodeDescriptor;
  Tables.GlobalDescriptors[KernelDataSelector shr 3] := KernelDataDescriptor;
  Tables.GlobalDescriptors[UserDataSelector shr 3] := UserDataDescriptor;
  Tables.GlobalDescriptors[UserCodeSelector shr 3] := UserCodeDescriptor;

  EncodeTaskStateDescriptor(QWord(@Tables.TaskState), SizeOf(TTaskStateSegment) - 1,
    TaskStateLow, TaskStateHigh);
  Tables.GlobalDescriptors[TaskStateSelector shr 3] := TaskStateLow;
  Tables.GlobalDescriptors[(TaskStateSelector shr 3) + 1] := TaskStateHigh;

  TablePointer.Limit := SizeOf(Tables.GlobalDescriptors) - 1;
  TablePointer.Base := QWord(@Tables.GlobalDescriptors[0]);

  LoadGlobalDescriptorTable(@TablePointer);
  ReloadSegmentRegisters(KernelCodeSelector, KernelDataSelector);
  LoadTaskRegister(TaskStateSelector);
end;

procedure InitializeBootDescriptorTables(var Tables: TProcessorDescriptorTables);
begin
  BuildAndLoadTables(Tables,
    AlignedStackTop(@BootDoubleFaultStack[0], InterruptStackSize),
    AlignedStackTop(@BootNonMaskableInterruptStack[0], InterruptStackSize),
    AlignedStackTop(@BootMachineCheckStack[0], InterruptStackSize));
end;

procedure InitializeDescriptorTables(var Tables: TProcessorDescriptorTables; StackArea: Pointer);
begin
  BuildAndLoadTables(Tables,
    AlignedStackTop(StackArea, InterruptStackSize),
    AlignedStackTop(PByte(StackArea) + InterruptStackSize, InterruptStackSize),
    AlignedStackTop(PByte(StackArea) + 2 * InterruptStackSize, InterruptStackSize));
end;

procedure SetInterruptKernelStack(StackTop: QWord);
begin
  CurrentProcessor^.DescriptorTables.TaskState.Rsp0 := StackTop;
end;

end.
