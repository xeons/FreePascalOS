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
  The rasterizer: shapes drawn anti-aliased, every pixel blended by how
  much of it the shape covers, exactly (the area, not samples).

  A shape is a set of edges with fractional ends, in canvas coordinates
  where pixel (X, Y) is the square from (X, Y) to (X + 1, Y + 1) (as for
  FillPolygon); several closed outlines may make one shape. Each edge
  adds, to every pixel row it crosses, the area to its right that it
  bounds (signed: downward edges add, upward ones take away), so after
  summing along a row each pixel holds how much of it is inside. That
  is the winding of the outlines, and a pixel is covered as much as
  that sum says, at most fully: outlines going the same way join, one
  going the other way inside another cuts a hole (non-zero rule).

  The sums are worked in a buffer the size of the shape within the
  canvas's clip; edges reaching outside it are cut at its sides (the
  part to the left counts as an edge down its left side, which covers
  the same rows the same way). The covered pixels then go through
  FillSpan in runs of equal coverage, so clipping and blending are the
  canvas's as for everything else.
}
unit Drawing.Rasterizer;

{$mode objfpc}

interface

uses
  Drawing.Colors,
  Drawing.Rectangles,
  Drawing.Canvas;

type
  TPrecisePoint = record
    X: Double;
    Y: Double;
  end;

  TPreciseEdge = record
    FromX: Double;
    FromY: Double;
    ToX: Double;
    ToY: Double;
  end;

  TCoverageShape = record
    Edges: array of TPreciseEdge;
    Count: LongInt;
  end;

function PrecisePoint(X, Y: Double): TPrecisePoint;
procedure BeginShape(out Shape: TCoverageShape);
procedure AddShapeEdge(var Shape: TCoverageShape; FromX, FromY, ToX, ToY: Double);
{ A closed outline: every point to the next, the last back to the first. }
procedure AddShapePolygon(var Shape: TCoverageShape; const Points: array of TPrecisePoint);
{ An ellipse as an outline of enough straight edges that none strays a
  hundredth of a pixel from the curve; clockwise on the screen (filled)
  or not (a hole in a clockwise outline around it). }
procedure AddShapeEllipse(var Shape: TCoverageShape; CentreX, CentreY, RadiusX, RadiusY: Double;
  Clockwise: Boolean);
{ A quadratic Bezier curve from (FromX, FromY) to (ToX, ToY) pulled
  towards (ControlX, ControlY), as the outlines of TrueType glyphs are
  made: enough straight edges that none strays more than a fiftieth of
  a pixel from the curve. }
procedure AddShapeQuadratic(var Shape: TCoverageShape; FromX, FromY, ControlX, ControlY, ToX, ToY: Double);
{ Draws the shape in Color, each pixel at the colour's alpha times its
  coverage. }
procedure FillShape(const Canvas: TCanvas; const Shape: TCoverageShape; Color: TColor);
{ How much of each pixel of Area (canvas coordinates) the shape covers,
  0 to 255, row by row: for tests and for masks. }
procedure ShapeCoverage(const Shape: TCoverageShape; const Area: TRectangle; out Coverage: array of Byte);

implementation

uses
  Math,
  Drawing.Regions;

type
  { The sums for a rectangle of pixels: a row is Width + 2 cells, so an
    edge on the right side still has a cell to write to. }
  TAccumulation = record
    Area: TRectangle;
    Stride: LongInt;
    Cells: array of Double;
  end;

function PrecisePoint(X, Y: Double): TPrecisePoint;
begin
  Result.X := X;
  Result.Y := Y;
end;

procedure BeginShape(out Shape: TCoverageShape);
begin
  Shape.Edges := nil;
  Shape.Count := 0;
end;

procedure AddShapeEdge(var Shape: TCoverageShape; FromX, FromY, ToX, ToY: Double);
begin
  { A level edge bounds no area. }
  if FromY = ToY then
    Exit;
  if Shape.Count = Length(Shape.Edges) then
    SetLength(Shape.Edges, 2 * Shape.Count + 16);
  Shape.Edges[Shape.Count].FromX := FromX;
  Shape.Edges[Shape.Count].FromY := FromY;
  Shape.Edges[Shape.Count].ToX := ToX;
  Shape.Edges[Shape.Count].ToY := ToY;
  Inc(Shape.Count);
