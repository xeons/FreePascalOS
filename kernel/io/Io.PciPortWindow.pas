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
  The PCI I/O space window of processors without I/O instructions.

  A PCIe host bridge on AArch64 forwards a window of memory addresses
  to the I/O space of the devices below it (QEMU's virt machine: 64 KiB
  at 3EFF0000h). The root bridge says where: the I/O range its _CRS
  produces (an address space descriptor whose translation offset turns
  port numbers into processor addresses, Firmware.AcpiResourceList), or
  after a native boot the I/O window of the ECAM host's "ranges"
  (Firmware.DeviceTreePci). Hal.PortIo is given the processor address
  of port 0, so devices with I/O BARs (AC'97, the I/O BARs of e1000 and
  the Realtek cards) work. Ports form one 64 KiB space: the first host
  bridge's window is used.

  On x86-64 the ports are the processor's own and the HAL ignores it.
}
unit Io.PciPortWindow;

{$mode objfpc}

interface

{ Finds the root bridge's I/O window and hands it to the HAL. Runs once
  the ACPI namespace is loaded (its _CRS) and the device tree's hosts
  are known. }
procedure InitializePciPortWindow;

implementation

uses
  DeviceTree.Addresses,
  Firmware.DeviceTree,
  Firmware.DeviceTreePci,
  Io.PlatformDevices,
  Hal.PortIo,
  Debug.Output;

const
  PortSpaceSize = $10000;

{ The window in processor addresses as seen from port 0: Physical is
  where bus address BusAddress lies. False if it does not start low
  enough to hold port 0's page. }
function MakeWindow(Physical, BusAddress, Size: QWord; out Base, Length: QWord): Boolean;
begin
  Base := 0;
  Length := 0;
  if (Size = 0) or (BusAddress >= PortSpaceSize) or (Physical < BusAddress) then
    Exit(False);
  Base := Physical - BusAddress;
  Length := BusAddress + Size;
  if Length > PortSpaceSize then
    Length := PortSpaceSize;
  Result := True;
end;

function FindDeviceTreeWindow(out Base, Length: QWord): Boolean;
var
  HostIndex: Integer;
  WindowIndex: Integer;
  Host: TDeviceTreePciHost;
begin
  Result := False;
  if not DeviceTreeIsAvailable then
    Exit;
  for HostIndex := 0 to DeviceTreePciHostCount - 1 do
    if GetDeviceTreePciHost(HostIndex, Host) then
      for WindowIndex := 0 to Host.WindowCount - 1 do
        if (Host.Windows[WindowIndex].Space = PciSpaceIo) and
           MakeWindow(Host.Windows[WindowIndex].PhysicalAddress, Host.Windows[WindowIndex].BusAddress,
             Host.Windows[WindowIndex].Size, Base, Length) then
          Exit(True);
end;

function FindAcpiWindow(out Base, Length: QWord): Boolean;
var
  Index: Integer;
  Device: PPlatformDevice;
  RangeIndex: Integer;
begin
  Result := False;
  for Index := 0 to PlatformDeviceCount - 1 do
  begin
    Device := PlatformDeviceAt(Index);
    if not PlatformDeviceHasId(Device, 'PNP0A08') and not PlatformDeviceHasId(Device, 'PNP0A03') then
      Continue;
    for RangeIndex := 0 to Device^.Resources.IoCount - 1 do
      if Device^.Resources.Io[RangeIndex].IsProducer and
         MakeWindow(Device^.Resources.Io[RangeIndex].Start, Device^.Resources.Io[RangeIndex].BusStart,
           Device^.Resources.Io[RangeIndex].Length, Base, Length) then
        Exit(True);
  end;
end;

procedure InitializePciPortWindow;
var
  Base: QWord;
  Length: QWord;
begin
  if not PortIoNeedsWindow then
    Exit;
  if not FindAcpiWindow(Base, Length) and not FindDeviceTreeWindow(Base, Length) then
    Exit;
  if not UsePortIoWindow(Base, Length) then
    Exit;
  DebugBeginMessage;
  DebugWriteTag('pci');
  DebugWrite('I/O ports 0-0x');
  DebugWriteHex(Length - 1, 4);
  DebugWrite(' through the window at 0x');
  DebugWriteHex(Base, 8);
  DebugWriteLine('');
  DebugEndMessage;
end;

end.
