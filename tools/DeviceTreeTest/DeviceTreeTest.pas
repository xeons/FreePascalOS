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
  Host test of the device tree reading (make device-tree-test): the
  shared units the native boot stub and the kernel use (DeviceTree.Blob,
  .Addresses, .Chosen) and the kernel's (Firmware.DeviceTreeInterrupts,
  .Machine, .Pci), over a tree make-tree.py encodes in the Raspberry Pi
  5's layout:

    - the header, the memory reservation, paths with and without unit
      addresses, an alias, phandles, the disabled node and its child;
    - /chosen: bootargs, the initrd, stdout-path through the alias to the
      PL011 at 10_7D00_1000 (through /soc's ranges), the r5g6b5
      simple-framebuffer in /chosen without ranges;
    - /memory with two entries, reg of 64-bit buses, the PCIe root
      complex's three-cell ranges, dma-ranges and dma-coherent;
    - the GIC-400 (distributor and CPU interface), the virtual timer's
      PPI, PSCI by SMC, the four processors by MPIDR;
    - interrupts: an SPI, interrupts-extended with a controller that is
      not the GIC, the interrupt-maps of both PCI host bridges;
    - the ECAM host bridge: configuration space, buses, windows;
    - the RP1 root complex as a host that is not ECAM (segment, windows,
      inbound windows, the MIP it sends messages to) and RP1's own node
      (Firmware.DeviceTreeRp1): its peripheral window, peripherals'
      registers as offsets into it and as the processor's addresses,
      their RP1 interrupt numbers and triggers, their DMA windows.

  Prints every failed check and exits with 1 if there was one.
}
program DeviceTreeTest;

{$mode objfpc}

uses
  SysUtils,
  DeviceTree.Blob,
  DeviceTree.Addresses,
  DeviceTree.Chosen,
  Firmware.DeviceTree,
  Firmware.DeviceTreeInterrupts,
  Firmware.DeviceTreeMachine,
  Firmware.DeviceTreePci,
  Firmware.DeviceTreeRp1;

var
  Failures: Integer = 0;
  Blob: array of Byte;
  Tree: PDeviceTree;

procedure Check(Condition: Boolean; const What: string);
begin
  if not Condition then
  begin
    WriteLn('DEVICE TREE TEST: failed: ', What);
    Inc(Failures);
  end;
end;

procedure CheckNumber(Actual, Expected: QWord; const What: string);
begin
  Check(Actual = Expected, What + ' is $' + IntToHex(Actual, 1) + ', expected $' + IntToHex(Expected, 1));
end;

procedure LoadBlob(const Path: string);
var
  Input: File;
begin
  AssignFile(Input, Path);
  Reset(Input, 1);
  SetLength(Blob, FileSize(Input));
  BlockRead(Input, Blob[0], Length(Blob));
  CloseFile(Input);
end;

procedure TestStructure;
var
  Address: QWord;
  Size: QWord;
  Node: LongInt;
begin
  CheckNumber(DeviceTreeTotalSize(@Blob[0]), Length(Blob), 'the total size');
  Check(GetMemoryReservation(Tree^, 0, Address, Size) and (Address = 0) and (Size = $80000),
    'the memory reservation');
  Check(not GetMemoryReservation(Tree^, 1, Address, Size), 'only one memory reservation');
  Check(DeviceTreeTextIsEqual(DeviceTreeModel, 'Raspberry Pi 5 Model B Rev 1.1'), 'the model');
  Node := FindNodeByPath(Tree^, '/soc@107c000000/serial@7d001000');
  Check(Node <> NoNode, 'the full path of the UART');
  Check(FindNodeByPath(Tree^, '/soc/serial') = Node, 'the path without unit addresses');
  Check(FindNodeByPath(Tree^, 'serial10:115200n8') = Node, 'the alias with options');
  Check(DeviceTreeTextIsEqual(NodeName(Tree^, ParentNode(Tree^, Node)), 'soc@107c000000'), 'the parent');
  Check(FindNodeByPath(Tree^, '/soc/nothing') = NoNode, 'a path that is not there');
  Check(FindNodeByPhandle(Tree^, 1) = FindNodeByPath(Tree^, '/soc/interrupt-controller'), 'the phandle');
  Check(FindCompatibleNode(Tree^, NoNode, 'brcm,bcm2712-pm') = NoNode, 'the disabled node is not found');
  Check(FindCompatibleNode(Tree^, NoNode, 'test,hidden-child') <> NoNode, 'a node below a disabled one exists');
  Check(NodeIsCompatible(Tree^, Node, 'arm,primecell'), 'the second compatible string');
