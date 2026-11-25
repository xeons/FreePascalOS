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
  Starting the other processors on AArch64.

  The firmware starts a processor on request (PSCI CPU_ON, Hal.Psci) at a
  physical address with its MMU off, at EL2 on the Raspberry Pi and EL1
  in QEMU, passing one argument. The entry code (ArchSecondaryEntry in
  KernelEntry.s) is part of the kernel image; it is started with the
  physical address of a start-up record holding the boot processor's
  memory attributes, translation control and system control, the
  kernel's table root, and a small identity mapping of the page the
  entry code is on, so it can turn translation on and continue at its
  linked address. There it takes its stack, block and entry point from
  the record.

  The record and the identity tables are read with the MMU (and caches)
  off, so they are cleaned to the point of coherency before each start.
}
unit Kernel.Arch.ProcessorStartup;

{$mode objfpc}
{$pointermath on}

interface

uses
  Kernel.Processors;

{ Sets up the start-up record and tables. Returns False if memory ran
  out or the firmware cannot start processors. }
function PrepareProcessorStartup: Boolean;
{ Wakes Processor, which then runs EntryPoint(Processor) on the stack
  ending at StackTop. False if it could not be started (the firmware
  refused, or says it is still on). }
function StartProcessor(Processor: PProcessor; StackTop: QWord; EntryPoint: Pointer): Boolean;
{ Called by a secondary processor first thing at its entry point. }
procedure InitializeThisSecondaryProcessor(Processor: PProcessor);
{ Suspend to RAM (PSCI SYSTEM_SUSPEND): the boot processor wakes through
  the start-up entry as a started processor does, then runs
  EntryPoint(Processor) on the stack ending at StackTop. Returns the
  entry's physical address; WakeEntryContext is the X0 to give it. }
function PrepareWakeEntry(Processor: PProcessor; StackTop: QWord; EntryPoint: Pointer): QWord;
function WakeEntryContext: QWord;
procedure ReinitializeThisProcessor(Processor: PProcessor);

implementation

uses
  Runtime.Memory,
  Boot.TranslationTableFormat,
  Memory.Layout,
  Memory.PhysicalPages,
  Memory.Arch.PageTables,
  Kernel.Arch.Cpu,
  Kernel.Arch.DescriptorTables,
  Kernel.Arch.ProcessorBlock,
  Kernel.Arch.ProcessorProtection,
  Hal.Platform;

type
  { Read by ArchSecondaryEntry (offsets there). }
  TSecondaryStartRecord = record
    MemoryAttributes: QWord;
    TranslationControl: QWord;
    IdentityRoot: QWord;
    KernelRoot: QWord;
    SystemControl: QWord;
    StackTop: QWord;
    Processor: QWord;
    EntryPoint: QWord;
  end;
  PSecondaryStartRecord = ^TSecondaryStartRecord;

  TPageTable = array[0..EntriesPerTable - 1] of QWord;
  PPageTable = ^TPageTable;

const
  TableLevels = 4;

var
  RecordPhysical: TPhysicalAddress;
  StartRecord: PSecondaryStartRecord;
  EntryPhysical: TPhysicalAddress;
  IdentityTables: array[1..TableLevels] of TPhysicalAddress;

procedure ArchSecondaryEntry; external name 'ArchSecondaryEntry';
function ArchReadTranslationControl: QWord; external name 'ArchReadTranslationControl';
function ArchReadMemoryAttributes: QWord; external name 'ArchReadMemoryAttributes';
function ArchReadSystemControl: QWord; external name 'ArchReadSystemControl';

function TableIndex(Address: QWord; Level: Integer): Integer;
begin
  Result := Integer((Address shr (PageShift + 9 * (Level - 1))) and (EntriesPerTable - 1));
end;

{ Maps the entry code's page at its own (physical) address. }
function BuildIdentityTables: Boolean;
var
  Level: Integer;
  Table: PPageTable;
  PageAddress: QWord;
begin
  for Level := TableLevels downto 1 do
  begin
    IdentityTables[Level] := AllocateZeroedPhysicalPage(PageUsagePageTable);
    if IdentityTables[Level] = 0 then
      Exit(False);
  end;
  PageAddress := EntryPhysical and not PageOffsetMask;
  for Level := TableLevels downto 2 do
  begin
    Table := PPageTable(PhysicalToVirtual(IdentityTables[Level]));
    Table^[TableIndex(PageAddress, Level)] := IdentityTables[Level - 1] or DescriptorValid or
      DescriptorTableOrPage;
  end;
  Table := PPageTable(PhysicalToVirtual(IdentityTables[1]));
  Table^[TableIndex(PageAddress, 1)] := PageAddress or DescriptorValid or DescriptorTableOrPage or
    MemoryTypeBits(MemoryTypeNormal) or DescriptorInnerShareable or DescriptorAccessed or
    DescriptorReadOnly or DescriptorUserExecuteNever;
  for Level := 1 to TableLevels do
    CleanDataCache(PhysicalToVirtual(IdentityTables[Level]), PageSize);
  Result := True;
end;

function PrepareProcessorStartup: Boolean;
begin
  Result := False;
  if not TranslateVirtualAddress(QWord(@ArchSecondaryEntry), EntryPhysical) then
    Exit;
  RecordPhysical := AllocateZeroedPhysicalPage(PageUsagePageTable);
  if (RecordPhysical = 0) or not BuildIdentityTables then
    Exit;
  StartRecord := PSecondaryStartRecord(PhysicalToVirtual(RecordPhysical));
  StartRecord^.MemoryAttributes := ArchReadMemoryAttributes;
  StartRecord^.TranslationControl := ArchReadTranslationControl;
  StartRecord^.IdentityRoot := IdentityTables[TableLevels];
  StartRecord^.KernelRoot := KernelPageTableRoot;
  StartRecord^.SystemControl := ArchReadSystemControl;
  Result := True;
end;

function StartProcessor(Processor: PProcessor; StackTop: QWord; EntryPoint: Pointer): Boolean;
begin
  StartRecord^.StackTop := StackTop;
  StartRecord^.Processor := QWord(Processor);
  StartRecord^.EntryPoint := QWord(EntryPoint);
  CleanDataCache(StartRecord, SizeOf(TSecondaryStartRecord));
  Result := HalStartProcessorAt(Processor^.ApicId, EntryPhysical, RecordPhysical);
end;

procedure InitializeThisSecondaryProcessor(Processor: PProcessor);
begin
  { The priority level (a spin lock raises it) needs it on a GICv3. }
  HalOpenInterruptInterface;
  ArchSetProcessorBlock(Processor);
  InitializeDescriptorTables(Processor^.DescriptorTables, Processor^.InterruptStackArea);
  { Off the start-up identity mapping, onto an empty user half. }
  ActivateAddressSpace(0);
  EnableProcessorProtectionOnThisProcessor;
  HalInitializeSecondaryProcessor;
end;

function PrepareWakeEntry(Processor: PProcessor; StackTop: QWord; EntryPoint: Pointer): QWord;
begin
  Result := 0;
  if StartRecord = nil then
    Exit;
  StartRecord^.StackTop := StackTop;
  StartRecord^.Processor := QWord(Processor);
  StartRecord^.EntryPoint := QWord(EntryPoint);
  CleanDataCache(StartRecord, SizeOf(TSecondaryStartRecord));
  Result := EntryPhysical;
end;

function WakeEntryContext: QWord;
begin
  Result := RecordPhysical;
end;

procedure ReinitializeThisProcessor(Processor: PProcessor);
begin
  HalOpenInterruptInterface;
  ArchSetProcessorBlock(Processor);
  ReloadDescriptorTables(Processor^.DescriptorTables);
  ActivateAddressSpace(Processor^.ActiveAddressSpace);
  EnableProcessorProtectionOnThisProcessor;
end;

end.
