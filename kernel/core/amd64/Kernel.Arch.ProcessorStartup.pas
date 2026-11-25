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
  Starting the secondary processors of an x86-64 PC.

  A secondary processor wakes up in 16-bit real mode at a page below
  1 MiB. PrepareProcessorStartup copies the start-up code there
  (ProcessorTrampoline.s) together with a small top level page table: it
  maps that low memory at its own address, which the code needs at the
  moment it turns paging on, and shares the kernel half with the kernel's
  table. StartProcessor fills in the processor's stack, block and entry
  point and wakes it; one processor starts at a time, since they share
  the page.

  The new processor arrives at the entry point in 64-bit mode on its idle
  thread's stack, where InitializeThisSecondaryProcessor gives it the
  kernel's page table, its own descriptor tables and block, the shared
  interrupt table, the boot processor's memory type settings (PAT), its
  system call registers and its interrupt controller and clock.
}
unit Kernel.Arch.ProcessorStartup;

{$mode objfpc}
{$pointermath on}

interface

uses
  Kernel.Processors;

{ Sets up the start-up page. Returns False if no low memory is free. }
function PrepareProcessorStartup: Boolean;
{ Wakes Processor, which then runs EntryPoint(Processor) on the stack
  ending at StackTop. False if it could not be started (the firmware
  refused, or says it is still on). }
function StartProcessor(Processor: PProcessor; StackTop: QWord; EntryPoint: Pointer): Boolean;
{ Called by a secondary processor first thing at its entry point. }
procedure InitializeThisSecondaryProcessor(Processor: PProcessor);

