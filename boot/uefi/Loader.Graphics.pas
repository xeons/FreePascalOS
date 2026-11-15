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
  Discovers the framebuffer set up by the firmware's Graphics Output
  Protocol so the kernel can draw to the screen without a display driver.
}
unit Loader.Graphics;

{$mode objfpc}

interface

uses
  Uefi.Base,
  Boot.Information;

{ Fills Framebuffer with the current graphics mode. Returns False (and
  leaves Framebuffer zeroed) if no usable linear framebuffer exists. }
function DescribeFramebuffer(out Framebuffer: TFramebufferInformation): Boolean;

implementation

uses
  Runtime.Memory,
  Uefi.GraphicsOutput,
  Loader.Firmware;

{ Copies the display's EDID base block, active one first. }
procedure CopyEdid(var Framebuffer: TFramebufferInformation);
var
  Edid: PEfiEdidProtocol;
begin
  if EfiIsError(FirmwareBootServices^.LocateProtocol(@EdidActiveProtocolGuid, nil, @Edid)) and
     EfiIsError(FirmwareBootServices^.LocateProtocol(@EdidDiscoveredProtocolGuid, nil, @Edid)) then
    Exit;
  if (Edid = nil) or (Edid^.Edid = nil) or (Edid^.SizeOfEdid < EdidBlockSize) then
    Exit;
  CopyMemory(@Framebuffer.Edid[0], Edid^.Edid, EdidBlockSize);
  Framebuffer.HasEdid := 1;
end;

function DescribeFramebuffer(out Framebuffer: TFramebufferInformation): Boolean;
var
  Status: TEfiStatus;
  GraphicsOutput: PEfiGraphicsOutputProtocol;
  ModeInformation: PEfiGraphicsOutputModeInformation;
begin
  ZeroMemory(@Framebuffer, SizeOf(Framebuffer));
  Result := False;

  Status := FirmwareBootServices^.LocateProtocol(@GraphicsOutputProtocolGuid, nil,
    @GraphicsOutput);
  if EfiIsError(Status) then
    Exit;

  ModeInformation := GraphicsOutput^.Mode^.Information;

  case ModeInformation^.PixelFormat of
    EfiPixelRedGreenBlueReserved8BitPerColor:
      Framebuffer.PixelFormat := PixelFormatRedGreenBlue;
    EfiPixelBlueGreenRedReserved8BitPerColor:
      Framebuffer.PixelFormat := PixelFormatBlueGreenRed;
  else
    { Bit mask and blit-only modes are not supported yet. }
    Exit;
  end;

  Framebuffer.PhysicalBase := GraphicsOutput^.Mode^.FramebufferBase;
  Framebuffer.SizeInBytes := GraphicsOutput^.Mode^.FramebufferSize;
  Framebuffer.Width := ModeInformation^.HorizontalResolution;
  Framebuffer.Height := ModeInformation^.VerticalResolution;
  Framebuffer.PixelsPerScanLine := ModeInformation^.PixelsPerScanLine;
  CopyEdid(Framebuffer);
  Result := True;
end;

end.
