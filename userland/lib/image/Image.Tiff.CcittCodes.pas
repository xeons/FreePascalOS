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
  The codes of fax compression (ITU-T T.4 and T.6), as written in the
  recommendations, and lookup tables made from them.

  A run of one colour is coded as make-up codes (multiples of 64; above
  1728 the extended ones, the same for both colours) followed by one
  terminating code (0 to 63). Two-dimensional rows are coded in modes:
  pass, horizontal (two runs follow) and vertical (the change is 0 to
  3 pixels left or right of the one above).

  The lookup tables are indexed by the next 13 bits (the longest run
  code); each entry gives the code's length (0: no code starts so) and
  its run, or its mode for the mode table (7 bits).
}
unit Image.Tiff.CcittCodes;

{$mode objfpc}
{$H+}

interface

type
  TCcittCode = record
    Run: LongInt;
    Code: string[13];
  end;

  TCcittMode = (CcittModeNone, CcittModePass, CcittModeHorizontal, CcittModeVertical0, CcittModeVerticalRight1,
    CcittModeVerticalRight2, CcittModeVerticalRight3, CcittModeVerticalLeft1, CcittModeVerticalLeft2,
    CcittModeVerticalLeft3, CcittModeExtension);

  TCcittRunEntry = record
    Length: Byte;
    Run: Word;
  end;

  TCcittModeEntry = record
    Length: Byte;
    Mode: TCcittMode;
  end;

