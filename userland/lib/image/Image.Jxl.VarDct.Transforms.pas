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
  The inverse transforms of JPEG XL's VarDCT (ISO/IEC 18181-1 annex
  I.2.5 to I.2.8), as libjxl computes them: scaled DCTs of 4 to 256
  points (a recursive butterfly on all columns at once, rows and
  columns joined by transposes in libjxl's order, which decides how a
  varblock's coefficient matrix is oriented), the 2x2 and 4x4 DCTs,
  DCT4x8 and DCT8x4, the identity ("Hornuss") transform and AFV (a 4 x
  4 corner with its own basis, a 4 x 4 DCT and a 4 x 8 DCT).

  The lowest frequencies of a large varblock come from the LF image: a
  forward DCT of the varblock's LF samples, rescaled.
}
unit Image.Jxl.VarDct.Transforms;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

uses
  SysUtils,
  Image.Jxl.VarDct.Strategies;

const
  { Floats of scratch space TransformToPixels and LowestFrequenciesFromDc
    need at most. }
  JxlTransformScratchSize = 256 * 256 * 4;

{ The pixels of one varblock (written at Pixels with PixelStride between
  lines) from its dequantized Coefficients (overwritten). }
procedure JxlTransformToPixels(Strategy: LongInt; Coefficients: PSingle; Pixels: PSingle; PixelStride: LongInt;
  Scratch: PSingle);
{ Fills the lowest frequencies of a varblock's coefficients from its LF
  samples (at LowFrequency, LowFrequencyStride between lines). }
procedure JxlLowestFrequenciesFromDc(Strategy: LongInt; LowFrequency: PSingle; LowFrequencyStride: LongInt;
  Coefficients: PSingle; Scratch: PSingle);

implementation

uses
  Image.Jxl.VarDct.Tables;

const
  Sqrt2 = 1.41421356237;

function WcMultiplier(N, Index: LongInt): Single;
begin
  case N of
    4: Result := JxlWcMultipliers4[Index];
    8: Result := JxlWcMultipliers8[Index];
    16: Result := JxlWcMultipliers16[Index];
    32: Result := JxlWcMultipliers32[Index];
    64: Result := JxlWcMultipliers64[Index];
    128: Result := JxlWcMultipliers128[Index];
  else
    Result := JxlWcMultipliers256[Index];
  end;
end;

function ResampleScale(Count, Index: LongInt): Single;
begin
  case Count of
    1: Result := JxlResampleScales1To8[Index];
    2: Result := JxlResampleScales2To16[Index];
    4: Result := JxlResampleScales4To32[Index];
    8: Result := JxlResampleScales8To64[Index];
    16: Result := JxlResampleScales16To128[Index];
  else
    Result := JxlResampleScales32To256[Index];
  end;
end;

{ To[m][n] := From[n][m] for a Rows x Columns From. }
procedure Transpose(Rows, Columns: LongInt; From: PSingle; FromStride: LongInt; ToBlock: PSingle; ToStride: LongInt);
var
  Row: LongInt;
  Column: LongInt;
begin
  for Row := 0 to Rows - 1 do
    for Column := 0 to Columns - 1 do
      ToBlock[Column * ToStride + Row] := From[Row * FromStride + Column];
end;

{ An N point inverse DCT down each of Lanes columns: row i of the input
  at From + i * FromStride, of the output at Output + i * OutputStride. }
procedure InverseDct1D(N, Lanes: LongInt; From: PSingle; FromStride: LongInt; Output: PSingle; OutputStride: LongInt;
  Scratch: PSingle);
var
  Half: LongInt;
  Row: LongInt;
  Lane: LongInt;
  Source: PSingle;
  Target: PSingle;
  Low: PSingle;
  High: PSingle;
  Multiplier: Single;
  First: Single;
  Second: Single;
