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
  VP9's inverse transforms (section 8.7.1 of the VP9 specification):
  the DCT of 4, 8, 16 and 32 points and the ADST of 4, 8 and 16, applied
  to the rows then the columns of a block and added to the prediction,
  and the Walsh-Hadamard transform of lossless frames.

  The 1-D transforms are the reference decoder's high bit depth ones
  (libvpx), with 64-bit products, rounded after every multiplication as
  it does; they serve every bit depth (for 8 bits the results are the
  same as long as the stream keeps its coefficients in range, which
  conforming streams do).
}
unit Vp9.Transforms;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

{ Adds the inverse transform of the Size x Size (4 << TransformSize)
  coefficients at Coefficients (row by row) to Target. TransformType is
  a Type* constant; Lossless selects the Walsh-Hadamard transform (4x4
  only). }
procedure AddInverseTransform(Coefficients: PLongInt; TransformSize, TransformType: LongInt;
  Lossless: Boolean; Target: PWord; Stride: LongInt; BitDepth: LongInt);

implementation

uses
  Vp9.Tables;

const
  cospi_1_64 = Int64(16364);
  cospi_2_64 = Int64(16305);
  cospi_3_64 = Int64(16207);
  cospi_4_64 = Int64(16069);
  cospi_5_64 = Int64(15893);
  cospi_6_64 = Int64(15679);
  cospi_7_64 = Int64(15426);
  cospi_8_64 = Int64(15137);
  cospi_9_64 = Int64(14811);
  cospi_10_64 = Int64(14449);
  cospi_11_64 = Int64(14053);
  cospi_12_64 = Int64(13623);
  cospi_13_64 = Int64(13160);
  cospi_14_64 = Int64(12665);
  cospi_15_64 = Int64(12140);
  cospi_16_64 = Int64(11585);
  cospi_17_64 = Int64(11003);
  cospi_18_64 = Int64(10394);
  cospi_19_64 = Int64(9760);
  cospi_20_64 = Int64(9102);
  cospi_21_64 = Int64(8423);
  cospi_22_64 = Int64(7723);
  cospi_23_64 = Int64(7005);
  cospi_24_64 = Int64(6270);
  cospi_25_64 = Int64(5520);
  cospi_26_64 = Int64(4756);
  cospi_27_64 = Int64(3981);
  cospi_28_64 = Int64(3196);
  cospi_29_64 = Int64(2404);
  cospi_30_64 = Int64(1606);
  cospi_31_64 = Int64(804);
  sinpi_1_9 = Int64(5283);
  sinpi_2_9 = Int64(9929);
  sinpi_3_9 = Int64(13377);
  sinpi_4_9 = Int64(15212);

type
  TTransform1D = procedure(Input, Output: PLongInt);

function DctRound(Value: Int64): Int64; inline;
begin
  Result := SarInt64(Value + 8192, 14);
end;

procedure InverseAdst4(Input, Output: PLongInt);
var
  s0, s1, s2, s3, s4, s5, s6, s7: Int64;
  x0, x1, x2, x3: LongInt;
begin
  x0 := input[0];
  x1 := input[1];
  x2 := input[2];
  x3 := input[3];
  if (x0 or x1 or x2 or x3) = 0 then
  begin
    FillChar(Output^, 4 * SizeOf(LongInt), 0);
    Exit;
  end;
  s0 := sinpi_1_9 * x0;
  s1 := sinpi_2_9 * x0;
  s2 := sinpi_3_9 * x1;
  s3 := sinpi_4_9 * x2;
  s4 := sinpi_1_9 * x2;
  s5 := sinpi_2_9 * x3;
  s6 := sinpi_4_9 * x3;
  s7 := (x0 - x2 + x3);
  s0 := s0 + s3 + s5;
  s1 := s1 - s4 - s6;
  s3 := s2;
  s2 := sinpi_3_9 * s7;
  Output[0] := LongInt((DctRound(s0 + s3)));
  Output[1] := LongInt((DctRound(s1 + s3)));
  Output[2] := LongInt((DctRound(s2)));
  Output[3] := LongInt((DctRound(s0 + s1 - s3)));
end;

procedure InverseDct4(Input, Output: PLongInt);
var
  temp1, temp2: Int64;
  step: array[0..3] of LongInt;
begin
  temp1 := (Input[0] + Input[2]) * cospi_16_64;
  temp2 := (Input[0] - Input[2]) * cospi_16_64;
  step[0] := LongInt((DctRound(temp1)));
  step[1] := LongInt((DctRound(temp2)));
  temp1 := Input[1] * cospi_24_64 - Input[3] * cospi_8_64;
  temp2 := Input[1] * cospi_8_64 + Input[3] * cospi_24_64;
  step[2] := LongInt((DctRound(temp1)));
  step[3] := LongInt((DctRound(temp2)));
  Output[0] := LongInt((step[0] + step[3]));
  Output[1] := LongInt((step[1] + step[2]));
  Output[2] := LongInt((step[1] - step[2]));
  Output[3] := LongInt((step[0] - step[3]));
end;

procedure InverseAdst8(Input, Output: PLongInt);
var
  s0, s1, s2, s3, s4, s5, s6, s7: Int64;
  x0, x1, x2, x3, x4, x5, x6, x7: LongInt;
