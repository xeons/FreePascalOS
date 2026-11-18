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
  Platform devices: the devices the ACPI namespace describes that are
  not found by enumerating a bus (on a Raspberry Pi 4: the SD card
  controllers, the Ethernet controller, the VideoCore mailbox, the xHCI
  controller the firmware set up behind its PCIe bridge).

  After a native boot the device tree describes them instead:
  Io.DeviceTreeDevices adds each enabled node with a "compatible" (its
  strings are the ids, the first the hardware id), its "reg" translated
  to physical memory ranges, its interrupts that end at the GIC (as
  global system interrupts: INTIDs), "dma-coherent" and "dma-ranges" as
  the DMA attributes, and the node itself (DeviceTreeNode) for the rest
  of its properties (Io.PlatformProperties reads both kinds).

  Io.AcpiDevices fills the list while the namespace loads: each present
  device with a hardware id (_HID), its compatible ids (_CID), unique id
  (_UID), status (_STA), resources (_CRS: memory, I/O ports,
  interrupts), DMA attributes (_CCA: coherent or not, inherited from the
  nearest device above that says; _DMA: the windows its DMA goes
  through, likewise) and properties (_DSD).

  Drivers bind by id: a driver gives a table of ids and a probe routine
  (TPlatformDriver), and BindPlatformDriver offers it every device not
  yet taken whose hardware id or one of whose compatible ids is in the
  table. Each driver binds from its own start routine, so the order
  drivers start in (and the names their devices get) stays the one
  Io.Startup gives.
}
unit Io.PlatformDevices;

{$mode objfpc}
{$pointermath on}

interface

uses
  Kernel.Interrupts,
  Firmware.AmlValues,
  Firmware.AcpiResourceList,
  Firmware.AcpiDeviceWalk,
  Io.Pci,
  Io.Dma;

const
  { Long enough for device tree compatible strings
    ("raspberrypi,rp1-dwc3"). }
  PlatformIdLength = 48;
  MaximumCompatibleIds = AcpiMaximumCompatibleIds;
  PlatformPathLength = AcpiPathLength;
  MaximumPlatformDevices = 512;
  NoDeviceTreeNode = -1;

  { _STA bits. }
  DeviceStatusPresent = AcpiStatusPresent;
  DeviceStatusFunctioning = AcpiStatusFunctioning;

