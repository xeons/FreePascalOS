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
  ICC tone curves (the TRC tags, and the curves of LUT tags): how a
  device value from 0 to 1 becomes a linear one.

    curv with no entries      the identity
    curv with one entry       a gamma, Y = X ^ g (g as u8Fixed8)
    curv with more entries    a table over 0 to 1, linearly interpolated
    para, function types 0-4  Y = X ^ g; (aX + b) ^ g; (aX + b) ^ g + c;
                              (aX + b) ^ g above d, cX below;
                              (aX + b) ^ g + e above d, cX + f below

  ReadToneCurve reads either kind of tag at an offset of the profile
  and says how many bytes it took (curves follow each other in LUT
  tags, each on four bytes).
}
unit Image.ColorProfiles.Curves;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils;

type
  TToneCurveKind = (ToneCurveIdentity, ToneCurveGamma, ToneCurveTable, ToneCurveParametric);

  TToneCurve = record
    Kind: TToneCurveKind;
    Gamma: Double;
    { Table entries over 0 to 1. }
    Table: array of Double;
    FunctionType: LongInt;
    { g, a, b, c, d, e, f. }
    Parameters: array[0..6] of Double;
  end;

  TToneCurves = array of TToneCurve;

function IdentityCurve: TToneCurve;
function GammaCurve(Gamma: Double): TToneCurve;
{ The curve at Value (0 to 1; the result is not clamped). }
function EvaluateToneCurve(constref Curve: TToneCurve; Value: Double): Double;
{ The curve of the curv or para tag at Offset of Profile (Limit is
  where the tag ends); Size is the bytes it took, rounded up to four.
  False when it is neither or does not fit. }
function ReadToneCurve(const Profile: TBytes; Offset, Limit: PtrInt; out Curve: TToneCurve;
  out Size: PtrInt): Boolean;
{ Count curves one after another from Offset. }
function ReadToneCurves(const Profile: TBytes; Offset, Limit: PtrInt; Count: LongInt;
  out Curves: TToneCurves): Boolean;

implementation

uses
  Math,
  Image.ColorProfiles.Numbers;

const
  ParameterCounts: array[0..4] of LongInt = (1, 3, 4, 5, 7);

function IdentityCurve: TToneCurve;
begin
  Result := Default(TToneCurve);
  Result.Kind := ToneCurveIdentity;
  Result.Gamma := 1;
end;

function GammaCurve(Gamma: Double): TToneCurve;
begin
  Result := IdentityCurve;
  Result.Kind := ToneCurveGamma;
  Result.Gamma := Gamma;
end;

function SafePower(Base, Exponent: Double): Double;
begin
  if Base <= 0 then
    Result := 0
  else
    Result := Power(Base, Exponent);
end;

function EvaluateTable(const Table: array of Double; Value: Double): Double;
var
  Position: Double;
  Index: LongInt;
  Fraction: Double;
  Last: LongInt;
begin
  Last := High(Table);
  if Value <= 0 then
    Exit(Table[0]);
  if Value >= 1 then
    Exit(Table[Last]);
  Position := Value * Last;
  Index := Trunc(Position);
  if Index >= Last then
    Exit(Table[Last]);
  Fraction := Position - Index;
  Result := Table[Index] + (Table[Index + 1] - Table[Index]) * Fraction;
end;

function EvaluateParametric(constref Curve: TToneCurve; X: Double): Double;
var
  G, A, B, C, D, E, F: Double;
begin
  G := Curve.Parameters[0];
  A := Curve.Parameters[1];
  B := Curve.Parameters[2];
  C := Curve.Parameters[3];
  D := Curve.Parameters[4];
  E := Curve.Parameters[5];
  F := Curve.Parameters[6];
  case Curve.FunctionType of
    0:
      Result := SafePower(X, G);
    1:
      if (A <> 0) and (X >= -B / A) then
        Result := SafePower(A * X + B, G)
      else
        Result := 0;
    2:
      if (A <> 0) and (X >= -B / A) then
        Result := SafePower(A * X + B, G) + C
      else
        Result := C;
    3:
      if X >= D then
        Result := SafePower(A * X + B, G)
      else
        Result := C * X;
    4:
      if X >= D then
        Result := SafePower(A * X + B, G) + E
      else
        Result := C * X + F;
  else
    Result := X;
  end;
