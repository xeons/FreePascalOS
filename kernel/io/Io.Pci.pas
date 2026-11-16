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
  PCI and PCI Express device enumeration.

  Configuration space is accessed through the memory mapped enhanced
  configuration mechanism (ECAM) described by the ACPI MCFG table. Every
  function has a 4 KiB configuration page at

    Base + (Bus - StartBus) * 1 MiB + Device * 32 KiB + Function * 4 KiB

  At startup every bus in the MCFG range is scanned one bus (1 MiB) at a
  time. Buses without devices are unmapped again; buses with devices stay
  mapped so drivers can reach their configuration space later.
}
unit Io.Pci;

{$mode objfpc}
{$pointermath on}

interface

const
  MaximumPciDevices = 256;

  PciClassMassStorage = $01;
  PciSubclassSata = $06;
  PciInterfaceAhci = $01;
  PciSubclassNvm = $08;
  PciClassBridge = $06;

  PciConfigurationVendorId = $00;
  PciConfigurationDeviceId = $02;
  PciConfigurationCommand = $04;
  PciConfigurationStatus = $06;
  PciConfigurationRevision = $08;
  PciConfigurationHeaderType = $0E;
  PciConfigurationBar0 = $10;
  PciConfigurationInterruptLine = $3C;

  PciCommandIoSpace = $0001;
  PciCommandMemorySpace = $0002;
  PciCommandBusMaster = $0004;
  PciCommandInterruptDisable = $0400;

  PciCapabilityMessageInterrupts = $05;
  PciCapabilityExpress = $10;
  PciCapabilityExtendedMessageInterrupts = $11;
  { In the PCI Express capability: link control, whose two low bits
    enable the active state power management link states (L0s, L1). }
  PciExpressLinkControl = $10;
  PciExpressLinkControlAspmMask = $0003;

type
  TPciDevice = record
    Segment: Word;
    Bus: Byte;
    Device: Byte;
    FunctionNumber: Byte;
    VendorId: Word;
    DeviceId: Word;
    ClassCode: Byte;
    Subclass: Byte;
    ProgrammingInterface: Byte;
    Revision: Byte;
    HeaderType: Byte;
    Configuration: PByte;
  end;
  PPciDevice = ^TPciDevice;

  TPciBar = record
    PhysicalAddress: QWord;
    SizeInBytes: QWord;
    IsIoPort: Boolean;
    Is64Bit: Boolean;
  end;

procedure InitializePci;

function PciDeviceCount: Integer;
function PciDeviceAt(Index: Integer): PPciDevice;

{ Finds the next device (starting at StartIndex) with the given class,
  subclass and programming interface. Returns its index or -1. }
{ The function at Segment, Bus, Device, FunctionNumber, or nil if there
  is none. }
function FindPciFunction(Segment: Word; Bus, Device, FunctionNumber: Byte): PPciDevice;
function FindPciDeviceByClass(ClassCode, Subclass, ProgrammingInterface: Byte;
  StartIndex: Integer): Integer;

function PciRead8(Device: PPciDevice; Offset: Word): Byte;
function PciRead16(Device: PPciDevice; Offset: Word): Word;
function PciRead32(Device: PPciDevice; Offset: Word): LongWord;
procedure PciWrite16(Device: PPciDevice; Offset: Word; Value: Word);
procedure PciWrite32(Device: PPciDevice; Offset: Word; Value: LongWord);

{ Decodes base address register BarIndex (0..5), including its size. }
function PciReadBar(Device: PPciDevice; BarIndex: Integer; out Bar: TPciBar): Boolean;

procedure PciEnableDevice(Device: PPciDevice; EnableBusMastering: Boolean);

{ The offset of capability CapabilityId (PciCapability*) in Device's
  configuration space, or 0 if it has none. }
function FindPciCapability(Device: PPciDevice; CapabilityId: Byte): Word;

procedure WritePciSummary;
{ Keeps every function's configuration space across suspend to RAM
  (waking resets the devices: their BARs, command register and
  capabilities are written back). }
procedure RegisterPciPowerHandler;

implementation

uses
  Io.PowerManagement,
  Memory.Layout,
  Memory.DeviceMapping,
  Firmware.Acpi,
  Debug.Output;

const
  BytesPerBus = QWord(1) shl 20;
  BytesPerDevice = QWord(1) shl 15;
  BytesPerFunction = QWord(1) shl 12;
  DevicesPerBus = 32;
  FunctionsPerDevice = 8;
  InvalidVendorId = $FFFF;
  HeaderTypeMultiFunction = $80;
  HeaderTypeMask = $7F;

  BarIoSpace = $1;
  BarTypeMask = $6;
  BarType64Bit = $4;

