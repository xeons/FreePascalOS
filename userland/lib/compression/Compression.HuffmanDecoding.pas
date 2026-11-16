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
  Decoding tables for canonical Huffman codes (RFC 1951 section 3.2.2).

  A table is looked up with the next RootBits bits of the input (deflate
  sends codes first bit first, so the bits are in reverse code order). A
  root entry is one of:

    a symbol: its code is at most RootBits long; the entry says how many
      bits it took. Every index whose low bits are the code holds it.
    a link: the codes starting with these RootBits bits are longer; the
      entry says where their subtable starts and how many more bits
      index it. The subtable holds symbols (lengths counted from the end
      of the root bits) or invalid entries.
    invalid: no code starts with these bits.

  An invalid entry's length is the width of its table, so a decoder
  short of input knows it must read more before calling it an error.

  Codes are checked as zlib checks them: never over-subscribed; complete,
  except that a literal/length or distance code may be a single code of
  one bit, or have no codes at all.
}
unit Compression.HuffmanDecoding;

{$mode objfpc}
{$H+}

interface

uses
  Compression.DeflateFormat;

const
  LiteralLengthRootBits = 10;
  DistanceRootBits = 8;
  CodeLengthRootBits = 7;

  { The most entries the tables can need, roots included, for the
    widest codes of each alphabet (zlib's "enough": 1334 and 402),
    rounded up. }
  LiteralLengthTableSize = 1536;
  DistanceTableSize = 512;
  CodeLengthTableSize = 1 shl CodeLengthRootBits;

  EntryKindSymbol = 0;
  EntryKindLink = 1;
  EntryKindInvalid = 2;

type
  TDecodeEntry = LongWord;
  PDecodeEntry = ^TDecodeEntry;

  TCodeKind = (
    { The code length code: must be complete. }
    CodeKindCodeLengths,
    { Literal/length or distance codes. }
    CodeKindSymbols
  );

  TLiteralLengthTable = array[0..LiteralLengthTableSize - 1] of TDecodeEntry;
  TDistanceTable = array[0..DistanceTableSize - 1] of TDecodeEntry;
  TCodeLengthTable = array[0..CodeLengthTableSize - 1] of TDecodeEntry;

{ Builds the table for the code with the given lengths (Count of them,
  each 0 to 15) into Table (TableSize entries). False if the lengths do
  not make a valid code. }
function BuildDecodeTable(Lengths: PByte; Count: Integer; RootBits: Integer; Table: PDecodeEntry;
  TableSize: Integer; Kind: TCodeKind): Boolean;

{ The parts of an entry. }
function EntryValue(Entry: TDecodeEntry): Integer; inline;
function EntryLength(Entry: TDecodeEntry): Integer; inline;
function EntrySubtableBits(Entry: TDecodeEntry): Integer; inline;
function EntryKind(Entry: TDecodeEntry): Integer; inline;

implementation

function MakeEntry(Kind: Integer; Value: Integer; Length: Integer; SubtableBits: Integer): TDecodeEntry;
begin
  Result := TDecodeEntry(Value) or (TDecodeEntry(Length) shl 16) or (TDecodeEntry(SubtableBits) shl 20) or
    (TDecodeEntry(Kind) shl 24);
end;

function EntryValue(Entry: TDecodeEntry): Integer;
begin
  Result := Entry and $FFFF;
end;

function EntryLength(Entry: TDecodeEntry): Integer;
begin
  Result := (Entry shr 16) and $F;
end;

function EntrySubtableBits(Entry: TDecodeEntry): Integer;
begin
  Result := (Entry shr 20) and $F;
end;

function EntryKind(Entry: TDecodeEntry): Integer;
begin
  Result := Entry shr 24;
end;

function ReverseBits(Code: LongWord; Length: Integer): LongWord;
var
  Bit: Integer;
begin
  Result := 0;
  for Bit := 1 to Length do
  begin
    Result := (Result shl 1) or (Code and 1);
    Code := Code shr 1;
  end;
end;

procedure FillEntries(Table: PDecodeEntry; First: Integer; Size: Integer; Entry: TDecodeEntry);
var
  Index: Integer;
begin
  for Index := First to First + Size - 1 do
    Table[Index] := Entry;
end;

{ Places Entry at every index of a table of TableEntries whose low
  CodeLength bits are Reversed. }
procedure SpreadEntry(Table: PDecodeEntry; Reversed: LongWord; CodeLength: Integer; TableEntries: Integer;
  Entry: TDecodeEntry);
var
  Index: Integer;
  Step: Integer;
begin
  Step := 1 shl CodeLength;
  Index := Reversed;
  while Index < TableEntries do
  begin
    Table[Index] := Entry;
    Inc(Index, Step);
  end;
end;

{ How many index bits the subtable needs that starts with a code of
  CodeLength, given how many codes of each length are still to be placed
  (as zlib works it out): enough for every code sharing its root bits. }
function SubtableBitsFor(CodeLength: Integer; RootBits: Integer; MaximumLength: Integer;
  const Remaining: array of Integer): Integer;
var
  Space: Integer;
begin
  Result := CodeLength - RootBits;
  Space := 1 shl Result;
  while Result + RootBits < MaximumLength do
  begin
    Dec(Space, Remaining[Result + RootBits]);
    if Space <= 0 then
      Break;
    Inc(Result);
    Space := Space shl 1;
  end;
end;

function BuildDecodeTable(Lengths: PByte; Count: Integer; RootBits: Integer; Table: PDecodeEntry;
  TableSize: Integer; Kind: TCodeKind): Boolean;
var
  LengthCounts: array[0..MaximumCodeLength] of Integer;
  Remaining: array[0..MaximumCodeLength] of Integer;
  NextCode: array[0..MaximumCodeLength] of LongWord;
  Offsets: array[0..MaximumCodeLength + 1] of Integer;
  SortedSymbols: array[0..LiteralLengthSymbols - 1] of Word;
  Symbol: Integer;
  CodeLength: Integer;
  MaximumLength: Integer;
  Unused: Integer;
  Code: LongWord;
  Reversed: LongWord;
  RootEntries: Integer;
  TableEnd: Integer;
  CurrentPrefix: Integer;
  SubtableStart: Integer;
  SubtableBits: Integer;
  Prefix: Integer;
  Position: Integer;
begin
  Result := False;
  if (Count > LiteralLengthSymbols) or (RootBits > MaximumCodeLength) then
    Exit;
  RootEntries := 1 shl RootBits;
  if TableSize < RootEntries then
    Exit;

  for CodeLength := 0 to MaximumCodeLength do
    LengthCounts[CodeLength] := 0;
  for Symbol := 0 to Count - 1 do
  begin
    if Lengths[Symbol] > MaximumCodeLength then
      Exit;
    Inc(LengthCounts[Lengths[Symbol]]);
  end;
  MaximumLength := 0;
  for CodeLength := 1 to MaximumCodeLength do
    if LengthCounts[CodeLength] > 0 then
      MaximumLength := CodeLength;

  FillEntries(Table, 0, RootEntries, MakeEntry(EntryKindInvalid, 0, RootBits, 0));
  if MaximumLength = 0 then
  begin
    Result := True;
    Exit;
  end;

  { Over-subscribed or incomplete? }
  Unused := 1;
  for CodeLength := 1 to MaximumCodeLength do
  begin
    Unused := (Unused shl 1) - LengthCounts[CodeLength];
    if Unused < 0 then
      Exit;
  end;
  if (Unused > 0) and ((Kind = CodeKindCodeLengths) or (MaximumLength <> 1)) then
    Exit;

  { The first code of each length, and the symbols in code order. }
  Code := 0;
  NextCode[0] := 0;
  for CodeLength := 1 to MaximumCodeLength do
  begin
    if CodeLength = 1 then
      Code := 0
    else
      Code := (Code + LongWord(LengthCounts[CodeLength - 1])) shl 1;
    NextCode[CodeLength] := Code;
  end;
  Offsets[1] := 0;
  for CodeLength := 1 to MaximumCodeLength do
    Offsets[CodeLength + 1] := Offsets[CodeLength] + LengthCounts[CodeLength];
  for Symbol := 0 to Count - 1 do
    if Lengths[Symbol] > 0 then
    begin
      SortedSymbols[Offsets[Lengths[Symbol]]] := Symbol;
      Inc(Offsets[Lengths[Symbol]]);
    end;
  for CodeLength := 0 to MaximumCodeLength do
    Remaining[CodeLength] := LengthCounts[CodeLength];

  TableEnd := RootEntries;
  CurrentPrefix := -1;
  SubtableStart := 0;
  SubtableBits := 0;
  for Position := 0 to Offsets[MaximumCodeLength + 1] - 1 do
  begin
    Symbol := SortedSymbols[Position];
    CodeLength := Lengths[Symbol];
    Code := NextCode[CodeLength];
    Inc(NextCode[CodeLength]);
    Reversed := ReverseBits(Code, CodeLength);
    if CodeLength <= RootBits then
      SpreadEntry(Table, Reversed, CodeLength, RootEntries, MakeEntry(EntryKindSymbol, Symbol, CodeLength, 0))
    else
    begin
      Prefix := Reversed and LongWord(RootEntries - 1);
      if Prefix <> CurrentPrefix then
      begin
        SubtableBits := SubtableBitsFor(CodeLength, RootBits, MaximumLength, Remaining);
        if TableEnd + (1 shl SubtableBits) > TableSize then
          Exit;
        SubtableStart := TableEnd;
        Inc(TableEnd, 1 shl SubtableBits);
        FillEntries(Table, SubtableStart, 1 shl SubtableBits, MakeEntry(EntryKindInvalid, 0, SubtableBits, 0));
        Table[Prefix] := MakeEntry(EntryKindLink, SubtableStart, RootBits, SubtableBits);
        CurrentPrefix := Prefix;
      end;
      SpreadEntry(Table + SubtableStart, Reversed shr RootBits, CodeLength - RootBits, 1 shl SubtableBits,
        MakeEntry(EntryKindSymbol, Symbol, CodeLength - RootBits, 0));
    end;
    Dec(Remaining[CodeLength]);
  end;
  Result := True;
end;

end.
