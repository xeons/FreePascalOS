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
  VP8's inverse transforms (RFC 6386 section 14): the 4x4 DCT
  approximation added to the prediction, its DC-only shortcut, and the
  Walsh-Hadamard transform that spreads the second order block's
  coefficients to the DCs of the 16 luma blocks.

  The intermediate values are kept in 16 bits, as the reference
  decoder keeps them.
}
unit Vp8.Transforms;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

type
  TCoefficientBlock = array[0..15] of SmallInt;
  PCoefficientBlock = ^TCoefficientBlock;

{ Adds the inverse transform of Coefficients (dequantized) to the 4x4
  pixels at Target. }
procedure AddInverseTransform(Coefficients: PSmallInt; Target: PByte; Stride: LongInt);
{ Adds (Dc + 4) >> 3 to the 4x4 pixels at Target. }
procedure AddDcOnly(Dc: SmallInt; Target: PByte; Stride: LongInt);
{ The inverse Walsh-Hadamard transform of Input; the 16 results go to
  Output[0], Output[16], ... Output[240] (the luma blocks' DCs). }
procedure InverseWalsh(Input: PSmallInt; Output: PSmallInt);
{ The same when only the DC of Input is not zero. }
procedure InverseWalshDcOnly(Dc: SmallInt; Output: PSmallInt);

implementation

const
  CosPi8Sqrt2Minus1 = 20091;
  SinPi8Sqrt2 = 35468;

function ClampPixel(Value: LongInt): Byte; inline;
begin
  if Value < 0 then
    Result := 0
  else if Value > 255 then
    Result := 255
  else
    Result := Value;
end;

procedure AddInverseTransform(Coefficients: PSmallInt; Target: PByte; Stride: LongInt);
var
  Output: array[0..15] of SmallInt;
  Index, Row, Column: LongInt;
  A, B, C, D, Temp1, Temp2: LongInt;
  Source: PSmallInt;
begin
  for Index := 0 to 3 do
  begin
    Source := Coefficients + Index;
    A := Source[0] + Source[8];
    B := Source[0] - Source[8];
    Temp1 := SarLongint(Source[4] * SinPi8Sqrt2, 16);
    Temp2 := Source[12] + SarLongint(Source[12] * CosPi8Sqrt2Minus1, 16);
    C := Temp1 - Temp2;
    Temp1 := Source[4] + SarLongint(Source[4] * CosPi8Sqrt2Minus1, 16);
    Temp2 := SarLongint(Source[12] * SinPi8Sqrt2, 16);
    D := Temp1 + Temp2;
    Output[Index] := SmallInt(A + D);
    Output[Index + 12] := SmallInt(A - D);
    Output[Index + 4] := SmallInt(B + C);
    Output[Index + 8] := SmallInt(B - C);
  end;
  for Row := 0 to 3 do
  begin
    Source := @Output[Row * 4];
    A := Source[0] + Source[2];
    B := Source[0] - Source[2];
    Temp1 := SarLongint(Source[1] * SinPi8Sqrt2, 16);
    Temp2 := Source[3] + SarLongint(Source[3] * CosPi8Sqrt2Minus1, 16);
    C := Temp1 - Temp2;
    Temp1 := Source[1] + SarLongint(Source[1] * CosPi8Sqrt2Minus1, 16);
    Temp2 := SarLongint(Source[3] * SinPi8Sqrt2, 16);
    D := Temp1 + Temp2;
    Source[0] := SmallInt(SarLongint(A + D + 4, 3));
    Source[3] := SmallInt(SarLongint(A - D + 4, 3));
    Source[1] := SmallInt(SarLongint(B + C + 4, 3));
    Source[2] := SmallInt(SarLongint(B - C + 4, 3));
  end;
  for Row := 0 to 3 do
  begin
    for Column := 0 to 3 do
      Target[Column] := ClampPixel(Output[Row * 4 + Column] + Target[Column]);
    Inc(Target, Stride);
  end;
end;

procedure AddDcOnly(Dc: SmallInt; Target: PByte; Stride: LongInt);
var
  Value, Row, Column: LongInt;
begin
  Value := SarLongint(Dc + 4, 3);
  for Row := 0 to 3 do
  begin
    for Column := 0 to 3 do
      Target[Column] := ClampPixel(Value + Target[Column]);
    Inc(Target, Stride);
  end;
end;

procedure InverseWalsh(Input: PSmallInt; Output: PSmallInt);
var
  Temp: array[0..15] of SmallInt;
  Index: LongInt;
  A1, B1, C1, D1, A2, B2, C2, D2: LongInt;
  Source: PSmallInt;
begin
  for Index := 0 to 3 do
  begin
    Source := Input + Index;
    A1 := Source[0] + Source[12];
    B1 := Source[4] + Source[8];
    C1 := Source[4] - Source[8];
    D1 := Source[0] - Source[12];
    Temp[Index] := SmallInt(A1 + B1);
    Temp[Index + 4] := SmallInt(C1 + D1);
    Temp[Index + 8] := SmallInt(A1 - B1);
    Temp[Index + 12] := SmallInt(D1 - C1);
  end;
  for Index := 0 to 3 do
  begin
    Source := @Temp[Index * 4];
    A1 := Source[0] + Source[3];
    B1 := Source[1] + Source[2];
    C1 := Source[1] - Source[2];
    D1 := Source[0] - Source[3];
    A2 := A1 + B1;
    B2 := C1 + D1;
    C2 := A1 - B1;
    D2 := D1 - C1;
    Source[0] := SmallInt(SarLongint(A2 + 3, 3));
    Source[1] := SmallInt(SarLongint(B2 + 3, 3));
    Source[2] := SmallInt(SarLongint(C2 + 3, 3));
    Source[3] := SmallInt(SarLongint(D2 + 3, 3));
  end;
  for Index := 0 to 15 do
    Output[Index * 16] := Temp[Index];
end;

procedure InverseWalshDcOnly(Dc: SmallInt; Output: PSmallInt);
var
  Value: SmallInt;
  Index: LongInt;
begin
  Value := SmallInt(SarLongint(Dc + 3, 3));
  for Index := 0 to 15 do
    Output[Index * 16] := Value;
end;

end.