type
  TMcfgAllocation = packed record
    BaseAddress: QWord;
    Segment: Word;
    StartBus: Byte;
    EndBus: Byte;
    Reserved: LongWord;
  end;
  PMcfgAllocation = ^TMcfgAllocation;

var
  Devices: array[0..MaximumPciDevices - 1] of TPciDevice;
  DeviceCount: Integer;
  ConfigurationMechanismFound: Boolean;

function PciDeviceCount: Integer;
begin
  Result := DeviceCount;
end;

function PciDeviceAt(Index: Integer): PPciDevice;
begin
  Result := @Devices[Index];
end;

function PciRead8(Device: PPciDevice; Offset: Word): Byte;
begin
  Result := PByte(Device^.Configuration + Offset)^;
end;

function PciRead16(Device: PPciDevice; Offset: Word): Word;
begin
  Result := PWord(Device^.Configuration + Offset)^;
end;

function PciRead32(Device: PPciDevice; Offset: Word): LongWord;
begin
  Result := PLongWord(Device^.Configuration + Offset)^;
end;

procedure PciWrite16(Device: PPciDevice; Offset: Word; Value: Word);
begin
  PWord(Device^.Configuration + Offset)^ := Value;
end;

procedure PciWrite32(Device: PPciDevice; Offset: Word; Value: LongWord);
begin
  PLongWord(Device^.Configuration + Offset)^ := Value;
end;

procedure RecordFunction(Segment: Word; Bus, Device, FunctionNumber: Byte; Configuration: PByte);
var
  Entry: PPciDevice;
begin
  if DeviceCount >= MaximumPciDevices then
    Exit;

  Entry := @Devices[DeviceCount];
  Entry^.Segment := Segment;
  Entry^.Bus := Bus;
  Entry^.Device := Device;
  Entry^.FunctionNumber := FunctionNumber;
  Entry^.Configuration := Configuration;
  Entry^.VendorId := PWord(Configuration + PciConfigurationVendorId)^;
  Entry^.DeviceId := PWord(Configuration + PciConfigurationDeviceId)^;
  Entry^.Revision := Configuration[PciConfigurationRevision];
  Entry^.ProgrammingInterface := Configuration[PciConfigurationRevision + 1];
  Entry^.Subclass := Configuration[PciConfigurationRevision + 2];
  Entry^.ClassCode := Configuration[PciConfigurationRevision + 3];
  Entry^.HeaderType := Configuration[PciConfigurationHeaderType] and HeaderTypeMask;
  Inc(DeviceCount);
end;

{ Scans one bus. Returns True if any function was found (the mapping is
  then kept). }
function ScanBus(BusBase: PByte; Segment: Word; Bus: Byte): Boolean;
var
  Device: Integer;
  FunctionNumber: Integer;
  FunctionCount: Integer;
  Configuration: PByte;
begin
  Result := False;
  for Device := 0 to DevicesPerBus - 1 do
  begin
    Configuration := BusBase + QWord(Device) * BytesPerDevice;
    if PWord(Configuration)^ = InvalidVendorId then
      Continue;

    if (Configuration[PciConfigurationHeaderType] and HeaderTypeMultiFunction) <> 0 then
      FunctionCount := FunctionsPerDevice
    else
      FunctionCount := 1;

    for FunctionNumber := 0 to FunctionCount - 1 do
    begin
      Configuration := BusBase + QWord(Device) * BytesPerDevice +
        QWord(FunctionNumber) * BytesPerFunction;
      if PWord(Configuration)^ = InvalidVendorId then
        Continue;
      RecordFunction(Segment, Bus, Byte(Device), Byte(FunctionNumber), Configuration);
      Result := True;
    end;
  end;
end;

procedure ScanAllocation(Allocation: PMcfgAllocation);
var
  Bus: Integer;
  BusPhysical: QWord;
  BusBase: PByte;
begin
  for Bus := Allocation^.StartBus to Allocation^.EndBus do
  begin
    BusPhysical := Allocation^.BaseAddress + QWord(Bus - Allocation^.StartBus) * BytesPerBus;
    BusBase := PByte(MapDeviceMemory(BusPhysical, BytesPerBus));
    if BusBase = nil then
      Exit;
    if not ScanBus(BusBase, Allocation^.Segment, Byte(Bus)) then
      UnmapDeviceMemory(BusBase, BytesPerBus);
  end;
end;

procedure InitializePci;
const
  McfgReservedBytes = 8;
var
  Table: PAcpiTableHeader;
  Allocation: PMcfgAllocation;
  AllocationCount: LongWord;
  AllocationIndex: LongWord;
