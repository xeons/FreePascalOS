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
  Paths: outlines made of subpaths of straight lines, quadratic and
  cubic Bezier curves and elliptical arcs (as SVG's path data and the
  canvas API describe them), in any coordinate space.

  A path is a list of commands: MoveTo starts a subpath, LineTo,
  QuadraticTo and CubicTo extend it, Close joins it back to its start.
  Arcs (PathArcTo, SVG's endpoint form) become cubic curves when added,
  at most a quarter turn each, which stray less than a thousandth of
  the radius from the ellipse.

  FlattenPath turns a path into polylines through a transform: curves
  are cut into straight pieces after transforming their control points,
  so that no piece strays more than Tolerance (in the transformed
  space) from the curve. AddPolylinesToShape gives the rasterizer the
  outlines of the filled path (every polyline closed).
}
unit Drawing.Paths;

{$mode objfpc}

interface

uses
  Drawing.Rasterizer,
  Drawing.Curves,
  Drawing.Transforms;

type
  TPathCommandKind = (pcMoveTo, pcLineTo, pcQuadraticTo, pcCubicTo, pcClose);

  TPathCommand = record
    Kind: TPathCommandKind;
    { The control points, then the end point (the last one used). }
    Points: array[0..2] of TPrecisePoint;
  end;

  TPath = record
    Commands: array of TPathCommand;
    Count: LongInt;
    { Where the current subpath started and where the pen is. }
    StartPoint: TPrecisePoint;
    CurrentPoint: TPrecisePoint;
    HasCurrentPoint: Boolean;
  end;

  TPolyline = record
    Points: TPrecisePoints;
    Count: LongInt;
    Closed: Boolean;
  end;

  TPolylines = array of TPolyline;

  TPathBounds = record
    Left: Double;
    Top: Double;
    Right: Double;
    Bottom: Double;
    Empty: Boolean;
  end;

