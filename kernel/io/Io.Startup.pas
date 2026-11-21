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

    1. Input devices (keyboard, serial port), attached to the console,
       and a device tree's watchdog (the Pi 5's), armed before any bus
       bring-up can hang the machine
    2. PCI enumeration (the Pi 5's PCIe root complexes bring their links
       up and add their functions; then RP1 presents its peripherals)

  Kernel.Startup then loads the ACPI namespace (Io.AcpiNamespace: the
  AML, and with it PCI interrupt routing), which needs PCI configuration
  space, and InitializeIoSystem finishes:

    1. Storage, sound, network and USB drivers; storage registers whole-disk
       block devices, with the statistics filter on each disk
    2. Partition tables, which register partition block devices
    3. Device objects for all of them (/dev/disk0, /dev/disk0p1, ...)
    4. File systems, which mount every recognizable volume
    5. Firmware files the drivers asked for (Io.Firmware), now that the
       system volume is there

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
{ Which keyboards the keys came from (the input test checks both). }
procedure WriteKeyboardSummary;

implementation

uses
  Drivers.UsbHid,
  Drivers.Ps2Mouse,
  Io.InputEvents,
  Io.PciMessageInterrupts,
  Firmware.Acpi,
  Io.Pci,
  Memory.Layout,
  Firmware.DeviceTree,
  Io.DeviceTreeDevices,
  Io.PciResources,
  Drivers.BrcmPcie,
  Drivers.Rp1,
  Io.BlockDevice,
  Io.Partitions,
  Drivers.Ahci,
  Drivers.VirtioBlock,
  Drivers.RamDisk,
  Drivers.VirtioNet,
  Drivers.Nvme,
  Drivers.Sdhci,
  Drivers.Xhci,
  Drivers.UsbStorage,
  Drivers.UsbKeyboard,
  Drivers.HdAudio,
  Drivers.Ac97,
  Drivers.Bcm2712Dma,
  Drivers.HdmiAudio,
  Drivers.UsbAudio,
  Drivers.E1000,
  Drivers.Rtl8139,
  Drivers.Rtl8168,
  Drivers.Rtl8125,
  Drivers.Genet,
  Drivers.CadenceGem,
  Io.Firmware,
  FileSystem.Volumes,
  Io.DiskArrival,
  Debug.Output,
  Io.InterruptRouting,
  Drivers.SerialDevice,
  Drivers.Ps2Keyboard,
  Io.ConsoleInput,
  Drivers.DiskDevices,
  Drivers.DiskStatistics,
  Drivers.VideoCoreMailbox,
  Drivers.RaspberryPiBoard,
  Power.BoardClocks,
  Drivers.Bcm2835Watchdog,
  Drivers.I6300EsbWatchdog,
  Io.Watchdog;

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
  InitializeInputEvents;
  SerialByInterrupt := InitializeSerialDevice;
  if SerialByInterrupt then
    AttachConsoleInput('serial0');
  if InitializePs2Keyboard then
    AttachConsoleInput('keyboard');
  InitializePs2Mouse;
  DebugBeginMessage;
  DebugWriteTag('input');
  if SerialByInterrupt then
    DebugWriteLine('Serial console input from /dev/serial0, interrupt driven')
  else
    DebugWriteLine('Serial console input is polled');
  DebugEndMessage;
end;

procedure WriteDeviceTreeSummary(DeviceCount: Integer);
var
  Model: PChar;
begin
  DebugBeginMessage;
  DebugWriteTag('dt');
  DebugWrite('Device tree');
  Model := DeviceTreeModel;
  if Model <> nil then
  begin
    DebugWrite(' of ');
    DebugWrite(Model);
  end;
  DebugWrite(': ');
  DebugWriteDecimal(DeviceCount);
  DebugWriteLine(' platform devices');
  DebugEndMessage;
end;

