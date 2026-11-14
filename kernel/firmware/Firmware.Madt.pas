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
  The ACPI Multiple APIC Description Table ("APIC").

  It lists the interrupt controllers: the processors' local APICs (one
  per processor, which is how the processors are found), the I/O APICs
  (where each one's registers are and which global system interrupts it
  serves) and the
  interrupt source overrides, which say where an ISA IRQ is really wired
  (on most PCs IRQ 0, the timer, arrives on global interrupt 2) and with
  what polarity and trigger mode.
}
unit Firmware.Madt;

{$mode objfpc}
{$pointermath on}

interface

uses
  Memory.Layout;

const
  MaximumIoApics = 8;
  MaximumListedProcessors = 64;

type
  TIoApicDescription = record
    Id: Byte;
    PhysicalAddress: TPhysicalAddress;
    { The first global system interrupt this I/O APIC serves. }
    GlobalInterruptBase: LongWord;
  end;

  TIsaInterruptRouting = record
    GlobalInterrupt: LongWord;
    ActiveLow: Boolean;
    LevelTriggered: Boolean;
  end;

{ Reads the table. Returns False if there is none. }
function ParseMadt: Boolean;
function IoApicCount: Integer;
function IoApicDescription(Index: Integer): TIoApicDescription;
{ Where ISA IRQ Irq arrives: the override if there is one, otherwise
  global interrupt Irq, active high and edge triggered. }
function RoutingOfIsaInterrupt(Irq: Byte): TIsaInterruptRouting;

{ The processors that can be started, by local APIC id (the boot
  processor among them). }
function ListedProcessorCount: Integer;
function ListedProcessorApicId(Index: Integer): LongWord;

implementation

uses
  Firmware.Acpi;

const
  EntryTypeLocalApic = 0;
  EntryTypeIoApic = 1;
  EntryTypeSourceOverride = 2;
  EntryTypeLocalX2Apic = 9;

  { Flags of a processor: enabled, or "online capable" (may be enabled). }
  ProcessorEnabled = 1;
  ProcessorOnlineCapable = 2;

  { Flags of an override: bits 0-1 polarity, bits 2-3 trigger mode. }
  PolarityMask = $03;
  PolarityActiveLow = $03;
  TriggerMask = $0C;
  TriggerLevel = $0C;

  MaximumOverrides = 16;

type
  TMadtHeader = packed record
    Header: TAcpiTableHeader;
    LocalApicAddress: LongWord;
    Flags: LongWord;
  end;
  PMadtHeader = ^TMadtHeader;

  TEntryHeader = packed record
    EntryType: Byte;
    Length: Byte;
  end;
  PEntryHeader = ^TEntryHeader;

  TLocalApicEntry = packed record
    Header: TEntryHeader;
    ProcessorUid: Byte;
    ApicId: Byte;
    Flags: LongWord;
  end;
  PLocalApicEntry = ^TLocalApicEntry;

  TLocalX2ApicEntry = packed record
    Header: TEntryHeader;
    Reserved: Word;
    ApicId: LongWord;
    Flags: LongWord;
    ProcessorUid: LongWord;
  end;
  PLocalX2ApicEntry = ^TLocalX2ApicEntry;

  TIoApicEntry = packed record
    Header: TEntryHeader;
    Id: Byte;
    Reserved: Byte;
    Address: LongWord;
    GlobalInterruptBase: LongWord;
  end;
  PIoApicEntry = ^TIoApicEntry;

  TSourceOverrideEntry = packed record
    Header: TEntryHeader;
    Bus: Byte;
    Source: Byte;
    GlobalInterrupt: LongWord;
    Flags: Word;
  end;
  PSourceOverrideEntry = ^TSourceOverrideEntry;

  TOverride = record
    Source: Byte;
    Routing: TIsaInterruptRouting;
  end;

var
  IoApics: array[0..MaximumIoApics - 1] of TIoApicDescription;
  IoApicTotal: Integer;
  Overrides: array[0..MaximumOverrides - 1] of TOverride;
  OverrideTotal: Integer;
  ProcessorApicIds: array[0..MaximumListedProcessors - 1] of LongWord;
  ProcessorTotal: Integer;

