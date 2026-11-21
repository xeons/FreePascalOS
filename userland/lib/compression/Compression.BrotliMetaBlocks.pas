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
  The headers of a brotli stream (RFC 7932 section 9): the window size
  at the start, then before each meta-block its length and kind (last,
  empty, metadata, uncompressed) and, for a compressed one, what its
  commands are decoded with:

    for literals, commands and distances (the three block categories):
      the number of block types and, with more than one, the codes of
      the block types and block counts and the first block's count;
    the distance parameters (NPOSTFIX, NDIRECT);
    the context mode of each literal block type;
    the literal and distance context maps;
    the prefix codes: one per literal tree, per command block type and
      per distance tree.

  TBrotliMetaBlock holds all of that; the decoder reads it in small
  steps with these routines (each reads past the input like the prefix
  codes do: the caller looks at the reader's Overrun first).
}
unit Compression.BrotliMetaBlocks;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

uses
  Compression.Errors,
  Compression.HuffmanDecoding,
  Compression.BrotliBitReader,
  Compression.BrotliPrefixCodes;

const
  BrotliLiteralCategory = 0;
  BrotliCommandCategory = 1;
  BrotliDistanceCategory = 2;
  { The count of a category with one block type: never runs out within
    a meta-block (at most 1 shl 24 bytes). }
  BrotliEndlessBlock = 1 shl 24;
  BrotliLargestWindowBits = 24;

