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
  The inverse transforms of the AV1 specification (section 7.13): the
  butterfly based DCT (4 to 64 points), ADST (4, 8, 16), the identity
  transforms (4 to 32), the Walsh-Hadamard transform of lossless blocks,
  and the 2D inverse transform with its rounding and clamping.

  The 1D transforms follow the specification's steps one for one on an
  array T; the butterflies multiply in 64 bits. Rows whose coefficients
  are all zero give zero residual rows (every transform maps zeros to
  zeros), so they are not transformed.
}
unit Av1.InverseTransform;

{$mode objfpc}

interface

uses
  Av1.Common, Av1.Constants, Av1.Tables;

type
  TTransformArray = array[0..63] of Integer;

{ The 2D inverse transform process (7.13.3). Dequant holds the
  dequantized coefficients, Min(32, height) rows of DequantStride
  entries (only the first Min(32, width) of each row are read). Residual
  receives the height by width result, width entries per row. }
procedure InverseTransform2D(Dequant: PInteger; DequantStride: Integer; Residual: PInteger;
  TxSz, TxType, BitDepth: Integer; Lossless: Boolean);

implementation

const
  SINPI_1_9 = 1321;
  SINPI_2_9 = 2482;
  SINPI_3_9 = 3344;
  SINPI_4_9 = 3803;

type
  TTransformKind = (KindDct, KindAdst, KindIdentity);

function BitReverse(NumBits, Value: Integer): Integer; inline;
var
  Index: Integer;
begin
  Result := 0;
  for Index := 0 to NumBits - 1 do
    Result := Result + (((Value shr Index) and 1) shl (NumBits - 1 - Index));
end;

function Cos128(Angle: Integer): Integer; inline;
var
  Angle2: Integer;
begin
  Angle2 := Angle and 255;
  if Angle2 <= 64 then
    Result := Cos128_Lookup[Angle2]
  else if Angle2 <= 128 then
    Result := -Cos128_Lookup[128 - Angle2]
  else if Angle2 <= 192 then
    Result := -Cos128_Lookup[Angle2 - 128]
  else
    Result := Cos128_Lookup[256 - Angle2];
end;

function Sin128(Angle: Integer): Integer; inline;
begin
  Result := Cos128(Angle - 64);
end;

{ B( a, b, angle, flip, r ): the butterfly rotation, then the exchange when Flip. }
procedure Butterfly(var T: TTransformArray; A, B, Angle: Integer; Flip: Boolean); inline;
var
  X, Y: Int64;
  CosValue, SinValue, Temporary: Integer;
begin
  CosValue := Cos128(Angle);
  SinValue := Sin128(Angle);
  X := Int64(T[A]) * CosValue - Int64(T[B]) * SinValue;
  Y := Int64(T[A]) * SinValue + Int64(T[B]) * CosValue;
  T[A] := Integer(Round2Int64(X, 12));
  T[B] := Integer(Round2Int64(Y, 12));
  if Flip then
  begin
    Temporary := T[A];
    T[A] := T[B];
    T[B] := Temporary;
  end;
end;

{ H( a, b, flip, r ): the Hadamard rotation with clamping to r bits. }
procedure Hadamard(var T: TTransformArray; A, B: Integer; Flip: Boolean; Range: Integer); inline;
var
  X, Y, Low, High, Temporary: Integer;
begin
  if Flip then
  begin
    Temporary := A;
    A := B;
    B := Temporary;
  end;
  X := T[A];
  Y := T[B];
  Low := -(1 shl (Range - 1));
  High := (1 shl (Range - 1)) - 1;
  T[A] := Clip3(Low, High, X + Y);
  T[B] := Clip3(Low, High, X - Y);
end;

procedure InverseDctPermutation(var T: TTransformArray; N: Integer);
var
  Copy: TTransformArray;
  Index: Integer;
begin
  Copy := T;
  for Index := 0 to (1 shl N) - 1 do
    T[Index] := Copy[BitReverse(N, Index)];
