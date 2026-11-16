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
  Huffman codes for the compressor: code lengths from symbol
  frequencies, no longer than a limit, and the canonical codes for them.

  The lengths come from a Huffman tree built over the used symbols
  sorted by frequency (two queues: leaves in order, and the inner nodes,
  which are made in order). If the tree is deeper than the limit, the
  number of codes of each length is adjusted until it fits again (codes
  past the limit are moved to it; then, while the code is
  over-subscribed, a code at the limit is dropped and a shorter one
  split in two), and the lengths are dealt out again with the most
  frequent symbols getting the shortest codes.

  The codes are always complete: with fewer than two used symbols,
  unused ones are given one bit codes too, since decoders (zlib's and
  this library's) reject an incomplete code length code.
}
unit Compression.HuffmanEncoding;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

uses
  Compression.DeflateFormat;

{ Lengths (Count of them, at most LiteralLengthSymbols) for
  Frequencies, none longer than LengthLimit. }
procedure BuildCodeLengths(Frequencies: PLongWord; Count: Integer; LengthLimit: Integer; Lengths: PByte);
{ The canonical codes for Lengths, bit reversed, ready to be sent first
  bit first. }
procedure BuildCanonicalCodes(Lengths: PByte; Count: Integer; Codes: PWord);

implementation

const
  MaximumSymbols = LiteralLengthSymbols;
  MaximumNodes = 2 * MaximumSymbols;
  DeepestTree = MaximumSymbols;

type
  TSymbolList = array[0..MaximumSymbols - 1] of Integer;

{ Sorts the used symbols by rising frequency (ties by symbol). }
procedure SortByFrequency(Frequencies: PLongWord; var Symbols: TSymbolList; Count: Integer);
var
  Index: Integer;
  Position: Integer;
  Symbol: Integer;
begin
  for Index := 1 to Count - 1 do
  begin
    Symbol := Symbols[Index];
    Position := Index;
    while (Position > 0) and (Frequencies[Symbols[Position - 1]] > Frequencies[Symbol]) do
    begin
      Symbols[Position] := Symbols[Position - 1];
      Dec(Position);
    end;
    Symbols[Position] := Symbol;
  end;
end;

{ Depths of the leaves of a Huffman tree over the sorted symbols. The
  leaves are nodes 0..UsedCount-1, the inner nodes follow. }
procedure ComputeLeafDepths(Frequencies: PLongWord; const Symbols: TSymbolList; UsedCount: Integer;
  var Depths: array of Integer);
var
  Weights: array[0..MaximumNodes - 1] of QWord;
  Parents: array[0..MaximumNodes - 1] of Integer;
  NextLeaf: Integer;
  NextInner: Integer;
  InnerCount: Integer;
  Pick: Integer;
  Child: array[0..1] of Integer;
  Node: Integer;
  Root: Integer;
  NodeDepths: array[0..MaximumNodes - 1] of Integer;
begin
  for Node := 0 to UsedCount - 1 do
    Weights[Node] := Frequencies[Symbols[Node]];
  NextLeaf := 0;
  NextInner := UsedCount;
  InnerCount := UsedCount;
  while InnerCount < 2 * UsedCount - 1 do
  begin
    for Pick := 0 to 1 do
    begin
      if (NextLeaf < UsedCount) and ((NextInner >= InnerCount) or (Weights[NextLeaf] <= Weights[NextInner])) then
      begin
        Child[Pick] := NextLeaf;
        Inc(NextLeaf);
      end
      else
      begin
        Child[Pick] := NextInner;
        Inc(NextInner);
      end;
    end;
    Weights[InnerCount] := Weights[Child[0]] + Weights[Child[1]];
    Parents[Child[0]] := InnerCount;
    Parents[Child[1]] := InnerCount;
    Inc(InnerCount);
  end;
  Root := InnerCount - 1;
  NodeDepths[Root] := 0;
  for Node := Root - 1 downto 0 do
    NodeDepths[Node] := NodeDepths[Parents[Node]] + 1;
  for Node := 0 to UsedCount - 1 do
    Depths[Node] := NodeDepths[Node];
end;

{ Makes the counts of codes of each length fit LengthLimit. }
procedure LimitLengths(var LengthCounts: array of Integer; LongestLength: Integer; LengthLimit: Integer);
var
  CodeLength: Integer;
  Total: QWord;
