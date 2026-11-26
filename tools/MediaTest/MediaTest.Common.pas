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
  What the media tests share: reading fixtures and their manifests,
  decoding a whole file through libmedia (a container and the audio
  decoder for its first audio track), and comparing decoded audio with
  a reference (exactly, or by signal-to-noise ratio and largest error).
}
unit MediaTest.Common;

{$mode objfpc}
{$H+}

interface

uses
  Classes,
  SysUtils,
  Media.Packets;

type
  TFloatArray = array of Single;

  TDecodedAudio = record
    SampleRate: Integer;
    Channels: Integer;
    Samples: TFloatArray;
    PacketCount: Integer;
    FormatName: string;
    Codec: TCodecId;
  end;

function ReadFileBytes(const Path: string): TBytes;
{ The non-empty, non-comment lines of a manifest; empty if it is missing. }
function ReadManifestLines(const Path: string): TStringList;
{ The space-separated fields of a manifest line. }
function SplitFields(const Line: string): TStringList;
{ Decodes the first audio track of the file at Path; raises on errors. }
function DecodeAudioFile(const Path: string): TDecodedAudio;
{ Raw little-endian samples of a reference file as floats. }
function ReadS16Reference(const Path: string): TFloatArray;
function ReadS32Reference(const Path: string): TFloatArray;
function ReadF32Reference(const Path: string): TFloatArray;
{ The signal-to-noise ratio of Actual against Expected in decibels, over
  the samples both have (200 for identical signals). }
