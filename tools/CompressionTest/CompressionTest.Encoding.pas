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
  Compression checks: round trips at every level over varied data in
  every format, whole and in pieces; sizes against zlib's on the same
  data; the stream adapter; gzip header fields written and read back.
  WriteSamples leaves compressed files for check-with-zlib.py, which
  decompresses them with Python's zlib and gzip.
}
unit CompressionTest.Encoding;

{$mode objfpc}
{$H+}

interface

procedure TestRoundTrips;
procedure TestRoundTripsInPieces;
procedure TestCompressedSizes;
procedure TestCompressionStream;
procedure TestGzipHeaderWriting;
procedure WriteSamples(const Directory: string);

implementation

uses
  Classes,
  SysUtils,
  TestChecks,
  Compression.Errors,
  Compression.Formats,
  Compression.GzipFormat,
  Compression.Inflater,
  Compression.Deflater,
  Compression.Buffers,
  Compression.Streams,
  CompressionTest.Data,
  CompressionTest.Vectors,
  CompressionTest.Pieces;

type
  TSampleData = record
    Name: string;
    Kind: TDataKind;
    Size: Integer;
    Seed: LongWord;
  end;

const
  Samples: array[0..9] of TSampleData = (
    (Name: 'empty'; Kind: DataText; Size: 0; Seed: 1),
    (Name: 'one byte'; Kind: DataRandom; Size: 1; Seed: 1),
    (Name: 'short text'; Kind: DataText; Size: 100; Seed: 9),
    (Name: 'text'; Kind: DataText; Size: 50000; Seed: 1),
    (Name: 'random'; Kind: DataRandom; Size: 20000; Seed: 2),
    (Name: 'random past a stored block'; Kind: DataRandom; Size: 140000; Seed: 3),
    (Name: 'runs'; Kind: DataRuns; Size: 100000; Seed: 3),
    (Name: 'blocks'; Kind: DataBlocks; Size: 300000; Seed: 4),
    (Name: 'window apart'; Kind: DataFar; Size: 100000; Seed: 5),
    (Name: 'zeros'; Kind: DataZeros; Size: 300000; Seed: 0)
  );

  FormatNames: array[TCompressionFormat] of string = ('raw', 'zlib', 'gzip', 'automatic');

function SampleData(const Sample: TSampleData): TBytes;
begin
  Result := MakeData(Sample.Kind, Sample.Size, Sample.Seed);
end;

function RoundTrips(const Data: TBytes; Format: TCompressionFormat; Level: Integer): Boolean;
var
  Compressed: TBytes;
begin
  try
    Compressed := CompressBytes(Data, Format, Level);
    Result := SameData(DecompressBytes(Compressed, Format), Data);
  except
    on ECompressionError do
      Result := False;
  end;
end;

procedure TestRoundTrips;
var
  SampleIndex: Integer;
  Level: Integer;
  Format: TCompressionFormat;
  Data: TBytes;
begin
  for SampleIndex := Low(Samples) to High(Samples) do
  begin
    Data := SampleData(Samples[SampleIndex]);
    for Level := CompressionLevelStore to CompressionLevelBest do
      for Format := FormatRaw to FormatGzip do
        Check(RoundTrips(Data, Format, Level), Samples[SampleIndex].Name + ', ' + FormatNames[Format] + ', level ' +
          IntToStr(Level));
  end;
end;

procedure TestRoundTripsInPieces;
var
  SampleIndex: Integer;
  Level: Integer;
  Data: TBytes;
  Compressed: TBytes;
  Output: TBytes;
  Error: TCompressionError;
  Name: string;