end;

procedure AddShapePolygon(var Shape: TCoverageShape; const Points: array of TPrecisePoint);
var
  Index: LongInt;
  Next: LongInt;
begin
  for Index := 0 to High(Points) do
  begin
    Next := (Index + 1) mod Length(Points);
    AddShapeEdge(Shape, Points[Index].X, Points[Index].Y, Points[Next].X, Points[Next].Y);
  end;
end;

procedure AddShapeEllipse(var Shape: TCoverageShape; CentreX, CentreY, RadiusX, RadiusY: Double;
  Clockwise: Boolean);
const
  { How far an edge may stray from the curve, in pixels. }
  Tolerance = 0.01;
  MaximumSides = 1024;
var
  Largest: Double;
  Sides: LongInt;
  Side: LongInt;
  Angle: Double;
  PreviousX: Double;
  PreviousY: Double;
  X: Double;
  Y: Double;
begin
  if (RadiusX <= 0) or (RadiusY <= 0) then
    Exit;
  Largest := RadiusX;
  if RadiusY > Largest then
    Largest := RadiusY;
  { An edge across an angle A strays R (1 - cos(A / 2)) from a circle
    of radius R; enough sides keep that within the tolerance. A multiple
    of four keeps the outline as symmetric as the ellipse. }
  if Largest <= Tolerance then
    Sides := 4
  else
    Sides := Trunc(Pi / ArcCos(1 - Tolerance / Largest)) + 1;
  if Sides < 8 then
    Sides := 8;
  if Sides > MaximumSides then
    Sides := MaximumSides;
  Sides := (Sides + 3) div 4 * 4;
  PreviousX := CentreX + RadiusX;
  PreviousY := CentreY;
  for Side := 1 to Sides do
  begin
    Angle := 2 * Pi * Side / Sides;
    if not Clockwise then
      Angle := -Angle;
    X := CentreX + RadiusX * Cos(Angle);
    Y := CentreY + RadiusY * Sin(Angle);
    if Side = Sides then
    begin
      X := CentreX + RadiusX;
      Y := CentreY;
    end;
    AddShapeEdge(Shape, PreviousX, PreviousY, X, Y);
    PreviousX := X;
    PreviousY := Y;
  end;
end;

procedure AddShapeQuadratic(var Shape: TCoverageShape; FromX, FromY, ControlX, ControlY, ToX, ToY: Double);
const
  Tolerance = 0.02;
  MaximumPieces = 64;
var
  Deviation: Double;
  Pieces: LongInt;
  Piece: LongInt;
  T: Double;
  Rest: Double;
  PreviousX: Double;
  PreviousY: Double;
  X: Double;
  Y: Double;
begin
  { The curve strays at most a quarter of |From - 2 Control + To| from
    the chord; N edges cut that by N squared. }
  Deviation := 0.25 * Sqrt(Sqr(FromX - 2 * ControlX + ToX) + Sqr(FromY - 2 * ControlY + ToY));
  if Deviation <= Tolerance then
    Pieces := 1
  else if Deviation >= Tolerance * MaximumPieces * MaximumPieces then
    Pieces := MaximumPieces
  else
    Pieces := Trunc(Sqrt(Deviation / Tolerance)) + 1;
  PreviousX := FromX;
  PreviousY := FromY;
  for Piece := 1 to Pieces do
  begin
    if Piece = Pieces then
    begin
      X := ToX;
      Y := ToY;
    end
    else
    begin
      T := Piece / Pieces;
      Rest := 1 - T;
      X := Rest * Rest * FromX + 2 * Rest * T * ControlX + T * T * ToX;
      Y := Rest * Rest * FromY + 2 * Rest * T * ControlY + T * T * ToY;
    end;
    AddShapeEdge(Shape, PreviousX, PreviousY, X, Y);
    PreviousX := X;
    PreviousY := Y;
  end;