type
  TPlatformId = array[0..PlatformIdLength - 1] of Char;

  PPlatformDevice = ^TPlatformDevice;

  { Connects interrupt Index of Device (its number in Device's resources
    is the controller's own) to Handler: for devices whose interrupts go
    through a controller of their own rather than straight to the
    interrupt routing (RP1's peripherals). }
  TPlatformInterruptConnect = function(Controller: Pointer; Device: PPlatformDevice; Index: Integer;
    Handler: TInterruptHandler; Context: Pointer): Boolean;

  TPlatformDevice = record
    { The namespace node (PAmlNode), nil for a device tree's device. }
    Node: Pointer;
    { The device tree node (DeviceTree.Blob), NoDeviceTreeNode for an
      ACPI device. }
    DeviceTreeNode: LongInt;
    { "\_SB_.GDV0.SDC3", or the device tree path "/soc/serial@7d001000" }
    Path: array[0..PlatformPathLength - 1] of Char;
    HardwareId: TPlatformId;
    CompatibleIdCount: Integer;
    CompatibleIds: array[0..MaximumCompatibleIds - 1] of TPlatformId;
    UniqueId: QWord;
    Status: LongWord;
    Resources: TAcpiResourceList;
    Dma: TDmaAttributes;
    { Coherency and DMA windows came from the namespace (_CCA, _DMA), not
      from the defaults. }
    HasCoherencyObject: Boolean;
    HasDmaObject: Boolean;
    { What _DSD returned (AmlNone if nothing); kept for the drivers. }
    Properties: TAmlValue;
    { PCI root bridges: their segment (_SEG, linux,pci-domain). }
    Segment: Word;
    { The driver that took it, or nil. }
    DriverName: PChar;
    { nil: the interrupts are global system interrupts. Otherwise they
      are numbered by another controller, which connects them. }
    InterruptConnect: TPlatformInterruptConnect;
    InterruptController: Pointer;
  end;

  { Returns True if it took the device. }
  TPlatformProbe = function(Device: PPlatformDevice): Boolean;

  TPlatformDriver = record
    Name: PChar;
    { The ids it drives, ending with nil. }
    Ids: PPChar;
    Probe: TPlatformProbe;
  end;

{ For Io.AcpiDevices: adds a device (copied). False if the list is full. }
function AddPlatformDevice(constref Device: TPlatformDevice): Boolean;

function PlatformDeviceCount: Integer;
function PlatformDeviceAt(Index: Integer): PPlatformDevice;
{ True if the device's hardware id or a compatible id is Id. }
function PlatformDeviceHasId(Device: PPlatformDevice; Id: PChar): Boolean;
{ The next device (from StartIndex) with Id, or -1. }
function FindPlatformDevice(Id: PChar; StartIndex: Integer): Integer;

{ Offers the driver every free, present and working device that has
  one of its ids; returns how many it took. }
function BindPlatformDriver(constref Driver: TPlatformDriver): Integer;

{ Memory range Index of the device's _CRS. }
function PlatformMemoryRange(Device: PPlatformDevice; Index: Integer; out Start, Length: QWord): Boolean;
{ Maps memory range Index (device memory, uncached); nil if there is no
  such range or it could not be mapped. }
function MapPlatformMemory(Device: PPlatformDevice; Index: Integer; out Length: QWord): Pointer;
{ Connects interrupt Index of the device's _CRS. }
function ConnectPlatformInterrupt(Device: PPlatformDevice; Index: Integer; Handler: TInterruptHandler;
  Context: Pointer): Boolean;
{ The interrupt's number (for the start-up lines), or -1 if none. }
function PlatformInterruptNumber(Device: PPlatformDevice; Index: Integer): Int64;

{ The DMA attributes of a PCI device: those of the ACPI root bridge of
  its segment (_CCA, _DMA), else the architecture's defaults. }
procedure GetPciDmaAttributes(Pci: PPciDevice; out Attributes: TDmaAttributes);

{ Every platform device: its path, ids, resources, DMA and driver (the
  kernel debug shell's "devices"). }
procedure WritePlatformDeviceSummary;

implementation

uses
  Runtime.Memory,
  Runtime.Text,
  Memory.KernelHeap,
  Memory.DeviceMapping,
  Io.InterruptRouting,
  Debug.Output;

var
  Devices: array[0..MaximumPlatformDevices - 1] of PPlatformDevice;
  DeviceCount: Integer;

function AddPlatformDevice(constref Device: TPlatformDevice): Boolean;
var
  Copy: PPlatformDevice;
begin
  Result := False;
  if DeviceCount >= MaximumPlatformDevices then
    Exit;
  Copy := PPlatformDevice(AllocateZeroedKernelMemory(SizeOf(TPlatformDevice)));
  if Copy = nil then
    Exit;
  Copy^ := Device;
  Devices[DeviceCount] := Copy;
  Inc(DeviceCount);
  Result := True;
end;

function PlatformDeviceCount: Integer;
begin
  Result := DeviceCount;
end;

function PlatformDeviceAt(Index: Integer): PPlatformDevice;
begin
  if (Index < 0) or (Index >= DeviceCount) then
    Exit(nil);
  Result := Devices[Index];
end;

function UpperCase(Character: Char): Char;
begin
  if (Character >= 'a') and (Character <= 'z') then
    Result := Char(Ord(Character) - 32)
  else
    Result := Character;
end;

{ Ids compare without regard to case ("BCM2849" and "bcm2849"). }
function IdIsEqual(First, Second: PChar): Boolean;
var
  Index: Integer;
begin
  Index := 0;
  while (First[Index] <> #0) and (Second[Index] <> #0) do
  begin
    if UpperCase(First[Index]) <> UpperCase(Second[Index]) then
      Exit(False);
    Inc(Index);
  end;
  Result := First[Index] = Second[Index];
end;

function PlatformDeviceHasId(Device: PPlatformDevice; Id: PChar): Boolean;
var
  Index: Integer;
begin
  if IdIsEqual(@Device^.HardwareId[0], Id) then
    Exit(True);
  for Index := 0 to Device^.CompatibleIdCount - 1 do
    if IdIsEqual(@Device^.CompatibleIds[Index][0], Id) then
      Exit(True);
  Result := False;
end;

function FindPlatformDevice(Id: PChar; StartIndex: Integer): Integer;
var
  Index: Integer;
begin
  if StartIndex < 0 then
    StartIndex := 0;
  for Index := StartIndex to DeviceCount - 1 do
    if PlatformDeviceHasId(Devices[Index], Id) then
      Exit(Index);
  Result := -1;
end;

function DeviceMatchesDriver(Device: PPlatformDevice; constref Driver: TPlatformDriver): Boolean;
var
  Id: PPChar;
begin
  Id := Driver.Ids;
  while (Id <> nil) and (Id^ <> nil) do
  begin
    if PlatformDeviceHasId(Device, Id^) then
      Exit(True);
    Inc(Id);
  end;
  Result := False;
end;

function DeviceIsUsable(Device: PPlatformDevice): Boolean;
begin
  Result := ((Device^.Status and DeviceStatusPresent) <> 0) and
    ((Device^.Status and DeviceStatusFunctioning) <> 0);
end;

function BindPlatformDriver(constref Driver: TPlatformDriver): Integer;
var
  Index: Integer;
  Device: PPlatformDevice;
begin
  Result := 0;
  for Index := 0 to DeviceCount - 1 do
  begin
    Device := Devices[Index];
    if (Device^.DriverName <> nil) or not DeviceIsUsable(Device) or
       not DeviceMatchesDriver(Device, Driver) then
      Continue;
    if Driver.Probe(Device) then
    begin
      Device^.DriverName := Driver.Name;
      Inc(Result);
    end;
  end;
end;

function PlatformMemoryRange(Device: PPlatformDevice; Index: Integer; out Start, Length: QWord): Boolean;
begin
  Start := 0;
  Length := 0;
  if (Index < 0) or (Index >= Device^.Resources.MemoryCount) then
    Exit(False);
  Start := Device^.Resources.Memory[Index].Start;
  Length := Device^.Resources.Memory[Index].Length;
  Result := True;
end;

function MapPlatformMemory(Device: PPlatformDevice; Index: Integer; out Length: QWord): Pointer;
var
  Start: QWord;
begin
  Result := nil;
  if not PlatformMemoryRange(Device, Index, Start, Length) then
    Exit;
  Result := MapDeviceMemory(Start, Length);
end;

function ConnectPlatformInterrupt(Device: PPlatformDevice; Index: Integer; Handler: TInterruptHandler;
  Context: Pointer): Boolean;
var
  Interrupt: TAcpiInterrupt;
begin
  if (Index < 0) or (Index >= Device^.Resources.InterruptCount) then
    Exit(False);
  if Assigned(Device^.InterruptConnect) then
    Exit(Device^.InterruptConnect(Device^.InterruptController, Device, Index, Handler, Context));
  Interrupt := Device^.Resources.Interrupts[Index];
  if Interrupt.IsIsaIrq then
    Result := ConnectGlobalInterrupt(GlobalInterruptOfIsaIrq(Byte(Interrupt.Number)), Interrupt.LevelTriggered,
      Interrupt.ActiveLow, Handler, Context)
  else
    Result := ConnectGlobalInterrupt(Interrupt.Number, Interrupt.LevelTriggered, Interrupt.ActiveLow,
      Handler, Context);
end;

function PlatformInterruptNumber(Device: PPlatformDevice; Index: Integer): Int64;
begin
  if (Index < 0) or (Index >= Device^.Resources.InterruptCount) then
    Exit(-1);
  Result := Device^.Resources.Interrupts[Index].Number;
end;

procedure GetPciDmaAttributes(Pci: PPciDevice; out Attributes: TDmaAttributes);
var
  Index: Integer;
  Device: PPlatformDevice;
begin
  for Index := 0 to DeviceCount - 1 do
  begin
    Device := Devices[Index];
    if (PlatformDeviceHasId(Device, 'PNP0A08') or PlatformDeviceHasId(Device, 'PNP0A03') or
        PlatformDeviceHasId(Device, 'pci-host-ecam-generic')) and
       (Device^.Segment = Pci^.Segment) then
    begin
      Attributes := Device^.Dma;
      Exit;
    end;
  end;
  SetDefaultDmaAttributes(Attributes);
end;

{ --- The summary --------------------------------------------------------------- }

procedure WriteResources(Device: PPlatformDevice);
var
  Index: Integer;
begin
  for Index := 0 to Device^.Resources.MemoryCount - 1 do
  begin
    DebugWrite(' mem ');
    DebugWriteHex(Device^.Resources.Memory[Index].Start, 1);
    DebugWrite('+');
    DebugWriteHex(Device^.Resources.Memory[Index].Length, 1);
  end;
  for Index := 0 to Device^.Resources.IoCount - 1 do
  begin
    DebugWrite(' io ');
    DebugWriteHex(Device^.Resources.Io[Index].Start, 1);
    DebugWrite('+');
    DebugWriteHex(Device^.Resources.Io[Index].Length, 1);
  end;
  for Index := 0 to Device^.Resources.InterruptCount - 1 do
  begin
    if Assigned(Device^.InterruptConnect) then
      DebugWrite(' line ')
    else if Device^.Resources.Interrupts[Index].IsIsaIrq then
      DebugWrite(' irq ')
    else
      DebugWrite(' gsi ');
    DebugWriteDecimal(Device^.Resources.Interrupts[Index].Number);
    if Device^.Resources.Interrupts[Index].LevelTriggered then
      DebugWrite(' level')
    else
      DebugWrite(' edge');
  end;
end;

procedure WriteDma(Device: PPlatformDevice);
var
  Index: Integer;
begin
  if Device^.HasCoherencyObject then
  begin
    if Device^.Dma.Coherent then
      DebugWrite(', coherent')
    else
      DebugWrite(', not coherent');
  end;
  for Index := 0 to Device^.Dma.WindowCount - 1 do
  begin
    DebugWrite(', dma ');
    DebugWriteHex(Device^.Dma.Windows[Index].PhysicalStart, 1);
    DebugWrite('+');
    DebugWriteHex(Device^.Dma.Windows[Index].Length, 1);
    DebugWrite(' at bus ');
    DebugWriteHex(Device^.Dma.Windows[Index].BusStart, 1);
  end;
end;

procedure WritePlatformDeviceSummary;
var
  Index: Integer;
  IdIndex: Integer;
  Device: PPlatformDevice;
begin
  DebugBeginMessage;
  if DeviceCount = 0 then
  begin
    DebugWriteTag('devices');
    DebugWriteLine('no platform devices');
  end;
  for Index := 0 to DeviceCount - 1 do
  begin
    Device := Devices[Index];
    if Device^.DeviceTreeNode = NoDeviceTreeNode then
      DebugWriteTag('acpi')
    else
      DebugWriteTag('dt');
    DebugWrite(@Device^.Path[0]);
    DebugWrite(' ');
    DebugWrite(@Device^.HardwareId[0]);
    for IdIndex := 0 to Device^.CompatibleIdCount - 1 do
    begin
      DebugWrite(' / ');
      DebugWrite(@Device^.CompatibleIds[IdIndex][0]);
    end;
    if not DeviceIsUsable(Device) then
      DebugWrite(' (absent)');
    WriteResources(Device);
    WriteDma(Device);
    if Device^.DriverName <> nil then
    begin
      DebugWrite(': ');
      DebugWrite(Device^.DriverName);
    end;
    DebugWriteLine('');
  end;
  DebugEndMessage;
end;

end.