begin
  if N = 1 then
  begin
    Move(From^, Output^, SizeOf(Single) * Lanes);
    Exit;
  end;
  if N = 2 then
  begin
    for Lane := 0 to Lanes - 1 do
    begin
      First := From[Lane];
      Second := From[FromStride + Lane];
      Output[Lane] := First + Second;
      Output[OutputStride + Lane] := First - Second;
    end;
    Exit;
  end;
  Half := N div 2;
  for Row := 0 to Half - 1 do
  begin
    Move((From + 2 * Row * FromStride)^, (Scratch + Row * Lanes)^, SizeOf(Single) * Lanes);
    Move((From + (2 * Row + 1) * FromStride)^, (Scratch + (Half + Row) * Lanes)^, SizeOf(Single) * Lanes);
  end;
  InverseDct1D(Half, Lanes, Scratch, Lanes, Scratch, Lanes, Scratch + N * Lanes);
  { The transposed B step on the odd half. }
  for Row := Half - 1 downto 1 do
  begin
    Target := Scratch + (Half + Row) * Lanes;
    Source := Scratch + (Half + Row - 1) * Lanes;
    for Lane := 0 to Lanes - 1 do
      Target[Lane] := Target[Lane] + Source[Lane];
  end;
  Target := Scratch + Half * Lanes;
  for Lane := 0 to Lanes - 1 do
    Target[Lane] := Target[Lane] * Sqrt2;
  InverseDct1D(Half, Lanes, Scratch + Half * Lanes, Lanes, Scratch + Half * Lanes, Lanes, Scratch + N * Lanes);
  for Row := 0 to Half - 1 do
  begin
    Multiplier := WcMultiplier(N, Row);
    Low := Scratch + Row * Lanes;
    High := Scratch + (Half + Row) * Lanes;
    Source := Output + Row * OutputStride;
    Target := Output + (N - Row - 1) * OutputStride;
    for Lane := 0 to Lanes - 1 do
    begin
      First := Low[Lane];
      Second := High[Lane] * Multiplier;
      Source[Lane] := First + Second;
      Target[Lane] := First - Second;
    end;
  end;
end;

{ The forward butterfly (unscaled) on N rows of Lanes values, in place. }
procedure ForwardDct1DInPlace(N, Lanes: LongInt; Memory: PSingle; Scratch: PSingle);
var
  Half: LongInt;
  Row: LongInt;
  Lane: LongInt;
  First: PSingle;
  Second: PSingle;
  Target: PSingle;
  Multiplier: Single;
  A: Single;
  B: Single;
begin
  if N = 1 then
    Exit;
  if N = 2 then
  begin
    for Lane := 0 to Lanes - 1 do
    begin
      A := Memory[Lane];
      B := Memory[Lanes + Lane];
      Memory[Lane] := A + B;
      Memory[Lanes + Lane] := A - B;
    end;
    Exit;
  end;
  Half := N div 2;
  for Row := 0 to Half - 1 do
  begin
    First := Memory + Row * Lanes;
    Second := Memory + (N - 1 - Row) * Lanes;
    Target := Scratch + Row * Lanes;
    for Lane := 0 to Lanes - 1 do
      Target[Lane] := First[Lane] + Second[Lane];
  end;
  ForwardDct1DInPlace(Half, Lanes, Scratch, Scratch + N * Lanes);
  for Row := 0 to Half - 1 do
  begin
    First := Memory + Row * Lanes;
    Second := Memory + (N - 1 - Row) * Lanes;
    Target := Scratch + (Half + Row) * Lanes;
    Multiplier := WcMultiplier(N, Row);
    for Lane := 0 to Lanes - 1 do
      Target[Lane] := (First[Lane] - Second[Lane]) * Multiplier;
  end;
  ForwardDct1DInPlace(Half, Lanes, Scratch + Half * Lanes, Scratch + N * Lanes);
  { The B step on the odd half. }
  Target := Scratch + Half * Lanes;
  for Lane := 0 to Lanes - 1 do
    Target[Lane] := Target[Lane] * Sqrt2 + Target[Lanes + Lane];
  for Row := 1 to Half - 2 do
  begin
    Target := Scratch + (Half + Row) * Lanes;
    for Lane := 0 to Lanes - 1 do
      Target[Lane] := Target[Lane] + Target[Lanes + Lane];
  end;
  for Row := 0 to Half - 1 do
  begin
    Move((Scratch + Row * Lanes)^, (Memory + 2 * Row * Lanes)^, SizeOf(Single) * Lanes);
    Move((Scratch + (Half + Row) * Lanes)^, (Memory + (2 * Row + 1) * Lanes)^, SizeOf(Single) * Lanes);
  end;
end;

{ An N point forward DCT (scaled by 1/N) down Lanes columns. }
procedure ForwardDct1D(N, Lanes: LongInt; From: PSingle; FromStride: LongInt; Output: PSingle; OutputStride: LongInt;
  Scratch: PSingle);
var
  Row: LongInt;
  Lane: LongInt;
  Scale: Single;
  Source: PSingle;
  Target: PSingle;
