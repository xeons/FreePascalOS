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
  The Bochs display adapter (QEMU's standard VGA, secondary-vga and
  bochs-display, PCI 1234:1111): a native driver that sets its modes.

  Each such device is a display of its own. Its framebuffer is BAR 0
  (its size is the video memory); BAR 2 holds its registers: the EDID
  at the start, and from 0x500 the "DISPI" mode registers (resolution,
  depth, virtual size, offsets, enable), one 16-bit word each. The
  registers are reached through BAR 2 rather than the old I/O ports
  (0x1CE, 0x1CF) because bochs-display has no ports and two devices
  cannot share them.

  The device the firmware's framebuffer lies in is the console's display
  and keeps the mode the firmware set. Any other has no picture until a
  driver gives it one: it is set to the mode its EDID prefers (else
  1024x768). A mode is set with the display off: the depth (32 bits),
  the size, a virtual size of the same width (so the pitch is 4 bytes a
  pixel), no offsets, then on with the linear framebuffer (the memory is
  cleared). Reading the X and Y resolution with the "capabilities" bit
  set in the enable register gives the largest mode.

  Suspend to RAM: waking resets the devices (the standard VGA to text
  mode), and the firmware does not set the mode again, so the mode
  registers are read before suspending and written back after (the mode
  a program set is kept), with the memory kept; a VGA device's attribute
  controller is told to show the picture again; the console draws its
  screen again from its copy.
}
unit Drivers.BochsDisplay;

{$mode objfpc}

interface

uses
  Boot.Information;

