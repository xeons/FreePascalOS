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
  The fixed tables of brotli (RFC 7932):

    the insert and copy lengths of each insert-and-copy length code
      (section 5), worked out once into BrotliCommands;
    the block counts (section 6);
    the order the code length code lengths come in (section 3.5);
    the context of a literal from the two bytes before it, for each of
    the four context modes (section 7.1), worked out once from Lut0,
    Lut1 and Lut2 into BrotliContextLookup: the context is
    Lookup[Mode, P1] or Lookup[Mode, 256 + P2].
}
unit Compression.BrotliTables;

{$mode objfpc}
{$H+}

interface

const
  BrotliLiteralAlphabet = 256;
  BrotliCommandAlphabet = 704;
  BrotliBlockCountAlphabet = 26;
  BrotliCodeLengthAlphabet = 18;
  BrotliLiteralContexts = 64;
  BrotliDistanceContexts = 4;
  BrotliContextModes = 4;

  BrotliInsertLengthBases: array[0..23] of LongWord = (
    0, 1, 2, 3, 4, 5, 6, 8, 10, 14, 18, 26, 34, 50, 66, 98, 130, 194, 322, 578, 1090, 2114, 6210, 22594);
  BrotliInsertLengthExtraBits: array[0..23] of Byte = (
    0, 0, 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 7, 8, 9, 10, 12, 14, 24);
  BrotliCopyLengthBases: array[0..23] of LongWord = (
    2, 3, 4, 5, 6, 7, 8, 9, 10, 12, 14, 18, 22, 30, 38, 54, 70, 102, 134, 198, 326, 582, 1094, 2118);
  BrotliCopyLengthExtraBits: array[0..23] of Byte = (
    0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 7, 8, 9, 10, 24);

  BrotliBlockCountBases: array[0..BrotliBlockCountAlphabet - 1] of LongWord = (
    1, 5, 9, 13, 17, 25, 33, 41, 49, 65, 81, 97, 113, 145, 177, 209, 241, 305, 369, 497, 753, 1265, 2289,
    4337, 8433, 16625);
  BrotliBlockCountExtraBits: array[0..BrotliBlockCountAlphabet - 1] of Byte = (
    2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 6, 6, 7, 8, 9, 10, 11, 12, 13, 24);

  BrotliCodeLengthOrder: array[0..BrotliCodeLengthAlphabet - 1] of Byte = (
    1, 2, 3, 4, 0, 5, 17, 6, 16, 7, 8, 9, 10, 11, 12, 13, 14, 15);

  BrotliContextLsb6 = 0;
  BrotliContextMsb6 = 1;
  BrotliContextUtf8 = 2;
  BrotliContextSigned = 3;

  { The context lookup tables of section 7.1 (their CRC-32s: $8E91EFB7,
    $D01A32F4 and $0DD7A0D6, checked by tools/CompressionTest). }
  BrotliLut0: array[0..255] of Byte = (
     0,  0,  0,  0,  0,  0,  0,  0,  0,  4,  4,  0,  0,  4,  0,  0,
     0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,
     8, 12, 16, 12, 12, 20, 12, 16, 24, 28, 12, 12, 32, 12, 36, 12,
    44, 44, 44, 44, 44, 44, 44, 44, 44, 44, 32, 32, 24, 40, 28, 12,
    12, 48, 52, 52, 52, 48, 52, 52, 52, 48, 52, 52, 52, 52, 52, 48,
    52, 52, 52, 52, 52, 48, 52, 52, 52, 52, 52, 24, 12, 28, 12, 12,
    12, 56, 60, 60, 60, 56, 60, 60, 60, 56, 60, 60, 60, 60, 60, 56,
    60, 60, 60, 60, 60, 56, 60, 60, 60, 60, 60, 24, 12, 28, 12,  0,
     0,  1,  0,  1,  0,  1,  0,  1,  0,  1,  0,  1,  0,  1,  0,  1,
     0,  1,  0,  1,  0,  1,  0,  1,  0,  1,  0,  1,  0,  1,  0,  1,
     0,  1,  0,  1,  0,  1,  0,  1,  0,  1,  0,  1,  0,  1,  0,  1,
     0,  1,  0,  1,  0,  1,  0,  1,  0,  1,  0,  1,  0,  1,  0,  1,
     2,  3,  2,  3,  2,  3,  2,  3,  2,  3,  2,  3,  2,  3,  2,  3,
     2,  3,  2,  3,  2,  3,  2,  3,  2,  3,  2,  3,  2,  3,  2,  3,
     2,  3,  2,  3,  2,  3,  2,  3,  2,  3,  2,  3,  2,  3,  2,  3,
     2,  3,  2,  3,  2,  3,  2,  3,  2,  3,  2,  3,  2,  3,  2,  3);
  BrotliLut1: array[0..255] of Byte = (
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
    2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 1, 1, 1, 1, 1, 1,
    1, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2,
    2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 1, 1, 1, 1, 1,
    1, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3,
    3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 1, 1, 1, 1, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2,
    2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2);
  BrotliLut2: array[0..255] of Byte = (
    0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
    2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2,
    2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2,
    2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2,
    3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3,
    3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3,
    3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3,
    3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3,
    4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4,
    4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4,
    4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4,
    4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4,
    5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5,
    5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5,
    5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5,
    6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 7);

