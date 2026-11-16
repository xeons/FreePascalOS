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
  The coefficient orders of a JPEG XL pass (ISO/IEC 18181-1 annex
  I.3.2): each of the 13 orders is its strategy's natural order, or, if
  the pass says so, a permutation of it (Lehmer coded, the lowest
  frequencies left in place), per channel. Orders are kept only for the
  strategies the frame uses.
}
unit Image.Jxl.VarDct.CoefficientOrders;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Image.Errors,
  Image.Jxl.BitReader,
  Image.Jxl.Entropy,
  Image.Jxl.Permutation,
  Image.Jxl.VarDct.Strategies;

const
  JxlCoefficientOrderSize = 6156 * 64;

type
  TJxlPassCoefficientOrders = array of LongWord;

{ Reads one pass's orders. UsedStrategies has a bit per strategy the
  frame uses. }
function ReadJxlCoefficientOrders(Reader: TJxlBitReader; UsedStrategies: LongWord): TJxlPassCoefficientOrders;
{ Offset of order Order, channel Channel in a pass's orders. }
function JxlCoefficientOrderOffset(Order, Channel: LongInt): LongInt; inline;

implementation

function JxlCoefficientOrderOffset(Order, Channel: LongInt): LongInt;
begin
  Result := JxlCoefficientOrderOffsets[3 * Order + Channel] * 64;
end;

function ReadJxlCoefficientOrders(Reader: TJxlBitReader; UsedStrategies: LongWord): TJxlPassCoefficientOrders;
var
  UsedOrders: LongWord;
  Code: TJxlEntropyCode;
  SymbolReader: TJxlSymbolReader;
  OrderMask: LongWord;
  Computed: LongWord;
  Strategy: LongInt;
  Order: LongInt;
  Used: Boolean;
  Natural: TJxlCoefficientOrder;
  Size: LongInt;
  LowFrequencies: LongInt;
  Channel: LongInt;
  Permutation: TJxlPermutation;
  Offset: LongInt;
  Index: LongInt;
begin
  SetLength(Result, JxlCoefficientOrderSize);
  UsedOrders := Reader.ReadU32(JxlVal($5F), JxlVal($13), JxlVal(0), JxlBits(JxlOrderCount));
  Code := nil;
  SymbolReader := nil;
  try
    if UsedOrders <> 0 then
    begin
      Code := ReadJxlEntropyCode(Reader, JxlPermutationContexts);
      SymbolReader := TJxlSymbolReader.Create(Code, Reader);
    end;
    OrderMask := 0;
    for Strategy := 0 to JxlStrategyCount - 1 do
      if (UsedStrategies and (LongWord(1) shl Strategy)) <> 0 then
        OrderMask := OrderMask or (LongWord(1) shl JxlStrategyOrder[Strategy]);
    Computed := 0;
    for Strategy := 0 to JxlStrategyCount - 1 do
    begin
      Order := JxlStrategyOrder[Strategy];
      if (Computed and (LongWord(1) shl Order)) <> 0 then
        Continue;
      Computed := Computed or (LongWord(1) shl Order);
      Used := (OrderMask and (LongWord(1) shl Order)) <> 0;
      LowFrequencies := JxlStrategyBlocksX[Strategy] * JxlStrategyBlocksY[Strategy];
      Size := 64 * LowFrequencies;
      if (not Used) and ((UsedOrders and (LongWord(1) shl Order)) = 0) then
        Continue;
      Natural := JxlNaturalCoefficientOrder(Strategy);
      for Channel := 0 to 2 do
      begin
        Offset := JxlCoefficientOrderOffset(Order, Channel);
        if (UsedOrders and (LongWord(1) shl Order)) = 0 then
        begin
          for Index := 0 to Size - 1 do
            Result[Offset + Index] := Natural[Index];
        end
        else
        begin
          Permutation := ReadJxlPermutation(SymbolReader, Size, LowFrequencies);
          if Used then
            for Index := 0 to Size - 1 do
              Result[Offset + Index] := Natural[Permutation[Index]];
        end;
      end;
    end;
    if SymbolReader <> nil then
      SymbolReader.CheckFinalState;
  finally
    SymbolReader.Free;
    Code.Free;
  end;
end;

end.
