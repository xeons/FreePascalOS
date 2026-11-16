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
  The colour arithmetic of colour management: XYZ colours and 3 x 3
  matrices in double precision, chromaticities, Bradford chromatic
  adaptation, CIE Lab, and sRGB's own numbers.

  ICC profiles connect through the profile connection space (PCS),
  CIE XYZ (or Lab) relative to the D50 illuminant. sRGB is defined with
  D65 white; its matrix to the PCS is worked out from its primaries and
  adapted to D50 with Bradford's method, as LittleCMS does it, so the
  two agree.
}
unit Image.ColorProfiles.Matrices;

{$mode objfpc}
{$H+}

interface

type
  TColorVector = array[0..2] of Double;
  TColorMatrix = array[0..2, 0..2] of Double;

  TChromaticity = record
    X: Double;
    Y: Double;
  end;

const
  { The PCS illuminant (ICC: X 0.9642, Y 1.0, Z 0.8249). }
  WhiteD50: TColorVector = (0.9642, 1.0, 0.8249);
  ChromaticityD65: TChromaticity = (X: 0.3127; Y: 0.3290);
  SrgbRed: TChromaticity = (X: 0.64; Y: 0.33);
  SrgbGreen: TChromaticity = (X: 0.30; Y: 0.60);
  SrgbBlue: TChromaticity = (X: 0.15; Y: 0.06);

