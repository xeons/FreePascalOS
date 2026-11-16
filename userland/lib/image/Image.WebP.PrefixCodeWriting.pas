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
  Prefix codes for the VP8L encoder: lengths of at most 15 bits from a
  histogram (libcompression's Huffman code builder), the canonical
  codes, and the code written as VP8L stores it: a "simple" code for a
  single symbol below 256 (which then takes no bits), otherwise the
  lengths run-length coded (16 repeats the previous length, 17 and 18
  runs of zeros) with a code length code of up to 7 bits.
}
unit Image.WebP.PrefixCodeWriting;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Compression.HuffmanEncoding,
  Image.WebP.LosslessBitWriter;

type
  TPrefixCodeTable = record
    Count: LongInt;
    Lengths: array of Byte;
    Codes: array of Word;
    { One symbol used (or none): stored as a simple code when it is
      below 256. }
    Single: Boolean;
    SingleSymbol: LongInt;
  end;

{ The code for Histogram[0..Count - 1] (at most 288 symbols). }
procedure BuildPrefixCodeTable(const Histogram: array of LongWord; Count: LongInt; out Table: TPrefixCodeTable);
procedure StorePrefixCode(Writer: TLosslessBitWriter; constref Table: TPrefixCodeTable);
procedure WriteSymbol(Writer: TLosslessBitWriter; constref Table: TPrefixCodeTable; Symbol: LongInt); inline;

implementation

const
  CodeLengthCodes = 19;
  CodeLengthLimit = 7;
  SymbolLengthLimit = 15;
  DefaultCodeLength = 8;

  CodeLengthOrder: array[0..CodeLengthCodes - 1] of Byte = (
    17, 18, 0, 1, 2, 3, 4, 5, 16, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15);

type
  TLengthToken = record
    Code: LongInt;
    ExtraValue: LongInt;
  end;
  TLengthTokens = array of TLengthToken;

procedure BuildPrefixCodeTable(const Histogram: array of LongWord; Count: LongInt; out Table: TPrefixCodeTable);
var
  Symbol: LongInt;
  UsedCount: LongInt;
  Frequencies: array of LongWord;
begin
  Table.Count := Count;
  Table.Lengths := nil;
  Table.Codes := nil;
  SetLength(Table.Lengths, Count);
  SetLength(Table.Codes, Count);
  FillChar(Table.Lengths[0], Count, 0);
  FillChar(Table.Codes[0], Count * SizeOf(Word), 0);
  UsedCount := 0;
  Table.SingleSymbol := 0;
  for Symbol := 0 to Count - 1 do
    if Histogram[Symbol] > 0 then
    begin
      Inc(UsedCount);
      Table.SingleSymbol := Symbol;
    end;
  Table.Single := (UsedCount <= 1) and (Table.SingleSymbol < 256);
  if Table.Single then
    Exit;
  Frequencies := nil;
  SetLength(Frequencies, Count);
  for Symbol := 0 to Count - 1 do
    Frequencies[Symbol] := Histogram[Symbol];
  BuildCodeLengths(@Frequencies[0], Count, SymbolLengthLimit, @Table.Lengths[0]);
  BuildCanonicalCodes(@Table.Lengths[0], Count, @Table.Codes[0]);
end;

procedure AddToken(var Tokens: TLengthTokens; var TokenCount: LongInt; Code, ExtraValue: LongInt);
begin
  if TokenCount >= Length(Tokens) then
    SetLength(Tokens, 2 * Length(Tokens) + 16);
  Tokens[TokenCount].Code := Code;
  Tokens[TokenCount].ExtraValue := ExtraValue;
  Inc(TokenCount);
end;

{ The run-length tokens of the code lengths. }
function TokenizeLengths(constref Table: TPrefixCodeTable; out TokenCount: LongInt): TLengthTokens;
var
  Index: LongInt;
  Run: LongInt;
  Value: LongInt;
  Previous: LongInt;
  Chunk: LongInt;
