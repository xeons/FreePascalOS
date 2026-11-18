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
  The Raspberry Pi 5's RP1 south bridge (PCI 1de4:0001, behind the
  BCM2712's pcie2, Drivers.BrcmPcie): its Ethernet, USB, UARTs, SPI,
  I2C, GPIO... as platform devices that ordinary drivers bind.

  - BAR1 is RP1's peripheral space (4 MiB), BAR2 its shared memory
    (64 KiB). A BAR1 of 64 KiB or less means RP1's own firmware has not
    run (Linux refuses it too).
  - The chip id (SYSINFO at BAR1 + 0) must read 2000_1927 (C0, what Pi 5
    boards have).
  - The interrupts: MSI-X, Drivers.Rp1Interrupts.
  - The peripherals: the device tree's "rp1" node below the host
    (Firmware.DeviceTreeRp1). Io.DeviceTreeDevices already made a
    platform device of each enabled one, its memory translated through
    the tree's ranges (right only if RP1's BARs are where the tree
    assumes) and no interrupts (RP1's are not the GIC's). Here each
    gets its memory again from the BARs actually assigned (an offset
    into RP1's window: BAR1 then BAR2) and its interrupts as RP1
    numbers, connected through RP1 (TPlatformDevice.InterruptConnect).
    Their DMA attributes stay those the tree gives (the "rp1" node's
    dma-ranges: RAM at bus address 10_0000_0000; not coherent).

  Everything is logged with the tag "rp1".
}
unit Drivers.Rp1;

{$mode objfpc}
{$pointermath on}

interface

{ Finds RP1 on the PCI buses and presents its peripherals; True if it
  is there and working. }
function InitializeRp1: Boolean;

implementation

uses
  Runtime.Atomic,
  Memory.KernelHeap,
  Memory.DeviceMapping,
  DeviceTree.Blob,
  Firmware.DeviceTree,
  Firmware.AcpiResourceList,
  Firmware.DeviceTreeRp1,
  Io.Pci,
  Io.PlatformDevices,
  Drivers.Rp1Interrupts,
  Debug.Output;

const
  Rp1VendorId = $1DE4;
  Rp1DeviceId = $0001;
  Rp1C0ChipId = LongWord($20001927);
  SysinfoChipId = $0;
  SysinfoPlatform = $4;
  PcieBlockOffset = $108000;
  BlockBytes = $1000;
  MinimumPeripheralBar = $10000;
  PeripheralBar = 1;
  SharedMemoryBar = 2;

type
  PRp1 = ^TRp1;
  TRp1 = record
    Pci: PPciDevice;
    HostNode: LongInt;
    Window: TRp1Window;
    Peripherals: TPciBar;
    PeripheralsBus: QWord;
    SharedMemory: TPciBar;
    SharedMemoryBus: QWord;
    Interrupts: TRp1Interrupts;
  end;

procedure Report(Text: PChar; Value: Int64);
begin
  DebugBeginMessage;
  DebugWriteTag('rp1');
  DebugWrite(Text);
  if Value >= 0 then
  begin
    DebugWrite(' 0x');
    DebugWriteHex(QWord(Value), 1);
  end;
  DebugWriteLine('');
  DebugEndMessage;
end;

function FindRp1Function: PPciDevice;
var
  Index: Integer;
  Candidate: PPciDevice;
begin
  for Index := 0 to PciDeviceCount - 1 do
  begin
    Candidate := PciDeviceAt(Index);
    if (Candidate^.VendorId = Rp1VendorId) and (Candidate^.DeviceId = Rp1DeviceId) then
      Exit(Candidate);
  end;
  Result := nil;
end;

{ The brcm,bcm2712-pcie node of the segment RP1 is on. }
function FindHostNode(Segment: Word): LongInt;
var
  Index: Integer;
  Device: PPlatformDevice;
