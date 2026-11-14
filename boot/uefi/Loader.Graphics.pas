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
  Result := True;
end;

end.
