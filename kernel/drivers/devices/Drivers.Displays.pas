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
  Finding the displays, the console's first.

  The first display is the one the firmware showed the boot on: if a
  native driver knows its adapter (Drivers.BochsDisplay) it drives it
  and its modes can be changed; otherwise the firmware's framebuffer is
  used as it is, in the one mode the firmware set. Then every other
  adapter a native driver finds is a display of its own: the other Bochs
  devices, then each scanout of a virtio GPU (Drivers.VirtioGpu), which
  is the first display when the firmware left no framebuffer (its own
  graphics output on a virtio GPU only blits).
}
unit Drivers.Displays;

{$mode objfpc}

interface

uses
  Boot.Information;

procedure InitializeDisplays(const Framebuffer: TFramebufferInformation);

implementation

uses
  Abi.SystemCalls,
  Runtime.Memory,
  Drivers.DisplayDevice,
  Drivers.BochsDisplay,
  Drivers.NarrowFramebuffer,
  Drivers.VirtioGpu;

const
  BytesPerPixel = 4;

{ The firmware's framebuffer, without a driver: one mode, no changing it. }
procedure RegisterFirmwareDisplay(const Framebuffer: TFramebufferInformation);
var
  Adapter: TDisplayAdapter;
begin
  if (Framebuffer.PhysicalBase = 0) or (Framebuffer.Width = 0) then
    Exit;
  { 16 bits a pixel: through a 32-bit copy. }
  if Framebuffer.PixelFormat = PixelFormatRedGreenBlue565 then
  begin
    RegisterNarrowFramebufferDisplay(Framebuffer);
    Exit;
  end;
  ZeroMemory(@Adapter, SizeOf(Adapter));
  Adapter.FramebufferPhysical := Framebuffer.PhysicalBase;
  Adapter.Width := Framebuffer.Width;
  Adapter.Height := Framebuffer.Height;
  Adapter.Pitch := QWord(Framebuffer.PixelsPerScanLine) * BytesPerPixel;
  Adapter.FramebufferBytes := Adapter.Pitch * Framebuffer.Height;
  Adapter.MaximumWidth := Framebuffer.Width;
  Adapter.MaximumHeight := Framebuffer.Height;
  if Framebuffer.PixelFormat = PixelFormatRedGreenBlue then
    Adapter.PixelFormat := DisplayFormatRedGreenBlue
  else
    Adapter.PixelFormat := DisplayFormatBlueGreenRed;
  if Framebuffer.HasEdid <> 0 then
  begin
    CopyMemory(@Adapter.Edid[0], @Framebuffer.Edid[0], EdidBlockSize);
    Adapter.HasEdid := True;
  end;
  RegisterDisplay(Adapter);
end;

procedure InitializeDisplays(const Framebuffer: TFramebufferInformation);
begin
  if not RegisterBochsConsoleDisplay(Framebuffer) then
    RegisterFirmwareDisplay(Framebuffer);
  RegisterOtherBochsDisplays;
  RegisterVirtioGpuDisplays(Framebuffer);
end;

end.