begin
  Index := FindPlatformDevice('brcm,bcm2712-pcie', 0);
  while Index >= 0 do
  begin
    Device := PlatformDeviceAt(Index);
    if Device^.Segment = Segment then
      Exit(Device^.DeviceTreeNode);
    Index := FindPlatformDevice('brcm,bcm2712-pcie', Index + 1);
  end;
  Result := NoNode;
end;

function BarBusAddress(Pci: PPciDevice; Index: Integer; Is64Bit: Boolean): QWord;
begin
  Result := PciRead32(Pci, PciConfigurationBar0 + Word(Index) * 4) and $FFFFFFF0;
  if Is64Bit then
    Result := Result or (QWord(PciRead32(Pci, PciConfigurationBar0 + Word(Index) * 4 + 4)) shl 32);
end;

function ReadBars(Rp1: PRp1): Boolean;
begin
  Result := False;
  if not PciReadBar(Rp1^.Pci, PeripheralBar, Rp1^.Peripherals) or Rp1^.Peripherals.IsIoPort then
  begin
    Report('FAILED: BAR1 (peripherals) missing', -1);
    Exit;
  end;
  if Rp1^.Peripherals.SizeInBytes <= MinimumPeripheralBar then
  begin
    Report('FAILED: BAR1 too small (RP1 firmware not running?), size', Int64(Rp1^.Peripherals.SizeInBytes));
    Exit;
  end;
  Rp1^.PeripheralsBus := BarBusAddress(Rp1^.Pci, PeripheralBar, Rp1^.Peripherals.Is64Bit);
  if not PciReadBar(Rp1^.Pci, SharedMemoryBar, Rp1^.SharedMemory) then
    Rp1^.SharedMemory.SizeInBytes := 0;
  Rp1^.SharedMemoryBus := BarBusAddress(Rp1^.Pci, SharedMemoryBar, Rp1^.SharedMemory.Is64Bit);

  DebugBeginMessage;
  DebugWriteTag('rp1');
  DebugWrite('BAR1 ');
  DebugWriteSize(Rp1^.Peripherals.SizeInBytes);
  DebugWrite(' at 0x');
  DebugWriteHex(Rp1^.Peripherals.PhysicalAddress, 1);
  DebugWrite(' (bus 0x');
  DebugWriteHex(Rp1^.PeripheralsBus, 1);
  DebugWrite('), BAR2 ');
  DebugWriteSize(Rp1^.SharedMemory.SizeInBytes);
  DebugWrite(' at 0x');
  DebugWriteHex(Rp1^.SharedMemory.PhysicalAddress, 1);
  DebugWriteLine('');
  DebugEndMessage;
  Result := True;
end;

function CheckChip(Rp1: PRp1): Boolean;
var
  Sysinfo: PByte;
  ChipId: LongWord;
  Platform: LongWord;
begin
  Result := False;
  Sysinfo := PByte(MapDeviceMemory(Rp1^.Peripherals.PhysicalAddress + SysinfoChipId, BlockBytes));
  if Sysinfo = nil then
  begin
    Report('FAILED: SYSINFO could not be mapped', -1);
    Exit;
  end;
  ChipId := PLongWord(Sysinfo + SysinfoChipId)^;
  Platform := PLongWord(Sysinfo + SysinfoPlatform)^;
  UnmapDeviceMemory(Sysinfo, BlockBytes);
  DebugBeginMessage;
  DebugWriteTag('rp1');
  DebugWrite('chip id 0x');
  DebugWriteHex(ChipId, 8);
  DebugWrite(', platform 0x');
  DebugWriteHex(Platform, 1);
  if ChipId = Rp1C0ChipId then
    DebugWriteLine(' (RP1 C0)')
  else
    DebugWriteLine(' (NOT the RP1 C0 id 20001927)');
  DebugEndMessage;
  { All ones: BAR1 does not reach RP1 at all. }
  Result := ChipId <> $FFFFFFFF;
end;

{ The processor's address of offset Offset of RP1's window: the BAR
  holding the bus address the tree says, else BAR1 then BAR2 in a row. }