{ Registers the Bochs device the firmware's framebuffer is in as the
  first display (the console's); False if there is none. }
function RegisterBochsConsoleDisplay(const Framebuffer: TFramebufferInformation): Boolean;
{ Registers every other Bochs device as a display, each set to a mode. }
procedure RegisterOtherBochsDisplays;

implementation

uses
  Abi.SystemCalls,
  Runtime.Memory,
  Memory.DeviceMapping,
  Io.Pci,
  Io.PowerManagement,
  Debug.Output,
  Debug.FramebufferConsole,
  Drivers.Edid,
  Drivers.DisplayDevice;

const
  BochsVendor = $1234;
  BochsDevice = $1111;
  FramebufferBar = 0;
  RegisterBar = 2;
  RegisterBytes = $1000;
  { Where the registers are in BAR 2. }
  EdidOffset = $000;
  VgaPortsOffset = $400;
  DispiOffset = $500;
  { DISPI registers. }
  DispiXResolution = 1;
  DispiYResolution = 2;
  DispiDepth = 3;
  DispiEnable = 4;
  DispiBank = 5;
  DispiVirtualWidth = 6;
  DispiVirtualHeight = 7;
  DispiXOffset = 8;
  DispiYOffset = 9;
  FirstSavedRegister = DispiXResolution;
  LastSavedRegister = DispiYOffset;
  EnableDisplay = $01;
  EnableCapabilities = $02;
  EnableLinearFramebuffer = $40;
  { Keep the framebuffer's contents when enabling. }
  EnableKeepMemory = $80;
  Depth = 32;
  BytesPerPixel = 4;
  { The VGA registers in BAR 2 are the ports from 0x3C0. }
  InputStatusPort = $03DA;
  AttributePort = $03C0;
  FirstVgaPort = $03C0;
  AttributePaletteSource = $20;
  VgaClass = $03;
  VgaCompatibleSubclass = $00;
  FallbackWidth = 1024;
  FallbackHeight = 768;
  MaximumBochsDisplays = 8;

type
  PBochsDisplay = ^TBochsDisplay;
  TBochsDisplay = record
    Pci: PPciDevice;
    Registers: PByte;
    HasVgaRegisters: Boolean;
    Saved: array[FirstSavedRegister..LastSavedRegister] of Word;
  end;

var
  BochsDisplays: array[0..MaximumBochsDisplays - 1] of TBochsDisplay;
  BochsDisplayCount: LongInt;
  PowerHandlerRegistered: Boolean;

{ --- Registers ---------------------------------------------------------------- }

function ReadDispi(Display: PBochsDisplay; Register: Word): Word;
begin
  Result := PWord(Display^.Registers + DispiOffset + Register * 2)^;
end;

procedure WriteDispi(Display: PBochsDisplay; Register, Value: Word);
begin
  PWord(Display^.Registers + DispiOffset + Register * 2)^ := Value;
end;

function ReadVgaPort(Display: PBochsDisplay; Port: Word): Byte;
begin
  Result := PByte(Display^.Registers + VgaPortsOffset + (Port - FirstVgaPort))^;
end;

procedure WriteVgaPort(Display: PBochsDisplay; Port: Word; Value: Byte);
begin
  PByte(Display^.Registers + VgaPortsOffset + (Port - FirstVgaPort))^ := Value;
end;

{ The VGA attribute controller blanks the screen until its palette
  address source bit is set (reading the status register first selects
  its index register). }
procedure UnblankVga(Display: PBochsDisplay);
begin
  if not Display^.HasVgaRegisters then
    Exit;
  ReadVgaPort(Display, InputStatusPort);
  WriteVgaPort(Display, AttributePort, AttributePaletteSource);
end;

procedure ReadLargestMode(Display: PBochsDisplay; out Width, Height: LongWord);
var
  Enable: Word;
begin
  { With the capabilities bit set the resolution registers read as the
    largest ones; the display stays on meanwhile. }
  Enable := ReadDispi(Display, DispiEnable);
  WriteDispi(Display, DispiEnable, Enable or EnableCapabilities);
  Width := ReadDispi(Display, DispiXResolution);
  Height := ReadDispi(Display, DispiYResolution);
  WriteDispi(Display, DispiEnable, Enable);
end;

function SetBochsMode(Adapter: PDisplayAdapter; Width, Height: LongWord; out Pitch: QWord): Boolean;
var
  Display: PBochsDisplay;
begin
  Display := PBochsDisplay(Adapter^.Context);
  Pitch := QWord(Width) * BytesPerPixel;
  WriteDispi(Display, DispiEnable, 0);
  WriteDispi(Display, DispiDepth, Depth);
  WriteDispi(Display, DispiXResolution, Word(Width));
  WriteDispi(Display, DispiYResolution, Word(Height));
  WriteDispi(Display, DispiBank, 0);
  WriteDispi(Display, DispiVirtualWidth, Word(Width));
  WriteDispi(Display, DispiVirtualHeight, Word(Height));
  WriteDispi(Display, DispiXOffset, 0);
  WriteDispi(Display, DispiYOffset, 0);
  WriteDispi(Display, DispiEnable, EnableDisplay or EnableLinearFramebuffer);
  UnblankVga(Display);
  Result := (ReadDispi(Display, DispiXResolution) = Width) and (ReadDispi(Display, DispiYResolution) = Height);
end;

{ --- Suspend to RAM ------------------------------------------------------------ }

procedure SaveModes(Context: Pointer);
var
  Index: LongInt;
  Register: Word;
begin
  for Index := 0 to BochsDisplayCount - 1 do
    for Register := FirstSavedRegister to LastSavedRegister do
      BochsDisplays[Index].Saved[Register] := ReadDispi(@BochsDisplays[Index], Register);
end;

procedure RestoreMode(Display: PBochsDisplay);
var
  Register: Word;
begin
  if (Display^.Saved[DispiEnable] and EnableDisplay) = 0 then
    Exit;
  WriteDispi(Display, DispiEnable, 0);
  for Register := FirstSavedRegister to LastSavedRegister do
    if Register <> DispiEnable then
      WriteDispi(Display, Register, Display^.Saved[Register]);
  WriteDispi(Display, DispiEnable, Display^.Saved[DispiEnable] or EnableKeepMemory);
  UnblankVga(Display);
end;

procedure RestoreModes(Context: Pointer);
var
  Index: LongInt;
begin
  for Index := 0 to BochsDisplayCount - 1 do
    RestoreMode(@BochsDisplays[Index]);
  DebugBeginMessage;
  ConsoleRedraw;
  DebugEndMessage;
end;

{ --- Finding and registering ---------------------------------------------------- }

function IsBochsDevice(Device: PPciDevice): Boolean;
begin
  Result := (Device^.VendorId = BochsVendor) and (Device^.DeviceId = BochsDevice);
end;

function IsTaken(Device: PPciDevice): Boolean;
var
  Index: LongInt;
begin
  for Index := 0 to BochsDisplayCount - 1 do
    if BochsDisplays[Index].Pci = Device then
      Exit(True);
  Result := False;
end;

{ Sets up the record for Device and fills what the adapter has from the
  device; nil if its BARs are not usable. }
function TakeDevice(Device: PPciDevice; out Adapter: TDisplayAdapter): PBochsDisplay;
var
  Framebuffer: TPciBar;
  Registers: TPciBar;
  Index: LongInt;
  Size: TEdidSize;
begin
  Result := nil;
  ZeroMemory(@Adapter, SizeOf(Adapter));
  if (BochsDisplayCount = MaximumBochsDisplays) or not PciReadBar(Device, FramebufferBar, Framebuffer) or
     Framebuffer.IsIoPort or (Framebuffer.PhysicalAddress = 0) or not PciReadBar(Device, RegisterBar, Registers) or
     Registers.IsIoPort or (Registers.PhysicalAddress = 0) or (Registers.SizeInBytes < RegisterBytes) then
    Exit;
  PciEnableDevice(Device, False);
  Result := @BochsDisplays[BochsDisplayCount];
  ZeroMemory(Result, SizeOf(Result^));
  Result^.Registers := PByte(MapDeviceMemory(Registers.PhysicalAddress, RegisterBytes));
  if Result^.Registers = nil then
    Exit(nil);
  Result^.Pci := Device;
  Result^.HasVgaRegisters := (Device^.ClassCode = VgaClass) and (Device^.Subclass = VgaCompatibleSubclass);
  Inc(BochsDisplayCount);
  Adapter.FramebufferPhysical := Framebuffer.PhysicalAddress;
  Adapter.FramebufferBytes := Framebuffer.SizeInBytes;
  Adapter.PixelFormat := DisplayFormatBlueGreenRed;
  Adapter.SetMode := @SetBochsMode;
  Adapter.Context := Result;
  ReadLargestMode(Result, Adapter.MaximumWidth, Adapter.MaximumHeight);
  { A byte at a time, as device registers are read. }
  for Index := 0 to EdidBlockSize - 1 do
    Adapter.Edid[Index] := PByte(Result^.Registers + EdidOffset + Index)^;
  Adapter.HasEdid := ParseEdid(@Adapter.Edid[0], Size);
  if not PowerHandlerRegistered then
  begin
    RegisterPowerHandler('Bochs display', PowerStageDevices, @SaveModes, @RestoreModes, nil);
    PowerHandlerRegistered := True;
  end;
end;

function HoldsFramebuffer(Device: PPciDevice; Physical: QWord): Boolean;
var
  Bar: TPciBar;
begin
  Result := PciReadBar(Device, FramebufferBar, Bar) and not Bar.IsIoPort and (Physical >= Bar.PhysicalAddress) and
    (Physical < Bar.PhysicalAddress + Bar.SizeInBytes);
end;

function RegisterBochsConsoleDisplay(const Framebuffer: TFramebufferInformation): Boolean;
var
  Index: LongInt;
  Device: PPciDevice;
  Adapter: TDisplayAdapter;
begin
  Result := False;
  if (Framebuffer.PhysicalBase = 0) or (Framebuffer.Width = 0) then
    Exit;
  for Index := 0 to PciDeviceCount - 1 do
  begin
    Device := PciDeviceAt(Index);
    if not IsBochsDevice(Device) or not HoldsFramebuffer(Device, Framebuffer.PhysicalBase) then
      Continue;
    if TakeDevice(Device, Adapter) = nil then
      Exit;
    { The firmware's mode, where it put it. }
    Adapter.FramebufferBytes := Adapter.FramebufferBytes - (Framebuffer.PhysicalBase - Adapter.FramebufferPhysical);
    Adapter.FramebufferPhysical := Framebuffer.PhysicalBase;
    Adapter.Width := Framebuffer.Width;
    Adapter.Height := Framebuffer.Height;
    Adapter.Pitch := QWord(Framebuffer.PixelsPerScanLine) * BytesPerPixel;
    if Framebuffer.PixelFormat = PixelFormatRedGreenBlue then
      Adapter.PixelFormat := DisplayFormatRedGreenBlue;
    if not Adapter.HasEdid and (Framebuffer.HasEdid <> 0) then
    begin
      CopyMemory(@Adapter.Edid[0], @Framebuffer.Edid[0], EdidBlockSize);
      Adapter.HasEdid := True;
    end;
    Exit(RegisterDisplay(Adapter));
  end;
end;

{ The mode a display without a picture starts in: what its EDID prefers. }
procedure ChooseFirstMode(const Adapter: TDisplayAdapter; out Width, Height: LongWord);
var
  Size: TEdidSize;
begin
  Width := FallbackWidth;
  Height := FallbackHeight;
  if Adapter.HasEdid and ParseEdid(@Adapter.Edid[0], Size) and (Size.PreferredWidth > 0) and
     (Size.PreferredHeight > 0) and (QWord(Size.PreferredWidth) * Size.PreferredHeight * BytesPerPixel <=
     Adapter.FramebufferBytes) and (Size.PreferredWidth <= Adapter.MaximumWidth) and
     (Size.PreferredHeight <= Adapter.MaximumHeight) then
  begin
    Width := Size.PreferredWidth;
    Height := Size.PreferredHeight;
  end;
end;

procedure RegisterOtherBochsDisplays;
var
  Index: LongInt;
  Device: PPciDevice;
  Adapter: TDisplayAdapter;
  Width: LongWord;
  Height: LongWord;
  Pitch: QWord;
begin
  for Index := 0 to PciDeviceCount - 1 do
  begin
    Device := PciDeviceAt(Index);
    if not IsBochsDevice(Device) or IsTaken(Device) then
      Continue;
    if TakeDevice(Device, Adapter) = nil then
      Continue;
    ChooseFirstMode(Adapter, Width, Height);
    if not SetBochsMode(@Adapter, Width, Height, Pitch) then
      Continue;
    Adapter.Width := Width;
    Adapter.Height := Height;
    Adapter.Pitch := Pitch;
    RegisterDisplay(Adapter);
  end;
end;

end.
