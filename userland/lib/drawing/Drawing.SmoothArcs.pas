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
  Anti-aliased sectors of a circle (a pie's slices) and of a ring (a
  doughnut's), filled through the rasterizer like Drawing.SmoothShapes.

  Angles are in degrees, 0 at the top (twelve o'clock) and growing
  clockwise on the screen, as a pie chart is read. The centre is in the
  rasterizer's coordinates (pixel (X, Y) is the square from (X, Y) to
  (X + 1, Y + 1)). A sector of a ring runs along the outer arc from the
  start to the end and back along the inner one; with no inner radius
  it is a slice from the centre. A sweep of 360 or more is the whole
  circle (or ring).
}
unit Drawing.SmoothArcs;

{$mode objfpc}

interface

uses
  Drawing.Colors,
  Drawing.Canvas,
  Drawing.Rasterizer;

{ The point at Angle on the circle of Radius around (CentreX, CentreY). }
function PointOnCircle(CentreX, CentreY, Radius, Angle: Double): TPrecisePoint;
{ The outline of the sector added to Shape (InnerRadius 0: a slice). }
procedure AddShapeSector(var Shape: TCoverageShape; CentreX, CentreY, OuterRadius, InnerRadius, StartAngle,
  SweepAngle: Double);
procedure FillSmoothSector(const Canvas: TCanvas; CentreX, CentreY, OuterRadius, InnerRadius, StartAngle,
  SweepAngle: Double; Color: TColor);

implementation

uses
  Math;

const
  { How far an edge may stray from the arc, in pixels. }
  Tolerance = 0.05;
  MaximumStepsPerTurn = 1024;
  FullTurn = 360.0;

function PointOnCircle(CentreX, CentreY, Radius, Angle: Double): TPrecisePoint;
var
  Radians: Double;
begin
  Radians := Angle * Pi / 180;
  Result := PrecisePoint(CentreX + Radius * Sin(Radians), CentreY - Radius * Cos(Radians));
end;

{ Enough straight pieces for an arc of Sweep degrees of Radius that none
  strays more than the tolerance from it. }
function StepsFor(Radius, Sweep: Double): LongInt;
var
  PerTurn: LongInt;
begin
  if Radius <= Tolerance then
    PerTurn := 8
  else
    PerTurn := Trunc(Pi / ArcCos(1 - Tolerance / Radius)) + 1;
  if PerTurn > MaximumStepsPerTurn then
    PerTurn := MaximumStepsPerTurn;
  if PerTurn < 8 then
    PerTurn := 8;
  Result := Trunc(PerTurn * Sweep / FullTurn) + 1;
end;

{ The arc's points from StartAngle through SweepAngle (backwards if
  Reverse) appended to Points from Count on. }
procedure AppendArc(var Points: array of TPrecisePoint; var Count: LongInt; CentreX, CentreY, Radius, StartAngle,
  SweepAngle: Double; Steps: LongInt; Reverse: Boolean);
var
  Step: LongInt;
  Angle: Double;
begin
  for Step := 0 to Steps do
  begin
    if Reverse then
      Angle := StartAngle + SweepAngle * (Steps - Step) / Steps
    else
      Angle := StartAngle + SweepAngle * Step / Steps;
    Points[Count] := PointOnCircle(CentreX, CentreY, Radius, Angle);
    Inc(Count);
  end;
end;

procedure AddShapeSector(var Shape: TCoverageShape; CentreX, CentreY, OuterRadius, InnerRadius, StartAngle,
  SweepAngle: Double);
var
  Points: array of TPrecisePoint;
  Count: LongInt;
  Steps: LongInt;
begin
  if (OuterRadius <= 0) or (SweepAngle <= 0) then
    Exit;
  if SweepAngle >= FullTurn then
  begin
    { The whole circle, and the hole the other way round. }
    AddShapeEllipse(Shape, CentreX, CentreY, OuterRadius, OuterRadius, True);
    if InnerRadius > 0 then
      AddShapeEllipse(Shape, CentreX, CentreY, InnerRadius, InnerRadius, False);
    Exit;
  end;
  Steps := StepsFor(OuterRadius, SweepAngle);
  Points := nil;
  SetLength(Points, 2 * (Steps + 1) + 1);
  Count := 0;
  AppendArc(Points, Count, CentreX, CentreY, OuterRadius, StartAngle, SweepAngle, Steps, False);
  if InnerRadius > 0 then
    AppendArc(Points, Count, CentreX, CentreY, InnerRadius, StartAngle, SweepAngle, Steps, True)
  else
  begin
    Points[Count] := PrecisePoint(CentreX, CentreY);
    Inc(Count);
  end;
  AddShapePolygon(Shape, Points[0..Count - 1]);
end;

procedure FillSmoothSector(const Canvas: TCanvas; CentreX, CentreY, OuterRadius, InnerRadius, StartAngle,
  SweepAngle: Double; Color: TColor);
var
  Shape: TCoverageShape;
begin
  BeginShape(Shape);
  AddShapeSector(Shape, CentreX, CentreY, OuterRadius, InnerRadius, StartAngle, SweepAngle);
  if Shape.Count > 0 then
    FillShape(Canvas, Shape, Color);
end;

end.
