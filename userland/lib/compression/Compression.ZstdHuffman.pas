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
  Zstandard's Huffman coded literals (RFC 8878 section 4.2).

  The tree description gives each literal a weight (4 bits each, or FSE
  coded with two interleaved states); the last literal's weight is what
  completes the sum to a power of two, which also gives the longest code
  (at most 11 bits). A literal of weight W has a code of
  MaximumBits + 1 - W bits.

  The table is looked up with the next MaximumBits bits of a backward
  stream: literals in order of weight, then of value, each fill
  1 shl (W - 1) entries from the start of the table.
}
unit Compression.ZstdHuffman;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

uses
  Compression.Errors;

const
  ZstdHuffmanMaximumBits = 11;

type
  TZstdHuffmanEntry = record
    Symbol: Byte;
    BitCount: Byte;
  end;

  TZstdHuffmanTable = record
    MaximumBits: Integer;
    Entries: array[0..(1 shl ZstdHuffmanMaximumBits) - 1] of TZstdHuffmanEntry;
  end;

{ Reads a Huffman tree description from Data (Size bytes available)
  into Table; Used is its size. }
function ReadZstdHuffmanTable(Data: PByte; Size: SizeUInt; out Table: TZstdHuffmanTable;
  out Used: SizeUInt): TCompressionError;

{ Decodes Count literals from one stream (Size bytes) into Output; the
  stream must end exactly with the last. }
function DecodeZstdHuffmanStream(const Table: TZstdHuffmanTable; Data: PByte; Size: SizeUInt; Output: PByte;
  Count: SizeUInt): Boolean;

{ Decodes RegeneratedSize literals from one stream or from four after a
  jump table (Size bytes in all) into Output. }
function DecodeZstdHuffmanLiterals(const Table: TZstdHuffmanTable; Data: PByte; Size: SizeUInt;
  FourStreams: Boolean; Output: PByte; RegeneratedSize: SizeUInt): TCompressionError;

implementation

uses
  Compression.ZstdBitReaders,
  Compression.FiniteStateEntropy;

const
  MaximumWeightAccuracyLog = 6;
  MaximumListedWeights = 255;
  JumpTableSize = 6;

type
  TWeights = array[0..255] of Byte;

{ Weights FSE coded in Size bytes: a distribution, then a backward
  stream with two states taking turns, until the stream runs out. }
function ReadCodedWeights(Data: PByte; Size: SizeUInt; var Weights: TWeights; out Count: Integer): Boolean;
var
  Distribution: TFseDistribution;
  Table: TFseTable;
  Used: SizeUInt;
  Reader: TZstdBackwardReader;
  State1: Integer;
  State2: Integer;
begin
  Result := False;
  Count := 0;
  if not ReadFseDistribution(Data, Size, 255, MaximumWeightAccuracyLog, Distribution, Used) then
    Exit;
  if not BuildFseTable(Distribution, Table) then
    Exit;
  if not Reader.Start(Data + Used, Size - Used) then
    Exit;
  State1 := Reader.ReadBits(Table.AccuracyLog);
  State2 := Reader.ReadBits(Table.AccuracyLog);
  if Reader.Overflowed then
    Exit;
  repeat
    if Count > MaximumListedWeights - 2 then
      Exit;
    Weights[Count] := Table.Entries[State1].Symbol;
    Inc(Count);
    State1 := Table.Entries[State1].Baseline + Reader.ReadBits(Table.Entries[State1].BitCount);
    if Reader.Overflowed then
    begin
      Weights[Count] := Table.Entries[State2].Symbol;
      Inc(Count);
      Break;
    end;
    Weights[Count] := Table.Entries[State2].Symbol;
    Inc(Count);
    State2 := Table.Entries[State2].Baseline + Reader.ReadBits(Table.Entries[State2].BitCount);
    if Reader.Overflowed then
    begin
      Weights[Count] := Table.Entries[State1].Symbol;
      Inc(Count);
      Break;
    end;
  until False;
  Result := True;
end;

function ReadZstdHuffmanTable(Data: PByte; Size: SizeUInt; out Table: TZstdHuffmanTable;
  out Used: SizeUInt): TCompressionError;
var
  Weights: TWeights;
  Header: Byte;
  ListedCount: Integer;
  Index: Integer;
  Total: LongWord;
  Power: LongWord;
  Rest: LongWord;
  LastWeight: Integer;
  SymbolCount: Integer;
  Weight: Integer;
  Position: Integer;
  Span: Integer;
  Fill: Integer;
