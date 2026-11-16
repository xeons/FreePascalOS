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
  The contexts of JPEG XL's AC coefficients (ISO/IEC 18181-1 annex
  I.4): a block's context comes from its channel, its coefficient
  order, its quantization field value and the quantized LF of its
  block (thresholds on both), through a small context map; the default
  map clusters the large transforms together.

  Each block context has 37 contexts for the number of non-zero
  coefficients (from the number predicted from the blocks above and to
  the left) and 458 for the coefficients themselves (from how many
  non-zeros are left and the position in the scan).
}
unit Image.Jxl.VarDct.BlockContext;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Image.Errors,
  Image.Jxl.BitReader,
  Image.Jxl.Entropy,
  Image.Jxl.VarDct.Strategies;

const
  JxlNonZeroBuckets = 37;
  JxlZeroDensityContextCount = 458;

type
  TJxlBlockContextMap = record
    LowFrequencyThresholds: array[0..2] of array of LongInt;
    QuantFieldThresholds: array of LongWord;
    ContextMap: array of Byte;
    ContextCount: LongInt;
    LowFrequencyContextCount: LongInt;
  end;

function DefaultJxlBlockContextMap: TJxlBlockContextMap;
function ReadJxlBlockContextMap(Reader: TJxlBitReader): TJxlBlockContextMap;
{ The block context of a block (LowFrequencyIndex from the quantized LF
  thresholds, QuantField its quantization field value, Order its
  coefficient order, Channel 0, 1 or 2 as X, Y, B). }
function JxlBlockContext(const Map: TJxlBlockContextMap; LowFrequencyIndex: LongInt; QuantField: LongWord;
  Order, Channel: LongInt): LongInt;
function JxlNonZeroContext(const Map: TJxlBlockContextMap; NonZeros: LongWord; BlockContext: LongInt): LongInt;
function JxlZeroDensityContextsOffset(const Map: TJxlBlockContextMap; BlockContext: LongInt): LongInt;
function JxlAcContextCount(const Map: TJxlBlockContextMap): LongInt;
function JxlZeroDensityContext(NonZerosLeft, Index, CoveredBlocks, Log2CoveredBlocks, Previous: LongWord): LongInt;

implementation

const
  DefaultContextMap: array[0..3 * JxlOrderCount - 1] of Byte = (
    0, 1, 2, 2, 3, 3, 4, 5, 6, 6, 6, 6, 6,
    7, 8, 9, 9, 10, 11, 12, 13, 14, 14, 14, 14, 14,
    7, 8, 9, 9, 10, 11, 12, 13, 14, 14, 14, 14, 14);
  CoefficientFrequencyContext: array[0..63] of Word = (
    $BAD, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14,
    15, 15, 16, 16, 17, 17, 18, 18, 19, 19, 20, 20, 21, 21, 22, 22,
    23, 23, 23, 23, 24, 24, 24, 24, 25, 25, 25, 25, 26, 26, 26, 26,
    27, 27, 27, 27, 28, 28, 28, 28, 29, 29, 29, 29, 30, 30, 30, 30);
  CoefficientNonZeroContext: array[0..63] of Word = (
    $BAD, 0, 31, 62, 62, 93, 93, 93, 93, 123, 123, 123, 123,
    152, 152, 152, 152, 152, 152, 152, 152, 180, 180, 180, 180, 180,
    180, 180, 180, 180, 180, 180, 180, 206, 206, 206, 206, 206, 206,
    206, 206, 206, 206, 206, 206, 206, 206, 206, 206, 206, 206, 206,
    206, 206, 206, 206, 206, 206, 206, 206, 206, 206, 206, 206);

procedure RaiseBadBlockContext(const Detail: string);
begin
  RaiseImageError(ImageErrorMalformed, 'JPEG XL block context: ' + Detail);
end;

function DefaultJxlBlockContextMap: TJxlBlockContextMap;
var
  Index: LongInt;
begin
  Result := Default(TJxlBlockContextMap);
  SetLength(Result.ContextMap, Length(DefaultContextMap));
  for Index := 0 to High(DefaultContextMap) do
    Result.ContextMap[Index] := DefaultContextMap[Index];
  Result.ContextCount := 15;
  Result.LowFrequencyContextCount := 1;