begin
  x0 := input[7];
  x1 := input[0];
  x2 := input[5];
  x3 := input[2];
  x4 := input[3];
  x5 := input[4];
  x6 := input[1];
  x7 := input[6];
  if (x0 or x1 or x2 or x3 or x4 or x5 or x6 or x7) = 0 then
  begin
    FillChar(Output^, 8 * SizeOf(LongInt), 0);
    Exit;
  end;
  s0 := cospi_2_64 * x0 + cospi_30_64 * x1;
  s1 := cospi_30_64 * x0 - cospi_2_64 * x1;
  s2 := cospi_10_64 * x2 + cospi_22_64 * x3;
  s3 := cospi_22_64 * x2 - cospi_10_64 * x3;
  s4 := cospi_18_64 * x4 + cospi_14_64 * x5;
  s5 := cospi_14_64 * x4 - cospi_18_64 * x5;
  s6 := cospi_26_64 * x6 + cospi_6_64 * x7;
  s7 := cospi_6_64 * x6 - cospi_26_64 * x7;
  x0 := LongInt((DctRound(s0 + s4)));
  x1 := LongInt((DctRound(s1 + s5)));
  x2 := LongInt((DctRound(s2 + s6)));
  x3 := LongInt((DctRound(s3 + s7)));
  x4 := LongInt((DctRound(s0 - s4)));
  x5 := LongInt((DctRound(s1 - s5)));
  x6 := LongInt((DctRound(s2 - s6)));
  x7 := LongInt((DctRound(s3 - s7)));
  s0 := x0;
  s1 := x1;
  s2 := x2;
  s3 := x3;
  s4 := cospi_8_64 * x4 + cospi_24_64 * x5;
  s5 := cospi_24_64 * x4 - cospi_8_64 * x5;
  s6 := (-cospi_24_64) * x6 + cospi_8_64 * x7;
  s7 := cospi_8_64 * x6 + cospi_24_64 * x7;
  x0 := LongInt((s0 + s2));
  x1 := LongInt((s1 + s3));
  x2 := LongInt((s0 - s2));
  x3 := LongInt((s1 - s3));
  x4 := LongInt((DctRound(s4 + s6)));
  x5 := LongInt((DctRound(s5 + s7)));
  x6 := LongInt((DctRound(s4 - s6)));
  x7 := LongInt((DctRound(s5 - s7)));
  s2 := cospi_16_64 * (x2 + x3);
  s3 := cospi_16_64 * (x2 - x3);
  s6 := cospi_16_64 * (x6 + x7);
  s7 := cospi_16_64 * (x6 - x7);
  x2 := LongInt((DctRound(s2)));
  x3 := LongInt((DctRound(s3)));
  x6 := LongInt((DctRound(s6)));
  x7 := LongInt((DctRound(s7)));
  Output[0] := LongInt((x0));
  Output[1] := LongInt((-x4));
  Output[2] := LongInt((x6));
  Output[3] := LongInt((-x2));
  Output[4] := LongInt((x3));
  Output[5] := LongInt((-x7));
  Output[6] := LongInt((x5));
  Output[7] := LongInt((-x1));
end;

procedure InverseDct8(Input, Output: PLongInt);
var
  temp1, temp2: Int64;
  step1: array[0..7] of LongInt;
  step2: array[0..7] of LongInt;
begin
  step1[0] := LongInt(Input[0]);
  step1[2] := LongInt(Input[4]);
  step1[1] := LongInt(Input[2]);
  step1[3] := LongInt(Input[6]);
  temp1 := Input[1] * cospi_28_64 - Input[7] * cospi_4_64;
  temp2 := Input[1] * cospi_4_64 + Input[7] * cospi_28_64;
  step1[4] := LongInt((DctRound(temp1)));
  step1[7] := LongInt((DctRound(temp2)));
  temp1 := Input[5] * cospi_12_64 - Input[3] * cospi_20_64;
  temp2 := Input[5] * cospi_20_64 + Input[3] * cospi_12_64;
  step1[5] := LongInt((DctRound(temp1)));
  step1[6] := LongInt((DctRound(temp2)));
  InverseDct4(@step1[0], @step1[0]);
  step2[4] := LongInt((step1[4] + step1[5]));
  step2[5] := LongInt((step1[4] - step1[5]));
  step2[6] := LongInt((-step1[6] + step1[7]));
  step2[7] := LongInt((step1[6] + step1[7]));
  step1[4] := LongInt(step2[4]);
  temp1 := (step2[6] - step2[5]) * cospi_16_64;
  temp2 := (step2[5] + step2[6]) * cospi_16_64;
  step1[5] := LongInt((DctRound(temp1)));
  step1[6] := LongInt((DctRound(temp2)));
  step1[7] := LongInt(step2[7]);
  Output[0] := LongInt((step1[0] + step1[7]));
  Output[1] := LongInt((step1[1] + step1[6]));
  Output[2] := LongInt((step1[2] + step1[5]));
  Output[3] := LongInt((step1[3] + step1[4]));
  Output[4] := LongInt((step1[3] - step1[4]));
  Output[5] := LongInt((step1[2] - step1[5]));
  Output[6] := LongInt((step1[1] - step1[6]));
  Output[7] := LongInt((step1[0] - step1[7]));
end;

procedure InverseAdst16(Input, Output: PLongInt);
var
  s0, s1, s2, s3, s4, s5, s6, s7: Int64;
  s8, s9, s10, s11, s12, s13, s14, s15: Int64;
  x0, x1, x2, x3, x4, x5, x6, x7: LongInt;
  x8, x9, x10, x11, x12, x13, x14, x15: LongInt;