begin
  for SampleIndex := Low(Samples) to High(Samples) do
  begin
    Data := SampleData(Samples[SampleIndex]);
    for Level := CompressionLevelStore to CompressionLevelBest do
    begin
      if not (Level in [0, 1, 4, 6, 9]) then
        Continue;
      Name := Samples[SampleIndex].Name + ', level ' + IntToStr(Level);
      Compressed := CompressInPieces(Data, FormatZlib, Level, Pieces(3000, 100, True));
      Output := DecompressInPieces(Compressed, FormatZlib, Pieces(1000, 3000, True), Error);
      Check((Error = CompressionErrorNone) and SameData(Output, Data), Name + ', in varying pieces');
    end;
    Compressed := CompressInPieces(Data, FormatGzip, CompressionLevelDefault, Pieces(1, 1, False));
    Output := DecompressInPieces(Compressed, FormatGzip, Pieces(1, 1, False), Error);
    Check((Error = CompressionErrorNone) and SameData(Output, Data), Samples[SampleIndex].Name +
      ', gzip a byte at a time');
  end;
end;

function LevelInName(const Name: string; out Level: Integer): Boolean;
var
  Position: Integer;
begin
  Position := Pos('zlib level ', Name);
  Result := Position > 0;
  if Result then
    Level := StrToInt(Copy(Name, Position + Length('zlib level '), 2));
end;

{ Ours against zlib's, on the data of the vectors zlib made: within a
  tenth of the size (and a few bytes). }
procedure TestCompressedSizes;
var
  Index: Integer;
  Vector: TGoodVector;
  Level: Integer;
  Data: TBytes;
  OurSize: Integer;
  ZlibSize: Integer;
  Text: TBytes;
begin
  for Index := Low(GoodVectors) to High(GoodVectors) do
  begin
    Vector := GoodVectors[Index];
    if not LevelInName(Vector.Name, Level) then
      Continue;
    Data := MakeData(Vector.Kind, Vector.Size, Vector.Seed);
    OurSize := Length(CompressBytes(Data, FormatZlib, Level));
    ZlibSize := StrLen(Vector.Compressed) div 2;
    Check(OurSize <= ZlibSize + ZlibSize div 10 + 16, string(Vector.Name) + ': ' + IntToStr(OurSize) +
      ' bytes, zlib ' + IntToStr(ZlibSize));
  end;

  Text := MakeData(DataText, 50000, 1);
  Check(Length(CompressBytes(Text, FormatRaw, 9)) <= Length(CompressBytes(Text, FormatRaw, 1)),
    'level 9 no larger than level 1');
  Check(Length(CompressBytes(Text, FormatRaw, 1)) < Length(Text) div 3, 'level 1 compresses text');
  Data := MakeData(DataRandom, 140000, 3);
  Check(Length(CompressBytes(Data, FormatRaw, 0)) <= Length(Data) + 5 * (Length(Data) div 16384 + 2),
    'level 0 stores');
  for Level := 1 to 9 do
    Check(Length(CompressBytes(Data, FormatRaw, Level)) <= Length(Data) + 5 * (Length(Data) div 16384 + 2),
      'random data does not grow, level ' + IntToStr(Level));
  Data := MakeData(DataZeros, 300000, 0);
  Check(Length(CompressBytes(Data, FormatRaw, 6)) < 1000, 'zeros shrink to almost nothing');
end;

procedure TestCompressionStream;
var
  Data: TBytes;
  Target: TBytesStream;
  Writer: TCompressionStream;
  Position: Integer;
  Piece: Integer;
  Compressed: TBytes;
begin
  Data := MakeData(DataBlocks, 120000, 7);
  Target := TBytesStream.Create;
  try
    Writer := TCompressionStream.Create(Target, FormatGzip, CompressionLevelBest);
    try
      Position := 0;
      Piece := 1;
      while Position < Length(Data) do
      begin
        if Piece > Length(Data) - Position then
          Piece := Length(Data) - Position;
        Writer.WriteBuffer(Data[Position], Piece);
        Inc(Position, Piece);
        Piece := (Piece * 5 + 11) mod 7000 + 1;
      end;
      Check(Writer.Seek(0, soCurrent) = Length(Data), 'compression stream position');
    finally
      Writer.Free;
    end;
    Compressed := Copy(Target.Bytes, 0, Target.Size);
    Check(SameData(DecompressGzip(Compressed), Data), 'compression stream to gzip, freed to finish');
  finally
    Target.Free;
  end;

  Target := TBytesStream.Create;
  try
    Writer := TCompressionStream.Create(Target, FormatZlib, CompressionLevelFast);
    try
      Writer.WriteBuffer(Data[0], Length(Data));
      Writer.Finish;
      Check(Target.Size > 0, 'compression stream finished');
    finally
      Writer.Free;
    end;
    Compressed := Copy(Target.Bytes, 0, Target.Size);
    Check(SameData(DecompressZlib(Compressed), Data), 'compression stream to zlib, finished');
  finally
    Target.Free;
  end;
