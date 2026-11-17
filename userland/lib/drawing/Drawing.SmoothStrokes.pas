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
  Strokes with round ends: what a brush leaves, a line drawn with a
  thick round pen. A stroke runs through its points (centre
  coordinates, as Drawing.SmoothLines takes them: (X, Y) is the middle
  of pixel (X, Y)), Width wide, with a disc Width across at every point
  so its ends and corners are round. It is one shape, anti-aliased
  (Drawing.Rasterizer), so where its pieces overlap nothing is blended
  twice. A stroke of one point (or of points all in one place) is a
  dot.
}
unit Drawing.SmoothStrokes;

{$mode objfpc}

interface

uses
  Drawing.Colors,
  Drawing.Canvas,
  Drawing.Rasterizer;

{ The outline of the stroke added to Shape, clockwise. }
procedure AddRoundStroke(var Shape: TCoverageShape; const Points: array of TPrecisePoint; Width: Double);
procedure DrawSmoothRoundStroke(const Canvas: TCanvas; const Points: array of TPrecisePoint; Width: Double;
  Color: TColor);
{ A line with round ends. }
procedure DrawSmoothRoundLine(const Canvas: TCanvas; FromX, FromY, ToX, ToY, Width: Double; Color: TColor);
{ A dot Width across centred on (X, Y). }
procedure DrawSmoothDot(const Canvas: TCanvas; X, Y, Width: Double; Color: TColor);

implementation

uses
  Drawing.SmoothLines;

procedure AddRoundStroke(var Shape: TCoverageShape; const Points: array of TPrecisePoint; Width: Double);
var
  Index: LongInt;
begin
  if (Width <= 0) or (Length(Points) = 0) then
    Exit;
  AddRoundJoint(Shape, Points[0].X, Points[0].Y, Width);
  for Index := 1 to High(Points) do
  begin
    AddLineStroke(Shape, Points[Index - 1].X, Points[Index - 1].Y, Points[Index].X, Points[Index].Y, Width);
    AddRoundJoint(Shape, Points[Index].X, Points[Index].Y, Width);
  end;
end;

procedure DrawSmoothRoundStroke(const Canvas: TCanvas; const Points: array of TPrecisePoint; Width: Double;
  Color: TColor);
var
  Shape: TCoverageShape;
begin
  if (Width <= 0) or (Length(Points) = 0) then
    Exit;
  BeginShape(Shape);
  AddRoundStroke(Shape, Points, Width);
  FillShape(Canvas, Shape, Color);
end;

procedure DrawSmoothRoundLine(const Canvas: TCanvas; FromX, FromY, ToX, ToY, Width: Double; Color: TColor);
var
  Points: array[0..1] of TPrecisePoint;
begin
  Points[0] := PrecisePoint(FromX, FromY);
  Points[1] := PrecisePoint(ToX, ToY);
  DrawSmoothRoundStroke(Canvas, Points, Width, Color);
end;

procedure DrawSmoothDot(const Canvas: TCanvas; X, Y, Width: Double; Color: TColor);
var
  Points: array[0..0] of TPrecisePoint;
begin
  Points[0] := PrecisePoint(X, Y);
  DrawSmoothRoundStroke(Canvas, Points, Width, Color);
end;

end.