end;

procedure InverseDct(var T: TTransformArray; N, R: Integer);
var
  I, J: Integer;
begin
  InverseDctPermutation(T, N);
  if N = 6 then
    for I := 0 to 15 do
      Butterfly(T, 32 + I, 63 - I, 63 - 4 * BitReverse(4, I), False);
  if N >= 5 then
    for I := 0 to 7 do
      Butterfly(T, 16 + I, 31 - I, 6 + (BitReverse(3, 7 - I) shl 3), False);
  if N = 6 then
    for I := 0 to 15 do
      Hadamard(T, 32 + I * 2, 33 + I * 2, (I and 1) <> 0, R);
  if N >= 4 then
    for I := 0 to 3 do
      Butterfly(T, 8 + I, 15 - I, 12 + (BitReverse(2, 3 - I) shl 4), False);
  if N >= 5 then
    for I := 0 to 7 do
      Hadamard(T, 16 + 2 * I, 17 + 2 * I, (I and 1) <> 0, R);
  if N = 6 then
    for I := 0 to 3 do
      for J := 0 to 1 do
        Butterfly(T, 62 - I * 4 - J, 33 + I * 4 + J, 60 - 16 * BitReverse(2, I) + 64 * J, True);
  if N >= 3 then
    for I := 0 to 1 do
      Butterfly(T, 4 + I, 7 - I, 56 - 32 * I, False);
  if N >= 4 then
    for I := 0 to 3 do
      Hadamard(T, 8 + 2 * I, 9 + 2 * I, (I and 1) <> 0, R);
  if N >= 5 then
    for I := 0 to 1 do
      for J := 0 to 1 do
        Butterfly(T, 30 - 4 * I - J, 17 + 4 * I + J, 24 + (J shl 6) + ((1 - I) shl 5), True);
  if N = 6 then
    for I := 0 to 7 do
      for J := 0 to 1 do
        Hadamard(T, 32 + I * 4 + J, 35 + I * 4 - J, (I and 1) <> 0, R);
  for I := 0 to 1 do
    Butterfly(T, 2 * I, 2 * I + 1, 32 + 16 * I, I = 0);
  if N >= 3 then
    for I := 0 to 1 do
      Hadamard(T, 4 + 2 * I, 5 + 2 * I, I <> 0, R);
  if N >= 4 then
    for I := 0 to 1 do
      Butterfly(T, 14 - I, 9 + I, 48 + 64 * I, True);
  if N >= 5 then
    for I := 0 to 3 do
      for J := 0 to 1 do
        Hadamard(T, 16 + 4 * I + J, 19 + 4 * I - J, (I and 1) <> 0, R);
  if N = 6 then
    for I := 0 to 1 do
      for J := 0 to 3 do
        Butterfly(T, 61 - I * 8 - J, 34 + I * 8 + J, 56 - I * 32 + (J shr 1) * 64, True);
  for I := 0 to 1 do
    Hadamard(T, I, 3 - I, False, R);
  if N >= 3 then
    Butterfly(T, 6, 5, 32, True);
  if N >= 4 then
    for I := 0 to 1 do
      for J := 0 to 1 do
        Hadamard(T, 8 + 4 * I + J, 11 + 4 * I - J, I <> 0, R);
  if N >= 5 then
    for I := 0 to 3 do
      Butterfly(T, 29 - I, 18 + I, 48 + (I shr 1) * 64, True);
  if N = 6 then
    for I := 0 to 3 do
      for J := 0 to 3 do
        Hadamard(T, 32 + 8 * I + J, 39 + 8 * I - J, (I and 1) <> 0, R);
  if N >= 3 then
    for I := 0 to 3 do
      Hadamard(T, I, 7 - I, False, R);
  if N >= 4 then
    for I := 0 to 1 do
      Butterfly(T, 13 - I, 10 + I, 32, True);
  if N >= 5 then
    for I := 0 to 1 do
      for J := 0 to 3 do
        Hadamard(T, 16 + I * 8 + J, 23 + I * 8 - J, I <> 0, R);
  if N = 6 then
    for I := 0 to 7 do
      if I < 4 then
        Butterfly(T, 59 - I, 36 + I, 48, True)
      else
        Butterfly(T, 59 - I, 36 + I, 112, True);
  if N >= 4 then
    for I := 0 to 7 do
      Hadamard(T, I, 15 - I, False, R);
  if N >= 5 then
    for I := 0 to 3 do
      Butterfly(T, 27 - I, 20 + I, 32, True);
  if N = 6 then
    for I := 0 to 7 do
    begin
      Hadamard(T, 32 + I, 47 - I, False, R);
      Hadamard(T, 48 + I, 63 - I, True, R);
    end;
  if N >= 5 then
    for I := 0 to 15 do
      Hadamard(T, I, 31 - I, False, R);
  if N = 6 then
    for I := 0 to 7 do
      Butterfly(T, 55 - I, 40 + I, 32, True);
  if N = 6 then
    for I := 0 to 31 do
      Hadamard(T, I, 63 - I, False, R);
