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
  The Bochs display interface (QEMU's standard VGA and bochs-display,
  PCI 1234:1111): only what suspend to RAM needs.

  The firmware set the display mode at boot and the console draws into
  that framebuffer. Waking resets the device to VGA text mode, and the
  firmware does not set the mode again, so the mode registers (the
  "DISPI" interface: resolution, depth, virtual size, offsets, enable)
  are read before suspending and written back after, the VGA attribute
  controller is told to show the picture again, and the console draws
  the screen again from its copy.
}
unit Drivers.BochsDisplay;

{$mode objfpc}

interface

{ Registers the power handler if there is such a display. }
procedure InitializeBochsDisplay;

implementation

uses
  Hal.PortIo,
  Io.Pci,
  Io.PowerManagement,
  Debug.Output,
  Debug.FramebufferConsole;

const
  BochsVendor = $1234;
  BochsDevice = $1111;
  IndexPort = $01CE;
  DataPort = $01CF;
  { DISPI registers: X and Y resolution, depth, enable, bank, virtual
    width and height, X and Y offset. }
  FirstRegister = 1;
  LastRegister = 9;
  EnableRegister = 4;
  EnableDisplay = $01;
  { Keep the framebuffer's contents when enabling. }
  EnableKeepMemory = $80;
  InputStatusPort = $03DA;
  AttributePort = $03C0;
  AttributePaletteSource = $20;

var
  Saved: array[FirstRegister..LastRegister] of Word;

function ReadDispi(Register: Word): Word;
begin
  WritePortWord(IndexPort, Register);
  Result := ReadPortWord(DataPort);
end;

procedure WriteDispi(Register, Value: Word);
begin
  WritePortWord(IndexPort, Register);
  WritePortWord(DataPort, Value);
end;

procedure SaveMode(Context: Pointer);
var
  Register: Word;
begin
  for Register := FirstRegister to LastRegister do
    Saved[Register] := ReadDispi(Register);
end;

procedure RestoreMode(Context: Pointer);
var
  Register: Word;
begin
  if (Saved[EnableRegister] and EnableDisplay) = 0 then
    Exit;
  WriteDispi(EnableRegister, 0);
  for Register := FirstRegister to LastRegister do
    if Register <> EnableRegister then
      WriteDispi(Register, Saved[Register]);
  WriteDispi(EnableRegister, Saved[EnableRegister] or EnableKeepMemory);
  { The VGA attribute controller blanks the screen until its palette
    address source bit is set (reading the status register first
    selects its index register). }
  ReadPortByte(InputStatusPort);
  WritePortByte(AttributePort, AttributePaletteSource);
  DebugBeginMessage;
  ConsoleRedraw;
  DebugEndMessage;
end;

procedure InitializeBochsDisplay;
var
  Index: Integer;
  Device: PPciDevice;
begin
  for Index := 0 to PciDeviceCount - 1 do
  begin
    Device := PciDeviceAt(Index);
    if (Device^.VendorId = BochsVendor) and (Device^.DeviceId = BochsDevice) then
    begin
      RegisterPowerHandler('Bochs display', PowerStageDevices, @SaveMode, @RestoreMode, nil);
      Exit;
    end;
  end;
end;

end.
