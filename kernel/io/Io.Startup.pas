{
  I/O system startup.

  Brings up device discovery and storage in dependency order:

    1. ACPI tables (needed to find PCI configuration space)
    2. PCI enumeration
    3. Storage drivers, which register whole-disk block devices
    4. Partition tables, which register partition block devices
    5. Device objects for all of them (/dev/disk0, /dev/disk0p1, ...)
    6. File systems, which mount every recognizable volume

  Runs in phase 1 because drivers sleep, wait and take mutexes.
}
unit Io.Startup;

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
  Debug.Output,
  Io.InterruptRouting,
  Drivers.SerialInput,
  Drivers.Ps2Keyboard,
  Drivers.DiskDevices;

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

procedure InitializeInputDevices;
var
  SerialByInterrupt: Boolean;
begin
  SerialByInterrupt := InitializeSerialInput;
  InitializePs2Keyboard;
  DebugBeginMessage;
  DebugWriteTag('input');
  if SerialByInterrupt then
    DebugWriteLine('Serial console input on IRQ 4')
  else
    DebugWriteLine('Serial console input is polled');
  DebugEndMessage;
end;

procedure InitializeIoSystem(const BootInformation: TBootInformation);
begin
  InitializeAcpi(BootInformation.AcpiRootPointer);
  WriteAcpiSummary;
  InitializeInterruptRouting;
  InitializeInputDevices;

  InitializePci;
  WritePciSummary;

  InitializeBlockDevices;
  InitializeAhciControllers;
  ScanAllDisksForPartitions;
  InitializeDiskDevices;

  InitializeFileSystems;
  MountAllVolumes;
end;

end.
