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
  I/O system startup.

  Brings up device discovery and storage in dependency order, in two
  steps. The first, InitializePlatformTables, reads what the firmware
  describes:

    1. ACPI tables (needed to find PCI configuration space and the
       processors)
    2. Interrupt routing (the I/O APICs from the MADT)

  Then the other processors are started (Kernel.SecondaryProcessors), so
  device interrupts can be spread over them, and InitializeBuses goes on:

    1. Input devices (keyboard, serial port), attached to the console
    2. PCI enumeration

  Kernel.Startup then loads the ACPI namespace (Io.AcpiNamespace: the
  AML, and with it PCI interrupt routing), which needs PCI configuration
  space, and InitializeIoSystem finishes:

    1. Storage, sound and USB drivers; storage registers whole-disk
       block devices, with the statistics filter on each disk
    2. Partition tables, which register partition block devices
    3. Device objects for all of them (/dev/disk0, /dev/disk0p1, ...)
    4. File systems, which mount every recognizable volume

  Runs in phase 1 because drivers sleep, wait and take mutexes.
}
unit Io.Startup;

{$mode objfpc}

interface

uses
  Boot.Information;

procedure InitializePlatformTables(const BootInformation: TBootInformation);
procedure InitializeBuses;
procedure InitializeIoSystem;

implementation

uses
  Firmware.Acpi,
  Io.Pci,
  Io.BlockDevice,
  Io.Partitions,
  Drivers.Ahci,
  Drivers.VirtioBlock,
  Drivers.Nvme,
  Drivers.Xhci,
  Drivers.UsbStorage,
  Drivers.UsbKeyboard,
  Drivers.HdAudio,
  Drivers.Ac97,
  Drivers.UsbAudio,
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

procedure InitializeBuses;
begin
  InitializeInputDevices;
  InitializePci;
  WritePciSummary;
end;

procedure InitializeIoSystem;
begin
  InitializeBlockDevices;
  InitializeAhciControllers;
  InitializeVirtioBlockDevices;
  InitializeNvmeControllers;
  { Built-in sound first, so it keeps the first device names. }
  InitializeHdAudioControllers;
  InitializeAc97Controllers;
  RegisterUsbStorageDriver;
  RegisterUsbKeyboardDriver;
  RegisterUsbAudioDriver;
  InitializeXhciControllers;
  AttachDiskStatistics;
  ScanAllDisksForPartitions;
  InitializeDiskDevices;

  InitializeFileSystems;
  MountAllVolumes;
end;

end.
