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
  The platform devices of a device tree (Io.PlatformDevices), what
  Io.AcpiDevices makes of the ACPI namespace: every enabled node with a
  "compatible", depth first, the subtrees of disabled nodes left out, as
  are /chosen, /aliases, /cpus, /memory and /reserved-memory (the HAL
  reads those itself).

  - Ids: the compatible strings, the first as the hardware id ("arm,pl011",
    "brcm,bcm2712-pcie", "pci-host-ecam-generic").
  - Memory: each "reg" entry translated to the processor's address
    (entries that cannot be, such as those of devices below a PCI
    function, are left out: their driver finds them through the BAR).
  - Interrupts: each one that resolves to the GIC, as its INTID (the
    global system interrupt ConnectPlatformInterrupt takes); interrupts
    of other controllers (RP1's own) are left to their drivers.
  - DMA: "dma-coherent" on the node or above it (without it a device
    does not snoop, as the architecture's default says), the nearest
    "dma-ranges" as windows, then the noncoherentdma option.
  - Segment: "linux,pci-domain" of a PCI host bridge.
}
unit Io.DeviceTreeDevices;

{$mode objfpc}

interface

{ Records the device tree's devices; returns how many there are now. }
function EnumerateDeviceTreeDevices: Integer;

implementation

uses
  Runtime.Memory,
  Runtime.Text,
  DeviceTree.Blob,
  DeviceTree.Addresses,
  Firmware.AcpiResourceList,
  Firmware.DeviceTree,
  Firmware.DeviceTreeInterrupts,
  Io.Dma,
  Io.PlatformDevices;

const
  MaximumDepth = 16;
  DeviceStatusWorking = DeviceStatusPresent or DeviceStatusFunctioning;

var
  Tree: PDeviceTree;
  NextUniqueId: QWord;

function IsSkippedTopLevelNode(Node: LongInt): Boolean;
var
  Name: PChar;
begin
  Name := NodeName(Tree^, Node);
  Result := DeviceTreeTextIsEqual(Name, 'chosen') or DeviceTreeTextIsEqual(Name, 'aliases') or
    DeviceTreeTextIsEqual(Name, 'cpus') or DeviceTreeTextIsEqual(Name, 'reserved-memory') or
    NodeHasDeviceType(Tree^, Node, 'memory');
end;

{ Path := Parent + '/' + Name, cut to the room there is. }
procedure AppendPath(var Path: array of Char; Parent: PChar; Name: PChar);
var
  Capacity: PtrUInt;
  Used: PtrUInt;
begin
  Capacity := PtrUInt(High(Path)) + 1;
  CopyText(@Path[0], Parent, Capacity);
  Used := TextLength(@Path[0]);
  if ((Used = 0) or (Path[Used - 1] <> '/')) and (Used + 2 < Capacity) then
  begin
    Path[Used] := '/';
    Path[Used + 1] := #0;
    Inc(Used);
  end;
  if Used + 1 < Capacity then
    CopyText(@Path[Used], Name, Capacity - Used);
end;

procedure DescribeIds(Node: LongInt; var Device: TPlatformDevice);
var
  Prop: TDeviceTreeProperty;
  Index: LongWord;
  Item: PChar;
begin
  if not FindProperty(Tree^, Node, 'compatible', Prop) or (PropertyString(Prop, 0) = nil) then
    Exit;
  CopyText(@Device.HardwareId[0], PropertyString(Prop, 0), PlatformIdLength);
  Index := 1;
  Item := PropertyString(Prop, Index);
  while (Item <> nil) and (Device.CompatibleIdCount < MaximumCompatibleIds) do
  begin
    CopyText(@Device.CompatibleIds[Device.CompatibleIdCount][0], Item, PlatformIdLength);
    Inc(Device.CompatibleIdCount);
    Inc(Index);
    Item := PropertyString(Prop, Index);
  end;
end;

procedure DescribeMemory(Node: LongInt; var Resources: TAcpiResourceList);
var
  Count: LongWord;
  Index: LongWord;
  Physical: QWord;
  Size: QWord;
  Address: TDeviceTreeAddress;
begin
  Count := RegisterCount(Tree^, Node);
  Index := 0;
  while (Index < Count) and (Resources.MemoryCount < MaximumResourceRanges) do
  begin
    if NodeRegisterPhysical(Tree^, Node, Index, Physical, Size) and (Size > 0) then
    begin
      ReadRegister(Tree^, Node, Index, Address, Size);
      Resources.Memory[Resources.MemoryCount].Start := Physical;
      Resources.Memory[Resources.MemoryCount].Length := Size;
      Resources.Memory[Resources.MemoryCount].BusStart := AddressValue(Address);
      Resources.Memory[Resources.MemoryCount].IsProducer := False;
      Inc(Resources.MemoryCount);
    end;
    Inc(Index);
  end;
end;

procedure DescribeInterrupts(Node: LongInt; var Resources: TAcpiResourceList);
var
  Count: LongWord;
  Index: LongWord;
  Gic: TGicInterrupt;
begin
  Count := NodeInterruptCount(Tree^, Node);
  Index := 0;
  while (Index < Count) and (Resources.InterruptCount < MaximumResourceInterrupts) do
  begin
    if NodeGicInterrupt(Tree^, Node, Index, Gic) then
    begin
      Resources.Interrupts[Resources.InterruptCount].Number := Gic.Intid;
      Resources.Interrupts[Resources.InterruptCount].LevelTriggered := Gic.LevelTriggered;
      Resources.Interrupts[Resources.InterruptCount].ActiveLow := Gic.ActiveLow;
      Resources.Interrupts[Resources.InterruptCount].Shared := Gic.LevelTriggered;
      Resources.Interrupts[Resources.InterruptCount].IsIsaIrq := False;
      Inc(Resources.InterruptCount);
    end;
    Inc(Index);
  end;
end;

procedure DescribeDma(Node: LongInt; var Device: TPlatformDevice);
var
  Bus: LongInt;
  Index: LongWord;
  BusStart: QWord;
  PhysicalStart: QWord;
  Size: QWord;
begin
  SetDefaultDmaAttributes(Device.Dma);
  Device.Dma.Coherent := NodeIsDmaCoherent(Tree^, Node);
  Device.HasCoherencyObject := True;
  Bus := FindDmaRangesBus(Tree^, Node);
  if Bus <> NoNode then
  begin
    Index := 0;
    while (Device.Dma.WindowCount < MaximumDmaWindows) and
          ReadDmaRange(Tree^, Bus, Index, BusStart, PhysicalStart, Size) do
    begin
      if Size > 0 then
      begin
        Device.Dma.Windows[Device.Dma.WindowCount].PhysicalStart := PhysicalStart;
        Device.Dma.Windows[Device.Dma.WindowCount].BusStart := BusStart;
        Device.Dma.Windows[Device.Dma.WindowCount].Length := Size;
        Inc(Device.Dma.WindowCount);
        Device.HasDmaObject := True;
      end;
      Inc(Index);
    end;
  end;
  ApplyDmaOptions(Device.Dma);
end;

procedure RecordNode(Node: LongInt; Path: PChar);
var
  Device: TPlatformDevice;
  Domain: LongWord;
begin
  ZeroMemory(@Device, SizeOf(Device));
  Device.Node := nil;
  Device.DeviceTreeNode := Node;
  CopyText(@Device.Path[0], Path, PlatformPathLength);
  DescribeIds(Node, Device);
  Device.UniqueId := NextUniqueId;
  Inc(NextUniqueId);
  Device.Status := DeviceStatusWorking;
  DescribeMemory(Node, Device.Resources);
  DescribeInterrupts(Node, Device.Resources);
  DescribeDma(Node, Device);
  if ReadCellProperty(Tree^, Node, 'linux,pci-domain', Domain) then
    Device.Segment := Word(Domain);
  AddPlatformDevice(Device);
end;

procedure VisitChildren(Parent: LongInt; ParentPath: PChar; Depth: Integer);
var
  Node: LongInt;
  Path: array[0..PlatformPathLength - 1] of Char;
begin
  if Depth > MaximumDepth then
    Exit;
  Node := FirstChildNode(Tree^, Parent);
  while Node <> NoNode do
  begin
    if NodeIsEnabled(Tree^, Node) and not ((Depth = 1) and IsSkippedTopLevelNode(Node)) then
    begin
      AppendPath(Path, ParentPath, NodeName(Tree^, Node));
      if NodeHasProperty(Tree^, Node, 'compatible') then
        RecordNode(Node, @Path[0]);
      VisitChildren(Node, @Path[0], Depth + 1);
    end;
    Node := NextSiblingNode(Tree^, Node);
  end;
end;

function EnumerateDeviceTreeDevices: Integer;
begin
  Tree := SystemDeviceTree;
  NextUniqueId := 0;
  if DeviceTreeIsAvailable then
    VisitChildren(RootNode(Tree^), '/', 1);
  Result := PlatformDeviceCount;
end;

end.
