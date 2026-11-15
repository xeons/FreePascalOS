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
  Anti-aliased lines, alongside Drawing.Shapes' exact ones (which the
  crisp edges of the interface keep using).

  Ends are given as for DrawLine: (X, Y) is the centre of pixel (X, Y),
  here with fractions. A line runs from one end to the other with
  square ends there, so a line from one pixel's centre to another's
  covers half of each end pixel.

  Lines one pixel wide or thinner are drawn by Wu's algorithm: along
  the line, one pixel per step, shared between the two pixels across
  that the line's centre falls between, by how near it is to each (and
  the ends by how much of their pixel the line reaches). Thinner lines
  are the same, fainter. Wider ones are their outlines (a rectangle
  along the line) filled by the rasterizer (Drawing.Rasterizer), as are
  joined lines (AddLineStroke and AddRoundJoint build them up into one
  shape, so where pieces overlap nothing is blended twice).
}
unit Drawing.SmoothLines;

{$mode objfpc}

interface

uses
  Drawing.Colors,
  Drawing.Canvas,
  Drawing.Rasterizer;

procedure DrawSmoothLine(const Canvas: TCanvas; FromX, FromY, ToX, ToY, Width: Double; Color: TColor);
{ The outline of a line Width wide (centre coordinates, as above) added
  to Shape, clockwise. }
procedure AddLineStroke(var Shape: TCoverageShape; FromX, FromY, ToX, ToY, Width: Double);
{ A disc Width across at (X, Y) (centre coordinates) added to Shape,
  clockwise: rounds the corner where two strokes meet. }
procedure AddRoundJoint(var Shape: TCoverageShape; X, Y, Width: Double);

implementation

const
  { From a pixel centre to the edge of its square. }
  HalfPixel = 0.5;

function FloorOf(Value: Double): LongInt;
begin
  Result := Trunc(Value);
  if Result > Value then
    Dec(Result);
end;

function FractionOf(Value: Double): Double;
begin
  Result := Value - FloorOf(Value);
end;

{ One pixel at Strength (0 to 1) of the colour; across and along are
  swapped back for a steep line. }
procedure PlotPixel(const Canvas: TCanvas; Along, Across: LongInt; Steep: Boolean; Strength: Double;
  Color: TColor);
var
  X: LongInt;
  Y: LongInt;
  Opacity: LongInt;
begin
  if Steep then
  begin
    X := Across;
    Y := Along;
  end
  else
  begin
    X := Along;
    Y := Across;
  end;
  if Strength > 1 then
    Strength := 1;
  Opacity := Trunc(Strength * 255 + 0.5);
  if Opacity <= 0 then
    Exit;
  FillSpan(Canvas, Y + Canvas.OriginY, X + Canvas.OriginX, X + Canvas.OriginX + 1, FadeColor(Color, Byte(Opacity)));
end;

{ Wu's algorithm, every pixel's share times Strength. }
procedure DrawThinLine(const Canvas: TCanvas; FromX, FromY, ToX, ToY, Strength: Double; Color: TColor);
var
  Steep: Boolean;
  Swap: Double;
  Gradient: Double;
  EndAlong: LongInt;
  EndAcross: Double;
  Gap: Double;
  FirstAlong: LongInt;
  LastAlong: LongInt;
  Across: Double;
  Along: LongInt;
