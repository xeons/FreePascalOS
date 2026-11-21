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
  Brotli's prefix codes (RFC 7932 section 3), read into decoding tables
  (Compression.HuffmanDecoding, BrotliRootBits wide at the root).

  A simple code lists one to four symbols, whose lengths follow from
  their number. A complex code sends the code lengths of the code
  length alphabet (in a fixed order, themselves in a small fixed code),
  then the lengths of the symbols with that code, where 16 repeats the
  last nonzero length and 17 repeats zero, a run of them multiplying the
  count. A code must be complete, or a single symbol that takes no
  bits.

  A tree group holds the tables of all the codes of one kind in a
  meta-block (one per literal context tree, per command block type,
  per distance context tree) end to end.

  Reading runs to the end even when the input does not last (the reader
  gives zeros): the caller looks at the reader's Overrun before it
  believes the result.
}
unit Compression.BrotliPrefixCodes;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

uses
  Compression.Errors,
  Compression.HuffmanDecoding,
  Compression.BrotliBitReader;

const
  BrotliRootBits = 8;
  { Room to build one table in: the root and every subtable. }
  BrotliTableBuildSize = 4096;

type
  TBrotliTableBuffer = array[0..BrotliTableBuildSize - 1] of TDecodeEntry;

  TBrotliTreeGroup = record
    Entries: array of TDecodeEntry;
    Used: Integer;
    Offsets: array of Integer;
    { The trees read so far, of TreeCount. }
    Count: Integer;
    TreeCount: Integer;
    AlphabetSize: Integer;
  end;

{ Reads one code over AlphabetSize symbols into Table; Used is how many
  entries it filled. }
function ReadBrotliPrefixCode(var Reader: TBrotliBitReader; AlphabetSize: Integer; var Table: TBrotliTableBuffer;
  out Used: Integer): TCompressionError;

{ Empties Group for TreeCount codes over AlphabetSize symbols (keeping
  its memory). }
procedure StartTreeGroup(var Group: TBrotliTreeGroup; AlphabetSize: Integer; TreeCount: Integer);
{ Appends a table read with ReadBrotliPrefixCode. }
procedure AddTree(var Group: TBrotliTreeGroup; const Table: TBrotliTableBuffer; Used: Integer);
function TreeTable(const Group: TBrotliTreeGroup; Index: Integer): PDecodeEntry; inline;

implementation

uses
  Compression.BrotliTables;

const
  CodeLengthRoot = 5;
  RepeatPreviousLength = 16;
  RepeatZeroLength = 17;
  InitialPreviousLength = 8;
  { The fixed code of the code length code lengths (section 3.5). }
  LengthCodeLengths: array[0..5] of Byte = (2, 4, 3, 2, 2, 4);
  LengthCodeRoot = 4;

var
  LengthCodeTable: array[0..(1 shl LengthCodeRoot) - 1] of TDecodeEntry;

procedure FillSingleSymbol(var Table: TBrotliTableBuffer; RootBits: Integer; Symbol: Integer; out Used: Integer);
var
  Index: Integer;
begin
  Used := 1 shl RootBits;
  for Index := 0 to Used - 1 do
    Table[Index] := SingleSymbolEntry(Symbol);
end;

function BitsFor(AlphabetSize: Integer): Integer;
begin
  Result := 0;
  while (1 shl Result) < AlphabetSize do
    Inc(Result);
end;

function ReadSimpleCode(var Reader: TBrotliBitReader; AlphabetSize: Integer; var Table: TBrotliTableBuffer;
  out Used: Integer): TCompressionError;
var
  Lengths: array[0..MaximumTableSymbols - 1] of Byte;
  Symbols: array[0..3] of Integer;
  SymbolCount: Integer;
  AlphabetBits: Integer;
  Index: Integer;
  Other: Integer;