begin
  for Row := 0 to N - 1 do
    Move((From + Row * FromStride)^, (Scratch + Row * Lanes)^, SizeOf(Single) * Lanes);
  ForwardDct1DInPlace(N, Lanes, Scratch, Scratch + N * Lanes);
  Scale := 1.0 / N;
  for Row := 0 to N - 1 do
  begin
    Source := Scratch + Row * Lanes;
    Target := Output + Row * OutputStride;
    for Lane := 0 to Lanes - 1 do
      Target[Lane] := Source[Lane] * Scale;
  end;
end;

procedure ComputeScaledIdct(Rows, Columns: LongInt; From: PSingle; Output: PSingle; OutputStride: LongInt;
  Scratch: PSingle);
var
  Block: PSingle;
  Temporary: PSingle;
begin
  Block := Scratch;
  Temporary := Scratch + Rows * Columns;
  if Rows < Columns then
  begin
    Transpose(Rows, Columns, From, Columns, Block, Rows);
    InverseDct1D(Columns, Rows, Block, Rows, From, Rows, Temporary);
    Transpose(Columns, Rows, From, Rows, Block, Columns);
    InverseDct1D(Rows, Columns, Block, Columns, Output, OutputStride, Temporary);
  end
  else
  begin
    InverseDct1D(Columns, Rows, From, Rows, Block, Rows, Temporary);
    Transpose(Columns, Rows, Block, Rows, From, Columns);
    InverseDct1D(Rows, Columns, From, Columns, Output, OutputStride, Temporary);
  end;
end;

{ Output (Rows x Columns, or Columns x Rows when Rows >= Columns, as
  libjxl leaves it) from Rows x Columns samples at From. }
procedure ComputeScaledDct(Rows, Columns: LongInt; From: PSingle; FromStride: LongInt; Output: PSingle;
  Scratch: PSingle);
var
  Block: PSingle;
  Temporary: PSingle;
begin
  Block := Scratch;
  Temporary := Scratch + Rows * Columns;
  if Rows < Columns then
  begin
    ForwardDct1D(Rows, Columns, From, FromStride, Block, Columns, Temporary);
    Transpose(Rows, Columns, Block, Columns, Output, Rows);
    ForwardDct1D(Columns, Rows, Output, Rows, Block, Rows, Temporary);
    Transpose(Columns, Rows, Block, Rows, Output, Columns);
  end
  else
  begin
    ForwardDct1D(Rows, Columns, From, FromStride, Output, Columns, Temporary);
    Transpose(Rows, Columns, Output, Columns, Block, Rows);
    ForwardDct1D(Columns, Rows, Block, Rows, Output, Rows, Temporary);
  end;
end;

procedure Idct2TopBlock(Size: LongInt; Block: PSingle);
var
  Temporary: array[0..63] of Single;
  Count: LongInt;
  X: LongInt;
  Y: LongInt;
  C00: Single;
  C01: Single;
  C10: Single;
  C11: Single;
begin
  Count := Size div 2;
  for Y := 0 to Count - 1 do
    for X := 0 to Count - 1 do
    begin
      C00 := Block[Y * 8 + X];
      C01 := Block[Y * 8 + Count + X];
      C10 := Block[(Y + Count) * 8 + X];
      C11 := Block[(Y + Count) * 8 + Count + X];
      Temporary[Y * 2 * 8 + X * 2] := C00 + C01 + C10 + C11;
      Temporary[Y * 2 * 8 + X * 2 + 1] := C00 + C01 - C10 - C11;
      Temporary[(Y * 2 + 1) * 8 + X * 2] := C00 - C01 + C10 - C11;
      Temporary[(Y * 2 + 1) * 8 + X * 2 + 1] := C00 - C01 - C10 + C11;
    end;
  for Y := 0 to Size - 1 do
    for X := 0 to Size - 1 do
      Block[Y * 8 + X] := Temporary[Y * 8 + X];
end;

procedure AfvIdct4x4(Coefficients: PSingle; Pixels: PSingle);
var
  Index: LongInt;
  Basis: LongInt;
  Sum: Single;
begin
  for Index := 0 to 15 do
  begin
    Sum := 0;
    for Basis := 0 to 15 do
      Sum := Sum + Coefficients[Basis] * JxlAfvBasis[Basis, Index];
    Pixels[Index] := Sum;
  end;
end;

procedure AfvToPixels(Kind: LongInt; Coefficients: PSingle; Pixels: PSingle; PixelStride: LongInt; Scratch: PSingle);
var
  AfvX: LongInt;
  AfvY: LongInt;
  Dcs: array[0..2] of Single;
  Corner: array[0..15] of Single;
  Block: array[0..31] of Single;
  X: LongInt;
  Y: LongInt;
  SourceX: LongInt;
  SourceY: LongInt;
