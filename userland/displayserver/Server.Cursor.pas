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
  0-65535 across the screen) events; it stays on the screen. Its shape
  (an arrow, resize arrows, a text beam... Server.PointerShapes) is
  drawn from a small pattern, each of its pixels a square of
  PointerScale pixels (the display's scale rounded to a whole number),
  so it is about the same size on every display; the pattern's hotspot
  is where the pointer is.
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

procedure InitializeCursor(ScreenWidth, ScreenHeight: LongInt; ScalePercent: LongWord);
{ The pattern's size for a new scale. }
procedure SetPointerScale(ScalePercent: LongWord);
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
  Server.PointerShapes;

const
  BlackColor = $FF000000;
  WhiteColor = $FFFFFFFF;

var
  ScreenWidth: LongInt;
  ScreenHeight: LongInt;
  PointerScale: LongInt;
  Shape: LongWord;

procedure InitializeCursor(ScreenWidth, ScreenHeight: LongInt; ScalePercent: LongWord);
begin
  Server.Cursor.ScreenWidth := ScreenWidth;
  Server.Cursor.ScreenHeight := ScreenHeight;
  SetPointerScale(ScalePercent);
  PointerX := ScreenWidth div 2;
  PointerY := ScreenHeight div 2;
end;

procedure SetPointerScale(ScalePercent: LongWord);
begin
  PointerScale := (LongInt(ScalePercent) + 50) div 100;
  if PointerScale < 1 then
    PointerScale := 1;
end;

procedure KeepOnScreen;
begin
  if PointerX < 0 then
    PointerX := 0;
  if PointerY < 0 then
    PointerY := 0;
  if PointerX >= ScreenWidth then
    PointerX := ScreenWidth - 1;
  if PointerY >= ScreenHeight then
    PointerY := ScreenHeight - 1;
end;

procedure MovePointerBy(DeltaX, DeltaY: LongInt);
begin
  PointerX := PointerX + DeltaX;
  PointerY := PointerY + DeltaY;
  KeepOnScreen;
end;

procedure MovePointerToPosition(X, Y: LongInt);
begin
  { Rounded to the nearest pixel. }
  PointerX := LongInt((Int64(X) * (ScreenWidth - 1) + InputPositionMaximum div 2) div InputPositionMaximum);
  PointerY := LongInt((Int64(Y) * (ScreenHeight - 1) + InputPositionMaximum div 2) div InputPositionMaximum);
  KeepOnScreen;
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
begin
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
begin
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
