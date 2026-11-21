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
  Brotli's static dictionary (RFC 7932 section 8): runs of words of 4 to
  24 bytes, 1 shl BrotliWordBits[Length] words of each length.

  The bytes are Compression.BrotliDictionaryData.inc, written once by
  make-brotli-dictionary.py from the host's brotli library and checked
  in (see that script); tools/CompressionTest checks their CRC-32.
}
unit Compression.BrotliDictionary;

{$mode objfpc}
{$H+}

interface

{$I Compression.BrotliDictionaryData.inc}

const
  BrotliShortestWord = 4;
  BrotliLongestWord = 24;

  { NDBITS: how many words of each length, as a power of two. }
  BrotliWordBits: array[0..BrotliLongestWord] of Byte = (
    0, 0, 0, 0, 10, 10, 11, 11, 10, 10, 10, 10, 10, 9, 9, 8, 7, 7, 8, 7, 7, 6, 6, 5, 5);

  { DOFFSET: where the words of each length start. }
  BrotliWordOffsets: array[0..BrotliLongestWord] of LongWord = (
    0, 0, 0, 0, 0, 4096, 9216, 21504, 35840, 44032, 53248, 63488, 74752, 87040, 93696, 100864, 104704,
    106752, 108928, 113536, 115968, 118528, 119872, 121280, 122016);

{ Word Index of the given length (4 to 24; Index below the count). }
function BrotliDictionaryWord(Length: Integer; Index: LongWord): PByte;

implementation

function BrotliDictionaryWord(Length: Integer; Index: LongWord): PByte;
begin
  Result := @BrotliDictionaryData[BrotliWordOffsets[Length] + Index * LongWord(Length)];
end;

end.
