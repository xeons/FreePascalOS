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
  Interrupt remapping on Intel VT-d (the ACPI DMAR table).

  Each remapping unit (DRHD) gets the same interrupt remapping table
  (4096 entries of 16 bytes): an I/O APIC entry or a message names an
  entry (its "handle") instead of a processor, and the entry holds the
  vector, the destination - a full 32-bit x2APIC id in extended
  interrupt mode (EIME, used when the local APICs are in x2APIC mode) -
  the trigger mode and the source allowed to use it (the requester id
  of the PCI function, or the I/O APIC's from the DMAR's device scope;
  SVT 1 verifies it).

  Turning it on, per unit: the invalidation queue (one page of 16-byte
  descriptors; changing an entry needs the interrupt entry cache
  invalidated, which only the queue can ask), the table's address
  (SIRTP), a global interrupt entry cache invalidation waited for with a
  status write, then IRE. DMA remapping stays off. Suspend to RAM resets
  the units: ResumeIntelRemapping does it all again (the table is in
  memory and kept).

  Entries are given out once and kept (connections are made at start
  and rarely after), each changed entry invalidated by index.
}
unit Hal.IntelRemapping;

{$mode objfpc}
{$pointermath on}

interface

{ Reads the DMAR and turns remapping on in every unit; False if there
  is none or a unit cannot remap interrupts. ExtendedIds: the local
  APICs are in x2APIC mode. }
function StartIntelRemapping(ExtendedIds: Boolean): Boolean;
procedure ResumeIntelRemapping;
{ A new entry for Vector to processor Destination from source SourceId
  (High(LongWord): unknown, not verified); returns its handle or -1. }
function AddIntelRemapEntry(Vector: Byte; Destination: LongWord; LevelTriggered: Boolean;
  SourceId: LongWord): LongInt;
{ The source id the DMAR gives the I/O APIC with this id, or
  High(LongWord). }
function IntelIoApicSourceId(IoApicId: Byte): LongWord;
function IntelRemappingUnitCount: Integer;
{ The entry for (the self test) handle Handle, as its two words. }
procedure ReadIntelRemapEntry(Handle: LongInt; out Low, High: QWord);

implementation

uses
  Runtime.Memory,
  Runtime.Atomic,
  Memory.Layout,
  Memory.PhysicalPages,
  Memory.DeviceMapping,
  Kernel.SpinLock,
  Kernel.PriorityLevel,
  Kernel.Arch.Cpu,
  Firmware.Acpi;

const
  MaximumUnits = 8;
  MaximumIoApicScopes = 8;
  { 4096 entries (S = 11: 2^(S+1)). }
  EntrySizeField = 11;
  EntryCount = 4096;
  EntryTablePages = EntryCount * 16 div 4096;
  RegisterWindow = $1000;

  RegisterCapability = $08;
  RegisterExtendedCapability = $10;
  RegisterGlobalCommand = $18;
  RegisterGlobalStatus = $1C;
  RegisterRemapTableAddress = $B8;
  RegisterQueueHead = $80;
  RegisterQueueTail = $88;
  RegisterQueueAddress = $90;

  ExtendedQueuedInvalidation = QWord(1) shl 1;
  ExtendedInterruptRemapping = QWord(1) shl 3;
  ExtendedInterruptMode = QWord(1) shl 4;

  CommandQueueEnable = LongWord(1) shl 26;
  CommandRemapEnable = LongWord(1) shl 25;
  CommandSetTablePointer = LongWord(1) shl 24;
  CommandCompatibilityFormat = LongWord(1) shl 23;
  StatusQueueEnabled = LongWord(1) shl 26;
  StatusRemapEnabled = LongWord(1) shl 25;
  StatusTablePointerSet = LongWord(1) shl 24;
  { The status bits that stand for commands kept on (written back with
    every command). }
  PersistentStatus = LongWord($96FFFFFF);

  TableExtendedMode = QWord(1) shl 11;

  DescriptorEntryCacheInvalidate = 4;
  DescriptorEntryCacheIndexed = QWord(1) shl 4;
  DescriptorWait = 5;
  DescriptorWaitStatusWrite = QWord(1) shl 5;
  QueueDescriptorBytes = 16;
  QueueEntries = 256;

  EntryPresent = QWord(1);
  EntryLevelTriggered = QWord(1) shl 4;
  EntryVectorShift = 16;
  EntryDestinationShift = 32;
  EntryLegacyDestinationShift = 40;
  { High word: verify the source id exactly (SVT 1, SQ 0). }
  EntryVerifySource = QWord(1) shl 18;

  DmarHeaderLength = 48;
  DmarFlagsOffset = 37;
  StructureUnit = 0;
  ScopeIoApic = 3;
  WaitSpins = 100000000;