begin
  x0 := input[15];
  x1 := input[0];
  x2 := input[13];
  x3 := input[2];
  x4 := input[11];
  x5 := input[4];
  x6 := input[9];
  x7 := input[6];
  x8 := input[7];
  x9 := input[8];
  x10 := input[5];
  x11 := input[10];
  x12 := input[3];
  x13 := input[12];
  x14 := input[1];
  x15 := input[14];
  if (x0 or x1 or x2 or x3 or x4 or x5 or x6 or x7 or x8 or x9 or x10 or x11 or x12 or x13 or x14 or x15) = 0 then
  begin
    FillChar(Output^, 16 * SizeOf(LongInt), 0);
    Exit;
  end;
  s0 := x0 * cospi_1_64 + x1 * cospi_31_64;
  s1 := x0 * cospi_31_64 - x1 * cospi_1_64;
  s2 := x2 * cospi_5_64 + x3 * cospi_27_64;
  s3 := x2 * cospi_27_64 - x3 * cospi_5_64;
  s4 := x4 * cospi_9_64 + x5 * cospi_23_64;
  s5 := x4 * cospi_23_64 - x5 * cospi_9_64;
  s6 := x6 * cospi_13_64 + x7 * cospi_19_64;
  s7 := x6 * cospi_19_64 - x7 * cospi_13_64;
  s8 := x8 * cospi_17_64 + x9 * cospi_15_64;
  s9 := x8 * cospi_15_64 - x9 * cospi_17_64;
  s10 := x10 * cospi_21_64 + x11 * cospi_11_64;
  s11 := x10 * cospi_11_64 - x11 * cospi_21_64;
  s12 := x12 * cospi_25_64 + x13 * cospi_7_64;
  s13 := x12 * cospi_7_64 - x13 * cospi_25_64;
  s14 := x14 * cospi_29_64 + x15 * cospi_3_64;
  s15 := x14 * cospi_3_64 - x15 * cospi_29_64;
  x0 := LongInt((DctRound(s0 + s8)));
  x1 := LongInt((DctRound(s1 + s9)));
  x2 := LongInt((DctRound(s2 + s10)));
  x3 := LongInt((DctRound(s3 + s11)));
  x4 := LongInt((DctRound(s4 + s12)));
  x5 := LongInt((DctRound(s5 + s13)));
  x6 := LongInt((DctRound(s6 + s14)));
  x7 := LongInt((DctRound(s7 + s15)));
  x8 := LongInt((DctRound(s0 - s8)));
  x9 := LongInt((DctRound(s1 - s9)));
  x10 := LongInt((DctRound(s2 - s10)));
  x11 := LongInt((DctRound(s3 - s11)));
  x12 := LongInt((DctRound(s4 - s12)));
  x13 := LongInt((DctRound(s5 - s13)));
  x14 := LongInt((DctRound(s6 - s14)));
  x15 := LongInt((DctRound(s7 - s15)));
  s0 := x0;
  s1 := x1;
  s2 := x2;
  s3 := x3;
  s4 := x4;
  s5 := x5;
  s6 := x6;
  s7 := x7;
  s8 := x8 * cospi_4_64 + x9 * cospi_28_64;
  s9 := x8 * cospi_28_64 - x9 * cospi_4_64;
  s10 := x10 * cospi_20_64 + x11 * cospi_12_64;
  s11 := x10 * cospi_12_64 - x11 * cospi_20_64;
  s12 := -x12 * cospi_28_64 + x13 * cospi_4_64;
  s13 := x12 * cospi_4_64 + x13 * cospi_28_64;
  s14 := -x14 * cospi_12_64 + x15 * cospi_20_64;
  s15 := x14 * cospi_20_64 + x15 * cospi_12_64;
  x0 := LongInt((s0 + s4));
  x1 := LongInt((s1 + s5));
  x2 := LongInt((s2 + s6));
  x3 := LongInt((s3 + s7));
  x4 := LongInt((s0 - s4));
  x5 := LongInt((s1 - s5));
  x6 := LongInt((s2 - s6));
  x7 := LongInt((s3 - s7));
  x8 := LongInt((DctRound(s8 + s12)));
  x9 := LongInt((DctRound(s9 + s13)));
  x10 := LongInt((DctRound(s10 + s14)));
  x11 := LongInt((DctRound(s11 + s15)));
  x12 := LongInt((DctRound(s8 - s12)));
  x13 := LongInt((DctRound(s9 - s13)));
  x14 := LongInt((DctRound(s10 - s14)));
  x15 := LongInt((DctRound(s11 - s15)));
  s0 := x0;
  s1 := x1;
  s2 := x2;
  s3 := x3;
  s4 := x4 * cospi_8_64 + x5 * cospi_24_64;
  s5 := x4 * cospi_24_64 - x5 * cospi_8_64;
  s6 := -x6 * cospi_24_64 + x7 * cospi_8_64;
  s7 := x6 * cospi_8_64 + x7 * cospi_24_64;
  s8 := x8;
  s9 := x9;
  s10 := x10;
  s11 := x11;
  s12 := x12 * cospi_8_64 + x13 * cospi_24_64;
  s13 := x12 * cospi_24_64 - x13 * cospi_8_64;
  s14 := -x14 * cospi_24_64 + x15 * cospi_8_64;
  s15 := x14 * cospi_8_64 + x15 * cospi_24_64;
  x0 := LongInt((s0 + s2));
  x1 := LongInt((s1 + s3));
  x2 := LongInt((s0 - s2));
  x3 := LongInt((s1 - s3));
  x4 := LongInt((DctRound(s4 + s6)));
  x5 := LongInt((DctRound(s5 + s7)));
  x6 := LongInt((DctRound(s4 - s6)));
  x7 := LongInt((DctRound(s5 - s7)));
  x8 := LongInt((s8 + s10));
  x9 := LongInt((s9 + s11));
  x10 := LongInt((s8 - s10));
  x11 := LongInt((s9 - s11));
  x12 := LongInt((DctRound(s12 + s14)));
  x13 := LongInt((DctRound(s13 + s15)));
  x14 := LongInt((DctRound(s12 - s14)));
  x15 := LongInt((DctRound(s13 - s15)));
  s2 := (-cospi_16_64) * (x2 + x3);
  s3 := cospi_16_64 * (x2 - x3);
  s6 := cospi_16_64 * (x6 + x7);
  s7 := cospi_16_64 * (-x6 + x7);
  s10 := cospi_16_64 * (x10 + x11);
  s11 := cospi_16_64 * (-x10 + x11);
  s14 := (-cospi_16_64) * (x14 + x15);
  s15 := cospi_16_64 * (x14 - x15);
  x2 := LongInt((DctRound(s2)));
  x3 := LongInt((DctRound(s3)));
  x6 := LongInt((DctRound(s6)));
  x7 := LongInt((DctRound(s7)));
  x10 := LongInt((DctRound(s10)));
  x11 := LongInt((DctRound(s11)));
  x14 := LongInt((DctRound(s14)));
  x15 := LongInt((DctRound(s15)));
  Output[0] := LongInt((x0));
  Output[1] := LongInt((-x8));
  Output[2] := LongInt((x12));
  Output[3] := LongInt((-x4));
  Output[4] := LongInt((x6));
  Output[5] := LongInt((x14));
  Output[6] := LongInt((x10));
  Output[7] := LongInt((x2));
  Output[8] := LongInt((x3));
  Output[9] := LongInt((x11));
  Output[10] := LongInt((x15));
  Output[11] := LongInt((x7));
  Output[12] := LongInt((x5));
  Output[13] := LongInt((-x13));
  Output[14] := LongInt((x9));
  Output[15] := LongInt((-x1));
end;

procedure InverseDct16(Input, Output: PLongInt);
var
  temp1, temp2: Int64;
  step1: array[0..15] of LongInt;
  step2: array[0..15] of LongInt;
