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
  The inverse DCT of an 8 x 8 block, in integers.

  This is the accurate integer method of the Independent JPEG Group's
  library (Loeffler, Ligtenberg and Moschytz: 12 multiplications and 32
  additions per eight points, constants scaled by 2^13), with the same
  rounding, so its samples are those libjpeg and libjpeg-turbo produce
  by default. Coefficients are multiplied by their quantization values
  as they are read (dequantization costs nothing extra). Columns go
  first, keeping two more bits; a column whose AC coefficients are all
  zero, the usual case, is just its DC value, and so is such a row; a
  block with only a DC coefficient is filled at once.

  Samples are clamped to 0..255 after adding 128.
}
unit Image.Jpeg.Idct;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

{ The block's 64 coefficients (natural order) times Quantization, turned
  into 8 x 8 samples at Output, Stride bytes from line to line. }
procedure InverseDctBlock(Coefficients: PSmallInt; Quantization: PLongInt; Output: PByte; Stride: PtrInt);

implementation

const
  ConstantBits = 13;
  Pass1Bits = 2;
  Fix0298631336 = 2446;
  Fix0390180644 = 3196;
  Fix0541196100 = 4433;
  Fix0765366865 = 6270;
  Fix0899976223 = 7373;
  Fix1175875602 = 9633;
  Fix1501321110 = 12299;
  Fix1847759065 = 15137;
  Fix1961570560 = 16069;
  Fix2053119869 = 16819;
  Fix2562915447 = 20995;
  Fix3072711026 = 25172;

function Descale(Value: Int64; Shift: LongInt): Int64; inline;
begin
  Result := SarInt64(Value + (Int64(1) shl (Shift - 1)), Shift);
end;

procedure FillBlock(Output: PByte; Stride: PtrInt; Value: Byte);
var
  Row: LongInt;
begin
  for Row := 0 to 7 do
  begin
    FillChar(Output^, 8, Value);
    Inc(Output, Stride);
  end;
end;

function LimitSample(Value: Int64): Byte; inline;
begin
  Value := Value + 128;
  if Value < 0 then
    Result := 0
  else if Value > 255 then
    Result := 255
  else
    Result := Byte(Value);
end;

procedure InverseDctBlock(Coefficients: PSmallInt; Quantization: PLongInt; Output: PByte; Stride: PtrInt);
var
  Workspace: array[0..63] of LongInt;
  Column: LongInt;
  Row: LongInt;
  Index: LongInt;
  AllZero: Boolean;
  DcValue: LongInt;
  Input: PSmallInt;
  Quant: PLongInt;
  Work: PLongInt;
  OutputLine: PByte;
  Tmp0, Tmp1, Tmp2, Tmp3: Int64;
  Tmp10, Tmp11, Tmp12, Tmp13: Int64;
  Z1, Z2, Z3, Z4, Z5: Int64;
