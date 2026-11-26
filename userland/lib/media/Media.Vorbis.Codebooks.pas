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
  Vorbis codebooks (Vorbis I specification, section 3): the entries'
  codeword lengths, the Huffman codewords they imply, and the vector
  quantisation lookup (types 1 and 2) giving each entry's vector.

  Codewords are given out in entry order, each the lowest one free at its
  length, and are read from the packet first bit first; so each is kept
  bit-reversed, and a table indexed by the next LookupBits bits of the
  packet decodes the short ones in one step. Longer ones are matched
  against a list, shortest first. The vectors of every entry are worked
  out when the codebook is read.
}
unit Media.Vorbis.Codebooks;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Media.Vorbis.BitReader;

const
  LookupBits = 10;

type
  TLongCodeword = record
    ReversedCode: LongWord;
    Length: Byte;
    Entry: LongInt;
  end;

  TVorbisCodebook = class
  public
    Dimensions: Integer;
    Entries: Integer;
    Lengths: array of Byte;
    LookupType: Integer;
    { Entries * Dimensions values, entry by entry (lookup types 1 and 2). }
    Vectors: array of Single;
    { Per table index: the entry (-1: no short codeword starts so) and the
      length in the low byte, as Entry shl 8 or Length. }
    FastTable: array of LongInt;
    LongCodes: array of TLongCodeword;
    { The entry of a codebook with a single used entry, else -1. }
    SingleEntry: Integer;
    { Reads the codebook from the setup header; raises EMediaError. }
    procedure ReadFrom(var Reader: TVorbisBitReader);
    { The next entry from the packet; -1 at the end of the packet (or a
      codeword not in the book). }
    function DecodeEntry(var Reader: TVorbisBitReader): Integer;
  private
    procedure AssignCodewords;
    procedure BuildVectors(MinimumValue, DeltaValue: Single; SequenceP: Boolean; LookupValues: Integer;
      const Multiplicands: array of LongWord);
  end;