begin
  DeviceCount := 0;
  ConfigurationMechanismFound := False;

  Table := FindAcpiTable('MCFG', 0);
  if Table = nil then
    Exit;
  ConfigurationMechanismFound := True;

  AllocationCount := (Table^.Length - SizeOf(TAcpiTableHeader) - McfgReservedBytes) div
    SizeOf(TMcfgAllocation);
  Allocation := PMcfgAllocation(PByte(Table) + SizeOf(TAcpiTableHeader) + McfgReservedBytes);

  AllocationIndex := 0;
  while AllocationIndex < AllocationCount do
  begin
    ScanAllocation(Allocation);
    Inc(Allocation);
    Inc(AllocationIndex);
  end;
end;

function FindPciFunction(Segment: Word; Bus, Device, FunctionNumber: Byte): PPciDevice;
var
  Index: Integer;
begin
  for Index := 0 to DeviceCount - 1 do
  begin
    Result := @Devices[Index];
    if (Result^.Segment = Segment) and (Result^.Bus = Bus) and (Result^.Device = Device) and
       (Result^.FunctionNumber = FunctionNumber) then
      Exit;
  end;
  Result := nil;
end;

function FindPciDeviceByClass(ClassCode, Subclass, ProgrammingInterface: Byte;
  StartIndex: Integer): Integer;
var
  Index: Integer;
begin
  for Index := StartIndex to DeviceCount - 1 do
  begin
    if (Devices[Index].ClassCode = ClassCode) and (Devices[Index].Subclass = Subclass) and
       (Devices[Index].ProgrammingInterface = ProgrammingInterface) then
      Exit(Index);
  end;
  Result := -1;
end;

function PciReadBar(Device: PPciDevice; BarIndex: Integer; out Bar: TPciBar): Boolean;
var
  Offset: Word;
  OriginalLow: LongWord;
  OriginalHigh: LongWord;
  SizeLow: LongWord;
  SizeHigh: LongWord;
  OriginalCommand: Word;
  SizeMask: QWord;
begin
  Bar.PhysicalAddress := 0;
  Bar.SizeInBytes := 0;
  Bar.IsIoPort := False;
  Bar.Is64Bit := False;
  Result := False;
  if (BarIndex < 0) or (BarIndex > 5) or (Device^.HeaderType <> 0) then
    Exit;

  Offset := PciConfigurationBar0 + Word(BarIndex) * 4;
  OriginalLow := PciRead32(Device, Offset);
  Bar.IsIoPort := (OriginalLow and BarIoSpace) <> 0;
  Bar.Is64Bit := (not Bar.IsIoPort) and ((OriginalLow and BarTypeMask) = BarType64Bit);

  { Turn decoding off while the BAR temporarily holds all ones. }
  OriginalCommand := PciRead16(Device, PciConfigurationCommand);
  PciWrite16(Device, PciConfigurationCommand,
    OriginalCommand and not (PciCommandIoSpace or PciCommandMemorySpace));

  PciWrite32(Device, Offset, $FFFFFFFF);
  SizeLow := PciRead32(Device, Offset);
  PciWrite32(Device, Offset, OriginalLow);

  OriginalHigh := 0;
  SizeHigh := $FFFFFFFF;
  if Bar.Is64Bit then
  begin
    OriginalHigh := PciRead32(Device, Offset + 4);
    PciWrite32(Device, Offset + 4, $FFFFFFFF);
    SizeHigh := PciRead32(Device, Offset + 4);
    PciWrite32(Device, Offset + 4, OriginalHigh);
  end;

  PciWrite16(Device, PciConfigurationCommand, OriginalCommand);

  if Bar.IsIoPort then
  begin
    Bar.PhysicalAddress := OriginalLow and $FFFFFFFC;
    SizeMask := QWord($FFFF0000) or (SizeLow and $FFFFFFFC);
    SizeMask := SizeMask or QWord($FFFFFFFF00000000);
  end
  else
  begin
    Bar.PhysicalAddress := (QWord(OriginalHigh) shl 32) or (OriginalLow and $FFFFFFF0);
    SizeMask := (QWord(SizeHigh) shl 32) or (SizeLow and $FFFFFFF0);
  end;

  if SizeMask = 0 then
    Exit;
  Bar.SizeInBytes := (not SizeMask) + 1;
  Result := Bar.SizeInBytes <> 0;
end;

procedure PciEnableDevice(Device: PPciDevice; EnableBusMastering: Boolean);
var
  Command: Word;
