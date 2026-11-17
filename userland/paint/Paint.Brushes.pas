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
  The marks the freehand tools leave as the pointer moves from one
  place to the next.

  The pencil draws exact one-pixel lines (Bresenham's steps). The brush
  is round and anti-aliased: a stroke Size across with round ends from
  one place to the next (centre coordinates, fractions kept, so it is
  smooth at any zoom). The eraser is a square Size pixels across
  stamped at every pixel of the way, in whole pixels. The airbrush
  sprays dots at random within a circle Size across; its random numbers
  come from a seed the caller keeps, so the same seed sprays the same.
}
unit Paint.Brushes;

{$mode objfpc}
{$H+}

interface

uses
  Drawing.Colors,
  Drawing.Rectangles,
  Drawing.Canvas;

const
  { Dots an airbrush puff sprays, per pixel of its size. }
  AirbrushDotsPerSize = 2;

procedure DrawPencilLine(const Canvas: TCanvas; FromX, FromY, ToX, ToY: LongInt; Color: TColor);
procedure DrawBrushLine(const Canvas: TCanvas; FromX, FromY, ToX, ToY: Double; Size: LongInt; Color: TColor);
{ The eraser's square around pixel (X, Y). }
function EraserSquare(X, Y, Size: LongInt): TRectangle;
procedure DrawEraserLine(const Canvas: TCanvas; FromX, FromY, ToX, ToY, Size: LongInt; Color: TColor);
{ One puff around pixel (X, Y). }
procedure SprayAirbrush(const Canvas: TCanvas; X, Y, Size: LongInt; Color: TColor; var Seed: LongWord);
{ The pixels a puff around (X, Y) can reach. }
function AirbrushExtent(X, Y, Size: LongInt): TRectangle;

implementation

uses
  Math,
  Drawing.Shapes,
  Drawing.SmoothStrokes;

procedure DrawPencilLine(const Canvas: TCanvas; FromX, FromY, ToX, ToY: LongInt; Color: TColor);
begin
  DrawLine(Canvas, FromX, FromY, ToX, ToY, Color);
end;

procedure DrawBrushLine(const Canvas: TCanvas; FromX, FromY, ToX, ToY: Double; Size: LongInt; Color: TColor);
begin
  DrawSmoothRoundLine(Canvas, FromX, FromY, ToX, ToY, Max(1, Size), Color);
end;

function EraserSquare(X, Y, Size: LongInt): TRectangle;
begin
  Size := Max(1, Size);
  Result := MakeRectangle(X - Size div 2, Y - Size div 2, Size, Size);
end;

procedure DrawEraserLine(const Canvas: TCanvas; FromX, FromY, ToX, ToY, Size: LongInt; Color: TColor);
var
  Steps: LongInt;
  Step: LongInt;
  X: LongInt;
  Y: LongInt;
begin
  Steps := Max(Abs(ToX - FromX), Abs(ToY - FromY));
  if Steps = 0 then
  begin
    FillRectangle(Canvas, EraserSquare(FromX, FromY, Size), Color);
    Exit;
  end;
  for Step := 0 to Steps do
  begin
    X := FromX + Round((ToX - FromX) * Step / Steps);
    Y := FromY + Round((ToY - FromY) * Step / Steps);
    FillRectangle(Canvas, EraserSquare(X, Y, Size), Color);
  end;
end;

{ The next random number from Seed (a linear congruential generator),
  0 to 65535. }
function NextRandom(var Seed: LongWord): LongWord;
begin
  Seed := LongWord((QWord(Seed) * 1103515245 + 12345) and $FFFFFFFF);
  Result := (Seed shr 16) and $FFFF;
end;

procedure SprayAirbrush(const Canvas: TCanvas; X, Y, Size: LongInt; Color: TColor; var Seed: LongWord);
var
  Radius: LongInt;
  Dot: LongInt;
  DeltaX: LongInt;
  DeltaY: LongInt;
begin
  Radius := Max(1, Size div 2);
  for Dot := 1 to Max(1, Size * AirbrushDotsPerSize) do
  begin
    { Points of the square around, those in the circle kept. }
    DeltaX := LongInt(NextRandom(Seed) mod LongWord(2 * Radius + 1)) - Radius;
    DeltaY := LongInt(NextRandom(Seed) mod LongWord(2 * Radius + 1)) - Radius;
    if DeltaX * DeltaX + DeltaY * DeltaY <= Radius * Radius then
      DrawPixel(Canvas, X + DeltaX, Y + DeltaY, Color);
  end;
end;

function AirbrushExtent(X, Y, Size: LongInt): TRectangle;
var
  Radius: LongInt;
begin
  Radius := Max(1, Size div 2);
  Result := MakeRectangle(X - Radius, Y - Radius, 2 * Radius + 1, 2 * Radius + 1);
end;

end.
