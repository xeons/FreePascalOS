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
  The BCM2712's MIP (brcm,bcm2712-mip): the message interrupt receiver
  that pcie2's devices (RP1) write their MSI-X messages to, as Linux's
  irq-bcm2712-mip.c describes it.

  A device writes vector number N (plus "brcm,msi-offset") to the MIP's
  doorbell, which the PCIe bus sees at the address of the node's second
  "reg" entry (FF_FFFF_F000; pcie2's last inbound window turns it into
  the MIP's registers at 10_0013_0000). That raises GIC SPI
  "msi-ranges" base + offset + N, a rising edge. "msi-ranges" gives the
  GIC, the first SPI (128 for pcie2's MIP) and how many there are (64).

  Registers: raise 00h, clear 10h, edge/level per vector (20h/30h, low
  and high 32), host mask 40h/50h, VPU mask 60h/70h, status 80h/90h.
  Set up as Linux does: every vector edge triggered, unmasked for the
  host, masked for the VPU.

  Each vector connected becomes one global system interrupt (an edge
  SPI) through the interrupt routing; the PCI message controller of the
  host's segment (Io.PciMessageInterrupts) hands them out.
}
unit Drivers.Bcm2712Mip;

{$mode objfpc}
{$pointermath on}

interface

uses
  Kernel.Interrupts,
  Io.InterruptRouting;

type
  PMipController = ^TMipController;
  TMipController = record
    Node: LongInt;
    Registers: PByte;
    { Where devices write, as the PCI bus sees it. }
    Doorbell: QWord;
    FirstSpi: LongWord;
    Offset: LongWord;
    Count: LongWord;
    NextVector: LongWord;
  end;

{ Sets up the MIP of device tree node Node; nil (and a line saying why)
  if it cannot. }
function OpenMipController(Node: LongInt): PMipController;

{ A TPciMessageControllerConnect: a fresh vector of the MIP Controller,
  its SPI connected to Handler. }
function ConnectMipVector(Controller: Pointer; Handler: TInterruptHandler; Context: Pointer;
  out Message: TInterruptMessage): Boolean;

implementation

uses
  Runtime.Atomic,
  Memory.KernelHeap,
  Memory.DeviceMapping,
  DeviceTree.Blob,
  DeviceTree.Addresses,
  Firmware.DeviceTree,
  Firmware.DeviceTreeInterrupts,
  Debug.Output;

const
  MipRegisterBytes = $C0;
  MipConfigLow = $20;
  MipConfigHigh = $30;
  MipHostMaskLow = $40;
  MipHostMaskHigh = $50;
  MipVpuMaskLow = $60;
  MipVpuMaskHigh = $70;
  FirstSharedIntid = 32;

procedure WriteMip(Controller: PMipController; Offset: LongWord; Value: LongWord);
begin
  FullMemoryBarrier;
  PLongWord(Controller^.Registers + Offset)^ := Value;
end;

procedure ReportMip(Node: LongInt; Text: PChar);
begin
  DebugBeginMessage;
  DebugWriteTag('mip');
  DebugWrite(NodeName(SystemDeviceTree^, Node));
  DebugWrite(': ');
  DebugWriteLine(Text);
  DebugEndMessage;
end;

{ "msi-ranges": the GIC's phandle, its specifier (first SPI), the count. }
function ReadMessageRange(Node: LongInt; out FirstSpi, Count: LongWord): Boolean;
var
  Tree: PDeviceTree;
  Prop: TDeviceTreeProperty;
  Parent: LongInt;
  Cells: LongWord;
begin
  FirstSpi := 0;
  Count := 0;
  Result := False;
  Tree := SystemDeviceTree;
  if not FindProperty(Tree^, Node, 'msi-ranges', Prop) or (PropertyCellCount(Prop) < 3) then
    Exit;
  Parent := FindNodeByPhandle(Tree^, PropertyCell(Prop, 0));
  Cells := InterruptCellsOf(Tree^, Parent);
  if (Cells < 2) or (PropertyCellCount(Prop) < Cells + 2) then
    Exit;
  FirstSpi := PropertyCell(Prop, 2);
  Count := PropertyCell(Prop, Cells + 1);
  Result := Count > 0;
end;

function OpenMipController(Node: LongInt): PMipController;
var
  Tree: PDeviceTree;
  Controller: PMipController;
  Physical: QWord;
  Size: QWord;
  Address: TDeviceTreeAddress;
begin
  Result := nil;
  Tree := SystemDeviceTree;
  Controller := PMipController(AllocateZeroedKernelMemory(SizeOf(TMipController)));
  if Controller = nil then
    Exit;
  Controller^.Node := Node;
  if not ReadMessageRange(Node, Controller^.FirstSpi, Controller^.Count) then
  begin
    ReportMip(Node, 'FAILED: no usable msi-ranges');
    Exit;
  end;
  if not ReadCellProperty(Tree^, Node, 'brcm,msi-offset', Controller^.Offset) then
    Controller^.Offset := 0;
  if not ReadRegister(Tree^, Node, 1, Address, Size) then
  begin
    ReportMip(Node, 'FAILED: no doorbell (second reg entry)');
    Exit;
  end;
  Controller^.Doorbell := AddressValue(Address);
  if not NodeRegisterPhysical(Tree^, Node, 0, Physical, Size) then
  begin
    ReportMip(Node, 'FAILED: its registers do not translate');
    Exit;
  end;
  Controller^.Registers := PByte(MapDeviceMemory(Physical, MipRegisterBytes));
  if Controller^.Registers = nil then
  begin
    ReportMip(Node, 'FAILED: its registers could not be mapped');
    Exit;
  end;
  WriteMip(Controller, MipHostMaskLow, 0);
  WriteMip(Controller, MipHostMaskHigh, 0);
  WriteMip(Controller, MipVpuMaskLow, $FFFFFFFF);
  WriteMip(Controller, MipVpuMaskHigh, $FFFFFFFF);
  WriteMip(Controller, MipConfigLow, $FFFFFFFF);
  WriteMip(Controller, MipConfigHigh, $FFFFFFFF);

  DebugBeginMessage;
  DebugWriteTag('mip');
  DebugWrite(NodeName(Tree^, Node));
  DebugWrite(': ');
  DebugWriteDecimal(Controller^.Count);
  DebugWrite(' vectors on SPIs ');
  DebugWriteDecimal(Controller^.FirstSpi + Controller^.Offset);
  DebugWrite('-');
  DebugWriteDecimal(Controller^.FirstSpi + Controller^.Offset + Controller^.Count - 1);
  DebugWrite(', doorbell 0x');
  DebugWriteHex(Controller^.Doorbell, 1);
  DebugWrite(' (bus), registers 0x');
  DebugWriteHex(Physical, 1);
  DebugWriteLine('');
  DebugEndMessage;
  Result := Controller;
end;

function ConnectMipVector(Controller: Pointer; Handler: TInterruptHandler; Context: Pointer;
  out Message: TInterruptMessage): Boolean;
var
  Mip: PMipController;
  Vector: LongWord;
  Spi: LongWord;
begin
  Message.Address := 0;
  Message.Data := 0;
  Mip := PMipController(Controller);
  Result := False;
  if (Mip = nil) or (Mip^.NextVector >= Mip^.Count) then
    Exit;
  Vector := Mip^.NextVector;
  Spi := Mip^.FirstSpi + Mip^.Offset + Vector;
  if not ConnectGlobalInterrupt(Spi + FirstSharedIntid, False, False, Handler, Context) then
  begin
    DebugBeginMessage;
    DebugWriteTag('mip');
    DebugWrite('FAILED to connect SPI ');
    DebugWriteDecimal(Spi);
    DebugWriteLine(' (no free kernel vector?)');
    DebugEndMessage;
    Exit;
  end;
  Inc(Mip^.NextVector);
  Message.Address := Mip^.Doorbell;
  Message.Data := Mip^.Offset + Vector;
  Result := True;
end;

end.
