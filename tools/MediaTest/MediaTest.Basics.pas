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
  Tests of libmedia's common parts: Y'CbCr to BGRA conversion (known
  colours in each matrix, range and depth), times, PCM decoding and
  trimming, the WAV reader over every sample kind (against the floats
  the fixtures were made from), the resampler (length, a tone's accuracy,
  aliasing rejection, chunking not changing the result), the channel
  mixer's matrices and the output sample encoding.
}
unit MediaTest.Basics;

{$mode objfpc}
{$H+}

interface

procedure RunBasicTests(const FixtureRoot: string);

implementation

uses
  Classes,
  SysUtils,
  Math,
  TestChecks,
  MediaTest.Common,
  Media.Frames,
  Media.Packets,
  Media.Pcm,
  Media.Resampler,
  Media.ChannelMixer,
  Media.AudioConversion;

function Near(Actual, Expected, Tolerance: Integer): Boolean;
begin
  Result := Abs(Actual - Expected) <= Tolerance;
end;

procedure SetSample(var Plane: TVideoPlane; BitDepth, Value: Integer);
var
  Index: Integer;
begin
  for Index := 0 to Plane.Width * Plane.Height - 1 do
    if BitDepth > 8 then
    begin
      Plane.Data[(Index div Plane.Width) * Plane.Stride + (Index mod Plane.Width) * 2] := Value and $FF;
      Plane.Data[(Index div Plane.Width) * Plane.Stride + (Index mod Plane.Width) * 2 + 1] := Value shr 8;
    end
    else
      Plane.Data[(Index div Plane.Width) * Plane.Stride + Index mod Plane.Width] := Value;
end;

procedure CheckColour(const Name: string; BitDepth, Matrix: Integer; FullRange: Boolean; Layout: TPixelLayout;
  Y, U, V, Blue, Green, Red, Tolerance: Integer);
var
  Frame: TVideoFrame;
  Pixels: array[0..4 * 4 * 4 - 1] of Byte;
  Index: Integer;
  Same: Boolean;
begin
  AllocateVideoFrame(Frame, 4, 4, BitDepth, Layout);
  Frame.MatrixCoefficients := Matrix;
  Frame.FullRange := FullRange;
  SetSample(Frame.Planes[0], BitDepth, Y);
  if Layout <> plMonochrome then
  begin
    SetSample(Frame.Planes[1], BitDepth, U);
    SetSample(Frame.Planes[2], BitDepth, V);
  end;
  FillChar(Pixels, SizeOf(Pixels), 0);
  ConvertFrameToBgra(Frame, @Pixels[0], 16);
  Same := True;
  for Index := 0 to 15 do
    if (Pixels[Index * 4] <> Pixels[0]) or (Pixels[Index * 4 + 1] <> Pixels[1]) or (Pixels[Index * 4 + 2] <> Pixels[2])
      or (Pixels[Index * 4 + 3] <> 255) then
      Same := False;
  Check(Same and Near(Pixels[0], Blue, Tolerance) and Near(Pixels[1], Green, Tolerance) and
    Near(Pixels[2], Red, Tolerance), Format('colour %s: BGR %d,%d,%d (wanted %d,%d,%d)', [Name, Pixels[0], Pixels[1],
    Pixels[2], Blue, Green, Red]));
end;

procedure CheckColourConversion;
begin
  CheckColour('601 limited black', 8, MatrixSmpte170m, False, pl420, 16, 128, 128, 0, 0, 0, 0);
  CheckColour('601 limited white', 8, MatrixSmpte170m, False, pl420, 235, 128, 128, 255, 255, 255, 0);
  CheckColour('601 limited red', 8, MatrixSmpte170m, False, pl420, 81, 90, 240, 0, 0, 255, 2);
  CheckColour('601 limited green', 8, MatrixSmpte170m, False, pl422, 145, 54, 34, 0, 255, 0, 2);
  CheckColour('601 limited blue', 8, MatrixSmpte170m, False, pl444, 41, 240, 110, 255, 0, 0, 2);
  CheckColour('709 limited red', 8, MatrixBt709, False, pl420, 63, 102, 240, 0, 0, 255, 2);
  CheckColour('709 full white', 8, MatrixBt709, True, pl420, 255, 128, 128, 255, 255, 255, 0);
  CheckColour('2020 10-bit limited white', 10, MatrixBt2020NonConstant, False, pl420, 940, 512, 512, 255, 255, 255, 0);
  CheckColour('2020 10-bit limited black', 10, MatrixBt2020NonConstant, False, pl420, 64, 512, 512, 0, 0, 0, 0);
  CheckColour('709 12-bit limited grey', 12, MatrixBt709, False, pl444, 2008, 2048, 2048, 128, 128, 128, 1);
  CheckColour('identity GBR', 8, MatrixIdentity, True, pl444, 10, 20, 30, 20, 10, 30, 0);
  CheckColour('monochrome grey', 8, MatrixBt709, False, plMonochrome, 126, 0, 0, 128, 128, 128, 1);
