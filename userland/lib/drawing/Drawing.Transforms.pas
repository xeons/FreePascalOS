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
  Affine transforms of the plane: a 2 x 3 matrix (A B, C D, E F) that
  takes (X, Y) to (A X + C Y + E, B X + D Y + F), as SVG's and the
  canvas API's matrix(a, b, c, d, e, f).

  CombineTransforms(Outer, Inner) is the transform that applies Inner
  first and Outer after it, so a child's transform combines as
  CombineTransforms(ParentTransform, ChildTransform).
}
unit Drawing.Transforms;

{$mode objfpc}

interface

uses
  Drawing.Rasterizer;

type
  TAffineTransform = record
    A: Double;
    B: Double;
    C: Double;
    D: Double;
    E: Double;
    F: Double;
  end;

function IdentityTransform: TAffineTransform;
function MakeTransform(A, B, C, D, E, F: Double): TAffineTransform;
function TranslationTransform(X, Y: Double): TAffineTransform;
function ScalingTransform(X, Y: Double): TAffineTransform;
{ A turn by Degrees, clockwise on the screen (y down). }
function RotationTransform(Degrees: Double): TAffineTransform;
function SkewXTransform(Degrees: Double): TAffineTransform;
function SkewYTransform(Degrees: Double): TAffineTransform;
{ Inner applied first, then Outer. }
function CombineTransforms(const Outer, Inner: TAffineTransform): TAffineTransform;
function TransformPoint(const Transform: TAffineTransform; X, Y: Double): TPrecisePoint;
{ A direction (no translation). }
function TransformVector(const Transform: TAffineTransform; X, Y: Double): TPrecisePoint;
{ False (and the identity) when the transform flattens the plane. }
function InvertTransform(const Transform: TAffineTransform; out Inverse: TAffineTransform): Boolean;
{ How much the transform scales lengths, on average (the square root of
  its determinant's size): for flattening tolerances and stroke widths
  given in one space and needed in the other. }
function TransformScale(const Transform: TAffineTransform): Double;
{ The transform only scales and translates (no turn or skew). }
function IsAxisAligned(const Transform: TAffineTransform): Boolean;
function IsIdentity(const Transform: TAffineTransform): Boolean;

implementation

uses
  Math;

function IdentityTransform: TAffineTransform;
begin
  Result := MakeTransform(1, 0, 0, 1, 0, 0);
end;

function MakeTransform(A, B, C, D, E, F: Double): TAffineTransform;
begin
  Result.A := A;
  Result.B := B;
  Result.C := C;
  Result.D := D;
  Result.E := E;
  Result.F := F;
end;

function TranslationTransform(X, Y: Double): TAffineTransform;
begin
  Result := MakeTransform(1, 0, 0, 1, X, Y);
end;

function ScalingTransform(X, Y: Double): TAffineTransform;
begin
  Result := MakeTransform(X, 0, 0, Y, 0, 0);
end;

function RotationTransform(Degrees: Double): TAffineTransform;
var
  Angle: Double;
begin
  Angle := DegToRad(Degrees);
  Result := MakeTransform(Cos(Angle), Sin(Angle), -Sin(Angle), Cos(Angle), 0, 0);
end;

function SkewXTransform(Degrees: Double): TAffineTransform;
begin
  Result := MakeTransform(1, 0, Tan(DegToRad(Degrees)), 1, 0, 0);
end;

function SkewYTransform(Degrees: Double): TAffineTransform;
begin
  Result := MakeTransform(1, Tan(DegToRad(Degrees)), 0, 1, 0, 0);
end;

function CombineTransforms(const Outer, Inner: TAffineTransform): TAffineTransform;
begin
  Result.A := Outer.A * Inner.A + Outer.C * Inner.B;
  Result.B := Outer.B * Inner.A + Outer.D * Inner.B;
  Result.C := Outer.A * Inner.C + Outer.C * Inner.D;
  Result.D := Outer.B * Inner.C + Outer.D * Inner.D;
  Result.E := Outer.A * Inner.E + Outer.C * Inner.F + Outer.E;
  Result.F := Outer.B * Inner.E + Outer.D * Inner.F + Outer.F;
end;

function TransformPoint(const Transform: TAffineTransform; X, Y: Double): TPrecisePoint;
begin
  Result.X := Transform.A * X + Transform.C * Y + Transform.E;
  Result.Y := Transform.B * X + Transform.D * Y + Transform.F;
end;

function TransformVector(const Transform: TAffineTransform; X, Y: Double): TPrecisePoint;
begin
  Result.X := Transform.A * X + Transform.C * Y;
  Result.Y := Transform.B * X + Transform.D * Y;
end;

function InvertTransform(const Transform: TAffineTransform; out Inverse: TAffineTransform): Boolean;
var
  Determinant: Double;
begin
  Determinant := Transform.A * Transform.D - Transform.B * Transform.C;
  if Abs(Determinant) < 1E-12 then
  begin
    Inverse := IdentityTransform;
    Exit(False);
  end;
  Inverse.A := Transform.D / Determinant;
  Inverse.B := -Transform.B / Determinant;
  Inverse.C := -Transform.C / Determinant;
  Inverse.D := Transform.A / Determinant;
  Inverse.E := (Transform.C * Transform.F - Transform.D * Transform.E) / Determinant;
  Inverse.F := (Transform.B * Transform.E - Transform.A * Transform.F) / Determinant;
  Result := True;
end;

function TransformScale(const Transform: TAffineTransform): Double;
begin
  Result := Sqrt(Abs(Transform.A * Transform.D - Transform.B * Transform.C));
end;

function IsAxisAligned(const Transform: TAffineTransform): Boolean;
begin
  Result := (Abs(Transform.B) < 1E-9) and (Abs(Transform.C) < 1E-9);
end;

function IsIdentity(const Transform: TAffineTransform): Boolean;
begin
  Result := IsAxisAligned(Transform) and (Abs(Transform.A - 1) < 1E-12) and (Abs(Transform.D - 1) < 1E-12) and
    (Abs(Transform.E) < 1E-12) and (Abs(Transform.F) < 1E-12);
end;

end.