end;

procedure InverseAdstInputPermutation(var T: TTransformArray; N: Integer);
var
  Copy: TTransformArray;
  Index, Count, Source: Integer;
begin
  Count := 1 shl N;
  Copy := T;
  for Index := 0 to Count - 1 do
  begin
    if (Index and 1) <> 0 then
      Source := Index - 1
    else
      Source := Count - Index - 1;
    T[Index] := Copy[Source];
  end;
end;

procedure InverseAdstOutputPermutation(var T: TTransformArray; N: Integer);
var
  Copy: TTransformArray;
  Index, Count, A, B, C, D, Source: Integer;
begin
  Count := 1 shl N;
  Copy := T;
  for Index := 0 to Count - 1 do
  begin
    A := (Index shr 3) and 1;
    B := ((Index shr 2) and 1) xor ((Index shr 3) and 1);
    C := ((Index shr 1) and 1) xor ((Index shr 2) and 1);
    D := (Index and 1) xor ((Index shr 1) and 1);
    Source := ((D shl 3) or (C shl 2) or (B shl 1) or A) shr (4 - N);
    if (Index and 1) <> 0 then
      T[Index] := -Copy[Source]
    else
      T[Index] := Copy[Source];
  end;
end;

procedure InverseAdst4(var T: TTransformArray);
var
  S0, S1, S2, S3, S4, S5, S6, X0, X1, X2, X3: Int64;
  A7, B7: Int64;
begin
  S0 := Int64(SINPI_1_9) * T[0];
  S1 := Int64(SINPI_2_9) * T[0];
  S2 := Int64(SINPI_3_9) * T[1];
  S3 := Int64(SINPI_4_9) * T[2];
  S4 := Int64(SINPI_1_9) * T[2];
  S5 := Int64(SINPI_2_9) * T[3];
  S6 := Int64(SINPI_4_9) * T[3];
  A7 := Int64(T[0]) - T[2];
  B7 := A7 + T[3];
  S0 := S0 + S3;
  S1 := S1 - S4;
  S3 := S2;
  S2 := SINPI_3_9 * B7;
  S0 := S0 + S5;
  S1 := S1 - S6;
  X0 := S0 + S3;
  X1 := S1 + S3;
  X2 := S2;
  X3 := S0 + S1;
  X3 := X3 - S3;
  T[0] := Integer(Round2Int64(X0, 12));
  T[1] := Integer(Round2Int64(X1, 12));
  T[2] := Integer(Round2Int64(X2, 12));
  T[3] := Integer(Round2Int64(X3, 12));
end;

procedure InverseAdst8(var T: TTransformArray; R: Integer);
var
  I, J: Integer;