type
  { What an insert-and-copy length code stands for. }
  TBrotliCommand = record
    InsertBase: LongWord;
    CopyBase: LongWord;
    InsertExtraBits: Byte;
    CopyExtraBits: Byte;
    { The command reuses the last distance (codes 0 to 127). }
    ImplicitDistance: Boolean;
  end;

var
  BrotliCommands: array[0..BrotliCommandAlphabet - 1] of TBrotliCommand;
  BrotliContextLookup: array[0..BrotliContextModes - 1, 0..511] of Byte;

implementation

const
  { Each group of 64 codes: where its insert and copy codes start. }
  InsertCodeStarts: array[0..10] of Byte = (0, 0, 0, 0, 8, 8, 0, 16, 8, 16, 16);
  CopyCodeStarts: array[0..10] of Byte = (0, 8, 0, 8, 0, 8, 16, 0, 16, 8, 16);
  ImplicitDistanceCodes = 128;

procedure BuildCommands;
var
  Code: Integer;
  Group: Integer;
  InsertCode: Integer;
  CopyCode: Integer;
begin
  for Code := 0 to BrotliCommandAlphabet - 1 do
  begin
    Group := Code shr 6;
    InsertCode := InsertCodeStarts[Group] + ((Code shr 3) and 7);
    CopyCode := CopyCodeStarts[Group] + (Code and 7);
    BrotliCommands[Code].InsertBase := BrotliInsertLengthBases[InsertCode];
    BrotliCommands[Code].InsertExtraBits := BrotliInsertLengthExtraBits[InsertCode];
    BrotliCommands[Code].CopyBase := BrotliCopyLengthBases[CopyCode];
    BrotliCommands[Code].CopyExtraBits := BrotliCopyLengthExtraBits[CopyCode];
    BrotliCommands[Code].ImplicitDistance := Code < ImplicitDistanceCodes;
  end;
end;

procedure BuildContextLookup;
var
  Value: Integer;
begin
  for Value := 0 to 255 do
  begin
    BrotliContextLookup[BrotliContextLsb6, Value] := Value and $3F;
    BrotliContextLookup[BrotliContextLsb6, 256 + Value] := 0;
    BrotliContextLookup[BrotliContextMsb6, Value] := Value shr 2;
    BrotliContextLookup[BrotliContextMsb6, 256 + Value] := 0;
    BrotliContextLookup[BrotliContextUtf8, Value] := BrotliLut0[Value];
    BrotliContextLookup[BrotliContextUtf8, 256 + Value] := BrotliLut1[Value];
    BrotliContextLookup[BrotliContextSigned, Value] := BrotliLut2[Value] shl 3;
    BrotliContextLookup[BrotliContextSigned, 256 + Value] := BrotliLut2[Value];
  end;
end;

initialization
  BuildCommands;
  BuildContextLookup;
end.
