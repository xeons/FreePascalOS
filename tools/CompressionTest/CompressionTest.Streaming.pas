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
  The brotli and Zstandard decoders: the fixed data checked against the
  RFCs' check values (the static dictionary, the transforms, the context
  lookup tables), XXH64 known answers, and the fixtures make-fixtures.py
  writes (the host's brotli and zstd output, hand-made streams, broken
  copies), each decoded whole, in pieces of one byte, and in pieces of
  varying sizes; then the decoding speed on the largest text.
}
unit CompressionTest.Streaming;

{$mode objfpc}
{$H+}

interface

procedure TestStreamingTables;
procedure TestStreamingFixtures(const Directory: string);

implementation

uses
  SysUtils,
  Classes,
  TestChecks,
  Compression.Errors,
  Compression.Checksums,
  Compression.StreamingDecoders,
  Compression.XxHash64,
  Compression.BrotliTables,
  Compression.BrotliDictionary,
  Compression.BrotliTransforms,
  Compression.BrotliDecoder,
  Compression.ZstdDecoder,
  CompressionTest.StreamFeeding;

const
  { The pieces of the third way of feeding: 1 to this many bytes. }
  VaryingInputPiece = 700;
  VaryingOutputPiece = 3000;
  { Inputs larger than this are fed a byte at a time only partly. }
  BytewiseLimit = 400 * 1024;
  { Speed is measured over at least this long. }
  SpeedMilliseconds = 250;

function TransformsSerialized: TBytes;
var
  Index: Integer;
  Used: Integer;

  procedure Append(const Text: ShortString);
  begin
    if Length(Text) > 0 then
      Move(Text[1], Result[Used], Length(Text));
    Inc(Used, Length(Text));
  end;

  procedure AppendByte(Value: Byte);
  begin
    Result[Used] := Value;
    Inc(Used);
  end;

begin
  Result := nil;
  SetLength(Result, 4096);
  Used := 0;
  for Index := 0 to BrotliTransformCount - 1 do
  begin
    Append(BrotliTransforms[Index].Prefix);
    AppendByte(0);
    AppendByte(BrotliTransforms[Index].Kind);
    Append(BrotliTransforms[Index].Suffix);
    AppendByte(0);
  end;
  SetLength(Result, Used);
end;

function TransformedWord(Length: Integer; Index: LongWord; Transform: Integer): string;
var
  Buffer: array[0..BrotliLongestTransformedWord - 1] of Byte;
  Count: Integer;
begin
  Count := TransformBrotliWord(@Buffer[0], BrotliDictionaryWord(Length, Index), Length, Transform);
  SetString(Result, PChar(@Buffer[0]), Count);
end;

function TextHash(const Text: string): QWord;
begin
  Result := XxHash64(PByte(PChar(Text)), Length(Text));
end;

procedure TestStreamingTables;
var
  Serialized: TBytes;
  Data: TBytes;
  Index: Integer;
  State: TXxHash64State;
  Whole: QWord;
  Count: Integer;
