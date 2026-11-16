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
  VP8's inverse transforms (RFC 6386 section 14): the 4x4 integer DCT,
  whose result is added to the prediction in a work block (lines
  WorkStride apart) and clipped, and the Walsh-Hadamard transform that
  turns the second order block into the DC terms of the sixteen luma
  blocks. The arithmetic is libwebp's (its multipliers 20091 and 35468
  over 2^16), shortcuts included, so the pixels are its pixels.
}
unit Image.WebP.LossyTransforms;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

uses
  Image.WebP.LossyPrediction;

type
  TCoefficientBlock = array[0..15] of SmallInt;
  PCoefficient = ^SmallInt;

{ Adds the inverse DCT of the 16 coefficients at Input to Target. }
procedure AddInverseTransform(Input: PCoefficient; Target: PByte);
{ The same when only coefficients 0, 1 and 4 can be other than zero. }
procedure AddInverseTransformAc3(Input: PCoefficient; Target: PByte);
{ The same when only the DC coefficient can be other than zero. }
procedure AddInverseTransformDc(Input: PCoefficient; Target: PByte);
{ The inverse Walsh-Hadamard transform of Input into the DC terms of
  the sixteen blocks of 16 coefficients at Output. }
procedure InverseWalshHadamard(Input: PCoefficient; Output: PCoefficient);

implementation

function Multiply1(Value: LongInt): LongInt; inline;
begin
  Result := LongInt(SarInt64(Int64(Value) * 20091, 16)) + Value;
end;

function Multiply2(Value: LongInt): LongInt; inline;
begin
  Result := LongInt(SarInt64(Int64(Value) * 35468, 16));
end;

procedure Store(Target: PByte; X, Y, Value: LongInt); inline;
var
  Sample: LongInt;
begin
  Sample := Target[X + Y * WorkStride] + SarLongint(Value, 3);
  if Sample < 0 then
    Sample := 0
  else if Sample > 255 then
    Sample := 255;
  Target[X + Y * WorkStride] := Sample;
end;

procedure AddInverseTransform(Input: PCoefficient; Target: PByte);
var
  Columns: array[0..15] of LongInt;
  Index: LongInt;
  A, B, C, D: LongInt;
  DcTerm: LongInt;
begin
  for Index := 0 to 3 do
  begin
    A := Input[Index] + Input[Index + 8];
    B := Input[Index] - Input[Index + 8];
    C := Multiply2(Input[Index + 4]) - Multiply1(Input[Index + 12]);
    D := Multiply1(Input[Index + 4]) + Multiply2(Input[Index + 12]);
    Columns[Index * 4 + 0] := A + D;
    Columns[Index * 4 + 1] := B + C;
    Columns[Index * 4 + 2] := B - C;
    Columns[Index * 4 + 3] := A - D;
  end;
  for Index := 0 to 3 do
  begin
    DcTerm := Columns[Index] + 4;
    A := DcTerm + Columns[Index + 8];
    B := DcTerm - Columns[Index + 8];
    C := Multiply2(Columns[Index + 4]) - Multiply1(Columns[Index + 12]);
    D := Multiply1(Columns[Index + 4]) + Multiply2(Columns[Index + 12]);
    Store(Target, 0, Index, A + D);
    Store(Target, 1, Index, B + C);
    Store(Target, 2, Index, B - C);
    Store(Target, 3, Index, A - D);
  end;
end;

procedure AddInverseTransformAc3(Input: PCoefficient; Target: PByte);
var
  A, C4, D4, C1, D1: LongInt;

  procedure StoreLine(Y, DcTerm: LongInt);
  begin
    Store(Target, 0, Y, DcTerm + D1);
    Store(Target, 1, Y, DcTerm + C1);
    Store(Target, 2, Y, DcTerm - C1);
    Store(Target, 3, Y, DcTerm - D1);
  end;

begin
  A := Input[0] + 4;
  C4 := Multiply2(Input[4]);
  D4 := Multiply1(Input[4]);
  C1 := Multiply2(Input[1]);
  D1 := Multiply1(Input[1]);
  StoreLine(0, A + D4);
  StoreLine(1, A + C4);
  StoreLine(2, A - C4);
  StoreLine(3, A - D4);
end;

procedure AddInverseTransformDc(Input: PCoefficient; Target: PByte);
var
  DcTerm: LongInt;
  X: LongInt;
  Y: LongInt;
begin
  DcTerm := Input[0] + 4;
  for Y := 0 to 3 do
    for X := 0 to 3 do
      Store(Target, X, Y, DcTerm);
end;

procedure InverseWalshHadamard(Input: PCoefficient; Output: PCoefficient);
var
  Temporary: array[0..15] of LongInt;
  Index: LongInt;
  A0, A1, A2, A3: LongInt;
  DcTerm: LongInt;
begin
  for Index := 0 to 3 do
  begin
    A0 := Input[Index] + Input[12 + Index];
    A1 := Input[4 + Index] + Input[8 + Index];
    A2 := Input[4 + Index] - Input[8 + Index];
    A3 := Input[Index] - Input[12 + Index];
    Temporary[Index] := A0 + A1;
    Temporary[8 + Index] := A0 - A1;
    Temporary[4 + Index] := A3 + A2;
    Temporary[12 + Index] := A3 - A2;
  end;
  for Index := 0 to 3 do
  begin
    DcTerm := Temporary[Index * 4] + 3;
    A0 := DcTerm + Temporary[Index * 4 + 3];
    A1 := Temporary[Index * 4 + 1] + Temporary[Index * 4 + 2];
    A2 := Temporary[Index * 4 + 1] - Temporary[Index * 4 + 2];
    A3 := DcTerm - Temporary[Index * 4 + 3];
    Output[Index * 64 + 0] := SmallInt(SarLongint(A0 + A1, 3));
    Output[Index * 64 + 16] := SmallInt(SarLongint(A3 + A2, 3));
    Output[Index * 64 + 32] := SmallInt(SarLongint(A0 - A1, 3));
    Output[Index * 64 + 48] := SmallInt(SarLongint(A3 - A2, 3));
  end;
end;

end.