end;

procedure TestChosen;
var
  StartAddress: QWord;
  EndAddress: QWord;
  Uart: TDeviceTreeUart;
  Framebuffer: TDeviceTreeFramebuffer;
begin
  Check(DeviceTreeTextIsEqual(ReadBootArguments(Tree^),
    'reboot=w coherent_pool=1M 8250.nr_uarts=1 netlog=192.168.1.2'), 'the bootargs');
  Check(ReadInitrdRange(Tree^, StartAddress, EndAddress), 'the initrd');
  CheckNumber(StartAddress, $2000000, 'the initrd start');
  CheckNumber(EndAddress, $6000000, 'the initrd end');
  Check(FindConsoleUart(Tree^, Uart), 'the console UART');
  Check(Uart.Kind = DeviceTreeUartPl011, 'the console is a PL011');
  CheckNumber(Uart.PhysicalAddress, $107D001000, 'the console UART''s address');
  Check(FindSimpleFramebuffer(Tree^, Framebuffer), 'the simple-framebuffer');
  CheckNumber(Framebuffer.PhysicalAddress, $3F800000, 'the framebuffer''s address');
  CheckNumber(Framebuffer.Width, 1920, 'the framebuffer''s width');
  CheckNumber(Framebuffer.Height, 1080, 'the framebuffer''s height');
  CheckNumber(Framebuffer.StrideInBytes, 3840, 'the framebuffer''s stride');
  CheckNumber(Framebuffer.BitsPerPixel, 16, 'the framebuffer''s depth');
end;

procedure TestAddresses;
var
  Node: LongInt;
  Physical: QWord;
  Size: QWord;
  Child: TDeviceTreeAddress;
  BusStart: QWord;
  Bus: LongInt;
begin
  Node := FindNodeByPath(Tree^, '/memory');
  CheckNumber(RegisterCount(Tree^, Node), 2, 'the memory entries');
  Check(NodeRegisterPhysical(Tree^, Node, 1, Physical, Size), 'the second memory entry');
  CheckNumber(Physical, $40000000, 'the second memory entry''s start');
  CheckNumber(Size, $1C0000000, 'the second memory entry''s size');

  Node := FindNodeByPath(Tree^, '/axi/mmc');
  Check(NodeRegisterPhysical(Tree^, Node, 1, Physical, Size), 'the SD controller''s second range');
  CheckNumber(Physical, $1000FFF400, 'the SD controller''s second range''s address');
  Bus := FindDmaRangesBus(Tree^, Node);
  Check(DeviceTreeTextIsEqual(NodeName(Tree^, Bus), 'axi'), 'the SD controller''s DMA bus');
  Check(ReadDmaRange(Tree^, Bus, 0, BusStart, Physical, Size) and (BusStart = 0) and (Physical = 0) and
    (Size = QWord($1000000000)), 'the SD controller''s DMA window');
  Check(not NodeIsDmaCoherent(Tree^, Node), 'the SD controller does not snoop');

  Node := FindNodeByPath(Tree^, '/axi/pcie@1000120000');
  Check(NodeRegisterPhysical(Tree^, Node, 0, Physical, Size) and (Physical = $1000120000),
    'the PCIe root complex''s registers');
  Check(ReadRangeEntry(Tree^, Node, 0, Child, Physical, Size), 'the root complex''s first window');
  CheckNumber(PciAddressSpace(Child), PciSpaceMemory32, 'the first window''s space');
  CheckNumber(AddressValue(Child), 0, 'the first window''s bus address');
  CheckNumber(Physical, $1F00000000, 'the first window''s address');
  CheckNumber(Size, $FFFFFFFC, 'the first window''s size');
  Check(ReadRangeEntry(Tree^, Node, 1, Child, Physical, Size), 'the root complex''s second window');
  CheckNumber(PciAddressSpace(Child), PciSpaceMemory64, 'the second window''s space');
  CheckNumber(AddressValue(Child), $400000000, 'the second window''s bus address');
  CheckNumber(Physical, $1C00000000, 'the second window''s address');
  Check(not NodeIsDmaCoherent(Tree^, Node), 'the root complex does not snoop');
  Check(ReadDmaRange(Tree^, Node, 0, BusStart, Physical, Size) and (BusStart = 0) and
    (Physical = $1F00000000) and (Size = $400000), 'the root complex''s inbound window onto RP1');
  Check(ReadDmaRange(Tree^, Node, 1, BusStart, Physical, Size) and (BusStart = $1000000000) and
    (Physical = 0) and (Size = $1000000000), 'the root complex''s inbound window onto RAM');
  Check(ReadDmaRange(Tree^, Node, 2, BusStart, Physical, Size) and (BusStart = $FFFFFFF000) and
    (Physical = $1000130000) and (Size = $1000), 'the root complex''s inbound window onto the MIP');
  Check(not ReadDmaRange(Tree^, Node, 3, BusStart, Physical, Size), 'three inbound windows');