begin
  step1[0] := LongInt(Input[0 div 2]);
  step1[1] := LongInt(Input[16 div 2]);
  step1[2] := LongInt(Input[8 div 2]);
  step1[3] := LongInt(Input[24 div 2]);
  step1[4] := LongInt(Input[4 div 2]);
  step1[5] := LongInt(Input[20 div 2]);
  step1[6] := LongInt(Input[12 div 2]);
  step1[7] := LongInt(Input[28 div 2]);
  step1[8] := LongInt(Input[2 div 2]);
  step1[9] := LongInt(Input[18 div 2]);
  step1[10] := LongInt(Input[10 div 2]);
  step1[11] := LongInt(Input[26 div 2]);
  step1[12] := LongInt(Input[6 div 2]);
  step1[13] := LongInt(Input[22 div 2]);
  step1[14] := LongInt(Input[14 div 2]);
  step1[15] := LongInt(Input[30 div 2]);
  step2[0] := LongInt(step1[0]);
  step2[1] := LongInt(step1[1]);
  step2[2] := LongInt(step1[2]);
  step2[3] := LongInt(step1[3]);
  step2[4] := LongInt(step1[4]);
  step2[5] := LongInt(step1[5]);
  step2[6] := LongInt(step1[6]);
  step2[7] := LongInt(step1[7]);
  temp1 := step1[8] * cospi_30_64 - step1[15] * cospi_2_64;
  temp2 := step1[8] * cospi_2_64 + step1[15] * cospi_30_64;
  step2[8] := LongInt((DctRound(temp1)));
  step2[15] := LongInt((DctRound(temp2)));
  temp1 := step1[9] * cospi_14_64 - step1[14] * cospi_18_64;
  temp2 := step1[9] * cospi_18_64 + step1[14] * cospi_14_64;
  step2[9] := LongInt((DctRound(temp1)));
  step2[14] := LongInt((DctRound(temp2)));
  temp1 := step1[10] * cospi_22_64 - step1[13] * cospi_10_64;
  temp2 := step1[10] * cospi_10_64 + step1[13] * cospi_22_64;
  step2[10] := LongInt((DctRound(temp1)));
  step2[13] := LongInt((DctRound(temp2)));
  temp1 := step1[11] * cospi_6_64 - step1[12] * cospi_26_64;
  temp2 := step1[11] * cospi_26_64 + step1[12] * cospi_6_64;
  step2[11] := LongInt((DctRound(temp1)));
  step2[12] := LongInt((DctRound(temp2)));
  step1[0] := LongInt(step2[0]);
  step1[1] := LongInt(step2[1]);
  step1[2] := LongInt(step2[2]);
  step1[3] := LongInt(step2[3]);
  temp1 := step2[4] * cospi_28_64 - step2[7] * cospi_4_64;
  temp2 := step2[4] * cospi_4_64 + step2[7] * cospi_28_64;
  step1[4] := LongInt((DctRound(temp1)));
  step1[7] := LongInt((DctRound(temp2)));
  temp1 := step2[5] * cospi_12_64 - step2[6] * cospi_20_64;
  temp2 := step2[5] * cospi_20_64 + step2[6] * cospi_12_64;
  step1[5] := LongInt((DctRound(temp1)));
  step1[6] := LongInt((DctRound(temp2)));
  step1[8] := LongInt((step2[8] + step2[9]));
  step1[9] := LongInt((step2[8] - step2[9]));
  step1[10] := LongInt((-step2[10] + step2[11]));
  step1[11] := LongInt((step2[10] + step2[11]));
  step1[12] := LongInt((step2[12] + step2[13]));
  step1[13] := LongInt((step2[12] - step2[13]));
  step1[14] := LongInt((-step2[14] + step2[15]));
  step1[15] := LongInt((step2[14] + step2[15]));
  temp1 := (step1[0] + step1[1]) * cospi_16_64;
  temp2 := (step1[0] - step1[1]) * cospi_16_64;
  step2[0] := LongInt((DctRound(temp1)));
  step2[1] := LongInt((DctRound(temp2)));
  temp1 := step1[2] * cospi_24_64 - step1[3] * cospi_8_64;
  temp2 := step1[2] * cospi_8_64 + step1[3] * cospi_24_64;
  step2[2] := LongInt((DctRound(temp1)));
  step2[3] := LongInt((DctRound(temp2)));
  step2[4] := LongInt((step1[4] + step1[5]));
  step2[5] := LongInt((step1[4] - step1[5]));
  step2[6] := LongInt((-step1[6] + step1[7]));
  step2[7] := LongInt((step1[6] + step1[7]));
  step2[8] := LongInt(step1[8]);
  step2[15] := LongInt(step1[15]);
  temp1 := -step1[9] * cospi_8_64 + step1[14] * cospi_24_64;
  temp2 := step1[9] * cospi_24_64 + step1[14] * cospi_8_64;
  step2[9] := LongInt((DctRound(temp1)));
  step2[14] := LongInt((DctRound(temp2)));
  temp1 := -step1[10] * cospi_24_64 - step1[13] * cospi_8_64;
  temp2 := -step1[10] * cospi_8_64 + step1[13] * cospi_24_64;
  step2[10] := LongInt((DctRound(temp1)));
  step2[13] := LongInt((DctRound(temp2)));
  step2[11] := LongInt(step1[11]);
  step2[12] := LongInt(step1[12]);
  step1[0] := LongInt((step2[0] + step2[3]));
  step1[1] := LongInt((step2[1] + step2[2]));
  step1[2] := LongInt((step2[1] - step2[2]));
  step1[3] := LongInt((step2[0] - step2[3]));
  step1[4] := LongInt(step2[4]);
  temp1 := (step2[6] - step2[5]) * cospi_16_64;
  temp2 := (step2[5] + step2[6]) * cospi_16_64;
  step1[5] := LongInt((DctRound(temp1)));
  step1[6] := LongInt((DctRound(temp2)));
  step1[7] := LongInt(step2[7]);
  step1[8] := LongInt((step2[8] + step2[11]));
  step1[9] := LongInt((step2[9] + step2[10]));
  step1[10] := LongInt((step2[9] - step2[10]));
  step1[11] := LongInt((step2[8] - step2[11]));
  step1[12] := LongInt((-step2[12] + step2[15]));
  step1[13] := LongInt((-step2[13] + step2[14]));
  step1[14] := LongInt((step2[13] + step2[14]));
  step1[15] := LongInt((step2[12] + step2[15]));
  step2[0] := LongInt((step1[0] + step1[7]));
  step2[1] := LongInt((step1[1] + step1[6]));
  step2[2] := LongInt((step1[2] + step1[5]));
  step2[3] := LongInt((step1[3] + step1[4]));
  step2[4] := LongInt((step1[3] - step1[4]));
  step2[5] := LongInt((step1[2] - step1[5]));
  step2[6] := LongInt((step1[1] - step1[6]));
  step2[7] := LongInt((step1[0] - step1[7]));
  step2[8] := LongInt(step1[8]);
  step2[9] := LongInt(step1[9]);
  temp1 := (-step1[10] + step1[13]) * cospi_16_64;
  temp2 := (step1[10] + step1[13]) * cospi_16_64;
  step2[10] := LongInt((DctRound(temp1)));
  step2[13] := LongInt((DctRound(temp2)));
  temp1 := (-step1[11] + step1[12]) * cospi_16_64;
  temp2 := (step1[11] + step1[12]) * cospi_16_64;
  step2[11] := LongInt((DctRound(temp1)));
  step2[12] := LongInt((DctRound(temp2)));
  step2[14] := LongInt(step1[14]);
  step2[15] := LongInt(step1[15]);
  Output[0] := LongInt((step2[0] + step2[15]));
  Output[1] := LongInt((step2[1] + step2[14]));
  Output[2] := LongInt((step2[2] + step2[13]));
  Output[3] := LongInt((step2[3] + step2[12]));
  Output[4] := LongInt((step2[4] + step2[11]));
  Output[5] := LongInt((step2[5] + step2[10]));
  Output[6] := LongInt((step2[6] + step2[9]));
  Output[7] := LongInt((step2[7] + step2[8]));
  Output[8] := LongInt((step2[7] - step2[8]));
  Output[9] := LongInt((step2[6] - step2[9]));
  Output[10] := LongInt((step2[5] - step2[10]));
  Output[11] := LongInt((step2[4] - step2[11]));
  Output[12] := LongInt((step2[3] - step2[12]));
  Output[13] := LongInt((step2[2] - step2[13]));
  Output[14] := LongInt((step2[1] - step2[14]));
  Output[15] := LongInt((step2[0] - step2[15]));
