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
  JPEG's entropy coded data: Huffman tables and the bits of a scan.

  A table is built from a DHT segment's sixteen counts and its symbols
  (BuildHuffmanTable refuses counts that overflow the code space). Codes
  of up to nine bits are found with one look at a 512 entry table; longer
  ones by comparing with the largest code of each length.

  The bit reader keeps up to 64 bits, the next one at the top. Bytes
  $FF 00 stand for $FF; any other byte after $FF is a marker, where the
  scan's data ends: the reader stops before it and, like the end of the
  data, feeds zeros from then on, so a decoder never reads past the data
  whatever the bits say. InjectedBytes counts those zeros: more than
  eight means bits that are not in the file have been used, and the scan
  is cut short (BitReaderExhausted).
}
unit Image.Jpeg.Huffman;

{$mode objfpc}
{$H+}
{$inline on}
{$pointermath on}

interface

uses
  SysUtils;

type
  THuffmanTable = record
    Defined: Boolean;
    { (length shl 8) or symbol for codes of up to 9 bits; 0 otherwise. }
    Lookup: array[0..511] of Word;
    { The largest code of each length, -1 when there is none. }
    MaximumCode: array[0..17] of LongInt;
    { Added to a code of a length to give its symbol's index. }
    ValueOffset: array[0..17] of LongInt;
    Symbols: array[0..255] of Byte;
  end;

  TJpegHuffmanCounts = array[1..16] of LongInt;

  TJpegBitReader = record
    Data: PByte;
    Size: PtrInt;
    Position: PtrInt;
    Buffer: QWord;
    BitCount: LongInt;
    InjectedBytes: LongInt;
    MarkerReached: Boolean;
    { A code no table has was met. }
    Corrupt: Boolean;
  end;

{ False when the counts do not make a prefix code. }
function BuildHuffmanTable(out Table: THuffmanTable; constref Counts: TJpegHuffmanCounts;
  constref Symbols: array of Byte): Boolean;

procedure StartBitReader(out Reader: TJpegBitReader; Data: PByte; Size, Position: PtrInt);
procedure FillBitReader(var Reader: TJpegBitReader);
function DecodeHuffman(var Reader: TJpegBitReader; constref Table: THuffmanTable): LongInt; inline;
{ Count bits (0 to 16) as a number. }
function ReadBits(var Reader: TJpegBitReader; Count: LongInt): LongInt; inline;
function ReadBit(var Reader: TJpegBitReader): LongInt; inline;
{ Count bits as a signed number the JPEG way (Count 0 gives 0). }
function ReceiveAndExtend(var Reader: TJpegBitReader; Count: LongInt): LongInt; inline;
function BitReaderExhausted(constref Reader: TJpegBitReader): Boolean; inline;
{ After a restart interval: forgets the bits held and moves past the
  next restart marker (RST0 to RST7) if one is there. }
procedure RestartBitReader(var Reader: TJpegBitReader);

implementation

function BuildHuffmanTable(out Table: THuffmanTable; constref Counts: TJpegHuffmanCounts;
  constref Symbols: array of Byte): Boolean;
var
  Code: LongInt;
  SymbolIndex: LongInt;
  CodeLength: LongInt;
  Index: LongInt;
  Codes: array[0..255] of LongInt;
  Lengths: array[0..255] of LongInt;
  Fill: LongInt;
  First: LongInt;
begin
  FillChar(Table, SizeOf(Table), 0);
  Code := 0;
  SymbolIndex := 0;
  for CodeLength := 1 to 16 do
  begin
    Table.ValueOffset[CodeLength] := SymbolIndex - Code;
    for Index := 1 to Counts[CodeLength] do
    begin
      if (SymbolIndex > 255) or (SymbolIndex > High(Symbols)) or (Code >= (1 shl CodeLength)) then
        Exit(False);
      Codes[SymbolIndex] := Code;
      Lengths[SymbolIndex] := CodeLength;
      Table.Symbols[SymbolIndex] := Symbols[SymbolIndex];
      Inc(Code);
      Inc(SymbolIndex);
    end;
    if Counts[CodeLength] > 0 then
      Table.MaximumCode[CodeLength] := Code - 1
    else
      Table.MaximumCode[CodeLength] := -1;
    Code := Code shl 1;
  end;
  Table.MaximumCode[0] := -1;
  Table.MaximumCode[17] := High(LongInt);
  for Index := 0 to SymbolIndex - 1 do
    if Lengths[Index] <= 9 then
    begin
      First := Codes[Index] shl (9 - Lengths[Index]);
      for Fill := 0 to (1 shl (9 - Lengths[Index])) - 1 do
        Table.Lookup[First + Fill] := (Lengths[Index] shl 8) or Table.Symbols[Index];
    end;
  Table.Defined := True;
  Result := True;
end;

procedure StartBitReader(out Reader: TJpegBitReader; Data: PByte; Size, Position: PtrInt);
begin
  Reader.Data := Data;
  Reader.Size := Size;
  Reader.Position := Position;
  Reader.Buffer := 0;
  Reader.BitCount := 0;
  Reader.InjectedBytes := 0;
  Reader.MarkerReached := False;
  Reader.Corrupt := False;
end;

procedure FillBitReader(var Reader: TJpegBitReader);
var
  Value: LongWord;
  Position: PtrInt;
begin
  Position := Reader.Position;
  while Reader.BitCount <= 56 do
  begin
    if Reader.MarkerReached or (Position >= Reader.Size) then
    begin
      Value := 0;
      Inc(Reader.InjectedBytes);
    end
    else
    begin
      Value := Reader.Data[Position];
      if Value <> $FF then
        Inc(Position)
      else if (Position + 1 < Reader.Size) and (Reader.Data[Position + 1] = 0) then
        Inc(Position, 2)
      else
      begin
        Reader.MarkerReached := True;
        Value := 0;
        Inc(Reader.InjectedBytes);
      end;
    end;
    Reader.Buffer := Reader.Buffer or (QWord(Value) shl (56 - Reader.BitCount));
    Inc(Reader.BitCount, 8);
  end;
  Reader.Position := Position;
end;

function DecodeHuffman(var Reader: TJpegBitReader; constref Table: THuffmanTable): LongInt;
var
  Entry: LongWord;
  Code: LongInt;
  CodeLength: LongInt;
begin
  if Reader.BitCount < 16 then
    FillBitReader(Reader);
  Entry := Table.Lookup[Reader.Buffer shr 55];
  if Entry <> 0 then
  begin
    CodeLength := Entry shr 8;
    Reader.Buffer := Reader.Buffer shl CodeLength;
    Dec(Reader.BitCount, CodeLength);
    Exit(Entry and $FF);
  end;
  CodeLength := 10;
  Code := LongInt(Reader.Buffer shr 54);
  while Code > Table.MaximumCode[CodeLength] do
  begin
    Inc(CodeLength);
    Code := LongInt(Reader.Buffer shr (64 - CodeLength));
  end;
  if CodeLength > 16 then
  begin
    Reader.Corrupt := True;
    Reader.Buffer := Reader.Buffer shl 16;
    Dec(Reader.BitCount, 16);
    Exit(0);
  end;
  Reader.Buffer := Reader.Buffer shl CodeLength;
  Dec(Reader.BitCount, CodeLength);
  Result := Table.Symbols[(Code + Table.ValueOffset[CodeLength]) and $FF];
end;

function ReadBits(var Reader: TJpegBitReader; Count: LongInt): LongInt;
begin
  if Count <= 0 then
    Exit(0);
  if Reader.BitCount < Count then
    FillBitReader(Reader);
  Result := LongInt(Reader.Buffer shr (64 - Count));
  Reader.Buffer := Reader.Buffer shl Count;
  Dec(Reader.BitCount, Count);
end;

function ReadBit(var Reader: TJpegBitReader): LongInt;
begin
  if Reader.BitCount < 1 then
    FillBitReader(Reader);
  Result := LongInt(Reader.Buffer shr 63);
  Reader.Buffer := Reader.Buffer shl 1;
  Dec(Reader.BitCount);
end;

function ReceiveAndExtend(var Reader: TJpegBitReader; Count: LongInt): LongInt;
begin
  if Count <= 0 then
    Exit(0);
  if Count > 16 then
  begin
    Reader.Corrupt := True;
    Exit(0);
  end;
  Result := ReadBits(Reader, Count);
  if Result < (1 shl (Count - 1)) then
    Result := Result - (1 shl Count) + 1;
end;

function BitReaderExhausted(constref Reader: TJpegBitReader): Boolean;
begin
  Result := Reader.InjectedBytes > 8;
end;

procedure RestartBitReader(var Reader: TJpegBitReader);
var
  Position: PtrInt;
  Next: Byte;
begin
  Reader.Buffer := 0;
  Reader.BitCount := 0;
  Reader.InjectedBytes := 0;
  Reader.MarkerReached := False;
  Position := Reader.Position;
  while Position + 1 < Reader.Size do
  begin
    if Reader.Data[Position] = $FF then
    begin
      Next := Reader.Data[Position + 1];
      if (Next >= $D0) and (Next <= $D7) then
      begin
        Inc(Position, 2);
        Break;
      end;
      if (Next <> 0) and (Next <> $FF) then
        Break;
    end;
    Inc(Position);
  end;
  Reader.Position := Position;
end;

end.