end;

procedure TestMachine;
var
  Gic: TDeviceTreeGic;
  Timer: TDeviceTreeTimer;
  Psci: TDeviceTreePsci;
  Affinities: array[0..7] of LongWord;
  IdleStates: array[0..3] of TDeviceTreeIdleState;
begin
  Check(DescribeDeviceTreeGic(Gic), 'the GIC');
  CheckNumber(Gic.Version, 2, 'the GIC version');
  CheckNumber(Gic.DistributorAddress, $107FFF9000, 'the distributor');
  CheckNumber(Gic.CpuInterfaceAddress, $107FFFA000, 'the CPU interface');
  CheckNumber(Gic.MessageFrameAddress, 0, 'no GICv2m frame');
  Check(DescribeDeviceTreeTimer(Timer), 'the timer');
  CheckNumber(Timer.Intid, 27, 'the virtual timer''s INTID');
  Check(Timer.LevelTriggered, 'the timer is level triggered');
  Check(DescribeDeviceTreePsci(Psci) and not Psci.UseHypervisorCall, 'PSCI by SMC');
  CheckNumber(Psci.CpuOnFunction, $C4000003, 'the CPU_ON function');
  CheckNumber(ListDeviceTreeProcessors(Affinities), 4, 'the processors');
  CheckNumber(Affinities[3], $300, 'the fourth processor''s affinity');
  CheckNumber(ListDeviceTreeIdleStates(IdleStates), 2, 'the idle states');
  CheckNumber(IdleStates[0].PowerState, 1, 'the standby state''s power state');
  CheckNumber(IdleStates[0].ExitLatencyMicroseconds, 40, 'its exit latency');
  CheckNumber(IdleStates[0].MinimumResidencyMicroseconds, 100, 'its minimum residency');
  Check(not IdleStates[0].StopsLocalTimer, 'its timer keeps running');
  CheckNumber(IdleStates[1].PowerState, $10000, 'the power-down state''s power state');
  Check(IdleStates[1].StopsLocalTimer, 'its timer stops');
end;

procedure TestInterrupts;
var
  Node: LongInt;
  Gic: TGicInterrupt;
  Interrupt: TDeviceTreeInterrupt;
begin
  Node := FindNodeByPath(Tree^, '/soc/serial');
  CheckNumber(NodeInterruptCount(Tree^, Node), 1, 'the UART''s interrupts');
  Check(NodeGicInterrupt(Tree^, Node, 0, Gic), 'the UART''s interrupt');
  CheckNumber(Gic.Intid, 32 + 121, 'the UART''s INTID');
  Check(Gic.LevelTriggered and not Gic.ActiveLow, 'the UART''s trigger');

  Node := FindNodeByPath(Tree^, '/soc/gpio');
  CheckNumber(NodeInterruptCount(Tree^, Node), 2, 'the extended interrupts');
  Check(ReadNodeInterrupt(Tree^, Node, 0, Interrupt) and (Interrupt.CellCount = 1) and
    (Interrupt.Cells[0] = 7), 'the interrupt of the second controller');
  Check(not NodeGicInterrupt(Tree^, Node, 0, Gic), 'that interrupt does not end at the GIC');
  Check(NodeGicInterrupt(Tree^, Node, 1, Gic) and (Gic.Intid = 32 + 244) and not Gic.LevelTriggered,
    'the extended interrupt at the GIC');
end;

procedure TestPci;
var
  Host: TDeviceTreePciHost;
  Gic: TGicInterrupt;