end;

procedure InverseDct32(Input, Output: PLongInt);
var
  temp1, temp2: Int64;
  step1: array[0..31] of LongInt;
  step2: array[0..31] of LongInt;
begin
  step1[0] := LongInt(Input[0]);
  step1[1] := LongInt(Input[16]);
  step1[2] := LongInt(Input[8]);
  step1[3] := LongInt(Input[24]);
  step1[4] := LongInt(Input[4]);
  step1[5] := LongInt(Input[20]);
  step1[6] := LongInt(Input[12]);
  step1[7] := LongInt(Input[28]);
  step1[8] := LongInt(Input[2]);
  step1[9] := LongInt(Input[18]);
  step1[10] := LongInt(Input[10]);
  step1[11] := LongInt(Input[26]);
  step1[12] := LongInt(Input[6]);
  step1[13] := LongInt(Input[22]);
  step1[14] := LongInt(Input[14]);
  step1[15] := LongInt(Input[30]);
  temp1 := Input[1] * cospi_31_64 - Input[31] * cospi_1_64;
  temp2 := Input[1] * cospi_1_64 + Input[31] * cospi_31_64;
  step1[16] := LongInt((DctRound(temp1)));
  step1[31] := LongInt((DctRound(temp2)));
  temp1 := Input[17] * cospi_15_64 - Input[15] * cospi_17_64;
  temp2 := Input[17] * cospi_17_64 + Input[15] * cospi_15_64;
  step1[17] := LongInt((DctRound(temp1)));
  step1[30] := LongInt((DctRound(temp2)));
  temp1 := Input[9] * cospi_23_64 - Input[23] * cospi_9_64;
  temp2 := Input[9] * cospi_9_64 + Input[23] * cospi_23_64;
  step1[18] := LongInt((DctRound(temp1)));
  step1[29] := LongInt((DctRound(temp2)));
  temp1 := Input[25] * cospi_7_64 - Input[7] * cospi_25_64;
  temp2 := Input[25] * cospi_25_64 + Input[7] * cospi_7_64;
  step1[19] := LongInt((DctRound(temp1)));
  step1[28] := LongInt((DctRound(temp2)));
  temp1 := Input[5] * cospi_27_64 - Input[27] * cospi_5_64;
  temp2 := Input[5] * cospi_5_64 + Input[27] * cospi_27_64;
  step1[20] := LongInt((DctRound(temp1)));
  step1[27] := LongInt((DctRound(temp2)));
  temp1 := Input[21] * cospi_11_64 - Input[11] * cospi_21_64;
  temp2 := Input[21] * cospi_21_64 + Input[11] * cospi_11_64;
  step1[21] := LongInt((DctRound(temp1)));
  step1[26] := LongInt((DctRound(temp2)));
  temp1 := Input[13] * cospi_19_64 - Input[19] * cospi_13_64;
  temp2 := Input[13] * cospi_13_64 + Input[19] * cospi_19_64;
  step1[22] := LongInt((DctRound(temp1)));
  step1[25] := LongInt((DctRound(temp2)));
  temp1 := Input[29] * cospi_3_64 - Input[3] * cospi_29_64;
  temp2 := Input[29] * cospi_29_64 + Input[3] * cospi_3_64;
  step1[23] := LongInt((DctRound(temp1)));
  step1[24] := LongInt((DctRound(temp2)));
  step2[0] := LongInt(step1[0]);
  step2[1] := LongInt(step1[1]);
  step2[2] := LongInt(step1[2]);
  step2[3] := LongInt(step1[3]);
  step2[4] := LongInt(step1[4]);
  step2[5] := LongInt(step1[5]);
  step2[6] := LongInt(step1[6]);
  step2[7] := LongInt(step1[7]);
  temp1 := step1[8] * cospi_30_64 - step1[15] * cospi_2_64;
  temp2 := step1[8] * cospi_2_64 + step1[15] * cospi_30_64;
  step2[8] := LongInt((DctRound(temp1)));
  step2[15] := LongInt((DctRound(temp2)));
  temp1 := step1[9] * cospi_14_64 - step1[14] * cospi_18_64;
  temp2 := step1[9] * cospi_18_64 + step1[14] * cospi_14_64;
  step2[9] := LongInt((DctRound(temp1)));
  step2[14] := LongInt((DctRound(temp2)));
  temp1 := step1[10] * cospi_22_64 - step1[13] * cospi_10_64;
  temp2 := step1[10] * cospi_10_64 + step1[13] * cospi_22_64;
  step2[10] := LongInt((DctRound(temp1)));
  step2[13] := LongInt((DctRound(temp2)));
  temp1 := step1[11] * cospi_6_64 - step1[12] * cospi_26_64;
  temp2 := step1[11] * cospi_26_64 + step1[12] * cospi_6_64;
  step2[11] := LongInt((DctRound(temp1)));
  step2[12] := LongInt((DctRound(temp2)));
  step2[16] := LongInt((step1[16] + step1[17]));
  step2[17] := LongInt((step1[16] - step1[17]));
  step2[18] := LongInt((-step1[18] + step1[19]));
  step2[19] := LongInt((step1[18] + step1[19]));
  step2[20] := LongInt((step1[20] + step1[21]));
  step2[21] := LongInt((step1[20] - step1[21]));
  step2[22] := LongInt((-step1[22] + step1[23]));
  step2[23] := LongInt((step1[22] + step1[23]));
  step2[24] := LongInt((step1[24] + step1[25]));
  step2[25] := LongInt((step1[24] - step1[25]));
  step2[26] := LongInt((-step1[26] + step1[27]));
  step2[27] := LongInt((step1[26] + step1[27]));
  step2[28] := LongInt((step1[28] + step1[29]));
  step2[29] := LongInt((step1[28] - step1[29]));
  step2[30] := LongInt((-step1[30] + step1[31]));
  step2[31] := LongInt((step1[30] + step1[31]));
  step1[0] := LongInt(step2[0]);
  step1[1] := LongInt(step2[1]);
  step1[2] := LongInt(step2[2]);
  step1[3] := LongInt(step2[3]);
  temp1 := step2[4] * cospi_28_64 - step2[7] * cospi_4_64;
  temp2 := step2[4] * cospi_4_64 + step2[7] * cospi_28_64;
  step1[4] := LongInt((DctRound(temp1)));
  step1[7] := LongInt((DctRound(temp2)));
  temp1 := step2[5] * cospi_12_64 - step2[6] * cospi_20_64;
  temp2 := step2[5] * cospi_20_64 + step2[6] * cospi_12_64;
  step1[5] := LongInt((DctRound(temp1)));
  step1[6] := LongInt((DctRound(temp2)));
  step1[8] := LongInt((step2[8] + step2[9]));
  step1[9] := LongInt((step2[8] - step2[9]));
  step1[10] := LongInt((-step2[10] + step2[11]));
  step1[11] := LongInt((step2[10] + step2[11]));
  step1[12] := LongInt((step2[12] + step2[13]));
  step1[13] := LongInt((step2[12] - step2[13]));
  step1[14] := LongInt((-step2[14] + step2[15]));
  step1[15] := LongInt((step2[14] + step2[15]));
  step1[16] := LongInt(step2[16]);
  step1[31] := LongInt(step2[31]);
  temp1 := -step2[17] * cospi_4_64 + step2[30] * cospi_28_64;
  temp2 := step2[17] * cospi_28_64 + step2[30] * cospi_4_64;
  step1[17] := LongInt((DctRound(temp1)));
  step1[30] := LongInt((DctRound(temp2)));
  temp1 := -step2[18] * cospi_28_64 - step2[29] * cospi_4_64;
  temp2 := -step2[18] * cospi_4_64 + step2[29] * cospi_28_64;
  step1[18] := LongInt((DctRound(temp1)));
  step1[29] := LongInt((DctRound(temp2)));
  step1[19] := LongInt(step2[19]);
  step1[20] := LongInt(step2[20]);
  temp1 := -step2[21] * cospi_20_64 + step2[26] * cospi_12_64;
  temp2 := step2[21] * cospi_12_64 + step2[26] * cospi_20_64;
  step1[21] := LongInt((DctRound(temp1)));
  step1[26] := LongInt((DctRound(temp2)));
  temp1 := -step2[22] * cospi_12_64 - step2[25] * cospi_20_64;
  temp2 := -step2[22] * cospi_20_64 + step2[25] * cospi_12_64;
  step1[22] := LongInt((DctRound(temp1)));
  step1[25] := LongInt((DctRound(temp2)));
  step1[23] := LongInt(step2[23]);
  step1[24] := LongInt(step2[24]);
  step1[27] := LongInt(step2[27]);
  step1[28] := LongInt(step2[28]);
  temp1 := (step1[0] + step1[1]) * cospi_16_64;
  temp2 := (step1[0] - step1[1]) * cospi_16_64;
  step2[0] := LongInt((DctRound(temp1)));
  step2[1] := LongInt((DctRound(temp2)));
  temp1 := step1[2] * cospi_24_64 - step1[3] * cospi_8_64;
  temp2 := step1[2] * cospi_8_64 + step1[3] * cospi_24_64;
  step2[2] := LongInt((DctRound(temp1)));
  step2[3] := LongInt((DctRound(temp2)));
  step2[4] := LongInt((step1[4] + step1[5]));
  step2[5] := LongInt((step1[4] - step1[5]));
  step2[6] := LongInt((-step1[6] + step1[7]));
  step2[7] := LongInt((step1[6] + step1[7]));
  step2[8] := LongInt(step1[8]);
  step2[15] := LongInt(step1[15]);
  temp1 := -step1[9] * cospi_8_64 + step1[14] * cospi_24_64;
  temp2 := step1[9] * cospi_24_64 + step1[14] * cospi_8_64;
  step2[9] := LongInt((DctRound(temp1)));
  step2[14] := LongInt((DctRound(temp2)));
  temp1 := -step1[10] * cospi_24_64 - step1[13] * cospi_8_64;
  temp2 := -step1[10] * cospi_8_64 + step1[13] * cospi_24_64;
  step2[10] := LongInt((DctRound(temp1)));
  step2[13] := LongInt((DctRound(temp2)));
  step2[11] := LongInt(step1[11]);
  step2[12] := LongInt(step1[12]);
  step2[16] := LongInt((step1[16] + step1[19]));
  step2[17] := LongInt((step1[17] + step1[18]));
  step2[18] := LongInt((step1[17] - step1[18]));
  step2[19] := LongInt((step1[16] - step1[19]));
  step2[20] := LongInt((-step1[20] + step1[23]));
  step2[21] := LongInt((-step1[21] + step1[22]));
  step2[22] := LongInt((step1[21] + step1[22]));
  step2[23] := LongInt((step1[20] + step1[23]));
  step2[24] := LongInt((step1[24] + step1[27]));
  step2[25] := LongInt((step1[25] + step1[26]));
  step2[26] := LongInt((step1[25] - step1[26]));
  step2[27] := LongInt((step1[24] - step1[27]));
  step2[28] := LongInt((-step1[28] + step1[31]));
  step2[29] := LongInt((-step1[29] + step1[30]));
  step2[30] := LongInt((step1[29] + step1[30]));
  step2[31] := LongInt((step1[28] + step1[31]));
  step1[0] := LongInt((step2[0] + step2[3]));
  step1[1] := LongInt((step2[1] + step2[2]));
  step1[2] := LongInt((step2[1] - step2[2]));
  step1[3] := LongInt((step2[0] - step2[3]));
  step1[4] := LongInt(step2[4]);
  temp1 := (step2[6] - step2[5]) * cospi_16_64;
  temp2 := (step2[5] + step2[6]) * cospi_16_64;
  step1[5] := LongInt((DctRound(temp1)));
  step1[6] := LongInt((DctRound(temp2)));
  step1[7] := LongInt(step2[7]);
  step1[8] := LongInt((step2[8] + step2[11]));
  step1[9] := LongInt((step2[9] + step2[10]));
  step1[10] := LongInt((step2[9] - step2[10]));
  step1[11] := LongInt((step2[8] - step2[11]));
  step1[12] := LongInt((-step2[12] + step2[15]));
  step1[13] := LongInt((-step2[13] + step2[14]));
  step1[14] := LongInt((step2[13] + step2[14]));
  step1[15] := LongInt((step2[12] + step2[15]));
  step1[16] := LongInt(step2[16]);
  step1[17] := LongInt(step2[17]);
  temp1 := -step2[18] * cospi_8_64 + step2[29] * cospi_24_64;
  temp2 := step2[18] * cospi_24_64 + step2[29] * cospi_8_64;
  step1[18] := LongInt((DctRound(temp1)));
  step1[29] := LongInt((DctRound(temp2)));
  temp1 := -step2[19] * cospi_8_64 + step2[28] * cospi_24_64;
  temp2 := step2[19] * cospi_24_64 + step2[28] * cospi_8_64;
  step1[19] := LongInt((DctRound(temp1)));
  step1[28] := LongInt((DctRound(temp2)));
  temp1 := -step2[20] * cospi_24_64 - step2[27] * cospi_8_64;
  temp2 := -step2[20] * cospi_8_64 + step2[27] * cospi_24_64;
  step1[20] := LongInt((DctRound(temp1)));
  step1[27] := LongInt((DctRound(temp2)));
  temp1 := -step2[21] * cospi_24_64 - step2[26] * cospi_8_64;
  temp2 := -step2[21] * cospi_8_64 + step2[26] * cospi_24_64;
  step1[21] := LongInt((DctRound(temp1)));
  step1[26] := LongInt((DctRound(temp2)));
  step1[22] := LongInt(step2[22]);
  step1[23] := LongInt(step2[23]);
  step1[24] := LongInt(step2[24]);
  step1[25] := LongInt(step2[25]);
  step1[30] := LongInt(step2[30]);
  step1[31] := LongInt(step2[31]);
  step2[0] := LongInt((step1[0] + step1[7]));
  step2[1] := LongInt((step1[1] + step1[6]));
  step2[2] := LongInt((step1[2] + step1[5]));
  step2[3] := LongInt((step1[3] + step1[4]));
  step2[4] := LongInt((step1[3] - step1[4]));
  step2[5] := LongInt((step1[2] - step1[5]));
  step2[6] := LongInt((step1[1] - step1[6]));
  step2[7] := LongInt((step1[0] - step1[7]));
  step2[8] := LongInt(step1[8]);
  step2[9] := LongInt(step1[9]);
  temp1 := (-step1[10] + step1[13]) * cospi_16_64;
  temp2 := (step1[10] + step1[13]) * cospi_16_64;
  step2[10] := LongInt((DctRound(temp1)));
  step2[13] := LongInt((DctRound(temp2)));
  temp1 := (-step1[11] + step1[12]) * cospi_16_64;
  temp2 := (step1[11] + step1[12]) * cospi_16_64;
  step2[11] := LongInt((DctRound(temp1)));
  step2[12] := LongInt((DctRound(temp2)));
  step2[14] := LongInt(step1[14]);
  step2[15] := LongInt(step1[15]);
  step2[16] := LongInt((step1[16] + step1[23]));
  step2[17] := LongInt((step1[17] + step1[22]));
  step2[18] := LongInt((step1[18] + step1[21]));
  step2[19] := LongInt((step1[19] + step1[20]));
  step2[20] := LongInt((step1[19] - step1[20]));
  step2[21] := LongInt((step1[18] - step1[21]));
  step2[22] := LongInt((step1[17] - step1[22]));
  step2[23] := LongInt((step1[16] - step1[23]));
  step2[24] := LongInt((-step1[24] + step1[31]));
  step2[25] := LongInt((-step1[25] + step1[30]));
  step2[26] := LongInt((-step1[26] + step1[29]));
  step2[27] := LongInt((-step1[27] + step1[28]));
  step2[28] := LongInt((step1[27] + step1[28]));
  step2[29] := LongInt((step1[26] + step1[29]));
  step2[30] := LongInt((step1[25] + step1[30]));
  step2[31] := LongInt((step1[24] + step1[31]));
  step1[0] := LongInt((step2[0] + step2[15]));
  step1[1] := LongInt((step2[1] + step2[14]));
  step1[2] := LongInt((step2[2] + step2[13]));
  step1[3] := LongInt((step2[3] + step2[12]));
  step1[4] := LongInt((step2[4] + step2[11]));
  step1[5] := LongInt((step2[5] + step2[10]));
  step1[6] := LongInt((step2[6] + step2[9]));
  step1[7] := LongInt((step2[7] + step2[8]));
  step1[8] := LongInt((step2[7] - step2[8]));
  step1[9] := LongInt((step2[6] - step2[9]));
  step1[10] := LongInt((step2[5] - step2[10]));
  step1[11] := LongInt((step2[4] - step2[11]));
  step1[12] := LongInt((step2[3] - step2[12]));
  step1[13] := LongInt((step2[2] - step2[13]));
  step1[14] := LongInt((step2[1] - step2[14]));
  step1[15] := LongInt((step2[0] - step2[15]));
  step1[16] := LongInt(step2[16]);
  step1[17] := LongInt(step2[17]);
  step1[18] := LongInt(step2[18]);
  step1[19] := LongInt(step2[19]);
  temp1 := (-step2[20] + step2[27]) * cospi_16_64;
  temp2 := (step2[20] + step2[27]) * cospi_16_64;
  step1[20] := LongInt((DctRound(temp1)));
  step1[27] := LongInt((DctRound(temp2)));
  temp1 := (-step2[21] + step2[26]) * cospi_16_64;
  temp2 := (step2[21] + step2[26]) * cospi_16_64;
  step1[21] := LongInt((DctRound(temp1)));
  step1[26] := LongInt((DctRound(temp2)));
  temp1 := (-step2[22] + step2[25]) * cospi_16_64;
  temp2 := (step2[22] + step2[25]) * cospi_16_64;
  step1[22] := LongInt((DctRound(temp1)));
  step1[25] := LongInt((DctRound(temp2)));
  temp1 := (-step2[23] + step2[24]) * cospi_16_64;
  temp2 := (step2[23] + step2[24]) * cospi_16_64;
  step1[23] := LongInt((DctRound(temp1)));
  step1[24] := LongInt((DctRound(temp2)));
  step1[28] := LongInt(step2[28]);
  step1[29] := LongInt(step2[29]);
  step1[30] := LongInt(step2[30]);
  step1[31] := LongInt(step2[31]);
  Output[0] := LongInt((step1[0] + step1[31]));
  Output[1] := LongInt((step1[1] + step1[30]));
  Output[2] := LongInt((step1[2] + step1[29]));
  Output[3] := LongInt((step1[3] + step1[28]));
  Output[4] := LongInt((step1[4] + step1[27]));
  Output[5] := LongInt((step1[5] + step1[26]));
  Output[6] := LongInt((step1[6] + step1[25]));
  Output[7] := LongInt((step1[7] + step1[24]));
  Output[8] := LongInt((step1[8] + step1[23]));
  Output[9] := LongInt((step1[9] + step1[22]));
  Output[10] := LongInt((step1[10] + step1[21]));
  Output[11] := LongInt((step1[11] + step1[20]));
  Output[12] := LongInt((step1[12] + step1[19]));
  Output[13] := LongInt((step1[13] + step1[18]));
  Output[14] := LongInt((step1[14] + step1[17]));
  Output[15] := LongInt((step1[15] + step1[16]));
  Output[16] := LongInt((step1[15] - step1[16]));
  Output[17] := LongInt((step1[14] - step1[17]));
  Output[18] := LongInt((step1[13] - step1[18]));
  Output[19] := LongInt((step1[12] - step1[19]));
  Output[20] := LongInt((step1[11] - step1[20]));
  Output[21] := LongInt((step1[10] - step1[21]));
  Output[22] := LongInt((step1[9] - step1[22]));
  Output[23] := LongInt((step1[8] - step1[23]));
  Output[24] := LongInt((step1[7] - step1[24]));
  Output[25] := LongInt((step1[6] - step1[25]));
  Output[26] := LongInt((step1[5] - step1[26]));
  Output[27] := LongInt((step1[4] - step1[27]));
  Output[28] := LongInt((step1[3] - step1[28]));
  Output[29] := LongInt((step1[2] - step1[29]));
  Output[30] := LongInt((step1[1] - step1[30]));
  Output[31] := LongInt((step1[0] - step1[31]));
