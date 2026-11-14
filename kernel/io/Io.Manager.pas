{
  I/O system startup.

  Brings up device discovery and storage in dependency order:

    1. ACPI tables (needed to find PCI configuration space)
    2. PCI enumeration
    3. Storage drivers, which register whole-disk block devices
    4. Partition tables, which register partition block devices
    5. File systems, which mount every recognizable volume

  Runs in phase 1 because drivers sleep, wait and take mutexes.
}
unit Io.Manager;

{$mode objfpc}

interface

uses
  Boot.Information;

procedure InitializeIoSystem(const BootInformation: TBootInformation);

implementation

uses
  Firmware.Acpi,
  Io.Pci,
  Io.BlockDevice,
  Io.Partitions,
  Drivers.Ahci,
  FileSystem.Volumes,
  Debug.Output;

procedure ScanAllDisksForPartitions;
var
  DeviceIndex: Integer;
  WholeDiskCount: Integer;
  Device: PBlockDevice;
begin
  { Partition devices are appended while scanning, so only look at the
    devices that existed beforehand. }
  WholeDiskCount := BlockDeviceCount;
  for DeviceIndex := 0 to WholeDiskCount - 1 do
  begin
    Device := BlockDeviceAt(DeviceIndex);
    if not BlockDeviceIsPartition(Device) then
      ScanPartitions(Device);
  end;
end;

procedure InitializeIoSystem(const BootInformation: TBootInformation);
begin
  InitializeAcpi(BootInformation.AcpiRootPointer);
  WriteAcpiSummary;

  InitializePci;
  WritePciSummary;

  InitializeBlockDevices;
  InitializeAhciControllers;
  ScanAllDisksForPartitions;

  InitializeFileSystems;
  MountAllVolumes;
end;

end.