procedure InitializePlatformTables(const BootInformation: TBootInformation);
begin
  InitializeAcpi(BootInformation.AcpiRootPointer);
  WriteAcpiSummary;
  { A native boot's device tree (the HAL took it already on AArch64). }
  if (BootInformation.DeviceTreePhysicalBase <> 0) and
     UseDeviceTree(PhysicalToVirtual(BootInformation.DeviceTreePhysicalBase)) then
    WriteDeviceTreeSummary(EnumerateDeviceTreeDevices);
  InitializeInterruptRouting;
end;

procedure InitializeBuses;
begin
  InitializeInputDevices;
  { A device tree's watchdog (the Pi 5's) armed before any bus is
    brought up, so a bring-up that hangs the machine resets it. }
  if InitializeBcm2835WatchdogFromDeviceTree then
    StartWatchdogPolicy;
  InitializePci;
  { Root complexes that are not ECAM (the Raspberry Pi 5's) add their
    functions themselves. }
  InitializeBrcmPcieHosts;
  { After a native boot nobody gave the devices addresses yet. }
  AssignPciResources;
  WritePciSummary;
  { The Pi 5's south bridge: its peripherals become platform devices
    with working memory and interrupts before any driver binds them. }
  InitializeRp1;
  { Suspend to RAM: configuration space first, then the MSI-X tables. }
  RegisterPciPowerHandler;
  RegisterMessageInterruptPowerHandler;
end;

procedure InitializeIoSystem;
begin
  { The Raspberry Pi's firmware first: the drivers ask it for clocks and
    addresses. }
  if InitializeVideoCoreMailbox then
  begin
    WriteBoardInformation;
    { The ARM clock's scaling, its thermal limit and the fan. }
    StartBoardPower;
  end;
  { The hardware watchdog as early as it can be found (the Pi 3/4's
    needs the mailbox), armed if the options or its driver say so;
    a device tree's is armed already (InitializeBuses). }
  if not WatchdogIsPresent then
  begin
    if not InitializeBcm2835Watchdog then
      InitializeI6300EsbWatchdog;
    StartWatchdogPolicy;
  end;
  InitializeBlockDevices;
  RegisterBlockIoPowerHandler;
  { The image a network boot brought (ramdisk0), the system volume. }
  InitializeRamDisk;
  InitializeAhciControllers;
  InitializeVirtioBlockDevices;
  InitializeNvmeControllers;
  { Network adapters (Io.NetworkAdapters). }
  InitializeVirtioNetDevices;
  { Built-in sound first, so it keeps the first device names. }
  InitializeHdAudioControllers;
  InitializeAc97Controllers;
  { The Raspberry Pi 5's HDMI audio: its DMA controller first (device
    tree platform devices; both find nothing elsewhere). }
  InitializeBcm2712DmaControllers;
  InitializeHdmiAudio;
  { Network cards register their adapters (eth0, eth1, ...). }
  InitializeE1000Adapters;
  InitializeRtl8139Adapters;
  InitializeRtl8168Adapters;
  InitializeRtl8125Adapters;
  { The Raspberry Pi 4's own Ethernet (an ACPI platform device). }
  InitializeGenetAdapters;
  { The Raspberry Pi 5's Ethernet, in RP1 (a device tree platform
    device once Drivers.Rp1 described it). }
  InitializeCadenceGemAdapters;
  RegisterUsbStorageDriver;
  RegisterUsbHidDriver;
  RegisterUsbAudioDriver;
  InitializeXhciControllers;
  { After the other disks, so their names stay as they were. }
  InitializeSdhciControllers;
  AttachDiskStatistics;
  ScanAllDisksForPartitions;
  InitializeDiskDevices;

  InitializeFileSystems;
  MountAllVolumes;
  { Firmware drivers asked for comes from /lib/firmware on the system
    volume, now mounted. }
  DeliverRequestedFirmware;
  { Disks found from now on (USB disks plugged in) are brought up one by
    one as they come. }
  EnableDiskArrival;
end;

procedure WriteKeyboardSummary;
begin
  DebugBeginMessage;
  DebugWriteTag('input');
  DebugWrite('keys pressed: PS/2 ');
  DebugWriteDecimal(Ps2KeyboardKeyCount);
  DebugWrite(', USB ');
  DebugWriteDecimal(UsbKeyboardKeyCount);
  DebugWriteLine('');
  DebugEndMessage;
end;

end.
