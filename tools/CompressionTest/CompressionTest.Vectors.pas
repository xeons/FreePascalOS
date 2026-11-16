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
  The known answers: CompressionTest.Vectors.inc, written at build time
  by make-vectors.py with Python's zlib.
}
unit CompressionTest.Vectors;

{$mode objfpc}
{$H+}

interface

uses
  Compression.Errors,
  Compression.Formats,
  CompressionTest.Data;

type
  { Data zlib compressed: what it must decompress to is made again by
    MakeData(Kind, Size, Seed), whose checksums are Crc and Adler. }
  TGoodVector = record
    Name: PChar;
    Format: TCompressionFormat;
    Kind: TDataKind;
    Size: Integer;
    Seed: LongWord;
    Crc: LongWord;
    Adler: LongWord;
    Compressed: PChar;
  end;

  { Broken data and the error it must give. }
  TBrokenVector = record
    Name: PChar;
    Format: TCompressionFormat;
    Expected: TCompressionError;
    Compressed: PChar;
  end;

  { Data zlib compressed with a preset dictionary of
    MakeData(DataText, DictionarySize, DictionarySeed), whose Adler-32 is
    DictionaryId. }
  TDictionaryVector = record
    Name: PChar;
    Format: TCompressionFormat;
    Kind: TDataKind;
    Size: Integer;
    Seed: LongWord;
    DictionarySize: Integer;
    DictionarySeed: LongWord;
    DictionaryId: LongWord;
    Compressed: PChar;
  end;

  { zlib data with flush points: "compressed length:input length:full"
    separated by commas (full is 1 after a full flush, 0 after a sync
    flush). }
  TFlushVector = record
    Name: PChar;
    Kind: TDataKind;
    Size: Integer;
    Seed: LongWord;
    Points: PChar;
    Compressed: PChar;
  end;

{$I CompressionTest.Vectors.inc}

implementation

end.
