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
  Tests of the FLAC decoder and file reader, over the files the host's
  flac made from WAV files (make-flac-fixtures.py): FLAC is lossless, so
  the decoded samples must be exactly the WAV's, and their MD5 the one in
  STREAMINFO; seeking must land on the frame holding the target with the
  same samples as the WAV there. Damaged frames must be refused, never
  crash.
}
unit MediaTest.Flac;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

procedure RunFlacTests(const FixtureRoot: string);

implementation

uses
  Classes,
  SysUtils,
  md5,
  TestChecks,
  MediaTest.Common,
  Media.Errors,
  Media.Frames,
  Media.Packets,
  Media.Demuxers,
  Media.FlacFile,
  Media.Flac,
  Media.Flac.Headers;

{ The MD5 FLAC computes over the decoder's integer samples: little-endian
  integers of whole bytes, interleaved, frame after frame. }
function DecodedMd5(const Path: string): string;
var
  Demuxer: TFlacDemuxer;
  Decoder: TFlacDecoder;
  Packet: TMediaPacket;
  Context: TMD5Context;
  Digest: TMD5Digest;
  Bytes: TBytes;
  Index, Channel, ByteIndex, SampleBytes, Position: Integer;
  Value: Int64;
begin
  Demuxer := TFlacDemuxer.Create(TFileStream.Create(Path, fmOpenRead or fmShareDenyNone), True);
  Decoder := TFlacDecoder.Create;
  try
    Demuxer.Open;
    Decoder.Configure(Demuxer.Tracks[0]);
    MD5Init(Context);
    Bytes := nil;
    while Demuxer.ReadPacket(Packet) do
    begin
      Decoder.DecodeFrameIntegers(@Packet.Data[0], Length(Packet.Data));
      SampleBytes := (Decoder.BitsPerSample + 7) div 8;
      SetLength(Bytes, Decoder.BlockSize * Decoder.Channels * SampleBytes);
      Position := 0;
      for Index := 0 to Decoder.BlockSize - 1 do
        for Channel := 0 to Decoder.Channels - 1 do
        begin
          Value := Decoder.Samples(Channel)[Index];
          for ByteIndex := 0 to SampleBytes - 1 do
          begin
            Bytes[Position] := (Value shr (8 * ByteIndex)) and $FF;
            Inc(Position);
          end;
        end;
      if Position > 0 then
        MD5Update(Context, Bytes[0], Position);
    end;
    MD5Final(Context, Digest);
    Result := MD5Print(Digest);
  finally
    Decoder.Free;
    Demuxer.Free;
  end;
end;

function StreamInfoMd5(const Path: string; out Info: TFlacStreamInfo): string;
var
  Demuxer: TFlacDemuxer;
  Index: Integer;
begin
  Result := '';
  Demuxer := TFlacDemuxer.Create(TFileStream.Create(Path, fmOpenRead or fmShareDenyNone), True);
  try
    Demuxer.Open;
    ParseFlacStreamInfo(Demuxer.Tracks[0].Headers[0], Info);
    for Index := 0 to 15 do
      Result := Result + LowerCase(IntToHex(Info.Md5[Index], 2));
  finally
    Demuxer.Free;
  end;
end;

procedure CheckSeeking(const Path: string; const Reference: TDecodedAudio);
const
  { Thousandths of the duration. }
  Targets: array[0..4] of Int64 = (250, 600, 0, 950, 389);
var
  Demuxer: TFlacDemuxer;
  Decoder: TFlacDecoder;
  Packet: TMediaPacket;
  Buffer: TAudioBuffer;
  Fraction, Target, TargetSample, Offset: Int64;
  Index, Channels: Integer;
  Matches: Boolean;
begin
  Demuxer := TFlacDemuxer.Create(TFileStream.Create(Path, fmOpenRead or fmShareDenyNone), True);
  Decoder := TFlacDecoder.Create;
  try
    Demuxer.Open;
    Decoder.Configure(Demuxer.Tracks[0]);
    Channels := Reference.Channels;
    Buffer := Default(TAudioBuffer);
    for Fraction in Targets do
    begin
      Target := Demuxer.Duration * Fraction div 1000;
      TargetSample := Demuxer.Tracks[0].FromMicroseconds(Target);
      Check(Demuxer.SeekTo(Target), Format('flac %s seeks to %d us', [ExtractFileName(Path), Target]));
      if not Demuxer.ReadPacket(Packet) then
      begin
        Check(False, 'flac packet after the seek');
        Continue;
      end;
      Check((Packet.PresentationTime <= TargetSample) and (Packet.PresentationTime + Packet.Duration > TargetSample),
        Format('flac %s seek to %d lands on the frame holding it (frame at %d, %d long)',
        [ExtractFileName(Path), TargetSample, Packet.PresentationTime, Packet.Duration]));
      Decoder.Decode(Packet, Buffer);
      Matches := True;
      Offset := Packet.PresentationTime * Channels;
      for Index := 0 to High(Buffer.Samples) do
        if (Offset + Index > High(Reference.Samples)) or (Buffer.Samples[Index] <> Reference.Samples[Offset + Index]) then
        begin
          Matches := False;
          Break;
        end;
      Check(Matches, Format('flac %s frame after seeking to %d has the reference samples', [ExtractFileName(Path),
        Target]));
    end;
  finally
    Decoder.Free;
    Demuxer.Free;
  end;