const
  { A fiftieth of a pixel, as the rasterizer's curves. }
  DefaultFlatteningTolerance = 0.02;

procedure BeginPath(out Path: TPath);
procedure PathMoveTo(var Path: TPath; X, Y: Double);
procedure PathLineTo(var Path: TPath; X, Y: Double);
procedure PathQuadraticTo(var Path: TPath; ControlX, ControlY, X, Y: Double);
procedure PathCubicTo(var Path: TPath; FirstX, FirstY, SecondX, SecondY, X, Y: Double);
{ An elliptical arc from the current point to (X, Y) as SVG's A command:
  radii, the ellipse's turn in degrees, which of the four arcs. Radii of
  zero make a straight line; radii too small for the ends grow until
  they reach. }
procedure PathArcTo(var Path: TPath; RadiusX, RadiusY, Rotation: Double; LargeArc, Sweep: Boolean; X, Y: Double);
procedure PathClose(var Path: TPath);
procedure PathAddRectangle(var Path: TPath; X, Y, Width, Height: Double);
{ A rectangle with elliptical corners (radii already within half the
  sides), drawn clockwise from the top left corner's end as SVG's rect. }
procedure PathAddRoundedRectangle(var Path: TPath; X, Y, Width, Height, RadiusX, RadiusY: Double);
procedure PathAddEllipse(var Path: TPath; CentreX, CentreY, RadiusX, RadiusY: Double);
{ Adds every command of Source, transformed. }
procedure PathAppend(var Path: TPath; const Source: TPath; const Transform: TAffineTransform);

{ The polylines of Path through Transform. Subpaths of a single point
  are kept (with one point) for round and square caps. }
function FlattenPath(const Path: TPath; const Transform: TAffineTransform; Tolerance: Double): TPolylines;
procedure AddPolylinesToShape(var Shape: TCoverageShape; const Polylines: TPolylines);
{ The polylines' points through Transform. }
procedure TransformPolylines(var Polylines: TPolylines; const Transform: TAffineTransform);
{ The box around the path's points (control points included) through
  Transform. }
function PathBounds(const Path: TPath; const Transform: TAffineTransform): TPathBounds;
{ The exact box around the path through Transform (from its flattening). }
function PathTightBounds(const Path: TPath; const Transform: TAffineTransform): TPathBounds;

implementation

uses
  Math;

const
  MaximumPieces = 512;

procedure BeginPath(out Path: TPath);
begin
  Path.Commands := nil;
  Path.Count := 0;
  Path.StartPoint := PrecisePoint(0, 0);
  Path.CurrentPoint := PrecisePoint(0, 0);
  Path.HasCurrentPoint := False;
end;

procedure AddCommand(var Path: TPath; Kind: TPathCommandKind; const P0, P1, P2: TPrecisePoint);
begin
  if Path.Count = Length(Path.Commands) then
    SetLength(Path.Commands, 2 * Path.Count + 8);
  Path.Commands[Path.Count].Kind := Kind;
  Path.Commands[Path.Count].Points[0] := P0;
  Path.Commands[Path.Count].Points[1] := P1;
  Path.Commands[Path.Count].Points[2] := P2;
  Inc(Path.Count);
end;

procedure EnsureSubpath(var Path: TPath);
begin
  if not Path.HasCurrentPoint then
    PathMoveTo(Path, Path.CurrentPoint.X, Path.CurrentPoint.Y);
end;

procedure PathMoveTo(var Path: TPath; X, Y: Double);
var
  Point: TPrecisePoint;
begin
  Point := PrecisePoint(X, Y);
  AddCommand(Path, pcMoveTo, Point, Point, Point);
  Path.StartPoint := Point;
  Path.CurrentPoint := Point;
  Path.HasCurrentPoint := True;
end;

procedure PathLineTo(var Path: TPath; X, Y: Double);
var
  Point: TPrecisePoint;
begin
  EnsureSubpath(Path);
  Point := PrecisePoint(X, Y);
  AddCommand(Path, pcLineTo, Point, Point, Point);
  Path.CurrentPoint := Point;
end;

procedure PathQuadraticTo(var Path: TPath; ControlX, ControlY, X, Y: Double);
var
  Point: TPrecisePoint;
begin
  EnsureSubpath(Path);
  Point := PrecisePoint(X, Y);
  AddCommand(Path, pcQuadraticTo, PrecisePoint(ControlX, ControlY), Point, Point);
  Path.CurrentPoint := Point;
end;

procedure PathCubicTo(var Path: TPath; FirstX, FirstY, SecondX, SecondY, X, Y: Double);
var
  Point: TPrecisePoint;
begin
  EnsureSubpath(Path);
  Point := PrecisePoint(X, Y);
  AddCommand(Path, pcCubicTo, PrecisePoint(FirstX, FirstY), PrecisePoint(SecondX, SecondY), Point);
  Path.CurrentPoint := Point;
end;

procedure PathClose(var Path: TPath);
begin
  if not Path.HasCurrentPoint then
    Exit;
  AddCommand(Path, pcClose, Path.StartPoint, Path.StartPoint, Path.StartPoint);
  Path.CurrentPoint := Path.StartPoint;
  { The next command starts a subpath at the start point. }
  Path.HasCurrentPoint := False;
end;

{ The angle from vector U to vector V, signed. }
function VectorAngle(UX, UY, VX, VY: Double): Double;
var
  Dot: Double;
  Lengths: Double;
  Ratio: Double;
begin
  Dot := UX * VX + UY * VY;
  Lengths := Sqrt(UX * UX + UY * UY) * Sqrt(VX * VX + VY * VY);
  if Lengths = 0 then
    Exit(0);
  Ratio := Dot / Lengths;
  if Ratio > 1 then
    Ratio := 1;
  if Ratio < -1 then
    Ratio := -1;
  Result := ArcCos(Ratio);
  if UX * VY - UY * VX < 0 then
    Result := -Result;
end;

procedure PathArcTo(var Path: TPath; RadiusX, RadiusY, Rotation: Double; LargeArc, Sweep: Boolean; X, Y: Double);
var
  StartX, StartY: Double;
  CosPhi, SinPhi: Double;
  HalfDX, HalfDY: Double;
  PrimeX, PrimeY: Double;
  Lambda: Double;
  Numerator, Denominator, Coefficient: Double;
  CentrePrimeX, CentrePrimeY: Double;
  CentreX, CentreY: Double;
  StartAngle, DeltaAngle: Double;
  Segments, Segment: LongInt;
  SegmentAngle, Alpha: Double;
  Angle1, Angle2: Double;
  Cos1, Sin1, Cos2, Sin2: Double;
  E1X, E1Y, E2X, E2Y: Double;
  D1X, D1Y, D2X, D2Y: Double;

  procedure EllipsePoint(CosT, SinT: Double; out PX, PY: Double);
  begin
    PX := CentreX + RadiusX * CosT * CosPhi - RadiusY * SinT * SinPhi;
    PY := CentreY + RadiusX * CosT * SinPhi + RadiusY * SinT * CosPhi;
  end;

  procedure EllipseDerivative(CosT, SinT: Double; out DX, DY: Double);
  begin
    DX := -RadiusX * SinT * CosPhi - RadiusY * CosT * SinPhi;
    DY := -RadiusX * SinT * SinPhi + RadiusY * CosT * CosPhi;
  end;

begin
  EnsureSubpath(Path);
  StartX := Path.CurrentPoint.X;
  StartY := Path.CurrentPoint.Y;
  if (StartX = X) and (StartY = Y) then
    Exit;
  RadiusX := Abs(RadiusX);
  RadiusY := Abs(RadiusY);
  if (RadiusX = 0) or (RadiusY = 0) then
  begin
    PathLineTo(Path, X, Y);
    Exit;
  end;
  { SVG 1.1 appendix F.6.5: the centre from the end points. }
  CosPhi := Cos(DegToRad(Rotation));
  SinPhi := Sin(DegToRad(Rotation));
  HalfDX := (StartX - X) / 2;
  HalfDY := (StartY - Y) / 2;
  PrimeX := CosPhi * HalfDX + SinPhi * HalfDY;
  PrimeY := -SinPhi * HalfDX + CosPhi * HalfDY;
  Lambda := Sqr(PrimeX) / Sqr(RadiusX) + Sqr(PrimeY) / Sqr(RadiusY);
  if Lambda > 1 then
  begin
    RadiusX := RadiusX * Sqrt(Lambda);
    RadiusY := RadiusY * Sqrt(Lambda);
  end;
  Numerator := Sqr(RadiusX) * Sqr(RadiusY) - Sqr(RadiusX) * Sqr(PrimeY) - Sqr(RadiusY) * Sqr(PrimeX);
  Denominator := Sqr(RadiusX) * Sqr(PrimeY) + Sqr(RadiusY) * Sqr(PrimeX);
  if (Numerator <= 0) or (Denominator = 0) then
    Coefficient := 0
  else
    Coefficient := Sqrt(Numerator / Denominator);
  if LargeArc = Sweep then
    Coefficient := -Coefficient;
  CentrePrimeX := Coefficient * RadiusX * PrimeY / RadiusY;
  CentrePrimeY := -Coefficient * RadiusY * PrimeX / RadiusX;
  CentreX := CosPhi * CentrePrimeX - SinPhi * CentrePrimeY + (StartX + X) / 2;
  CentreY := SinPhi * CentrePrimeX + CosPhi * CentrePrimeY + (StartY + Y) / 2;
  StartAngle := VectorAngle(1, 0, (PrimeX - CentrePrimeX) / RadiusX, (PrimeY - CentrePrimeY) / RadiusY);
  DeltaAngle := VectorAngle((PrimeX - CentrePrimeX) / RadiusX, (PrimeY - CentrePrimeY) / RadiusY,
    (-PrimeX - CentrePrimeX) / RadiusX, (-PrimeY - CentrePrimeY) / RadiusY);
  if not Sweep and (DeltaAngle > 0) then
    DeltaAngle := DeltaAngle - 2 * Pi
  else if Sweep and (DeltaAngle < 0) then
    DeltaAngle := DeltaAngle + 2 * Pi;
  { Quarter turns at most, each a cubic curve. }
  Segments := Ceil(Abs(DeltaAngle) / (Pi / 2) - 1E-9);
  if Segments < 1 then
    Segments := 1;
  SegmentAngle := DeltaAngle / Segments;
  Alpha := 4 / 3 * Tan(SegmentAngle / 4);
  for Segment := 0 to Segments - 1 do
  begin
    Angle1 := StartAngle + Segment * SegmentAngle;
    Angle2 := Angle1 + SegmentAngle;
    Cos1 := Cos(Angle1);
    Sin1 := Sin(Angle1);
    Cos2 := Cos(Angle2);
    Sin2 := Sin(Angle2);
    EllipsePoint(Cos1, Sin1, E1X, E1Y);
    EllipsePoint(Cos2, Sin2, E2X, E2Y);
    EllipseDerivative(Cos1, Sin1, D1X, D1Y);
    EllipseDerivative(Cos2, Sin2, D2X, D2Y);
    if Segment = Segments - 1 then
    begin
      E2X := X;
      E2Y := Y;
    end;
    PathCubicTo(Path, E1X + Alpha * D1X, E1Y + Alpha * D1Y, E2X - Alpha * D2X, E2Y - Alpha * D2Y, E2X, E2Y);
  end;
end;

procedure PathAddRectangle(var Path: TPath; X, Y, Width, Height: Double);
begin
  PathMoveTo(Path, X, Y);
  PathLineTo(Path, X + Width, Y);
  PathLineTo(Path, X + Width, Y + Height);
  PathLineTo(Path, X, Y + Height);
  PathClose(Path);
end;

procedure PathAddRoundedRectangle(var Path: TPath; X, Y, Width, Height, RadiusX, RadiusY: Double);
begin
  if (RadiusX <= 0) or (RadiusY <= 0) then
  begin
    PathAddRectangle(Path, X, Y, Width, Height);
    Exit;
  end;
  PathMoveTo(Path, X + RadiusX, Y);
  PathLineTo(Path, X + Width - RadiusX, Y);
  PathArcTo(Path, RadiusX, RadiusY, 0, False, True, X + Width, Y + RadiusY);
  PathLineTo(Path, X + Width, Y + Height - RadiusY);
  PathArcTo(Path, RadiusX, RadiusY, 0, False, True, X + Width - RadiusX, Y + Height);
  PathLineTo(Path, X + RadiusX, Y + Height);
  PathArcTo(Path, RadiusX, RadiusY, 0, False, True, X, Y + Height - RadiusY);
  PathLineTo(Path, X, Y + RadiusY);
  PathArcTo(Path, RadiusX, RadiusY, 0, False, True, X + RadiusX, Y);
  PathClose(Path);
end;

procedure PathAddEllipse(var Path: TPath; CentreX, CentreY, RadiusX, RadiusY: Double);
begin
  if (RadiusX <= 0) or (RadiusY <= 0) then
    Exit;
  { SVG's ellipse starts at (cx + rx, cy) and goes clockwise. }
  PathMoveTo(Path, CentreX + RadiusX, CentreY);
  PathArcTo(Path, RadiusX, RadiusY, 0, False, True, CentreX, CentreY + RadiusY);
  PathArcTo(Path, RadiusX, RadiusY, 0, False, True, CentreX - RadiusX, CentreY);
  PathArcTo(Path, RadiusX, RadiusY, 0, False, True, CentreX, CentreY - RadiusY);
  PathArcTo(Path, RadiusX, RadiusY, 0, False, True, CentreX + RadiusX, CentreY);
  PathClose(Path);
end;

procedure PathAppend(var Path: TPath; const Source: TPath; const Transform: TAffineTransform);
var
  Index: LongInt;
  Command: TPathCommand;
  Point: LongInt;
begin
  for Index := 0 to Source.Count - 1 do
  begin
    Command := Source.Commands[Index];
    for Point := 0 to 2 do
      Command.Points[Point] := TransformPoint(Transform, Command.Points[Point].X, Command.Points[Point].Y);
    AddCommand(Path, Command.Kind, Command.Points[0], Command.Points[1], Command.Points[2]);
    case Command.Kind of
      pcMoveTo:
        begin
          Path.StartPoint := Command.Points[2];
          Path.CurrentPoint := Command.Points[2];
          Path.HasCurrentPoint := True;
        end;
      pcClose:
        begin
          Path.CurrentPoint := Path.StartPoint;
          Path.HasCurrentPoint := False;
        end;
      else
        Path.CurrentPoint := Command.Points[2];
    end;
  end;
end;

{ ---- flattening ---- }

type
  TPolylineBuilder = record
    Lines: TPolylines;
    LineCount: LongInt;
    Open: Boolean;
  end;

procedure StartPolyline(var Builder: TPolylineBuilder; const Point: TPrecisePoint);
begin
  if Builder.LineCount = Length(Builder.Lines) then
    SetLength(Builder.Lines, 2 * Builder.LineCount + 4);
  Builder.Lines[Builder.LineCount].Points := nil;
  SetLength(Builder.Lines[Builder.LineCount].Points, 8);
  Builder.Lines[Builder.LineCount].Points[0] := Point;
  Builder.Lines[Builder.LineCount].Count := 1;
  Builder.Lines[Builder.LineCount].Closed := False;
  Inc(Builder.LineCount);
  Builder.Open := True;
end;

procedure AddPoint(var Builder: TPolylineBuilder; const Point: TPrecisePoint);
var
  Line: ^TPolyline;
begin
  Line := @Builder.Lines[Builder.LineCount - 1];
  { Repeated points add nothing but trouble for joins. }
  if (Line^.Points[Line^.Count - 1].X = Point.X) and (Line^.Points[Line^.Count - 1].Y = Point.Y) then
    Exit;
  if Line^.Count = Length(Line^.Points) then
    SetLength(Line^.Points, 2 * Line^.Count);
  Line^.Points[Line^.Count] := Point;
  Inc(Line^.Count);
end;

function PiecesFor(Deviation, Tolerance: Double): LongInt;
begin
  if Deviation <= 0 then
    Exit(1);
  Result := Ceil(Sqrt(Deviation / (8 * Tolerance)));
  if Result < 1 then
    Result := 1;
  if Result > MaximumPieces then
    Result := MaximumPieces;
end;

procedure AddQuadratic(var Builder: TPolylineBuilder; const From, Control, Target: TPrecisePoint; Tolerance: Double);
var
  Pieces: LongInt;
  Piece: LongInt;
  T, U: Double;
begin
  Pieces := PiecesFor(2 * Sqrt(Sqr(From.X - 2 * Control.X + Target.X) + Sqr(From.Y - 2 * Control.Y + Target.Y)),
    Tolerance);
  for Piece := 1 to Pieces - 1 do
  begin
    T := Piece / Pieces;
    U := 1 - T;
    AddPoint(Builder, PrecisePoint(U * U * From.X + 2 * U * T * Control.X + T * T * Target.X,
      U * U * From.Y + 2 * U * T * Control.Y + T * T * Target.Y));
  end;
  AddPoint(Builder, Target);
end;

procedure AddCubic(var Builder: TPolylineBuilder; const From, First, Second, Target: TPrecisePoint;
  Tolerance: Double);
var
  Pieces: LongInt;
  Piece: LongInt;
  T, U: Double;
begin
  Pieces := PiecesFor(6 * Max(Sqrt(Sqr(From.X - 2 * First.X + Second.X) + Sqr(From.Y - 2 * First.Y + Second.Y)),
    Sqrt(Sqr(First.X - 2 * Second.X + Target.X) + Sqr(First.Y - 2 * Second.Y + Target.Y))), Tolerance);
  for Piece := 1 to Pieces - 1 do
  begin
    T := Piece / Pieces;
    U := 1 - T;
    AddPoint(Builder, PrecisePoint(U * U * U * From.X + 3 * U * U * T * First.X + 3 * U * T * T * Second.X +
      T * T * T * Target.X, U * U * U * From.Y + 3 * U * U * T * First.Y + 3 * U * T * T * Second.Y +
      T * T * T * Target.Y));
  end;
  AddPoint(Builder, Target);
end;

function FlattenPath(const Path: TPath; const Transform: TAffineTransform; Tolerance: Double): TPolylines;
var
  Builder: TPolylineBuilder;
  Index: LongInt;
  Command: TPathCommand;
  Current: TPrecisePoint;
  Start: TPrecisePoint;
  P0, P1, P2: TPrecisePoint;
  Line: ^TPolyline;
begin
  Result := nil;
  if Tolerance <= 0 then
    Tolerance := DefaultFlatteningTolerance;
  Builder.Lines := nil;
  Builder.LineCount := 0;
  Builder.Open := False;
  Current := PrecisePoint(0, 0);
  Start := Current;
  for Index := 0 to Path.Count - 1 do
  begin
    Command := Path.Commands[Index];
    P0 := TransformPoint(Transform, Command.Points[0].X, Command.Points[0].Y);
    P1 := TransformPoint(Transform, Command.Points[1].X, Command.Points[1].Y);
    P2 := TransformPoint(Transform, Command.Points[2].X, Command.Points[2].Y);
    case Command.Kind of
      pcMoveTo:
        begin
          StartPolyline(Builder, P2);
          Current := P2;
          Start := P2;
        end;
      pcLineTo:
        begin
          if not Builder.Open then
            StartPolyline(Builder, Current);
          AddPoint(Builder, P2);
          Current := P2;
        end;
      pcQuadraticTo:
        begin
          if not Builder.Open then
            StartPolyline(Builder, Current);
          AddQuadratic(Builder, Current, P0, P2, Tolerance);
          Current := P2;
        end;
      pcCubicTo:
        begin
          if not Builder.Open then
            StartPolyline(Builder, Current);
          AddCubic(Builder, Current, P0, P1, P2, Tolerance);
          Current := P2;
        end;
      pcClose:
        if Builder.Open then
        begin
          Line := @Builder.Lines[Builder.LineCount - 1];
          { The closing point, if it repeats the first, is implied. }
          if (Line^.Count > 1) and (Line^.Points[Line^.Count - 1].X = Line^.Points[0].X) and
             (Line^.Points[Line^.Count - 1].Y = Line^.Points[0].Y) then
            Dec(Line^.Count);
          Line^.Closed := True;
          Builder.Open := False;
          Current := Start;
        end;
    end;
  end;
  SetLength(Builder.Lines, Builder.LineCount);
  Result := Builder.Lines;
end;

procedure AddPolylinesToShape(var Shape: TCoverageShape; const Polylines: TPolylines);
var
  Index: LongInt;
  Point: LongInt;
  Next: LongInt;
begin
  for Index := 0 to High(Polylines) do
    with Polylines[Index] do
      if Count >= 2 then
        for Point := 0 to Count - 1 do
        begin
          Next := Point + 1;
          if Next = Count then
            Next := 0;
          AddShapeEdge(Shape, Points[Point].X, Points[Point].Y, Points[Next].X, Points[Next].Y);
        end;
end;

procedure TransformPolylines(var Polylines: TPolylines; const Transform: TAffineTransform);
var
  Index: LongInt;
  Point: LongInt;
begin
  for Index := 0 to High(Polylines) do
    for Point := 0 to Polylines[Index].Count - 1 do
      Polylines[Index].Points[Point] := TransformPoint(Transform, Polylines[Index].Points[Point].X,
        Polylines[Index].Points[Point].Y);
end;

procedure IncludeInBounds(var Bounds: TPathBounds; const Point: TPrecisePoint);
begin
  if Bounds.Empty then
  begin
    Bounds.Left := Point.X;
    Bounds.Right := Point.X;
    Bounds.Top := Point.Y;
    Bounds.Bottom := Point.Y;
    Bounds.Empty := False;
    Exit;
  end;
  if Point.X < Bounds.Left then
    Bounds.Left := Point.X;
  if Point.X > Bounds.Right then
    Bounds.Right := Point.X;
  if Point.Y < Bounds.Top then
    Bounds.Top := Point.Y;
  if Point.Y > Bounds.Bottom then
    Bounds.Bottom := Point.Y;
end;

function PathBounds(const Path: TPath; const Transform: TAffineTransform): TPathBounds;
var
  Index: LongInt;
  Point: LongInt;
  Last: LongInt;
begin
  Result.Left := 0;
  Result.Top := 0;
  Result.Right := 0;
  Result.Bottom := 0;
  Result.Empty := True;
  for Index := 0 to Path.Count - 1 do
  begin
    case Path.Commands[Index].Kind of
      pcQuadraticTo: Last := 1;
      pcCubicTo: Last := 2;
      pcClose: Continue;
      else
        Last := 0;
    end;
    for Point := 0 to Last do
      IncludeInBounds(Result, TransformPoint(Transform, Path.Commands[Index].Points[Point].X,
        Path.Commands[Index].Points[Point].Y));
    if Last < 2 then
      IncludeInBounds(Result, TransformPoint(Transform, Path.Commands[Index].Points[2].X,
        Path.Commands[Index].Points[2].Y));
  end;
end;

function PathTightBounds(const Path: TPath; const Transform: TAffineTransform): TPathBounds;
var
  Lines: TPolylines;
  Index: LongInt;
  Point: LongInt;
  Tolerance: Double;
begin
  Result.Left := 0;
  Result.Top := 0;
  Result.Right := 0;
  Result.Bottom := 0;
  Result := PathBounds(Path, Transform);
  if Result.Empty then
    Exit;
  { A thousandth of the path's size is close enough for a box. }
  Tolerance := Max(Result.Right - Result.Left, Result.Bottom - Result.Top) / 1000;
  if Tolerance <= 0 then
    Exit;
  Result.Empty := True;
  Lines := FlattenPath(Path, Transform, Tolerance);
  for Index := 0 to High(Lines) do
    for Point := 0 to Lines[Index].Count - 1 do
      IncludeInBounds(Result, Lines[Index].Points[Point]);
end;

end.
