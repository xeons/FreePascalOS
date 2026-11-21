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
  The 2D matrix of a transform (CSS Transforms 1 and 2): the transform
  list's functions and the translate, rotate and scale properties, with
  3D functions flattened to the plane (matrix3d's 2D part, translateZ
  and perspective dropped, rotateX and rotateY as the scaling their
  projection gives), and the 2D decomposition and recomposition used to
  interpolate transforms that do not match function by function.

  A matrix (A B C D E F) takes (x, y) to (A x + C y + E, B x + D y + F).
  Lengths are px (or relative units against the font size given);
  percentages are of the reference box.
}
unit Css.TransformMatrices;

{$mode objfpc}
{$H+}

interface

uses
  Css.Values;

type
  TCssMatrix2D = record
    A, B, C, D, E, F: Double;
  end;

  { A 2D matrix taken apart (CSS Transforms 1, "Interpolation of
    matrices"). }
  TCssDecomposedMatrix = record
    TranslateX, TranslateY: Double;
    ScaleX, ScaleY: Double;
    { Degrees. }
    Angle: Double;
    M11, M12, M21, M22: Double;
  end;

function IdentityMatrix: TCssMatrix2D;
{ Inner applied first, then Outer. }
function MultiplyMatrices(const Outer, Inner: TCssMatrix2D): TCssMatrix2D;
function IsIdentityMatrix(const Matrix: TCssMatrix2D): Boolean;
{ Only a translation. }
function IsTranslationMatrix(const Matrix: TCssMatrix2D): Boolean;
{ One transform function's matrix. }
function FunctionMatrix(Func: TCssValue; Width, Height, FontSize: Double): TCssMatrix2D;
{ A transform list's matrix (none: the identity). }
function TransformListMatrix(List: TCssValue; Width, Height, FontSize: Double): TCssMatrix2D;
{ The translate, rotate and scale properties' matrices (none: nil). }
function TranslatePropertyMatrix(Value: TCssValue; Width, Height, FontSize: Double): TCssMatrix2D;
function RotatePropertyMatrix(Value: TCssValue): TCssMatrix2D;
function ScalePropertyMatrix(Value: TCssValue): TCssMatrix2D;
{ A length (or calc, or percentage of Basis) argument in px. }
function ArgumentPixels(Value: TCssValue; Basis, FontSize: Double): Double;
{ An angle argument in degrees. }
function ArgumentDegrees(Value: TCssValue): Double;
function DecomposeMatrix(const Matrix: TCssMatrix2D; out Parts: TCssDecomposedMatrix): Boolean;
function RecomposeMatrix(const Parts: TCssDecomposedMatrix): TCssMatrix2D;
function InterpolateMatrices(const From, Target: TCssMatrix2D; Progress: Double): TCssMatrix2D;

implementation

uses
  Math, Css.Units, Css.Calc;

function MakeMatrix(A, B, C, D, E, F: Double): TCssMatrix2D;
begin
  Result.A := A;
  Result.B := B;
  Result.C := C;
  Result.D := D;
  Result.E := E;
  Result.F := F;
end;

function IdentityMatrix: TCssMatrix2D;
begin
  Result := MakeMatrix(1, 0, 0, 1, 0, 0);
end;

function MultiplyMatrices(const Outer, Inner: TCssMatrix2D): TCssMatrix2D;
begin
  Result.A := Outer.A * Inner.A + Outer.C * Inner.B;
  Result.B := Outer.B * Inner.A + Outer.D * Inner.B;
  Result.C := Outer.A * Inner.C + Outer.C * Inner.D;
  Result.D := Outer.B * Inner.C + Outer.D * Inner.D;
  Result.E := Outer.A * Inner.E + Outer.C * Inner.F + Outer.E;
  Result.F := Outer.B * Inner.E + Outer.D * Inner.F + Outer.F;
end;

function IsIdentityMatrix(const Matrix: TCssMatrix2D): Boolean;
begin
  Result := IsTranslationMatrix(Matrix) and (Abs(Matrix.E) < 1E-9) and (Abs(Matrix.F) < 1E-9);
end;

function IsTranslationMatrix(const Matrix: TCssMatrix2D): Boolean;
begin
  Result := (Abs(Matrix.A - 1) < 1E-9) and (Abs(Matrix.B) < 1E-9) and (Abs(Matrix.C) < 1E-9) and
    (Abs(Matrix.D - 1) < 1E-9);
end;

function ArgumentPixels(Value: TCssValue; Basis, FontSize: Double): Double;
var
  Pixels, Percent: Double;
begin
  Result := 0;
  if Value = nil then
    Exit;
  case Value.Kind of
    vkDimension:
      case Value.UnitValue of
        cuEm: Result := Value.Number * FontSize;
        cuRem: Result := Value.Number * 16;
        cuEx: Result := Value.Number * FontSize / 2;
        cuCh: Result := Value.Number * FontSize / 2;
      else
        Result := Value.Number * CanonicalFactor(Value.UnitValue);
      end;
    vkPercentage:
      Result := Value.Number * Basis / 100;
    vkNumber, vkInteger:
      Result := Value.Number;
    vkCalc:
      if CalcAsLengthPercentage(Value.Calc, Pixels, Percent) then
        Result := Pixels + Percent * Basis / 100;
  end;
end;

function ArgumentDegrees(Value: TCssValue): Double;
begin
  Result := 0;
  if Value = nil then
    Exit;
  if Value.Kind = vkDimension then
    Result := Value.Number * CanonicalFactor(Value.UnitValue);
end;

function ArgumentNumber(Value: TCssValue): Double;
begin
  Result := 0;
  if Value = nil then
    Exit;
  if Value.Kind in [vkNumber, vkInteger] then
    Result := Value.Number
  else if Value.Kind = vkPercentage then
    Result := Value.Number / 100;
end;

function Rotation(Degrees: Double): TCssMatrix2D;
var
  Radians: Double;
begin
  Radians := DegToRad(Degrees);
  Result := MakeMatrix(Cos(Radians), Sin(Radians), -Sin(Radians), Cos(Radians), 0, 0);
end;

function Item(Func: TCssValue; Index: Integer): TCssValue; inline;
begin
  if Index < Func.Count then
    Result := Func.Items[Index]
  else
    Result := nil;
end;

function FunctionMatrix(Func: TCssValue; Width, Height, FontSize: Double): TCssMatrix2D;
var
  Name: string;
  X, Y: Double;
begin
  Result := IdentityMatrix;
  if (Func = nil) or (Func.Kind <> vkFunction) then
    Exit;
  Name := Func.Text;
  if Name = 'matrix' then
  begin
    if Func.Count = 6 then
      Result := MakeMatrix(ArgumentNumber(Func.Items[0]), ArgumentNumber(Func.Items[1]), ArgumentNumber(Func.Items[2]),
        ArgumentNumber(Func.Items[3]), ArgumentNumber(Func.Items[4]), ArgumentNumber(Func.Items[5]));
  end
  else if Name = 'matrix3d' then
  begin
    { The 2D part of the 4x4 matrix (column major): m11 m12 m21 m22 m41 m42. }
    if Func.Count = 16 then
      Result := MakeMatrix(ArgumentNumber(Func.Items[0]), ArgumentNumber(Func.Items[1]), ArgumentNumber(Func.Items[4]),
        ArgumentNumber(Func.Items[5]), ArgumentNumber(Func.Items[12]), ArgumentNumber(Func.Items[13]));
  end
  else if (Name = 'translate') or (Name = 'translate3d') then
    Result := MakeMatrix(1, 0, 0, 1, ArgumentPixels(Item(Func, 0), Width, FontSize),
      ArgumentPixels(Item(Func, 1), Height, FontSize))
  else if Name = 'translatex' then
    Result := MakeMatrix(1, 0, 0, 1, ArgumentPixels(Item(Func, 0), Width, FontSize), 0)
  else if Name = 'translatey' then
    Result := MakeMatrix(1, 0, 0, 1, 0, ArgumentPixels(Item(Func, 0), Height, FontSize))
  else if (Name = 'scale') or (Name = 'scale3d') then
  begin
    X := ArgumentNumber(Item(Func, 0));
    if Func.Count >= 2 then
      Y := ArgumentNumber(Item(Func, 1))
    else
      Y := X;
    Result := MakeMatrix(X, 0, 0, Y, 0, 0);
  end
  else if Name = 'scalex' then
    Result := MakeMatrix(ArgumentNumber(Item(Func, 0)), 0, 0, 1, 0, 0)
  else if Name = 'scaley' then
    Result := MakeMatrix(1, 0, 0, ArgumentNumber(Item(Func, 0)), 0, 0)
  else if (Name = 'rotate') or (Name = 'rotatez') then
    Result := Rotation(ArgumentDegrees(Item(Func, 0)))
  else if Name = 'rotatex' then
    { Seen from the front, a turn about the x axis squashes y. }
    Result := MakeMatrix(1, 0, 0, Cos(DegToRad(ArgumentDegrees(Item(Func, 0)))), 0, 0)
  else if Name = 'rotatey' then
    Result := MakeMatrix(Cos(DegToRad(ArgumentDegrees(Item(Func, 0)))), 0, 0, 1, 0, 0)
  else if Name = 'rotate3d' then
  begin
    { Only the part about the z axis turns the plane. }
    if (Func.Count = 4) and (Abs(ArgumentNumber(Func.Items[0])) < 1E-9) and
      (Abs(ArgumentNumber(Func.Items[1])) < 1E-9) then
    begin
      if ArgumentNumber(Func.Items[2]) < 0 then
        Result := Rotation(-ArgumentDegrees(Func.Items[3]))
      else
        Result := Rotation(ArgumentDegrees(Func.Items[3]));
    end;
  end
  else if Name = 'skew' then
  begin
    X := Tan(DegToRad(ArgumentDegrees(Item(Func, 0))));
    Y := Tan(DegToRad(ArgumentDegrees(Item(Func, 1))));
    Result := MakeMatrix(1, Y, X, 1, 0, 0);
  end
  else if Name = 'skewx' then
    Result := MakeMatrix(1, 0, Tan(DegToRad(ArgumentDegrees(Item(Func, 0)))), 1, 0, 0)
  else if Name = 'skewy' then
    Result := MakeMatrix(1, Tan(DegToRad(ArgumentDegrees(Item(Func, 0)))), 0, 1, 0, 0);
  { translateZ, scaleZ and perspective do not change the plane. }
end;

function TransformListMatrix(List: TCssValue; Width, Height, FontSize: Double): TCssMatrix2D;
var
  Index: Integer;
begin
  Result := IdentityMatrix;
  if List = nil then
    Exit;
  if List.Kind = vkFunction then
    Exit(FunctionMatrix(List, Width, Height, FontSize));
  if List.Kind <> vkList then
    Exit;
  for Index := 0 to List.Count - 1 do
    Result := MultiplyMatrices(Result, FunctionMatrix(List.Items[Index], Width, Height, FontSize));
end;

function TranslatePropertyMatrix(Value: TCssValue; Width, Height, FontSize: Double): TCssMatrix2D;
begin
  Result := IdentityMatrix;
  if (Value = nil) or (Value.Kind = vkKeyword) then
    Exit;
  if Value.Kind = vkList then
  begin
    if Value.Count >= 1 then
      Result.E := ArgumentPixels(Value.Items[0], Width, FontSize);
    if Value.Count >= 2 then
      Result.F := ArgumentPixels(Value.Items[1], Height, FontSize);
  end
  else
    Result.E := ArgumentPixels(Value, Width, FontSize);
end;

function RotatePropertyMatrix(Value: TCssValue): TCssMatrix2D;
var
  Axis: TCssValue;
  Angle: Double;
begin
  Result := IdentityMatrix;
  if (Value = nil) or (Value.Kind = vkKeyword) then
    Exit;
  if Value.Kind = vkDimension then
    Exit(Rotation(ArgumentDegrees(Value)));
  if (Value.Kind <> vkList) or (Value.Count < 2) then
    Exit;
  Axis := Value.Items[0];
  Angle := ArgumentDegrees(Value.Items[1]);
  if Axis.Kind = vkKeyword then
  begin
    { x and y squash the plane; z turns it. }
    case Axis.Serialize of
      'x': Result := MakeMatrix(1, 0, 0, Cos(DegToRad(Angle)), 0, 0);
      'y': Result := MakeMatrix(Cos(DegToRad(Angle)), 0, 0, 1, 0, 0);
    else
      Result := Rotation(Angle);
    end;
  end
  else if (Axis.Kind = vkList) and (Axis.Count = 3) and (Abs(ArgumentNumber(Axis.Items[0])) < 1E-9) and
    (Abs(ArgumentNumber(Axis.Items[1])) < 1E-9) then
  begin
    if ArgumentNumber(Axis.Items[2]) < 0 then
      Angle := -Angle;
    Result := Rotation(Angle);
  end;
end;

function ScalePropertyMatrix(Value: TCssValue): TCssMatrix2D;
var
  X, Y: Double;
begin
  Result := IdentityMatrix;
  if (Value = nil) or (Value.Kind = vkKeyword) then
    Exit;
  if Value.Kind = vkList then
  begin
    if Value.Count = 0 then
      Exit;
    X := ArgumentNumber(Value.Items[0]);
    if Value.Count >= 2 then
      Y := ArgumentNumber(Value.Items[1])
    else
      Y := X;
  end
  else
  begin
    X := ArgumentNumber(Value);
    Y := X;
  end;
  Result := MakeMatrix(X, 0, 0, Y, 0, 0);
end;

function DecomposeMatrix(const Matrix: TCssMatrix2D; out Parts: TCssDecomposedMatrix): Boolean;
var
  Row0X, Row0Y, Row1X, Row1Y, Determinant, Shear: Double;
begin
  Parts := Default(TCssDecomposedMatrix);
  Row0X := Matrix.A;
  Row0Y := Matrix.B;
  Row1X := Matrix.C;
  Row1Y := Matrix.D;
  Parts.TranslateX := Matrix.E;
  Parts.TranslateY := Matrix.F;
  Parts.ScaleX := Sqrt(Row0X * Row0X + Row0Y * Row0Y);
  Parts.ScaleY := Sqrt(Row1X * Row1X + Row1Y * Row1Y);
  Determinant := Row0X * Row1Y - Row0Y * Row1X;
  if Determinant < 0 then
  begin
    if Row0X < Row1Y then
      Parts.ScaleX := -Parts.ScaleX
    else
      Parts.ScaleY := -Parts.ScaleY;
  end;
  if Parts.ScaleX <> 0 then
  begin
    Row0X := Row0X / Parts.ScaleX;
    Row0Y := Row0Y / Parts.ScaleX;
  end;
  if Parts.ScaleY <> 0 then
  begin
    Row1X := Row1X / Parts.ScaleY;
    Row1Y := Row1Y / Parts.ScaleY;
  end;
  Parts.Angle := RadToDeg(ArcTan2(Row0Y, Row0X));
  if Parts.Angle <> 0 then
  begin
    { Take the rotation out of the remaining matrix. }
    Shear := DegToRad(Parts.Angle);
    Parts.M11 := Cos(Shear) * Row0X + Sin(Shear) * Row0Y;
    Parts.M12 := -Sin(Shear) * Row0X + Cos(Shear) * Row0Y;
    Parts.M21 := Cos(Shear) * Row1X + Sin(Shear) * Row1Y;
    Parts.M22 := -Sin(Shear) * Row1X + Cos(Shear) * Row1Y;
  end
  else
  begin
    Parts.M11 := Row0X;
    Parts.M12 := Row0Y;
    Parts.M21 := Row1X;
    Parts.M22 := Row1Y;
  end;
  Result := True;
end;

function RecomposeMatrix(const Parts: TCssDecomposedMatrix): TCssMatrix2D;
var
  Inner, Turn: TCssMatrix2D;
begin
  Inner := MakeMatrix(Parts.M11, Parts.M12, Parts.M21, Parts.M22, 0, 0);
  Turn := Rotation(Parts.Angle);
  Result := MakeMatrix(1, 0, 0, 1, Parts.TranslateX, Parts.TranslateY);
  Result := MultiplyMatrices(Result, Turn);
  Result := MultiplyMatrices(Result, Inner);
  Result := MultiplyMatrices(Result, MakeMatrix(Parts.ScaleX, 0, 0, Parts.ScaleY, 0, 0));
end;

function InterpolateMatrices(const From, Target: TCssMatrix2D; Progress: Double): TCssMatrix2D;
var
  A, B, Parts: TCssDecomposedMatrix;

  function Mix(X, Y: Double): Double;
  begin
    Result := X + (Y - X) * Progress;
  end;

begin
  DecomposeMatrix(From, A);
  DecomposeMatrix(Target, B);
  { Flip one way so the shorter turn is taken. }
  if ((A.ScaleX < 0) and (B.ScaleY < 0)) or ((A.ScaleY < 0) and (B.ScaleX < 0)) then
  begin
    A.ScaleX := -A.ScaleX;
    A.ScaleY := -A.ScaleY;
    if A.Angle < 0 then
      A.Angle := A.Angle + 180
    else
      A.Angle := A.Angle - 180;
  end;
  if A.Angle = 0 then
    A.Angle := 360;
  if B.Angle = 0 then
    B.Angle := 360;
  if Abs(A.Angle - B.Angle) > 180 then
  begin
    if A.Angle > B.Angle then
      A.Angle := A.Angle - 360
    else
      B.Angle := B.Angle - 360;
  end;
  Parts.TranslateX := Mix(A.TranslateX, B.TranslateX);
  Parts.TranslateY := Mix(A.TranslateY, B.TranslateY);
  Parts.ScaleX := Mix(A.ScaleX, B.ScaleX);
  Parts.ScaleY := Mix(A.ScaleY, B.ScaleY);
  Parts.Angle := Mix(A.Angle, B.Angle);
  Parts.M11 := Mix(A.M11, B.M11);
  Parts.M12 := Mix(A.M12, B.M12);
  Parts.M21 := Mix(A.M21, B.M21);
  Parts.M22 := Mix(A.M22, B.M22);
  Result := RecomposeMatrix(Parts);
end;

end.
