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
  Decoding one channel of one JPEG XL varblock's AC coefficients in one
  pass (ISO/IEC 18181-1 annex I.4.3): the number of non-zero
  coefficients, in a context from the counts predicted by the blocks
  above and to the left (kept per 8 x 8 block of the group), then the
  coefficients in the scan order until that many non-zeros were seen,
  each in a context from the non-zeros left, the position and whether
  the previous one was zero. Values are shifted by the pass's shift and
  added to what earlier passes gave.
}
unit Image.Jxl.VarDct.AcDecoding;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

uses
  SysUtils,
  Image.Errors,
  Image.Jxl.Entropy,
  Image.Jxl.VarDct.Strategies,
  Image.Jxl.VarDct.BlockContext;

type
  TJxlAcPassDecoder = record
    SymbolReader: TJxlSymbolReader;
    { Contexts the pass's entropy code has. }
    ContextCount: LongInt;
    { First context of the histogram set the group selected. }
    ContextOffset: LongInt;
    { The pass's coefficient orders. }
    Orders: PLongWord;
    Shift: LongInt;
  end;

{ Decodes channel Channel of a varblock of Strategy into Coefficients.
  NonZeros points at the block's non-zero count cell in the group's
  grid for this channel and pass (NonZeroStride cells a line), Column
  and Line are the block's position in that grid. }
procedure DecodeJxlVarBlock(var Decoder: TJxlAcPassDecoder; const Map: TJxlBlockContextMap;
  Strategy, Channel, LowFrequencyIndex: LongInt; QuantField: LongWord; NonZeros: PLongInt;
  NonZeroStride, Column, Line: LongInt; Coefficients: PLongInt);

implementation

procedure RaiseBadAc(const Detail: string);
begin
  RaiseImageError(ImageErrorMalformed, 'JPEG XL AC: ' + Detail);
end;

function ReadValue(var Decoder: TJxlAcPassDecoder; Context: LongInt): LongWord; inline;
begin
  if (Context < 0) or (Context >= Decoder.ContextCount) then
    RaiseBadAc('context out of range');
  Result := Decoder.SymbolReader.ReadUint(Context);
end;

procedure DecodeJxlVarBlock(var Decoder: TJxlAcPassDecoder; const Map: TJxlBlockContextMap;
  Strategy, Channel, LowFrequencyIndex: LongInt; QuantField: LongWord; NonZeros: PLongInt;
  NonZeroStride, Column, Line: LongInt; Coefficients: PLongInt);
var
  Log2Covered: LongInt;
  Covered: LongInt;
  Size: LongInt;
  Predicted: LongInt;
  Order: LongInt;
  ScanOrder: PLongWord;
  BlockContext: LongInt;
  Count: LongWord;
  X: LongInt;
  Y: LongInt;
  HistogramOffset: LongInt;
  Previous: LongWord;
  Index: LongInt;
  Value: LongWord;
  Coefficient: Int64;
  Stored: LongInt;
begin
  Log2Covered := JxlStrategyLog2Blocks[Strategy];
  Covered := 1 shl Log2Covered;
  Size := Covered * 64;
  if Column = 0 then
  begin
    if Line = 0 then
      Predicted := 32
    else
      Predicted := (NonZeros - NonZeroStride)^;
  end
  else if Line = 0 then
    Predicted := (NonZeros - 1)^
  else
    Predicted := ((NonZeros - NonZeroStride)^ + (NonZeros - 1)^ + 1) div 2;
  Order := JxlStrategyOrder[Strategy];
  ScanOrder := Decoder.Orders + JxlCoefficientOrderOffsets[3 * Order + Channel] * 64;
  BlockContext := JxlBlockContext(Map, LowFrequencyIndex, QuantField, Order, Channel);
  Count := ReadValue(Decoder, JxlNonZeroContext(Map, LongWord(Predicted), BlockContext) + Decoder.ContextOffset);
  if Count > LongWord(Size - Covered) then
    RaiseBadAc('too many non-zero coefficients');
  Stored := LongInt((Count + LongWord(Covered) - 1) shr Log2Covered);
  for Y := 0 to JxlStrategyBlocksY[Strategy] - 1 do
    for X := 0 to JxlStrategyBlocksX[Strategy] - 1 do
      NonZeros[X + Y * NonZeroStride] := Stored;
  HistogramOffset := Decoder.ContextOffset + JxlZeroDensityContextsOffset(Map, BlockContext);
  if Count > LongWord(Size div 16) then
    Previous := 0
  else
    Previous := 1;
  Index := Covered;
  while (Index < Size) and (Count <> 0) do
  begin
    Value := ReadValue(Decoder, HistogramOffset + JxlZeroDensityContext(Count, Index, Covered, Log2Covered, Previous));
    if (Value and 1) <> 0 then
      Coefficient := -Int64(Value shr 1) - 1
    else
      Coefficient := Value shr 1;
    Coefficient := Coefficient * (Int64(1) shl Decoder.Shift);
    Coefficients[ScanOrder[Index]] := LongInt((Coefficients[ScanOrder[Index]] + Coefficient) and $FFFFFFFF);
    if Value <> 0 then
      Previous := 1
    else
      Previous := 0;
    Dec(Count, Previous);
    Inc(Index);
  end;
  if Count <> 0 then
    RaiseBadAc('non-zero count not reached');
end;

end.