const
  CcittRunBits = 13;
  CcittModeBits = 7;
  { An end-of-line code: eleven zeros and a one. }
  CcittEndOfLineZeros = 11;

  WhiteCodes: array[0..90] of TCcittCode = (
    (Run: 0; Code: '00110101'), (Run: 1; Code: '000111'), (Run: 2; Code: '0111'), (Run: 3; Code: '1000'),
    (Run: 4; Code: '1011'), (Run: 5; Code: '1100'), (Run: 6; Code: '1110'), (Run: 7; Code: '1111'),
    (Run: 8; Code: '10011'), (Run: 9; Code: '10100'), (Run: 10; Code: '00111'), (Run: 11; Code: '01000'),
    (Run: 12; Code: '001000'), (Run: 13; Code: '000011'), (Run: 14; Code: '110100'), (Run: 15; Code: '110101'),
    (Run: 16; Code: '101010'), (Run: 17; Code: '101011'), (Run: 18; Code: '0100111'), (Run: 19; Code: '0001100'),
    (Run: 20; Code: '0001000'), (Run: 21; Code: '0010111'), (Run: 22; Code: '0000011'), (Run: 23; Code: '0000100'),
    (Run: 24; Code: '0101000'), (Run: 25; Code: '0101011'), (Run: 26; Code: '0010011'), (Run: 27; Code: '0100100'),
    (Run: 28; Code: '0011000'), (Run: 29; Code: '00000010'), (Run: 30; Code: '00000011'), (Run: 31; Code: '00011010'),
    (Run: 32; Code: '00011011'), (Run: 33; Code: '00010010'), (Run: 34; Code: '00010011'), (Run: 35; Code: '00010100'),
    (Run: 36; Code: '00010101'), (Run: 37; Code: '00010110'), (Run: 38; Code: '00010111'), (Run: 39; Code: '00101000'),
    (Run: 40; Code: '00101001'), (Run: 41; Code: '00101010'), (Run: 42; Code: '00101011'), (Run: 43; Code: '00101100'),
    (Run: 44; Code: '00101101'), (Run: 45; Code: '00000100'), (Run: 46; Code: '00000101'), (Run: 47; Code: '00001010'),
    (Run: 48; Code: '00001011'), (Run: 49; Code: '01010010'), (Run: 50; Code: '01010011'), (Run: 51; Code: '01010100'),
    (Run: 52; Code: '01010101'), (Run: 53; Code: '00100100'), (Run: 54; Code: '00100101'), (Run: 55; Code: '01011000'),
    (Run: 56; Code: '01011001'), (Run: 57; Code: '01011010'), (Run: 58; Code: '01011011'), (Run: 59; Code: '01001010'),
    (Run: 60; Code: '01001011'), (Run: 61; Code: '00110010'), (Run: 62; Code: '00110011'), (Run: 63; Code: '00110100'),
    (Run: 64; Code: '11011'), (Run: 128; Code: '10010'), (Run: 192; Code: '010111'), (Run: 256; Code: '0110111'),
    (Run: 320; Code: '00110110'), (Run: 384; Code: '00110111'), (Run: 448; Code: '01100100'),
    (Run: 512; Code: '01100101'), (Run: 576; Code: '01101000'), (Run: 640; Code: '01100111'),
    (Run: 704; Code: '011001100'), (Run: 768; Code: '011001101'), (Run: 832; Code: '011010010'),
    (Run: 896; Code: '011010011'), (Run: 960; Code: '011010100'), (Run: 1024; Code: '011010101'),
    (Run: 1088; Code: '011010110'), (Run: 1152; Code: '011010111'), (Run: 1216; Code: '011011000'),
    (Run: 1280; Code: '011011001'), (Run: 1344; Code: '011011010'), (Run: 1408; Code: '011011011'),
    (Run: 1472; Code: '010011000'), (Run: 1536; Code: '010011001'), (Run: 1600; Code: '010011010'),
    (Run: 1664; Code: '011000'), (Run: 1728; Code: '010011011'));

  BlackCodes: array[0..90] of TCcittCode = (
    (Run: 0; Code: '0000110111'), (Run: 1; Code: '010'), (Run: 2; Code: '11'), (Run: 3; Code: '10'),
    (Run: 4; Code: '011'), (Run: 5; Code: '0011'), (Run: 6; Code: '0010'), (Run: 7; Code: '00011'),
    (Run: 8; Code: '000101'), (Run: 9; Code: '000100'), (Run: 10; Code: '0000100'), (Run: 11; Code: '0000101'),
    (Run: 12; Code: '0000111'), (Run: 13; Code: '00000100'), (Run: 14; Code: '00000111'),
    (Run: 15; Code: '000011000'), (Run: 16; Code: '0000010111'), (Run: 17; Code: '0000011000'),
    (Run: 18; Code: '0000001000'), (Run: 19; Code: '00001100111'), (Run: 20; Code: '00001101000'),
    (Run: 21; Code: '00001101100'), (Run: 22; Code: '00000110111'), (Run: 23; Code: '00000101000'),
    (Run: 24; Code: '00000010111'), (Run: 25; Code: '00000011000'), (Run: 26; Code: '000011001010'),
    (Run: 27; Code: '000011001011'), (Run: 28; Code: '000011001100'), (Run: 29; Code: '000011001101'),
    (Run: 30; Code: '000001101000'), (Run: 31; Code: '000001101001'), (Run: 32; Code: '000001101010'),
    (Run: 33; Code: '000001101011'), (Run: 34; Code: '000011010010'), (Run: 35; Code: '000011010011'),
    (Run: 36; Code: '000011010100'), (Run: 37; Code: '000011010101'), (Run: 38; Code: '000011010110'),
    (Run: 39; Code: '000011010111'), (Run: 40; Code: '000001101100'), (Run: 41; Code: '000001101101'),
    (Run: 42; Code: '000011011010'), (Run: 43; Code: '000011011011'), (Run: 44; Code: '000001010100'),
    (Run: 45; Code: '000001010101'), (Run: 46; Code: '000001010110'), (Run: 47; Code: '000001010111'),
    (Run: 48; Code: '000001100100'), (Run: 49; Code: '000001100101'), (Run: 50; Code: '000001010010'),
    (Run: 51; Code: '000001010011'), (Run: 52; Code: '000000100100'), (Run: 53; Code: '000000110111'),
    (Run: 54; Code: '000000111000'), (Run: 55; Code: '000000100111'), (Run: 56; Code: '000000101000'),
    (Run: 57; Code: '000001011000'), (Run: 58; Code: '000001011001'), (Run: 59; Code: '000000101011'),
    (Run: 60; Code: '000000101100'), (Run: 61; Code: '000001011010'), (Run: 62; Code: '000001100110'),
    (Run: 63; Code: '000001100111'),
    (Run: 64; Code: '0000001111'), (Run: 128; Code: '000011001000'), (Run: 192; Code: '000011001001'),
    (Run: 256; Code: '000001011011'), (Run: 320; Code: '000000110011'), (Run: 384; Code: '000000110100'),
    (Run: 448; Code: '000000110101'), (Run: 512; Code: '0000001101100'), (Run: 576; Code: '0000001101101'),
    (Run: 640; Code: '0000001001010'), (Run: 704; Code: '0000001001011'), (Run: 768; Code: '0000001001100'),
    (Run: 832; Code: '0000001001101'), (Run: 896; Code: '0000001110010'), (Run: 960; Code: '0000001110011'),
    (Run: 1024; Code: '0000001110100'), (Run: 1088; Code: '0000001110101'), (Run: 1152; Code: '0000001110110'),
    (Run: 1216; Code: '0000001110111'), (Run: 1280; Code: '0000001010010'), (Run: 1344; Code: '0000001010011'),
    (Run: 1408; Code: '0000001010100'), (Run: 1472; Code: '0000001010101'), (Run: 1536; Code: '0000001011010'),
    (Run: 1600; Code: '0000001011011'), (Run: 1664; Code: '0000001100100'), (Run: 1728; Code: '0000001100101'));

  { The same for white and black. }
  ExtendedMakeUpCodes: array[0..12] of TCcittCode = (
    (Run: 1792; Code: '00000001000'), (Run: 1856; Code: '00000001100'), (Run: 1920; Code: '00000001101'),
    (Run: 1984; Code: '000000010010'), (Run: 2048; Code: '000000010011'), (Run: 2112; Code: '000000010100'),
    (Run: 2176; Code: '000000010101'), (Run: 2240; Code: '000000010110'), (Run: 2304; Code: '000000010111'),
    (Run: 2368; Code: '000000011100'), (Run: 2432; Code: '000000011101'), (Run: 2496; Code: '000000011110'),
    (Run: 2560; Code: '000000011111'));

