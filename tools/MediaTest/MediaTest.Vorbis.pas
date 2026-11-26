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
  Tests of the Vorbis decoder.

  The inverse MDCT is checked against the transform's definition; header
  handling against broken and Xiph-laced headers; and the decoder over
  the files make-vorbis-fixtures.py encoded with libvorbis, compared with
  libvorbis' own decoding of them (both work in floats, so they agree to
  rounding: a signal-to-noise ratio of at least MinimumSnr decibels and
  no sample off by more than LargestError). The packets come from a test
  Ogg reader (MediaTest.OggPackets); the reference's first sample is
  found within the first frames, since ffmpeg may drop a few at the start.
  Through libmedia's own Ogg demuxer the same files are decoded again
  when it reads Ogg.
}
unit MediaTest.Vorbis;

{$mode objfpc}
{$H+}

interface

procedure RunVorbisTests(const FixtureRoot: string);

implementation

uses
  Classes,
  SysUtils,
  Math,
  DateUtils,
  TestChecks,
  MediaTest.Common,
  MediaTest.OggPackets,
  Media.Errors,
  Media.Frames,
  Media.Packets,
  Media.Vorbis,
  Media.Vorbis.Mdct;

const
  MinimumSnr = 100.0;
  LargestError = 1e-4;
  { How far into the decoded signal the reference may start. }
  AlignmentSearch = 2048;

procedure CheckMdct(Size: Integer);
var
  Mdct: TVorbisMdct;
  Input, Output: array of Single;
  Index, Coefficient: Integer;
  Expected, Worst: Double;
begin
  Input := nil;
  Output := nil;
  SetLength(Input, Size div 2);
  SetLength(Output, Size);
  RandSeed := Size;
  for Index := 0 to High(Input) do
    Input[Index] := Random - 0.5;
  Mdct := TVorbisMdct.Create(Size);
  try
    Mdct.Inverse(@Input[0], @Output[0]);
  finally
    Mdct.Free;
  end;
  Worst := 0;
  for Index := 0 to Size - 1 do
  begin
    Expected := 0;
    for Coefficient := 0 to Size div 2 - 1 do
      Expected := Expected + Input[Coefficient] * Cos(2 * Pi / Size * (Index + 0.5 + Size / 4) * (Coefficient + 0.5));
    Worst := Max(Worst, Abs(Expected - Output[Index]));
  end;
  Check(Worst < 1e-4, Format('vorbis: inverse MDCT of %d matches its definition (largest error %.2g)', [Size, Worst]));
end;

procedure CheckHeaderHandling;
var
  Decoder: TVorbisDecoder;
  Garbage, Block: TBytes;
  Rejected: Boolean;
  Split: THeaderPackets;
begin
  Garbage := TBytes.Create(1, Ord('v'), Ord('o'), Ord('r'), Ord('b'), Ord('i'), Ord('s'), 0, 0);
  Decoder := TVorbisDecoder.Create;
  try
    Rejected := False;
    try
      Decoder.ConfigureFromHeaders(Garbage, Garbage, Garbage);
    except
      on EMediaError do
        Rejected := True;
    end;
    Check(Rejected, 'vorbis: a cut short identification header is refused');
  finally
    Decoder.Free;
  end;
  { Two sizes laced (3 and 300 = 255 + 45), then three packets. }
  Block := nil;
  SetLength(Block, 1 + 1 + 2 + 3 + 300 + 7);
  Block[0] := 2;
  Block[1] := 3;
  Block[2] := 255;
  Block[3] := 45;
  Block[4] := 11;
  Block[7] := 22;
  Block[High(Block)] := 33;
  Split := SplitXiphLacedHeaders(Block);
  Check((Length(Split) = 3) and (Length(Split[0]) = 3) and (Length(Split[1]) = 300) and (Length(Split[2]) = 7) and
    (Split[0][0] = 11) and (Split[1][0] = 22) and (Split[2][6] = 33), 'vorbis: Xiph-laced headers are split');
end;

{ The offset (in frames) at which Expected best lines up with Actual. }
function FindAlignment(const Actual, Expected: TFloatArray; Channels: Integer): Integer;
var
  Offset, Index, Span: Integer;
  Error, BestError: Double;
begin
  Result := 0;
  BestError := Infinity;
  Span := Min(4096 * Channels, Length(Expected));
  for Offset := 0 to AlignmentSearch do
  begin
    if Offset * Channels + Span > Length(Actual) then
      Break;
    Error := 0;
    for Index := 0 to Span - 1 do
    begin
      Error := Error + Sqr(Double(Actual[Offset * Channels + Index]) - Expected[Index]);
      if Error >= BestError then
        Break;
    end;
    if Error < BestError then
    begin
      BestError := Error;
      Result := Offset;
    end;
  end;
end;

function DecodeWithTestReader(const Path: string; out Rate, Channels: Integer; out FirstPacketEmpty: Boolean;
  out Seconds: Double): TFloatArray;
var
  Packets: TOggPacketList;
  LastGranule: Int64;
  Decoder: TVorbisDecoder;
  Packet: TMediaPacket;
  Buffer: TAudioBuffer;
  Index, Count, Frames: Integer;
  Started: TDateTime;