end;

function EvaluateToneCurve(constref Curve: TToneCurve; Value: Double): Double;
begin
  case Curve.Kind of
    ToneCurveGamma:
      Result := SafePower(Value, Curve.Gamma);
    ToneCurveTable:
      Result := EvaluateTable(Curve.Table, Value);
    ToneCurveParametric:
      Result := EvaluateParametric(Curve, Value);
  else
    Result := Value;
  end;
end;

function RoundUpToFour(Value: PtrInt): PtrInt;
begin
  Result := (Value + 3) and not PtrInt(3);
end;

function ReadCurv(const Profile: TBytes; Offset, Limit: PtrInt; out Curve: TToneCurve; out Size: PtrInt): Boolean;
var
  Count: Int64;
  Index: LongInt;
begin
  Result := False;
  Curve := IdentityCurve;
  Size := 0;
  if Offset + 12 > Limit then
    Exit;
  Count := ReadProfileLong(Profile, Offset + 8);
  if (Count < 0) or (Offset + 12 + 2 * Count > Limit) then
    Exit;
  if Count = 1 then
    Curve := GammaCurve(ReadProfileWord(Profile, Offset + 12) / 256)
  else if Count > 1 then
  begin
    Curve.Kind := ToneCurveTable;
    SetLength(Curve.Table, Count);
    for Index := 0 to Count - 1 do
      Curve.Table[Index] := ReadProfileWord(Profile, Offset + 12 + 2 * Index) / 65535;
  end;
  Size := RoundUpToFour(12 + 2 * Count);
  Result := True;
end;

function ReadPara(const Profile: TBytes; Offset, Limit: PtrInt; out Curve: TToneCurve; out Size: PtrInt): Boolean;
var
  FunctionType: LongInt;
  Count: LongInt;
  Index: LongInt;
begin
  Result := False;
  Curve := IdentityCurve;
  Size := 0;
  if Offset + 12 > Limit then
    Exit;
  FunctionType := ReadProfileWord(Profile, Offset + 8);
  if FunctionType > High(ParameterCounts) then
    Exit;
  Count := ParameterCounts[FunctionType];
  if Offset + 12 + 4 * Count > Limit then
    Exit;
  Curve.Kind := ToneCurveParametric;
  Curve.FunctionType := FunctionType;
  for Index := 0 to Count - 1 do
    Curve.Parameters[Index] := ReadProfileFixed(Profile, Offset + 12 + 4 * Index);
  Size := RoundUpToFour(12 + 4 * Count);
  Result := True;
end;

function ReadToneCurve(const Profile: TBytes; Offset, Limit: PtrInt; out Curve: TToneCurve;
  out Size: PtrInt): Boolean;
var
  Signature: LongWord;
begin
  Curve := IdentityCurve;
  Size := 0;
  if (Offset < 0) or (Limit > Length(Profile)) or (Offset + 4 > Limit) then
    Exit(False);
  Signature := ReadProfileLong(Profile, Offset);
  if Signature = SignatureOf('curv') then
    Result := ReadCurv(Profile, Offset, Limit, Curve, Size)
  else if Signature = SignatureOf('para') then
    Result := ReadPara(Profile, Offset, Limit, Curve, Size)
  else
    Result := False;
end;

function ReadToneCurves(const Profile: TBytes; Offset, Limit: PtrInt; Count: LongInt;
  out Curves: TToneCurves): Boolean;
var
  Index: LongInt;
  Size: PtrInt;
begin
  Curves := nil;
  SetLength(Curves, Count);
  for Index := 0 to Count - 1 do
  begin
    if not ReadToneCurve(Profile, Offset, Limit, Curves[Index], Size) then
      Exit(False);
    Inc(Offset, Size);
  end;
  Result := True;
end;

end.