type
  TCcittRunTable = array[0..(1 shl CcittRunBits) - 1] of TCcittRunEntry;
  TCcittModeTable = array[0..(1 shl CcittModeBits) - 1] of TCcittModeEntry;
  PCcittRunTable = ^TCcittRunTable;
  PCcittModeTable = ^TCcittModeTable;

{ The tables, made the first time they are asked for. }
function WhiteRunTable: PCcittRunTable;
function BlackRunTable: PCcittRunTable;
function ModeTable: PCcittModeTable;

implementation

var
  TablesMade: Boolean = False;
  WhiteTable: TCcittRunTable;
  BlackTable: TCcittRunTable;
  Modes: TCcittModeTable;

function CodeValue(const Code: ShortString): LongWord;
var
  Index: LongInt;
begin
  Result := 0;
  for Index := 1 to Length(Code) do
    Result := (Result shl 1) or LongWord(Ord(Code[Index]) - Ord('0'));
end;

procedure AddRunCode(var Table: TCcittRunTable; const Code: TCcittCode);
var
  CodeLength: LongInt;
  First: LongWord;
  Count: LongWord;
  Index: LongWord;
begin
  CodeLength := Length(Code.Code);
  First := CodeValue(Code.Code) shl (CcittRunBits - CodeLength);
  Count := LongWord(1) shl (CcittRunBits - CodeLength);
  Index := 0;
  while Index < Count do
  begin
    Table[First + Index].Length := CodeLength;
    Table[First + Index].Run := Code.Run;
    Inc(Index);
  end;
end;

procedure AddModeCode(const Code: ShortString; Mode: TCcittMode);
var
  CodeLength: LongInt;
  First: LongWord;
  Count: LongWord;
  Index: LongWord;
begin
  CodeLength := Length(Code);
  First := CodeValue(Code) shl (CcittModeBits - CodeLength);
  Count := LongWord(1) shl (CcittModeBits - CodeLength);
  Index := 0;
  while Index < Count do
  begin
    Modes[First + Index].Length := CodeLength;
    Modes[First + Index].Mode := Mode;
    Inc(Index);
  end;
end;

procedure MakeTables;
var
  Index: LongInt;
begin
  FillChar(WhiteTable, SizeOf(WhiteTable), 0);
  FillChar(BlackTable, SizeOf(BlackTable), 0);
  FillChar(Modes, SizeOf(Modes), 0);
  for Index := Low(WhiteCodes) to High(WhiteCodes) do
    AddRunCode(WhiteTable, WhiteCodes[Index]);
  for Index := Low(BlackCodes) to High(BlackCodes) do
    AddRunCode(BlackTable, BlackCodes[Index]);
  for Index := Low(ExtendedMakeUpCodes) to High(ExtendedMakeUpCodes) do
  begin
    AddRunCode(WhiteTable, ExtendedMakeUpCodes[Index]);
    AddRunCode(BlackTable, ExtendedMakeUpCodes[Index]);
  end;
  AddModeCode('0001', CcittModePass);
  AddModeCode('001', CcittModeHorizontal);
  AddModeCode('1', CcittModeVertical0);
  AddModeCode('011', CcittModeVerticalRight1);
  AddModeCode('000011', CcittModeVerticalRight2);
  AddModeCode('0000011', CcittModeVerticalRight3);
  AddModeCode('010', CcittModeVerticalLeft1);
  AddModeCode('000010', CcittModeVerticalLeft2);
  AddModeCode('0000010', CcittModeVerticalLeft3);
  { 0000001xxx: extensions (uncompressed mode), told apart by length. }
  AddModeCode('0000001', CcittModeExtension);
  TablesMade := True;
end;

function WhiteRunTable: PCcittRunTable;
begin
  if not TablesMade then
    MakeTables;
  Result := @WhiteTable;
end;

function BlackRunTable: PCcittRunTable;
begin
  if not TablesMade then
    MakeTables;
  Result := @BlackTable;
end;

function ModeTable: PCcittModeTable;
begin
  if not TablesMade then
    MakeTables;
  Result := @Modes;
end;

end.
