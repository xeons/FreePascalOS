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
  A screen under QEMU when no firmware set one up: QEMU's ramfb device
  (-device ramfb) shows whatever memory the guest names in the fw_cfg
  file "etc/ramfb". With a native boot nobody else does that (on UEFI
  the firmware's GOP driver does), so the stub does, when the device
  tree has QEMU's fw_cfg ("qemu,fw-cfg-mmio") and fw_cfg has the file:
  it takes memory for a 1024 x 768 XRGB8888 screen (reserved: the
  kernel keeps it), writes the configuration with fw_cfg's DMA interface
  and describes the screen as the framebuffer. This is how the native
  boot's framebuffer path (the kernel's console, the display server) is
  tried in QEMU; on a Raspberry Pi the firmware's simple-framebuffer is
  used instead.

  The MMU is off here, so memory is uncached and QEMU sees every write.
}
unit Native.QemuFramebuffer;

{$mode objfpc}
{$pointermath on}

interface

uses
  Boot.Information,
  DeviceTree.Blob;

function SetUpQemuFramebuffer(constref Tree: TDeviceTree; var Framebuffer: TFramebufferInformation): Boolean;

implementation

uses
  DeviceTree.Addresses,
  Native.MemoryMap;

const
  RegisterData = 0;
  RegisterSelector = 8;
  RegisterDma = 16;
  ItemFileDirectory = $19;
  DirectoryEntrySize = 64;
  DirectoryNameOffset = 8;
  DirectoryNameLength = 56;
  MaximumDirectoryEntries = 512;

  DmaControlError = 1;
  DmaControlSelect = 8;
  DmaControlWrite = $10;
  MaximumDmaPolls = 10000000;

  ScreenWidth = 1024;
  ScreenHeight = 768;
  BytesPerPixel = 4;
  { DRM_FORMAT_XRGB8888, "XR24": blue, green, red, unused in memory. }
  FourCcXrgb8888 = $34325258;
  RamfbConfigurationSize = 28;

type
  TDmaAccess = record
    Control: LongWord;
    Length: LongWord;
    Address: QWord;
  end;

var
  Registers: QWord;

function SwapBytes32(Value: LongWord): LongWord;
begin
  Result := ((Value and $FF) shl 24) or ((Value and $FF00) shl 8) or ((Value shr 8) and $FF00) or (Value shr 24);
end;

function SwapBytes64(Value: QWord): QWord;
begin
  Result := (QWord(SwapBytes32(LongWord(Value))) shl 32) or SwapBytes32(LongWord(Value shr 32));
end;

procedure SelectItem(Key: Word);
begin
  PWord(Registers + RegisterSelector)^ := Word((Key shr 8) or (Key shl 8));
end;

function ReadDataByte: Byte;
begin
  Result := PByte(Registers + RegisterData)^;
end;

function ReadDataBigEndian(ByteCount: Integer): LongWord;
var
  Index: Integer;
begin
  Result := 0;
  for Index := 1 to ByteCount do
    Result := (Result shl 8) or ReadDataByte;
end;

{ The selector of file Name, or 0. }
function FindFile(Name: PChar): Word;
var
  Count: LongWord;
  Entry: LongWord;
  Selector: Word;
  Index: Integer;
  EntryName: array[0..DirectoryNameLength - 1] of Char;
begin
  Result := 0;
  SelectItem(ItemFileDirectory);
  Count := ReadDataBigEndian(4);
  if Count > MaximumDirectoryEntries then
    Exit;
  Entry := 0;
  while Entry < Count do
  begin
    ReadDataBigEndian(4);
    Selector := Word(ReadDataBigEndian(2));
    ReadDataBigEndian(2);
    for Index := 0 to DirectoryNameLength - 1 do
      EntryName[Index] := Char(ReadDataByte);
    EntryName[DirectoryNameLength - 1] := #0;
    if DeviceTreeTextIsEqual(@EntryName[0], Name) then
      Exit(Selector);
    Inc(Entry);
  end;
end;

{ Read through a call, so the loop below reads memory each time (QEMU
  clears the control word when the transfer is done). }
function ReadControl(Control: PLongWord): LongWord;
begin
  Result := SwapBytes32(Control^);
end;

function WriteFile(Selector: Word; Data: Pointer; Length: LongWord): Boolean;
var
  Access: TDmaAccess;
  Address: QWord;
  Polls: LongWord;
begin
  Access.Control := SwapBytes32((LongWord(Selector) shl 16) or DmaControlSelect or DmaControlWrite);
  Access.Length := SwapBytes32(Length);
  Access.Address := SwapBytes64(QWord(Data));
  Address := QWord(@Access);
  { Big endian; writing the low half starts the transfer. }
  PLongWord(Registers + RegisterDma)^ := SwapBytes32(LongWord(Address shr 32));
  PLongWord(Registers + RegisterDma + 4)^ := SwapBytes32(LongWord(Address));
  Polls := 0;
  while (ReadControl(@Access.Control) and not LongWord(DmaControlError)) <> 0 do
  begin
    Inc(Polls);
    if Polls > MaximumDmaPolls then
      Exit(False);
  end;
  Result := (ReadControl(@Access.Control) and DmaControlError) = 0;
end;

procedure PutBigEndian(Buffer: PByte; Offset: Integer; Value: QWord; ByteCount: Integer);
var
  Index: Integer;
begin
  for Index := ByteCount - 1 downto 0 do
  begin
    Buffer[Offset + Index] := Byte(Value);
    Value := Value shr 8;
  end;
end;

function SetUpQemuFramebuffer(constref Tree: TDeviceTree; var Framebuffer: TFramebufferInformation): Boolean;
var
  Node: LongInt;
  Size: QWord;
  Selector: Word;
  Screen: QWord;
  ScreenBytes: QWord;
  Configuration: array[0..31] of Byte;
begin
  Result := False;
  Node := FindCompatibleNode(Tree, NoNode, 'qemu,fw-cfg-mmio');
  if (Node = NoNode) or not NodeRegisterPhysical(Tree, Node, 0, Registers, Size) then
    Exit;
  Selector := FindFile('etc/ramfb');
  if Selector = 0 then
    Exit;
  ScreenBytes := QWord(ScreenWidth) * ScreenHeight * BytesPerPixel;
  Screen := AllocatePages(PagesFor(ScreenBytes), MemoryRegionReserved);
  if Screen = 0 then
    Exit;
  PutBigEndian(@Configuration[0], 0, Screen, 8);
  PutBigEndian(@Configuration[0], 8, FourCcXrgb8888, 4);
  PutBigEndian(@Configuration[0], 12, 0, 4);
  PutBigEndian(@Configuration[0], 16, ScreenWidth, 4);
  PutBigEndian(@Configuration[0], 20, ScreenHeight, 4);
  PutBigEndian(@Configuration[0], 24, ScreenWidth * BytesPerPixel, 4);
  if not WriteFile(Selector, @Configuration[0], RamfbConfigurationSize) then
    Exit;
  Framebuffer.PhysicalBase := Screen;
  Framebuffer.SizeInBytes := ScreenBytes;
  Framebuffer.Width := ScreenWidth;
  Framebuffer.Height := ScreenHeight;
  Framebuffer.PixelsPerScanLine := ScreenWidth;
  Framebuffer.PixelFormat := PixelFormatBlueGreenRed;
  Framebuffer.HasEdid := 0;
  Result := True;
end;

end.
