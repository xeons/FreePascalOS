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
  Tests of the MP3 decoder and the MP3 file reader, over the files
  make-mp3-fixtures.py makes with lame (FIXTURES/mp3/manifest.txt).

  Each file is decoded through libmedia (container, then decoder) and
  compared with ffmpeg's floating point decoding by the accuracy test of
  ISO/IEC 11172-4: the RMS difference must stay below 2^-15 / sqrt(12)
  of full scale ("full accuracy") and no sample may differ by more than
  2^-14. Free format, which ffmpeg does not read, is compared with lame's
  own 16-bit decoding to within one step. The decoder is also fed a file
  in uneven pieces, and the reader seeks.
}
unit MediaTest.Mp3;

{$mode objfpc}
{$H+}

interface

procedure RunMp3Tests(const FixtureRoot: string);

implementation

uses
  Classes,
  SysUtils,
  Math,
  DateUtils,
  TestChecks,
  MediaTest.Common,
  Media.Frames,
  Media.Errors,
  Media.Packets,
  Media.Demuxers,
  Media.Containers,
  Media.AudioDecoders,
  Media.AudioCodecs,
  Media.Mp3,
  Media.Mp3.Header,
  Media.Mp3.Tags,
  Media.Mp3File;

const
  { ISO/IEC 11172-4 full accuracy, relative to full scale (1.0). }
  FullAccuracyRms = 8.8e-6;
  FullAccuracyLargest = 6.1035e-5;

function RootMeanSquareDifference(const Actual, Expected: TFloatArray): Double;
var
  Index, Count: Integer;
  Sum: Double;
begin
  Count := Min(Length(Actual), Length(Expected));
  if Count = 0 then
    Exit(0);
  Sum := 0;
  for Index := 0 to Count - 1 do
    Sum := Sum + Sqr(Double(Actual[Index]) - Expected[Index]);
  Result := Sqrt(Sum / Count);
end;

procedure CompareWithReference(const Name: string; const Actual, Expected: TFloatArray);
var
  Rms, Largest: Double;
begin
  Rms := RootMeanSquareDifference(Actual, Expected);
  Largest := LargestDifference(Actual, Expected);
  WriteLn(Format('     %s: %d samples (reference %d), SNR %.1f dB, RMS %.3g, largest %.3g',
    [Name, Length(Actual), Length(Expected), SignalToNoise(Actual, Expected), Rms, Largest]));
  Check(Length(Actual) = Length(Expected), Name + ': as many samples as the reference');
  Check(Rms < FullAccuracyRms, Name + ': RMS difference within full accuracy');
  Check(Largest < FullAccuracyLargest, Name + ': largest difference within 2^-14');
end;

procedure CheckDecode(const Directory: string; Fields: TStringList);
var
  Decoded: TDecodedAudio;
  Expected: TFloatArray;
  Name: string;
begin
  Name := Fields[1];
  try
    Decoded := DecodeAudioFile(FixturePath(Directory, Name));
  except
    on Error: Exception do
    begin
      Check(False, Name + ': decodes (' + Error.Message + ')');
      Exit;
    end;
  end;
  Check(Decoded.Codec = codecMp3, Name + ': an MP3 track');
  Check(Decoded.SampleRate = StrToInt(Fields[3]), Name + ': sample rate');
  Check(Decoded.Channels = StrToInt(Fields[4]), Name + ': channels');
  Expected := ReadF32Reference(FixturePath(Directory, Fields[2]));
  CompareWithReference(Name, Decoded.Samples, Expected);
end;

procedure CheckDecode16(const Directory: string; Fields: TStringList);
var
  Decoded: TDecodedAudio;
  Expected, Trimmed: TFloatArray;
  Name: string;
  Skip, Mismatches: Integer;
