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
  Preset dictionaries and flush points: zlib's data made with a
  dictionary decompressed (whole and a byte at a time), refused without
  the dictionary or with another one; our own data made with one at
  every level; zlib's sync and full flushes giving everything before
  them as soon as the input up to them is in, and data after a full
  flush decompressing on its own; the same of our flushes. Samples of
  both go to check-with-zlib.py.
}
unit CompressionTest.Flushing;

{$mode objfpc}
{$H+}

interface

procedure TestDictionaries;
procedure TestFlushes;
procedure WriteDictionaryAndFlushSamples(const Directory: string);

implementation

uses
  Classes,
  SysUtils,
  TestChecks,
  Compression.Errors,
  Compression.Formats,
  Compression.Checksums,
  Compression.Inflater,
  Compression.Deflater,
  CompressionTest.Data,
  CompressionTest.Vectors;

type
  TFlushPoint = record
    CompressedLength: Integer;
    InputLength: Integer;
    Full: Boolean;
  end;

  TFlushPoints = array of TFlushPoint;

const
  FormatNames: array[TCompressionFormat] of string = ('raw', 'zlib', 'gzip', 'automatic');

{ Decompresses with the dictionary (none if empty), the input given
  InputPiece bytes at a time. }
function Inflate(const Compressed: TBytes; Format: TCompressionFormat; const Dictionary: TBytes;
  InputPiece: Integer; out Error: TCompressionError; out DictionaryId: LongWord): TBytes;
var
  Inflater: TInflater;
  Buffer: array[0..4095] of Byte;
  Used: Integer;
  InputPosition: Integer;
  Count: Integer;
  Written: SizeInt;
  Outcome: TInflateResult;
begin
  Result := nil;
  Used := 0;
  Error := CompressionErrorNone;
  InputPosition := 0;
  Inflater := TInflater.Create(Format);
  try
    if Length(Dictionary) > 0 then
      Inflater.SetDictionary(@Dictionary[0], Length(Dictionary));
    repeat
      Outcome := Inflater.Decompress(@Buffer[0], Length(Buffer), Written);
      if Written > 0 then
      begin
        SetLength(Result, Used + Written);
        Move(Buffer[0], Result[Used], Written);
        Inc(Used, Written);
      end;
      if Outcome = InflateNeedsInput then
      begin
        if InputPosition >= Length(Compressed) then
        begin
          Error := CompressionErrorTruncated;
          Break;
        end;
        Count := InputPiece;
        if Count > Length(Compressed) - InputPosition then
          Count := Length(Compressed) - InputPosition;
        Inflater.SetInput(@Compressed[InputPosition], Count);
        Inc(InputPosition, Count);
      end
      else if Outcome = InflateFailed then
        Error := Inflater.Error;
    until Outcome in [InflateFinished, InflateFailed];
    DictionaryId := Inflater.DictionaryId;
  finally
    Inflater.Free;
  end;
end;

function InflateSimply(const Compressed: TBytes; Format: TCompressionFormat; const Dictionary: TBytes;
  out Error: TCompressionError): TBytes;
var
  DictionaryId: LongWord;
begin
  Result := Inflate(Compressed, Format, Dictionary, Length(Compressed) + 1, Error, DictionaryId);
end;

function Deflate(const Data: TBytes; Format: TCompressionFormat; Level: Integer; const Dictionary: TBytes): TBytes;
var
  Deflater: TDeflater;
  Buffer: array[0..999] of Byte;
  Used: Integer;
  Written: SizeInt;
  Outcome: TDeflateResult;
begin
  Result := nil;
  Used := 0;
  Deflater := TDeflater.Create(Format, Level);
  try
    if Length(Dictionary) > 0 then
      Deflater.SetDictionary(@Dictionary[0], Length(Dictionary));
    if Length(Data) > 0 then
      Deflater.SetInput(@Data[0], Length(Data));
    repeat
      Outcome := Deflater.Compress(@Buffer[0], Length(Buffer), Written, True);
      SetLength(Result, Used + Written);
      if Written > 0 then
        Move(Buffer[0], Result[Used], Written);
      Inc(Used, Written);
    until Outcome = DeflateFinished;
  finally
    Deflater.Free;
  end;
end;

procedure CheckDictionaryVector(const Vector: TDictionaryVector);
var
  Compressed: TBytes;
  Expected: TBytes;
  Dictionary: TBytes;
  Other: TBytes;
  Output: TBytes;
  Error: TCompressionError;
  DictionaryId: LongWord;
  Name: string;