end;

procedure CheckTimes;
var
  Track: TMediaTrack;
begin
  Track := TMediaTrack.Create;
  try
    Track.TimeBase := MakeTimeBase(1, 48000);
    Check(Track.ToMicroseconds(48000) = 1000000, 'time: 48000 samples are a second');
    Check(Track.FromMicroseconds(500000) = 24000, 'time: half a second is 24000 samples');
    Track.TimeBase := MakeTimeBase(1, 1000000000);
    Check(Track.ToMicroseconds(Int64(3600) * 1000000000 * 24) = Int64(3600) * 1000000 * 24,
      'time: a day of nanoseconds does not overflow');
    Check(ScaleTime(-1, 1, 2) = -1, 'time: negative times round down');
  finally
    Track.Free;
  end;
end;

procedure CheckPcmAndTrimming;
var
  Track: TMediaTrack;
  Decoder: TPcmDecoder;
  Packet: TMediaPacket;
  Buffer: TAudioBuffer;
begin
  Track := TMediaTrack.Create;
  Decoder := TPcmDecoder.Create;
  try
    Track.Codec := codecPcm;
    Track.SampleRate := 8000;
    Track.Channels := 2;
    Track.BitsPerSample := 16;
    Track.PcmBigEndian := True;
    Track.CodecDelay := 1;
    Decoder.Configure(Track);
    Packet := NewPacket(0);
    { Four frames of big-endian 16-bit: (1,2) (3,4) (-32768,32767) (0,16384). }
    Packet.Data := TBytes.Create(0, 1, 0, 2, 0, 3, 0, 4, $80, 0, $7F, $FF, 0, 0, $40, 0);
    Packet.TrimEnd := 1;
    Buffer := Default(TAudioBuffer);
    Decoder.Decode(Packet, Buffer);
    Check((Length(Buffer.Samples) = 4) and (Buffer.Samples[0] = 3 / 32768) and (Buffer.Samples[2] = -1) and
      (Buffer.Samples[3] = 32767 / 32768), 'pcm: big-endian 16-bit with a codec delay and an end trim');
  finally
    Decoder.Free;
    Track.Free;
  end;
end;

procedure CheckWavFile(const Directory: string; Fields: TStringList);
var
  Decoded: TDecodedAudio;
  Expected: TFloatArray;
  Bits, Channels, Rate, Frames: Integer;
  Tolerance: Double;
begin
  Bits := StrToInt(Fields[2]);
  Channels := StrToInt(Fields[4]);
  Rate := StrToInt(Fields[5]);
  Frames := StrToInt(Fields[6]);
  try
    Decoded := DecodeAudioFile(FixturePath(Directory, Fields[1]));
  except
    on Error: Exception do
    begin
      Check(False, Format('wav %s decodes (%s)', [Fields[1], Error.Message]));
      Exit;
    end;
  end;
  Expected := ReadF32Reference(FixturePath(Directory, Fields[1] + '.f32'));
  if Fields[3] = '1' then
    Tolerance := 1e-7
  else
    { Single floats hold 24 bits: 32-bit integers come within that. }
    Tolerance := Max(1.0 / (Int64(1) shl (Bits - 1)), 6e-8);
  Check((Decoded.FormatName = 'wav') and (Decoded.SampleRate = Rate) and (Decoded.Channels = Channels) and
    (Length(Decoded.Samples) = Frames * Channels), Format('wav %s: %d Hz, %d channels, %d frames', [Fields[1],
    Decoded.SampleRate, Decoded.Channels, Length(Decoded.Samples) div Max(1, Decoded.Channels)]));
  Check(LargestDifference(Decoded.Samples, Expected) <= Tolerance, Format('wav %s samples within %g (largest %g)',
    [Fields[1], Tolerance, LargestDifference(Decoded.Samples, Expected)]));
