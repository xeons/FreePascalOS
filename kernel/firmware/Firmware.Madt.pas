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
  MaximumRedistributorRegions = 8;

type
  TIoApicDescription = record
    Id: Byte;
    PhysicalAddress: TPhysicalAddress;
    { The first global system interrupt this I/O APIC serves. }
    GlobalInterruptBase: LongWord;
  end;

  { A GICv3 redistributor region: Length bytes of redistributors one
    after the other from Base, or (Length 0) a single redistributor. }
  TRedistributorRegion = record
    Base: TPhysicalAddress;
    Length: QWord;
  end;

  TIsaInterruptRouting = record
    GlobalInterrupt: LongWord;
    ActiveLow: Boolean;
    LevelTriggered: Boolean;
  end;

  { The ARM generic interrupt controller (GIC) the MADT describes on
    AArch64 machines: its distributor, the CPU interface (GICv2, the
    same address for every processor: it is banked) and a GICv2m frame
    that turns PCIe message writes into SPIs, if there is one. Zero
    where absent. }
  TGicDescription = record
    Version: Byte;
    DistributorAddress: TPhysicalAddress;
    CpuInterfaceAddress: TPhysicalAddress;
    { GICv3: the first redistributor region's start (as a device tree
      gives it), every region (the MADT's GICR entries, else each
      processor's GICC redistributor address), and the first ITS. }
    RedistributorAddress: TPhysicalAddress;
    RedistributorRegionCount: LongWord;
    RedistributorRegions: array[0..MaximumRedistributorRegions - 1] of TRedistributorRegion;
    ItsAddress: TPhysicalAddress;
    MessageFrameAddress: TPhysicalAddress;
    MessageFrameFirstSpi: LongWord;
    MessageFrameSpiCount: LongWord;
  end;

{ Reads the table. Returns False if there is none, or it lists neither an
  I/O APIC nor a GIC distributor. Without ACPI tables the device tree of
  a native boot gives the GIC and the processors instead
  (Firmware.DeviceTreeMachine). }
function ParseMadt: Boolean;

function GicDescription: TGicDescription;
function IoApicCount: Integer;
function IoApicDescription(Index: Integer): TIoApicDescription;
{ Where ISA IRQ Irq arrives: the override if there is one, otherwise
  global interrupt Irq, active high and edge triggered. }
function RoutingOfIsaInterrupt(Irq: Byte): TIsaInterruptRouting;
{ True if the MADT has an interrupt source override for Irq. }
function IsaInterruptIsOverridden(Irq: Byte): Boolean;

{ The processors that can be started, by local APIC id (the boot
  processor among them). }
function ListedProcessorCount: Integer;
function ListedProcessorApicId(Index: Integer): LongWord;

implementation

uses
  Runtime.Memory,
  Firmware.Acpi,
  Firmware.DeviceTree,
  Firmware.DeviceTreeMachine;

const
  EntryTypeLocalApic = 0;
  EntryTypeIoApic = 1;
  EntryTypeSourceOverride = 2;
  EntryTypeLocalX2Apic = 9;
  EntryTypeGicCpuInterface = $0B;
  EntryTypeGicDistributor = $0C;
  EntryTypeGicMessageFrame = $0D;
  EntryTypeGicRedistributor = $0E;
  EntryTypeGicTranslationService = $0F;

  { A GIC CPU interface's flags: bit 0 enabled, bit 3 online capable. }
  GicProcessorOnlineCapable = 8;
  { MPIDR affinity Aff2.Aff1.Aff0, the processor's id. }
  AffinityMask = $FFFFFF;

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

  TGicCpuInterfaceEntry = packed record
    Header: TEntryHeader;
    Reserved: Word;
    CpuInterfaceNumber: LongWord;
    ProcessorUid: LongWord;
    Flags: LongWord;
    ParkingVersion: LongWord;
    PerformanceInterrupt: LongWord;
    ParkedAddress: QWord;
    PhysicalBaseAddress: QWord;
    VirtualInterfaceAddress: QWord;
    HypervisorInterfaceAddress: QWord;
    MaintenanceInterrupt: LongWord;
    RedistributorAddress: QWord;
    Affinity: QWord;
  end;
  PGicCpuInterfaceEntry = ^TGicCpuInterfaceEntry;

  TGicDistributorEntry = packed record
    Header: TEntryHeader;
    Reserved: Word;
    GicId: LongWord;
    PhysicalBaseAddress: QWord;
    SystemVectorBase: LongWord;
    Version: Byte;
  end;
  PGicDistributorEntry = ^TGicDistributorEntry;

  TGicMessageFrameEntry = packed record
    Header: TEntryHeader;
    Reserved: Word;
    FrameId: LongWord;
    PhysicalBaseAddress: QWord;
    Flags: LongWord;
    SpiCount: Word;
    SpiBase: Word;
  end;
  PGicMessageFrameEntry = ^TGicMessageFrameEntry;

  TGicRedistributorEntry = packed record
    Header: TEntryHeader;
    Reserved: Word;
    DiscoveryRangeBase: QWord;
    DiscoveryRangeLength: LongWord;
  end;
  PGicRedistributorEntry = ^TGicRedistributorEntry;

  TGicTranslationServiceEntry = packed record
    Header: TEntryHeader;
    Reserved: Word;
    TranslationServiceId: LongWord;
    PhysicalBaseAddress: QWord;
    Reserved2: LongWord;
  end;
  PGicTranslationServiceEntry = ^TGicTranslationServiceEntry;

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
  Gic: TGicDescription;
  { Redistributors named by GICC entries, used where no GICR entry
    describes the regions. }
  ProcessorRedistributors: array[0..MaximumRedistributorRegions - 1] of TPhysicalAddress;
  ProcessorRedistributorCount: Integer;

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

procedure AddRedistributorRegion(Base: TPhysicalAddress; Length: QWord);
begin
  if (Base = 0) or (Gic.RedistributorRegionCount >= MaximumRedistributorRegions) then
    Exit;
  Gic.RedistributorRegions[Gic.RedistributorRegionCount].Base := Base;
  Gic.RedistributorRegions[Gic.RedistributorRegionCount].Length := Length;
  Inc(Gic.RedistributorRegionCount);
  if Gic.RedistributorAddress = 0 then
    Gic.RedistributorAddress := Base;
end;

procedure AddGicCpuInterface(Entry: PGicCpuInterfaceEntry);
var
  Flags: LongWord;
begin
  Flags := Entry^.Flags and ProcessorEnabled;
  if (Entry^.Flags and GicProcessorOnlineCapable) <> 0 then
    Flags := Flags or ProcessorOnlineCapable;
  AddProcessor(LongWord(Entry^.Affinity and AffinityMask), Flags);
  if Gic.CpuInterfaceAddress = 0 then
    Gic.CpuInterfaceAddress := Entry^.PhysicalBaseAddress;
  if (Entry^.RedistributorAddress <> 0) and (ProcessorRedistributorCount < MaximumRedistributorRegions) then
  begin
    ProcessorRedistributors[ProcessorRedistributorCount] := Entry^.RedistributorAddress;
    Inc(ProcessorRedistributorCount);
  end;
end;

procedure AddGicTranslationService(Entry: PGicTranslationServiceEntry);
begin
  if Gic.ItsAddress = 0 then
    Gic.ItsAddress := Entry^.PhysicalBaseAddress;
end;

{ Without GICR entries each processor's redistributor is a region of
  its own. }
procedure UseProcessorRedistributors;
var
  Index: Integer;
begin
  if Gic.RedistributorRegionCount > 0 then
    Exit;
  for Index := 0 to ProcessorRedistributorCount - 1 do
    AddRedistributorRegion(ProcessorRedistributors[Index], 0);
end;

procedure AddGicDistributor(Entry: PGicDistributorEntry);
begin
  Gic.DistributorAddress := Entry^.PhysicalBaseAddress;
  Gic.Version := Entry^.Version;
end;

procedure AddGicMessageFrame(Entry: PGicMessageFrameEntry);
begin
  if Gic.MessageFrameAddress <> 0 then
    Exit;
  Gic.MessageFrameAddress := Entry^.PhysicalBaseAddress;
  Gic.MessageFrameFirstSpi := Entry^.SpiBase;
  Gic.MessageFrameSpiCount := Entry^.SpiCount;
end;

function DescribeFromDeviceTree: Boolean;
var
  Description: TDeviceTreeGic;
  Affinities: array[0..MaximumListedProcessors - 1] of LongWord;
  Count: Integer;
  Index: Integer;
begin
  Result := False;
  if not DeviceTreeIsAvailable or not DescribeDeviceTreeGic(Description) then
    Exit;
  Gic.Version := Description.Version;
  Gic.DistributorAddress := Description.DistributorAddress;
  Gic.CpuInterfaceAddress := Description.CpuInterfaceAddress;
  AddRedistributorRegion(Description.RedistributorAddress, Description.RedistributorSize);
  Gic.ItsAddress := Description.ItsAddress;
  Gic.MessageFrameAddress := Description.MessageFrameAddress;
  Gic.MessageFrameFirstSpi := Description.MessageFrameFirstSpi;
  Gic.MessageFrameSpiCount := Description.MessageFrameSpiCount;
  Count := ListDeviceTreeProcessors(Affinities);
  for Index := 0 to Count - 1 do
    AddProcessor(Affinities[Index], ProcessorEnabled);
  Result := True;
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
  ProcessorRedistributorCount := 0;
  ZeroMemory(@Gic, SizeOf(Gic));
  Table := PMadtHeader(FindAcpiTable('APIC', 0));
  if Table = nil then
    Exit(DescribeFromDeviceTree);

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
      EntryTypeGicCpuInterface:
        if Entry^.Length >= SizeOf(TGicCpuInterfaceEntry) then
          AddGicCpuInterface(PGicCpuInterfaceEntry(Entry));
      EntryTypeGicDistributor:
        if Entry^.Length >= SizeOf(TGicDistributorEntry) then
          AddGicDistributor(PGicDistributorEntry(Entry));
      EntryTypeGicMessageFrame:
        if Entry^.Length >= SizeOf(TGicMessageFrameEntry) then
          AddGicMessageFrame(PGicMessageFrameEntry(Entry));
      EntryTypeGicRedistributor:
        if Entry^.Length >= SizeOf(TGicRedistributorEntry) then
          AddRedistributorRegion(PGicRedistributorEntry(Entry)^.DiscoveryRangeBase,
            PGicRedistributorEntry(Entry)^.DiscoveryRangeLength);
      EntryTypeGicTranslationService:
        if Entry^.Length >= SizeOf(TGicTranslationServiceEntry) then
          AddGicTranslationService(PGicTranslationServiceEntry(Entry));
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
  UseProcessorRedistributors;
  Result := (IoApicTotal > 0) or (Gic.DistributorAddress <> 0);
end;

function GicDescription: TGicDescription;
begin
  Result := Gic;
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

function IsaInterruptIsOverridden(Irq: Byte): Boolean;
var
  Index: Integer;
begin
  for Index := 0 to OverrideTotal - 1 do
    if Overrides[Index].Source = Irq then
      Exit(True);
  Result := False;
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