type
  TUnit = record
    Registers: PByte;
    Queue: PByte;
    QueuePhysical: QWord;
    QueueTail: LongWord;
    { A page for the wait descriptors' status writes. }
    Status: PLongWord;
    StatusPhysical: QWord;
  end;

  TIoApicScope = record
    Id: Byte;
    SourceId: LongWord;
  end;

var
  Units: array[0..MaximumUnits - 1] of TUnit;
  UnitCount: Integer = 0;
  IoApicScopes: array[0..MaximumIoApicScopes - 1] of TIoApicScope;
  IoApicScopeCount: Integer = 0;
  Table: PQWord = nil;
  TablePhysical: QWord = 0;
  NextEntry: LongInt = 0;
  Extended: Boolean = False;
  Lock: TSpinLock;

function Read32(var TheUnit: TUnit; Offset: LongWord): LongWord;
begin
  Result := PLongWord(TheUnit.Registers + Offset)^;
end;

procedure Write32(var TheUnit: TUnit; Offset, Value: LongWord);
begin
  PLongWord(TheUnit.Registers + Offset)^ := Value;
end;

function Read64(var TheUnit: TUnit; Offset: LongWord): QWord;
begin
  Result := PQWord(TheUnit.Registers + Offset)^;
end;

procedure Write64(var TheUnit: TUnit; Offset: LongWord; Value: QWord);
begin
  PQWord(TheUnit.Registers + Offset)^ := Value;
end;

{ Sets Command (with the commands kept on) and waits for Status. }
function RunCommand(var TheUnit: TUnit; Command, Status: LongWord): Boolean;
var
  Spins: QWord;
begin
  Write32(TheUnit, RegisterGlobalCommand, (Read32(TheUnit, RegisterGlobalStatus) and PersistentStatus) or Command);
  Spins := 0;
  while (Read32(TheUnit, RegisterGlobalStatus) and Status) = 0 do
  begin
    Inc(Spins);
    if Spins >= WaitSpins then
      Exit(False);
    CpuRelax;
  end;
  Result := True;
end;

{ --- The invalidation queue --------------------------------------------------- }

procedure SubmitDescriptor(var TheUnit: TUnit; Low, High: QWord);
var
  Slot: PQWord;
begin
  Slot := PQWord(TheUnit.Queue + TheUnit.QueueTail * QueueDescriptorBytes);
  Slot[0] := Low;
  Slot[1] := High;
  TheUnit.QueueTail := (TheUnit.QueueTail + 1) mod QueueEntries;
end;

{ Submits what was queued and a wait descriptor, and waits for its
  status write. }
function FlushQueue(var TheUnit: TUnit): Boolean;
var
  Spins: QWord;
begin
  TheUnit.Status^ := 0;
  SubmitDescriptor(TheUnit, DescriptorWait or DescriptorWaitStatusWrite or (QWord(1) shl 32), TheUnit.StatusPhysical);
  FullMemoryBarrier;
  Write64(TheUnit, RegisterQueueTail, QWord(TheUnit.QueueTail) * QueueDescriptorBytes);
  Spins := 0;
  while AtomicLoad(PPtrUInt(TheUnit.Status)^) and $FFFFFFFF = 0 do
  begin
    Inc(Spins);
    if Spins >= WaitSpins then
      Exit(False);
    CpuRelax;
  end;
  Result := True;
end;

procedure InvalidateEntry(var TheUnit: TUnit; Handle: LongInt);
begin
  SubmitDescriptor(TheUnit, DescriptorEntryCacheInvalidate or DescriptorEntryCacheIndexed or
    (QWord(Handle) shl 32), 0);
  FlushQueue(TheUnit);
end;

{ --- Turning a unit on ------------------------------------------------------------ }

function EnableUnit(var TheUnit: TUnit): Boolean;
var
  TableValue: QWord;
begin
  TheUnit.QueueTail := 0;
  Write64(TheUnit, RegisterQueueTail, 0);
  Write64(TheUnit, RegisterQueueAddress, TheUnit.QueuePhysical);
  Result := RunCommand(TheUnit, CommandQueueEnable, StatusQueueEnabled);
  if not Result then
    Exit;
  TableValue := TablePhysical or EntrySizeField;
  if Extended then
    TableValue := TableValue or TableExtendedMode;
  Write64(TheUnit, RegisterRemapTableAddress, TableValue);
  Result := RunCommand(TheUnit, CommandSetTablePointer, StatusTablePointerSet);
  if not Result then
    Exit;
  { Every cached entry thrown away. }
  SubmitDescriptor(TheUnit, DescriptorEntryCacheInvalidate, 0);
  Result := FlushQueue(TheUnit) and RunCommand(TheUnit, CommandRemapEnable, StatusRemapEnabled);
end;

{ --- The DMAR ------------------------------------------------------------------------ }

procedure ReadScopes(Structure: PByte; Length: LongWord);
var
  Offset: LongWord;
  ScopeLength: Byte;
  Bus: Byte;
begin
  Offset := 16;
  while Offset + 6 <= Length do
  begin
    ScopeLength := Structure[Offset + 1];
    if ScopeLength < 6 then
      Break;
    if (Structure[Offset] = ScopeIoApic) and (ScopeLength >= 8) and (IoApicScopeCount < MaximumIoApicScopes) then
    begin
      Bus := Structure[Offset + 5];
      IoApicScopes[IoApicScopeCount].Id := Structure[Offset + 4];
      IoApicScopes[IoApicScopeCount].SourceId := (LongWord(Bus) shl 8) or
        (LongWord(Structure[Offset + 6]) shl 3) or Structure[Offset + 7];
      Inc(IoApicScopeCount);
    end;
    Offset := Offset + ScopeLength;
  end;
end;

function AddUnit(RegisterBase: QWord): Boolean;
var
  TheUnit: ^TUnit;
  Capabilities: QWord;
begin
  Result := False;
  if UnitCount >= MaximumUnits then
    Exit;
  TheUnit := @Units[UnitCount];
  TheUnit^.Registers := PByte(MapDeviceMemory(RegisterBase, RegisterWindow));
  if TheUnit^.Registers = nil then
    Exit;
  Capabilities := Read64(TheUnit^, RegisterExtendedCapability);
  if ((Capabilities and ExtendedInterruptRemapping) = 0) or ((Capabilities and ExtendedQueuedInvalidation) = 0) then
    Exit;
  if Extended and ((Capabilities and ExtendedInterruptMode) = 0) then
    Exit;
  TheUnit^.QueuePhysical := AllocateZeroedPhysicalPage(PageUsageGeneral);
  if TheUnit^.QueuePhysical = 0 then
    Exit;
  TheUnit^.Queue := PByte(PhysicalToVirtual(TheUnit^.QueuePhysical));
  TheUnit^.StatusPhysical := AllocateZeroedPhysicalPage(PageUsageGeneral);
  if TheUnit^.StatusPhysical = 0 then
    Exit;
  TheUnit^.Status := PLongWord(PhysicalToVirtual(TheUnit^.StatusPhysical));
  Inc(UnitCount);
  Result := True;
end;

function ReadDmar: Boolean;
var
  Dmar: PByte;
  Length: LongWord;
  Offset: LongWord;
  StructureType: Word;
  StructureLength: Word;
begin
  Result := False;
  Dmar := PByte(FindAcpiTable('DMAR', 0));
  if Dmar = nil then
    Exit;
  Length := PAcpiTableHeader(Dmar)^.Length;
  Offset := DmarHeaderLength;
  while Offset + 4 <= Length do
  begin
    StructureType := PWord(Dmar + Offset)^;
    StructureLength := PWord(Dmar + Offset + 2)^;
    if (StructureLength < 4) or (Offset + StructureLength > Length) then
      Break;
    if (StructureType = StructureUnit) and (StructureLength >= 16) then
    begin
      if not AddUnit(PQWord(Dmar + Offset + 8)^) then
        Exit(False);
      ReadScopes(Dmar + Offset, StructureLength);
    end;
    Offset := Offset + StructureLength;
  end;
  Result := UnitCount > 0;
end;

function StartIntelRemapping(ExtendedIds: Boolean): Boolean;
var
  Index: Integer;
begin
  Result := False;
  InitializeSpinLock(Lock);
  Extended := ExtendedIds;
  if not ReadDmar then
    Exit;
  TablePhysical := AllocateZeroedContiguousPhysicalPages(EntryTablePages, High(TPhysicalAddress), PageUsageGeneral);
  if TablePhysical = 0 then
    Exit;
  Table := PQWord(PhysicalToVirtual(TablePhysical));
  for Index := 0 to UnitCount - 1 do
    if not EnableUnit(Units[Index]) then
      Exit;
  Result := True;
end;

procedure ResumeIntelRemapping;
var
  Index: Integer;
begin
  for Index := 0 to UnitCount - 1 do
    EnableUnit(Units[Index]);
end;

function AddIntelRemapEntry(Vector: Byte; Destination: LongWord; LevelTriggered: Boolean;
  SourceId: LongWord): LongInt;
var
  PreviousLevel: TPriorityLevel;
  Low: QWord;
  High: QWord;
  Index: Integer;
begin
  PreviousLevel := AcquireSpinLock(Lock);
  Result := -1;
  if NextEntry < EntryCount then
  begin
    Result := NextEntry;
    Inc(NextEntry);
  end;
  ReleaseSpinLock(Lock, PreviousLevel);
  if Result < 0 then
    Exit;
  Low := EntryPresent or (QWord(Vector) shl EntryVectorShift);
  if LevelTriggered then
    Low := Low or EntryLevelTriggered;
  if Extended then
    Low := Low or (QWord(Destination) shl EntryDestinationShift)
  else
    Low := Low or (QWord(Destination and $FF) shl EntryLegacyDestinationShift);
  High := 0;
  if SourceId <= $FFFF then
    High := EntryVerifySource or SourceId;
  Table[Result * 2 + 1] := High;
  FullMemoryBarrier;
  Table[Result * 2] := Low;
  FullMemoryBarrier;
  for Index := 0 to UnitCount - 1 do
    InvalidateEntry(Units[Index], Result);
end;

function IntelIoApicSourceId(IoApicId: Byte): LongWord;
var
  Index: Integer;
begin
  for Index := 0 to IoApicScopeCount - 1 do
    if IoApicScopes[Index].Id = IoApicId then
      Exit(IoApicScopes[Index].SourceId);
  Result := High(LongWord);
end;

function IntelRemappingUnitCount: Integer;
begin
  Result := UnitCount;
end;

procedure ReadIntelRemapEntry(Handle: LongInt; out Low, High: QWord);
begin
  Low := 0;
  High := 0;
  if (Table = nil) or (Handle < 0) or (Handle >= EntryCount) then
    Exit;
  Low := Table[Handle * 2];
  High := Table[Handle * 2 + 1];
end;

end.