end;


function ClampSample(Value, Maximum: LongInt): Word; inline;
begin
  if Value < 0 then
    Result := 0
  else if Value > Maximum then
    Result := Maximum
  else
    Result := Value;
end;

procedure AddWalshHadamard(Input: PLongInt; Target: PWord; Stride, Maximum: LongInt);
var
  Output: array[0..15] of LongInt;
  Index: LongInt;
  A1, B1, C1, D1, E1: Int64;
  P: PLongInt;
begin
  for Index := 0 to 3 do
  begin
    P := Input + Index * 4;
    A1 := SarLongint(P[0], 2);
    C1 := SarLongint(P[1], 2);
    D1 := SarLongint(P[2], 2);
    B1 := SarLongint(P[3], 2);
    A1 := A1 + C1;
    D1 := D1 - B1;
    E1 := SarInt64(A1 - D1, 1);
    B1 := E1 - B1;
    C1 := E1 - C1;
    A1 := A1 - B1;
    D1 := D1 + C1;
    Output[Index * 4] := LongInt(A1);
    Output[Index * 4 + 1] := LongInt(B1);
    Output[Index * 4 + 2] := LongInt(C1);
    Output[Index * 4 + 3] := LongInt(D1);
  end;
  for Index := 0 to 3 do
  begin
    A1 := Output[Index];
    C1 := Output[4 + Index];
    D1 := Output[8 + Index];
    B1 := Output[12 + Index];
    A1 := A1 + C1;
    D1 := D1 - B1;
    E1 := SarInt64(A1 - D1, 1);
    B1 := E1 - B1;
    C1 := E1 - C1;
    A1 := A1 - B1;
    D1 := D1 + C1;
    Target[Index] := ClampSample(Target[Index] + LongInt(A1), Maximum);
    Target[Stride + Index] := ClampSample(Target[Stride + Index] + LongInt(B1), Maximum);
    Target[2 * Stride + Index] := ClampSample(Target[2 * Stride + Index] + LongInt(C1), Maximum);
    Target[3 * Stride + Index] := ClampSample(Target[3 * Stride + Index] + LongInt(D1), Maximum);
  end;