begin
  Command := PciRead16(Device, PciConfigurationCommand);
  Command := Command or PciCommandMemorySpace or PciCommandIoSpace;
  if EnableBusMastering then
    Command := Command or PciCommandBusMaster;
  PciWrite16(Device, PciConfigurationCommand, Command);
end;

const
  PciConfigurationCapabilitiesPointer = $34;
  PciStatusHasCapabilities = $0010;
  MaximumCapabilities = 48;

function FindPciCapability(Device: PPciDevice; CapabilityId: Byte): Word;
var
  Offset: Word;
  Steps: Integer;
begin
  Result := 0;
  if (PciRead16(Device, PciConfigurationStatus) and PciStatusHasCapabilities) = 0 then
    Exit;
  Offset := PciRead8(Device, PciConfigurationCapabilitiesPointer) and $FC;
  Steps := 0;
  { The list is linked through the second byte of each entry; the step
    limit guards against a broken, circular list. }
  while (Offset <> 0) and (Steps < MaximumCapabilities) do
  begin
    if PciRead8(Device, Offset) = CapabilityId then
      Exit(Offset);
    Offset := PciRead8(Device, Offset + 1) and $FC;
    Inc(Steps);
  end;
end;

function ClassDescription(Device: PPciDevice): PChar;
begin
  case Device^.ClassCode of
    $00: Result := 'unclassified';
    $01:
      case Device^.Subclass of
        $01: Result := 'IDE controller';
        $06: Result := 'SATA controller';
        $08: Result := 'NVMe controller';
      else
        Result := 'storage controller';
      end;
    $02: Result := 'network controller';
    $03: Result := 'display controller';
    $04: Result := 'multimedia controller';
    $05: Result := 'memory controller';
    $06:
      case Device^.Subclass of
        $00: Result := 'host bridge';
        $01: Result := 'ISA bridge';
        $04: Result := 'PCI bridge';
      else
        Result := 'bridge';
      end;
    $0C:
      case Device^.Subclass of
        $03: Result := 'USB controller';
        $05: Result := 'SMBus controller';
      else
        Result := 'serial bus controller';
      end;
  else
    Result := 'other device';
  end;
end;

procedure WritePciSummary;
var
  Index: Integer;
  Device: PPciDevice;
begin
  DebugBeginMessage;
  if not ConfigurationMechanismFound then
  begin
    DebugWriteTag('pci');
    DebugWriteLine('No MCFG table, PCI devices are not available');
    DebugEndMessage;
    Exit;
  end;

  for Index := 0 to DeviceCount - 1 do
  begin
    Device := @Devices[Index];
    DebugWriteTag('pci');
    DebugWriteHex(Device^.Bus, 2);
    DebugWrite(':');
    DebugWriteHex(Device^.Device, 2);
    DebugWrite('.');
    DebugWriteHex(Device^.FunctionNumber, 1);
    DebugWrite(' ');
    DebugWriteHex(Device^.VendorId, 4);
    DebugWrite(':');
    DebugWriteHex(Device^.DeviceId, 4);
    DebugWrite(' ');
    DebugWriteLine(ClassDescription(Device));
  end;
  DebugEndMessage;
end;

{ --- Suspend to RAM ------------------------------------------------------ }

const
  { The standard header and the capabilities after it. }
  SavedConfigurationBytes = 256;
  CommandRegister = $04;

var
  SavedConfiguration: array[0..MaximumPciDevices - 1, 0..SavedConfigurationBytes div 4 - 1] of LongWord;

procedure SaveConfigurations(Context: Pointer);
var
  Index: Integer;
  Slot: Integer;
begin
  for Index := 0 to DeviceCount - 1 do
    for Slot := 0 to SavedConfigurationBytes div 4 - 1 do
      SavedConfiguration[Index, Slot] := PLongWord(Devices[Index].Configuration + Slot * 4)^;
end;

procedure RestoreConfigurations(Context: Pointer);
var
  Index: Integer;
  Slot: Integer;
begin
  for Index := 0 to DeviceCount - 1 do
  begin
    { Everything after the identification and command/status words
      (BARs, bus numbers of bridges, interrupt line, capabilities); then
      the command register, which turns decoding and bus mastering on. }
    for Slot := 3 to SavedConfigurationBytes div 4 - 1 do
      PLongWord(Devices[Index].Configuration + Slot * 4)^ := SavedConfiguration[Index, Slot];
    PWord(Devices[Index].Configuration + CommandRegister)^ := Word(SavedConfiguration[Index, 1]);
  end;
end;

procedure RegisterPciPowerHandler;
begin
  RegisterPowerHandler('PCI configuration', PowerStagePlatform, @SaveConfigurations, @RestoreConfigurations, nil);
end;

end.