begin
  Result := nil;
  TokenCount := 0;
  Previous := DefaultCodeLength;
  Index := 0;
  while Index < Table.Count do
  begin
    Value := Table.Lengths[Index];
    Run := 1;
    while (Index + Run < Table.Count) and (Table.Lengths[Index + Run] = Value) do
      Inc(Run);
    if (Value = 0) and (Run >= 3) then
    begin
      while Run >= 3 do
      begin
        if Run <= 10 then
          Chunk := Run
        else if Run <= 138 then
          Chunk := Run
        else
          Chunk := 138;
        if Chunk <= 10 then
          AddToken(Result, TokenCount, 17, Chunk - 3)
        else
          AddToken(Result, TokenCount, 18, Chunk - 11);
        Inc(Index, Chunk);
        Dec(Run, Chunk);
      end;
    end
    else if (Value <> 0) and (Value = Previous) and (Run >= 3) then
    begin
      while Run >= 3 do
      begin
        if Run > 6 then
          Chunk := 6
        else
          Chunk := Run;
        AddToken(Result, TokenCount, 16, Chunk - 3);
        Inc(Index, Chunk);
        Dec(Run, Chunk);
      end;
    end
    else
    begin
      AddToken(Result, TokenCount, Value, 0);
      if Value <> 0 then
        Previous := Value;
      Inc(Index);
    end;
  end;
end;

procedure StoreNormalCode(Writer: TLosslessBitWriter; constref Table: TPrefixCodeTable);
var
  Tokens: TLengthTokens;
  TokenCount: LongInt;
  Histogram: array[0..CodeLengthCodes - 1] of LongWord;
  Lengths: array[0..CodeLengthCodes - 1] of Byte;
  Codes: array[0..CodeLengthCodes - 1] of Word;
  Index: LongInt;
  CodeCount: LongInt;
begin
  Tokens := TokenizeLengths(Table, TokenCount);
  FillChar(Histogram, SizeOf(Histogram), 0);
  for Index := 0 to TokenCount - 1 do
    Inc(Histogram[Tokens[Index].Code]);
  BuildCodeLengths(@Histogram[0], CodeLengthCodes, CodeLengthLimit, @Lengths[0]);
  BuildCanonicalCodes(@Lengths[0], CodeLengthCodes, @Codes[0]);
  CodeCount := 4;
  for Index := 0 to CodeLengthCodes - 1 do
    if Lengths[CodeLengthOrder[Index]] <> 0 then
      if Index + 1 > CodeCount then
        CodeCount := Index + 1;
  Writer.WriteBits(0, 1);
  Writer.WriteBits(CodeCount - 4, 4);
  for Index := 0 to CodeCount - 1 do
    Writer.WriteBits(Lengths[CodeLengthOrder[Index]], 3);
  { Every length is written: no maximum symbol. }
  Writer.WriteBits(0, 1);
  for Index := 0 to TokenCount - 1 do
  begin
    Writer.WriteBits(Codes[Tokens[Index].Code], Lengths[Tokens[Index].Code]);
    case Tokens[Index].Code of
      16: Writer.WriteBits(Tokens[Index].ExtraValue, 2);
      17: Writer.WriteBits(Tokens[Index].ExtraValue, 3);
      18: Writer.WriteBits(Tokens[Index].ExtraValue, 7);
    end;
  end;
end;

procedure StorePrefixCode(Writer: TLosslessBitWriter; constref Table: TPrefixCodeTable);
begin
  if Table.Single then
  begin
    Writer.WriteBits(1, 1);
    Writer.WriteBits(0, 1);
    if Table.SingleSymbol <= 1 then
    begin
      Writer.WriteBits(0, 1);
      Writer.WriteBits(Table.SingleSymbol, 1);
    end
    else
    begin
      Writer.WriteBits(1, 1);
      Writer.WriteBits(Table.SingleSymbol, 8);
    end;
  end
  else
    StoreNormalCode(Writer, Table);
end;

procedure WriteSymbol(Writer: TLosslessBitWriter; constref Table: TPrefixCodeTable; Symbol: LongInt);
begin
  Writer.WriteBits(Table.Codes[Symbol], Table.Lengths[Symbol]);
end;

end.
