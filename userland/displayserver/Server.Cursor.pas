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
  The mouse pointer: where it is, and its shape.

  Pointing devices move it by motion (relative) or position (absolute,
  0-65535 across the whole desktop, every screen side by side) events;
  it is in desktop pixels and stays on the screens, going from one to
  the next across their shared edge. Its shape (an arrow, resize arrows,
  a text beam... Server.PointerShapes) is its picture for the scale of
  the screen it is on (Server.PointerPictures: drawn in several sizes,
  the nearest used and scaled when none fits, blended by its alpha), so
  it is about the same size on every display. A shape without pictures
  is drawn from its small pattern, each of its pixels a square of
  PointerScale pixels (the scale rounded to a whole number). The
  hotspot is where the pointer is.
}
unit Server.Cursor;

{$mode objfpc}

interface

uses
  Drawing.Rectangles,
  Drawing.Canvas;

var
  PointerX: LongInt;
  PointerY: LongInt;

{ In the middle of the first screen. }
procedure InitializeCursor;
{ The shape's size for the scale of the screen it is on now (after a
  scale changed, or the screens moved: it is kept on them too). }
procedure FollowPointerScreen;
{ Moves by (DeltaX, DeltaY), or to an absolute position. }
procedure MovePointerBy(DeltaX, DeltaY: LongInt);
procedure MovePointerToPosition(X, Y: LongInt);
{ The shape drawn (Pointer*); the caller damages the old and new
  rectangles. }
function CursorShape: LongWord;
procedure SetCursorShape(Shape: LongWord);
{ Where the pointer is drawn (its pixels), for knowing what to redraw. }
function CursorRectangle: TRectangle;
procedure DrawCursor(const Canvas: TCanvas);

implementation

uses
  Abi.SystemCalls,
  Drawing.Colors,
  Windowing.Protocol,
  Image.Surfaces,
  Server.PointerShapes,
  Server.PointerPictures,
  Server.Screen,
  Server.Desktop;

const
  BlackColor = $FF000000;
  WhiteColor = $FFFFFFFF;

var
  PointerScale: LongInt;
  PointerScalePercent: LongInt;
  Shape: LongWord;

procedure FollowPointerScreen;
begin
  KeepPointOnScreens(PointerX, PointerY);
  PointerScalePercent := NearestScreen(PointerX, PointerY)^.ScalePercent;
  PointerScale := (PointerScalePercent + 50) div 100;
  if PointerScale < 1 then
    PointerScale := 1;
end;

procedure InitializeCursor;
begin
  PointerX := (Screens[0].Bounds.Left + Screens[0].Bounds.Right) div 2;
  PointerY := (Screens[0].Bounds.Top + Screens[0].Bounds.Bottom) div 2;
  FollowPointerScreen;
end;

procedure MovePointerBy(DeltaX, DeltaY: LongInt);
begin
  PointerX := PointerX + DeltaX;
  PointerY := PointerY + DeltaY;
  FollowPointerScreen;
end;

procedure MovePointerToPosition(X, Y: LongInt);
begin
  { Rounded to the nearest pixel. }
  PointerX := DesktopBounds.Left + LongInt((Int64(X) * (RectangleWidth(DesktopBounds) - 1) + InputPositionMaximum div 2) div
    InputPositionMaximum);
  PointerY := DesktopBounds.Top + LongInt((Int64(Y) * (RectangleHeight(DesktopBounds) - 1) + InputPositionMaximum div 2) div
    InputPositionMaximum);
  FollowPointerScreen;
end;

function CursorShape: LongWord;
begin
  Result := Shape;
end;

procedure SetCursorShape(Shape: LongWord);
begin
  if Shape >= PointerShapeCount then
    Shape := PointerArrow;
  Server.Cursor.Shape := Shape;
end;

function CursorRectangle: TRectangle;
var
  Pattern: ^TPointerPattern;
  Picture: TPointerPicture;
begin
  if PointerPictureFor(Shape, PointerScalePercent, Picture) then
    Exit(MakeRectangle(PointerX - Picture.HotspotX, PointerY - Picture.HotspotY, Picture.Image.Width,
      Picture.Image.Height));
  Pattern := @PointerPatterns[Shape];
  Result := MakeRectangle(PointerX - Pattern^.HotspotX * PointerScale, PointerY - Pattern^.HotspotY * PointerScale,
    Pattern^.Width * PointerScale, Pattern^.Height * PointerScale);
end;

procedure DrawCursor(const Canvas: TCanvas);
var
  Pattern: ^TPointerPattern;
  Bounds: TRectangle;
  Row: LongInt;
  Column: LongInt;
  Color: TColor;
  Picture: TPointerPicture;
begin
  if PointerPictureFor(Shape, PointerScalePercent, Picture) then
  begin
    DrawSurface(Canvas, ImageSurface(Picture.Image), MakeRectangle(0, 0, Picture.Image.Width, Picture.Image.Height),
      PointerX - Picture.HotspotX, PointerY - Picture.HotspotY, True, AlphaOpaque);
    Exit;
  end;
  Pattern := @PointerPatterns[Shape];
  Bounds := CursorRectangle;
  for Row := 0 to Pattern^.Height - 1 do
    for Column := 1 to Length(Pattern^.Rows[Row]) do
    begin
      case Pattern^.Rows[Row][Column] of
        PointerBlack: Color := BlackColor;
        PointerWhite: Color := WhiteColor;
      else
        Continue;
      end;
      FillRectangle(Canvas, MakeRectangle(Bounds.Left + (Column - 1) * PointerScale, Bounds.Top + Row * PointerScale,
        PointerScale, PointerScale), Color);
    end;
end;

end.
