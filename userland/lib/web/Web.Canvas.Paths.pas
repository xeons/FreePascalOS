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
  Canvas paths (HTML Standard 4.12.5.1.7, CanvasPath): the building
  methods shared by a context's current default path and Path2D, over
  libdrawing's TPath. A context transforms the points as they are added
  (its current transform), a Path2D keeps them as given (the identity),
  so every routine takes the transform to apply. Arcs and ellipses
  become cubic Beziers of at most a quarter turn each, which an affine
  transform keeps exact. Non-finite arguments make the call do nothing,
  as the standard asks; errors (a negative radius) are raised as
  ECanvasIndexSizeError or ECanvasRangeError.
}
unit Web.Canvas.Paths;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Drawing.Rasterizer,
  Drawing.Transforms,
  Drawing.Paths;

type
  ECanvasIndexSizeError = class(Exception);
  ECanvasRangeError = class(Exception);

  TCanvasPath = record
    Path: TPath;
    { No subpath yet (a new path): the next point starts one. }
    Empty: Boolean;
  end;
  PCanvasPath = ^TCanvasPath;

  { One corner radius of roundRect. }
  TCornerRadius = record
    X, Y: Double;
  end;
  TCornerRadii = array of TCornerRadius;

procedure ClearCanvasPath(out Path: TCanvasPath);
{ Every number finite. }
function AllFinite(const Values: array of Double): Boolean;

procedure CanvasMoveTo(var Path: TCanvasPath; const Transform: TAffineTransform; X, Y: Double);
procedure CanvasLineTo(var Path: TCanvasPath; const Transform: TAffineTransform; X, Y: Double);
procedure CanvasQuadraticCurveTo(var Path: TCanvasPath; const Transform: TAffineTransform;
  ControlX, ControlY, X, Y: Double);
procedure CanvasBezierCurveTo(var Path: TCanvasPath; const Transform: TAffineTransform;
  FirstX, FirstY, SecondX, SecondY, X, Y: Double);
procedure CanvasArcTo(var Path: TCanvasPath; const Transform: TAffineTransform; X1, Y1, X2, Y2, Radius: Double);
procedure CanvasArc(var Path: TCanvasPath; const Transform: TAffineTransform; X, Y, Radius, StartAngle,
  EndAngle: Double; Anticlockwise: Boolean);
procedure CanvasEllipse(var Path: TCanvasPath; const Transform: TAffineTransform; X, Y, RadiusX, RadiusY,
  Rotation, StartAngle, EndAngle: Double; Anticlockwise: Boolean);
procedure CanvasRect(var Path: TCanvasPath; const Transform: TAffineTransform; X, Y, Width, Height: Double);
{ Radii: one to four (else ECanvasRangeError); a radius with a
  non-finite part makes nothing (pass Valid False). }
procedure CanvasRoundRect(var Path: TCanvasPath; const Transform: TAffineTransform; X, Y, Width, Height: Double;
  Radii: TCornerRadii);
