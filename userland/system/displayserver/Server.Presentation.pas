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
  Presenting: putting what changed in a back buffer on the screen.

  Only the damaged rectangles are copied from the back buffer to the
  framebuffer (swapping red and blue for a display that keeps red in the
  low byte). The back buffer never holds the pointer: where the server
  draws it (a display without a cursor of its own, Server.PointerPresenting)
  its image is blended over the back buffer's pixels on the way, so
  moving it is presenting its old and new places again, with nothing
  composed. A display that needs flushing (virtio-gpu) is then told the
  rectangles copied (their bounding rectangle when there are many), so
  the device copies only those to the host.
}
unit Server.Presentation;

{$mode objfpc}
{$pointermath on}

interface

uses
  Drawing.Rectangles,
  Drawing.Regions,
  Drawing.Surfaces,
  Server.Screen;

{ Copies the part of Region (desktop pixels) on Screen to its display,
  with the server's pointer over it, and flushes it. }
procedure PresentScreenRegion(Screen: PScreen; const Region: TRegion);
{ Draws the pointer on Screen with Image at Place (desktop pixels), or
  takes it off when Place is empty; the old and new places are presented
  again. }
procedure SetSoftwareCursor(Screen: PScreen; const Image: TSurface; const Place: TRectangle);
procedure RemoveSoftwareCursor(Screen: PScreen);

implementation

uses
  Abi.SystemCalls,
  Sys.Display,
  Drawing.Colors;

const
  { More rectangles than this are flushed as the one around them. }
  MaximumFlushedRectangles = 8;

function SwapRedAndBlue(Pixel: LongWord): LongWord; inline;
begin
  Result := (Pixel and $FF00FF00) or ((Pixel and $FF) shl 16) or ((Pixel shr 16) and $FF);
end;

function FramebufferLine(Screen: PScreen; Y: LongInt): PLongWord;
begin
  Result := PLongWord(PByte(Screen^.Device.Pixels) + PtrUInt(Y) * Screen^.Device.Pitch);
end;

procedure CopyRows(Screen: PScreen; const Visible: TRectangle);
var
  Y: LongInt;
  X: LongInt;
  Source: PLongWord;
  Target: PLongWord;
begin
  for Y := Visible.Top to Visible.Bottom - 1 do
  begin
    Source := SurfaceLine(Screen^.BackBuffer, Y);
    Target := FramebufferLine(Screen, Y);
    if Screen^.Device.Format = DisplayFormatBlueGreenRed then
      Move(Source[Visible.Left], Target[Visible.Left], RectangleWidth(Visible) * SizeOf(LongWord))
    else
      for X := Visible.Left to Visible.Right - 1 do
        Target[X] := SwapRedAndBlue(Source[X]);
  end;
end;

{ The pointer over the back buffer's pixels, where Visible (the screen's
  pixels) meets it. }
procedure BlendCursor(Screen: PScreen; const Visible: TRectangle);
var
  Place: TRectangle;
  Common: TRectangle;
  Y: LongInt;
  X: LongInt;
  Back: PLongWord;
  Image: PLongWord;
  Target: PLongWord;
  Pixel: LongWord;
begin
  if RectangleIsEmpty(Screen^.SoftwareCursorPlace) or (Screen^.SoftwareCursorImage.Pixels = nil) then
    Exit;
  Place := OffsetRectangle(Screen^.SoftwareCursorPlace, -Screen^.Bounds.Left, -Screen^.Bounds.Top);
  if not IntersectRectangles(Place, Visible, Common) then
    Exit;
  for Y := Common.Top to Common.Bottom - 1 do
  begin
    Back := SurfaceLine(Screen^.BackBuffer, Y);
    Image := SurfaceLine(Screen^.SoftwareCursorImage, Y - Place.Top);
    Target := FramebufferLine(Screen, Y);
    for X := Common.Left to Common.Right - 1 do
    begin
      if (Image[X - Place.Left] shr 24) = 0 then
        Continue;
      Pixel := BlendColors(Back[X], Image[X - Place.Left]);
      if Screen^.Device.Format = DisplayFormatBlueGreenRed then
        Target[X] := Pixel
      else
        Target[X] := SwapRedAndBlue(Pixel);
    end;
  end;
end;

{ Presents Rectangle (desktop pixels); Visible is what of it is on the
  screen, in its pixels. False if nothing is. }
function PresentRectangle(Screen: PScreen; const Rectangle: TRectangle; out Visible: TRectangle): Boolean;
begin
  Result := IntersectRectangles(Rectangle, Screen^.Bounds, Visible);
  if not Result then
    Exit;
  Visible := OffsetRectangle(Visible, -Screen^.Bounds.Left, -Screen^.Bounds.Top);
  CopyRows(Screen, Visible);
  BlendCursor(Screen, Visible);
end;

procedure Flush(Screen: PScreen; const Rectangle: TRectangle);
begin
  FlushDisplay(Screen^.Device, Rectangle.Left, Rectangle.Top, RectangleWidth(Rectangle), RectangleHeight(Rectangle));
end;

procedure PresentScreenRegion(Screen: PScreen; const Region: TRegion);
var
  Index: LongInt;
  Visible: TRectangle;
  Around: TRectangle;
  AnyVisible: Boolean;
  FlushEach: Boolean;
begin
  FlushEach := DisplayNeedsFlush(Screen^.Device) and (Region.Count <= MaximumFlushedRectangles);
  AnyVisible := False;
  Around := MakeRectangle(0, 0, 0, 0);
  for Index := 0 to Region.Count - 1 do
  begin
    if not PresentRectangle(Screen, Region.Rectangles[Index], Visible) then
      Continue;
    if FlushEach then
      Flush(Screen, Visible)
    else if AnyVisible then
      Around := BoundingRectangle(Around, Visible)
    else
      Around := Visible;
    AnyVisible := True;
  end;
  if AnyVisible and not FlushEach and DisplayNeedsFlush(Screen^.Device) then
    Flush(Screen, Around);
end;

function SameSurface(const First, Second: TSurface): Boolean;
begin
  Result := (First.Pixels = Second.Pixels) and (First.Width = Second.Width) and (First.Height = Second.Height);
end;

function SameRectangle(const First, Second: TRectangle): Boolean;
begin
  Result := (First.Left = Second.Left) and (First.Top = Second.Top) and (First.Right = Second.Right) and
    (First.Bottom = Second.Bottom);
end;

procedure SetSoftwareCursor(Screen: PScreen; const Image: TSurface; const Place: TRectangle);
var
  Changed: TRegion;
begin
  if SameRectangle(Place, Screen^.SoftwareCursorPlace) and
     (RectangleIsEmpty(Place) or SameSurface(Image, Screen^.SoftwareCursorImage)) then
    Exit;
  ClearRegion(Changed);
  if not RectangleIsEmpty(Screen^.SoftwareCursorPlace) then
    AddRectangleToRegion(Changed, Screen^.SoftwareCursorPlace);
  if not RectangleIsEmpty(Place) then
    AddRectangleToRegion(Changed, Place);
  Screen^.SoftwareCursorImage := Image;
  Screen^.SoftwareCursorPlace := Place;
  PresentScreenRegion(Screen, Changed);
end;

procedure RemoveSoftwareCursor(Screen: PScreen);
var
  Nothing: TSurface;
begin
  FillChar(Nothing, SizeOf(Nothing), 0);
  SetSoftwareCursor(Screen, Nothing, MakeRectangle(0, 0, 0, 0));
end;

end.
