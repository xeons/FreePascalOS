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
  Decompression checks: the checksums' known answers, zlib's output
  decompressed whole and in pieces of every kind, broken streams giving
  the right error whole and a byte at a time, the gzip header's fields,
  the stream adapter, and damaged data that must be refused or
  decompressed but never crash.
}
unit CompressionTest.Decoding;

{$mode objfpc}
{$H+}

interface

procedure TestChecksums;
procedure TestGoodVectors;
procedure TestBrokenVectors;
procedure TestGzipHeader;
procedure TestDecompressionStream;
procedure TestDamagedData;

implementation

uses
  Classes,
  SysUtils,
  Math,
  TestChecks,
  Compression.Errors,
  Compression.Formats,
  Compression.Checksums,
  Compression.GzipFormat,
  Compression.Inflater,
  Compression.Buffers,
  Compression.Streams,
  CompressionTest.Data,
  CompressionTest.Vectors,
  CompressionTest.Pieces;

function TextData(const Text: string): TBytes;
begin
  Result := nil;
  SetLength(Result, Length(Text));
  if Length(Text) > 0 then
    Move(Text[1], Result[0], Length(Text));
end;

procedure TestChecksums;
var
  Filled: TBytes;
  Adler: LongWord;
  Crc: LongWord;
  Position: Integer;
  Piece: Integer;
begin
  Check(Crc32OfBytes(TextData('123456789')) = $CBF43926, 'CRC-32 of "123456789"');
  Check(Crc32OfBytes(TextData('The quick brown fox jumps over the lazy dog')) = $414FA339, 'CRC-32 of the fox');
  Check(Crc32OfBytes(nil) = 0, 'CRC-32 of nothing');
  Check(Adler32OfBytes(TextData('Wikipedia')) = $11E60398, 'Adler-32 of "Wikipedia"');
  Check(Adler32OfBytes(TextData('The quick brown fox jumps over the lazy dog')) = $5BDC0FDA, 'Adler-32 of the fox');
  Check(Adler32OfBytes(nil) = 1, 'Adler-32 of nothing');

  Filled := nil;
  SetLength(Filled, 1000000);
  FillChar(Filled[0], Length(Filled), $FF);
  Check(Adler32OfBytes(Filled) = FilledAdler, 'Adler-32 of a million $FF bytes');
  Check(Crc32OfBytes(Filled) = FilledCrc, 'CRC-32 of a million $FF bytes');
  Adler := Adler32Initial;
  Crc := Crc32Initial;
  Position := 0;
  Piece := 1;
  while Position < Length(Filled) do
  begin
    if Piece > Length(Filled) - Position then
      Piece := Length(Filled) - Position;
    Adler := Adler32(Adler, @Filled[Position], Piece);
    Crc := Crc32(Crc, @Filled[Position], Piece);
    Inc(Position, Piece);
    Piece := (Piece * 7 + 3) mod 9001 + 1;
  end;
  Check(Adler = FilledAdler, 'Adler-32 fed in pieces');
  Check(Crc = FilledCrc, 'CRC-32 fed in pieces');
end;

function DecompressWhole(const Compressed: TBytes; Format: TCompressionFormat; out Error: TCompressionError): TBytes;
begin
  Result := nil;
  Error := CompressionErrorNone;
  try
    Result := DecompressBytes(Compressed, Format);
  except
    on Failure: ECompressionError do
      Error := Failure.Code;
  end;
end;

procedure CheckPieces(const Name: string; const Compressed: TBytes; Format: TCompressionFormat;
  const Expected: TBytes; const Sizes: TPieceSizes; const SizesName: string);
var
  Output: TBytes;
  Error: TCompressionError;
begin
  Output := DecompressInPieces(Compressed, Format, Sizes, Error);
  Check((Error = CompressionErrorNone) and SameData(Output, Expected), Name + ', ' + SizesName);
end;

procedure TestGoodVectors;
var
  Index: Integer;
  Vector: TGoodVector;
  Expected: TBytes;
  Compressed: TBytes;
  Output: TBytes;
  Error: TCompressionError;
  Name: string;