begin
  Steep := Abs(ToY - FromY) > Abs(ToX - FromX);
  if Steep then
  begin
    Swap := FromX;
    FromX := FromY;
    FromY := Swap;
    Swap := ToX;
    ToX := ToY;
    ToY := Swap;
  end;
  if FromX > ToX then
  begin
    Swap := FromX;
    FromX := ToX;
    ToX := Swap;
    Swap := FromY;
    FromY := ToY;
    ToY := Swap;
  end;
  if ToX = FromX then
  begin
    { A point: no length, nothing to cover. }
    Exit;
  end;
  Gradient := (ToY - FromY) / (ToX - FromX);
  { Both ends in one pixel column: the share is the length within it. }
  if FloorOf(FromX + HalfPixel) = FloorOf(ToX + HalfPixel) then
  begin
    EndAlong := FloorOf(FromX + HalfPixel);
    EndAcross := (FromY + ToY) / 2;
    Gap := ToX - FromX;
    PlotPixel(Canvas, EndAlong, FloorOf(EndAcross), Steep, (1 - FractionOf(EndAcross)) * Gap * Strength, Color);
    PlotPixel(Canvas, EndAlong, FloorOf(EndAcross) + 1, Steep, FractionOf(EndAcross) * Gap * Strength, Color);
    Exit;
  end;
  { The first end: its pixel column, covered from the end to the
    column's right edge. }
  EndAlong := FloorOf(FromX + HalfPixel);
  EndAcross := FromY + Gradient * (EndAlong - FromX);
  Gap := 1 - FractionOf(FromX + HalfPixel);
  PlotPixel(Canvas, EndAlong, FloorOf(EndAcross), Steep, (1 - FractionOf(EndAcross)) * Gap * Strength, Color);
  PlotPixel(Canvas, EndAlong, FloorOf(EndAcross) + 1, Steep, FractionOf(EndAcross) * Gap * Strength, Color);
  FirstAlong := EndAlong;
  Across := EndAcross + Gradient;
  { The last end, from the column's left edge to the end. }
  EndAlong := FloorOf(ToX + HalfPixel);
  EndAcross := ToY + Gradient * (EndAlong - ToX);
  Gap := FractionOf(ToX + HalfPixel);
  PlotPixel(Canvas, EndAlong, FloorOf(EndAcross), Steep, (1 - FractionOf(EndAcross)) * Gap * Strength, Color);
  PlotPixel(Canvas, EndAlong, FloorOf(EndAcross) + 1, Steep, FractionOf(EndAcross) * Gap * Strength, Color);
  LastAlong := EndAlong;
  { Every whole column between. }
  for Along := FirstAlong + 1 to LastAlong - 1 do
  begin
    PlotPixel(Canvas, Along, FloorOf(Across), Steep, (1 - FractionOf(Across)) * Strength, Color);
    PlotPixel(Canvas, Along, FloorOf(Across) + 1, Steep, FractionOf(Across) * Strength, Color);
    Across := Across + Gradient;
  end;
end;

procedure AddLineStroke(var Shape: TCoverageShape; FromX, FromY, ToX, ToY, Width: Double);
var
  Length: Double;
  NormalX: Double;
  NormalY: Double;
  Corners: array[0..3] of TPrecisePoint;
begin
  Length := Sqrt(Sqr(ToX - FromX) + Sqr(ToY - FromY));
  if (Length = 0) or (Width <= 0) then
    Exit;
  { Half the width across the line, to its left as it goes, so the
    corners in this order go round clockwise on the screen. }
  NormalX := (ToY - FromY) / Length * Width / 2;
  NormalY := -(ToX - FromX) / Length * Width / 2;
  { Centre coordinates to the rasterizer's, where a pixel's square
    starts at its number. }
  FromX := FromX + HalfPixel;
  FromY := FromY + HalfPixel;
  ToX := ToX + HalfPixel;
  ToY := ToY + HalfPixel;
  Corners[0] := PrecisePoint(FromX + NormalX, FromY + NormalY);
  Corners[1] := PrecisePoint(ToX + NormalX, ToY + NormalY);
  Corners[2] := PrecisePoint(ToX - NormalX, ToY - NormalY);
  Corners[3] := PrecisePoint(FromX - NormalX, FromY - NormalY);
  AddShapePolygon(Shape, Corners);
end;

procedure AddRoundJoint(var Shape: TCoverageShape; X, Y, Width: Double);
begin
  AddShapeEllipse(Shape, X + HalfPixel, Y + HalfPixel, Width / 2, Width / 2, True);
end;

procedure DrawSmoothLine(const Canvas: TCanvas; FromX, FromY, ToX, ToY, Width: Double; Color: TColor);
var
  Shape: TCoverageShape;
begin
  if Width <= 0 then
    Exit;
  if Width <= 1 then
  begin
    DrawThinLine(Canvas, FromX, FromY, ToX, ToY, Width, Color);
    Exit;
  end;
  BeginShape(Shape);
  AddLineStroke(Shape, FromX, FromY, ToX, ToY, Width);
  FillShape(Canvas, Shape, Color);
end;

end.
