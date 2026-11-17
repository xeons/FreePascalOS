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

  Its picture (CursorPicture) is not composed with the windows: the
  device draws it, or the server blends it over the picture as it
  presents (Server.PointerPresenting).
}
unit Server.Cursor;

{$mode objfpc}
{$pointermath on}

interface

uses
  Drawing.Rectangles,
  Drawing.Surfaces;

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
{ Where the pointer is drawn (its pixels). }
function CursorRectangle: TRectangle;
{ The pointer's picture now: straight alpha, kept by this unit (the same
  pixels for as long as the shape and the scale stay), and its hotspot. }
procedure CursorPicture(out Image: TSurface; out HotspotX, HotspotY: LongInt);
{ Different for every shape and scale CursorPicture draws, never 0. }
function CursorPictureKey: LongWord;

implementation

uses
  Abi.SystemCalls,
  Windowing.Protocol,
  Image.Surfaces,
  Server.PointerShapes,
  Server.PointerPictures,
  Server.Screen,
  Server.Desktop;

const
  BlackColor = $FF000000;
  WhiteColor = $FFFFFFFF;

type
  { A shape's pattern drawn at a whole number scale. }
  TDrawnPattern = record
    Image: TSurface;
    Scale: LongInt;
  end;

var
  PointerScale: LongInt;
  PointerScalePercent: LongInt;
  Shape: LongWord;
  DrawnPatterns: array[0..PointerShapeCount - 1] of TDrawnPattern;

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

function CursorPictureKey: LongWord;
begin
  Result := (Shape + 1) * 100000 + LongWord(PointerScalePercent);
end;

{ Each of the pattern's pixels a square of Scale pixels. }
procedure DrawPattern(const Pattern: TPointerPattern; Scale: LongInt; var Image: TSurface);
var
  Row: LongInt;
  Column: LongInt;
  Color: LongWord;
  Y: LongInt;
  X: LongInt;
  Line: PLongWord;
begin
  FreeSurface(Image);
  if not CreateSurface(Image, Pattern.Width * Scale, Pattern.Height * Scale, 0) then
    Exit;
  for Row := 0 to Pattern.Height - 1 do
    for Column := 1 to Length(Pattern.Rows[Row]) do
    begin
      case Pattern.Rows[Row][Column] of
        PointerBlack: Color := BlackColor;
        PointerWhite: Color := WhiteColor;
      else
        Continue;
      end;
      for Y := Row * Scale to (Row + 1) * Scale - 1 do
      begin
        Line := SurfaceLine(Image, Y);
        for X := (Column - 1) * Scale to Column * Scale - 1 do
          Line[X] := Color;
      end;
    end;
end;

procedure CursorPicture(out Image: TSurface; out HotspotX, HotspotY: LongInt);
var
  Picture: TPointerPicture;
  Drawn: ^TDrawnPattern;
begin
  if PointerPictureFor(Shape, PointerScalePercent, Picture) then
  begin
    Image := ImageSurface(Picture.Image);
    HotspotX := Picture.HotspotX;
    HotspotY := Picture.HotspotY;
    Exit;
  end;
  Drawn := @DrawnPatterns[Shape];
  if (Drawn^.Scale <> PointerScale) or (Drawn^.Image.Pixels = nil) then
  begin
    DrawPattern(PointerPatterns[Shape], PointerScale, Drawn^.Image);
    Drawn^.Scale := PointerScale;
  end;
  Image := Drawn^.Image;
  HotspotX := PointerPatterns[Shape].HotspotX * PointerScale;
  HotspotY := PointerPatterns[Shape].HotspotY * PointerScale;
end;

end.