begin
  Name := Fields[1];
  try
    Decoded := DecodeAudioFile(FixturePath(Directory, Name));
  except
    on Error: Exception do
    begin
      Check(False, Name + ': decodes (' + Error.Message + ')');
      Exit;
    end;
  end;
  Check(Decoded.SampleRate = StrToInt(Fields[3]), Name + ': sample rate');
  Check(Decoded.Channels = StrToInt(Fields[4]), Name + ': channels');
  Skip := StrToInt(Fields[5]) * Decoded.Channels;
  Trimmed := Copy(Decoded.Samples, Skip, Length(Decoded.Samples) - Skip);
  Expected := ReadS16Reference(FixturePath(Directory, Fields[2]));
  Mismatches := CountS16Mismatches(Trimmed, Expected, 1);
  WriteLn(Format('     %s: %d samples (reference %d), SNR %.1f dB, %d differ by more than one step',
    [Name, Length(Trimmed), Length(Expected), SignalToNoise(Trimmed, Expected), Mismatches]));
  Check(Length(Trimmed) = Length(Expected), Name + ': as many samples as lame''s decoding');
  Check(Mismatches = 0, Name + ': within one 16-bit step of lame''s decoding');
end;

procedure CheckPieces(const Directory: string; Fields: TStringList);
var
  Data, Piece: TBytes;
  Decoder: TMp3Decoder;
  Track: TMediaTrack;
  Packet: TMediaPacket;
  Buffer: TAudioBuffer;
  Output, Expected: TFloatArray;
  Generator: Integer;
  Position, Size, Count: Integer;
  Name: string;
begin
  Name := Fields[1] + ' in pieces';
  Data := ReadFileBytes(FixturePath(Directory, Fields[1]));
  Track := TMediaTrack.Create;
  Decoder := TMp3Decoder.Create;
  try
    Track.Kind := mkAudio;
    Track.Codec := codecMp3;
    Track.SampleRate := StrToInt(Fields[3]);
    Track.Channels := StrToInt(Fields[4]);
    Decoder.Configure(Track);
    Output := nil;
    Count := 0;
    Position := 0;
    Generator := 12345;
    Buffer := Default(TAudioBuffer);
    while Position < Length(Data) do
    begin
      Generator := (Generator * 1103515245 + 12345) and $7FFFFFFF;
      Size := 1 + Generator mod 2500;
      if Position + Size > Length(Data) then
        Size := Length(Data) - Position;
      Piece := Copy(Data, Position, Size);
      Inc(Position, Size);
      Packet := NewPacket(0);
      Packet.Data := Piece;
      Decoder.Decode(Packet, Buffer);
      SetLength(Output, Count + Length(Buffer.Samples));
      if Length(Buffer.Samples) > 0 then
        Move(Buffer.Samples[0], Output[Count], Length(Buffer.Samples) * SizeOf(Single));
      Inc(Count, Length(Buffer.Samples));
    end;
    Expected := ReadF32Reference(FixturePath(Directory, Fields[2]));
    CompareWithReference(Name, Output, Expected);
  finally
    Decoder.Free;
    Track.Free;
  end;
end;

procedure CheckSeek(const Directory: string; Fields: TStringList);
var
  Demuxer: TMediaDemuxer;
  Track: TMediaTrack;
  Decoder: TAudioDecoder;
  Packet: TMediaPacket;
  Buffer: TAudioBuffer;
  Target, FirstTime: Int64;
  Decoded, PacketCount, Index: Integer;
  Finite: Boolean;
  Name: string;
