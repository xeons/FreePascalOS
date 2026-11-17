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
  Showing the pointer, without composing anything.

  On the screen the pointer is on, a display with a cursor of its own
  (virtio-gpu, DisplayCapabilityHardwareCursor) draws it: it is given
  the pointer's picture for that screen's scale (Server.Cursor, from the
  pointer pictures) when the shape or the scale changes, and the
  hotspot's place when it moves; nothing on the screen is drawn again.
  A picture larger than the device's cursor (above 200 %) is drawn by the
  server instead. Elsewhere the server draws it: its image is blended
  over the picture as the screen is presented (Server.Presentation), so
  a move presents the old and new places again from the back buffer. A
  picture hanging over the edge onto the next screen is drawn there by
  the server too. Each device's cursor is hidden while the pointer is
  on another screen.
}
unit Server.PointerPresenting;

{$mode objfpc}
{$H+}

interface

uses
  Server.Screen;

{ Puts the pointer where it is now, as it looks now (after composing). }
procedure PresentPointer;
{ How the screen is presented, for the log. }
function DescribePresentation(Screen: PScreen): string;

implementation

uses
  Abi.SystemCalls,
  Sys.Display,
  Drawing.Rectangles,
  Drawing.Surfaces,
  Server.Cursor,
  Server.Desktop,
  Server.Presentation;

function PictureFitsDevice(const Image: TSurface; HotspotX, HotspotY: LongInt): Boolean;
begin
  Result := (Image.Pixels <> nil) and (Image.Width <= DisplayCursorSize) and (Image.Height <= DisplayCursorSize) and
    (HotspotX >= 0) and (HotspotY >= 0) and (HotspotX < DisplayCursorSize) and (HotspotY < DisplayCursorSize);
end;

{ Image (Stride pixels a line) as the device's cursor; False if refused. }
function GiveDevicePicture(Screen: PScreen; const Image: TSurface; HotspotX, HotspotY: LongInt): Boolean;
var
  Pixels: array of LongWord;
  Row: LongInt;
begin
  SetLength(Pixels, Image.Width * Image.Height);
  for Row := 0 to Image.Height - 1 do
    Move(SurfaceLine(Image, Row)^, Pixels[Row * Image.Width], Image.Width * SizeOf(LongWord));
  Result := SetDisplayCursorImage(Screen^.Device, @Pixels[0], Image.Width, Image.Height, HotspotX, HotspotY) =
    ErrorNone;
end;

{ The picture (when it changed), the place and showing, told the device. }
function TellDeviceCursor(Screen: PScreen; const Image: TSurface; HotspotX, HotspotY: LongInt): Boolean;
var
  X: LongInt;
  Y: LongInt;
begin
  Result := False;
  if Screen^.HardwareCursorKey <> CursorPictureKey then
  begin
    if not GiveDevicePicture(Screen, Image, HotspotX, HotspotY) then
      Exit;
    Screen^.HardwareCursorKey := CursorPictureKey;
  end;
  X := PointerX - Screen^.Bounds.Left;
  Y := PointerY - Screen^.Bounds.Top;
  if (X <> Screen^.HardwareCursorX) or (Y <> Screen^.HardwareCursorY) then
  begin
    if MoveDisplayCursor(Screen^.Device, X, Y) <> ErrorNone then
      Exit;
    Screen^.HardwareCursorX := X;
    Screen^.HardwareCursorY := Y;
  end;
  if not Screen^.HardwareCursorShown then
  begin
    if ShowDisplayCursor(Screen^.Device, True) <> ErrorNone then
      Exit;
    Screen^.HardwareCursorShown := True;
  end;
  Result := True;
end;

{ Shows the device's cursor with the picture at the pointer; False if the
  device refused, which leaves the pointer to the server from then on. }
function UseDeviceCursor(Screen: PScreen; const Image: TSurface; HotspotX, HotspotY: LongInt): Boolean;
begin
  Result := TellDeviceCursor(Screen, Image, HotspotX, HotspotY);
  if not Result then
    Screen^.Device.Capabilities := Screen^.Device.Capabilities and not LongWord(DisplayCapabilityHardwareCursor);
end;

procedure HideDeviceCursor(Screen: PScreen);
begin
  if not Screen^.HardwareCursorShown then
    Exit;
  ShowDisplayCursor(Screen^.Device, False);
  Screen^.HardwareCursorShown := False;
end;

procedure PresentPointer;
var
  Image: TSurface;
  HotspotX: LongInt;
  HotspotY: LongInt;
  Place: TRectangle;
  Common: TRectangle;
  Target: PScreen;
  Screen: PScreen;
  Index: LongInt;
begin
  CursorPicture(Image, HotspotX, HotspotY);
  Place := MakeRectangle(PointerX - HotspotX, PointerY - HotspotY, Image.Width, Image.Height);
  Target := NearestScreen(PointerX, PointerY);
  for Index := 0 to ScreenCount - 1 do
  begin
    Screen := @Screens[Index];
    if (Screen = Target) and DisplayHasHardwareCursor(Screen^.Device) and
       PictureFitsDevice(Image, HotspotX, HotspotY) and UseDeviceCursor(Screen, Image, HotspotX, HotspotY) then
    begin
      RemoveSoftwareCursor(Screen);
      Continue;
    end;
    { Drawn by the server first, so the pointer never vanishes between. }
    if IntersectRectangles(Place, Screen^.Bounds, Common) then
      SetSoftwareCursor(Screen, Image, Place)
    else
      RemoveSoftwareCursor(Screen);
    HideDeviceCursor(Screen);
  end;
end;

function DescribePresentation(Screen: PScreen): string;
begin
  if DisplayNeedsFlush(Screen^.Device) then
    Result := 'damaged rectangles copied and flushed to the device'
  else
    Result := 'damaged rectangles copied to the framebuffer';
  if DisplayHasHardwareCursor(Screen^.Device) then
    Result := Result + ', hardware pointer'
  else
    Result := Result + ', software pointer';
end;

end.