end;

procedure CheckFlacFile(const Directory, FlacName, WavName, Options: string);
var
  Decoded, Reference: TDecodedAudio;
  Info: TFlacStreamInfo;
  ExpectedMd5: string;
begin
  try
    Decoded := DecodeAudioFile(FixturePath(Directory, FlacName));
    Reference := DecodeAudioFile(FixturePath(Directory, WavName));
  except
    on Error: Exception do
    begin
      Check(False, Format('flac %s decodes (%s)', [FlacName, Error.Message]));
      Exit;
    end;
  end;
  Check(Decoded.FormatName = 'flac', Format('flac %s is read as FLAC (%s)', [FlacName, Decoded.FormatName]));
  Check((Decoded.SampleRate = Reference.SampleRate) and (Decoded.Channels = Reference.Channels),
    Format('flac %s: %d Hz, %d channels', [FlacName, Decoded.SampleRate, Decoded.Channels]));
  Check(SameSamples(Decoded.Samples, Reference.Samples),
    Format('flac %s decodes to the WAV''s samples (%d of %d)', [FlacName, Length(Decoded.Samples),
    Length(Reference.Samples)]));
  ExpectedMd5 := StreamInfoMd5(FixturePath(Directory, FlacName), Info);
  Check(DecodedMd5(FixturePath(Directory, FlacName)) = ExpectedMd5,
    Format('flac %s matches its STREAMINFO MD5', [FlacName]));
  if Options = 'seek' then
    CheckSeeking(FixturePath(Directory, FlacName), Reference);
end;

procedure CheckDamagedFrames(const Directory, FlacName: string);
var
  Demuxer: TFlacDemuxer;
  Decoder: TFlacDecoder;
  Packet: TMediaPacket;
  Buffer: TAudioBuffer;
  Refused, Decoded, Index, Position: Integer;
  Generator: LongWord;
begin
  Demuxer := TFlacDemuxer.Create(TFileStream.Create(FixturePath(Directory, FlacName), fmOpenRead or
    fmShareDenyNone), True);
  Decoder := TFlacDecoder.Create;
  try
    Demuxer.Open;
    Decoder.Configure(Demuxer.Tracks[0]);
    Refused := 0;
    Decoded := 0;
    Generator := 12345;
    Buffer := Default(TAudioBuffer);
    while Demuxer.ReadPacket(Packet) do
    begin
      { Flip a few bytes, or cut the frame short. }
      for Index := 1 to 3 do
      begin
        Generator := LongWord((QWord(Generator) * 1103515245 + 12345) and $FFFFFFFF);
        Position := (Generator shr 8) mod LongWord(Length(Packet.Data));
        Packet.Data[Position] := Packet.Data[Position] xor $5A;
      end;
      if (Generator and 3) = 0 then
        SetLength(Packet.Data, Length(Packet.Data) div 2);
      try
        Decoder.Decode(Packet, Buffer);
        Inc(Decoded);
      except
        on EMediaError do
          Inc(Refused);
      end;
    end;
    Check((Refused > 0) and (Refused + Decoded > 0), Format('flac damaged frames are refused (%d refused, %d passed)',
      [Refused, Decoded]));
  finally
    Decoder.Free;
    Demuxer.Free;
  end;
end;

procedure RunFlacTests(const FixtureRoot: string);
var
  Directory: string;
  Lines, Fields: TStringList;
  Line: string;
  FlacCount: Integer;
begin
  Directory := FixturePath(FixtureRoot, 'flac');
  Lines := ReadManifestLines(FixturePath(Directory, 'manifest.txt'));
  try
    FlacCount := 0;
    for Line in Lines do
    begin
      Fields := SplitFields(Line);
      try
        if (Fields.Count >= 3) and (Fields[0] <> 'wav') then
        begin
          CheckFlacFile(Directory, Fields[0], Fields[1], Fields[2]);
          Inc(FlacCount);
        end;
      finally
        Fields.Free;
      end;
    end;
    if FlacCount = 0 then
      WriteLn('skip flac: no fixtures (no flac on the host)')
    else
      CheckDamagedFrames(Directory, 's16-stereo-44100.flac');
  finally
    Lines.Free;
  end;
end;

end.