function WindowPhysical(Rp1: PRp1; Offset: QWord; out Physical: QWord): Boolean;
var
  Bus: QWord;
begin
  Result := True;
  Bus := Rp1^.Window.PciAddress + Offset;
  if (Bus >= Rp1^.PeripheralsBus) and (Bus - Rp1^.PeripheralsBus < Rp1^.Peripherals.SizeInBytes) then
    Physical := Rp1^.Peripherals.PhysicalAddress + (Bus - Rp1^.PeripheralsBus)
  else if (Rp1^.SharedMemory.SizeInBytes > 0) and (Bus >= Rp1^.SharedMemoryBus) and
          (Bus - Rp1^.SharedMemoryBus < Rp1^.SharedMemory.SizeInBytes) then
    Physical := Rp1^.SharedMemory.PhysicalAddress + (Bus - Rp1^.SharedMemoryBus)
  else if Offset < Rp1^.Peripherals.SizeInBytes then
    Physical := Rp1^.Peripherals.PhysicalAddress + Offset
  else if Offset - Rp1^.Peripherals.SizeInBytes < Rp1^.SharedMemory.SizeInBytes then
    Physical := Rp1^.SharedMemory.PhysicalAddress + (Offset - Rp1^.Peripherals.SizeInBytes)
  else
  begin
    Physical := 0;
    Result := False;
  end;
end;

procedure DescribePeripheral(Rp1: PRp1; Device: PPlatformDevice);
var
  Tree: PDeviceTree;
  Node: LongInt;
  Count: LongWord;
  Index: LongWord;
  Offset: QWord;
  Size: QWord;
  Physical: QWord;
  Interrupt: TRp1Interrupt;
begin
  Tree := SystemDeviceTree;
  Node := Device^.DeviceTreeNode;
  Device^.Resources.MemoryCount := 0;
  Index := 0;
  while Device^.Resources.MemoryCount < MaximumResourceRanges do
  begin
    if not Rp1RegisterOffset(Tree^, Rp1^.Window, Node, Index, Offset, Size) then
      Break;
    if WindowPhysical(Rp1, Offset, Physical) then
    begin
      Device^.Resources.Memory[Device^.Resources.MemoryCount].Start := Physical;
      Device^.Resources.Memory[Device^.Resources.MemoryCount].Length := Size;
      Device^.Resources.Memory[Device^.Resources.MemoryCount].BusStart := Rp1^.Window.ChildBase + Offset;
      Device^.Resources.Memory[Device^.Resources.MemoryCount].IsProducer := False;
      Inc(Device^.Resources.MemoryCount);
    end;
    Inc(Index);
  end;
  Device^.Resources.InterruptCount := 0;
  Count := Rp1NodeInterruptCount(Tree^, Node);
  Index := 0;
  while (Index < Count) and (Device^.Resources.InterruptCount < MaximumResourceInterrupts) do
  begin
    if ReadRp1Interrupt(Tree^, Rp1^.Window, Node, Index, Interrupt) then
    begin
      Device^.Resources.Interrupts[Device^.Resources.InterruptCount].Number := Interrupt.Number;
      Device^.Resources.Interrupts[Device^.Resources.InterruptCount].LevelTriggered := Interrupt.LevelTriggered;
      Device^.Resources.Interrupts[Device^.Resources.InterruptCount].ActiveLow := False;
      Device^.Resources.Interrupts[Device^.Resources.InterruptCount].Shared := False;
      Device^.Resources.Interrupts[Device^.Resources.InterruptCount].IsIsaIrq := False;
      Inc(Device^.Resources.InterruptCount);
    end;
    Inc(Index);
  end;
  Device^.InterruptConnect := @ConnectRp1Interrupt;
  Device^.InterruptController := @Rp1^.Interrupts;
end;

{ Every platform device below the RP1 node; how many. }
function DescribePeripherals(Rp1: PRp1): Integer;
var
  Index: Integer;
  Device: PPlatformDevice;
