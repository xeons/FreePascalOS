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
  JPEG XL's permutations (of the table of contents' sections, and of
  coefficient orders): a Lehmer code entropy coded in 8 contexts, each
  entry's context following from the previous entry. Entry i picks the
  code-th of the elements not taken yet, found with an implicit order
  statistics tree as libjxl does, so long permutations stay fast.
}
unit Image.Jxl.Permutation;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Image.Errors,
  Image.Jxl.BitReader,
  Image.Jxl.Entropy;

const
  JxlPermutationContexts = 8;

type
  TJxlPermutation = array of LongWord;

{ Reads a permutation of Size elements whose first Skip stay in place,
  from an entropy coded stream whose contexts are 0 to 7. }
function ReadJxlPermutation(SymbolReader: TJxlSymbolReader; Size, Skip: LongWord): TJxlPermutation;
{ Reads the histograms of a permutation's own stream, then the
  permutation. }
function DecodeJxlPermutation(Reader: TJxlBitReader; Size, Skip: LongWord): TJxlPermutation;

implementation

function PermutationContext(Value: LongWord): LongInt;
var
  Log: LongInt;
begin
  if Value = 0 then
    Exit(0);
  Log := 0;
  while (Value shr (Log + 1)) <> 0 do
    Inc(Log);
  Result := Log + 1;
  if Result > JxlPermutationContexts - 1 then
    Result := JxlPermutationContexts - 1;
end;

function LowestBit(Value: PtrUInt): PtrUInt;
begin
  Result := Value and (not Value + 1);
end;

function DecodeLehmerCode(const Code: array of LongWord; Size: LongWord): TJxlPermutation;
var
  Log2Size: LongInt;
  PaddedSize: PtrUInt;
  Counts: array of LongWord;
  Index: PtrUInt;
  Rank: LongWord;
  Bit: PtrUInt;
  Next: PtrUInt;
  Candidate: PtrUInt;
  Level: LongInt;
begin
  Result := nil;
  SetLength(Result, Size);
  if Size = 0 then
    Exit;
  Log2Size := 0;
  while (PtrUInt(1) shl Log2Size) < Size do
    Inc(Log2Size);
  PaddedSize := PtrUInt(1) shl Log2Size;
  SetLength(Counts, PaddedSize);
  for Index := 0 to PaddedSize - 1 do
    Counts[Index] := LongWord(LowestBit(Index + 1));
  for Index := 0 to Size - 1 do
  begin
    if QWord(Code[Index]) + Index >= Size then
      RaiseImageError(ImageErrorMalformed, 'JPEG XL: bad permutation');
    Rank := Code[Index] + 1;
    Bit := PaddedSize;
    Next := 0;
    for Level := 0 to Log2Size do
    begin
      Candidate := Next + Bit;
      Bit := Bit shr 1;
      if (Candidate <= PaddedSize) and (Counts[Candidate - 1] < Rank) then
      begin
        Next := Candidate;
        Dec(Rank, Counts[Candidate - 1]);
      end;
    end;
    Result[Index] := LongWord(Next);
    Inc(Next);
    while Next <= PaddedSize do
    begin
      Dec(Counts[Next - 1]);
      Inc(Next, LowestBit(Next));
    end;
  end;
end;

function ReadJxlPermutation(SymbolReader: TJxlSymbolReader; Size, Skip: LongWord): TJxlPermutation;
var
  Lehmer: array of LongWord;
  EndIndex: QWord;
  Last: LongWord;
  Index: LongWord;
begin
  SetLength(Lehmer, Size);
  EndIndex := QWord(SymbolReader.ReadUint(PermutationContext(Size))) + Skip;
  if EndIndex > Size then
    RaiseImageError(ImageErrorMalformed, 'JPEG XL: bad permutation size');
  Last := 0;
  Index := Skip;
  while Index < EndIndex do
  begin
    Lehmer[Index] := SymbolReader.ReadUint(PermutationContext(Last));
    Last := Lehmer[Index];
    if Lehmer[Index] >= Size - Index then
      RaiseImageError(ImageErrorMalformed, 'JPEG XL: bad Lehmer code');
    Inc(Index);
  end;
  Result := DecodeLehmerCode(Lehmer, Size);
end;

function DecodeJxlPermutation(Reader: TJxlBitReader; Size, Skip: LongWord): TJxlPermutation;
var
  Code: TJxlEntropyCode;
  SymbolReader: TJxlSymbolReader;
begin
  Code := ReadJxlEntropyCode(Reader, JxlPermutationContexts);
  try
    SymbolReader := TJxlSymbolReader.Create(Code, Reader);
    try
      Result := ReadJxlPermutation(SymbolReader, Size, Skip);
      SymbolReader.CheckFinalState;
    finally
      SymbolReader.Free;
    end;
  finally
    Code.Free;
  end;
end;

end.