begin
  Result := CompressionErrorInvalidPrefixCode;
  Used := 0;
  SymbolCount := Reader.ReadBits(2) + 1;
  AlphabetBits := BitsFor(AlphabetSize);
  for Index := 0 to SymbolCount - 1 do
  begin
    Symbols[Index] := Reader.ReadBits(AlphabetBits);
    if Symbols[Index] >= AlphabetSize then
      Exit;
    for Other := 0 to Index - 1 do
      if Symbols[Other] = Symbols[Index] then
        Exit;
  end;
  if SymbolCount = 1 then
  begin
    FillSingleSymbol(Table, BrotliRootBits, Symbols[0], Used);
    Exit(CompressionErrorNone);
  end;
  FillChar(Lengths, AlphabetSize, 0);
  case SymbolCount of
    2:
      begin
        Lengths[Symbols[0]] := 1;
        Lengths[Symbols[1]] := 1;
      end;
    3:
      begin
        Lengths[Symbols[0]] := 1;
        Lengths[Symbols[1]] := 2;
        Lengths[Symbols[2]] := 2;
      end;
  else
    if Reader.ReadBits(1) = 0 then
      for Index := 0 to 3 do
        Lengths[Symbols[Index]] := 2
    else
    begin
      Lengths[Symbols[0]] := 1;
      Lengths[Symbols[1]] := 2;
      Lengths[Symbols[2]] := 3;
      Lengths[Symbols[3]] := 3;
    end;
  end;
  if BuildDecodeTableCounted(@Lengths[0], AlphabetSize, BrotliRootBits, @Table[0], BrotliTableBuildSize,
     CodeKindCodeLengths, Used) then
    Result := CompressionErrorNone;
end;

{ The symbol lengths of a complex code, with the code length code in
  LengthTable. }
function ReadSymbolLengths(var Reader: TBrotliBitReader; LengthTable: PDecodeEntry; AlphabetSize: Integer;
  var Lengths: array of Byte): TCompressionError;
var
  Symbol: Integer;
  Code: Integer;
  PreviousLength: Integer;
  RepeatCount: Integer;
  RepeatLength: Integer;
  OldRepeatCount: Integer;
  NewLength: Integer;
  ExtraBits: Integer;
  Added: Integer;
  Space: Int64;
  Index: Integer;
begin
  Result := CompressionErrorInvalidPrefixCode;
  Symbol := 0;
  PreviousLength := InitialPreviousLength;
  RepeatCount := 0;
  RepeatLength := 0;
  Space := 32768;
  while (Symbol < AlphabetSize) and (Space > 0) do
  begin
    Code := Reader.ReadSymbol(LengthTable, CodeLengthRoot);
    if Reader.Overrun then
      Exit;
    if Code < RepeatPreviousLength then
    begin
      RepeatCount := 0;
      Lengths[Symbol] := Code;
      if Code <> 0 then
      begin
        PreviousLength := Code;
        Dec(Space, 32768 shr Code);
      end;
      Inc(Symbol);
      Continue;
    end;
    if Code = RepeatPreviousLength then
    begin
      ExtraBits := 2;
      NewLength := PreviousLength;
    end
    else
    begin
      ExtraBits := 3;
      NewLength := 0;
    end;
    if RepeatLength <> NewLength then
    begin
      RepeatCount := 0;
      RepeatLength := NewLength;
    end;
    OldRepeatCount := RepeatCount;
    if RepeatCount > 0 then
      RepeatCount := (RepeatCount - 2) shl ExtraBits;
    RepeatCount := RepeatCount + Integer(Reader.ReadBits(ExtraBits)) + 3;
    Added := RepeatCount - OldRepeatCount;
    if Symbol + Added > AlphabetSize then
      Exit;
    for Index := Symbol to Symbol + Added - 1 do
      Lengths[Index] := RepeatLength;
    Inc(Symbol, Added);
    if RepeatLength <> 0 then
      Dec(Space, Int64(Added) shl (15 - RepeatLength));
  end;
  if Space <> 0 then
    Exit;
  Result := CompressionErrorNone;
end;

function ReadComplexCode(var Reader: TBrotliBitReader; Skipped: Integer; AlphabetSize: Integer;
  var Table: TBrotliTableBuffer; out Used: Integer): TCompressionError;
