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
  The platform devices of the ACPI namespace: each device the walk
  (Firmware.AcpiDeviceWalk) describes becomes a platform device
  (Io.PlatformDevices), its DMA attributes made from what it says: _CCA
  decides coherency (without one, the architecture's default holds, see
  Hal.DmaCoherency), each memory range of _DMA is a window (the
  processor's address, the bus address), and the noncoherentdma option
  applies on top.

  Runs while the namespace loads (Io.AcpiNamespace), on its thread with
  the large stack, before anybody else uses the interpreter.
}
unit Io.AcpiDevices;

{$mode objfpc}
{$pointermath on}

interface

{ Records every platform device; returns how many there are. }
function EnumerateAcpiDevices: Integer;

implementation

uses
  Runtime.Memory,
  Runtime.Text,
  Firmware.AmlValues,
  Firmware.AcpiResourceList,
  Firmware.AcpiDeviceWalk,
  Io.Dma,
  Io.PlatformDevices;

procedure MakeDmaAttributes(constref Description: TAcpiDeviceDescription; out Dma: TDmaAttributes);
var
  Index: Integer;
begin
  SetDefaultDmaAttributes(Dma);
  if Description.HasCoherency then
    Dma.Coherent := Description.Coherent;
  if Description.HasDma then
    for Index := 0 to Description.DmaRanges.MemoryCount - 1 do
      if Dma.WindowCount < MaximumDmaWindows then
      begin
        Dma.Windows[Dma.WindowCount].PhysicalStart := Description.DmaRanges.Memory[Index].Start;
        Dma.Windows[Dma.WindowCount].BusStart := Description.DmaRanges.Memory[Index].BusStart;
        Dma.Windows[Dma.WindowCount].Length := Description.DmaRanges.Memory[Index].Length;
        Inc(Dma.WindowCount);
      end;
  ApplyDmaOptions(Dma);
end;

procedure RecordDevice(var Description: TAcpiDeviceDescription; Context: Pointer);
var
  Device: TPlatformDevice;
  Index: Integer;
begin
  ZeroMemory(@Device, SizeOf(Device));
  Device.Node := Description.Node;
  Device.DeviceTreeNode := NoDeviceTreeNode;
  CopyMemory(@Device.Path[0], @Description.Path[0], SizeOf(Device.Path));
  CopyText(@Device.HardwareId[0], @Description.HardwareId[0], PlatformIdLength);
  Device.CompatibleIdCount := Description.CompatibleIdCount;
  for Index := 0 to Description.CompatibleIdCount - 1 do
    CopyText(@Device.CompatibleIds[Index][0], @Description.CompatibleIds[Index][0], PlatformIdLength);
  Device.UniqueId := Description.UniqueId;
  Device.Status := Description.Status;
  Device.Resources := Description.Resources;
  MakeDmaAttributes(Description, Device.Dma);
  Device.HasCoherencyObject := Description.HasCoherency;
  Device.HasDmaObject := Description.HasDma;
  Device.Properties := Description.Properties;
  Device.Segment := Description.Segment;
  { The list keeps the properties; dropped if it is full. }
  if not AddPlatformDevice(Device) then
    ReleaseValue(Description.Properties);
end;

function EnumerateAcpiDevices: Integer;
begin
  WalkAcpiDevices(@RecordDevice, nil);
  Result := PlatformDeviceCount;
end;

end.