end;

procedure CheckWavFiles(const FixtureRoot: string);
var
  Directory, Line: string;
  Lines, Fields: TStringList;
  Count: Integer;
begin
  Directory := FixturePath(FixtureRoot, 'flac');
  Lines := ReadManifestLines(FixturePath(Directory, 'manifest.txt'));
  Count := 0;
  try
    for Line in Lines do
    begin
      Fields := SplitFields(Line);
      try
        if (Fields.Count >= 7) and (Fields[0] = 'wav') then
        begin
          CheckWavFile(Directory, Fields);
          Inc(Count);
        end;
      finally
        Fields.Free;
      end;
    end;
  finally
    Lines.Free;
  end;
  Check(Count > 0, 'wav fixtures are there');
end;

function Tone(Rate, Frames: Integer; Frequency: Double): TSampleArray;
var
  Index: Integer;
begin
  Result := nil;
  SetLength(Result, Frames);
  for Index := 0 to Frames - 1 do
    Result[Index] := 0.5 * Sin(2 * Pi * Frequency * Index / Rate);
end;

function ResampleAll(InputRate, OutputRate: Integer; const Input: TSampleArray; Chunk: Integer): TSampleArray;
var
  Resampler: TResampler;
  Piece, Output: TSampleArray;
  Offset, Count: Integer;
begin
  Result := nil;
  Resampler := TResampler.Create(InputRate, OutputRate, 1);
  try
    Offset := 0;
    while Offset < Length(Input) do
    begin
      Count := Min(Chunk, Length(Input) - Offset);
      Piece := Copy(Input, Offset, Count);
      Output := Resampler.Process(Piece, Count);
      Result := Concat(Result, Output);
      Inc(Offset, Count);
    end;
    Result := Concat(Result, Resampler.Flush);
  finally
    Resampler.Free;
  end;
end;

{ The RMS of Signal against an ideal tone, away from the edges. }
function ToneError(const Signal: TSampleArray; Rate: Integer; Frequency: Double): Double;
var
  Index, Count: Integer;
  Sum: Double;
begin
  Sum := 0;
  Count := 0;
  for Index := 100 to Length(Signal) - 101 do
  begin
    Sum := Sum + Sqr(Signal[Index] - 0.5 * Sin(2 * Pi * Frequency * Index / Rate));
    Inc(Count);
  end;
  Result := Sqrt(Sum / Max(1, Count));
end;

function Rms(const Signal: TSampleArray): Double;
var
  Index: Integer;
  Sum: Double;
begin
  Sum := 0;
  for Index := 100 to Length(Signal) - 101 do
    Sum := Sum + Sqr(Signal[Index]);
  Result := Sqrt(Sum / Max(1, Length(Signal) - 200));
end;

procedure CheckResampler;
var
  Input, Whole, Chunked: TSampleArray;
  Index: Integer;
  Same: Boolean;
begin
  Input := Tone(44100, 44100, 1000);
  Whole := ResampleAll(44100, 48000, Input, Length(Input));
  Check(Length(Whole) = 48000, Format('resampler: 44100 frames at 44.1 kHz become 48000 at 48 kHz (%d)',
    [Length(Whole)]));
  Check(ToneError(Whole, 48000, 1000) < 1e-3, Format('resampler: a 1 kHz tone stays accurate (RMS error %g)',
    [ToneError(Whole, 48000, 1000)]));
  Chunked := ResampleAll(44100, 48000, Input, 333);
  Same := Length(Chunked) = Length(Whole);
  if Same then
    for Index := 0 to High(Whole) do
      if Abs(Chunked[Index] - Whole[Index]) > 1e-6 then
        Same := False;
  Check(Same, 'resampler: feeding in pieces gives the same output');
  Input := Tone(48000, 48000, 6000);
  Whole := ResampleAll(48000, 8000, Input, 4096);
  Check((Length(Whole) = 8000) and (Rms(Whole) < 0.5 * 0.7071 * 0.01),
    Format('resampler: a 6 kHz tone is filtered out going to 8 kHz (RMS %g)', [Rms(Whole)]));
  Input := Tone(22050, 22050, 3000);
  Whole := ResampleAll(22050, 47999, Input, 1000);
  Check((Length(Whole) = 47999) and (ToneError(Whole, 47999, 3000) < 2e-3),
    Format('resampler: an odd ratio (22050 to 47999) keeps a 3 kHz tone (RMS error %g)', [ToneError(Whole, 47999,
    3000)]));