begin
  Name := 'dictionary, ' + string(Vector.Name);
  Compressed := HexToData(Vector.Compressed);
  Expected := MakeData(Vector.Kind, Vector.Size, Vector.Seed);
  Dictionary := MakeData(DataText, Vector.DictionarySize, Vector.DictionarySeed);
  Check(Adler32OfBytes(Dictionary) = Vector.DictionaryId, Name + ': the dictionary made again');

  Output := Inflate(Compressed, Vector.Format, Dictionary, Length(Compressed), Error, DictionaryId);
  Check((Error = CompressionErrorNone) and SameData(Output, Expected), Name + ': decompressed whole');
  Output := Inflate(Compressed, Vector.Format, Dictionary, 1, Error, DictionaryId);
  Check((Error = CompressionErrorNone) and SameData(Output, Expected), Name + ': decompressed a byte at a time');

  if Vector.Format = FormatZlib then
  begin
    Output := Inflate(Compressed, Vector.Format, nil, Length(Compressed), Error, DictionaryId);
    Check((Error = CompressionErrorPresetDictionary) and (DictionaryId = Vector.DictionaryId),
      Name + ': refused without the dictionary, which it names');
    Other := MakeData(DataText, Vector.DictionarySize, Vector.DictionarySeed + 1);
    Output := Inflate(Compressed, Vector.Format, Other, 3, Error, DictionaryId);
    Check(Error = CompressionErrorDictionaryMismatch, Name + ': refused with another dictionary');
  end
  else
  begin
    Output := Inflate(Compressed, Vector.Format, nil, Length(Compressed), Error, DictionaryId);
    Check(not ((Error = CompressionErrorNone) and SameData(Output, Expected)),
      Name + ': not the data without the dictionary');
  end;
end;

procedure CheckOwnDictionaries;
const
  Levels: array[0..4] of Integer = (0, 1, 4, 6, 9);
var
  Data: TBytes;
  Dictionary: TBytes;
  LongDictionary: TBytes;
  WithDictionary: TBytes;
  WithoutDictionary: TBytes;
  Output: TBytes;
  Error: TCompressionError;
  LevelIndex: Integer;
  Level: Integer;
  DataFormat: TCompressionFormat;
  Deflater: TDeflater;
  Refused: Boolean;
begin
  Data := MakeData(DataText, 6000, 31);
  Dictionary := MakeData(DataText, 8000, 32);
  LongDictionary := MakeData(DataText, 70000, 33);
  for LevelIndex := Low(Levels) to High(Levels) do
  begin
    Level := Levels[LevelIndex];
    for DataFormat in [FormatZlib, FormatRaw] do
    begin
      WithDictionary := Deflate(Data, DataFormat, Level, Dictionary);
      Output := InflateSimply(WithDictionary, DataFormat, Dictionary, Error);
      Check((Error = CompressionErrorNone) and SameData(Output, Data),
        Format('own dictionary at level %d (%s): round trip', [Level, FormatNames[DataFormat]]));
      if Level > 0 then
      begin
        WithoutDictionary := Deflate(Data, DataFormat, Level, nil);
        Check(Length(WithDictionary) < Length(WithoutDictionary),
          Format('own dictionary at level %d (%s): smaller with it (%d < %d)', [Level,
          FormatNames[DataFormat], Length(WithDictionary), Length(WithoutDictionary)]));
      end;
    end;
    WithDictionary := Deflate(Data, FormatZlib, Level, LongDictionary);
    Output := InflateSimply(WithDictionary, FormatZlib, LongDictionary, Error);
    Check((Error = CompressionErrorNone) and SameData(Output, Data),
      Format('own dictionary longer than the window at level %d: round trip', [Level]));
  end;
  WithDictionary := Deflate(Data, FormatZlib, 6, Dictionary);
  Check((WithDictionary[1] and $20) <> 0, 'own dictionary: the zlib header says so');
  Check((LongWord(WithDictionary[2]) shl 24) or (LongWord(WithDictionary[3]) shl 16) or
    (LongWord(WithDictionary[4]) shl 8) or WithDictionary[5] = Adler32OfBytes(Dictionary),
    'own dictionary: its Adler-32 after the header');

  Deflater := TDeflater.Create(FormatGzip, 6);
  try
    Refused := False;
    try
      Deflater.SetDictionary(@Dictionary[0], Length(Dictionary));
    except
      on ECompressionError do
        Refused := True;
    end;
    Check(Refused, 'no dictionary for gzip');
  finally
    Deflater.Free;
  end;
end;

procedure TestDictionaries;
var
  Index: Integer;
begin
  for Index := Low(DictionaryVectors) to High(DictionaryVectors) do
    CheckDictionaryVector(DictionaryVectors[Index]);
  CheckOwnDictionaries;
