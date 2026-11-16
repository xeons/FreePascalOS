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
  CompressionTest - checks libcompression on the host (make
  compression-test): Adler-32 and CRC-32 known answers; zlib's own
  output (raw, zlib and gzip; stored, fixed and dynamic blocks; several
  members) decompressed whole and in pieces; broken streams refused
  with the right error; damaged streams handled cleanly; round trips at
  every level; sizes against zlib's; the stream adapters; preset
  dictionaries and sync and full flushes, against zlib's and our own.

    CompressionTest [sample directory]

  With a directory, it also writes compressed samples there for
  check-with-zlib.py. Prints one line per check and the totals; exits
  with 1 if any failed.
}
program CompressionTest;

{$mode objfpc}
{$H+}

uses
  TestChecks,
  CompressionTest.Decoding,
  CompressionTest.Encoding,
  CompressionTest.Flushing;

begin
  TestChecksums;
  TestGoodVectors;
  TestBrokenVectors;
  TestGzipHeader;
  TestDecompressionStream;
  TestDamagedData;
  TestRoundTrips;
  TestRoundTripsInPieces;
  TestCompressedSizes;
  TestCompressionStream;
  TestGzipHeaderWriting;
  TestDictionaries;
  TestFlushes;
  if ParamCount >= 1 then
  begin
    WriteSamples(ParamStr(1));
    WriteDictionaryAndFlushSamples(ParamStr(1));
  end;
  FinishChecks('compression test');
end.
