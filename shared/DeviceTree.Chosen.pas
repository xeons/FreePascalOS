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
  What a device tree's firmware says about the boot itself, mostly in
  /chosen:

  - "bootargs", the kernel options (a Raspberry Pi's firmware puts its
    own words first, then cmdline.txt);
  - "linux,initrd-start" and "linux,initrd-end", where the firmware put
    the initial RAM disk (config.txt "initramfs ... followkernel", QEMU
    -initrd): the system volume's image here;
  - "stdout-path", the console UART (a path or an alias, with options
    after ':'), described by its "compatible": a PL011 (QEMU, the
    Raspberry Pi 5's debug UART), or a 16550 with registers RegisterShift
    bits apart (the Pi 4's mini UART, DesignWare UARTs);
  - a "simple-framebuffer" (in /chosen or anywhere), the screen the
    firmware set up.

  Plain Pascal, shared by the native boot stub, the kernel and the host
  test.
}
unit DeviceTree.Chosen;

{$mode objfpc}
{$pointermath on}

interface

uses
  DeviceTree.Blob;

type
  TDeviceTreeUartKind = (DeviceTreeUartNone, DeviceTreeUartPl011, DeviceTreeUart16550);

  TDeviceTreeUart = record
    Kind: TDeviceTreeUartKind;
    Node: LongInt;
    PhysicalAddress: QWord;
    SizeInBytes: QWord;
    { 16550: register N is at N shl RegisterShift; accessed RegisterWidth
      bytes wide (1 or 4). }
    RegisterShift: LongWord;
    RegisterWidth: LongWord;
  end;

  TDeviceTreeFramebuffer = record
    Node: LongInt;
    PhysicalAddress: QWord;
    SizeInBytes: QWord;
    Width: LongWord;
    Height: LongWord;
    StrideInBytes: LongWord;
    BitsPerPixel: LongWord;
    { 32 bits per pixel: the bytes of a pixel in memory are blue, green,
      red (a8r8g8b8 and x8r8g8b8 on a little endian machine) rather than
      red, green, blue. 16 (r5g6b5): red in the top five bits. }
    IsBlueGreenRed: Boolean;
  end;

{ "bootargs" of /chosen, or nil. }
function ReadBootArguments(constref Tree: TDeviceTree): PChar;
{ The initial RAM disk's range [Start, End), if the firmware loaded one. }
function ReadInitrdRange(constref Tree: TDeviceTree; out StartAddress, EndAddress: QWord): Boolean;

{ The node "stdout-path" (or "linux,stdout-path") of /chosen names, or
  NoNode. }
function FindConsoleNode(constref Tree: TDeviceTree): LongInt;
{ Node as a UART the kernel drives (Kind = DeviceTreeUartNone if it is
  not one, or its registers cannot be translated). }
function DescribeUart(constref Tree: TDeviceTree; Node: LongInt; out Uart: TDeviceTreeUart): Boolean;
{ The console UART, or the first enabled PL011 if stdout-path names
  none. }
function FindConsoleUart(constref Tree: TDeviceTree; out Uart: TDeviceTreeUart): Boolean;

{ The first enabled simple-framebuffer in a format the kernel draws
  (32 bits per pixel, or r5g6b5). }
function FindSimpleFramebuffer(constref Tree: TDeviceTree; out Framebuffer: TDeviceTreeFramebuffer): Boolean;

implementation

uses
  DeviceTree.Addresses;

function ChosenNode(constref Tree: TDeviceTree): LongInt;
begin
  Result := FindChildNode(Tree, RootNode(Tree), 'chosen', 6);
end;

function ReadBootArguments(constref Tree: TDeviceTree): PChar;
begin
  Result := ReadTextProperty(Tree, ChosenNode(Tree), 'bootargs');
end;

{ A 32-bit or 64-bit address property. }
function ReadAddressProperty(constref Tree: TDeviceTree; Node: LongInt; Name: PChar; out Value: QWord): Boolean;
var
  Prop: TDeviceTreeProperty;
begin
  Value := 0;
  Result := False;
  if not FindProperty(Tree, Node, Name, Prop) then
    Exit;
  if Prop.Length = 4 then
    Value := ReadBigEndian32(Prop.Value)
  else if Prop.Length = 8 then
    Value := ReadBigEndian64(Prop.Value)
  else
    Exit;
  Result := True;
end;

function ReadInitrdRange(constref Tree: TDeviceTree; out StartAddress, EndAddress: QWord): Boolean;
var
  Chosen: LongInt;
begin
  Chosen := ChosenNode(Tree);
  Result := ReadAddressProperty(Tree, Chosen, 'linux,initrd-start', StartAddress) and
    ReadAddressProperty(Tree, Chosen, 'linux,initrd-end', EndAddress) and (EndAddress > StartAddress);
  if not Result then
  begin
    StartAddress := 0;
    EndAddress := 0;
  end;
end;

function FindConsoleNode(constref Tree: TDeviceTree): LongInt;
var
  Chosen: LongInt;
  Path: PChar;
begin
  Chosen := ChosenNode(Tree);
  Path := ReadTextProperty(Tree, Chosen, 'stdout-path');
  if Path = nil then
    Path := ReadTextProperty(Tree, Chosen, 'linux,stdout-path');
  Result := FindNodeByPath(Tree, Path);
end;

function DescribeUart(constref Tree: TDeviceTree; Node: LongInt; out Uart: TDeviceTreeUart): Boolean;
var
  Value: LongWord;
begin
  Uart.Kind := DeviceTreeUartNone;
  Uart.Node := Node;
  Uart.PhysicalAddress := 0;
  Uart.SizeInBytes := 0;
  Uart.RegisterShift := 0;
  Uart.RegisterWidth := 4;
  Result := False;
  if (Node = NoNode) or not NodeIsEnabled(Tree, Node) then
    Exit;
  if NodeIsCompatible(Tree, Node, 'arm,pl011') or NodeIsCompatible(Tree, Node, 'arm,sbsa-uart') then
    Uart.Kind := DeviceTreeUartPl011
  else if NodeIsCompatible(Tree, Node, 'brcm,bcm2835-aux-uart') then
  begin
    Uart.Kind := DeviceTreeUart16550;
    Uart.RegisterShift := 2;
  end
  else if NodeIsCompatible(Tree, Node, 'ns16550a') or NodeIsCompatible(Tree, Node, 'ns16550') or
          NodeIsCompatible(Tree, Node, 'snps,dw-apb-uart') then
  begin
    Uart.Kind := DeviceTreeUart16550;
    Uart.RegisterWidth := 1;
    if ReadCellProperty(Tree, Node, 'reg-shift', Value) then
      Uart.RegisterShift := Value;
    if ReadCellProperty(Tree, Node, 'reg-io-width', Value) then
      Uart.RegisterWidth := Value;
  end
  else
    Exit;
  if not NodeRegisterPhysical(Tree, Node, 0, Uart.PhysicalAddress, Uart.SizeInBytes) then
  begin
    Uart.Kind := DeviceTreeUartNone;
    Exit;
  end;
  Result := True;
end;

function FindConsoleUart(constref Tree: TDeviceTree; out Uart: TDeviceTreeUart): Boolean;
begin
  Result := DescribeUart(Tree, FindConsoleNode(Tree), Uart);
  if not Result then
    Result := DescribeUart(Tree, FindCompatibleNode(Tree, NoNode, 'arm,pl011'), Uart);
end;

{ The pixel format's name: the 32-bit ones and r5g6b5 (what a Raspberry
  Pi's firmware sets up unless config.txt asks for 32 bits). }
function DescribeFormat(Format: PChar; var Framebuffer: TDeviceTreeFramebuffer): Boolean;
begin
  Result := True;
  Framebuffer.BitsPerPixel := 32;
  if DeviceTreeTextIsEqual(Format, 'r5g6b5') then
    Framebuffer.BitsPerPixel := 16
  else if DeviceTreeTextIsEqual(Format, 'a8r8g8b8') or DeviceTreeTextIsEqual(Format, 'x8r8g8b8') then
    Framebuffer.IsBlueGreenRed := True
  else if DeviceTreeTextIsEqual(Format, 'a8b8g8r8') or DeviceTreeTextIsEqual(Format, 'x8b8g8r8') then
    Framebuffer.IsBlueGreenRed := False
  else
    Result := False;
end;

{ The framebuffer's memory. A firmware that puts the node in /chosen
  may give /chosen no "ranges": its reg is then a physical address. }
function FramebufferMemory(constref Tree: TDeviceTree; Node: LongInt; out Physical, Size: QWord): Boolean;
var
  Address: TDeviceTreeAddress;
begin
  Result := NodeRegisterPhysical(Tree, Node, 0, Physical, Size);
  if Result or (ParentNode(Tree, Node) <> ChosenNode(Tree)) then
    Exit;
  Result := ReadRegister(Tree, Node, 0, Address, Size);
  Physical := AddressValue(Address);
end;

function DescribeFramebufferNode(constref Tree: TDeviceTree; Node: LongInt;
  out Framebuffer: TDeviceTreeFramebuffer): Boolean;
begin
  Framebuffer.Node := Node;
  Framebuffer.PhysicalAddress := 0;
  Framebuffer.SizeInBytes := 0;
  Framebuffer.Width := 0;
  Framebuffer.Height := 0;
  Framebuffer.StrideInBytes := 0;
  Framebuffer.BitsPerPixel := 0;
  Framebuffer.IsBlueGreenRed := True;
  Result := NodeIsEnabled(Tree, Node) and
    FramebufferMemory(Tree, Node, Framebuffer.PhysicalAddress, Framebuffer.SizeInBytes) and
    ReadCellProperty(Tree, Node, 'width', Framebuffer.Width) and
    ReadCellProperty(Tree, Node, 'height', Framebuffer.Height) and
    ReadCellProperty(Tree, Node, 'stride', Framebuffer.StrideInBytes) and
    DescribeFormat(ReadTextProperty(Tree, Node, 'format'), Framebuffer) and
    (Framebuffer.Width > 0) and (Framebuffer.Height > 0) and
    (Framebuffer.StrideInBytes >= Framebuffer.Width * (Framebuffer.BitsPerPixel div 8)) and
    (QWord(Framebuffer.StrideInBytes) * Framebuffer.Height <= Framebuffer.SizeInBytes);
end;

function FindSimpleFramebuffer(constref Tree: TDeviceTree; out Framebuffer: TDeviceTreeFramebuffer): Boolean;
var
  Node: LongInt;
begin
  Node := FindCompatibleNode(Tree, NoNode, 'simple-framebuffer');
  while Node <> NoNode do
  begin
    if DescribeFramebufferNode(Tree, Node, Framebuffer) then
      Exit(True);
    Node := FindCompatibleNode(Tree, Node, 'simple-framebuffer');
  end;
  Framebuffer.Node := NoNode;
  Framebuffer.Width := 0;
  Result := False;
end;

end.