end;

function ParsePoints(Text: PChar): TFlushPoints;
var
  Pieces: TStringArray;
  Fields: TStringArray;
  Index: Integer;
begin
  Result := nil;
  Pieces := string(Text).Split([',']);
  SetLength(Result, Length(Pieces));
  for Index := 0 to High(Pieces) do
  begin
    Fields := Pieces[Index].Split([':']);
    Result[Index].CompressedLength := StrToInt(Fields[0]);
    Result[Index].InputLength := StrToInt(Fields[1]);
    Result[Index].Full := Fields[2] = '1';
  end;
end;

{ Gives the inflater the compressed data up to each flush point and
  checks that all the input before it has come out; after a full flush,
  the rest must decompress as raw data of its own. }
procedure CheckFlushPoints(const Name: string; const Compressed: TBytes; const Data: TBytes;
  const Points: TFlushPoints);
var
  Inflater: TInflater;
  Buffer: TBytes;
  Written: SizeInt;
  Outcome: TInflateResult;
  Index: Integer;
  Previous: Integer;
  Output: TBytes;
  Error: TCompressionError;
  AllOut: Boolean;
begin
  Buffer := nil;
  SetLength(Buffer, Length(Data) + 16);
  Inflater := TInflater.Create(FormatZlib);
  try
    Previous := 0;
    AllOut := True;
    for Index := 0 to High(Points) do
    begin
      Inflater.SetInput(@Compressed[Previous], Points[Index].CompressedLength - Previous);
      Outcome := Inflater.Decompress(@Buffer[Inflater.TotalOutput], Length(Buffer) - Inflater.TotalOutput, Written);
      if (Outcome <> InflateNeedsInput) or (Inflater.TotalOutput <> Points[Index].InputLength) then
        AllOut := False;
      Previous := Points[Index].CompressedLength;
    end;
    Check(AllOut, Name + ': everything before each flush comes out at it');
    Check(CompareByte(Buffer[0], Data[0], Points[High(Points)].InputLength) = 0, Name + ': and is the data');
  finally
    Inflater.Free;
  end;
  for Index := 0 to High(Points) do
  begin
    if not Points[Index].Full then
      Continue;
    Output := InflateSimply(SliceData(Compressed, Points[Index].CompressedLength,
      Length(Compressed) - Points[Index].CompressedLength - 4), FormatRaw, nil, Error);
    Check((Error = CompressionErrorNone) and SameData(Output, SliceData(Data, Points[Index].InputLength,
      Length(Data) - Points[Index].InputLength)), Format('%s: decompresses on its own after full flush %d',
      [Name, Index + 1]));
  end;
  Output := InflateSimply(Compressed, FormatZlib, nil, Error);
  Check((Error = CompressionErrorNone) and SameData(Output, Data), Name + ': decompressed whole');
end;

{ Compresses Data with a flush (full where Fulls says so) after each of
  the input lengths in Ends; Points says where they came out. }
function DeflateWithFlushes(const Data: TBytes; Level: Integer; const Ends: array of Integer;
  const Fulls: array of Boolean; OutputPiece: Integer; out Points: TFlushPoints): TBytes;
var
  Deflater: TDeflater;
  Buffer: TBytes;
  Used: Integer;
  Start: Integer;
  Index: Integer;
  Mode: TDeflateFlush;
  Written: SizeInt;
  Outcome: TDeflateResult;

  procedure Append;
  begin
    SetLength(Result, Used + Written);
    if Written > 0 then
      Move(Buffer[0], Result[Used], Written);
    Inc(Used, Written);
  end;

begin
  Result := nil;
  Points := nil;
  Buffer := nil;
  SetLength(Buffer, OutputPiece);
  SetLength(Points, Length(Ends));
  Used := 0;
  Start := 0;
  Deflater := TDeflater.Create(FormatZlib, Level);
  try
    for Index := 0 to High(Ends) do
    begin
      Deflater.SetInput(@Data[Start], Ends[Index] - Start);
      if Fulls[Index] then
        Mode := FlushFull
      else
        Mode := FlushSync;
      repeat
        Outcome := Deflater.Compress(@Buffer[0], Length(Buffer), Written, Mode);
        Append;
      until Outcome = DeflateNeedsInput;
      { Asked again without new input: nothing more. }
      Outcome := Deflater.Compress(@Buffer[0], Length(Buffer), Written, Mode);
      Append;
      Points[Index].CompressedLength := Used;
      Points[Index].InputLength := Ends[Index];
      Points[Index].Full := Fulls[Index];
      Start := Ends[Index];
    end;
    Deflater.SetInput(@Data[Start], Length(Data) - Start);
    repeat
      Outcome := Deflater.Compress(@Buffer[0], Length(Buffer), Written, FlushFinish);
      Append;
    until Outcome = DeflateFinished;
  finally
    Deflater.Free;
  end;