begin
  CheckNumber(DeviceTreePciHostCount, 1, 'the ECAM host bridges');
  Check(GetDeviceTreePciHost(0, Host), 'the ECAM host bridge');
  CheckNumber(Host.ConfigurationBase, $4010000000, 'the configuration space');
  CheckNumber(Host.EndBus, 255, 'the last bus');
  Check(Host.Coherent, 'the host bridge snoops');
  CheckNumber(Host.WindowCount, 3, 'the windows');
  CheckNumber(Host.Windows[0].Space, PciSpaceIo, 'the I/O window');
  CheckNumber(Host.Windows[0].PhysicalAddress, $3EFF0000, 'the I/O window''s address');
  CheckNumber(Host.Windows[1].BusAddress, $10000000, 'the 32-bit window');
  CheckNumber(Host.Windows[2].PhysicalAddress, $8000000000, 'the 64-bit window');
  Check(FindDeviceTreePciRoute(0, 0, 1, 0, Gic), 'slot 1 INTA');
  CheckNumber(Gic.Intid, 32 + 4, 'slot 1 INTA''s INTID');
  Check(FindDeviceTreePciRoute(0, 0, 5, 1, Gic), 'slot 5 INTB (masked to slot 1)');
  CheckNumber(Gic.Intid, 32 + 5, 'slot 5 INTB''s INTID');
  Check(not FindDeviceTreePciRoute(0, 0, 2, 0, Gic), 'slot 2 is not mapped');
end;

procedure TestRp1;
var
  Host: LongInt;
  Rp1: LongInt;
  Node: LongInt;
  Window: TRp1Window;
  Offset: QWord;
  Size: QWord;
  Physical: QWord;
  BusStart: QWord;
  Interrupt: TRp1Interrupt;
  PciHost: TDeviceTreePciHost;
  Address: TDeviceTreeAddress;
  Mip: LongInt;
  Bus: LongInt;