type
  TDecodeEntryArray = array of TDecodeEntry;

  TBrotliBlockCategory = record
    TypeCount: Integer;
    CurrentType: Integer;
    PreviousType: Integer;
    Remaining: LongWord;
    TypeTable: TDecodeEntryArray;
    CountTable: TDecodeEntryArray;
  end;

  TBrotliMetaBlockStart = record
    IsLast: Boolean;
    { The last meta-block, empty: the stream ends. }
    EndsStream: Boolean;
    IsMetadata: Boolean;
    IsUncompressed: Boolean;
    { The uncompressed length (MLEN), or the metadata's. }
    Length: LongWord;
  end;

  TBrotliMetaBlock = record
    Categories: array[BrotliLiteralCategory..BrotliDistanceCategory] of TBrotliBlockCategory;
    PostfixBits: Integer;
    DirectCodes: Integer;
    DistanceAlphabet: Integer;
    ContextModes: array[0..255] of Byte;
    LiteralTreeCount: Integer;
    DistanceTreeCount: Integer;
    LiteralContextMap: array of Byte;
    DistanceContextMap: array of Byte;
    LiteralTrees: TBrotliTreeGroup;
    CommandTrees: TBrotliTreeGroup;
    DistanceTrees: TBrotliTreeGroup;
  end;

function ReadBrotliWindowBits(var Reader: TBrotliBitReader; out WindowBits: Integer): TCompressionError;
function ReadBrotliMetaBlockStart(var Reader: TBrotliBitReader; out Start: TBrotliMetaBlockStart): TCompressionError;

{ NBLTYPES, NTREES: 1 to 256. }
function ReadBrotliTypeCount(var Reader: TBrotliBitReader): Integer;
procedure StartBlockCategory(var Category: TBrotliBlockCategory; TypeCount: Integer);
{ The block type or block count code of a category (with more than one
  type), into the category. }
function ReadCategoryTypeCode(var Reader: TBrotliBitReader; var Category: TBrotliBlockCategory;
  var Table: TBrotliTableBuffer): TCompressionError;
function ReadCategoryCountCode(var Reader: TBrotliBitReader; var Category: TBrotliBlockCategory;
  var Table: TBrotliTableBuffer): TCompressionError;
function ReadBlockCount(var Reader: TBrotliBitReader; const Category: TBrotliBlockCategory): LongWord;
{ A block switch command: the new type and count. }
function ReadBlockSwitch(var Reader: TBrotliBitReader; var Category: TBrotliBlockCategory): TCompressionError;

{ NPOSTFIX, NDIRECT, the literal context modes and NTREESL. }
procedure ReadDistanceParameters(var Reader: TBrotliBitReader; var MetaBlock: TBrotliMetaBlock);

implementation

uses
  Compression.BrotliTables;

function ReadBrotliWindowBits(var Reader: TBrotliBitReader; out WindowBits: Integer): TCompressionError;
var
  Value: Integer;
begin
  Result := CompressionErrorNone;
  if Reader.ReadBits(1) = 0 then
  begin
    WindowBits := 16;
    Exit;
  end;
  Value := Reader.ReadBits(3);
  if Value <> 0 then
  begin
    WindowBits := 17 + Value;
    Exit;
  end;
  Value := Reader.ReadBits(3);
  if Value = 1 then
  begin
    { 0010001: not used (large windows are another format). }
    WindowBits := 0;
    Exit(CompressionErrorInvalidWindowSize);
  end;
  if Value = 0 then
    WindowBits := 17
  else
    WindowBits := 8 + Value;
end;

function ReadBrotliMetaBlockStart(var Reader: TBrotliBitReader; out Start: TBrotliMetaBlockStart): TCompressionError;
var
  NibbleCode: Integer;
  Nibbles: Integer;
  Index: Integer;
  Part: LongWord;
  SkipBytes: Integer;
begin
  Result := CompressionErrorNone;
  Start.IsLast := Reader.ReadBits(1) = 1;
  Start.EndsStream := False;
  Start.IsMetadata := False;
  Start.IsUncompressed := False;
  Start.Length := 0;
  if Start.IsLast and (Reader.ReadBits(1) = 1) then
  begin
    Start.EndsStream := True;
    Exit;
  end;
  NibbleCode := Reader.ReadBits(2);
  if NibbleCode = 3 then
  begin
    Start.IsMetadata := True;
    if Reader.ReadBits(1) <> 0 then
      Exit(CompressionErrorInvalidPadding);
    SkipBytes := Reader.ReadBits(2);
    for Index := 0 to SkipBytes - 1 do
    begin
      Part := Reader.ReadBits(8);
      if (Index = SkipBytes - 1) and (SkipBytes > 1) and (Part = 0) then
        Exit(CompressionErrorCorruptBlock);
      Start.Length := Start.Length or (Part shl (8 * Index));
    end;
    if SkipBytes > 0 then
      Inc(Start.Length);
    if not Reader.SkipToByteBoundary then
      Exit(CompressionErrorInvalidPadding);
    Exit;
  end;
  Nibbles := 4 + NibbleCode;
  for Index := 0 to Nibbles - 1 do
  begin
    Part := Reader.ReadBits(4);
    if (Index = Nibbles - 1) and (Nibbles > 4) and (Part = 0) then
      Exit(CompressionErrorCorruptBlock);
    Start.Length := Start.Length or (Part shl (4 * Index));
  end;
  Inc(Start.Length);
  if not Start.IsLast then
    Start.IsUncompressed := Reader.ReadBits(1) = 1;
  if Start.IsUncompressed and not Reader.SkipToByteBoundary then
    Exit(CompressionErrorInvalidPadding);
end;

function ReadBrotliTypeCount(var Reader: TBrotliBitReader): Integer;
var
  Bits: Integer;
begin
  if Reader.ReadBits(1) = 0 then
    Exit(1);
  Bits := Reader.ReadBits(3);
  if Bits = 0 then
    Exit(2);
  Result := (1 shl Bits) + Integer(Reader.ReadBits(Bits)) + 1;
end;

procedure StartBlockCategory(var Category: TBrotliBlockCategory; TypeCount: Integer);
begin
  Category.TypeCount := TypeCount;
  Category.CurrentType := 0;
  Category.PreviousType := 1;
  Category.Remaining := BrotliEndlessBlock;
end;

procedure StoreTable(var Target: TDecodeEntryArray; const Table: TBrotliTableBuffer; Used: Integer);
begin
  if Length(Target) < Used then
    SetLength(Target, Used);
  Move(Table[0], Target[0], Used * SizeOf(TDecodeEntry));
end;

function ReadCategoryTypeCode(var Reader: TBrotliBitReader; var Category: TBrotliBlockCategory;
  var Table: TBrotliTableBuffer): TCompressionError;
var
  Used: Integer;
begin
  Result := ReadBrotliPrefixCode(Reader, Category.TypeCount + 2, Table, Used);
  if (Result = CompressionErrorNone) and not Reader.Overrun then
    StoreTable(Category.TypeTable, Table, Used);
end;

function ReadCategoryCountCode(var Reader: TBrotliBitReader; var Category: TBrotliBlockCategory;
  var Table: TBrotliTableBuffer): TCompressionError;
var
  Used: Integer;
begin
  Result := ReadBrotliPrefixCode(Reader, BrotliBlockCountAlphabet, Table, Used);
  if (Result = CompressionErrorNone) and not Reader.Overrun then
    StoreTable(Category.CountTable, Table, Used);
end;

function ReadBlockCount(var Reader: TBrotliBitReader; const Category: TBrotliBlockCategory): LongWord;
var
  Code: Integer;
begin
  Code := Reader.ReadSymbol(@Category.CountTable[0], BrotliRootBits);
  Result := BrotliBlockCountBases[Code] + Reader.ReadBits(BrotliBlockCountExtraBits[Code]);
end;

function ReadBlockSwitch(var Reader: TBrotliBitReader; var Category: TBrotliBlockCategory): TCompressionError;
var
  TypeCode: Integer;
  Count: LongWord;
  NewType: Integer;
begin
  Result := CompressionErrorNone;
  TypeCode := Reader.ReadSymbol(@Category.TypeTable[0], BrotliRootBits);
  Count := ReadBlockCount(Reader, Category);
  if Reader.Overrun then
    Exit;
  case TypeCode of
    0: NewType := Category.PreviousType;
    1: NewType := Category.CurrentType + 1;
  else
    NewType := TypeCode - 2;
  end;
  if NewType >= Category.TypeCount then
    Dec(NewType, Category.TypeCount);
  if NewType >= Category.TypeCount then
    Exit(CompressionErrorInvalidBlockSwitch);
  Category.PreviousType := Category.CurrentType;
  Category.CurrentType := NewType;
  Category.Remaining := Count;
end;

procedure ReadDistanceParameters(var Reader: TBrotliBitReader; var MetaBlock: TBrotliMetaBlock);
var
  Index: Integer;
begin
  MetaBlock.PostfixBits := Reader.ReadBits(2);
  MetaBlock.DirectCodes := Integer(Reader.ReadBits(4)) shl MetaBlock.PostfixBits;
  MetaBlock.DistanceAlphabet := 16 + MetaBlock.DirectCodes + (48 shl MetaBlock.PostfixBits);
  for Index := 0 to MetaBlock.Categories[BrotliLiteralCategory].TypeCount - 1 do
    MetaBlock.ContextModes[Index] := Reader.ReadBits(2);
  MetaBlock.LiteralTreeCount := ReadBrotliTypeCount(Reader);
end;

end.