begin
  for CodeLength := LengthLimit + 1 to LongestLength do
  begin
    Inc(LengthCounts[LengthLimit], LengthCounts[CodeLength]);
    LengthCounts[CodeLength] := 0;
  end;
  Total := 0;
  for CodeLength := 1 to LengthLimit do
    Inc(Total, QWord(LengthCounts[CodeLength]) shl (LengthLimit - CodeLength));
  while Total > (QWord(1) shl LengthLimit) do
  begin
    Dec(LengthCounts[LengthLimit]);
    for CodeLength := LengthLimit - 1 downto 1 do
      if LengthCounts[CodeLength] > 0 then
      begin
        Dec(LengthCounts[CodeLength]);
        Inc(LengthCounts[CodeLength + 1], 2);
        Break;
      end;
    Dec(Total);
  end;
end;

procedure BuildCodeLengths(Frequencies: PLongWord; Count: Integer; LengthLimit: Integer; Lengths: PByte);
var
  Symbols: TSymbolList;
  Depths: array[0..MaximumSymbols - 1] of Integer;
  LengthCounts: array[0..DeepestTree] of Integer;
  UsedCount: Integer;
  Symbol: Integer;
  Index: Integer;
  CodeLength: Integer;
  LongestLength: Integer;
  Position: Integer;
begin
  UsedCount := 0;
  for Symbol := 0 to Count - 1 do
  begin
    Lengths[Symbol] := 0;
    if Frequencies[Symbol] > 0 then
    begin
      Symbols[UsedCount] := Symbol;
      Inc(UsedCount);
    end;
  end;

  if UsedCount < 2 then
  begin
    { One bit codes for the used symbol, if any, and the first unused
      ones, two in all. }
    Position := 0;
    Symbol := 0;
    if UsedCount = 1 then
    begin
      Lengths[Symbols[0]] := 1;
      Position := 1;
    end;
    while (Position < 2) and (Symbol < Count) do
    begin
      if Lengths[Symbol] = 0 then
      begin
        Lengths[Symbol] := 1;
        Inc(Position);
      end;
      Inc(Symbol);
    end;
    Exit;
  end;

  SortByFrequency(Frequencies, Symbols, UsedCount);
  ComputeLeafDepths(Frequencies, Symbols, UsedCount, Depths);

  for CodeLength := 0 to DeepestTree do
    LengthCounts[CodeLength] := 0;
  LongestLength := 0;
  for Index := 0 to UsedCount - 1 do
  begin
    Inc(LengthCounts[Depths[Index]]);
    if Depths[Index] > LongestLength then
      LongestLength := Depths[Index];
  end;
  if LongestLength > LengthLimit then
    LimitLengths(LengthCounts, LongestLength, LengthLimit);

  { The most frequent symbols (the end of the sorted list) get the
    shortest codes. }
  Index := UsedCount - 1;
  for CodeLength := 1 to LengthLimit do
    for Position := 1 to LengthCounts[CodeLength] do
    begin
      Lengths[Symbols[Index]] := CodeLength;
      Dec(Index);
    end;
end;

procedure BuildCanonicalCodes(Lengths: PByte; Count: Integer; Codes: PWord);
var
  LengthCounts: array[0..MaximumCodeLength] of Integer;
  NextCode: array[0..MaximumCodeLength] of LongWord;
  Symbol: Integer;
  CodeLength: Integer;
  Code: LongWord;
  Reversed: LongWord;
  Bit: Integer;
begin
  for CodeLength := 0 to MaximumCodeLength do
    LengthCounts[CodeLength] := 0;
  for Symbol := 0 to Count - 1 do
    Inc(LengthCounts[Lengths[Symbol]]);
  LengthCounts[0] := 0;
  Code := 0;
  NextCode[0] := 0;
  for CodeLength := 1 to MaximumCodeLength do
  begin
    Code := (Code + LongWord(LengthCounts[CodeLength - 1])) shl 1;
    NextCode[CodeLength] := Code;
  end;
  for Symbol := 0 to Count - 1 do
  begin
    CodeLength := Lengths[Symbol];
    Codes[Symbol] := 0;
    if CodeLength = 0 then
      Continue;
    Code := NextCode[CodeLength];
    Inc(NextCode[CodeLength]);
    Reversed := 0;
    for Bit := 1 to CodeLength do
    begin
      Reversed := (Reversed shl 1) or (Code and 1);
      Code := Code shr 1;
    end;
    Codes[Symbol] := Reversed;
  end;
end;

end.