function SignalToNoise(const Actual, Expected: TFloatArray): Double;
function LargestDifference(const Actual, Expected: TFloatArray): Double;
{ Whether Actual is exactly Expected (same length, same values). }
function SameSamples(const Actual, Expected: TFloatArray): Boolean;
{ Floats as 16-bit integers (rounded, clipped), then compared exactly with
  the reference's 16-bit values: how many differ by more than Tolerance. }
function CountS16Mismatches(const Actual, Expected: TFloatArray; Tolerance: Integer): Integer;
function MD5OfBytes(const Bytes: TBytes): string;
function FixturePath(const Root, Name: string): string;

implementation

uses
  Math,
  md5,
  Media.Frames,
  Media.Demuxers,
  Media.Containers,
  Media.AudioDecoders,
  Media.AudioCodecs;

function ReadFileBytes(const Path: string): TBytes;
var
  Stream: TFileStream;
begin
  Result := nil;
  Stream := TFileStream.Create(Path, fmOpenRead or fmShareDenyNone);
  try
    SetLength(Result, Stream.Size);
    if Length(Result) > 0 then
      Stream.ReadBuffer(Result[0], Length(Result));
  finally
    Stream.Free;
  end;
end;

function ReadManifestLines(const Path: string): TStringList;
var
  Lines: TStringList;
  Line: string;
begin
  Result := TStringList.Create;
  if not FileExists(Path) then
    Exit;
  Lines := TStringList.Create;
  try
    Lines.LoadFromFile(Path);
    for Line in Lines do
      if (Trim(Line) <> '') and (Trim(Line)[1] <> '#') then
        Result.Add(Trim(Line));
  finally
    Lines.Free;
  end;
end;

function SplitFields(const Line: string): TStringList;
begin
  Result := TStringList.Create;
  Result.Delimiter := ' ';
  Result.StrictDelimiter := True;
  Result.DelimitedText := Line;
end;

function DecodeAudioFile(const Path: string): TDecodedAudio;
var
  Demuxer: TMediaDemuxer;
  Track: TMediaTrack;
  Decoder: TAudioDecoder;
  Packet: TMediaPacket;
  Buffer: TAudioBuffer;
  Count: Integer;
begin
  Result := Default(TDecodedAudio);
  Result.Samples := nil;
  Demuxer := OpenMediaFile(Path);
  try
    Result.FormatName := Demuxer.FormatName;
    Track := Demuxer.FirstTrackOf(mkAudio);
    if Track = nil then
      raise Exception.Create('no audio track');
    Result.Codec := Track.Codec;
    Decoder := CreateAudioDecoder(Track);
    try
      Count := 0;
      SetLength(Result.Samples, 65536);
      Buffer := Default(TAudioBuffer);
      while Demuxer.ReadPacket(Packet) do
      begin
        if Packet.TrackIndex <> Track.Index then
          Continue;
        Inc(Result.PacketCount);
        if not Decoder.Decode(Packet, Buffer) then
          Continue;
        Result.SampleRate := Buffer.SampleRate;
        Result.Channels := Buffer.Channels;
        if Count + Length(Buffer.Samples) > Length(Result.Samples) then
          SetLength(Result.Samples, (Count + Length(Buffer.Samples)) * 2);
        if Length(Buffer.Samples) > 0 then
          Move(Buffer.Samples[0], Result.Samples[Count], Length(Buffer.Samples) * SizeOf(Single));
        Inc(Count, Length(Buffer.Samples));
      end;
      SetLength(Result.Samples, Count);
      if Result.SampleRate = 0 then
      begin
        Result.SampleRate := Decoder.SampleRate;
        Result.Channels := Decoder.Channels;
      end;
    finally
      Decoder.Free;
    end;
  finally
    Demuxer.Free;
  end;
end;

function ReadS16Reference(const Path: string): TFloatArray;
var
  Bytes: TBytes;
  Index: Integer;
begin
  Result := nil;
  Bytes := ReadFileBytes(Path);
  SetLength(Result, Length(Bytes) div 2);
  for Index := 0 to High(Result) do
    Result[Index] := SmallInt(Bytes[Index * 2] or (Bytes[Index * 2 + 1] shl 8)) / 32768;
end;

function ReadS32Reference(const Path: string): TFloatArray;
var
  Bytes: TBytes;
  Index: Integer;
  Raw: LongWord;
begin
  Result := nil;
  Bytes := ReadFileBytes(Path);
  SetLength(Result, Length(Bytes) div 4);
  for Index := 0 to High(Result) do
  begin
    Raw := LongWord(Bytes[Index * 4]) or (LongWord(Bytes[Index * 4 + 1]) shl 8) or
      (LongWord(Bytes[Index * 4 + 2]) shl 16) or (LongWord(Bytes[Index * 4 + 3]) shl 24);
    Result[Index] := LongInt(Raw) / 2147483648.0;
  end;
end;

function ReadF32Reference(const Path: string): TFloatArray;
var
  Bytes: TBytes;
begin
  Result := nil;
  Bytes := ReadFileBytes(Path);
  SetLength(Result, Length(Bytes) div 4);
  if Length(Result) > 0 then
    Move(Bytes[0], Result[0], Length(Result) * 4);
end;

function SignalToNoise(const Actual, Expected: TFloatArray): Double;
var
  Index, Count: Integer;
  Signal, Noise, Difference: Double;
begin
  Count := Min(Length(Actual), Length(Expected));
  Signal := 0;
  Noise := 0;
  for Index := 0 to Count - 1 do
  begin
    Signal := Signal + Sqr(Double(Expected[Index]));
    Difference := Double(Actual[Index]) - Expected[Index];
    Noise := Noise + Sqr(Difference);
  end;
  if Noise = 0 then
    Exit(200);
  if Signal = 0 then
    Exit(-200);
  Result := 10 * Log10(Signal / Noise);
end;

function LargestDifference(const Actual, Expected: TFloatArray): Double;
var
  Index: Integer;
begin
  Result := 0;
  for Index := 0 to Min(Length(Actual), Length(Expected)) - 1 do
    Result := Max(Result, Abs(Double(Actual[Index]) - Expected[Index]));
end;

function SameSamples(const Actual, Expected: TFloatArray): Boolean;
var
  Index: Integer;
begin
  if Length(Actual) <> Length(Expected) then
    Exit(False);
  for Index := 0 to High(Actual) do
    if Actual[Index] <> Expected[Index] then
      Exit(False);
  Result := True;
end;

function ToS16(Value: Single): Integer;
begin
  Result := Round(Double(Value) * 32768);
  if Result > 32767 then
    Result := 32767
  else if Result < -32768 then
    Result := -32768;
end;

function CountS16Mismatches(const Actual, Expected: TFloatArray; Tolerance: Integer): Integer;
var
  Index: Integer;
begin
  Result := Abs(Length(Actual) - Length(Expected));
  for Index := 0 to Min(Length(Actual), Length(Expected)) - 1 do
    if Abs(ToS16(Actual[Index]) - ToS16(Expected[Index])) > Tolerance then
      Inc(Result);
end;

function MD5OfBytes(const Bytes: TBytes): string;
var
  Context: TMD5Context;
  Digest: TMD5Digest;
begin
  MD5Init(Context);
  if Length(Bytes) > 0 then
    MD5Update(Context, Bytes[0], Length(Bytes));
  MD5Final(Context, Digest);
  Result := MD5Print(Digest);
end;

function FixturePath(const Root, Name: string): string;
begin
  Result := IncludeTrailingPathDelimiter(Root) + Name;
end;

end.
