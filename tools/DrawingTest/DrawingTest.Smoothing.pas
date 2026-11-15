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
  The anti-aliased drawing and smooth scaling, checked: exact coverage
  where it can be worked out by hand (squares, half pixels, a diagonal),
  symmetry where a shape is symmetric, and the coverage adding up to the
  shape's area otherwise.

  Shapes are drawn in white on black, so a pixel's red is its coverage.
}
unit DrawingTest.Smoothing;

{$mode objfpc}
{$H+}

interface

procedure TestSmoothing;

implementation

uses
  SysUtils,
  Drawing.Colors,
  Drawing.Rectangles,
  Drawing.Surfaces,
  Drawing.Canvas,
  Drawing.Shapes,
  Drawing.Rasterizer,
  Drawing.SmoothLines,
  Drawing.SmoothShapes,
  Drawing.Scaling,
  DrawingTest.Checks;

{ A pixel's coverage, drawn white on black. }
function Coverage(const Surface: TSurface; X, Y: Integer): Integer;
begin
  Result := RedOf(GetSurfacePixel(Surface, X, Y));
end;

{ Every pixel's coverage added up, in pixels (255 is one). }
function TotalCoverage(const Surface: TSurface): Double;
var
  X: Integer;
  Y: Integer;
begin
  Result := 0;
  for Y := 0 to Surface.Height - 1 do
    for X := 0 to Surface.Width - 1 do
      Result := Result + Coverage(Surface, X, Y);
  Result := Result / 255;
end;

function Near(Got, Expected, Tolerance: Double): Boolean;
begin
  Result := Abs(Got - Expected) <= Tolerance;
end;

{ Whether the surface looks the same mirrored across, mirrored down and
  turned about its diagonal (when square), give or take one in 255. }
function IsSymmetric(const Surface: TSurface; Diagonal: Boolean): Boolean;
var
  X: Integer;
  Y: Integer;
  Value: Integer;
begin
  Result := True;
  for Y := 0 to Surface.Height - 1 do
    for X := 0 to Surface.Width - 1 do
    begin
      Value := Coverage(Surface, X, Y);
      if Abs(Value - Coverage(Surface, Surface.Width - 1 - X, Y)) > 1 then
        Result := False;
      if Abs(Value - Coverage(Surface, X, Surface.Height - 1 - Y)) > 1 then
        Result := False;
      if Diagonal and (Abs(Value - Coverage(Surface, Y, X)) > 1) then
        Result := False;
    end;
end;

function SquareOutline(Left, Top, Right, Bottom: Double; Clockwise: Boolean): TCoverageShape;
var
  Corners: array[0..3] of TPrecisePoint;
begin
  if Clockwise then
  begin
    Corners[0] := PrecisePoint(Left, Top);
    Corners[1] := PrecisePoint(Right, Top);
    Corners[2] := PrecisePoint(Right, Bottom);
    Corners[3] := PrecisePoint(Left, Bottom);
  end
  else
  begin
    Corners[0] := PrecisePoint(Left, Top);
    Corners[1] := PrecisePoint(Left, Bottom);
    Corners[2] := PrecisePoint(Right, Bottom);
    Corners[3] := PrecisePoint(Right, Top);
  end;
  BeginShape(Result);
  AddShapePolygon(Result, Corners);
end;

procedure TestRasterizer;
var
  Shape: TCoverageShape;
  Hole: TCoverageShape;
  Cells: array[0..63] of Byte;
  Expected: array[0..15] of Byte;
  Index: Integer;
  Matches: Boolean;
  Triangle: array[0..2] of TPrecisePoint;
  Surface: TSurface;
  Canvas: TCanvas;
begin
  { A square on whole pixels covers them fully, nothing else. }
  Shape := SquareOutline(1, 1, 3, 3, True);
  ShapeCoverage(Shape, MakeRectangle(0, 0, 4, 4), Cells);
  Matches := True;
  for Index := 0 to 15 do
    if (Index mod 4 in [1, 2]) and (Index div 4 in [1, 2]) then
      Matches := Matches and (Cells[Index] = 255)
    else
      Matches := Matches and (Cells[Index] = 0);
  Check('rasterizer: a square on whole pixels', Matches);
  { Half a pixel off: edges half covered, corners a quarter. }
  Shape := SquareOutline(0.5, 0.5, 2.5, 2.5, True);
  ShapeCoverage(Shape, MakeRectangle(0, 0, 3, 3), Cells);
  Check('rasterizer: half pixels and quarter corners', (Cells[0] = 64) and (Cells[1] = 128) and (Cells[2] = 64) and
    (Cells[3] = 128) and (Cells[4] = 255) and (Cells[5] = 128) and (Cells[6] = 64) and (Cells[8] = 64));
  { A right triangle: the pixels its long side cuts in half are half
    covered, those under it full, those over it empty. }
  Triangle[0] := PrecisePoint(0, 0);
  Triangle[1] := PrecisePoint(4, 0);
  Triangle[2] := PrecisePoint(0, 4);
  BeginShape(Shape);
  AddShapePolygon(Shape, Triangle);
  ShapeCoverage(Shape, MakeRectangle(0, 0, 4, 4), Cells);
  Matches := True;
  for Index := 0 to 15 do
    if Index mod 4 + Index div 4 < 3 then
      Matches := Matches and (Cells[Index] = 255)
    else if Index mod 4 + Index div 4 = 3 then
      Matches := Matches and (Cells[Index] = 128)
    else
      Matches := Matches and (Cells[Index] = 0);
  Check('rasterizer: a diagonal halves the pixels it crosses', Matches);
  { The same triangle given the other way round covers the same. }
  Triangle[1] := PrecisePoint(0, 4);
  Triangle[2] := PrecisePoint(4, 0);
  BeginShape(Shape);
  AddShapePolygon(Shape, Triangle);
  ShapeCoverage(Shape, MakeRectangle(0, 0, 4, 4), Expected);
  Matches := True;
  for Index := 0 to 15 do
    Matches := Matches and (Expected[Index] = Cells[Index]);
  Check('rasterizer: either direction covers the same', Matches);
  { An outline inside another going the other way is a hole; going the
    same way, the two join. }
  Shape := SquareOutline(0, 0, 4, 4, True);
  Hole := SquareOutline(1, 1, 3, 3, False);
  for Index := 0 to Hole.Count - 1 do
    AddShapeEdge(Shape, Hole.Edges[Index].FromX, Hole.Edges[Index].FromY, Hole.Edges[Index].ToX,
      Hole.Edges[Index].ToY);
  ShapeCoverage(Shape, MakeRectangle(0, 0, 4, 4), Cells);
  Check('rasterizer: an inner outline the other way is a hole', (Cells[0] = 255) and (Cells[5] = 0) and
    (Cells[10] = 0) and (Cells[15] = 255) and (Cells[4] = 255));
  Shape := SquareOutline(0, 0, 4, 4, True);
  Hole := SquareOutline(1, 1, 3, 3, True);
  for Index := 0 to Hole.Count - 1 do
    AddShapeEdge(Shape, Hole.Edges[Index].FromX, Hole.Edges[Index].FromY, Hole.Edges[Index].ToX,
      Hole.Edges[Index].ToY);
  ShapeCoverage(Shape, MakeRectangle(0, 0, 4, 4), Cells);
  Check('rasterizer: outlines the same way join', (Cells[0] = 255) and (Cells[5] = 255) and (Cells[10] = 255));
  { Drawn on a canvas, cut at its left and top: a triangle reaching
    off the surface still covers what is on it exactly (the edge
    crossing the left side is cut there). }
  Surface := NewSurface(4, 4, ColorBlack);
  BeginCanvas(Canvas, Surface);
  Triangle[0] := PrecisePoint(-2, 0);
  Triangle[1] := PrecisePoint(2, 0);
  Triangle[2] := PrecisePoint(-2, 4);
  BeginShape(Shape);
  AddShapePolygon(Shape, Triangle);
  FillShape(Canvas, Shape, ColorWhite);
  Check('rasterizer: cut at the surface''s side', (GetSurfacePixel(Surface, 0, 0) = ColorWhite) and
    (GetSurfacePixel(Surface, 1, 0) = $FF808080) and (GetSurfacePixel(Surface, 0, 1) = $FF808080) and
    (GetSurfacePixel(Surface, 1, 1) = ColorBlack) and (CountPixels(Surface, ColorBlack) = 13));
  { Clipped by the canvas like everything else. }
  FillRectangle(Canvas, SurfaceBounds(Surface), ColorBlack);
  NarrowCanvasClip(Canvas, MakeRectangle(0, 0, 2, 4));
  FillShape(Canvas, SquareOutline(0, 0, 4, 4, True), ColorWhite);
  Check('rasterizer: clipped', (CountPixels(Surface, ColorWhite) = 8) and (GetSurfacePixel(Surface, 2, 0) = ColorBlack));
  FreeSurface(Surface);
end;

procedure TestSmoothEllipses;
var
  Surface: TSurface;
  Canvas: TCanvas;
  Total: Double;
begin
  Surface := NewSurface(20, 20, ColorBlack);
  BeginCanvas(Canvas, Surface);
  FillSmoothEllipse(Canvas, MakeRectangle(0, 0, 20, 20), ColorWhite);
  Total := TotalCoverage(Surface);
  Check('smooth circle: coverage adds up to its area (' + FloatToStrF(Total, ffFixed, 8, 2) + ' of 314.16)',
    Near(Total, Pi * 100, 0.5));
  Check('smooth circle: symmetric', IsSymmetric(Surface, True));
  Check('smooth circle: full inside, empty at the corners', (Coverage(Surface, 10, 10) = 255) and
    (Coverage(Surface, 0, 0) = 0) and (Coverage(Surface, 19, 19) = 0) and (Coverage(Surface, 0, 10) > 0) and
    (Coverage(Surface, 0, 10) < 255));
  FillRectangle(Canvas, SurfaceBounds(Surface), ColorBlack);
  DrawSmoothEllipseOutline(Canvas, MakeRectangle(0, 0, 20, 20), 2, ColorWhite);
  Total := TotalCoverage(Surface);
  Check('smooth ring: coverage adds up to its area (' + FloatToStrF(Total, ffFixed, 8, 2) + ' of 113.10)',
    Near(Total, Pi * (100 - 64), 0.5));
  Check('smooth ring: symmetric, empty inside', IsSymmetric(Surface, True) and (Coverage(Surface, 10, 10) = 0) and
    (Coverage(Surface, 5, 10) = 0));
  FreeSurface(Surface);
  { An ellipse wider than high: symmetric across and down. }
  Surface := NewSurface(30, 12, ColorBlack);
  BeginCanvas(Canvas, Surface);
  FillSmoothEllipse(Canvas, MakeRectangle(0, 0, 30, 12), ColorWhite);
  Total := TotalCoverage(Surface);
  Check('smooth ellipse: symmetric, its area (' + FloatToStrF(Total, ffFixed, 8, 2) + ' of 282.74)',
    IsSymmetric(Surface, False) and Near(Total, Pi * 15 * 6, 0.5));
  FreeSurface(Surface);
end;

procedure TestSmoothLines;
var
  Surface: TSurface;
  Reversed: TSurface;
  Canvas: TCanvas;
  X: Integer;
  Y: Integer;
  Matches: Boolean;
  ColumnSum: Integer;
  Total: Double;
begin
  Surface := NewSurface(8, 6, ColorBlack);
  BeginCanvas(Canvas, Surface);
  { On a pixel row: the row full, the ends (pixel centres) half. }
  DrawSmoothLine(Canvas, 1, 2, 5, 2, 1, ColorWhite);
  Check('smooth line: level on a row, ends half covered', (Coverage(Surface, 1, 2) = 128) and
    (Coverage(Surface, 2, 2) = 255) and (Coverage(Surface, 4, 2) = 255) and (Coverage(Surface, 5, 2) = 128) and
    (Coverage(Surface, 3, 1) = 0) and (Coverage(Surface, 3, 3) = 0) and Near(TotalCoverage(Surface), 4, 0.01));
  FillRectangle(Canvas, SurfaceBounds(Surface), ColorBlack);
  { Between two rows: half of each. }
  DrawSmoothLine(Canvas, 1, 2.5, 5, 2.5, 1, ColorWhite);
  Check('smooth line: between rows, half in each', (Coverage(Surface, 3, 2) = 128) and (Coverage(Surface, 3, 3) = 128) and
    (Coverage(Surface, 3, 1) = 0) and (Coverage(Surface, 3, 4) = 0));
  FillRectangle(Canvas, SurfaceBounds(Surface), ColorBlack);
  { Upright the same, turned. }
  DrawSmoothLine(Canvas, 3, 1, 3, 4, 1, ColorWhite);
  Check('smooth line: upright', (Coverage(Surface, 3, 1) = 128) and (Coverage(Surface, 3, 2) = 255) and
    (Coverage(Surface, 3, 4) = 128) and (Coverage(Surface, 2, 2) = 0) and (Coverage(Surface, 4, 2) = 0));
  FreeSurface(Surface);
  { A shallow line: every column between the ends shared out to a whole
    pixel, the same whichever end comes first. }
  Surface := NewSurface(16, 8, ColorBlack);
  Reversed := NewSurface(16, 8, ColorBlack);
  BeginCanvas(Canvas, Surface);
  DrawSmoothLine(Canvas, 1, 1, 14, 5.3, 1, ColorWhite);
  BeginCanvas(Canvas, Reversed);
  DrawSmoothLine(Canvas, 14, 5.3, 1, 1, 1, ColorWhite);
  Matches := True;
  for X := 2 to 13 do
  begin
    ColumnSum := 0;
    for Y := 0 to 7 do
      ColumnSum := ColumnSum + Coverage(Surface, X, Y);
    Matches := Matches and (Abs(ColumnSum - 255) <= 1);
  end;
  Check('smooth line: a whole pixel a column', Matches);
  Matches := True;
  for Y := 0 to 7 do
    for X := 0 to 15 do
      Matches := Matches and (GetSurfacePixel(Surface, X, Y) = GetSurfacePixel(Reversed, X, Y));
  Check('smooth line: the same from either end', Matches);
  FreeSurface(Reversed);
  FreeSurface(Surface);
  { The diagonal of a square: symmetric about it. }
  Surface := NewSurface(12, 12, ColorBlack);
  BeginCanvas(Canvas, Surface);
  DrawSmoothLine(Canvas, 1, 1, 10, 10, 1, ColorWhite);
  Matches := True;
  for Y := 0 to 11 do
    for X := 0 to 11 do
      Matches := Matches and (Coverage(Surface, X, Y) = Coverage(Surface, Y, X)) and
        (Coverage(Surface, X, Y) = Coverage(Surface, 11 - Y, 11 - X));
  Check('smooth line: a diagonal is symmetric', Matches);
  FreeSurface(Surface);
  { Wide lines are their outlines filled: three wide on whole rows, and
    a diagonal two wide covering its length times its width. }
  Surface := NewSurface(16, 10, ColorBlack);
  BeginCanvas(Canvas, Surface);
  DrawSmoothLine(Canvas, 2, 5, 12, 5, 3, ColorWhite);
  Check('wide smooth line: three rows full, ends half', (Coverage(Surface, 6, 4) = 255) and
    (Coverage(Surface, 6, 5) = 255) and (Coverage(Surface, 6, 6) = 255) and (Coverage(Surface, 6, 3) = 0) and
    (Coverage(Surface, 6, 7) = 0) and (Coverage(Surface, 2, 5) = 128) and (Coverage(Surface, 12, 5) = 128) and
    Near(TotalCoverage(Surface), 30, 0.02));
  FreeSurface(Surface);
  Surface := NewSurface(16, 16, ColorBlack);
  BeginCanvas(Canvas, Surface);
  DrawSmoothLine(Canvas, 3, 3, 12, 12, 2, ColorWhite);
  Total := TotalCoverage(Surface);
  Check('wide smooth diagonal: its area (' + FloatToStrF(Total, ffFixed, 8, 2) + ' of 25.46)',
    Near(Total, Sqrt(2) * 9 * 2, 0.1));
  FreeSurface(Surface);
end;

procedure TestSmoothPolygons;
var
  Surface: TSurface;
  Exact: TSurface;
  Canvas: TCanvas;
  Corners: array[0..3] of TPrecisePoint;
  Whole: array[0..3] of TPoint;
  Matches: Boolean;
  X: Integer;
  Y: Integer;
begin
  { On whole pixels the smooth fill is the exact one. }
  Surface := NewSurface(12, 12, ColorBlack);
  Exact := NewSurface(12, 12, ColorBlack);
  Corners[0] := PrecisePoint(2, 3);
  Corners[1] := PrecisePoint(9, 3);
  Corners[2] := PrecisePoint(9, 8);
  Corners[3] := PrecisePoint(2, 8);
  Whole[0] := MakePoint(2, 3);
  Whole[1] := MakePoint(9, 3);
  Whole[2] := MakePoint(9, 8);
  Whole[3] := MakePoint(2, 8);
  BeginCanvas(Canvas, Surface);
  FillSmoothPolygon(Canvas, Corners, ColorWhite);
  BeginCanvas(Canvas, Exact);
  FillPolygon(Canvas, Whole, ColorWhite);
  Matches := True;
  for Y := 0 to 11 do
    for X := 0 to 11 do
      Matches := Matches and (GetSurfacePixel(Surface, X, Y) = GetSurfacePixel(Exact, X, Y));
  Check('smooth polygon: on whole pixels, the exact fill', Matches and (CountPixels(Surface, ColorWhite) = 35));
  { The outline through pixel centres, one wide: whole pixel rows and
    columns, corners included, nothing outside or inside. }
  BeginCanvas(Canvas, Surface);
  FillRectangle(Canvas, SurfaceBounds(Surface), ColorBlack);
  Corners[0] := PrecisePoint(2, 2);
  Corners[1] := PrecisePoint(9, 2);
  Corners[2] := PrecisePoint(9, 9);
  Corners[3] := PrecisePoint(2, 9);
  DrawSmoothPolygonOutline(Canvas, Corners, 1, ColorWhite);
  Matches := True;
  for X := 2 to 9 do
    Matches := Matches and (Coverage(Surface, X, 2) = 255) and (Coverage(Surface, X, 9) = 255) and
      (Coverage(Surface, 2, X) = 255) and (Coverage(Surface, 9, X) = 255) and (Coverage(Surface, X, 1) = 0) and
      (Coverage(Surface, X, 10) = 0);
  Check('smooth polygon outline: whole edges and corners', Matches and (Coverage(Surface, 5, 5) = 0) and
    (Coverage(Surface, 1, 1) = 0) and IsSymmetric(Surface, True));
  FreeSurface(Exact);
  FreeSurface(Surface);
end;

procedure TestSmoothScaling;
var
  Source: TSurface;
  Surface: TSurface;
  Canvas: TCanvas;
  Matches: Boolean;
  X: Integer;
  Y: Integer;
begin
  { The same size: an exact copy. }
  Source := NewSurface(3, 2, $FF102030);
  SetSurfacePixel(Source, 1, 0, $80FF0000);
  SetSurfacePixel(Source, 2, 1, $FF00FF00);
  Surface := NewSurface(3, 2, ColorTransparent);
  BeginCanvas(Canvas, Surface);
  DrawSurfaceScaled(Canvas, Source, SurfaceBounds(Source), SurfaceBounds(Surface), False);
  Matches := True;
  for Y := 0 to 1 do
    for X := 0 to 2 do
      Matches := Matches and (GetSurfacePixel(Surface, X, Y) = GetSurfacePixel(Source, X, Y));
  Check('smooth scaling: the same size is a copy', Matches);
  FreeSurface(Surface);
  FreeSurface(Source);
  { Doubled: black and white become black, a quarter, three quarters,
    white (bilinear, the edges carried on). }
  Source := NewSurface(2, 1, ColorBlack);
  SetSurfacePixel(Source, 1, 0, ColorWhite);
  Surface := NewSurface(4, 1, ColorTransparent);
  BeginCanvas(Canvas, Surface);
  DrawSurfaceScaled(Canvas, Source, SurfaceBounds(Source), SurfaceBounds(Surface), False);
  Check('smooth scaling: doubled, in between', (GetSurfacePixel(Surface, 0, 0) = ColorBlack) and
    (GetSurfacePixel(Surface, 1, 0) = $FF404040) and (GetSurfacePixel(Surface, 2, 0) = $FFBFBFBF) and
    (GetSurfacePixel(Surface, 3, 0) = ColorWhite));
  FreeSurface(Surface);
  FreeSurface(Source);
  { Halved: a checkerboard averages to grey. }
  Source := NewSurface(4, 4, ColorBlack);
  for Y := 0 to 3 do
    for X := 0 to 3 do
      if (X + Y) mod 2 = 0 then
        SetSurfacePixel(Source, X, Y, ColorWhite);
  Surface := NewSurface(2, 2, ColorTransparent);
  BeginCanvas(Canvas, Surface);
  DrawSurfaceScaled(Canvas, Source, SurfaceBounds(Source), SurfaceBounds(Surface), False);
  Check('smooth scaling: halved, averaged', CountPixels(Surface, $FF808080) = 4);
  FreeSurface(Surface);
  FreeSurface(Source);
  { A thin line a third of the way shrinks to a third of its colour,
    not to nothing (nearest neighbour could miss it). }
  Source := NewSurface(3, 1, ColorBlack);
  SetSurfacePixel(Source, 0, 0, ColorWhite);
  Surface := NewSurface(1, 1, ColorTransparent);
  BeginCanvas(Canvas, Surface);
  DrawSurfaceScaled(Canvas, Source, SurfaceBounds(Source), SurfaceBounds(Surface), False);
  CheckColor('smooth scaling: a thin line fades', GetSurfacePixel(Surface, 0, 0), $FF555555);
  FreeSurface(Surface);
  FreeSurface(Source);
  { Transparent pixels lend no colour: red beside nothing, halved, is
    half transparent red. }
  Source := NewSurface(2, 1, ColorTransparent);
  SetSurfacePixel(Source, 0, 0, $FFFF0000);
  Surface := NewSurface(1, 1, ColorTransparent);
  BeginCanvas(Canvas, Surface);
  DrawSurfaceScaled(Canvas, Source, SurfaceBounds(Source), SurfaceBounds(Surface), False);
  CheckColor('smooth scaling: transparent pixels lend no colour', GetSurfacePixel(Surface, 0, 0), $80FF0000);
  { Blended over what is there. }
  FillRectangle(Canvas, SurfaceBounds(Surface), ColorWhite);
  DrawSurfaceScaled(Canvas, Source, SurfaceBounds(Source), SurfaceBounds(Surface), True);
  CheckColor('smooth scaling: blended', GetSurfacePixel(Surface, 0, 0), $FFFF7F7F);
  FreeSurface(Surface);
  FreeSurface(Source);
  { Clipped: only the clip's pixels change. }
  Source := NewSurface(2, 2, ColorWhite);
  Surface := NewSurface(8, 8, ColorBlack);
  BeginCanvas(Canvas, Surface);
  NarrowCanvasClip(Canvas, MakeRectangle(0, 0, 3, 8));
  DrawSurfaceScaled(Canvas, Source, SurfaceBounds(Source), MakeRectangle(0, 0, 8, 8), False);
  Check('smooth scaling: clipped', (CountPixels(Surface, ColorWhite) = 24) and (GetSurfacePixel(Surface, 3, 0) = ColorBlack));
  FreeSurface(Surface);
  FreeSurface(Source);
end;

procedure TestSmoothing;
begin
  TestRasterizer;
  TestSmoothEllipses;
  TestSmoothLines;
  TestSmoothPolygons;
  TestSmoothScaling;
end;

end.
