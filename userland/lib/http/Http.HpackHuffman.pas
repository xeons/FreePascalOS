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
  HPACK's Huffman code (RFC 7541 section 5.2 and appendix B). The code
  of appendix B is canonical: codes of the same length are consecutive
  in symbol order and each length's first code follows the last code of
  the length before. So the table here is only the 257 code lengths
  (256 bytes and EOS); the codes are worked out from them on first use.

  Encoding packs the codes most significant bit first and pads the last
  byte with the high bits of EOS (ones). Decoding goes bit by bit
  through the canonical tables (first code and symbol offset per
  length); padding longer than seven bits, padding that is not all
  ones, and an EOS in the data are errors (section 5.2).

  Plain Pascal (the RTL only), checked on the host by tools/HttpTest
  (appendix C's strings, and every byte against libnghttp2 when the
  host has it).
}
unit Http.HpackHuffman;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

uses
  Http.ByteBuffers;

{ Bytes the text takes Huffman coded. }
function HuffmanEncodedLength(const Text: string): Integer;
procedure HuffmanEncode(const Text: string; var Output: THttpByteBuffer);
function HuffmanDecode(Data: PByte; Count: Integer; out Text: string): Boolean;

implementation

const
  SymbolCount = 257;
  EndOfString = 256;
  MaximumCodeLength = 30;

  CodeLengths: array[0..SymbolCount - 1] of Byte = (
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
  Codes: array[0..SymbolCount - 1] of LongWord;
  { Per length: the first code, how many codes, where they start in
    SortedSymbols. }
  FirstCode: array[0..MaximumCodeLength] of LongWord;
  CodeCount: array[0..MaximumCodeLength] of LongWord;
  SymbolOffset: array[0..MaximumCodeLength] of LongWord;
  SortedSymbols: array[0..SymbolCount - 1] of Word;
  TablesBuilt: Boolean = False;

procedure BuildTables;
var
  Length, Symbol, Position: Integer;
  Code: LongWord;
begin
  FillChar(CodeCount, SizeOf(CodeCount), 0);
  for Symbol := 0 to SymbolCount - 1 do
    Inc(CodeCount[CodeLengths[Symbol]]);
  Code := 0;
  Position := 0;
  for Length := 1 to MaximumCodeLength do
  begin
    FirstCode[Length] := Code;
    SymbolOffset[Length] := Position;
    for Symbol := 0 to SymbolCount - 1 do
      if CodeLengths[Symbol] = Length then
      begin
        Codes[Symbol] := Code;
        SortedSymbols[Position] := Symbol;
        Inc(Code);
        Inc(Position);
      end;
    Code := Code shl 1;
  end;
  ReadWriteBarrier;
  TablesBuilt := True;
end;

{ Built on first use (unit initialization does not run for every
  program that reaches this unit through a library). Two threads
  building at once write the same values. }
procedure EnsureTables; inline;
begin
  if not TablesBuilt then
    BuildTables;
end;

function HuffmanEncodedLength(const Text: string): Integer;
var
  Bits: QWord;
  Character: Char;
begin
  Bits := 0;
  for Character in Text do
    Bits := Bits + CodeLengths[Ord(Character)];
  Result := Integer((Bits + 7) div 8);
end;

procedure HuffmanEncode(const Text: string; var Output: THttpByteBuffer);
var
  Accumulator: QWord;
  Pending: Integer;
  Character: Char;
  Length: Integer;
begin
  EnsureTables;
  ReserveBuffer(Output, HuffmanEncodedLength(Text));
  Accumulator := 0;
  Pending := 0;
  for Character in Text do
  begin
    Length := CodeLengths[Ord(Character)];
    Accumulator := (Accumulator shl Length) or Codes[Ord(Character)];
    Inc(Pending, Length);
    while Pending >= 8 do
    begin
      Dec(Pending, 8);
      AppendByte(Output, Byte(Accumulator shr Pending));
    end;
    Accumulator := Accumulator and ((QWord(1) shl Pending) - 1);
  end;
  if Pending > 0 then
    AppendByte(Output, Byte((Accumulator shl (8 - Pending)) or ($FF shr Pending)));
end;

function HuffmanDecode(Data: PByte; Count: Integer; out Text: string): Boolean;
var
  Code: LongWord;
  Length, Index, Bit, OutputLength: Integer;
  Symbol: Word;
  Ones: Boolean;
begin
  EnsureTables;
  Text := '';
  SetLength(Text, Count * 8 div 5 + 1);
  OutputLength := 0;
  Code := 0;
  Length := 0;
  Ones := True;
  for Index := 0 to Count - 1 do
    for Bit := 7 downto 0 do
    begin
      Code := (Code shl 1) or ((Data[Index] shr Bit) and 1);
      Ones := Ones and (((Data[Index] shr Bit) and 1) = 1);
      Inc(Length);
      if Length > MaximumCodeLength then
        Exit(False);
      if Code - FirstCode[Length] < CodeCount[Length] then
      begin
        Symbol := SortedSymbols[SymbolOffset[Length] + Code - FirstCode[Length]];
        if Symbol = EndOfString then
          Exit(False);
        Inc(OutputLength);
        Text[OutputLength] := Chr(Symbol);
        Code := 0;
        Length := 0;
        Ones := True;
      end;
    end;
  SetLength(Text, OutputLength);
  { What is left must be padding: at most seven bits, all ones. }
  Result := (Length <= 7) and Ones;
end;

end.
