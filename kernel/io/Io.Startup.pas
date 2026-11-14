{
  I/O system startup.

  Brings up device discovery and storage in dependency order, in two
  steps. The first, InitializePlatformTables, reads what the firmware
  describes:

    1. ACPI tables (needed to find PCI configuration space and the
       processors)
    2. Interrupt routing (the I/O APICs from the MADT)

  Then the other processors are started (Kernel.SecondaryProcessors), so
  device interrupts can be spread over them, and InitializeIoSystem
  continues:

    1. Input devices (keyboard, serial port), attached to the console
    2. PCI enumeration
    3. Storage drivers, which register whole-disk block devices, and
       the statistics filter on each disk
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

procedure InitializePlatformTables(const BootInformation: TBootInformation);
procedure InitializeIoSystem;

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
  Drivers.SerialDevice,
  Drivers.Ps2Keyboard,
  Io.ConsoleInput,
  Drivers.DiskDevices,
  Drivers.DiskStatistics;

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
  SerialByInterrupt := InitializeSerialDevice;
  if SerialByInterrupt then
    AttachConsoleInput('serial0');
  if InitializePs2Keyboard then
    AttachConsoleInput('keyboard');
  DebugBeginMessage;
  DebugWriteTag('input');
  if SerialByInterrupt then
    DebugWriteLine('Serial console input from /dev/serial0 (IRQ 4)')
  else
    DebugWriteLine('Serial console input is polled');
  DebugEndMessage;
end;

procedure InitializePlatformTables(const BootInformation: TBootInformation);
begin
  InitializeAcpi(BootInformation.AcpiRootPointer);
  WriteAcpiSummary;
  InitializeInterruptRouting;
end;

procedure InitializeIoSystem;
begin
  InitializeInputDevices;

  InitializePci;
  WritePciSummary;

  InitializeBlockDevices;
  InitializeAhciControllers;
  AttachDiskStatistics;
  ScanAllDisksForPartitions;
  InitializeDiskDevices;

  InitializeFileSystems;
  MountAllVolumes;
end;

end.
