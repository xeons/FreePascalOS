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
  The constants of the deflate format (RFC 1951 section 3.2): the
  alphabets, what each length and distance code stands for, the order of
  the code length code's lengths, and the fixed Huffman codes.
}
unit Compression.DeflateFormat;

{$mode objfpc}
{$H+}

interface

const
  WindowSize = 32768;
  MinimumMatch = 3;
  MaximumMatch = 258;
  MaximumCodeLength = 15;
  MaximumCodeLengthCodeLength = 7;

  { The block types in a block header. }
  BlockStored = 0;
  BlockFixed = 1;
  BlockDynamic = 2;

  { The literal/length alphabet: literals, the end of a block, lengths.
    Codes 286 and 287 exist in the fixed code but never occur. }
  EndOfBlockSymbol = 256;
  FirstLengthSymbol = 257;
  LiteralLengthSymbols = 288;
  UsableLiteralLengthSymbols = 286;
  DistanceSymbols = 32;
  UsableDistanceSymbols = 30;
  CodeLengthSymbols = 19;
  LengthCodeCount = 29;

  { The code length code's symbols: 0..15 are lengths, these repeat. }
  RepeatPreviousSymbol = 16;
  RepeatZeroShortSymbol = 17;
  RepeatZeroLongSymbol = 18;

  LengthBase: array[0..28] of Word = (
    3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31,
    35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258);
  LengthExtraBits: array[0..28] of Byte = (
    0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2,
    3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0);
  DistanceBase: array[0..29] of Word = (
    1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193,
    257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577);
  DistanceExtraBits: array[0..29] of Byte = (
    0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6,
    7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13);

  CodeLengthOrder: array[0..CodeLengthSymbols - 1] of Byte = (
    16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15);

type
  TLiteralLengthCodeLengths = array[0..LiteralLengthSymbols - 1] of Byte;
  TDistanceCodeLengths = array[0..DistanceSymbols - 1] of Byte;

{ The lengths of the fixed codes (section 3.2.6). }
procedure GetFixedLiteralLengthCodeLengths(out Lengths: TLiteralLengthCodeLengths);
procedure GetFixedDistanceCodeLengths(out Lengths: TDistanceCodeLengths);

implementation

procedure GetFixedLiteralLengthCodeLengths(out Lengths: TLiteralLengthCodeLengths);
var
  Symbol: Integer;
begin
  for Symbol := 0 to LiteralLengthSymbols - 1 do
    case Symbol of
      0..143: Lengths[Symbol] := 8;
      144..255: Lengths[Symbol] := 9;
      256..279: Lengths[Symbol] := 7;
    else
      Lengths[Symbol] := 8;
    end;
end;

procedure GetFixedDistanceCodeLengths(out Lengths: TDistanceCodeLengths);
var
  Symbol: Integer;
begin
  for Symbol := 0 to DistanceSymbols - 1 do
    Lengths[Symbol] := 5;
end;

end.