begin
  Result := 0;
  for Index := 0 to PlatformDeviceCount - 1 do
  begin
    Device := PlatformDeviceAt(Index);
    if (Device^.DeviceTreeNode <> NoNode) and (Device^.DeviceTreeNode <> Rp1^.Window.Node) and
       NodeIsWithin(SystemDeviceTree^, Device^.DeviceTreeNode, Rp1^.Window.Node) then
    begin
      DescribePeripheral(Rp1, Device);
      Inc(Result);
    end;
  end;
end;

procedure ReportWindow(Rp1: PRp1; Count: Integer);
begin
  DebugBeginMessage;
  DebugWriteTag('rp1');
  DebugWriteDecimal(Count);
  DebugWrite(' peripherals; window 0x');
  DebugWriteHex(Rp1^.Window.ChildBase, 1);
  DebugWrite(' = bus 0x');
  DebugWriteHex(Rp1^.Window.PciAddress, 1);
  if not Rp1^.Window.FromRanges then
    DebugWrite(' (no ranges: defaults)');
  if Rp1^.Window.PciAddress <> Rp1^.PeripheralsBus then
    DebugWrite(', NOT where BAR1 is: offsets used');
  DebugWriteLine('');
  DebugEndMessage;
end;

function InitializeRp1: Boolean;
var
  Rp1: PRp1;
  Count: Integer;
begin
  Result := False;
  Rp1 := PRp1(AllocateZeroedKernelMemory(SizeOf(TRp1)));
  if Rp1 = nil then
    Exit;
  Rp1^.Pci := FindRp1Function;
  if Rp1^.Pci = nil then
  begin
    if FindPlatformDevice('brcm,bcm2712-pcie', 0) >= 0 then
      Report('not found on the PCI buses (is the pcie2 link up?)', -1);
    Exit;
  end;
  DebugBeginMessage;
  DebugWriteTag('rp1');
  DebugWrite('RP1 at ');
  DebugWriteDecimal(Rp1^.Pci^.Segment);
  DebugWrite(':');
  DebugWriteHex(Rp1^.Pci^.Bus, 2);
  DebugWrite(':');
  DebugWriteHex(Rp1^.Pci^.Device, 2);
  DebugWrite('.');
  DebugWriteDecimal(Rp1^.Pci^.FunctionNumber);
  DebugWrite(' rev ');
  DebugWriteHex(Rp1^.Pci^.Revision, 2);
  DebugWriteLine('');
  DebugEndMessage;
  if not ReadBars(Rp1) then
    Exit;
  PciEnableDevice(Rp1^.Pci, True);
  if not CheckChip(Rp1) then
  begin
    Report('FAILED: SYSINFO reads all ones: BAR1 does not reach RP1', -1);
    Exit;
  end;
  Rp1^.Interrupts.Pci := Rp1^.Pci;
  Rp1^.Interrupts.PcieBlock := PByte(MapDeviceMemory(Rp1^.Peripherals.PhysicalAddress + PcieBlockOffset,
    BlockBytes));
  if Rp1^.Interrupts.PcieBlock = nil then
  begin
    Report('FAILED: its PCIe block could not be mapped', -1);
    Exit;
  end;
  if not StartRp1Interrupts(@Rp1^.Interrupts) then
    Report('peripherals get no interrupts (their drivers poll)', -1);
  Rp1^.HostNode := FindHostNode(Rp1^.Pci^.Segment);
  ReadRp1Window(SystemDeviceTree^, FindRp1Node(SystemDeviceTree^, Rp1^.HostNode), Rp1^.Window);
  if Rp1^.Window.Node = NoNode then
  begin
    Report('FAILED: no "rp1" node below the PCIe host in the device tree', -1);
    Exit;
  end;
  Count := DescribePeripherals(Rp1);
  ReportWindow(Rp1, Count);
  Result := True;
end;

end.