begin
  for Index := Low(GoodVectors) to High(GoodVectors) do
  begin
    Vector := GoodVectors[Index];
    Name := Vector.Name;
    Expected := MakeData(Vector.Kind, Vector.Size, Vector.Seed);
    Check((Crc32OfBytes(Expected) = Vector.Crc) and (Adler32OfBytes(Expected) = Vector.Adler),
      Name + ': the test data is made as in Python');
    Compressed := HexToData(Vector.Compressed);
    Output := DecompressWhole(Compressed, Vector.Format, Error);
    Check((Error = CompressionErrorNone) and SameData(Output, Expected), Name + ', whole');
    if Error <> CompressionErrorNone then
      WriteLn('     error: ', CompressionErrorMessage(Error));
    CheckPieces(Name, Compressed, Vector.Format, Expected, Pieces(1, 1, False), 'a byte at a time');
    CheckPieces(Name, Compressed, Vector.Format, Expected, Pieces(1, 100000, False), 'input a byte at a time');
    CheckPieces(Name, Compressed, Vector.Format, Expected, Pieces(100000, 1, False), 'output a byte at a time');
    CheckPieces(Name, Compressed, Vector.Format, Expected, Pieces(37, 1000, True), 'varying small pieces');
    CheckPieces(Name, Compressed, Vector.Format, Expected, Pieces(5000, 70000, True), 'varying large pieces');
  end;
end;

procedure TestBrokenVectors;
var
  Index: Integer;
  Vector: TBrokenVector;
  Compressed: TBytes;
  Error: TCompressionError;
  Name: string;
begin
  for Index := Low(BrokenVectors) to High(BrokenVectors) do
  begin
    Vector := BrokenVectors[Index];
    Name := Vector.Name;
    Compressed := HexToData(Vector.Compressed);
    DecompressWhole(Compressed, Vector.Format, Error);
    Check(Error = Vector.Expected, Name + ' refused');
    if Error <> Vector.Expected then
      WriteLn('     got: ', CompressionErrorMessage(Error));
    DecompressInPieces(Compressed, Vector.Format, Pieces(1, 1, False), Error);
    Check(Error = Vector.Expected, Name + ' refused a byte at a time');
    DecompressInPieces(Compressed, Vector.Format, Pieces(3, 5, True), Error);
    Check(Error = Vector.Expected, Name + ' refused in small pieces');
  end;
end;

procedure TestGzipHeader;
var
  Compressed: TBytes;
  Output: TBytes;
  Inflater: TInflater;
  Header: TGzipHeader;
  Written: SizeInt;
  Outcome: TInflateResult;
begin
  Compressed := HexToData(GzipHeaderVector);
  Output := nil;
  SetLength(Output, 2 * GzipHeaderVectorSize);
  Inflater := TInflater.Create(FormatGzip);
  try
    Inflater.SetInput(@Compressed[0], Length(Compressed));
    Outcome := Inflater.Decompress(@Output[0], Length(Output), Written);
    Check(Outcome = InflateFinished, 'gzip with every header field decompresses');
    SetLength(Output, Written);
    Check(SameData(Output, MakeData(DataText, GzipHeaderVectorSize, GzipHeaderVectorSeed)),
      'gzip with every header field: the data');
    Header := Inflater.GzipHeader;
    Check(Header.FileName = 'hello.txt', 'gzip header: file name');
    Check(Header.Comment = 'a comment', 'gzip header: comment');
    Check(Header.ModificationTime = 1700000000, 'gzip header: modification time');
    Check(Header.OperatingSystem = 3, 'gzip header: operating system');
    Check(Header.HasExtra and SameData(Header.Extra, HexToData('41420400deadbeef')), 'gzip header: extra field');
    Check(Header.HasHeaderCrc, 'gzip header: header CRC');
    Check(Inflater.MemberCount = 1, 'gzip header: one member');
  finally
    Inflater.Free;
  end;
end;

function FindVector(const Name: string): TGoodVector;
var
  Index: Integer;
begin
  Result := GoodVectors[0];
  for Index := Low(GoodVectors) to High(GoodVectors) do
    if GoodVectors[Index].Name = Name then
      Result := GoodVectors[Index];
end;

procedure TestDecompressionStream;
var
  Vector: TGoodVector;
  Expected: TBytes;
  Compressed: TBytes;
  Output: TBytes;
  Source: TMemoryStream;
  Reader: TDecompressionStream;
  Count: Integer;
  Used: Integer;
  Failed: Boolean;