procedure CanvasClosePath(var Path: TCanvasPath);
{ Source's subpaths through Transform added to Path (Path2D.addPath). }
procedure CanvasAddPath(var Path: TCanvasPath; const Source: TCanvasPath; const Transform: TAffineTransform);

implementation

uses
  Math;

const
  TwoPi = 2 * Pi;

procedure ClearCanvasPath(out Path: TCanvasPath);
begin
  BeginPath(Path.Path);
  Path.Empty := True;
end;

function AllFinite(const Values: array of Double): Boolean;
var
  Index: Integer;
begin
  for Index := 0 to High(Values) do
    if IsNan(Values[Index]) or IsInfinite(Values[Index]) then
      Exit(False);
  Result := True;
end;

procedure MoveToPoint(var Path: TCanvasPath; const Point: TPrecisePoint);
begin
  PathMoveTo(Path.Path, Point.X, Point.Y);
  Path.Empty := False;
end;

{ A line to Point, or the start of a subpath there when there is none. }
procedure LineToPoint(var Path: TCanvasPath; const Point: TPrecisePoint);
begin
  if Path.Empty then
    MoveToPoint(Path, Point)
  else
    PathLineTo(Path.Path, Point.X, Point.Y);
end;

{ "Ensure there is a subpath" for (X, Y). }
procedure EnsureSubpath(var Path: TCanvasPath; const Transform: TAffineTransform; X, Y: Double);
begin
  if Path.Empty then
    MoveToPoint(Path, TransformPoint(Transform, X, Y));
end;

procedure CanvasMoveTo(var Path: TCanvasPath; const Transform: TAffineTransform; X, Y: Double);
begin
  if not AllFinite([X, Y]) then
    Exit;
  MoveToPoint(Path, TransformPoint(Transform, X, Y));
end;

procedure CanvasLineTo(var Path: TCanvasPath; const Transform: TAffineTransform; X, Y: Double);
begin
  if not AllFinite([X, Y]) then
    Exit;
  LineToPoint(Path, TransformPoint(Transform, X, Y));
end;

procedure CanvasQuadraticCurveTo(var Path: TCanvasPath; const Transform: TAffineTransform;
  ControlX, ControlY, X, Y: Double);
var
  Control, Target: TPrecisePoint;
begin
  if not AllFinite([ControlX, ControlY, X, Y]) then
    Exit;
  EnsureSubpath(Path, Transform, ControlX, ControlY);
  Control := TransformPoint(Transform, ControlX, ControlY);
  Target := TransformPoint(Transform, X, Y);
  PathQuadraticTo(Path.Path, Control.X, Control.Y, Target.X, Target.Y);
end;

procedure CanvasBezierCurveTo(var Path: TCanvasPath; const Transform: TAffineTransform;
  FirstX, FirstY, SecondX, SecondY, X, Y: Double);
var
  First, Second, Target: TPrecisePoint;
begin
  if not AllFinite([FirstX, FirstY, SecondX, SecondY, X, Y]) then
    Exit;
  EnsureSubpath(Path, Transform, FirstX, FirstY);
  First := TransformPoint(Transform, FirstX, FirstY);
  Second := TransformPoint(Transform, SecondX, SecondY);
  Target := TransformPoint(Transform, X, Y);
  PathCubicTo(Path.Path, First.X, First.Y, Second.X, Second.Y, Target.X, Target.Y);
end;

{ An arc of the ellipse (centre, radii, rotation) from angle Start
  through Sweep radians (negative: anticlockwise), joined to the path by
  a line (or starting a subpath). }
procedure AddEllipseArc(var Path: TCanvasPath; const Transform: TAffineTransform; CentreX, CentreY, RadiusX,
  RadiusY, Rotation, Start, Sweep: Double);
var
  CosR, SinR: Double;
  Pieces, Piece: Integer;
  Step, Angle, NextAngle, Handle: Double;
  First, Second, Target: TPrecisePoint;

  function EllipsePoint(Theta: Double): TPrecisePoint;
  var
    LocalX, LocalY: Double;
  begin
    LocalX := RadiusX * Cos(Theta);
    LocalY := RadiusY * Sin(Theta);
    Result := TransformPoint(Transform, CentreX + LocalX * CosR - LocalY * SinR,
      CentreY + LocalX * SinR + LocalY * CosR);
  end;

  { The point Distance along the tangent at Theta (in the ellipse's
    angle), from the point at Theta. }
  function TangentPoint(Theta, Distance: Double): TPrecisePoint;
  var
    LocalX, LocalY, DX, DY: Double;
  begin
    LocalX := RadiusX * Cos(Theta) - Distance * RadiusX * Sin(Theta);
    LocalY := RadiusY * Sin(Theta) + Distance * RadiusY * Cos(Theta);
    DX := LocalX * CosR - LocalY * SinR;
    DY := LocalX * SinR + LocalY * CosR;
    Result := TransformPoint(Transform, CentreX + DX, CentreY + DY);
  end;

begin
  CosR := Cos(Rotation);
  SinR := Sin(Rotation);
  LineToPoint(Path, EllipsePoint(Start));
  if Sweep = 0 then
    Exit;
  Pieces := Ceil(Abs(Sweep) / (Pi / 2) - 1E-9);
  if Pieces < 1 then
    Pieces := 1;
  Step := Sweep / Pieces;
  Handle := 4 / 3 * Tan(Step / 4);
  Angle := Start;
  for Piece := 1 to Pieces do
  begin
    NextAngle := Start + Step * Piece;
    First := TangentPoint(Angle, Handle);
    Second := TangentPoint(NextAngle, -Handle);
    Target := EllipsePoint(NextAngle);
    PathCubicTo(Path.Path, First.X, First.Y, Second.X, Second.Y, Target.X, Target.Y);
    Angle := NextAngle;
  end;
end;

{ The sweep from Start to End the standard describes (a whole turn at
  most, in the direction asked). }
function ArcSweep(Start, Finish: Double; Anticlockwise: Boolean): Double;
begin
  if not Anticlockwise and (Finish - Start >= TwoPi) then
    Exit(TwoPi);
  if Anticlockwise and (Start - Finish >= TwoPi) then
    Exit(-TwoPi);
  Result := Finish - Start;
  if not Anticlockwise then
  begin
    if Result < 0 then
    begin
      Result := FMod(Result, TwoPi);
      if Result < 0 then
        Result := Result + TwoPi;
      if Result = 0 then
        Result := TwoPi;
    end;
  end
  else if Result > 0 then
  begin
    Result := FMod(Result, TwoPi);
    if Result > 0 then
      Result := Result - TwoPi;
    if Result = 0 then
      Result := -TwoPi;
  end;
end;

procedure CanvasEllipse(var Path: TCanvasPath; const Transform: TAffineTransform; X, Y, RadiusX, RadiusY,
  Rotation, StartAngle, EndAngle: Double; Anticlockwise: Boolean);
begin
  if not AllFinite([X, Y, RadiusX, RadiusY, Rotation, StartAngle, EndAngle]) then
    Exit;
  if (RadiusX < 0) or (RadiusY < 0) then
    raise ECanvasIndexSizeError.Create('The radius provided is negative');
  AddEllipseArc(Path, Transform, X, Y, RadiusX, RadiusY, Rotation, StartAngle,
    ArcSweep(StartAngle, EndAngle, Anticlockwise));
end;

procedure CanvasArc(var Path: TCanvasPath; const Transform: TAffineTransform; X, Y, Radius, StartAngle,
  EndAngle: Double; Anticlockwise: Boolean);
begin
  if not AllFinite([X, Y, Radius, StartAngle, EndAngle]) then
    Exit;
  if Radius < 0 then
    raise ECanvasIndexSizeError.Create('The radius provided is negative');
  AddEllipseArc(Path, Transform, X, Y, Radius, Radius, 0, StartAngle,
    ArcSweep(StartAngle, EndAngle, Anticlockwise));
end;

procedure CanvasArcTo(var Path: TCanvasPath; const Transform: TAffineTransform; X1, Y1, X2, Y2, Radius: Double);
var
  Inverse: TAffineTransform;
  Last: TPrecisePoint;
  X0, Y0: Double;
  DX0, DY0, DX2, DY2, Length0, Length2: Double;
  Cosine, Angle, Distance: Double;
  StartX, StartY, EndX, EndY: Double;
  NormalX, NormalY, CentreX, CentreY: Double;
  StartAngle, EndAngle, Cross: Double;
begin
  if not AllFinite([X1, Y1, X2, Y2, Radius]) then
    Exit;
  if Radius < 0 then
    raise ECanvasIndexSizeError.Create('The radius provided is negative');
  EnsureSubpath(Path, Transform, X1, Y1);
  { The last point in the space of the arguments. }
  if not InvertTransform(Transform, Inverse) then
    Exit;
  Last := TransformPoint(Inverse, Path.Path.CurrentPoint.X, Path.Path.CurrentPoint.Y);
  X0 := Last.X;
  Y0 := Last.Y;
  DX0 := X0 - X1;
  DY0 := Y0 - Y1;
  DX2 := X2 - X1;
  DY2 := Y2 - Y1;
  Length0 := Sqrt(DX0 * DX0 + DY0 * DY0);
  Length2 := Sqrt(DX2 * DX2 + DY2 * DY2);
  Cross := DX0 * DY2 - DY0 * DX2;
  if ((X0 = X1) and (Y0 = Y1)) or ((X1 = X2) and (Y1 = Y2)) or (Radius = 0) or (Length0 = 0) or
     (Length2 = 0) or (Abs(Cross) < 1E-12 * Length0 * Length2) then
  begin
    LineToPoint(Path, TransformPoint(Transform, X1, Y1));
    Exit;
  end;
  Cosine := (DX0 * DX2 + DY0 * DY2) / (Length0 * Length2);
  if Cosine > 1 then
    Cosine := 1;
  if Cosine < -1 then
    Cosine := -1;
  Angle := ArcCos(Cosine);
  Distance := Radius / Tan(Angle / 2);
  StartX := X1 + DX0 / Length0 * Distance;
  StartY := Y1 + DY0 / Length0 * Distance;
  EndX := X1 + DX2 / Length2 * Distance;
  EndY := Y1 + DY2 / Length2 * Distance;
  { The centre is Radius from the start tangent point, on the side of
    the corner's inside. }
  NormalX := -DY0 / Length0;
  NormalY := DX0 / Length0;
  if NormalX * DX2 + NormalY * DY2 < 0 then
  begin
    NormalX := -NormalX;
    NormalY := -NormalY;
  end;
  CentreX := StartX + NormalX * Radius;
  CentreY := StartY + NormalY * Radius;
  StartAngle := ArcTan2(StartY - CentreY, StartX - CentreX);
  EndAngle := ArcTan2(EndY - CentreY, EndX - CentreX);
  { Clockwise (on the screen) when the turn from P0 P1 to P1 P2 is. }
  AddEllipseArc(Path, Transform, CentreX, CentreY, Radius, Radius, 0, StartAngle,
    ArcSweep(StartAngle, EndAngle, Cross > 0));
end;

procedure CanvasRect(var Path: TCanvasPath; const Transform: TAffineTransform; X, Y, Width, Height: Double);
begin
  if not AllFinite([X, Y, Width, Height]) then
    Exit;
  MoveToPoint(Path, TransformPoint(Transform, X, Y));
  PathLineTo(Path.Path, TransformPoint(Transform, X + Width, Y).X, TransformPoint(Transform, X + Width, Y).Y);
  PathLineTo(Path.Path, TransformPoint(Transform, X + Width, Y + Height).X,
    TransformPoint(Transform, X + Width, Y + Height).Y);
  PathLineTo(Path.Path, TransformPoint(Transform, X, Y + Height).X, TransformPoint(Transform, X, Y + Height).Y);
  PathClose(Path.Path);
  MoveToPoint(Path, TransformPoint(Transform, X, Y));
end;

procedure SwapRadii(var First, Second: TCornerRadius);
var
  Kept: TCornerRadius;
begin
  Kept := First;
  First := Second;
  Second := Kept;
end;

procedure CanvasRoundRect(var Path: TCanvasPath; const Transform: TAffineTransform; X, Y, Width, Height: Double;
  Radii: TCornerRadii);
var
  UpperLeft, UpperRight, LowerRight, LowerLeft: TCornerRadius;
  Index: Integer;
  Top, Right, Bottom, Left, Scale: Double;

  procedure Corner(CentreX, CentreY: Double; const Radius: TCornerRadius; Start: Double);
  begin
    if (Radius.X > 0) and (Radius.Y > 0) then
      AddEllipseArc(Path, Transform, CentreX, CentreY, Radius.X, Radius.Y, 0, Start, Pi / 2)
    else
      LineToPoint(Path, TransformPoint(Transform, CentreX, CentreY));
  end;

begin
  if not AllFinite([X, Y, Width, Height]) then
    Exit;
  if (Length(Radii) < 1) or (Length(Radii) > 4) then
    raise ECanvasRangeError.Create(IntToStr(Length(Radii)) + ' radii provided. Between one and four radii are necessary.');
  for Index := 0 to High(Radii) do
  begin
    if not AllFinite([Radii[Index].X, Radii[Index].Y]) then
      Exit;
    if (Radii[Index].X < 0) or (Radii[Index].Y < 0) then
      raise ECanvasRangeError.Create('A radius provided is negative');
  end;
  case Length(Radii) of
    1:
      begin
        UpperLeft := Radii[0]; UpperRight := Radii[0]; LowerRight := Radii[0]; LowerLeft := Radii[0];
      end;
    2:
      begin
        UpperLeft := Radii[0]; LowerRight := Radii[0]; UpperRight := Radii[1]; LowerLeft := Radii[1];
      end;
    3:
      begin
        UpperLeft := Radii[0]; UpperRight := Radii[1]; LowerLeft := Radii[1]; LowerRight := Radii[2];
      end;
  else
    begin
      UpperLeft := Radii[0]; UpperRight := Radii[1]; LowerRight := Radii[2]; LowerLeft := Radii[3];
    end;
  end;
  if Width < 0 then
  begin
    X := X + Width;
    Width := -Width;
    SwapRadii(UpperLeft, UpperRight);
    SwapRadii(LowerLeft, LowerRight);
  end;
  if Height < 0 then
  begin
    Y := Y + Height;
    Height := -Height;
    SwapRadii(UpperLeft, LowerLeft);
    SwapRadii(UpperRight, LowerRight);
  end;
  Top := UpperLeft.X + UpperRight.X;
  Right := UpperRight.Y + LowerRight.Y;
  Bottom := LowerRight.X + LowerLeft.X;
  Left := UpperLeft.Y + LowerLeft.Y;
  Scale := 1;
  if Top > 0 then
    Scale := Min(Scale, Width / Top);
  if Right > 0 then
    Scale := Min(Scale, Height / Right);
  if Bottom > 0 then
    Scale := Min(Scale, Width / Bottom);
  if Left > 0 then
    Scale := Min(Scale, Height / Left);
  if Scale < 1 then
  begin
    UpperLeft.X := UpperLeft.X * Scale; UpperLeft.Y := UpperLeft.Y * Scale;
    UpperRight.X := UpperRight.X * Scale; UpperRight.Y := UpperRight.Y * Scale;
    LowerRight.X := LowerRight.X * Scale; LowerRight.Y := LowerRight.Y * Scale;
    LowerLeft.X := LowerLeft.X * Scale; LowerLeft.Y := LowerLeft.Y * Scale;
  end;
  MoveToPoint(Path, TransformPoint(Transform, X + UpperLeft.X, Y));
  LineToPoint(Path, TransformPoint(Transform, X + Width - UpperRight.X, Y));
  if (UpperRight.X > 0) and (UpperRight.Y > 0) then
    Corner(X + Width - UpperRight.X, Y + UpperRight.Y, UpperRight, -Pi / 2);
  LineToPoint(Path, TransformPoint(Transform, X + Width, Y + Height - LowerRight.Y));
  if (LowerRight.X > 0) and (LowerRight.Y > 0) then
    Corner(X + Width - LowerRight.X, Y + Height - LowerRight.Y, LowerRight, 0);
  LineToPoint(Path, TransformPoint(Transform, X + LowerLeft.X, Y + Height));
  if (LowerLeft.X > 0) and (LowerLeft.Y > 0) then
    Corner(X + LowerLeft.X, Y + Height - LowerLeft.Y, LowerLeft, Pi / 2);
  LineToPoint(Path, TransformPoint(Transform, X, Y + UpperLeft.Y));
  if (UpperLeft.X > 0) and (UpperLeft.Y > 0) then
    Corner(X + UpperLeft.X, Y + UpperLeft.Y, UpperLeft, Pi);
  PathClose(Path.Path);
  MoveToPoint(Path, TransformPoint(Transform, X, Y));
end;

procedure CanvasClosePath(var Path: TCanvasPath);
begin
  if Path.Empty then
    Exit;
  PathClose(Path.Path);
end;

procedure CanvasAddPath(var Path: TCanvasPath; const Source: TCanvasPath; const Transform: TAffineTransform);
begin
  if Source.Path.Count = 0 then
    Exit;
  PathAppend(Path.Path, Source.Path, Transform);
  Path.Empty := False;
end;

end.
