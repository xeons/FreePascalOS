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
  Flood fill: the area of like colour around a pixel, as a paint
  program's fill bucket takes it.

  The area is every pixel joined to the starting one through its four
  neighbours (left, right, above, below) whose colour is near enough to
  the starting pixel's: no channel (alpha included) more than Tolerance
  away (0 to 255; 0 is the very same colour). It is found a run at a
  time (a scanline fill: a run of the line, then the runs above and
  below it that touch it), with a mask of the pixels taken so none is
  looked at twice, so the time grows with the area, not its shape.

  FloodFill paints the area in a colour (replacing the pixels, alpha and
  all) and says what part of the image changed; FloodFillMask only finds
  it.
}
unit Image.FloodFill;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

uses
  SysUtils,
  Drawing.Colors,
  Drawing.Rectangles,
  Image.Model;

{ Whether First and Second differ by at most Tolerance in every
  channel. }
function ColorsAreNear(First, Second: TColor; Tolerance: Byte): Boolean;
{ The area around (X, Y): Image.Width x Image.Height bytes, 1 where the
  area is, 0 elsewhere; Bounds is the smallest rectangle holding it
  (empty, and the mask all 0, if (X, Y) is outside the image). }
function FloodFillMask(Image: TImage; X, Y: LongInt; Tolerance: Byte; out Bounds: TRectangle): TBytes;
{ Paints the area around (X, Y) in Color; the part changed (empty when
  nothing was). }
function FloodFill(Image: TImage; X, Y: LongInt; Color: TColor; Tolerance: Byte): TRectangle;
{ A percentage (0 to 100) as a tolerance. }
function ToleranceFromPercent(Percent: LongInt): Byte;

implementation

type
  TSeed = record
    X: LongInt;
    Y: LongInt;
  end;

function ColorsAreNear(First, Second: TColor; Tolerance: Byte): Boolean;
begin
  Result := (Abs(LongInt(AlphaOf(First)) - AlphaOf(Second)) <= Tolerance) and
    (Abs(LongInt(RedOf(First)) - RedOf(Second)) <= Tolerance) and
    (Abs(LongInt(GreenOf(First)) - GreenOf(Second)) <= Tolerance) and
    (Abs(LongInt(BlueOf(First)) - BlueOf(Second)) <= Tolerance);
end;

function ToleranceFromPercent(Percent: LongInt): Byte;
begin
  if Percent <= 0 then
    Exit(0);
  if Percent >= 100 then
    Exit(255);
  Result := (Percent * 255 + 50) div 100;
end;

function FloodFillMask(Image: TImage; X, Y: LongInt; Tolerance: Byte; out Bounds: TRectangle): TBytes;
var
  Seeds: array of TSeed;
  SeedCount: LongInt;
  Target: TColor;
  Width: LongInt;
  Height: LongInt;
  Mask: TBytes;

  function Takes(PixelX, PixelY: LongInt): Boolean;
  begin
    Result := (Mask[PtrUInt(PixelY) * PtrUInt(Width) + PtrUInt(PixelX)] = 0) and ColorsAreNear(Image.Line(PixelY)[PixelX], Target, Tolerance);
  end;

  procedure Push(SeedX, SeedY: LongInt);
  begin
    if SeedCount = Length(Seeds) then
      SetLength(Seeds, 2 * Length(Seeds) + 64);
    Seeds[SeedCount].X := SeedX;
    Seeds[SeedCount].Y := SeedY;
    Inc(SeedCount);
  end;

  { Seeds a run of takeable pixels from Left to Right on line Line. }
  procedure SeedRuns(Left, Right, Line: LongInt);
  var
    Column: LongInt;
    InRun: Boolean;
  begin
    if (Line < 0) or (Line >= Height) then
      Exit;
    InRun := False;
    for Column := Left to Right do
      if Takes(Column, Line) then
      begin
        if not InRun then
          Push(Column, Line);
        InRun := True;
      end
      else
        InRun := False;
  end;

var
  Seed: TSeed;
  Left: LongInt;
  Right: LongInt;
  Column: LongInt;
begin
  Mask := nil;
  Bounds := MakeRectangle(0, 0, 0, 0);
  Width := Image.Width;
  Height := Image.Height;
  SetLength(Mask, PtrUInt(Width) * PtrUInt(Height));
  if Length(Mask) > 0 then
    FillChar(Mask[0], Length(Mask), 0);
  Result := Mask;
  if (X < 0) or (Y < 0) or (X >= Width) or (Y >= Height) then
    Exit;
  Target := Image.Line(Y)[X];
  Bounds := MakeRectangle(X, Y, 1, 1);
  Seeds := nil;
  SeedCount := 0;
  Push(X, Y);
  while SeedCount > 0 do
  begin
    Dec(SeedCount);
    Seed := Seeds[SeedCount];
    if not Takes(Seed.X, Seed.Y) then
      Continue;
    { The whole run through the seed. }
    Left := Seed.X;
    while (Left > 0) and Takes(Left - 1, Seed.Y) do
      Dec(Left);
    Right := Seed.X;
    while (Right < Width - 1) and Takes(Right + 1, Seed.Y) do
      Inc(Right);
    for Column := Left to Right do
      Mask[PtrUInt(Seed.Y) * PtrUInt(Width) + PtrUInt(Column)] := 1;
    Bounds := BoundingRectangle(Bounds, MakeRectangle(Left, Seed.Y, Right - Left + 1, 1));
    SeedRuns(Left, Right, Seed.Y - 1);
    SeedRuns(Left, Right, Seed.Y + 1);
  end;
  Result := Mask;
end;

function FloodFill(Image: TImage; X, Y: LongInt; Color: TColor; Tolerance: Byte): TRectangle;
var
  Mask: TBytes;
  Line: PLongWord;
  Row: LongInt;
  Column: LongInt;
  Changed: Boolean;
begin
  Mask := FloodFillMask(Image, X, Y, Tolerance, Result);
  if RectangleIsEmpty(Result) then
    Exit;
  Changed := False;
  for Row := Result.Top to Result.Bottom - 1 do
  begin
    Line := Image.Line(Row);
    for Column := Result.Left to Result.Right - 1 do
      if Mask[PtrUInt(Row) * PtrUInt(Image.Width) + PtrUInt(Column)] <> 0 then
        if Line[Column] <> Color then
        begin
          Line[Column] := Color;
          Changed := True;
        end;
  end;
  if not Changed then
    Result := MakeRectangle(0, 0, 0, 0);
end;

end.