end;

procedure CheckChannelMixer;
var
  Mixer: TChannelMixer;
  Output: TSampleArray;
  Total: Single;
begin
  Mixer := TChannelMixer.Create(2, 1);
  try
    Output := Mixer.Mix(TSampleArray.Create(0.25, 0.75), 1);
    Check(Abs(Output[0] - 0.5) < 1e-6, 'mixer: stereo to mono averages');
  finally
    Mixer.Free;
  end;
  Mixer := TChannelMixer.Create(1, 2);
  try
    Output := Mixer.Mix(TSampleArray.Create(0.5), 1);
    Check((Output[0] = 0.5) and (Output[1] = 0.5), 'mixer: mono to stereo duplicates');
  finally
    Mixer.Free;
  end;
  Mixer := TChannelMixer.Create(6, 2);
  try
    Total := 1 + 0.70710678 + 0.70710678;
    Check((Abs(Mixer.Weight(0, 0) - 1 / Total) < 1e-5) and (Abs(Mixer.Weight(0, 2) - 0.70710678 / Total) < 1e-5) and
      (Mixer.Weight(0, 3) = 0) and (Abs(Mixer.Weight(0, 4) - 0.70710678 / Total) < 1e-5) and (Mixer.Weight(0, 1) = 0)
      and (Mixer.Weight(0, 5) = 0), '5.1 to stereo folds centre and back left into left at -3 dB, without LFE');
    Output := Mixer.Mix(TSampleArray.Create(1, 1, 1, 1, 1, 1), 1);
    Check((Output[0] <= 1.0001) and (Output[1] <= 1.0001), 'mixer: full-scale 5.1 cannot clip in stereo');
  finally
    Mixer.Free;
  end;
  Mixer := TChannelMixer.Create(8, 6);
  try
    Check((Abs(Mixer.Weight(4, 6) - 0.5) < 1e-6) and (Abs(Mixer.Weight(4, 4) - 0.5) < 1e-6) and
      (Mixer.Weight(0, 6) = 0), '7.1 to 5.1 folds the sides into the backs');
  finally
    Mixer.Free;
  end;
end;

procedure CheckEncoding;
var
  Samples: TSampleArray;
  Bytes: array[0..15] of Byte;
begin
  Samples := TSampleArray.Create(0.5, 1.5, -2, -0.25);
  EncodeOutputSamples(@Samples[0], 4, OutputSigned16, @Bytes[0]);
  Check((PSmallInt(@Bytes[0])^ = 16384) and (PSmallInt(@Bytes[2])^ = 32767) and (PSmallInt(@Bytes[4])^ = -32768)
    and (PSmallInt(@Bytes[6])^ = -8192), 'output: 16-bit samples rounded and clipped');
  EncodeOutputSamples(@Samples[0], 4, OutputSigned32, @Bytes[0]);
  Check((PLongInt(@Bytes[0])^ = 1073741824) and (PLongInt(@Bytes[4])^ = High(LongInt)) and
    (PLongInt(@Bytes[8])^ = Low(LongInt)), 'output: 32-bit samples rounded and clipped');
end;

procedure RunBasicTests(const FixtureRoot: string);
begin
  CheckColourConversion;
  CheckTimes;
  CheckPcmAndTrimming;
  CheckWavFiles(FixtureRoot);
  CheckResampler;
  CheckChannelMixer;
  CheckEncoding;
end;

end.