end;

procedure AddInverseTransform(Coefficients: PLongInt; TransformSize, TransformType: LongInt;
  Lossless: Boolean; Target: PWord; Stride: LongInt; BitDepth: LongInt);
var
  Size, Shift, Row, Column, Index, Maximum: LongInt;
  Rows, Columns: TTransform1D;
  Intermediate: array[0..32 * 32 - 1] of LongInt;
  ColumnIn, ColumnOut: array[0..31] of LongInt;
  Input: PLongInt;
  AnyNonZero: Boolean;
begin
  Maximum := (1 shl BitDepth) - 1;
  if Lossless then
  begin
    AddWalshHadamard(Coefficients, Target, Stride, Maximum);
    Exit;
  end;
  Size := 4 shl TransformSize;
  case TransformSize of
    0:
      begin
        Shift := 4;
        if (TransformType = TypeDctAdst) or (TransformType = TypeAdstAdst) then
          Rows := @InverseAdst4
        else
          Rows := @InverseDct4;
        if (TransformType = TypeAdstDct) or (TransformType = TypeAdstAdst) then
          Columns := @InverseAdst4
        else
          Columns := @InverseDct4;
      end;
    1:
      begin
        Shift := 5;
        if (TransformType = TypeDctAdst) or (TransformType = TypeAdstAdst) then
          Rows := @InverseAdst8
        else
          Rows := @InverseDct8;
        if (TransformType = TypeAdstDct) or (TransformType = TypeAdstAdst) then
          Columns := @InverseAdst8
        else
          Columns := @InverseDct8;
      end;
    2:
      begin
        Shift := 6;
        if (TransformType = TypeDctAdst) or (TransformType = TypeAdstAdst) then
          Rows := @InverseAdst16
        else
          Rows := @InverseDct16;
        if (TransformType = TypeAdstDct) or (TransformType = TypeAdstAdst) then
          Columns := @InverseAdst16
        else
          Columns := @InverseDct16;
      end;
  else
    begin
      Shift := 6;
      Rows := @InverseDct32;
      Columns := @InverseDct32;
    end;
  end;
  for Row := 0 to Size - 1 do
  begin
    Input := Coefficients + Row * Size;
    AnyNonZero := False;
    for Index := 0 to Size - 1 do
      if Input[Index] <> 0 then
      begin
        AnyNonZero := True;
        Break;
      end;
    if AnyNonZero then
      Rows(Input, @Intermediate[Row * Size])
    else
      FillChar(Intermediate[Row * Size], Size * SizeOf(LongInt), 0);
  end;
  for Column := 0 to Size - 1 do
  begin
    for Index := 0 to Size - 1 do
      ColumnIn[Index] := Intermediate[Index * Size + Column];
    Columns(@ColumnIn[0], @ColumnOut[0]);
    for Index := 0 to Size - 1 do
      Target[Index * Stride + Column] := ClampSample(Target[Index * Stride + Column] +
        SarLongint(ColumnOut[Index] + (1 shl (Shift - 1)), Shift), Maximum);
  end;
end;

end.