begin
  Check(Crc32(Crc32Initial, @BrotliDictionaryData[0], BrotliDictionarySize) = $5136CB04,
    'brotli: the static dictionary is RFC 7932''s (122784 bytes, CRC-32 5136CB04)');
  Serialized := TransformsSerialized;
  Check((Length(Serialized) = 648) and (Crc32OfBytes(Serialized) = $3D965F81),
    'brotli: the transforms are RFC 7932''s (648 bytes, CRC-32 3D965F81)');
  Check(Crc32(Crc32Initial, @BrotliLut0[0], 256) = $8E91EFB7, 'brotli: context table Lut0');
  Check(Crc32(Crc32Initial, @BrotliLut1[0], 256) = $D01A32F4, 'brotli: context table Lut1');
  Check(Crc32(Crc32Initial, @BrotliLut2[0], 256) = $0DD7A0D6, 'brotli: context table Lut2');
  Check(TransformedWord(4, 0, 0) = 'time', 'brotli: the first word of four letters');
  Check(TransformedWord(4, 0, 9) = 'Time', 'brotli: transform 9 puts the first letter in upper case');
  Check(TransformedWord(4, 0, 44) = 'TIME', 'brotli: transform 44 puts all of it in upper case');
  Check(TransformedWord(4, 0, 73) = ' the time of the ', 'brotli: transform 73 adds a prefix and a suffix');
  Check(TransformedWord(4, 0, 3) = 'ime', 'brotli: transform 3 leaves out the first letter');
  Check(TransformedWord(4, 0, 49) = 'timing ', 'brotli: transform 49 leaves out the last letter, adds "ing "');

  Check(TextHash('') = QWord($EF46DB3751D8E999), 'XXH64 of nothing');
  Check(TextHash('a') = QWord($D24EC4F1A98C6E5B), 'XXH64 of "a"');
  Check(TextHash('abc') = QWord($44BC2CF5AD770999), 'XXH64 of "abc"');
  Data := nil;
  SetLength(Data, 100000);
  for Index := 0 to High(Data) do
    Data[Index] := Byte(Index * 7 + Index shr 5);
  Whole := XxHash64(@Data[0], Length(Data));
  XxHash64Start(State, 0);
  Index := 0;
  while Index < Length(Data) do
  begin
    Count := 1 + Index mod 97;
    if Count > Length(Data) - Index then
      Count := Length(Data) - Index;
    XxHash64Update(State, @Data[Index], Count);
    Inc(Index, Count);
  end;
  Check(XxHash64Finish(State) = Whole, 'XXH64 in pieces equals XXH64 at once');
end;

function ReadWholeFile(const Path: string): TBytes;
var
  Stream: TFileStream;
begin
  Result := nil;
  Stream := TFileStream.Create(Path, fmOpenRead or fmShareDenyNone);
  try
    SetLength(Result, Stream.Size);
    if Stream.Size > 0 then
      Stream.ReadBuffer(Result[0], Stream.Size);
  finally
    Stream.Free;
  end;
end;

function SameBytes(const Left, Right: TBytes): Boolean;
begin
  Result := (Length(Left) = Length(Right)) and
    ((Length(Left) = 0) or CompareMem(@Left[0], @Right[0], Length(Left)));
end;

{ Whether an ending is the one the manifest asks for. }
function EndingMatches(const Ending: TStreamEnding; const Expected: string): Boolean;
begin
  if Expected = 'any' then
    Result := Ending.Outcome <> 'too-large'
  else if Expected = 'fail' then
    Result := (Ending.Outcome <> 'ok') and (Ending.Outcome <> 'trailing')
  else
    Result := Ending.Outcome = Expected;
end;

procedure CheckWay(Decoder: TStreamingDecoder; const Name: string; const Way: string; const Input: TBytes;
  InputPiece: Integer; OutputPiece: Integer; Varying: Boolean; const Expected: string; const Original: TBytes;
  HasOriginal: Boolean);
var
  Output: TBytes;
  Ending: TStreamEnding;
  Detail: string;
begin
  Output := DecodeInPieces(Decoder, Input, InputPiece, OutputPiece, Varying, Ending);
  Detail := Ending.Outcome;
  if Ending.Error <> CompressionErrorNone then
    Detail := Detail + ': ' + CompressionErrorMessage(Ending.Error);
  Check(EndingMatches(Ending, Expected), Format('%s %s: %s (got %s)', [Name, Way, Expected, Detail]));
  if HasOriginal and (Expected = 'ok') then
    Check(SameBytes(Output, Original), Format('%s %s: output equals the original (%d bytes, got %d)',
      [Name, Way, Length(Original), Length(Output)]));
end;

procedure RunCase(const Directory: string; Fields: TStringList; Brotli: TBrotliDecoder; Zstd: TZstdDecoder);
var
  Name: string;
  Expected: string;
  Input: TBytes;
  Original: TBytes;
  HasOriginal: Boolean;
  Decoder: TStreamingDecoder;
