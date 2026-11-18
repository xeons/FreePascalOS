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
  PCI host bridges of a device tree with ECAM configuration space
  ("pci-host-ecam-generic": QEMU's virt machine), what ACPI's MCFG and
  the root bridge's _CRS and _PRT say otherwise:

  - "reg": the ECAM area, for the buses of "bus-range" (0-255 if not
    given); the segment is "linux,pci-domain" (else the host's place in
    the tree's order);
  - "ranges": the windows the host forwards (PCI address with its space
    code, the processor's address, the size): I/O, 32-bit and 64-bit
    memory, where nobody assigned BARs yet (no firmware did: Io.Pci
    assigns them from these);
  - "interrupt-map": where each slot's INTA-INTD goes (the child unit
    address is bus, device and function in phys.hi, the specifier the
    pin 1-4);
  - "dma-coherent".

  A Raspberry Pi 5's PCIe (brcm,bcm2712-pcie) is not ECAM and needs a
  driver of its own; its nodes read the same way (DeviceTree.Addresses
  translates their three-cell addresses).

  Plain Pascal, built by the host test.
}
unit Firmware.DeviceTreePci;

{$mode objfpc}

interface

uses
  Firmware.DeviceTreeInterrupts;

const
  MaximumPciHostWindows = 8;
  MaximumDeviceTreePciHosts = 8;

type
  TPciHostWindow = record
    { DeviceTree.Addresses' PciSpace*. }
    Space: LongWord;
    Prefetchable: Boolean;
    BusAddress: QWord;
    PhysicalAddress: QWord;
    Size: QWord;
  end;

  TDeviceTreePciHost = record
    Node: LongInt;
    Segment: Word;
    StartBus: Byte;
    EndBus: Byte;
    { The ECAM area's start: bus StartBus's configuration space. }
    ConfigurationBase: QWord;
    Coherent: Boolean;
    WindowCount: Integer;
    Windows: array[0..MaximumPciHostWindows - 1] of TPciHostWindow;
  end;

function DeviceTreePciHostCount: Integer;
function GetDeviceTreePciHost(Index: Integer; out Host: TDeviceTreePciHost): Boolean;
{ Where line Pin (0 for INTA .. 3 for INTD) of Device on the host's root
  bus (Bus) arrives. }
function FindDeviceTreePciRoute(Segment: Word; Bus, Device, Pin: Byte; out Gic: TGicInterrupt): Boolean;

implementation

uses
  DeviceTree.Blob,
  DeviceTree.Addresses,
  Firmware.DeviceTree;

const
  EcamCompatible = 'pci-host-ecam-generic';
  PrefetchableBit = $40000000;

function FindHostNode(Index: Integer): LongInt;
var
  Seen: Integer;
begin
  Seen := 0;
  Result := FindCompatibleNode(SystemDeviceTree^, NoNode, EcamCompatible);
  while (Result <> NoNode) and (Seen < Index) do
  begin
    Inc(Seen);
    Result := FindCompatibleNode(SystemDeviceTree^, Result, EcamCompatible);
  end;
end;

function DeviceTreePciHostCount: Integer;
begin
  Result := 0;
  while (Result < MaximumDeviceTreePciHosts) and (FindHostNode(Result) <> NoNode) do
    Inc(Result);
end;

procedure ReadWindows(Node: LongInt; var Host: TDeviceTreePciHost);
var
  Index: LongWord;
  ChildAddress: TDeviceTreeAddress;
  Physical: QWord;
  Size: QWord;
  Window: ^TPciHostWindow;
begin
  Host.WindowCount := 0;
  Index := 0;
  while (Host.WindowCount < MaximumPciHostWindows) and
        ReadRangeEntry(SystemDeviceTree^, Node, Index, ChildAddress, Physical, Size) do
  begin
    if ChildAddress.CellCount = 3 then
    begin
      Window := @Host.Windows[Host.WindowCount];
      Window^.Space := PciAddressSpace(ChildAddress);
      Window^.Prefetchable := (ChildAddress.Cells[0] and PrefetchableBit) <> 0;
      Window^.BusAddress := AddressValue(ChildAddress);
      Window^.PhysicalAddress := Physical;
      Window^.Size := Size;
      Inc(Host.WindowCount);
    end;
    Inc(Index);
  end;
end;

function GetDeviceTreePciHost(Index: Integer; out Host: TDeviceTreePciHost): Boolean;
var
  Tree: PDeviceTree;
  Prop: TDeviceTreeProperty;
  Domain: LongWord;
  Size: QWord;
begin
  Tree := SystemDeviceTree;
  Host.Node := FindHostNode(Index);
  Host.Segment := Word(Index);
  Host.StartBus := 0;
  Host.EndBus := 255;
  Host.ConfigurationBase := 0;
  Host.Coherent := False;
  Host.WindowCount := 0;
  Result := False;
  if (Host.Node = NoNode) or not NodeRegisterPhysical(Tree^, Host.Node, 0, Host.ConfigurationBase, Size) then
    Exit;
  if ReadCellProperty(Tree^, Host.Node, 'linux,pci-domain', Domain) then
    Host.Segment := Word(Domain);
  if FindProperty(Tree^, Host.Node, 'bus-range', Prop) and (PropertyCellCount(Prop) >= 2) then
  begin
    Host.StartBus := Byte(PropertyCell(Prop, 0));
    Host.EndBus := Byte(PropertyCell(Prop, 1));
  end;
  { No more buses than the ECAM area holds (1 MiB each). }
  if (Size shr 20) > 0 then
    if Host.EndBus - Host.StartBus + 1 > (Size shr 20) then
      Host.EndBus := Byte(Host.StartBus + (Size shr 20) - 1);
  Host.Coherent := NodeIsDmaCoherent(Tree^, Host.Node);
  ReadWindows(Host.Node, Host);
  Result := True;
end;

function FindDeviceTreePciRoute(Segment: Word; Bus, Device, Pin: Byte; out Gic: TGicInterrupt): Boolean;
var
  Index: Integer;
  Host: TDeviceTreePciHost;
  Interrupt: TDeviceTreeInterrupt;
  Address: TDeviceTreeAddress;
begin
  Gic.Intid := 0;
  Gic.LevelTriggered := True;
  Gic.ActiveLow := False;
  Result := False;
  for Index := 0 to DeviceTreePciHostCount - 1 do
  begin
    if not GetDeviceTreePciHost(Index, Host) or (Host.Segment <> Segment) then
      Continue;
    Address.CellCount := 3;
    Address.Cells[0] := (LongWord(Bus) shl 16) or (LongWord(Device) shl 11);
    Address.Cells[1] := 0;
    Address.Cells[2] := 0;
    Address.Cells[3] := 0;
    Interrupt.Parent := Host.Node;
    Interrupt.CellCount := 1;
    Interrupt.Cells[0] := LongWord(Pin) + 1;
    Interrupt.Cells[1] := 0;
    Interrupt.Cells[2] := 0;
    Interrupt.Cells[3] := 0;
    Exit(ResolveInterrupt(SystemDeviceTree^, Interrupt, Address) and
      DecodeGicInterrupt(SystemDeviceTree^, Interrupt, Gic));
  end;
end;

end.