begin
  Name := Fields[1];
  Demuxer := OpenMediaFile(FixturePath(Directory, Name));
  try
    Track := Demuxer.Tracks[0];
    Check(Demuxer.Duration > 0, Name + ': duration known');
    Target := Demuxer.Duration div 2;
    Check(Demuxer.SeekTo(Target), Name + ': seeks to the middle');
    Decoder := CreateAudioDecoder(Track);
    try
      Decoder.Reset;
      FirstTime := NoTimestamp;
      Decoded := 0;
      PacketCount := 0;
      Finite := True;
      Buffer := Default(TAudioBuffer);
      while (PacketCount < 10) and Demuxer.ReadPacket(Packet) do
      begin
        if FirstTime = NoTimestamp then
          FirstTime := Track.ToMicroseconds(Packet.PresentationTime);
        Decoder.Decode(Packet, Buffer);
        for Index := 0 to High(Buffer.Samples) do
          if IsNan(Buffer.Samples[Index]) or IsInfinite(Buffer.Samples[Index]) then
            Finite := False;
        Inc(Decoded, Length(Buffer.Samples));
        Inc(PacketCount);
      end;
      Check(PacketCount = 10, Name + ': packets after the seek');
      Check(Decoded > 0, Name + ': audio after the seek');
      Check(Finite, Name + ': finite samples after the seek');
      WriteLn(Format('     %s: seek to %d us landed at %d us', [Name, Target, FirstTime]));
      Check(Abs(FirstTime - Target) < 100000, Name + ': lands within 100 ms of the target');
      Check(Demuxer.SeekTo(0), Name + ': seeks back to the start');
      Check(Demuxer.ReadPacket(Packet) and (Packet.PresentationTime = -Track.CodecDelay),
        Name + ': the first packet again');
    finally
      Decoder.Free;
    end;
  finally
    Demuxer.Free;
  end;
end;

{ Damaged copies of a file (bytes overwritten here and there) must decode
  without crashing: errors are EMediaError at most, samples finite. }
procedure CheckDamage(const Directory, Name: string);
var
  Original, Data: TBytes;
  Decoder: TMp3Decoder;
  Track: TMediaTrack;
  Packet: TMediaPacket;
  Buffer: TAudioBuffer;
  Seed, Generator, Damage, Position, Size, Index: Integer;
  Survived, Finite: Boolean;
begin
  if not FileExists(FixturePath(Directory, Name)) then
    Exit;
  Original := ReadFileBytes(FixturePath(Directory, Name));
  Survived := True;
  Finite := True;
  for Seed := 1 to 8 do
  begin
    Data := Copy(Original, 0, Length(Original));
    Generator := Seed * 7777;
    for Damage := 1 to 40 * Seed do
    begin
      Generator := (Generator * 1103515245 + 12345) and $7FFFFFFF;
      Index := Generator mod Length(Data);
      Generator := (Generator * 1103515245 + 12345) and $7FFFFFFF;
      Data[Index] := Generator and $FF;
    end;
    Track := TMediaTrack.Create;
    Decoder := TMp3Decoder.Create;
    try
      Track.SampleRate := 44100;
      Track.Channels := 2;
      Decoder.Configure(Track);
      Buffer := Default(TAudioBuffer);
      Position := 0;
      while Position < Length(Data) do
      begin
        Generator := (Generator * 1103515245 + 12345) and $7FFFFFFF;
        Size := 1 + Generator mod 1500;
        if Position + Size > Length(Data) then
          Size := Length(Data) - Position;
        Packet := NewPacket(0);
        Packet.Data := Copy(Data, Position, Size);
        Inc(Position, Size);
        try
          Decoder.Decode(Packet, Buffer);
          for Index := 0 to High(Buffer.Samples) do
            if IsNan(Buffer.Samples[Index]) or IsInfinite(Buffer.Samples[Index]) then
              Finite := False;
        except
          on EMediaError do
            ;
          on Error: Exception do
          begin
            WriteLn('     damage seed ', Seed, ': ', Error.ClassName, ': ', Error.Message);
            Survived := False;
            Break;
          end;
        end;
      end;
    finally
      Decoder.Free;
      Track.Free;
    end;
  end;
  Check(Survived, Name + ': damaged copies decode without crashing');
  Check(Finite, Name + ': damaged copies decode to finite samples');
end;