begin
  Name := Fields[0];
  if Fields[1] = 'br' then
    Decoder := Brotli
  else
    Decoder := Zstd;
  Expected := Fields[2];
  Input := ReadWholeFile(Directory + '/' + Name);
  HasOriginal := Fields.Count > 3;
  Original := nil;
  if HasOriginal then
    Original := ReadWholeFile(Directory + '/' + Fields[3]);
  CheckWay(Decoder, Name, 'whole', Input, Length(Input) + 1, 1024 * 1024, False, Expected, Original, HasOriginal);
  CheckWay(Decoder, Name, 'varying pieces', Input, VaryingInputPiece, VaryingOutputPiece, True, Expected, Original,
    HasOriginal);
  { A byte at a time, in and out, for what is small enough. }
  if (Length(Input) <= BytewiseLimit) and (Length(Original) <= 4 * BytewiseLimit) then
    CheckWay(Decoder, Name, 'byte by byte', Input, 1, 1, False, Expected, Original, HasOriginal)
  else
    CheckWay(Decoder, Name, 'byte-sized input', Input, 1, 65536, False, Expected, Original, HasOriginal);
end;

procedure MeasureSpeed(Decoder: TStreamingDecoder; const Title: string; const Path: string);
var
  Input: TBytes;
  Output: TBytes;
  Ending: TStreamEnding;
  Rounds: Integer;
  Started: QWord;
  Milliseconds: QWord;
  Megabytes: Double;
begin
  if not FileExists(Path) then
    Exit;
  Input := ReadWholeFile(Path);
  Output := nil;
  Rounds := 0;
  Started := GetTickCount64;
  repeat
    Output := DecodeInPieces(Decoder, Input, 64 * 1024, 64 * 1024, False, Ending);
    Inc(Rounds);
    Milliseconds := GetTickCount64 - Started;
  until Milliseconds >= SpeedMilliseconds;
  Megabytes := Double(Length(Output)) * Rounds / (1024 * 1024);
  Check(Ending.Outcome = 'ok', Format('%s decoding speed: %.0f MiB/s (%d KiB in, %d KiB out, %d rounds, %d ms)',
    [Title, Megabytes * 1000 / Milliseconds, Length(Input) div 1024, Length(Output) div 1024, Rounds,
    Milliseconds]));
end;

procedure TestStreamingFixtures(const Directory: string);
var
  Lines: TStringList;
  Fields: TStringList;
  Line: string;
  Brotli: TBrotliDecoder;
  Zstd: TZstdDecoder;
begin
  if not FileExists(Directory + '/manifest.txt') then
  begin
    Check(False, 'brotli and zstd fixtures: ' + Directory + '/manifest.txt is there');
    Exit;
  end;
  Lines := TStringList.Create;
  Fields := TStringList.Create;
  Brotli := TBrotliDecoder.Create;
  Zstd := TZstdDecoder.Create;
  try
    Lines.LoadFromFile(Directory + '/manifest.txt');
    Fields.Delimiter := ' ';
    Fields.StrictDelimiter := True;
    for Line in Lines do
    begin
      if Trim(Line) = '' then
        Continue;
      Fields.DelimitedText := Trim(Line);
      RunCase(Directory, Fields, Brotli, Zstd);
    end;
    MeasureSpeed(Brotli, 'brotli (quality 11)', Directory + '/text.q11.br');
    MeasureSpeed(Brotli, 'brotli (quality 5)', Directory + '/repetitive.q5.br');
    MeasureSpeed(Zstd, 'zstd (level 19)', Directory + '/text.l19.zst');
    MeasureSpeed(Zstd, 'zstd (level 3)', Directory + '/repetitive.l3.zst');
  finally
    Zstd.Free;
    Brotli.Free;
    Fields.Free;
    Lines.Free;
  end;
end;

end.
