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
  Interrupt remapping on AMD-Vi (the ACPI IVRS table).

  An AMD IOMMU looks each interrupt up by its source: the device table
  (32 bytes per requester id, for buses 0 to the last the MCFG names)
  gives each source an interrupt remapping table of its own (here 256
  entries of 16 bytes, one page), and a message's data (an I/O APIC
  entry's vector field) is the index in it. Entries are the 128-bit
  kind (GAEn), whose destination is 32 bits wide with XTEn (the local
  APICs in x2APIC mode: what reaches ids above 255). DMA is left
  untranslated (the entries' V bit clear); only the interrupt bits are
  valid (IV, IntCtl remapped). A source without an entry passes its
  interrupts through unchanged.

  Changes are told to the IOMMU through its command buffer
  (INVALIDATE_DEVTAB_ENTRY, INVALIDATE_INTERRUPT_TABLE) and waited for
  with COMPLETION_WAIT storing a word. The I/O APICs' requester ids come
  from the IVHD's special device entries. Suspend to RAM resets the
  IOMMU: ResumeAmdRemapping sets its registers again.
}
unit Hal.AmdRemapping;

{$mode objfpc}
{$pointermath on}

interface

{ Reads the IVRS and turns the IOMMUs on for interrupts; False if there
  is none, or x2APIC ids are needed and an IOMMU cannot give them. }
function StartAmdRemapping(ExtendedIds: Boolean): Boolean;
procedure ResumeAmdRemapping;
{ An entry of source SourceId's table for Vector to processor
  Destination: index Preferred if it is free or already says the same,
  else the first free one; returns its index or -1. }
function AddAmdRemapEntry(SourceId: LongWord; Vector: Byte; Destination: LongWord; Preferred: LongInt): LongInt;
{ The requester id the IVRS gives the I/O APIC with this id, or
  High(LongWord). }