end;

function ReadJxlBlockContextMap(Reader: TJxlBitReader): TJxlBlockContextMap;
var
  Channel: LongInt;
  Index: LongInt;
  Count: LongInt;
begin
  if Reader.ReadBool then
    Exit(DefaultJxlBlockContextMap);
  Result := Default(TJxlBlockContextMap);
  Result.LowFrequencyContextCount := 1;
  for Channel := 0 to 2 do
  begin
    Count := LongInt(Reader.ReadBits(4));
    SetLength(Result.LowFrequencyThresholds[Channel], Count);
    Result.LowFrequencyContextCount := Result.LowFrequencyContextCount * (Count + 1);
    for Index := 0 to Count - 1 do
      Result.LowFrequencyThresholds[Channel][Index] := JxlUnpackSigned(Reader.ReadU32(JxlBits(4),
        JxlBitsOffset(8, 16), JxlBitsOffset(16, 272), JxlBitsOffset(32, 65808)));
  end;
  Count := LongInt(Reader.ReadBits(4));
  SetLength(Result.QuantFieldThresholds, Count);
  for Index := 0 to Count - 1 do
    Result.QuantFieldThresholds[Index] := Reader.ReadU32(JxlBits(2), JxlBitsOffset(3, 4), JxlBitsOffset(5, 12),
      JxlBitsOffset(8, 44)) + 1;
  if Result.LowFrequencyContextCount * (Count + 1) > 64 then
    RaiseBadBlockContext('too big');
  SetLength(Result.ContextMap, 3 * JxlOrderCount * Result.LowFrequencyContextCount * (Count + 1));
  Result.ContextCount := ReadJxlContextMap(Reader, Result.ContextMap);
  if Result.ContextCount > 16 then
    RaiseBadBlockContext('too many contexts');
end;

function JxlBlockContext(const Map: TJxlBlockContextMap; LowFrequencyIndex: LongInt; QuantField: LongWord;
  Order, Channel: LongInt): LongInt;
var
  QuantFieldIndex: LongInt;
  Index: LongInt;
begin
  QuantFieldIndex := 0;
  for Index := 0 to High(Map.QuantFieldThresholds) do
    if QuantField > Map.QuantFieldThresholds[Index] then
      Inc(QuantFieldIndex);
  if Channel < 2 then
    Index := Channel xor 1
  else
    Index := 2;
  Index := Index * JxlOrderCount + Order;
  Index := Index * (Length(Map.QuantFieldThresholds) + 1) + QuantFieldIndex;
  Index := Index * Map.LowFrequencyContextCount + LowFrequencyIndex;
  Result := Map.ContextMap[Index];
end;

function JxlNonZeroContext(const Map: TJxlBlockContextMap; NonZeros: LongWord; BlockContext: LongInt): LongInt;
var
  Context: LongInt;
begin
  if NonZeros >= 64 then
    NonZeros := 64;
  if NonZeros < 8 then
    Context := NonZeros
  else
    Context := 4 + LongInt(NonZeros) div 2;
  Result := Context * Map.ContextCount + BlockContext;
end;

function JxlZeroDensityContextsOffset(const Map: TJxlBlockContextMap; BlockContext: LongInt): LongInt;
begin
  Result := Map.ContextCount * JxlNonZeroBuckets + JxlZeroDensityContextCount * BlockContext;
end;

function JxlAcContextCount(const Map: TJxlBlockContextMap): LongInt;
begin
  Result := Map.ContextCount * (JxlNonZeroBuckets + JxlZeroDensityContextCount);
end;

function JxlZeroDensityContext(NonZerosLeft, Index, CoveredBlocks, Log2CoveredBlocks, Previous: LongWord): LongInt;
begin
  NonZerosLeft := (NonZerosLeft + CoveredBlocks - 1) shr Log2CoveredBlocks;
  Index := Index shr Log2CoveredBlocks;
  if (NonZerosLeft > 63) or (Index > 63) then
    RaiseBadBlockContext('bad coefficient context');
  Result := (CoefficientNonZeroContext[NonZerosLeft] + CoefficientFrequencyContext[Index]) * 2 + LongInt(Previous);
end;

end.