end;

function FloorOf(Value: Double): LongInt;
begin
  Result := Trunc(Value);
  if Result > Value then
    Dec(Result);
end;

function CeilingOf(Value: Double): LongInt;
begin
  Result := Trunc(Value);
  if Result < Value then
    Inc(Result);
end;

{ The pixels the shape's edges reach, offset by (OffsetX, OffsetY). }
function ShapeBounds(const Shape: TCoverageShape; OffsetX, OffsetY: LongInt): TRectangle;
var
  Index: LongInt;
  Left: Double;
  Top: Double;
  Right: Double;
  Bottom: Double;
  Edge: TPreciseEdge;

  procedure Include(X, Y: Double);
  begin
    if X < Left then
      Left := X;
    if X > Right then
      Right := X;
    if Y < Top then
      Top := Y;
    if Y > Bottom then
      Bottom := Y;
  end;

begin
  Result := MakeRectangle(0, 0, 0, 0);
  if Shape.Count = 0 then
    Exit;
  Left := Shape.Edges[0].FromX;
  Right := Left;
  Top := Shape.Edges[0].FromY;
  Bottom := Top;
  for Index := 0 to Shape.Count - 1 do
  begin
    Edge := Shape.Edges[Index];
    Include(Edge.FromX, Edge.FromY);
    Include(Edge.ToX, Edge.ToY);
  end;
  { Far outside any surface is as good as outside it, and stays clear
    of overflowing a LongInt. }
  if (Left < -1E8) or (Top < -1E8) or (Right > 1E8) or (Bottom > 1E8) then
    Exit;
  Result.Left := FloorOf(Left) + OffsetX;
  Result.Top := FloorOf(Top) + OffsetY;
  Result.Right := CeilingOf(Right) + OffsetX;
  Result.Bottom := CeilingOf(Bottom) + OffsetY;
end;

{ One edge, already within the buffer across (0 <= x <= Width), in the
  buffer's own coordinates: on every row it crosses, the area between
  it and each cell's right side, spread so that summing along the row
  gives each pixel's coverage. }
procedure AccumulateEdge(var Accumulation: TAccumulation; FromX, FromY, ToX, ToY: Double);
var
  Direction: Double;
  Swap: Double;
  SlopeX: Double;
  X: Double;
  NextX: Double;
  Row: LongInt;
  FirstRow: LongInt;
  EndRow: LongInt;
  Height: Double;
  Delta: Double;
  Left: Double;
  Right: Double;
  LeftFloor: Double;
  LeftCell: LongInt;
  RightCell: LongInt;
  Middle: Double;
  LineStart: LongInt;
  Reciprocal: Double;
  LeftFraction: Double;
  RightFraction: Double;
  FirstArea: Double;
  LastArea: Double;
  SecondArea: Double;
  RunningArea: Double;
  Cell: LongInt;
begin
  if FromY = ToY then
    Exit;
  Direction := 1;
  if FromY > ToY then
  begin
    Direction := -1;
    Swap := FromX;
    FromX := ToX;
    ToX := Swap;
    Swap := FromY;
    FromY := ToY;
    ToY := Swap;
  end;
  SlopeX := (ToX - FromX) / (ToY - FromY);
  X := FromX;
  if FromY < 0 then
  begin
    X := X - FromY * SlopeX;
    FirstRow := 0;
  end
  else
    FirstRow := FloorOf(FromY);
  EndRow := CeilingOf(ToY);
  if EndRow > RectangleHeight(Accumulation.Area) then
    EndRow := RectangleHeight(Accumulation.Area);
  for Row := FirstRow to EndRow - 1 do
  begin
    LineStart := Row * Accumulation.Stride;
    { How much of this row the edge spans, and where it leaves it. }
    if ToY < Row + 1 then
      Height := ToY
    else
      Height := Row + 1;
    if FromY > Row then
      Height := Height - FromY
    else
      Height := Height - Row;
    NextX := X + SlopeX * Height;
    Delta := Height * Direction;
    if X < NextX then
    begin
      Left := X;
      Right := NextX;
    end
    else
    begin
      Left := NextX;
      Right := X;
    end;
    LeftFloor := FloorOf(Left);
    LeftCell := LongInt(Trunc(LeftFloor));
    RightCell := CeilingOf(Right);
    if RightCell <= LeftCell + 1 then
    begin
      { Within one cell: the part right of the edge's middle. }
      Middle := 0.5 * (X + NextX) - LeftFloor;
      Accumulation.Cells[LineStart + LeftCell] := Accumulation.Cells[LineStart + LeftCell] + Delta - Delta * Middle;
      Accumulation.Cells[LineStart + LeftCell + 1] := Accumulation.Cells[LineStart + LeftCell + 1] + Delta * Middle;
    end
    else
    begin
      { Across several cells: a triangle in the first, a trapezoid in
        each one between and in the last, what is left after it. }
      Reciprocal := 1 / (Right - Left);
      LeftFraction := Left - LeftFloor;
      FirstArea := 0.5 * Reciprocal * (1 - LeftFraction) * (1 - LeftFraction);
      RightFraction := Right - RightCell + 1;
      LastArea := 0.5 * Reciprocal * RightFraction * RightFraction;
      Accumulation.Cells[LineStart + LeftCell] := Accumulation.Cells[LineStart + LeftCell] + Delta * FirstArea;
      if RightCell = LeftCell + 2 then
        Accumulation.Cells[LineStart + LeftCell + 1] := Accumulation.Cells[LineStart + LeftCell + 1] +
          Delta * (1 - FirstArea - LastArea)
      else
      begin
        SecondArea := Reciprocal * (1.5 - LeftFraction);
        Accumulation.Cells[LineStart + LeftCell + 1] := Accumulation.Cells[LineStart + LeftCell + 1] +
          Delta * (SecondArea - FirstArea);
        for Cell := LeftCell + 2 to RightCell - 2 do
          Accumulation.Cells[LineStart + Cell] := Accumulation.Cells[LineStart + Cell] + Delta * Reciprocal;
        RunningArea := SecondArea + (RightCell - LeftCell - 3) * Reciprocal;
        Accumulation.Cells[LineStart + RightCell - 1] := Accumulation.Cells[LineStart + RightCell - 1] +
          Delta * (1 - RunningArea - LastArea);
      end;
      Accumulation.Cells[LineStart + RightCell] := Accumulation.Cells[LineStart + RightCell] + Delta * LastArea;
    end;
    X := NextX;
  end;
end;

{ An edge in buffer coordinates, cut to the buffer across: a part left
  of it becomes the same rows down its left side; a part right of it,
  the same down its right side (which only the spare cell sees). }
procedure AddEdgeWithin(var Accumulation: TAccumulation; FromX, FromY, ToX, ToY: Double);
var
  Width: Double;
  CrossY: Double;
begin
  Width := RectangleWidth(Accumulation.Area);
  { Split only where the edge goes from one side of a line to the
    other; an edge that just touches it is on one side already. }
  if ((FromX < 0) and (ToX > 0)) or ((FromX > 0) and (ToX < 0)) then
  begin
    CrossY := FromY + (0 - FromX) * (ToY - FromY) / (ToX - FromX);
    AddEdgeWithin(Accumulation, FromX, FromY, 0, CrossY);
    AddEdgeWithin(Accumulation, 0, CrossY, ToX, ToY);
    Exit;
  end;
  if ((FromX > Width) and (ToX < Width)) or ((FromX < Width) and (ToX > Width)) then
  begin
    CrossY := FromY + (Width - FromX) * (ToY - FromY) / (ToX - FromX);
    AddEdgeWithin(Accumulation, FromX, FromY, Width, CrossY);
    AddEdgeWithin(Accumulation, Width, CrossY, ToX, ToY);
    Exit;
  end;
  if (FromX < 0) or (ToX < 0) then
  begin
    FromX := 0;
    ToX := 0;
  end
  else if (FromX > Width) or (ToX > Width) then
  begin
    FromX := Width;
    ToX := Width;
  end;
  AccumulateEdge(Accumulation, FromX, FromY, ToX, ToY);
end;

{ The shape's sums over Area, given in the shape's own coordinates
  (offset by OffsetX, OffsetY). }
procedure AccumulateShape(const Shape: TCoverageShape; const Area: TRectangle; OffsetX, OffsetY: LongInt;
  out Accumulation: TAccumulation);
var
  Index: LongInt;
  Edge: TPreciseEdge;
  ShiftX: Double;
  ShiftY: Double;
begin
  Accumulation.Area := Area;
  Accumulation.Stride := RectangleWidth(Area) + 2;
  { A new dynamic array comes filled with zeros. }
  Accumulation.Cells := nil;
  SetLength(Accumulation.Cells, Accumulation.Stride * RectangleHeight(Area));
  ShiftX := OffsetX - Area.Left;
  ShiftY := OffsetY - Area.Top;
  for Index := 0 to Shape.Count - 1 do
  begin
    Edge := Shape.Edges[Index];
    AddEdgeWithin(Accumulation, Edge.FromX + ShiftX, Edge.FromY + ShiftY, Edge.ToX + ShiftX, Edge.ToY + ShiftY);
  end;
end;

{ A running sum as coverage: its size, at most one, in 0 to 255. }
function CoverageOf(Sum: Double): Byte;
begin
  Sum := Abs(Sum);
  if Sum >= 1 then
    Exit(255);
  Result := Byte(Trunc(Sum * 255 + 0.5));
end;

procedure FillShape(const Canvas: TCanvas; const Shape: TCoverageShape; Color: TColor);
var
  Area: TRectangle;
  Accumulation: TAccumulation;
  Row: LongInt;
  Column: LongInt;
  RunStart: LongInt;
  Width: LongInt;
  Sum: Double;
  Value: Byte;
  RunValue: Byte;
  LineStart: LongInt;
begin
  if (Shape.Count = 0) or (AlphaOf(Color) = 0) then
    Exit;
  if not IntersectRectangles(ShapeBounds(Shape, Canvas.OriginX, Canvas.OriginY), RegionBounds(Canvas.Clip), Area) then
    Exit;
  AccumulateShape(Shape, Area, Canvas.OriginX, Canvas.OriginY, Accumulation);
  Width := RectangleWidth(Area);
  for Row := 0 to RectangleHeight(Area) - 1 do
  begin
    LineStart := Row * Accumulation.Stride;
    Sum := 0;
    RunStart := 0;
    RunValue := 0;
    for Column := 0 to Width do
    begin
      if Column < Width then
      begin
        Sum := Sum + Accumulation.Cells[LineStart + Column];
        Value := CoverageOf(Sum);
      end
      else
        Value := 0;
      { At the end of a run of one coverage, the run is one span. }
      if (Column = Width) or (Value <> RunValue) then
      begin
        if (Column > RunStart) and (RunValue <> 0) then
          FillSpan(Canvas, Area.Top + Row, Area.Left + RunStart, Area.Left + Column, FadeColor(Color, RunValue));
        RunStart := Column;
        RunValue := Value;
      end;
    end;
  end;
end;

procedure ShapeCoverage(const Shape: TCoverageShape; const Area: TRectangle; out Coverage: array of Byte);
var
  Accumulation: TAccumulation;
  Row: LongInt;
  Column: LongInt;
  Sum: Double;
  Index: LongInt;
begin
  for Index := 0 to High(Coverage) do
    Coverage[Index] := 0;
  if RectangleIsEmpty(Area) or (Length(Coverage) < RectangleWidth(Area) * RectangleHeight(Area)) then
    Exit;
  AccumulateShape(Shape, Area, 0, 0, Accumulation);
  Index := 0;
  for Row := 0 to RectangleHeight(Area) - 1 do
  begin
    Sum := 0;
    for Column := 0 to RectangleWidth(Area) - 1 do
    begin
      Sum := Sum + Accumulation.Cells[Row * Accumulation.Stride + Column];
      Coverage[Index] := CoverageOf(Sum);
      Inc(Index);
    end;
  end;
end;

end.