begin
  AllZero := True;
  for Index := 1 to 63 do
    if Coefficients[Index] <> 0 then
    begin
      AllZero := False;
      Break;
    end;
  if AllZero then
  begin
    DcValue := LongInt(Coefficients[0]) * Quantization[0];
    FillBlock(Output, Stride, LimitSample(Descale(Int64(DcValue) shl Pass1Bits, Pass1Bits + 3)));
    Exit;
  end;

  { Columns. }
  for Column := 0 to 7 do
  begin
    Input := Coefficients + Column;
    Quant := Quantization + Column;
    Work := @Workspace[Column];
    if (Input[8] = 0) and (Input[16] = 0) and (Input[24] = 0) and (Input[32] = 0) and (Input[40] = 0) and
      (Input[48] = 0) and (Input[56] = 0) then
    begin
      DcValue := (LongInt(Input[0]) * Quant[0]) shl Pass1Bits;
      for Row := 0 to 7 do
        Work[Row * 8] := DcValue;
      Continue;
    end;
    Z2 := Int64(Input[16]) * Quant[16];
    Z3 := Int64(Input[48]) * Quant[48];
    Z1 := (Z2 + Z3) * Fix0541196100;
    Tmp2 := Z1 - Z3 * Fix1847759065;
    Tmp3 := Z1 + Z2 * Fix0765366865;
    Z2 := Int64(Input[0]) * Quant[0];
    Z3 := Int64(Input[32]) * Quant[32];
    Tmp0 := (Z2 + Z3) shl ConstantBits;
    Tmp1 := (Z2 - Z3) shl ConstantBits;
    Tmp10 := Tmp0 + Tmp3;
    Tmp13 := Tmp0 - Tmp3;
    Tmp11 := Tmp1 + Tmp2;
    Tmp12 := Tmp1 - Tmp2;

    Tmp0 := Int64(Input[56]) * Quant[56];
    Tmp1 := Int64(Input[40]) * Quant[40];
    Tmp2 := Int64(Input[24]) * Quant[24];
    Tmp3 := Int64(Input[8]) * Quant[8];
    Z1 := Tmp0 + Tmp3;
    Z2 := Tmp1 + Tmp2;
    Z3 := Tmp0 + Tmp2;
    Z4 := Tmp1 + Tmp3;
    Z5 := (Z3 + Z4) * Fix1175875602;
    Tmp0 := Tmp0 * Fix0298631336;
    Tmp1 := Tmp1 * Fix2053119869;
    Tmp2 := Tmp2 * Fix3072711026;
    Tmp3 := Tmp3 * Fix1501321110;
    Z1 := -Z1 * Fix0899976223;
    Z2 := -Z2 * Fix2562915447;
    Z3 := -Z3 * Fix1961570560 + Z5;
    Z4 := -Z4 * Fix0390180644 + Z5;
    Tmp0 := Tmp0 + Z1 + Z3;
    Tmp1 := Tmp1 + Z2 + Z4;
    Tmp2 := Tmp2 + Z2 + Z3;
    Tmp3 := Tmp3 + Z1 + Z4;

    Work[0] := LongInt(Descale(Tmp10 + Tmp3, ConstantBits - Pass1Bits));
    Work[56] := LongInt(Descale(Tmp10 - Tmp3, ConstantBits - Pass1Bits));
    Work[8] := LongInt(Descale(Tmp11 + Tmp2, ConstantBits - Pass1Bits));
    Work[48] := LongInt(Descale(Tmp11 - Tmp2, ConstantBits - Pass1Bits));
    Work[16] := LongInt(Descale(Tmp12 + Tmp1, ConstantBits - Pass1Bits));
    Work[40] := LongInt(Descale(Tmp12 - Tmp1, ConstantBits - Pass1Bits));
    Work[24] := LongInt(Descale(Tmp13 + Tmp0, ConstantBits - Pass1Bits));
    Work[32] := LongInt(Descale(Tmp13 - Tmp0, ConstantBits - Pass1Bits));
  end;

  { Rows. }
  for Row := 0 to 7 do
  begin
    Work := @Workspace[Row * 8];
    OutputLine := Output + Row * Stride;
    if (Work[1] = 0) and (Work[2] = 0) and (Work[3] = 0) and (Work[4] = 0) and (Work[5] = 0) and
      (Work[6] = 0) and (Work[7] = 0) then
    begin
      FillChar(OutputLine^, 8, LimitSample(Descale(Work[0], Pass1Bits + 3)));
      Continue;
    end;
    Z2 := Work[2];
    Z3 := Work[6];
    Z1 := (Z2 + Z3) * Fix0541196100;
    Tmp2 := Z1 - Z3 * Fix1847759065;
    Tmp3 := Z1 + Z2 * Fix0765366865;
    Tmp0 := (Int64(Work[0]) + Work[4]) shl ConstantBits;
    Tmp1 := (Int64(Work[0]) - Work[4]) shl ConstantBits;
    Tmp10 := Tmp0 + Tmp3;
    Tmp13 := Tmp0 - Tmp3;
    Tmp11 := Tmp1 + Tmp2;
    Tmp12 := Tmp1 - Tmp2;

    Tmp0 := Work[7];
    Tmp1 := Work[5];
    Tmp2 := Work[3];
    Tmp3 := Work[1];
    Z1 := Tmp0 + Tmp3;
    Z2 := Tmp1 + Tmp2;
    Z3 := Tmp0 + Tmp2;
    Z4 := Tmp1 + Tmp3;
    Z5 := (Z3 + Z4) * Fix1175875602;
    Tmp0 := Tmp0 * Fix0298631336;
    Tmp1 := Tmp1 * Fix2053119869;
    Tmp2 := Tmp2 * Fix3072711026;
    Tmp3 := Tmp3 * Fix1501321110;
    Z1 := -Z1 * Fix0899976223;
    Z2 := -Z2 * Fix2562915447;
    Z3 := -Z3 * Fix1961570560 + Z5;
    Z4 := -Z4 * Fix0390180644 + Z5;
    Tmp0 := Tmp0 + Z1 + Z3;
    Tmp1 := Tmp1 + Z2 + Z4;
    Tmp2 := Tmp2 + Z2 + Z3;
    Tmp3 := Tmp3 + Z1 + Z4;

    OutputLine[0] := LimitSample(Descale(Tmp10 + Tmp3, ConstantBits + Pass1Bits + 3));
    OutputLine[7] := LimitSample(Descale(Tmp10 - Tmp3, ConstantBits + Pass1Bits + 3));
    OutputLine[1] := LimitSample(Descale(Tmp11 + Tmp2, ConstantBits + Pass1Bits + 3));
    OutputLine[6] := LimitSample(Descale(Tmp11 - Tmp2, ConstantBits + Pass1Bits + 3));
    OutputLine[2] := LimitSample(Descale(Tmp12 + Tmp1, ConstantBits + Pass1Bits + 3));
    OutputLine[5] := LimitSample(Descale(Tmp12 - Tmp1, ConstantBits + Pass1Bits + 3));
    OutputLine[3] := LimitSample(Descale(Tmp13 + Tmp0, ConstantBits + Pass1Bits + 3));
    OutputLine[4] := LimitSample(Descale(Tmp13 - Tmp0, ConstantBits + Pass1Bits + 3));
  end;
end;

end.
