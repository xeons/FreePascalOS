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
  The Huffman code of HPACK (RFC 7541 appendix B), which QPACK uses for
  string literals too (RFC 9204 section 4.1.2).

  The code is canonical: codes of one length are consecutive numbers in
  symbol order, and each length's first code follows from the shorter
  ones. So only the 257 code lengths are kept here, and the codes and
  the decoding tables are worked out from them once (FirstCode and the
  symbols sorted by length): decoding goes bit by bit, comparing the
  code read so far with the first code of its length.

  A string decodes only when it ends in at most seven 1 bits (a prefix
  of EOS) and never holds EOS itself (section 5.2).
}
unit Qpack.Huffman;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

{ Bytes Text takes Huffman coded. }
function HuffmanEncodedLength(const Text: string): PtrUInt;
{ Appends Text Huffman coded (HuffmanEncodedLength bytes) at Output. }
procedure HuffmanEncode(const Text: string; Output: PByte);
{ False for a bad code, EOS inside, or bad padding. }
function HuffmanDecode(Data: PByte; Length: PtrUInt; out Text: string): Boolean;

implementation

const
  EndOfString = 256;
  MaximumCodeLength = 30;

  CodeLengths: array[0..256] of Byte = (
    13, 23, 28, 28, 28, 28, 28, 28, 28, 24, 30, 28, 28, 30, 28, 28,
    28, 28, 28, 28, 28, 28, 30, 28, 28, 28, 28, 28, 28, 28, 28, 28,
    6, 10, 10, 12, 13, 6, 8, 11, 10, 10, 8, 11, 8, 6, 6, 6,
    5, 5, 5, 6, 6, 6, 6, 6, 6, 6, 7, 8, 15, 6, 12, 10,
    13, 6, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7,
    7, 7, 7, 7, 7, 7, 7, 7, 8, 7, 8, 13, 19, 13, 14, 6,
    15, 5, 6, 5, 6, 5, 6, 6, 6, 5, 7, 7, 6, 6, 6, 5,
    6, 7, 6, 5, 5, 6, 7, 7, 7, 7, 7, 15, 11, 14, 13, 28,
    20, 22, 20, 20, 22, 22, 22, 23, 22, 23, 23, 23, 23, 23, 24, 23,
    24, 24, 22, 23, 24, 23, 23, 23, 23, 21, 22, 23, 22, 23, 23, 24,
    22, 21, 20, 22, 22, 23, 23, 21, 23, 22, 22, 24, 21, 22, 23, 23,
    21, 21, 22, 21, 23, 22, 23, 23, 20, 22, 22, 22, 23, 22, 22, 23,
    26, 26, 20, 19, 22, 23, 22, 25, 26, 26, 26, 27, 27, 26, 24, 25,
    19, 21, 26, 27, 27, 26, 27, 24, 21, 21, 26, 26, 28, 27, 27, 27,
    20, 24, 20, 21, 22, 21, 21, 23, 22, 22, 25, 25, 24, 24, 26, 23,
    26, 27, 26, 26, 27, 27, 27, 27, 27, 28, 27, 27, 27, 27, 27, 26,
    30);

var
  Codes: array[0..256] of LongWord;
  { Symbols sorted by code length (then symbol), and for each length
    its first code, where its symbols start in that list, and how many
    there are. }
  SortedSymbols: array[0..256] of Word;
  FirstCode: array[0..MaximumCodeLength] of LongWord;
  FirstIndex: array[0..MaximumCodeLength] of Integer;
  LengthCount: array[0..MaximumCodeLength] of Integer;
  TablesBuilt: Boolean = False;

procedure BuildTables;
var
  Bits, Symbol, Position: Integer;
  Code: LongWord;
begin
  Position := 0;
  Code := 0;
  for Bits := 1 to MaximumCodeLength do
  begin
    FirstCode[Bits] := Code;
    FirstIndex[Bits] := Position;
    LengthCount[Bits] := 0;
    for Symbol := 0 to EndOfString do
      if CodeLengths[Symbol] = Bits then
      begin
        Codes[Symbol] := Code;
        SortedSymbols[Position] := Symbol;
        Inc(Position);
        Inc(Code);
        Inc(LengthCount[Bits]);
      end;
    Code := Code shl 1;
  end;
  TablesBuilt := True;
end;

function HuffmanEncodedLength(const Text: string): PtrUInt;
var
  Index: Integer;
  Bits: QWord;
begin
  Bits := 0;
  if not TablesBuilt then
    BuildTables;
  for Index := 1 to Length(Text) do
    Bits := Bits + CodeLengths[Ord(Text[Index])];
  Result := (Bits + 7) div 8;
end;

procedure HuffmanEncode(const Text: string; Output: PByte);
var
  Index, Pending: Integer;
  Accumulator: QWord;
  Symbol: Byte;
begin
  if not TablesBuilt then
    BuildTables;
  Accumulator := 0;
  Pending := 0;
  for Index := 1 to Length(Text) do
  begin
    Symbol := Ord(Text[Index]);
    Accumulator := (Accumulator shl CodeLengths[Symbol]) or Codes[Symbol];
    Pending := Pending + CodeLengths[Symbol];
    while Pending >= 8 do
    begin
      Pending := Pending - 8;
      Output^ := Byte(Accumulator shr Pending);
      Inc(Output);
    end;
    Accumulator := Accumulator and ((QWord(1) shl Pending) - 1);
  end;
  if Pending > 0 then
    { Padded with the high bits of EOS (all ones). }
    Output^ := Byte((Accumulator shl (8 - Pending)) or ((1 shl (8 - Pending)) - 1));
end;

function HuffmanDecode(Data: PByte; Length: PtrUInt; out Text: string): Boolean;
var
  Code: LongWord;
  Bits, BitIndex, Written: Integer;
  ByteIndex: PtrUInt;
  Bit: LongWord;
  Symbol: Integer;
  AllOnes: Boolean;
begin
  if not TablesBuilt then
    BuildTables;
  Text := '';
  if Length = 0 then
    Exit(True);
  { Each symbol takes at least five bits. }
  SetLength(Text, (Length * 8) div 5 + 1);
  Written := 0;
  Code := 0;
  Bits := 0;
  AllOnes := True;
  for ByteIndex := 0 to Length - 1 do
    for BitIndex := 7 downto 0 do
    begin
      Bit := (Data[ByteIndex] shr BitIndex) and 1;
      Code := (Code shl 1) or Bit;
      Inc(Bits);
      if Bit = 0 then
        AllOnes := False;
      if (LengthCount[Bits] > 0) and (Code >= FirstCode[Bits]) and
         (Code - FirstCode[Bits] < LongWord(LengthCount[Bits])) then
      begin
        Symbol := SortedSymbols[FirstIndex[Bits] + Integer(Code - FirstCode[Bits])];
        if Symbol = EndOfString then
          Exit(False);
        Inc(Written);
        Text[Written] := Chr(Symbol);
        Code := 0;
        Bits := 0;
        AllOnes := True;
      end
      else if Bits >= MaximumCodeLength then
        Exit(False);
    end;
  { What is left must be padding: fewer than eight 1 bits. }
  if (Bits > 7) or not AllOnes then
    Exit(False);
  SetLength(Text, Written);
  Result := True;
end;

end.