procedure CheckHeaders;
const
  { MPEG-1 layer III 128 kbit/s 44.1 kHz joint stereo, padded. }
  Mpeg1: array[0..3] of Byte = ($FF, $FB, $92, $64);
  { MPEG-2 layer III 64 kbit/s 22.05 kHz stereo. }
  Mpeg2: array[0..3] of Byte = ($FF, $F3, $80, $00);
  { MPEG-2.5 layer III 8 kbit/s 8 kHz mono. }
  Mpeg25: array[0..3] of Byte = ($FF, $E3, $18, $C0);
  Id3: array[0..9] of Byte = (Ord('I'), Ord('D'), Ord('3'), 4, 0, $10, 0, 0, 2, 1);
var
  Garbage: TBytes;
  Index: Integer;
begin
  Check(HeaderIsValid(@Mpeg1[0]) and (HeaderBitrateKbps(@Mpeg1[0]) = 128) and (HeaderSampleRate(@Mpeg1[0]) = 44100)
    and (HeaderFullFrameBytes(@Mpeg1[0], 0) = 418) and (HeaderChannels(@Mpeg1[0]) = 2), 'mp3: MPEG-1 header');
  Check(HeaderIsValid(@Mpeg2[0]) and (HeaderBitrateKbps(@Mpeg2[0]) = 64) and (HeaderSampleRate(@Mpeg2[0]) = 22050)
    and (HeaderFrameSamples(@Mpeg2[0]) = 576) and (HeaderFullFrameBytes(@Mpeg2[0], 0) = 208), 'mp3: MPEG-2 header');
  Check(HeaderIsValid(@Mpeg25[0]) and (HeaderBitrateKbps(@Mpeg25[0]) = 8) and (HeaderSampleRate(@Mpeg25[0]) = 8000)
    and HeaderIsMono(@Mpeg25[0]) and (HeaderFullFrameBytes(@Mpeg25[0], 0) = 72), 'mp3: MPEG-2.5 header');
  Check(Id3v2TagLength(@Id3[0], 10) = 10 + 257 + 10, 'mp3: ID3v2 length with footer');
  SetLength(Garbage, 8192);
  for Index := 0 to High(Garbage) do
    Garbage[Index] := (Index * 7919 + 13) and $FF;
  Check(not TMp3Demuxer.Recognizes(Garbage), 'mp3: noise is not taken for MP3');
end;

procedure RunMp3Tests(const FixtureRoot: string);
var
  Directory: string;
  Lines, Fields: TStringList;
  Line: string;
  Started: TDateTime;
begin
  CheckHeaders;
  Directory := FixturePath(FixtureRoot, 'mp3');
  Lines := ReadManifestLines(FixturePath(Directory, 'manifest.txt'));
  try
    if Lines.Count = 0 then
      WriteLn('skip mp3 fixtures (none made: see ', FixturePath(Directory, 'manifest.txt'), ')');
    Started := Now;
    for Line in Lines do
    begin
      Fields := SplitFields(Line);
      try
        try
          if Fields[0] = 'decode' then
            CheckDecode(Directory, Fields)
          else if Fields[0] = 'decode16' then
            CheckDecode16(Directory, Fields)
          else if Fields[0] = 'pieces' then
            CheckPieces(Directory, Fields)
          else if Fields[0] = 'seek' then
            CheckSeek(Directory, Fields);
        except
          on Error: Exception do
            Check(False, Line + ': ' + Error.ClassName + ': ' + Error.Message);
        end;
      finally
        Fields.Free;
      end;
    end;
    if Lines.Count > 0 then
    begin
      CheckDamage(Directory, 'vbr-v0-44k.mp3');
      CheckDamage(Directory, 'castanets-128-44k.mp3');
    end;
    WriteLn(Format('     mp3 fixtures took %d ms', [MilliSecondsBetween(Now, Started)]));
  finally
    Lines.Free;
  end;
end;

end.