{ Waking from suspend to RAM: the firmware starts the boot processor at
  the start-up page (in real mode, like a secondary processor), which
  then runs EntryPoint(Processor) on the stack ending at StackTop. Sets
  that up and returns the page's physical address (the waking vector). }
function PrepareWakeEntry(Processor: PProcessor; StackTop: QWord; EntryPoint: Pointer): QWord;
{ A processor woken from suspend to RAM sets itself up again (as at
  start-up, but keeping its descriptor tables' contents). }
procedure ReinitializeThisProcessor(Processor: PProcessor);

implementation

uses
  Runtime.Memory,
  Memory.Layout,
  Memory.PhysicalPages,
  Memory.Arch.PageTables,
  Kernel.Arch.Cpu,
  Kernel.Arch.DescriptorTables,
  Kernel.Arch.InterruptTable,
  Kernel.Arch.ProcessorBlock,
  Kernel.Arch.SystemCallEntry,
  Hal.Platform;

var
  ProcessorTrampolineStart: Byte; external name 'ProcessorTrampolineStart';
  ProcessorTrampolineEnd: Byte; external name 'ProcessorTrampolineEnd';

const
  { The start-up code page, then its page tables: top level, second and
    third level (one 2 MiB page mapping the start of memory). }
  StartupPageCount = 4;

  { Offsets in the start-up page (see ProcessorTrampoline.s). }
  GdtBaseOffset = 42;
  ProtectedEntryOffset = 48;
  LongEntryOffset = 56;
  Cr0Offset = 64;
  Cr3Offset = 72;
  Cr4Offset = 80;
  EferOffset = 88;
  StackTopOffset = 96;
  ProcessorBlockOffset = 104;
  EntryPointOffset = 112;
  StartedOffset = 120;

  EntryPresent = 1;
  EntryWritable = 2;
  EntryLargePage = $80;
  KernelHalfFirstEntry = 256;
  TableEntries = 512;

  MsrPageAttributeTable = $277;
  EferLongModeActive = QWord(1) shl 10;

var
  StartupPhysical: TPhysicalAddress;
  StartupPage: PByte;
  BootPageAttributes: QWord;

function StartupField(Offset: QWord): PQWord;
begin
  Result := PQWord(StartupPage + Offset);
end;

procedure AddBaseToField(Offset: QWord);
begin
  PLongWord(StartupPage + Offset)^ := PLongWord(StartupPage + Offset)^ + LongWord(StartupPhysical);
end;

procedure BuildStartupPageTables;
var
  TopLevel: PQWord;
  SecondLevel: PQWord;
  ThirdLevel: PQWord;
  KernelTopLevel: PQWord;
  Index: Integer;
begin
  TopLevel := PQWord(PhysicalToVirtual(StartupPhysical + PageSize));
  SecondLevel := PQWord(PhysicalToVirtual(StartupPhysical + 2 * PageSize));
  ThirdLevel := PQWord(PhysicalToVirtual(StartupPhysical + 3 * PageSize));
  ZeroMemory(TopLevel, PageSize);
  ZeroMemory(SecondLevel, PageSize);
  ZeroMemory(ThirdLevel, PageSize);

  TopLevel[0] := (StartupPhysical + 2 * PageSize) or EntryPresent or EntryWritable;
  SecondLevel[0] := (StartupPhysical + 3 * PageSize) or EntryPresent or EntryWritable;
  ThirdLevel[0] := 0 or EntryPresent or EntryWritable or EntryLargePage;

  KernelTopLevel := PQWord(PhysicalToVirtual(KernelPageTableRoot));
  for Index := KernelHalfFirstEntry to TableEntries - 1 do
    TopLevel[Index] := KernelTopLevel[Index];
end;

function PrepareProcessorStartup: Boolean;
var
  CodeSize: QWord;
begin
  StartupPhysical := ClaimLowPhysicalPages(StartupPageCount);
  if StartupPhysical = 0 then
    Exit(False);
  StartupPage := PByte(PhysicalToVirtual(StartupPhysical));
  CodeSize := QWord(@ProcessorTrampolineEnd) - QWord(@ProcessorTrampolineStart);
  CopyMemory(StartupPage, @ProcessorTrampolineStart, CodeSize);
  AddBaseToField(GdtBaseOffset);
  AddBaseToField(ProtectedEntryOffset);
  AddBaseToField(LongEntryOffset);
  BuildStartupPageTables;

  { Every processor runs with the boot processor's settings. }
  StartupField(Cr0Offset)^ := ReadControlRegister0;
  StartupField(Cr3Offset)^ := StartupPhysical + PageSize;
  StartupField(Cr4Offset)^ := ReadControlRegister4;
  StartupField(EferOffset)^ := ReadModelSpecificRegister(MsrExtendedFeatureEnable) and
    not EferLongModeActive;
  BootPageAttributes := ReadModelSpecificRegister(MsrPageAttributeTable);
  Result := True;
end;

function PrepareWakeEntry(Processor: PProcessor; StackTop: QWord; EntryPoint: Pointer): QWord;
begin
  { The kernel half may have grown new top level entries since start-up. }
  BuildStartupPageTables;
  StartupField(StackTopOffset)^ := StackTop;
  StartupField(ProcessorBlockOffset)^ := QWord(Processor);
  StartupField(EntryPointOffset)^ := QWord(EntryPoint);
  StartupField(StartedOffset)^ := 0;
  Result := StartupPhysical;
end;

function StartProcessor(Processor: PProcessor; StackTop: QWord; EntryPoint: Pointer): Boolean;
begin
  StartupField(StackTopOffset)^ := StackTop;
  StartupField(ProcessorBlockOffset)^ := QWord(Processor);
  StartupField(EntryPointOffset)^ := QWord(EntryPoint);
  StartupField(StartedOffset)^ := 0;
  HalStartProcessor(Processor^.ApicId, Byte(StartupPhysical shr PageShift));
  { INIT and STARTUP are not answered. }
  Result := True;
end;

procedure InitializeThisSecondaryProcessor(Processor: PProcessor);
begin
  WriteControlRegister3(KernelPageTableRoot);
  Processor^.ActiveAddressSpace := KernelPageTableRoot;
  InitializeDescriptorTables(Processor^.DescriptorTables, Processor^.InterruptStackArea);
  { After the segment registers were reloaded (which clears GS). }
  ArchSetProcessorBlock(Processor);
  LoadInterruptTableOnThisProcessor;
  WriteModelSpecificRegister(MsrPageAttributeTable, BootPageAttributes);
  EnableSystemCallsOnThisProcessor;
  HalInitializeSecondaryProcessor;
end;

procedure ReinitializeThisProcessor(Processor: PProcessor);
begin
  WriteControlRegister3(Processor^.ActiveAddressSpace);
  ReloadDescriptorTables(Processor^.DescriptorTables);
  ArchSetProcessorBlock(Processor);
  LoadInterruptTableOnThisProcessor;
  WriteModelSpecificRegister(MsrPageAttributeTable, BootPageAttributes);
  EnableSystemCallsOnThisProcessor;
end;

end.
