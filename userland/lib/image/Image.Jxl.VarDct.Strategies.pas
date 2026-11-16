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
  JPEG XL's 27 VarDCT transforms ("AC strategies", ISO/IEC 18181-1
  annex I.2): how many 8 x 8 blocks each covers horizontally and
  vertically (DCT16X8 is 16 tall and 8 wide), which of the 13
  coefficient orders and 17 quantization tables it uses, and its
  natural coefficient order.

  A varblock's coefficients are kept as a matrix of min(rows, columns)
  x max(rows, columns) values (8 times the blocks covered), the lowest
  frequencies (one per block covered) in its top left corner, as
  libjxl keeps them.
}
unit Image.Jxl.VarDct.Strategies;

{$mode objfpc}
{$H+}

interface

const
  JxlStrategyDct = 0;
  JxlStrategyIdentity = 1;
  JxlStrategyDct2x2 = 2;
  JxlStrategyDct4x4 = 3;
  JxlStrategyDct16x16 = 4;
  JxlStrategyDct32x32 = 5;
  JxlStrategyDct16x8 = 6;
  JxlStrategyDct8x16 = 7;
  JxlStrategyDct32x8 = 8;
  JxlStrategyDct8x32 = 9;
  JxlStrategyDct32x16 = 10;
  JxlStrategyDct16x32 = 11;
  JxlStrategyDct4x8 = 12;
  JxlStrategyDct8x4 = 13;
  JxlStrategyAfv0 = 14;
  JxlStrategyAfv1 = 15;
  JxlStrategyAfv2 = 16;
  JxlStrategyAfv3 = 17;
  JxlStrategyDct64x64 = 18;
  JxlStrategyDct64x32 = 19;
  JxlStrategyDct32x64 = 20;
  JxlStrategyDct128x128 = 21;
  JxlStrategyDct128x64 = 22;
  JxlStrategyDct64x128 = 23;
  JxlStrategyDct256x256 = 24;
  JxlStrategyDct256x128 = 25;
  JxlStrategyDct128x256 = 26;
  JxlStrategyCount = 27;

  JxlOrderCount = 13;
  JxlQuantTableCount = 17;

  JxlStrategyBlocksX: array[0..JxlStrategyCount - 1] of Byte = (
    1, 1, 1, 1, 2, 4, 1, 2, 1, 4, 2, 4, 1, 1, 1, 1, 1, 1, 8, 4, 8, 16, 8, 16, 32, 16, 32);
  JxlStrategyBlocksY: array[0..JxlStrategyCount - 1] of Byte = (
    1, 1, 1, 1, 2, 4, 2, 1, 4, 1, 4, 2, 1, 1, 1, 1, 1, 1, 8, 8, 4, 16, 16, 8, 32, 32, 16);
  JxlStrategyLog2Blocks: array[0..JxlStrategyCount - 1] of Byte = (
    0, 0, 0, 0, 2, 4, 1, 1, 2, 2, 3, 3, 0, 0, 0, 0, 0, 0, 6, 5, 5, 8, 7, 7, 10, 9, 9);
  JxlStrategyOrder: array[0..JxlStrategyCount - 1] of Byte = (
    0, 1, 1, 1, 2, 3, 4, 4, 5, 5, 6, 6, 1, 1, 1, 1, 1, 1, 7, 8, 8, 9, 10, 10, 11, 12, 12);
  JxlStrategyQuantTable: array[0..JxlStrategyCount - 1] of Byte = (
    0, 1, 2, 3, 4, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 10, 10, 11, 12, 12, 13, 14, 14, 15, 16, 16);

  { Blocks covered by each quantization table (its weights are
    8 x RequiredX rows by 8 x RequiredY columns). }
  JxlQuantTableRequiredX: array[0..JxlQuantTableCount - 1] of Byte = (
    1, 1, 1, 1, 2, 4, 1, 1, 2, 1, 1, 8, 4, 16, 8, 32, 16);
  JxlQuantTableRequiredY: array[0..JxlQuantTableCount - 1] of Byte = (
    1, 1, 1, 1, 2, 4, 2, 4, 4, 1, 1, 8, 8, 16, 16, 32, 32);

  { Offsets (in 64-coefficient units) of each order's three channels in
    a pass's coefficient orders. }
  JxlCoefficientOrderOffsets: array[0..3 * JxlOrderCount] of LongInt = (
    0, 1, 2, 3, 4, 5, 6, 10, 14, 18,
    34, 50, 66, 68, 70, 72, 76, 80, 84, 92,
    100, 108, 172, 236, 300, 332, 364, 396, 652, 908,
    1164, 1292, 1420, 1548, 2572, 3596, 4620, 5132, 5644, 6156);

type
  TJxlCoefficientOrder = array of LongWord;

{ The natural coefficient order of Strategy (position in the varblock's
  coefficient matrix of each index). }
function JxlNaturalCoefficientOrder(Strategy: LongInt): TJxlCoefficientOrder;
{ True for the strategies that cover more than one block. }
function JxlStrategyIsMultiblock(Strategy: LongInt): Boolean;

implementation

function JxlStrategyIsMultiblock(Strategy: LongInt): Boolean;
begin
  Result := (JxlStrategyBlocksX[Strategy] > 1) or (JxlStrategyBlocksY[Strategy] > 1);
end;

function JxlNaturalCoefficientOrder(Strategy: LongInt): TJxlCoefficientOrder;
var
  BlocksX: LongInt;
  BlocksY: LongInt;
  Swap: LongInt;
  Stretch: LongInt;
  StretchMask: LongInt;
  StretchShift: LongInt;
  Current: LongInt;
  Diagonal: LongInt;
  Step: LongInt;
  X: LongInt;
  Y: LongInt;
  Value: LongInt;
  Size: LongInt;
begin
  BlocksX := JxlStrategyBlocksX[Strategy];
  BlocksY := JxlStrategyBlocksY[Strategy];
  if BlocksY > BlocksX then
  begin
    Swap := BlocksX;
    BlocksX := BlocksY;
    BlocksY := Swap;
  end;
  Stretch := BlocksX div BlocksY;
  StretchMask := Stretch - 1;
  StretchShift := 0;
  while (1 shl StretchShift) < Stretch do
    Inc(StretchShift);
  Size := BlocksX * BlocksY * 64;
  SetLength(Result, Size);
  Current := BlocksX * BlocksY;
  Size := BlocksX * 8;
  for Diagonal := 0 to Size - 1 do
    for Step := 0 to Diagonal do
    begin
      X := Step;
      Y := Diagonal - Step;
      if (Diagonal and 1) <> 0 then
      begin
        Swap := X;
        X := Y;
        Y := Swap;
      end;
      if (Y and StretchMask) <> 0 then
        Continue;
      Y := Y shr StretchShift;
      if (X < BlocksX) and (Y < BlocksY) then
        Value := Y * BlocksX + X
      else
      begin
        Value := Current;
        Inc(Current);
      end;
      Result[Value] := LongWord(Y * BlocksX * 8 + X);
    end;
  for Diagonal := Size - 2 downto 0 do
    for Step := 0 to Diagonal do
    begin
      X := Size - 1 - (Diagonal - Step);
      Y := Size - 1 - Step;
      if (Diagonal and 1) <> 0 then
      begin
        Swap := X;
        X := Y;
        Y := Swap;
      end;
      if (Y and StretchMask) <> 0 then
        Continue;
      Y := Y shr StretchShift;
      Value := Current;
      Inc(Current);
      Result[Value] := LongWord(Y * BlocksX * 8 + X);
    end;
end;

end.