function IdentityMatrix: TColorMatrix;
function MultiplyMatrices(const Left, Right: TColorMatrix): TColorMatrix;
function ApplyMatrix(const Matrix: TColorMatrix; const Vector: TColorVector): TColorVector;
{ False when Matrix has no inverse (Inverse is then the identity). }
function InvertMatrix(const Matrix: TColorMatrix; out Inverse: TColorMatrix): Boolean;
{ The matrix whose columns are First, Second and Third. }
function MatrixFromColumns(const First, Second, Third: TColorVector): TColorMatrix;
function MakeVector(First, Second, Third: Double): TColorVector;
{ The largest difference between two matrices' entries. }
function MatrixDistance(const First, Second: TColorMatrix): Double;
{ The largest difference between two vectors' entries. }
function VectorDistance(const First, Second: TColorVector): Double;

{ The XYZ of a chromaticity at Y = 1. }
function ChromaticityToXyz(const Chromaticity: TChromaticity): TColorVector;
{ The matrix from linear RGB with these primaries and white to XYZ
  relative to that white. False for primaries that make no RGB space. }
function RgbToXyzMatrix(const Red, Green, Blue, White: TChromaticity; out Matrix: TColorMatrix): Boolean;
{ Bradford's adaptation of XYZ colours seen under SourceWhite to how
  they look under TargetWhite. }
function BradfordAdaptation(const SourceWhite, TargetWhite: TColorVector): TColorMatrix;
{ Linear sRGB to the PCS (XYZ relative to D50), and back. }
function SrgbToPcsMatrix: TColorMatrix;
function PcsToSrgbMatrix: TColorMatrix;

{ CIE Lab (relative to D50) to XYZ. }
function LabToXyz(Lightness, A, B: Double): TColorVector;

{ sRGB's transfer functions on values from 0 to 1: the encoded value
  to linear light and back (clamped to 0 to 1). }
function SrgbToLinear(Value: Double): Double;
function LinearToSrgb(Value: Double): Double;

implementation

uses
  Math;

function IdentityMatrix: TColorMatrix;
var
  Row: LongInt;
  Column: LongInt;
begin
  for Row := 0 to 2 do
    for Column := 0 to 2 do
      if Row = Column then
        Result[Row, Column] := 1
      else
        Result[Row, Column] := 0;
end;

function MultiplyMatrices(const Left, Right: TColorMatrix): TColorMatrix;
var
  Row: LongInt;
  Column: LongInt;
  Index: LongInt;
  Sum: Double;
begin
  for Row := 0 to 2 do
    for Column := 0 to 2 do
    begin
      Sum := 0;
      for Index := 0 to 2 do
        Sum := Sum + Left[Row, Index] * Right[Index, Column];
      Result[Row, Column] := Sum;
    end;
end;

function ApplyMatrix(const Matrix: TColorMatrix; const Vector: TColorVector): TColorVector;
var
  Row: LongInt;
begin
  for Row := 0 to 2 do
    Result[Row] := Matrix[Row, 0] * Vector[0] + Matrix[Row, 1] * Vector[1] + Matrix[Row, 2] * Vector[2];
end;

function InvertMatrix(const Matrix: TColorMatrix; out Inverse: TColorMatrix): Boolean;
var
  Determinant: Double;
begin
  Determinant :=
    Matrix[0, 0] * (Matrix[1, 1] * Matrix[2, 2] - Matrix[1, 2] * Matrix[2, 1]) -
    Matrix[0, 1] * (Matrix[1, 0] * Matrix[2, 2] - Matrix[1, 2] * Matrix[2, 0]) +
    Matrix[0, 2] * (Matrix[1, 0] * Matrix[2, 1] - Matrix[1, 1] * Matrix[2, 0]);
  if Abs(Determinant) < 1e-12 then
  begin
    Inverse := IdentityMatrix;
    Exit(False);
  end;
  Inverse[0, 0] := (Matrix[1, 1] * Matrix[2, 2] - Matrix[1, 2] * Matrix[2, 1]) / Determinant;
  Inverse[0, 1] := (Matrix[0, 2] * Matrix[2, 1] - Matrix[0, 1] * Matrix[2, 2]) / Determinant;
  Inverse[0, 2] := (Matrix[0, 1] * Matrix[1, 2] - Matrix[0, 2] * Matrix[1, 1]) / Determinant;
  Inverse[1, 0] := (Matrix[1, 2] * Matrix[2, 0] - Matrix[1, 0] * Matrix[2, 2]) / Determinant;
  Inverse[1, 1] := (Matrix[0, 0] * Matrix[2, 2] - Matrix[0, 2] * Matrix[2, 0]) / Determinant;
  Inverse[1, 2] := (Matrix[0, 2] * Matrix[1, 0] - Matrix[0, 0] * Matrix[1, 2]) / Determinant;
  Inverse[2, 0] := (Matrix[1, 0] * Matrix[2, 1] - Matrix[1, 1] * Matrix[2, 0]) / Determinant;
  Inverse[2, 1] := (Matrix[0, 1] * Matrix[2, 0] - Matrix[0, 0] * Matrix[2, 1]) / Determinant;
  Inverse[2, 2] := (Matrix[0, 0] * Matrix[1, 1] - Matrix[0, 1] * Matrix[1, 0]) / Determinant;
  Result := True;
end;

function MatrixFromColumns(const First, Second, Third: TColorVector): TColorMatrix;
var
  Row: LongInt;
begin
  for Row := 0 to 2 do
  begin
    Result[Row, 0] := First[Row];
    Result[Row, 1] := Second[Row];
    Result[Row, 2] := Third[Row];
  end;
end;

function MakeVector(First, Second, Third: Double): TColorVector;
begin
  Result[0] := First;
  Result[1] := Second;
  Result[2] := Third;
end;

function MatrixDistance(const First, Second: TColorMatrix): Double;
var
  Row: LongInt;
  Column: LongInt;
begin
  Result := 0;
  for Row := 0 to 2 do
    for Column := 0 to 2 do
      Result := Max(Result, Abs(First[Row, Column] - Second[Row, Column]));
end;

function VectorDistance(const First, Second: TColorVector): Double;
var
  Index: LongInt;
begin
  Result := 0;
  for Index := 0 to 2 do
    Result := Max(Result, Abs(First[Index] - Second[Index]));
end;

function ChromaticityToXyz(const Chromaticity: TChromaticity): TColorVector;
begin
  if Chromaticity.Y <= 0 then
    Exit(MakeVector(0, 0, 0));
  Result[0] := Chromaticity.X / Chromaticity.Y;
  Result[1] := 1;
  Result[2] := (1 - Chromaticity.X - Chromaticity.Y) / Chromaticity.Y;
end;

function RgbToXyzMatrix(const Red, Green, Blue, White: TChromaticity; out Matrix: TColorMatrix): Boolean;
var
  Primaries: TColorMatrix;
  Inverse: TColorMatrix;
  Scale: TColorVector;
  Row: LongInt;
  Column: LongInt;
begin
  Matrix := IdentityMatrix;
  if (Red.Y <= 0) or (Green.Y <= 0) or (Blue.Y <= 0) or (White.Y <= 0) then
    Exit(False);
  Primaries := MatrixFromColumns(ChromaticityToXyz(Red), ChromaticityToXyz(Green), ChromaticityToXyz(Blue));
  if not InvertMatrix(Primaries, Inverse) then
    Exit(False);
  Scale := ApplyMatrix(Inverse, ChromaticityToXyz(White));
  for Row := 0 to 2 do
    for Column := 0 to 2 do
      Matrix[Row, Column] := Primaries[Row, Column] * Scale[Column];
  Result := True;
end;

function BradfordAdaptation(const SourceWhite, TargetWhite: TColorVector): TColorMatrix;
const
  Bradford: TColorMatrix = (
    (0.8951, 0.2664, -0.1614),
    (-0.7502, 1.7135, 0.0367),
    (0.0389, -0.0685, 1.0296));
var
  Inverse: TColorMatrix;
  SourceCone: TColorVector;
  TargetCone: TColorVector;
  Scaling: TColorMatrix;
  Index: LongInt;
begin
  InvertMatrix(Bradford, Inverse);
  SourceCone := ApplyMatrix(Bradford, SourceWhite);
  TargetCone := ApplyMatrix(Bradford, TargetWhite);
  Scaling := IdentityMatrix;
  for Index := 0 to 2 do
    if Abs(SourceCone[Index]) > 1e-9 then
      Scaling[Index, Index] := TargetCone[Index] / SourceCone[Index];
  Result := MultiplyMatrices(Inverse, MultiplyMatrices(Scaling, Bradford));
end;

function SrgbToPcsMatrix: TColorMatrix;
var
  ToXyz: TColorMatrix;
begin
  RgbToXyzMatrix(SrgbRed, SrgbGreen, SrgbBlue, ChromaticityD65, ToXyz);
  Result := MultiplyMatrices(BradfordAdaptation(ChromaticityToXyz(ChromaticityD65), WhiteD50), ToXyz);
end;

function PcsToSrgbMatrix: TColorMatrix;
begin
  InvertMatrix(SrgbToPcsMatrix, Result);
end;

function LabInverseFunction(Value: Double): Double;
const
  Limit = 6.0 / 29.0;
begin
  if Value > Limit then
    Result := Value * Value * Value
  else
    Result := 3 * Limit * Limit * (Value - 4.0 / 29.0);
end;

function LabToXyz(Lightness, A, B: Double): TColorVector;
var
  FY: Double;
begin
  FY := (Lightness + 16) / 116;
  Result[0] := WhiteD50[0] * LabInverseFunction(FY + A / 500);
  Result[1] := WhiteD50[1] * LabInverseFunction(FY);
  Result[2] := WhiteD50[2] * LabInverseFunction(FY - B / 200);
end;

function SrgbToLinear(Value: Double): Double;
begin
  if Value <= 0 then
    Result := 0
  else if Value <= 0.04045 then
    Result := Value / 12.92
  else if Value >= 1 then
    Result := 1
  else
    Result := Power((Value + 0.055) / 1.055, 2.4);
end;

function LinearToSrgb(Value: Double): Double;
begin
  if Value <= 0 then
    Result := 0
  else if Value <= 0.0031308 then
    Result := Value * 12.92
  else if Value >= 1 then
    Result := 1
  else
    Result := 1.055 * Power(Value, 1 / 2.4) - 0.055;
end;

end.