begin
  InverseAdstInputPermutation(T, 3);
  for I := 0 to 3 do
    Butterfly(T, 2 * I, 2 * I + 1, 60 - 16 * I, True);
  for I := 0 to 3 do
    Hadamard(T, I, 4 + I, False, R);
  for I := 0 to 1 do
    Butterfly(T, 4 + 3 * I, 5 + I, 48 - 32 * I, True);
  for I := 0 to 1 do
    for J := 0 to 1 do
      Hadamard(T, 4 * J + I, 2 + 4 * J + I, False, R);
  for I := 0 to 1 do
    Butterfly(T, 2 + 4 * I, 3 + 4 * I, 32, True);
  InverseAdstOutputPermutation(T, 3);
end;

procedure InverseAdst16(var T: TTransformArray; R: Integer);
var
  I, J: Integer;
begin
  InverseAdstInputPermutation(T, 4);
  for I := 0 to 7 do
    Butterfly(T, 2 * I, 2 * I + 1, 62 - 8 * I, True);
  for I := 0 to 7 do
    Hadamard(T, I, 8 + I, False, R);
  for I := 0 to 1 do
  begin
    Butterfly(T, 8 + 2 * I, 9 + 2 * I, 56 - 32 * I, True);
    Butterfly(T, 13 + 2 * I, 12 + 2 * I, 8 + 32 * I, True);
  end;
  for I := 0 to 3 do
    for J := 0 to 1 do
      Hadamard(T, 8 * J + I, 4 + 8 * J + I, False, R);
  for I := 0 to 1 do
    for J := 0 to 1 do
      Butterfly(T, 4 + 8 * J + 3 * I, 5 + 8 * J + I, 48 - 32 * I, True);
  for I := 0 to 1 do
    for J := 0 to 3 do
      Hadamard(T, 4 * J + I, 2 + 4 * J + I, False, R);
  for I := 0 to 3 do
    Butterfly(T, 2 + 4 * I, 3 + 4 * I, 32, True);
  InverseAdstOutputPermutation(T, 4);
end;

procedure InverseAdst(var T: TTransformArray; N, R: Integer);
begin
  case N of
    2: InverseAdst4(T);
    3: InverseAdst8(T, R);
  else
    InverseAdst16(T, R);
  end;
end;

procedure InverseWalshHadamard(var T: TTransformArray; Shift: Integer);
var
  A, B, C, D, E: Integer;
begin
  A := SarLongint(T[0], Shift);
  C := SarLongint(T[1], Shift);
  D := SarLongint(T[2], Shift);
  B := SarLongint(T[3], Shift);
  A := A + C;
  D := D - B;
  E := SarLongint(A - D, 1);
  B := E - B;
  C := E - C;
  A := A - B;
  D := D + C;
  T[0] := A;
  T[1] := B;
  T[2] := C;
  T[3] := D;
end;

procedure InverseIdentity(var T: TTransformArray; N: Integer);
var
  Index: Integer;
begin
  case N of
    2:
      for Index := 0 to 3 do
        T[Index] := Integer(Round2Int64(Int64(T[Index]) * 5793, 12));
    3:
      for Index := 0 to 7 do
        T[Index] := T[Index] * 2;
    4:
      for Index := 0 to 15 do
        T[Index] := Integer(Round2Int64(Int64(T[Index]) * 11586, 12));
  else
    for Index := 0 to 31 do
      T[Index] := T[Index] * 4;
  end;
end;

function RowKind(TxType: Integer): TTransformKind;
begin
  case TxType of
    DCT_DCT, ADST_DCT, FLIPADST_DCT, H_DCT:
      Result := KindDct;
    DCT_ADST, ADST_ADST, DCT_FLIPADST, FLIPADST_FLIPADST, ADST_FLIPADST, FLIPADST_ADST, H_ADST, H_FLIPADST:
      Result := KindAdst;
  else
    Result := KindIdentity;
  end;
end;