{ The largest r with r^Dimensions <= Entries (lookup1_values). }
function LookupOneValues(Entries, Dimensions: Integer): Integer;
{ Vorbis' 32-bit float packing (float32_unpack). }
function UnpackVorbisFloat(Value: LongWord): Single;

implementation

uses
  Math,
  Media.Errors;

function LookupOneValues(Entries, Dimensions: Integer): Integer;
var
  Product: Int64;
  Index: Integer;
begin
  Result := Trunc(Math.Power(Entries, 1 / Dimensions));
  if Result < 0 then
    Result := 0;
  { Correct for floating point rounding either way. }
  repeat
    Product := 1;
    for Index := 1 to Dimensions do
    begin
      Product := Product * (Result + 1);
      if Product > Entries then
        Break;
    end;
    if Product <= Entries then
      Inc(Result)
    else
      Break;
  until False;
  while Result > 0 do
  begin
    Product := 1;
    for Index := 1 to Dimensions do
    begin
      Product := Product * Result;
      if Product > Entries then
        Break;
    end;
    if Product <= Entries then
      Break;
    Dec(Result);
  end;
end;

function UnpackVorbisFloat(Value: LongWord): Single;
var
  Mantissa: Double;
  Exponent: Integer;
begin
  Mantissa := Value and $1FFFFF;
  Exponent := (Value and $7FE00000) shr 21;
  if (Value and $80000000) <> 0 then
    Mantissa := -Mantissa;
  Result := Ldexp(Mantissa, Exponent - 788);
end;

function ReverseBits(Value: LongWord; Count: Integer): LongWord;
var
  Index: Integer;
begin
  Result := 0;
  for Index := 1 to Count do
  begin
    Result := (Result shl 1) or (Value and 1);
    Value := Value shr 1;
  end;
end;

procedure TVorbisCodebook.ReadFrom(var Reader: TVorbisBitReader);
var
  Entry, CurrentLength, Number, LookupValues, Index, ValueBits: Integer;
  Sparse, SequenceP: Boolean;
  MinimumValue, DeltaValue: Single;
  Multiplicands: array of LongWord;
begin
  if ReadBits(Reader, 24) <> $564342 then
    MediaFail('Vorbis codebook sync pattern missing');
  Dimensions := ReadBits(Reader, 16);
  Entries := ReadBits(Reader, 24);
  if (Dimensions = 0) and (Entries > 0) then
    MediaFail('Vorbis codebook without dimensions');
  SetLength(Lengths, Entries);
  if ReadBit(Reader) then
  begin
    { Ordered: runs of entries of increasing lengths. }
    Entry := 0;
    CurrentLength := ReadBits(Reader, 5) + 1;
    while Entry < Entries do
    begin
      Number := ReadBits(Reader, VorbisIntegerLog(Entries - Entry));
      if (Entry + Number > Entries) or (CurrentLength > 32) then
        MediaFail('bad ordered Vorbis codebook');
      for Index := Entry to Entry + Number - 1 do
        Lengths[Index] := CurrentLength;
      Inc(Entry, Number);
      Inc(CurrentLength);
      if Reader.EndOfPacket then
        MediaFail('Vorbis setup header cut short');
    end;
  end
  else
  begin
    Sparse := ReadBit(Reader);
    for Entry := 0 to Entries - 1 do
      if (not Sparse) or ReadBit(Reader) then
        Lengths[Entry] := ReadBits(Reader, 5) + 1
      else
        Lengths[Entry] := 0;
  end;
  LookupType := ReadBits(Reader, 4);
  case LookupType of
    0: ;
    1, 2:
      begin
        MinimumValue := UnpackVorbisFloat(ReadBits(Reader, 32));
        DeltaValue := UnpackVorbisFloat(ReadBits(Reader, 32));
        ValueBits := ReadBits(Reader, 4) + 1;
        SequenceP := ReadBit(Reader);
        if LookupType = 1 then
          LookupValues := LookupOneValues(Entries, Dimensions)
        else
          LookupValues := Entries * Dimensions;
        if Int64(LookupValues) * ValueBits > Int64(Reader.ByteCount) * 8 then
          MediaFail('Vorbis codebook lookup table larger than the header');
        Multiplicands := nil;
        SetLength(Multiplicands, LookupValues);
        for Index := 0 to LookupValues - 1 do
          Multiplicands[Index] := ReadBits(Reader, ValueBits);
        BuildVectors(MinimumValue, DeltaValue, SequenceP, LookupValues, Multiplicands);
      end;
  else
    MediaFail('unknown Vorbis codebook lookup type');
  end;
  if Reader.EndOfPacket then
    MediaFail('Vorbis setup header cut short');
  AssignCodewords;
end;

procedure TVorbisCodebook.BuildVectors(MinimumValue, DeltaValue: Single; SequenceP: Boolean; LookupValues: Integer;
  const Multiplicands: array of LongWord);
var
  Entry, Dimension, Offset: Integer;
  IndexDivisor: Int64;
  Last, Value: Single;
begin
  if Int64(Entries) * Dimensions > 64 * 1024 * 1024 then
    MediaFail('Vorbis codebook too large');
  SetLength(Vectors, Entries * Dimensions);
  for Entry := 0 to Entries - 1 do
  begin
    Last := 0;
    IndexDivisor := 1;
    for Dimension := 0 to Dimensions - 1 do
    begin
      if LookupType = 1 then
      begin
        if LookupValues = 0 then
          Offset := 0
        else
          Offset := (Entry div IndexDivisor) mod LookupValues;
        IndexDivisor := IndexDivisor * LookupValues;
        { Past every entry the divisor only grows: keep it in range. }
        if IndexDivisor > Entries then
          IndexDivisor := Int64(Entries) + 1;
      end
      else
        Offset := Entry * Dimensions + Dimension;
      if Offset < LookupValues then
        Value := Multiplicands[Offset] * DeltaValue + MinimumValue + Last
      else
        Value := MinimumValue + Last;
      Vectors[Entry * Dimensions + Dimension] := Value;
      if SequenceP then
        Last := Value;
    end;
  end;
end;

procedure TVorbisCodebook.AssignCodewords;
var
  { Available[L]: the lowest free codeword of length L (bit 0 last), 0 if
    none (the specification's "marker" tree, as in the reference decoder). }
  Available: array[0..32] of LongWord;
  Entry, Length, Level, UsedCount, LongCount, Fill, Index, Insert: Integer;
  Code: LongWord;
  Reversed: LongWord;
  Item: TLongCodeword;
begin
  SingleEntry := -1;
  SetLength(FastTable, 1 shl LookupBits);
  for Index := 0 to High(FastTable) do
    FastTable[Index] := -1;
  LongCodes := nil;
  UsedCount := 0;
  for Entry := 0 to Entries - 1 do
    if Lengths[Entry] > 0 then
    begin
      Inc(UsedCount);
      SingleEntry := Entry;
    end;
  if UsedCount = 0 then
    Exit;
  if UsedCount = 1 then
  begin
    { One codeword: whatever single bit is read, it is that entry. }
    for Index := 0 to High(FastTable) do
      FastTable[Index] := (SingleEntry shl 8) or 1;
    Exit;
  end;
  SingleEntry := -1;
  FillChar(Available, SizeOf(Available), 0);
  LongCount := 0;
  { The first used entry takes the all-zero codeword of its length. }
  Entry := 0;
  while Lengths[Entry] = 0 do
    Inc(Entry);
  Length := Lengths[Entry];
  for Level := 1 to Length do
    Available[Level] := LongWord(1) shl (32 - Level);
  Code := 0;
  while True do
  begin
    Reversed := ReverseBits(Code shr (32 - Length), Length);
    if Length <= LookupBits then
    begin
      Fill := Reversed;
      while Fill < (1 shl LookupBits) do
      begin
        FastTable[Fill] := (Entry shl 8) or Length;
        Inc(Fill, 1 shl Length);
      end;
    end
    else
    begin
      Item.ReversedCode := Reversed;
      Item.Length := Length;
      Item.Entry := Entry;
      { Kept ordered by length, shortest (likeliest) first. }
      SetLength(LongCodes, LongCount + 1);
      Insert := LongCount;
      while (Insert > 0) and (LongCodes[Insert - 1].Length > Length) do
      begin
        LongCodes[Insert] := LongCodes[Insert - 1];
        Dec(Insert);
      end;
      LongCodes[Insert] := Item;
      Inc(LongCount);
    end;
    { The next used entry. }
    repeat
      Inc(Entry);
    until (Entry >= Entries) or (Lengths[Entry] > 0);
    if Entry >= Entries then
      Break;
    Length := Lengths[Entry];
    { The deepest free node at or above Length. }
    Level := Length;
    while (Level > 0) and (Available[Level] = 0) do
      Dec(Level);
    if Level = 0 then
      MediaFail('Vorbis codebook is overspecified');
    Code := Available[Level];
    Available[Level] := 0;
    { The rest of the path down to Length frees right siblings. }
    for Index := Level + 1 to Length do
      Available[Index] := Code + (LongWord(1) shl (32 - Index));
  end;
end;

function TVorbisCodebook.DecodeEntry(var Reader: TVorbisBitReader): Integer;
var
  TableValue, Index, CodeLength: Integer;
  Peeked: QWord;
begin
  TableValue := FastTable[PeekBits(Reader, LookupBits)];
  if TableValue >= 0 then
  begin
    SkipBits(Reader, TableValue and $FF);
    if Reader.EndOfPacket then
      Exit(-1);
    Exit(TableValue shr 8);
  end;
  Peeked := PeekBits(Reader, 32);
  for Index := 0 to High(LongCodes) do
  begin
    CodeLength := LongCodes[Index].Length;
    if (Peeked and ((QWord(1) shl CodeLength) - 1)) = LongCodes[Index].ReversedCode then
    begin
      SkipBits(Reader, CodeLength);
      if Reader.EndOfPacket then
        Exit(-1);
      Exit(LongCodes[Index].Entry);
    end;
  end;
  { No codeword matches: an undecodable packet, treated as its end. }
  Reader.EndOfPacket := True;
  Result := -1;
end;

end.