procedure AddProcessor(ApicId: LongWord; Flags: LongWord);
var
  Index: Integer;
begin
  if (Flags and (ProcessorEnabled or ProcessorOnlineCapable)) = 0 then
    Exit;
  { The same processor may be listed in both forms. }
  for Index := 0 to ProcessorTotal - 1 do
    if ProcessorApicIds[Index] = ApicId then
      Exit;
  if ProcessorTotal < MaximumListedProcessors then
  begin
    ProcessorApicIds[ProcessorTotal] := ApicId;
    Inc(ProcessorTotal);
  end;
end;

function ParseMadt: Boolean;
var
  Table: PMadtHeader;
  Position: PByte;
  TableEnd: PByte;
  Entry: PEntryHeader;
  IoApic: PIoApicEntry;
  SourceOverride: PSourceOverrideEntry;
begin
  IoApicTotal := 0;
  OverrideTotal := 0;
  ProcessorTotal := 0;
  Table := PMadtHeader(FindAcpiTable('APIC', 0));
  if Table = nil then
    Exit(False);

  Position := PByte(Table) + SizeOf(TMadtHeader);
  TableEnd := PByte(Table) + Table^.Header.Length;
  while Position + SizeOf(TEntryHeader) <= TableEnd do
  begin
    Entry := PEntryHeader(Position);
    if (Entry^.Length < SizeOf(TEntryHeader)) or (Position + Entry^.Length > TableEnd) then
      Break;
    case Entry^.EntryType of
      EntryTypeLocalApic:
        if Entry^.Length >= SizeOf(TLocalApicEntry) then
          AddProcessor(PLocalApicEntry(Entry)^.ApicId, PLocalApicEntry(Entry)^.Flags);
      EntryTypeLocalX2Apic:
        if Entry^.Length >= SizeOf(TLocalX2ApicEntry) then
          AddProcessor(PLocalX2ApicEntry(Entry)^.ApicId, PLocalX2ApicEntry(Entry)^.Flags);
      EntryTypeIoApic:
        if (Entry^.Length >= SizeOf(TIoApicEntry)) and (IoApicTotal < MaximumIoApics) then
        begin
          IoApic := PIoApicEntry(Entry);
          IoApics[IoApicTotal].Id := IoApic^.Id;
          IoApics[IoApicTotal].PhysicalAddress := IoApic^.Address;
          IoApics[IoApicTotal].GlobalInterruptBase := IoApic^.GlobalInterruptBase;
          Inc(IoApicTotal);
        end;
      EntryTypeSourceOverride:
        if (Entry^.Length >= SizeOf(TSourceOverrideEntry)) and (OverrideTotal < MaximumOverrides) then
        begin
          SourceOverride := PSourceOverrideEntry(Entry);
          Overrides[OverrideTotal].Source := SourceOverride^.Source;
          Overrides[OverrideTotal].Routing.GlobalInterrupt := SourceOverride^.GlobalInterrupt;
          Overrides[OverrideTotal].Routing.ActiveLow :=
            (SourceOverride^.Flags and PolarityMask) = PolarityActiveLow;
          Overrides[OverrideTotal].Routing.LevelTriggered :=
            (SourceOverride^.Flags and TriggerMask) = TriggerLevel;
          Inc(OverrideTotal);
        end;
    end;
    Position := Position + Entry^.Length;
  end;
  Result := IoApicTotal > 0;
end;

function IoApicCount: Integer;
begin
  Result := IoApicTotal;
end;

function IoApicDescription(Index: Integer): TIoApicDescription;
begin
  Result := IoApics[Index];
end;

function RoutingOfIsaInterrupt(Irq: Byte): TIsaInterruptRouting;
var
  Index: Integer;
begin
  for Index := 0 to OverrideTotal - 1 do
    if Overrides[Index].Source = Irq then
      Exit(Overrides[Index].Routing);
  Result.GlobalInterrupt := Irq;
  Result.ActiveLow := False;
  Result.LevelTriggered := False;
end;

function ListedProcessorCount: Integer;
begin
  Result := ProcessorTotal;
end;

function ListedProcessorApicId(Index: Integer): LongWord;
begin
  Result := ProcessorApicIds[Index];
end;

end.