begin
  Vector := FindVector('gzip two members');
  Expected := MakeData(Vector.Kind, Vector.Size, Vector.Seed);
  Compressed := HexToData(Vector.Compressed);
  Source := TMemoryStream.Create;
  try
    Source.WriteBuffer(Compressed[0], Length(Compressed));
    Source.Position := 0;
    Reader := TDecompressionStream.Create(Source, FormatAutomatic);
    try
      Output := nil;
      SetLength(Output, Length(Expected) + 100);
      Used := 0;
      { Pieces of 777 bytes, each no larger than the room left, until the
        stream ends (or the buffer, larger than the data, would overflow). }
      repeat
        Count := Reader.Read(Output[Used], Min(777, Length(Output) - Used));
        Inc(Used, Count);
      until (Count = 0) or (Used = Length(Output));
      SetLength(Output, Used);
      Check(SameData(Output, Expected), 'decompression stream over two gzip members');
      Check(Reader.Seek(0, soCurrent) = Length(Expected), 'decompression stream position');
    finally
      Reader.Free;
    end;
  finally
    Source.Free;
  end;

  { zlib data with more after it: the source is left just after it. }
  Vector := FindVector('DataText zlib level 6');
  Expected := MakeData(Vector.Kind, Vector.Size, Vector.Seed);
  Compressed := HexToData(Vector.Compressed);
  Source := TMemoryStream.Create;
  try
    Source.WriteBuffer(Compressed[0], Length(Compressed));
    Source.WriteBuffer(PChar('more')^, 4);
    Source.Position := 0;
    Reader := TDecompressionStream.Create(Source, FormatZlib);
    try
      Output := nil;
      SetLength(Output, Length(Expected) + 10);
      Count := Reader.Read(Output[0], Length(Output));
      SetLength(Output, Count);
      Check(SameData(Output, Expected), 'decompression stream over zlib data with more after it');
      Check(Source.Position = Length(Compressed), 'decompression stream leaves the source after the data');
    finally
      Reader.Free;
    end;
  finally
    Source.Free;
  end;

  { Cut off data raises. }
  Source := TMemoryStream.Create;
  try
    Source.WriteBuffer(Compressed[0], Length(Compressed) div 2);
    Source.Position := 0;
    Reader := TDecompressionStream.Create(Source, FormatZlib);
    try
      Output := nil;
      SetLength(Output, Length(Expected));
      Failed := False;
      try
        Reader.Read(Output[0], Length(Output));
      except
        on Failure: ECompressionError do
          Failed := Failure.Code = CompressionErrorTruncated;
      end;
      Check(Failed, 'decompression stream raises on cut off data');
    finally
      Reader.Free;
    end;
  finally
    Source.Free;
  end;
end;

{ Every vector, damaged in many ways (bits flipped, bytes changed, cut
  short): whatever comes out, the decoder must stop cleanly. }
procedure TestDamagedData;
var
  Generator: TNumberGenerator;
  Index: Integer;
  Round: Integer;
  Compressed: TBytes;
  Damaged: TBytes;
  Position: Integer;
  Handled: Integer;
  Total: Integer;
  Output: TBytes;
  Error: TCompressionError;
begin
  StartGenerator(Generator, 2026);
  Handled := 0;
  Total := 0;
  for Index := Low(GoodVectors) to High(GoodVectors) do
  begin
    Compressed := HexToData(GoodVectors[Index].Compressed);
    if Length(Compressed) = 0 then
      Continue;
    for Round := 1 to 40 do
    begin
      Damaged := Copy(Compressed, 0, Length(Compressed));
      Position := NextNumber(Generator) mod LongWord(Length(Damaged));
      case Round mod 4 of
        0: Damaged[Position] := Damaged[Position] xor (1 shl (NextNumber(Generator) mod 8));
        1: Damaged[Position] := NextNumber(Generator) and $FF;
        2: SetLength(Damaged, Position);
      else
        begin
          Damaged[Position] := Damaged[Position] xor $FF;
          Position := NextNumber(Generator) mod LongWord(Length(Damaged));
          Damaged[Position] := Damaged[Position] xor $55;
        end;
      end;
      Inc(Total);
      try
        Output := DecompressBytes(Damaged, GoodVectors[Index].Format, 4 * 1024 * 1024);
        Inc(Handled);
      except
        on ECompressionError do
          Inc(Handled);
      end;
      if Round mod 8 = 0 then
        DecompressInPieces(Damaged, GoodVectors[Index].Format, Pieces(13, 4096, True), Error);
    end;
  end;
  Check(Handled = Total, Format('%d damaged streams handled cleanly', [Total]));
end;

end.