begin
  Host := FindNodeByPath(Tree^, '/axi/pcie@1000120000');
  DescribeDeviceTreePciHost(Host, 0, PciHost);
  CheckNumber(PciHost.Segment, 2, 'the RP1 host''s segment');
  CheckNumber(PciHost.ConfigurationBase, 0, 'the RP1 host is not ECAM');
  CheckNumber(PciHost.WindowCount, 2, 'the RP1 host''s windows');
  CheckNumber(PciHost.Windows[0].PhysicalAddress, $1F00000000, 'the RP1 host''s 32-bit window');
  Check(PciHost.Windows[1].Prefetchable, 'the 64-bit window is prefetchable');
  CheckNumber(DeviceTreePciHostCount, 1, 'the RP1 host is not an ECAM host');

  Mip := FindNodeByPhandle(Tree^, 4);
  Check(NodeIsCompatible(Tree^, Mip, 'brcm,bcm2712-mip'), 'msi-parent names the MIP');
  Check(ReadRegister(Tree^, Mip, 1, Address, Size) and (AddressValue(Address) = $FFFFFFF000) and
    (Size = $1000), 'the MIP''s doorbell as the PCI bus sees it');
  Check(NodeRegisterPhysical(Tree^, Mip, 0, Physical, Size) and (Physical = $1000130000), 'the MIP''s registers');

  Rp1 := FindRp1Node(Tree^, Host);
  Check(DeviceTreeTextIsEqual(NodeName(Tree^, Rp1), 'rp1'), 'the RP1 node');
  Check(FindRp1Node(Tree^, FindNodeByPath(Tree^, '/pcie@10000000')) = NoNode, 'no RP1 on the ECAM host');
  ReadRp1Window(Tree^, Rp1, Window);
  Check(Window.FromRanges, 'RP1''s window from its ranges');
  CheckNumber(Window.ChildBase, $C040000000, 'RP1''s window''s own address');
  CheckNumber(Window.PciAddress, 0, 'RP1''s window''s bus address');
  CheckNumber(Window.PciSpace, PciSpaceMemory32, 'RP1''s window''s space');
  CheckNumber(Window.Size, $410000, 'RP1''s window''s size');

  Node := FindNodeByPath(Tree^, '/axi/pcie@1000120000/rp1/ethernet@100000');
  Check(NodeIsWithin(Tree^, Node, Rp1), 'the Ethernet controller is RP1''s');
  Check(not NodeIsWithin(Tree^, Host, Rp1), 'the host is not RP1''s');
  Check(Rp1RegisterOffset(Tree^, Window, Node, 0, Offset, Size), 'the Ethernet controller''s registers');
  CheckNumber(Offset, $100000, 'the Ethernet controller''s offset in RP1''s window');
  CheckNumber(Size, $4000, 'the Ethernet controller''s register size');
  Check(NodeRegisterPhysical(Tree^, Node, 0, Physical, Size), 'the Ethernet controller through the ranges');
  CheckNumber(Physical, $1F00100000, 'the Ethernet controller''s address for the processor');
  CheckNumber(Rp1NodeInterruptCount(Tree^, Node), 1, 'the Ethernet controller''s interrupts');
  Check(ReadRp1Interrupt(Tree^, Window, Node, 0, Interrupt), 'the Ethernet controller''s interrupt');
  CheckNumber(Interrupt.Number, 6, 'the Ethernet controller''s RP1 interrupt');
  Check(Interrupt.LevelTriggered, 'the Ethernet controller''s interrupt is level triggered');
  Bus := FindDmaRangesBus(Tree^, Node);
  Check(Bus = Rp1, 'the Ethernet controller''s DMA goes through RP1''s dma-ranges');
  Check(ReadDmaRange(Tree^, Bus, 0, BusStart, Physical, Size) and (BusStart = $1000000000) and
    (Physical = 0) and (Size = $1000000000), 'RP1 sees RAM at 10_0000_0000');
  Check(ReadDmaRange(Tree^, Bus, 1, BusStart, Physical, Size) and (BusStart = $C040000000) and
    (Physical = $1F00000000), 'RP1 sees its own window');
  Check(not NodeIsDmaCoherent(Tree^, Node), 'RP1''s devices do not snoop');

  Node := FindNodeByPath(Tree^, '/axi/pcie@1000120000/rp1/usb@200000');
  Check(Rp1RegisterOffset(Tree^, Window, Node, 0, Offset, Size) and (Offset = $200000) and
    (Size = $100000), 'the USB controller''s registers');
  Check(ReadRp1Interrupt(Tree^, Window, Node, 0, Interrupt) and (Interrupt.Number = 31) and
    not Interrupt.LevelTriggered, 'the USB controller''s edge interrupt 31');

  Node := FindNodeByPath(Tree^, '/axi/pcie@1000120000/rp1/serial@30000');
  Check(ReadRp1Interrupt(Tree^, Window, Node, 0, Interrupt) and (Interrupt.Number = 25), 'the UART''s interrupt');
  Node := FindNodeByPath(Tree^, '/axi/pcie@1000120000/rp1/dsi@110000');
  Check(not NodeIsEnabled(Tree^, Node), 'the display controller is disabled');
  Node := FindNodeByPath(Tree^, '/axi/pcie@1000120000/rp1/sram@400000');
  Check(Rp1RegisterOffset(Tree^, Window, Node, 0, Offset, Size) and (Offset = $400000) and
    (Size = $10000), 'the shared memory, in BAR2''s part of the window');
  Node := FindNodeByPath(Tree^, '/axi/pcie@1000120000/rp1/sram@400000/shmem@ff00');
  Check(not Rp1RegisterOffset(Tree^, Window, Node, 0, Offset, Size), 'a grandchild is not read as RP1''s');
  Check(not ReadRp1Interrupt(Tree^, Window, FindNodeByPath(Tree^, '/soc/serial'), 0, Interrupt),
    'a GIC interrupt is not RP1''s');
end;

begin
  if ParamCount < 1 then
  begin
    WriteLn('usage: DeviceTreeTest <tree.dtb>');
    Halt(2);
  end;
  LoadBlob(ParamStr(1));
  Check(UseDeviceTree(@Blob[0]), 'the header');
  Tree := SystemDeviceTree;
  if DeviceTreeIsAvailable then
  begin
    TestStructure;
    TestChosen;
    TestAddresses;
    TestMachine;
    TestInterrupts;
    TestPci;
    TestRp1;
  end;
  if Failures > 0 then
  begin
    WriteLn('DEVICE TREE TEST FAILED: ', Failures, ' checks');
    Halt(1);
  end;
  WriteLn('DEVICE TREE TEST PASSED');
end.