end;

function EndsWithFlushMarker(const Compressed: TBytes; Length: Integer): Boolean;
begin
  Result := (Length >= 4) and (Compressed[Length - 4] = 0) and (Compressed[Length - 3] = 0) and
    (Compressed[Length - 2] = $FF) and (Compressed[Length - 1] = $FF);
end;

procedure CheckOwnFlushes;
const
  Levels: array[0..4] of Integer = (0, 1, 4, 6, 9);
var
  Data: TBytes;
  Compressed: TBytes;
  Points: TFlushPoints;
  LevelIndex: Integer;
  Index: Integer;
  Marked: Boolean;
  Name: string;
begin
  Data := MakeData(DataText, 100000, 41);
  for LevelIndex := Low(Levels) to High(Levels) do
  begin
    Name := Format('own flushes at level %d', [Levels[LevelIndex]]);
    Compressed := DeflateWithFlushes(Data, Levels[LevelIndex], [1, 7000, 7000, 40000, 70001, 99000],
      [False, True, False, True, False, True], 777, Points);
    Marked := True;
    for Index := 0 to High(Points) do
      if not EndsWithFlushMarker(Compressed, Points[Index].CompressedLength) then
        Marked := False;
    Check(Marked, Name + ': each ends on an empty stored block');
    Check(Points[2].CompressedLength = Points[1].CompressedLength, Name + ': a flush with no new input adds nothing');
    CheckFlushPoints(Name, Compressed, Data, Points);
  end;
end;

procedure TestFlushes;
var
  Index: Integer;
  Vector: TFlushVector;
begin
  for Index := Low(FlushVectors) to High(FlushVectors) do
  begin
    Vector := FlushVectors[Index];
    CheckFlushPoints('zlib''s ' + string(Vector.Name), HexToData(Vector.Compressed),
      MakeData(Vector.Kind, Vector.Size, Vector.Seed), ParsePoints(Vector.Points));
  end;
  CheckOwnFlushes;
end;

procedure WriteBytesToFile(const Path: string; const Data: TBytes);
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

function TextOfPoints(const Points: TFlushPoints): TBytes;
var
  Text: string;
  Index: Integer;
begin
  Text := '';
  for Index := 0 to High(Points) do
    Text := Text + Format('%d %d %d'#10, [Points[Index].CompressedLength, Points[Index].InputLength,
      Ord(Points[Index].Full)]);
  Result := nil;
  SetLength(Result, Length(Text));
  if Length(Text) > 0 then
    Move(Text[1], Result[0], Length(Text));
end;

{ For every level: <base>.dictdata, its dictionary (.dict) and the data
  compressed with it as zlib (.zdict) and raw (.rdict); <base>.flushdata
  compressed as zlib with flushes (.zflush) and where they are
  (.points). }
procedure WriteDictionaryAndFlushSamples(const Directory: string);
const
  Levels: array[0..3] of Integer = (0, 1, 6, 9);
var
  Data: TBytes;
  Dictionary: TBytes;
  Points: TFlushPoints;
  Base: string;
  LevelIndex: Integer;
begin
  ForceDirectories(Directory);
  Data := MakeData(DataText, 20000, 51);
  Dictionary := MakeData(DataText, 12000, 52);
  for LevelIndex := Low(Levels) to High(Levels) do
  begin
    Base := IncludeTrailingPathDelimiter(Directory) + 'dictionary-' + IntToStr(Levels[LevelIndex]);
    WriteBytesToFile(Base + '.dictdata', Data);
    WriteBytesToFile(Base + '.dict', Dictionary);
    WriteBytesToFile(Base + '.zdict', Deflate(Data, FormatZlib, Levels[LevelIndex], Dictionary));
    WriteBytesToFile(Base + '.rdict', Deflate(Data, FormatRaw, Levels[LevelIndex], Dictionary));
    Base := IncludeTrailingPathDelimiter(Directory) + 'flushes-' + IntToStr(Levels[LevelIndex]);
    WriteBytesToFile(Base + '.flushdata', Data);
    WriteBytesToFile(Base + '.zflush', DeflateWithFlushes(Data, Levels[LevelIndex], [100, 5000, 5001, 15000],
      [False, True, False, True], 4096, Points));
    WriteBytesToFile(Base + '.points', TextOfPoints(Points));
  end;
end;

end.