function AmdIoApicSourceId(IoApicId: Byte): LongWord;
function AmdRemappingUnitCount: Integer;
{ For the self test: the entry Index of SourceId's table. }
procedure ReadAmdRemapEntry(SourceId: LongWord; Index: LongInt; out Low, High: QWord);

implementation

uses
  Runtime.Memory,
  Runtime.Atomic,
  Memory.Layout,
  Memory.PhysicalPages,
  Memory.DeviceMapping,
  Memory.KernelHeap,
  Kernel.SpinLock,
  Kernel.PriorityLevel,
  Kernel.Arch.Cpu,
  Firmware.Acpi;

const
  MaximumUnits = 4;
  MaximumIoApicEntries = 8;
  RegisterWindow = $4000;
  EntriesPerTable = 256;
  TableLengthField = 8;

  RegisterDeviceTable = $0000;
  RegisterCommandBuffer = $0008;
  RegisterControl = $0018;
  RegisterExtendedFeatures = $0030;
  RegisterCommandHead = $2000;
  RegisterCommandTail = $2008;

  ControlEnable = QWord(1);
  ControlCommandBufferEnable = QWord(1) shl 12;
  ControlGuestApicEnable = QWord(1) shl 17;
  ControlExtendedIds = QWord(1) shl 50;
  FeatureExtendedIds = QWord(1) shl 2;
  FeatureGuestApic = QWord(1) shl 7;

  CommandCompletionWait = 1;
  CommandInvalidateDeviceEntry = 2;
  CommandInvalidateInterruptTable = 5;
  CommandBytes = 16;
  CommandEntries = 256;
  CommandLengthField = 8;

  { The device table entry's third word. }
  EntryInterruptValid = QWord(1);
  EntryInterruptRemapped = QWord(2) shl 60;

  RemapEnable = QWord(1);
  DestinationLowShift = 8;
  DestinationHighShift = 56;

  IvrsBlocksOffset = 48;
  BlockLegacy = $10;
  BlockExtended = $11;
  BlockMixed = $40;
  EntrySpecial = $48;
  SpecialIoApic = 1;
  WaitSpins = 100000000;

type
  TUnit = record
    Registers: PByte;
    Commands: PByte;
    CommandsPhysical: QWord;
    CommandTail: LongWord;
    Status: PQWord;
    StatusPhysical: QWord;
  end;

  TEntryBits = array[0..EntriesPerTable div 64 - 1] of QWord;

  TIoApicEntry = record
    Id: Byte;
    SourceId: LongWord;
  end;

var
  Units: array[0..MaximumUnits - 1] of TUnit;
  UnitCount: Integer = 0;
  IoApicEntries: array[0..MaximumIoApicEntries - 1] of TIoApicEntry;
  IoApicEntryCount: Integer = 0;
  DeviceTable: PQWord = nil;
  DeviceTablePhysical: QWord = 0;
  DeviceTablePages: QWord = 0;
  SourceLimit: LongWord = 0;
  { Each source's table (made when first needed) and its entries in use,
    a bit per entry. }
  Tables: ^PQWord = nil;
  UsedEntries: ^TEntryBits = nil;
  Extended: Boolean = False;
  Lock: TSpinLock;

function Read64(var TheUnit: TUnit; Offset: LongWord): QWord;
begin
  Result := PQWord(TheUnit.Registers + Offset)^;
end;

procedure Write64(var TheUnit: TUnit; Offset: LongWord; Value: QWord);
begin
  PQWord(TheUnit.Registers + Offset)^ := Value;
end;

{ --- Commands ---------------------------------------------------------------------- }

procedure QueueCommand(var TheUnit: TUnit; Word0, Word1, Word2, Word3: LongWord);
var
  Slot: PLongWord;
begin
  Slot := PLongWord(TheUnit.Commands + TheUnit.CommandTail * CommandBytes);
  Slot[0] := Word0;
  Slot[1] := Word1;
  Slot[2] := Word2;
  Slot[3] := Word3;
  TheUnit.CommandTail := (TheUnit.CommandTail + 1) mod CommandEntries;
end;

{ Sends what was queued with a completion wait, and waits for it. }
function FlushCommands(var TheUnit: TUnit): Boolean;
var
  Spins: QWord;
begin
  TheUnit.Status^ := 0;
  QueueCommand(TheUnit, LongWord(TheUnit.StatusPhysical and $FFFFFFF8) or 1,
    LongWord(TheUnit.StatusPhysical shr 32) or (CommandCompletionWait shl 28), 1, 0);
  FullMemoryBarrier;
  Write64(TheUnit, RegisterCommandTail, QWord(TheUnit.CommandTail) * CommandBytes);
  Spins := 0;
  while AtomicLoad(PPtrUInt(TheUnit.Status)^) = 0 do
  begin
    Inc(Spins);
    if Spins >= WaitSpins then
      Exit(False);
    CpuRelax;
  end;
  Result := True;
end;

procedure InvalidateSource(SourceId: LongWord);
var
  Index: Integer;
begin
  for Index := 0 to UnitCount - 1 do
  begin
    QueueCommand(Units[Index], SourceId, CommandInvalidateDeviceEntry shl 28, 0, 0);
    QueueCommand(Units[Index], SourceId, CommandInvalidateInterruptTable shl 28, 0, 0);
    FlushCommands(Units[Index]);
  end;
end;

{ --- Turning an IOMMU on ------------------------------------------------------------- }

function EnableUnit(var TheUnit: TUnit): Boolean;
var
  Control: QWord;
begin
  Control := Read64(TheUnit, RegisterControl) and not (ControlEnable or ControlCommandBufferEnable);
  Write64(TheUnit, RegisterControl, Control);
  Write64(TheUnit, RegisterDeviceTable, DeviceTablePhysical or (DeviceTablePages - 1));
  Write64(TheUnit, RegisterCommandBuffer, TheUnit.CommandsPhysical or (QWord(CommandLengthField) shl 56));
  Write64(TheUnit, RegisterCommandHead, 0);
  Write64(TheUnit, RegisterCommandTail, 0);
  TheUnit.CommandTail := 0;
  Control := Control or ControlGuestApicEnable or ControlCommandBufferEnable;
  if Extended then
    Control := Control or ControlExtendedIds;
  Write64(TheUnit, RegisterControl, Control);
  Write64(TheUnit, RegisterControl, Control or ControlEnable);
  Result := FlushCommands(TheUnit);
end;

function AddUnit(Base: QWord): Boolean;
var
  TheUnit: ^TUnit;
  Features: QWord;
begin
  Result := False;
  if UnitCount >= MaximumUnits then
    Exit;
  TheUnit := @Units[UnitCount];
  TheUnit^.Registers := PByte(MapDeviceMemory(Base, RegisterWindow));
  if TheUnit^.Registers = nil then
    Exit;
  Features := Read64(TheUnit^, RegisterExtendedFeatures);
  if (Features and FeatureGuestApic) = 0 then
    Exit;
  if Extended and ((Features and FeatureExtendedIds) = 0) then
    Exit;
  TheUnit^.CommandsPhysical := AllocateZeroedPhysicalPage(PageUsageGeneral);
  TheUnit^.StatusPhysical := AllocateZeroedPhysicalPage(PageUsageGeneral);
  if (TheUnit^.CommandsPhysical = 0) or (TheUnit^.StatusPhysical = 0) then
    Exit;
  TheUnit^.Commands := PByte(PhysicalToVirtual(TheUnit^.CommandsPhysical));
  TheUnit^.Status := PQWord(PhysicalToVirtual(TheUnit^.StatusPhysical));
  Inc(UnitCount);
  Result := True;
end;

{ --- The IVRS --------------------------------------------------------------------------- }

procedure ReadDeviceEntries(Block: PByte; Start, Length: LongWord);
var
  Offset: LongWord;
  Kind: Byte;
begin
  Offset := Start;
  while Offset + 4 <= Length do
  begin
    Kind := Block[Offset];
    if Kind < $40 then
      Offset := Offset + 4
    else if Kind < $80 then
    begin
      if Offset + 8 > Length then
        Break;
      if (Kind = EntrySpecial) and (Block[Offset + 7] = SpecialIoApic) and
         (IoApicEntryCount < MaximumIoApicEntries) then
      begin
        IoApicEntries[IoApicEntryCount].Id := Block[Offset + 4];
        IoApicEntries[IoApicEntryCount].SourceId := PWord(Block + Offset + 5)^;
        Inc(IoApicEntryCount);
      end;
      Offset := Offset + 8;
    end
    else
      { Variable-length entries (ACPI device names): nothing after them
        is needed here. }
      Break;
  end;
end;

function ReadIvrs: Boolean;
var
  Ivrs: PByte;
  Length: LongWord;
  Offset: LongWord;
  Kind: Byte;
  BlockLength: Word;
  EntriesStart: LongWord;
  HaveNewer: Boolean;
begin
  Result := False;
  Ivrs := PByte(FindAcpiTable('IVRS', 0));
  if Ivrs = nil then
    Exit;
  Length := PAcpiTableHeader(Ivrs)^.Length;
  { A machine lists each IOMMU as a type 10h block and again as 11h or
    40h: the newer kind is taken when present. }
  HaveNewer := False;
  Offset := IvrsBlocksOffset;
  while Offset + 4 <= Length do
  begin
    Kind := Ivrs[Offset];
    BlockLength := PWord(Ivrs + Offset + 2)^;
    if (BlockLength < 4) or (Offset + BlockLength > Length) then
      Break;
    if Kind in [BlockExtended, BlockMixed] then
      HaveNewer := True;
    Offset := Offset + BlockLength;
  end;
  Offset := IvrsBlocksOffset;
  while Offset + 4 <= Length do
  begin
    Kind := Ivrs[Offset];
    BlockLength := PWord(Ivrs + Offset + 2)^;
    if (BlockLength < 24) or (Offset + BlockLength > Length) then
      Break;
    if ((Kind = BlockLegacy) and not HaveNewer) or (Kind in [BlockExtended, BlockMixed]) then
    begin
      if Kind = BlockLegacy then
        EntriesStart := 24
      else
        EntriesStart := 40;
      if not AddUnit(PQWord(Ivrs + Offset + 8)^) then
        Exit(False);
      ReadDeviceEntries(Ivrs + Offset, EntriesStart, BlockLength);
    end;
    Offset := Offset + BlockLength;
  end;
  Result := UnitCount > 0;
end;

{ The last bus the MCFG names (31 without one): the device table covers
  buses 0 to it. }
function LastBus: LongWord;
const
  McfgEntriesOffset = 44;
  McfgEntryLength = 16;
var
  Mcfg: PByte;
  Offset: LongWord;
  Length: LongWord;
begin
  Result := 31;
  Mcfg := PByte(FindAcpiTable('MCFG', 0));
  if Mcfg = nil then
    Exit;
  Result := 0;
  Length := PAcpiTableHeader(Mcfg)^.Length;
  Offset := McfgEntriesOffset;
  while Offset + McfgEntryLength <= Length do
  begin
    if Mcfg[Offset + 11] > Result then
      Result := Mcfg[Offset + 11];
    Offset := Offset + McfgEntryLength;
  end;
end;

function StartAmdRemapping(ExtendedIds: Boolean): Boolean;
var
  Index: Integer;
begin
  Result := False;
  InitializeSpinLock(Lock);
  Extended := ExtendedIds;
  if not ReadIvrs then
    Exit;
  SourceLimit := (LastBus + 1) * 256;
  DeviceTablePages := (QWord(SourceLimit) * 32 + 4095) div 4096;
  DeviceTablePhysical := AllocateZeroedContiguousPhysicalPages(DeviceTablePages, High(TPhysicalAddress),
    PageUsageGeneral);
  if DeviceTablePhysical = 0 then
    Exit;
  DeviceTable := PQWord(PhysicalToVirtual(DeviceTablePhysical));
  Tables := AllocateZeroedKernelMemory(QWord(SourceLimit) * SizeOf(PQWord));
  UsedEntries := AllocateZeroedKernelMemory(QWord(SourceLimit) * SizeOf(TEntryBits));
  if (Tables = nil) or (UsedEntries = nil) then
    Exit;
  for Index := 0 to UnitCount - 1 do
    if not EnableUnit(Units[Index]) then
      Exit;
  Result := True;
end;

procedure ResumeAmdRemapping;
var
  Index: Integer;
begin
  for Index := 0 to UnitCount - 1 do
    EnableUnit(Units[Index]);
end;

{ SourceId's table, made (and named in its device table entry) the
  first time. }
function TableOf(SourceId: LongWord): PQWord;
var
  Physical: QWord;
begin
  Result := Tables[SourceId];
  if Result <> nil then
    Exit;
  Physical := AllocateZeroedPhysicalPage(PageUsageGeneral);
  if Physical = 0 then
    Exit;
  Result := PQWord(PhysicalToVirtual(Physical));
  Tables[SourceId] := Result;
  DeviceTable[SourceId * 4 + 2] := EntryInterruptValid or (QWord(TableLengthField) shl 1) or Physical or
    EntryInterruptRemapped;
end;

function EntryIsUsed(SourceId: LongWord; Index: LongInt): Boolean;
begin
  Result := (UsedEntries[SourceId][Index div 64] and (QWord(1) shl (Index mod 64))) <> 0;
end;

function EntryLow(Destination: LongWord): QWord;
begin
  Result := RemapEnable or (QWord(Destination and $FFFFFF) shl DestinationLowShift);
end;

function EntryHigh(Vector: Byte; Destination: LongWord): QWord;
begin
  Result := Vector or (QWord(Destination shr 24) shl DestinationHighShift);
end;

function AddAmdRemapEntry(SourceId: LongWord; Vector: Byte; Destination: LongWord; Preferred: LongInt): LongInt;
var
  PreviousLevel: TPriorityLevel;
  Table: PQWord;
  Low: QWord;
  High: QWord;
  Index: LongInt;
begin
  Result := -1;
  if (DeviceTable = nil) or (SourceId >= SourceLimit) then
    Exit;
  Low := EntryLow(Destination);
  High := EntryHigh(Vector, Destination);
  PreviousLevel := AcquireSpinLock(Lock);
  Table := TableOf(SourceId);
  if Table <> nil then
  begin
    if (Preferred >= 0) and (Preferred < EntriesPerTable) and
       (not EntryIsUsed(SourceId, Preferred) or
        ((Table[Preferred * 2] = Low) and (Table[Preferred * 2 + 1] = High))) then
      Result := Preferred
    else
      for Index := 0 to EntriesPerTable - 1 do
        if not EntryIsUsed(SourceId, Index) then
        begin
          Result := Index;
          Break;
        end;
    if Result >= 0 then
      UsedEntries[SourceId][Result div 64] := UsedEntries[SourceId][Result div 64] or
        (QWord(1) shl (Result mod 64));
  end;
  ReleaseSpinLock(Lock, PreviousLevel);
  if Result < 0 then
    Exit;
  Table[Result * 2 + 1] := High;
  FullMemoryBarrier;
  Table[Result * 2] := Low;
  FullMemoryBarrier;
  InvalidateSource(SourceId);
end;

function AmdIoApicSourceId(IoApicId: Byte): LongWord;
var
  Index: Integer;
begin
  for Index := 0 to IoApicEntryCount - 1 do
    if IoApicEntries[Index].Id = IoApicId then
      Exit(IoApicEntries[Index].SourceId);
  Result := High(LongWord);
end;

function AmdRemappingUnitCount: Integer;
begin
  Result := UnitCount;
end;

procedure ReadAmdRemapEntry(SourceId: LongWord; Index: LongInt; out Low, High: QWord);
begin
  Low := 0;
  High := 0;
  if (Tables = nil) or (SourceId >= SourceLimit) or (Tables[SourceId] = nil) or (Index < 0) or
     (Index >= EntriesPerTable) then
    Exit;
  Low := Tables[SourceId][Index * 2];
  High := Tables[SourceId][Index * 2 + 1];
end;

end.