function ColumnKind(TxType: Integer): TTransformKind;
begin
  case TxType of
    DCT_DCT, DCT_ADST, DCT_FLIPADST, V_DCT:
      Result := KindDct;
    ADST_DCT, ADST_ADST, FLIPADST_DCT, FLIPADST_FLIPADST, ADST_FLIPADST, FLIPADST_ADST, V_ADST, V_FLIPADST:
      Result := KindAdst;
  else
    Result := KindIdentity;
  end;
end;

procedure Transform1D(var T: TTransformArray; Kind: TTransformKind; N, R: Integer); inline;
begin
  case Kind of
    KindDct: InverseDct(T, N, R);
    KindAdst: InverseAdst(T, N, R);
  else
    InverseIdentity(T, N);
  end;
end;

procedure InverseTransform2D(Dequant: PInteger; DequantStride: Integer; Residual: PInteger;
  TxSz, TxType, BitDepth: Integer; Lossless: Boolean);
var
  Log2W, Log2H, Width, Height, RowShift, ColumnShift, RowClampRange, ColumnClampRange: Integer;
  RowLow, RowHigh, ColumnLow, ColumnHigh: Integer;
  I, J, CoefficientColumns: Integer;
  T: TTransformArray;
  Source, Target: PInteger;
  AllZero, Rectangular: Boolean;
  RowTransform, ColumnTransform: TTransformKind;
begin
  Log2W := Tx_Width_Log2[TxSz];
  Log2H := Tx_Height_Log2[TxSz];
  Width := 1 shl Log2W;
  Height := 1 shl Log2H;
  if Lossless then
  begin
    RowShift := 0;
    ColumnShift := 0;
  end
  else
  begin
    RowShift := Transform_Row_Shift[TxSz];
    ColumnShift := 4;
  end;
  RowClampRange := BitDepth + 8;
  ColumnClampRange := Max(BitDepth + 6, 16);
  RowLow := -(1 shl (RowClampRange - 1));
  RowHigh := (1 shl (RowClampRange - 1)) - 1;
  ColumnLow := -(1 shl (ColumnClampRange - 1));
  ColumnHigh := (1 shl (ColumnClampRange - 1)) - 1;
  Rectangular := Abs(Log2W - Log2H) = 1;
  RowTransform := RowKind(TxType);
  ColumnTransform := ColumnKind(TxType);
  CoefficientColumns := Min(Width, 32);

  { Row transforms. }
  for I := 0 to Height - 1 do
  begin
    Target := Residual + I * Width;
    AllZero := True;
    if I < 32 then
    begin
      Source := Dequant + I * DequantStride;
      for J := 0 to CoefficientColumns - 1 do
        if Source[J] <> 0 then
        begin
          AllZero := False;
          Break;
        end;
    end;
    if AllZero then
    begin
      FillChar(Target^, Width * SizeOf(Integer), 0);
      Continue;
    end;
    for J := 0 to Width - 1 do
      if J < 32 then
        T[J] := Source[J]
      else
        T[J] := 0;
    if Rectangular then
      for J := 0 to Width - 1 do
        T[J] := Integer(Round2Int64(Int64(T[J]) * 2896, 12));
    if Lossless then
      InverseWalshHadamard(T, 2)
    else
    begin
      { The row transform's input is within rowClampRange bits in conforming
        streams; the reference decoder clamps it, and so does this. }
      for J := 0 to Width - 1 do
        T[J] := Clip3(RowLow, RowHigh, T[J]);
      Transform1D(T, RowTransform, Log2W, RowClampRange);
    end;
    for J := 0 to Width - 1 do
      Target[J] := Clip3(ColumnLow, ColumnHigh, Round2(T[J], RowShift));
  end;

  { Column transforms. }
  for J := 0 to Width - 1 do
  begin
    for I := 0 to Height - 1 do
      T[I] := Residual[I * Width + J];
    if Lossless then
      InverseWalshHadamard(T, 0)
    else
      Transform1D(T, ColumnTransform, Log2H, ColumnClampRange);
    for I := 0 to Height - 1 do
      Residual[I * Width + J] := Round2(T[I], ColumnShift);
  end;
end;

end.