begin
  Result := nil;
  Packets := SplitOggPackets(ReadFileBytes(Path), LastGranule);
  if Length(Packets) < 4 then
    raise Exception.Create('fewer than four packets');
  Decoder := TVorbisDecoder.Create;
  try
    Decoder.ConfigureFromHeaders(Packets[0], Packets[1], Packets[2]);
    Rate := Decoder.SampleRate;
    Channels := Decoder.Channels;
    Count := 0;
    FirstPacketEmpty := False;
    Buffer := Default(TAudioBuffer);
    Started := Now;
    for Index := 3 to High(Packets) do
    begin
      Packet := NewPacket(0);
      Packet.Data := Packets[Index];
      Decoder.Decode(Packet, Buffer);
      if Index = 3 then
        FirstPacketEmpty := Length(Buffer.Samples) = 0;
      if Count + Length(Buffer.Samples) > Length(Result) then
        SetLength(Result, (Count + Length(Buffer.Samples)) * 2);
      if Length(Buffer.Samples) > 0 then
        Move(Buffer.Samples[0], Result[Count], Length(Buffer.Samples) * SizeOf(Single));
      Inc(Count, Length(Buffer.Samples));
    end;
    Seconds := MilliSecondsBetween(Now, Started) / 1000;
  finally
    Decoder.Free;
  end;
  { The last page's granule position is the stream's length. }
  Frames := Count div Channels;
  if (LastGranule > 0) and (LastGranule < Frames) then
    Frames := LastGranule;
  SetLength(Result, Frames * Channels);
end;

procedure CheckFixture(const Directory, Line: string);
var
  Fields: TStringList;
  Name: string;
  Expected, Actual, Aligned: TFloatArray;
  Rate, Channels, Offset, Missing: Integer;
  FirstPacketEmpty: Boolean;
  Snr, Largest, Seconds, Duration: Double;
begin
  Fields := SplitFields(Line);
  try
    Name := Fields[0];
    try
      Expected := ReadF32Reference(FixturePath(Directory, Fields[1]));
      Actual := DecodeWithTestReader(FixturePath(Directory, Name), Rate, Channels, FirstPacketEmpty, Seconds);
    except
      on Error: Exception do
      begin
        Check(False, 'vorbis: ' + Name + ' decodes (' + Error.Message + ')');
        Exit;
      end;
    end;
    Check((Rate = StrToInt(Fields[2])) and (Channels = StrToInt(Fields[3])),
      Format('vorbis: %s is %d Hz, %d channels', [Name, Rate, Channels]));
    Check(FirstPacketEmpty, 'vorbis: ' + Name + ': the first audio packet gives no samples');
    Offset := FindAlignment(Actual, Expected, Channels);
    Aligned := Copy(Actual, Offset * Channels, Length(Actual));
    Missing := (Length(Expected) - Length(Aligned)) div Channels;
    Snr := SignalToNoise(Aligned, Expected);
    Largest := LargestDifference(Aligned, Expected);
    Duration := Length(Actual) / Channels / Rate;
    Check(Missing <= 0, Format('vorbis: %s has the reference''s %d frames (%d decoded, reference from frame %d)',
      [Name, Length(Expected) div Channels, Length(Actual) div Channels, Offset]));
    Check((Snr >= MinimumSnr) and (Largest <= LargestError),
      Format('vorbis: %s matches libvorbis (SNR %.1f dB, largest error %.3g, %.1fx real time)',
      [Name, Snr, Largest, Duration / Max(Seconds, 0.001)]));
  finally
    Fields.Free;
  end;
end;

procedure CheckThroughDemuxer(const Directory, Line: string);
var
  Fields: TStringList;
  Decoded: TDecodedAudio;
  Expected, Aligned: TFloatArray;
  Offset: Integer;
  Snr: Double;
begin
  Fields := SplitFields(Line);
  try
    try
      Decoded := DecodeAudioFile(FixturePath(Directory, Fields[0]));
    except
      on EMediaUnsupported do
      begin
        WriteLn('skip vorbis: ', Fields[0], ' through the Ogg demuxer (Ogg not read)');
        Exit;
      end;
      on Error: Exception do
      begin
        Check(False, 'vorbis: ' + Fields[0] + ' decodes through the Ogg demuxer (' + Error.Message + ')');
        Exit;
      end;
    end;
    Expected := ReadF32Reference(FixturePath(Directory, Fields[1]));
    if Decoded.Channels <= 0 then
      Decoded.Channels := 1;
    Offset := FindAlignment(Decoded.Samples, Expected, Decoded.Channels);
    Aligned := Copy(Decoded.Samples, Offset * Decoded.Channels, Length(Decoded.Samples));
    Snr := SignalToNoise(Aligned, Expected);
    Check((Decoded.Codec = codecVorbis) and (Snr >= MinimumSnr),
      Format('vorbis: %s through the Ogg demuxer matches libvorbis (SNR %.1f dB)', [Fields[0], Snr]));
  finally
    Fields.Free;
  end;
end;

procedure RunVorbisTests(const FixtureRoot: string);
var
  Directory, Line: string;
  Lines: TStringList;
begin
  CheckMdct(64);
  CheckMdct(256);
  CheckMdct(2048);
  CheckHeaderHandling;
  Directory := FixturePath(FixtureRoot, 'vorbis');
  Lines := ReadManifestLines(FixturePath(Directory, 'manifest.txt'));
  try
    if Lines.Count = 0 then
      WriteLn('skip vorbis: no fixtures (', Directory, ')');
    for Line in Lines do
      CheckFixture(Directory, Line);
    for Line in Lines do
      CheckThroughDemuxer(Directory, Line);
  finally
    Lines.Free;
  end;
end;

end.