begin
  Result := CompressionErrorInvalidPrefixCode;
  Used := 0;
  Table.MaximumBits := 0;
  if Size < 1 then
    Exit;
  FillChar(Weights, SizeOf(Weights), 0);
  Header := Data[0];
  if Header < 128 then
  begin
    if (Header = 0) or (SizeUInt(Header) + 1 > Size) then
      Exit;
    if not ReadCodedWeights(Data + 1, Header, Weights, ListedCount) then
      Exit;
    Used := 1 + Header;
  end
  else
  begin
    ListedCount := Header - 127;
    Used := 1 + (SizeUInt(ListedCount) + 1) div 2;
    if Used > Size then
      Exit;
    for Index := 0 to ListedCount - 1 do
      if Index mod 2 = 0 then
        Weights[Index] := Data[1 + Index div 2] shr 4
      else
        Weights[Index] := Data[1 + Index div 2] and $0F;
  end;

  { The sum of 2^(W-1); the last weight brings it to a power of two. }
  Total := 0;
  for Index := 0 to ListedCount - 1 do
  begin
    if Weights[Index] > ZstdHuffmanMaximumBits then
      Exit;
    if Weights[Index] > 0 then
      Inc(Total, LongWord(1) shl (Weights[Index] - 1));
  end;
  if Total = 0 then
    Exit;
  Table.MaximumBits := 0;
  Power := 1;
  while Power <= Total do
  begin
    Power := Power shl 1;
    Inc(Table.MaximumBits);
  end;
  if Table.MaximumBits > ZstdHuffmanMaximumBits then
    Exit;
  Rest := Power - Total;
  { What is left must be a power of two itself. }
  if (Rest and (Rest - 1)) <> 0 then
    Exit;
  LastWeight := 1;
  while (LongWord(1) shl (LastWeight - 1)) < Rest do
    Inc(LastWeight);
  SymbolCount := ListedCount + 1;
  if SymbolCount > 256 then
    Exit;
  Weights[ListedCount] := LastWeight;

  Position := 0;
  for Weight := 1 to Table.MaximumBits do
  begin
    Span := 1 shl (Weight - 1);
    for Index := 0 to SymbolCount - 1 do
      if Weights[Index] = Weight then
        for Fill := 1 to Span do
        begin
          Table.Entries[Position].Symbol := Index;
          Table.Entries[Position].BitCount := Table.MaximumBits + 1 - Weight;
          Inc(Position);
        end;
  end;
  if Position <> 1 shl Table.MaximumBits then
    Exit;
  Result := CompressionErrorNone;
end;

function DecodeZstdHuffmanStream(const Table: TZstdHuffmanTable; Data: PByte; Size: SizeUInt; Output: PByte;
  Count: SizeUInt): Boolean;
var
  Reader: TZstdBackwardReader;
  MaximumBits: Integer;
  Index: SizeUInt;
  Entry: TZstdHuffmanEntry;
begin
  Result := False;
  if not Reader.Start(Data, Size) then
    Exit;
  MaximumBits := Table.MaximumBits;
  Index := 0;
  while Index < Count do
  begin
    Entry := Table.Entries[Reader.PeekBits(MaximumBits)];
    Reader.SkipBits(Entry.BitCount);
    Output[Index] := Entry.Symbol;
    Inc(Index);
  end;
  Result := Reader.AtStart;
end;

function ReadLittleEndian16(Data: PByte): SizeUInt; inline;
begin
  Result := SizeUInt(Data[0]) or (SizeUInt(Data[1]) shl 8);
end;

function DecodeZstdHuffmanLiterals(const Table: TZstdHuffmanTable; Data: PByte; Size: SizeUInt;
  FourStreams: Boolean; Output: PByte; RegeneratedSize: SizeUInt): TCompressionError;
var
  StreamSizes: array[0..3] of SizeUInt;
  SegmentSize: SizeUInt;
  Stream: Integer;
  Position: SizeUInt;
  OutputPosition: SizeUInt;
  StreamOutput: SizeUInt;
begin
  Result := CompressionErrorCorruptBlock;
  if not FourStreams then
  begin
    if DecodeZstdHuffmanStream(Table, Data, Size, Output, RegeneratedSize) then
      Result := CompressionErrorNone;
    Exit;
  end;
  if Size < JumpTableSize then
    Exit;
  StreamSizes[0] := ReadLittleEndian16(Data);
  StreamSizes[1] := ReadLittleEndian16(Data + 2);
  StreamSizes[2] := ReadLittleEndian16(Data + 4);
  if StreamSizes[0] + StreamSizes[1] + StreamSizes[2] > Size - JumpTableSize then
    Exit;
  StreamSizes[3] := Size - JumpTableSize - StreamSizes[0] - StreamSizes[1] - StreamSizes[2];
  SegmentSize := (RegeneratedSize + 3) div 4;
  if 3 * SegmentSize > RegeneratedSize then
    Exit;
  Position := JumpTableSize;
  OutputPosition := 0;
  for Stream := 0 to 3 do
  begin
    if Stream < 3 then
      StreamOutput := SegmentSize
    else
      StreamOutput := RegeneratedSize - 3 * SegmentSize;
    if not DecodeZstdHuffmanStream(Table, Data + Position, StreamSizes[Stream], Output + OutputPosition,
       StreamOutput) then
      Exit;
    Inc(Position, StreamSizes[Stream]);
    Inc(OutputPosition, StreamOutput);
  end;
  Result := CompressionErrorNone;
end;

end.