end;

procedure TestGzipHeaderWriting;
var
  Deflater: TDeflater;
  Header: TGzipHeader;
  Data: TBytes;
  Compressed: TBytes;
  Output: TBytes;
  Written: SizeInt;
  Inflater: TInflater;
  Read: TGzipHeader;
begin
  Data := MakeData(DataText, 5000, 3);
  Compressed := nil;
  SetLength(Compressed, 10000);
  Deflater := TDeflater.Create(FormatGzip, CompressionLevelDefault);
  try
    Header := Deflater.GzipHeader;
    Header.FileName := 'picture.png';
    Header.Comment := 'made by the test';
    Header.ModificationTime := 1234567890;
    Header.HasExtra := True;
    Header.Extra := HexToData('0102030405');
    Header.HasHeaderCrc := True;
    Deflater.GzipHeader := Header;
    Deflater.SetInput(@Data[0], Length(Data));
    Check(Deflater.Compress(@Compressed[0], Length(Compressed), Written, True) = DeflateFinished,
      'gzip with header fields written');
    SetLength(Compressed, Written);
  finally
    Deflater.Free;
  end;
  Output := nil;
  SetLength(Output, 6000);
  Inflater := TInflater.Create(FormatGzip);
  try
    Inflater.SetInput(@Compressed[0], Length(Compressed));
    Check(Inflater.Decompress(@Output[0], Length(Output), Written) = InflateFinished,
      'gzip with header fields read back');
    SetLength(Output, Written);
    Read := Inflater.GzipHeader;
    Check(SameData(Output, Data), 'gzip with header fields: the data');
    Check((Read.FileName = 'picture.png') and (Read.Comment = 'made by the test') and
      (Read.ModificationTime = 1234567890) and Read.HasExtra and SameData(Read.Extra, HexToData('0102030405')) and
      Read.HasHeaderCrc, 'gzip with header fields: the fields');
  finally
    Inflater.Free;
  end;
end;

procedure WriteFile(const Path: string; const Data: TBytes);
var
  Stream: TFileStream;
begin
  Stream := TFileStream.Create(Path, fmCreate);
  try
    if Length(Data) > 0 then
      Stream.WriteBuffer(Data[0], Length(Data));
  finally
    Stream.Free;
  end;
end;

procedure WriteSamples(const Directory: string);
const
  SampleLevels: array[0..4] of Integer = (0, 1, 4, 6, 9);
var
  SampleIndex: Integer;
  LevelIndex: Integer;
  Level: Integer;
  Data: TBytes;
  Base: string;
begin
  ForceDirectories(Directory);
  for SampleIndex := Low(Samples) to High(Samples) do
  begin
    Data := SampleData(Samples[SampleIndex]);
    for LevelIndex := Low(SampleLevels) to High(SampleLevels) do
    begin
      Level := SampleLevels[LevelIndex];
      Base := IncludeTrailingPathDelimiter(Directory) + StringReplace(Samples[SampleIndex].Name, ' ', '-',
        [rfReplaceAll]) + '-' + IntToStr(Level);
      WriteFile(Base + '.data', Data);
      WriteFile(Base + '.zlib', CompressZlib(Data, Level));
      WriteFile(Base + '.gz', CompressGzip(Data, Level));
      WriteFile(Base + '.raw', CompressRaw(Data, Level));
    end;
  end;
end;

end.