var
  CodeLengthLengths: array[0..BrotliCodeLengthAlphabet - 1] of Byte;
  LengthTable: array[0..(1 shl CodeLengthRoot) - 1] of TDecodeEntry;
  Lengths: array[0..MaximumTableSymbols - 1] of Byte;
  Space: Integer;
  CodeCount: Integer;
  Position: Integer;
  Value: Integer;
  OnlySymbol: Integer;
  LengthTableUsed: Integer;
begin
  Result := CompressionErrorInvalidPrefixCode;
  Used := 0;
  FillChar(CodeLengthLengths, SizeOf(CodeLengthLengths), 0);
  Space := 32;
  CodeCount := 0;
  OnlySymbol := 0;
  for Position := Skipped to BrotliCodeLengthAlphabet - 1 do
  begin
    Value := Reader.ReadSymbol(@LengthCodeTable[0], LengthCodeRoot);
    CodeLengthLengths[BrotliCodeLengthOrder[Position]] := Value;
    if Value <> 0 then
    begin
      Dec(Space, 32 shr Value);
      Inc(CodeCount);
      OnlySymbol := BrotliCodeLengthOrder[Position];
      if Space <= 0 then
        Break;
    end;
  end;
  if Reader.Overrun then
    Exit;
  if (CodeCount <> 1) and (Space <> 0) then
    Exit;
  if CodeCount = 1 then
  begin
    for Position := 0 to High(LengthTable) do
      LengthTable[Position] := SingleSymbolEntry(OnlySymbol);
  end
  else if not BuildDecodeTableCounted(@CodeLengthLengths[0], BrotliCodeLengthAlphabet, CodeLengthRoot,
     @LengthTable[0], Length(LengthTable), CodeKindCodeLengths, LengthTableUsed) then
    Exit;

  FillChar(Lengths, AlphabetSize, 0);
  Result := ReadSymbolLengths(Reader, @LengthTable[0], AlphabetSize, Lengths);
  if Result <> CompressionErrorNone then
    Exit;
  Result := CompressionErrorInvalidPrefixCode;
  if BuildDecodeTableCounted(@Lengths[0], AlphabetSize, BrotliRootBits, @Table[0], BrotliTableBuildSize,
     CodeKindCodeLengths, Used) then
    Result := CompressionErrorNone;
end;

function ReadBrotliPrefixCode(var Reader: TBrotliBitReader; AlphabetSize: Integer; var Table: TBrotliTableBuffer;
  out Used: Integer): TCompressionError;
var
  Kind: Integer;
begin
  Used := 0;
  Kind := Reader.ReadBits(2);
  if Kind = 1 then
    Result := ReadSimpleCode(Reader, AlphabetSize, Table, Used)
  else
    Result := ReadComplexCode(Reader, Kind, AlphabetSize, Table, Used);
end;

procedure StartTreeGroup(var Group: TBrotliTreeGroup; AlphabetSize: Integer; TreeCount: Integer);
begin
  Group.AlphabetSize := AlphabetSize;
  Group.TreeCount := TreeCount;
  Group.Count := 0;
  Group.Used := 0;
  if Length(Group.Offsets) < TreeCount then
    SetLength(Group.Offsets, TreeCount);
end;

procedure AddTree(var Group: TBrotliTreeGroup; const Table: TBrotliTableBuffer; Used: Integer);
begin
  if Group.Used + Used > Length(Group.Entries) then
    SetLength(Group.Entries, 2 * (Group.Used + Used));
  Move(Table[0], Group.Entries[Group.Used], Used * SizeOf(TDecodeEntry));
  Group.Offsets[Group.Count] := Group.Used;
  Inc(Group.Used, Used);
  Inc(Group.Count);
end;

function TreeTable(const Group: TBrotliTreeGroup; Index: Integer): PDecodeEntry;
begin
  Result := @Group.Entries[Group.Offsets[Index]];
end;

procedure BuildLengthCodeTable;
var
  Used: Integer;
begin
  BuildDecodeTableCounted(@LengthCodeLengths[0], Length(LengthCodeLengths), LengthCodeRoot, @LengthCodeTable[0],
    Length(LengthCodeTable), CodeKindCodeLengths, Used);
end;

initialization
  BuildLengthCodeTable;
end.