begin
  AfvX := Kind and 1;
  AfvY := Kind div 2;
  Dcs[0] := (Coefficients[0] + Coefficients[8] + Coefficients[1]) * 4.0;
  Dcs[1] := Coefficients[0] + Coefficients[8] - Coefficients[1];
  Dcs[2] := Coefficients[0] - Coefficients[8];
  Corner[0] := Dcs[0];
  for Y := 0 to 3 do
    for X := 0 to 3 do
      if (X <> 0) or (Y <> 0) then
        Corner[Y * 4 + X] := Coefficients[Y * 2 * 8 + X * 2];
  AfvIdct4x4(@Corner[0], @Block[0]);
  for Y := 0 to 3 do
    for X := 0 to 3 do
    begin
      if AfvY = 1 then
        SourceY := 3 - Y
      else
        SourceY := Y;
      if AfvX = 1 then
        SourceX := 3 - X
      else
        SourceX := X;
      Pixels[(Y + AfvY * 4) * PixelStride + AfvX * 4 + X] := Block[SourceY * 4 + SourceX];
    end;
  Block[0] := Dcs[1];
  for Y := 0 to 3 do
    for X := 0 to 3 do
      if (X <> 0) or (Y <> 0) then
        Block[Y * 4 + X] := Coefficients[Y * 2 * 8 + X * 2 + 1];
  if AfvX = 1 then
    ComputeScaledIdct(4, 4, @Block[0], Pixels + AfvY * 4 * PixelStride, PixelStride, Scratch)
  else
    ComputeScaledIdct(4, 4, @Block[0], Pixels + AfvY * 4 * PixelStride + 4, PixelStride, Scratch);
  Block[0] := Dcs[2];
  for Y := 0 to 3 do
    for X := 0 to 7 do
      if (X <> 0) or (Y <> 0) then
        Block[Y * 8 + X] := Coefficients[(1 + Y * 2) * 8 + X];
  if AfvY = 1 then
    ComputeScaledIdct(4, 8, @Block[0], Pixels, PixelStride, Scratch)
  else
    ComputeScaledIdct(4, 8, @Block[0], Pixels + 4 * PixelStride, PixelStride, Scratch);
end;

procedure IdentityToPixels(Coefficients: PSingle; Pixels: PSingle; PixelStride: LongInt);
var
  Dcs: array[0..3] of Single;
  X: LongInt;
  Y: LongInt;
  InnerX: LongInt;
  InnerY: LongInt;
  ResidualSum: Single;
  Center: Single;
begin
  Dcs[0] := Coefficients[0] + Coefficients[1] + Coefficients[8] + Coefficients[9];
  Dcs[1] := Coefficients[0] + Coefficients[1] - Coefficients[8] - Coefficients[9];
  Dcs[2] := Coefficients[0] - Coefficients[1] + Coefficients[8] - Coefficients[9];
  Dcs[3] := Coefficients[0] - Coefficients[1] - Coefficients[8] + Coefficients[9];
  for Y := 0 to 1 do
    for X := 0 to 1 do
    begin
      ResidualSum := 0;
      for InnerY := 0 to 3 do
        for InnerX := 0 to 3 do
          if (InnerX <> 0) or (InnerY <> 0) then
            ResidualSum := ResidualSum + Coefficients[(Y + InnerY * 2) * 8 + X + InnerX * 2];
      Center := Dcs[Y * 2 + X] - ResidualSum * (1.0 / 16);
      Pixels[(4 * Y + 1) * PixelStride + 4 * X + 1] := Center;
      for InnerY := 0 to 3 do
        for InnerX := 0 to 3 do
          if (InnerX <> 1) or (InnerY <> 1) then
            Pixels[(Y * 4 + InnerY) * PixelStride + X * 4 + InnerX] :=
              Coefficients[(Y + InnerY * 2) * 8 + X + InnerX * 2] + Center;
      Pixels[Y * 4 * PixelStride + X * 4] := Coefficients[(Y + 2) * 8 + X + 2] + Center;
    end;
end;

procedure SplitToPixels(Strategy: LongInt; Coefficients: PSingle; Pixels: PSingle; PixelStride: LongInt;
  Scratch: PSingle);
var
  Dcs: array[0..3] of Single;
  Block: array[0..31] of Single;
  Part: LongInt;
  X: LongInt;
  Y: LongInt;
  PartX: LongInt;
  PartY: LongInt;
begin
  case Strategy of
    JxlStrategyDct8x4, JxlStrategyDct4x8:
      begin
        Dcs[0] := Coefficients[0] + Coefficients[8];
        Dcs[1] := Coefficients[0] - Coefficients[8];
        for Part := 0 to 1 do
        begin
          Block[0] := Dcs[Part];
          for Y := 0 to 3 do
            for X := 0 to 7 do
              if (X <> 0) or (Y <> 0) then
                Block[Y * 8 + X] := Coefficients[(Part + Y * 2) * 8 + X];
          if Strategy = JxlStrategyDct8x4 then
            ComputeScaledIdct(8, 4, @Block[0], Pixels + Part * 4, PixelStride, Scratch)
          else
            ComputeScaledIdct(4, 8, @Block[0], Pixels + Part * 4 * PixelStride, PixelStride, Scratch);
        end;
      end;
  else
    begin
      Dcs[0] := Coefficients[0] + Coefficients[1] + Coefficients[8] + Coefficients[9];
      Dcs[1] := Coefficients[0] + Coefficients[1] - Coefficients[8] - Coefficients[9];
      Dcs[2] := Coefficients[0] - Coefficients[1] + Coefficients[8] - Coefficients[9];
      Dcs[3] := Coefficients[0] - Coefficients[1] - Coefficients[8] + Coefficients[9];
      for PartY := 0 to 1 do
        for PartX := 0 to 1 do
        begin
          Block[0] := Dcs[PartY * 2 + PartX];
          for Y := 0 to 3 do
            for X := 0 to 3 do
              if (X <> 0) or (Y <> 0) then
                Block[Y * 4 + X] := Coefficients[(PartY + Y * 2) * 8 + PartX + X * 2];
          ComputeScaledIdct(4, 4, @Block[0], Pixels + PartY * 4 * PixelStride + PartX * 4, PixelStride, Scratch);
        end;
    end;
  end;
end;

procedure JxlTransformToPixels(Strategy: LongInt; Coefficients: PSingle; Pixels: PSingle; PixelStride: LongInt;
  Scratch: PSingle);
var
  X: LongInt;
  Y: LongInt;
begin
  case Strategy of
    JxlStrategyIdentity:
      IdentityToPixels(Coefficients, Pixels, PixelStride);
    JxlStrategyDct8x4, JxlStrategyDct4x8, JxlStrategyDct4x4:
      SplitToPixels(Strategy, Coefficients, Pixels, PixelStride, Scratch);
    JxlStrategyDct2x2:
      begin
        Idct2TopBlock(2, Coefficients);
        Idct2TopBlock(4, Coefficients);
        Idct2TopBlock(8, Coefficients);
        for Y := 0 to 7 do
          for X := 0 to 7 do
            Pixels[Y * PixelStride + X] := Coefficients[Y * 8 + X];
      end;
    JxlStrategyAfv0, JxlStrategyAfv1, JxlStrategyAfv2, JxlStrategyAfv3:
      AfvToPixels(Strategy - JxlStrategyAfv0, Coefficients, Pixels, PixelStride, Scratch);
  else
    ComputeScaledIdct(8 * JxlStrategyBlocksY[Strategy], 8 * JxlStrategyBlocksX[Strategy], Coefficients, Pixels,
      PixelStride, Scratch);
  end;
end;

procedure JxlLowestFrequenciesFromDc(Strategy: LongInt; LowFrequency: PSingle; LowFrequencyStride: LongInt;
  Coefficients: PSingle; Scratch: PSingle);
var
  Rows: LongInt;
  Columns: LongInt;
  OutputStride: LongInt;
  Block: PSingle;
  X: LongInt;
  Y: LongInt;
begin
  Rows := JxlStrategyBlocksY[Strategy];
  Columns := JxlStrategyBlocksX[Strategy];
  if (not JxlStrategyIsMultiblock(Strategy)) then
  begin
    Coefficients[0] := LowFrequency[0];
    Exit;
  end;
  if Rows > Columns then
    OutputStride := 8 * Rows
  else
    OutputStride := 8 * Columns;
  Block := Scratch;
  ComputeScaledDct(Rows, Columns, LowFrequency, LowFrequencyStride, Block, Scratch + Rows * Columns);
  if Rows < Columns then
  begin
    for Y := 0 to Rows - 1 do
      for X := 0 to Columns - 1 do
        Coefficients[Y * OutputStride + X] := Block[Y * Columns + X] * ResampleScale(Rows, Y) *
          ResampleScale(Columns, X);
  end
  else
  begin
    for Y := 0 to Columns - 1 do
      for X := 0 to Rows - 1 do
        Coefficients[Y * OutputStride + X] := Block[Y * Rows + X] * ResampleScale(Columns, Y) *
          ResampleScale(Rows, X);
  end;
end;

end.
