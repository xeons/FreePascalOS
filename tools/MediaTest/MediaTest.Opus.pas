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
  Tests of the Opus decoder.

  The RFC 6716 / RFC 8251 test vectors (testvectorNN.bit: per packet a
  big-endian length, the encoder's final range and the packet) are
  decoded at 48 kHz in stereo and in mono, as the reference's opus_demo
  does: every packet's final range must equal the encoder's, and the
  output must pass opus_compare's quality measure (ported in
  OpusCompareQuality) against testvectorNN.dec or testvectorNNm.dec (the
  vectors allow either). The opus fixtures (make-opus-fixtures.py) are
  packets the host's libopus made in every mode and frame size, mono,
  stereo and 5.1, decoded through the TAudioDecoder interface and
  compared with libopus' own decoding by signal-to-noise ratio.
}
unit MediaTest.Opus;

{$mode objfpc}
{$H+}

interface

procedure RunOpusTests(const FixtureRoot, VectorDirectory: string);

implementation

uses
  Classes,
  SysUtils,
  Math,
  TestChecks,
  MediaTest.Common,
  Media.Frames,
  Media.Packets,
  Media.Opus,
  Media.Opus.CeltMdct;

type
  TOpusVectorPacket = record
    Data: TBytes;
    FinalRange: LongWord;
  end;
  TOpusVectorPackets = array of TOpusVectorPacket;
  TSingleArray = array of Single;

function ReadBigEndian32(const Bytes: TBytes; Offset: Integer): LongWord;
begin
  Result := (LongWord(Bytes[Offset]) shl 24) or (LongWord(Bytes[Offset + 1]) shl 16) or
    (LongWord(Bytes[Offset + 2]) shl 8) or Bytes[Offset + 3];
end;

function ReadVectorPackets(const Path: string; WithRange: Boolean): TOpusVectorPackets;
var
  Bytes: TBytes;
  Position, Count, Size: Integer;
begin
  Result := nil;
  Bytes := ReadFileBytes(Path);
  Position := 0;
  Count := 0;
  while Position + 4 <= Length(Bytes) do
  begin
    Size := ReadBigEndian32(Bytes, Position);
    Inc(Position, 4);
    if Count >= Length(Result) then
      SetLength(Result, Count * 2 + 64);
    Result[Count].FinalRange := 0;
    if WithRange then
    begin
      Result[Count].FinalRange := ReadBigEndian32(Bytes, Position);
      Inc(Position, 4);
    end;
    if Position + Size > Length(Bytes) then
      Break;
    Result[Count].Data := Copy(Bytes, Position, Size);
    Inc(Position, Size);
    Inc(Count);
  end;
  SetLength(Result, Count);
end;

{ opus_compare's per-frame band power spectrum: Window-sized Hann windows
  every Step samples, the power of each bin up to the last band edge (by
  FFT here, where the reference sums a DFT per bin). }
procedure BandEnergy(Output, PowerSpectrum: PSingle; const Bands: array of Integer; BandCount: Integer;
  Input: PSingle; Channels: Integer; FrameCount, WindowSize, Step, Downsample: Integer);
var
  Window: array of Single;
  Spectrum: array of TOpusComplex;
  Fft: TOpusFft;
  Frame, Channel, K, Band, Bin, PowerSize: Integer;
  Power: array[0..1] of Single;
  Re, Im: Single;
begin
  Window := nil;
  Spectrum := nil;
  SetLength(Window, WindowSize);
  SetLength(Spectrum, Channels * WindowSize);
  InitOpusFft(Fft, WindowSize);
  PowerSize := WindowSize div 2;
  for K := 0 to WindowSize - 1 do
    Window[K] := 0.5 - 0.5 * Cos((2 * 3.14159265 / (WindowSize - 1)) * K);
  for Frame := 0 to FrameCount - 1 do
  begin
    for Channel := 0 to Channels - 1 do
    begin
      for K := 0 to WindowSize - 1 do
      begin
        Spectrum[Channel * WindowSize + Fft.BitReverse[K]].Real :=
          Window[K] * Input[(Frame * Step + K) * Channels + Channel];
        Spectrum[Channel * WindowSize + Fft.BitReverse[K]].Imaginary := 0;
      end;
      OpusFftInPlace(Fft, @Spectrum[Channel * WindowSize]);
    end;
    Bin := 0;
    for Band := 0 to BandCount - 1 do
    begin
      Power[0] := 0;
      Power[1] := 0;
      while Bin < Bands[Band + 1] do
      begin
        for Channel := 0 to Channels - 1 do
        begin
          Re := Spectrum[Channel * WindowSize + Bin].Real * Downsample;
          Im := Spectrum[Channel * WindowSize + Bin].Imaginary * Downsample;
          PowerSpectrum[(Frame * PowerSize + Bin) * Channels + Channel] := Re * Re + Im * Im + 100000;
          Power[Channel] := Power[Channel] + PowerSpectrum[(Frame * PowerSize + Bin) * Channels + Channel];
        end;
        Inc(Bin);
      end;
      if Output <> nil then
      begin
        Output[(Frame * BandCount + Band) * Channels] := Power[0] / (Bands[Band + 1] - Bands[Band]);
        if Channels = 2 then
          Output[(Frame * BandCount + Band) * Channels + 1] := Power[1] / (Bands[Band + 1] - Bands[Band]);
      end;
    end;
  end;
end;

{ opus_compare at 48 kHz: Reference is the vector's stereo .dec file as
  samples, Decoded the decoder's output with Channels channels. Returns
  the quality (passing at 0 or more) and False if the lengths differ. }
function OpusCompareQuality(const Reference, Decoded: TSingleArray; Channels: Integer; out Quality: Double): Boolean;
const
  BandCount = 21;
  FrequencyCount = 240;
  Bands: array[0..BandCount] of Integer = (0, 2, 4, 6, 8, 10, 12, 14, 16, 20, 24, 28, 32, 40, 48, 56, 68, 80, 96,
    120, 156, 200);
  WindowSize = 480;
  WindowStep = 120;
var
  X, Y, XBands, XSpectrum, YSpectrum: TSingleArray;
  ReferenceLength, DecodedLength, FrameCount, Frame, Band, Channel, Bin, MaximumCompare: Integer;
  Left, Right, XTemp, YTemp, XTemp2, YTemp2, Re, Im: Single;
  Error, FrameError, BandError: Double;
begin
  Quality := -100;
  ReferenceLength := Length(Reference) div 2;
  X := nil;
  SetLength(X, Length(Reference));
  Move(Reference[0], X[0], Length(Reference) * SizeOf(Single));
  if Channels = 1 then
    for Frame := 0 to ReferenceLength - 1 do
      X[Frame] := 0.5 * (X[2 * Frame] + X[2 * Frame + 1]);
  Y := Decoded;
  DecodedLength := Length(Decoded) div Channels;
  if ReferenceLength <> DecodedLength then
    Exit(False);
  if ReferenceLength < WindowSize then
    Exit(False);
  FrameCount := (ReferenceLength - WindowSize + WindowStep) div WindowStep;
  XBands := nil;
  XSpectrum := nil;
  YSpectrum := nil;
  SetLength(XBands, FrameCount * BandCount * Channels);
  SetLength(XSpectrum, FrameCount * FrequencyCount * Channels);
  SetLength(YSpectrum, FrameCount * FrequencyCount * Channels);
  BandEnergy(@XBands[0], @XSpectrum[0], Bands, BandCount, @X[0], Channels, FrameCount, WindowSize, WindowStep, 1);
  BandEnergy(nil, @YSpectrum[0], Bands, BandCount, @Y[0], Channels, FrameCount, WindowSize, WindowStep, 1);
  for Frame := 0 to FrameCount - 1 do
  begin
    for Band := 1 to BandCount - 1 do
      for Channel := 0 to Channels - 1 do
        XBands[(Frame * BandCount + Band) * Channels + Channel] := XBands[(Frame * BandCount + Band) * Channels + Channel]
          + 0.1 * XBands[(Frame * BandCount + Band - 1) * Channels + Channel];
    for Band := BandCount - 2 downto 0 do
      for Channel := 0 to Channels - 1 do
        XBands[(Frame * BandCount + Band) * Channels + Channel] := XBands[(Frame * BandCount + Band) * Channels + Channel]
          + 0.03 * XBands[(Frame * BandCount + Band + 1) * Channels + Channel];
    if Frame > 0 then
      for Band := 0 to BandCount - 1 do
        for Channel := 0 to Channels - 1 do
          XBands[(Frame * BandCount + Band) * Channels + Channel] :=
            XBands[(Frame * BandCount + Band) * Channels + Channel] +
            0.5 * XBands[((Frame - 1) * BandCount + Band) * Channels + Channel];
    if Channels = 2 then
      for Band := 0 to BandCount - 1 do
      begin
        Left := XBands[(Frame * BandCount + Band) * Channels];
        Right := XBands[(Frame * BandCount + Band) * Channels + 1];
        XBands[(Frame * BandCount + Band) * Channels] := XBands[(Frame * BandCount + Band) * Channels] + 0.01 * Right;
        XBands[(Frame * BandCount + Band) * Channels + 1] := XBands[(Frame * BandCount + Band) * Channels + 1] +
          0.01 * Left;
      end;
    for Band := 0 to BandCount - 1 do
      for Bin := Bands[Band] to Bands[Band + 1] - 1 do
        for Channel := 0 to Channels - 1 do
        begin
          XSpectrum[(Frame * FrequencyCount + Bin) * Channels + Channel] :=
            XSpectrum[(Frame * FrequencyCount + Bin) * Channels + Channel] +
            0.1 * XBands[(Frame * BandCount + Band) * Channels + Channel];
          YSpectrum[(Frame * FrequencyCount + Bin) * Channels + Channel] :=
            YSpectrum[(Frame * FrequencyCount + Bin) * Channels + Channel] +
            0.1 * XBands[(Frame * BandCount + Band) * Channels + Channel];
        end;
  end;
  for Band := 0 to BandCount - 1 do
    for Bin := Bands[Band] to Bands[Band + 1] - 1 do
      for Channel := 0 to Channels - 1 do
      begin
        XTemp := XSpectrum[Bin * Channels + Channel];
        YTemp := YSpectrum[Bin * Channels + Channel];
        for Frame := 1 to FrameCount - 1 do
        begin
          XTemp2 := XSpectrum[(Frame * FrequencyCount + Bin) * Channels + Channel];
          YTemp2 := YSpectrum[(Frame * FrequencyCount + Bin) * Channels + Channel];
          XSpectrum[(Frame * FrequencyCount + Bin) * Channels + Channel] :=
            XSpectrum[(Frame * FrequencyCount + Bin) * Channels + Channel] + XTemp;
          YSpectrum[(Frame * FrequencyCount + Bin) * Channels + Channel] :=
            YSpectrum[(Frame * FrequencyCount + Bin) * Channels + Channel] + YTemp;
          XTemp := XTemp2;
          YTemp := YTemp2;
        end;
      end;
  MaximumCompare := Bands[BandCount];
  Error := 0;
  for Frame := 0 to FrameCount - 1 do
  begin
    FrameError := 0;
    for Band := 0 to BandCount - 1 do
    begin
      BandError := 0;
      Bin := Bands[Band];
      while (Bin < Bands[Band + 1]) and (Bin < MaximumCompare) do
      begin
        for Channel := 0 to Channels - 1 do
        begin
          Re := YSpectrum[(Frame * FrequencyCount + Bin) * Channels + Channel] /
            XSpectrum[(Frame * FrequencyCount + Bin) * Channels + Channel];
          Im := Re - Ln(Re) - 1;
          if (Bin >= 79) and (Bin <= 81) then
            Im := Im * 0.1;
          if Bin = 80 then
            Im := Im * 0.1;
          BandError := BandError + Im;
        end;
        Inc(Bin);
      end;
      BandError := BandError / ((Bands[Band + 1] - Bands[Band]) * Channels);
      FrameError := FrameError + BandError * BandError;
    end;
    FrameError := FrameError / BandCount;
    FrameError := FrameError * FrameError;
    Error := Error + FrameError * FrameError;
  end;
  Error := Power(Error / FrameCount, 1.0 / 16);
  Quality := 100 * (1 - 0.5 * Ln(1 + Error) / Ln(1.13));
  Result := True;
end;

function S16FileAsFloats(const Path: string): TSingleArray;
var
  Bytes: TBytes;
  Index: Integer;
begin
  Result := nil;
  Bytes := ReadFileBytes(Path);
  SetLength(Result, Length(Bytes) div 2);
  for Index := 0 to High(Result) do
    Result[Index] := SmallInt(Bytes[2 * Index] or (Bytes[2 * Index + 1] shl 8));
end;

{ Decodes a vector as opus_demo -d 48000 Channels; RangeFailures counts
  the packets whose final range is not the encoder's. }
function DecodeVector(const Packets: TOpusVectorPackets; Channels: Integer; out RangeFailures: Integer): TSingleArray;
var
  Decoder: TOpusDecoder;
  Output: array of SmallInt;
  Index, Samples, Count, J: Integer;
begin
  Result := nil;
  RangeFailures := 0;
  Output := nil;
  SetLength(Output, 5760 * 2);
  Count := 0;
  Decoder := TOpusDecoder.Create;
  try
    Decoder.ConfigureRaw(48000, Channels);
    for Index := 0 to High(Packets) do
    begin
      if Length(Packets[Index].Data) = 0 then
        Samples := Decoder.DecodeRawInt16(nil, 0, @Output[0], 5760)
      else
        Samples := Decoder.DecodeRawInt16(@Packets[Index].Data[0], Length(Packets[Index].Data), @Output[0], 5760);
      if Samples < 0 then
      begin
        Inc(RangeFailures);
        Continue;
      end;
      if (Length(Packets[Index].Data) > 0) and (Packets[Index].FinalRange <> 0) and
        (Decoder.FinalRange <> Packets[Index].FinalRange) then
      begin
        if RangeFailures < 3 then
          WriteLn(Format('     packet %d: final range %.8x, expected %.8x', [Index, Decoder.FinalRange,
            Packets[Index].FinalRange]));
        Inc(RangeFailures);
      end;
      if Count + Samples * Channels > Length(Result) then
        SetLength(Result, (Count + Samples * Channels) * 2);
      for J := 0 to Samples * Channels - 1 do
        Result[Count + J] := Output[J];
      Inc(Count, Samples * Channels);
    end;
  finally
    Decoder.Free;
  end;
  SetLength(Result, Count);
end;

{ The stereo Reference as Channels channels (mono: the average). }
function MonoMix(const Reference: TSingleArray; Channels: Integer): TFloatArray;
var
  Index: Integer;
begin
  Result := nil;
  if Channels = 2 then
    Exit(TFloatArray(Reference));
  SetLength(Result, Length(Reference) div 2);
  for Index := 0 to High(Result) do
    Result[Index] := 0.5 * (Reference[2 * Index] + Reference[2 * Index + 1]);
end;

procedure CheckVector(const VectorDirectory, Name: string);
var
  Packets: TOpusVectorPackets;
  Decoded, Reference, ReferenceMono: TSingleArray;
  Channels, RangeFailures: Integer;
  Quality1, Quality2, Best, Snr: Double;
  Valid1, Valid2: Boolean;
  Label_: string;
begin
  Packets := ReadVectorPackets(VectorDirectory + Name + '.bit', True);
  Reference := S16FileAsFloats(VectorDirectory + Name + '.dec');
  ReferenceMono := S16FileAsFloats(VectorDirectory + Name + 'm.dec');
  for Channels := 2 downto 1 do
  begin
    if Channels = 2 then
      Label_ := 'stereo'
    else
      Label_ := 'mono';
    Decoded := DecodeVector(Packets, Channels, RangeFailures);
    Check(RangeFailures = 0, Format('opus %s %s: final range of all %d packets', [Name, Label_, Length(Packets)]));
    Valid1 := OpusCompareQuality(Reference, Decoded, Channels, Quality1);
    Valid2 := OpusCompareQuality(ReferenceMono, Decoded, Channels, Quality2);
    Best := -1000;
    if Valid1 then
      Best := Quality1;
    if Valid2 and (Quality2 > Best) then
      Best := Quality2;
    Snr := Max(SignalToNoise(TFloatArray(Decoded), MonoMix(Reference, Channels)),
      SignalToNoise(TFloatArray(Decoded), MonoMix(ReferenceMono, Channels)));
    Check(Best >= 0, Format('opus %s %s: opus_compare quality %.1f %% (against .dec %.1f, m.dec %.1f), SNR %.1f dB',
      [Name, Label_, Best, Quality1, Quality2, Snr]));
  end;
end;

procedure RunVectorTests(const VectorDirectory: string);
var
  Index: Integer;
  Directory: string;
begin
  Directory := IncludeTrailingPathDelimiter(VectorDirectory);
  if (VectorDirectory = '') or not FileExists(Directory + 'testvector01.bit') then
  begin
    WriteLn('skip opus test vectors (not found in ', VectorDirectory, ')');
    Exit;
  end;
  for Index := 1 to 12 do
    CheckVector(Directory, Format('testvector%.2d', [Index]));
end;

function DecodeFixture(const Packets: TOpusVectorPackets; const Head: TBytes; PreSkip: Integer;
  out Channels: Integer): TSingleArray;
var
  Decoder: TOpusDecoder;
  Track: TMediaTrack;
  Packet: TMediaPacket;
  Buffer: TAudioBuffer;
  Index, Count: Integer;
begin
  Result := nil;
  Channels := 0;
  Track := TMediaTrack.Create;
  Decoder := TOpusDecoder.Create;
  try
    Track.Kind := mkAudio;
    Track.Codec := codecOpus;
    Track.AddHeader(Head);
    Track.CodecDelay := PreSkip;
    Decoder.Configure(Track);
    Channels := Decoder.Channels;
    Count := 0;
    Buffer := Default(TAudioBuffer);
    for Index := 0 to High(Packets) do
    begin
      Packet := NewPacket(0);
      Packet.Data := Packets[Index].Data;
      Decoder.Decode(Packet, Buffer);
      if Count + Length(Buffer.Samples) > Length(Result) then
        SetLength(Result, (Count + Length(Buffer.Samples)) * 2);
      if Length(Buffer.Samples) > 0 then
        Move(Buffer.Samples[0], Result[Count], Length(Buffer.Samples) * SizeOf(Single));
      Inc(Count, Length(Buffer.Samples));
    end;
    SetLength(Result, Count);
  finally
    Decoder.Free;
    Track.Free;
  end;
end;

procedure RunFixtureTests(const FixtureRoot: string);
var
  Directory, Name: string;
  Lines, Fields: TStringList;
  Line: string;
  Packets: TOpusVectorPackets;
  Head: TBytes;
  Decoded: TSingleArray;
  Reference: TFloatArray;
  PreSkip, Channels, ExpectedChannels: Integer;
  MinimumSnr, Snr: Double;
begin
  Directory := FixturePath(FixtureRoot, 'opus') + PathDelim;
  Lines := ReadManifestLines(Directory + 'manifest.txt');
  try
    if Lines.Count = 0 then
      WriteLn('skip opus fixtures (none made: ', Directory, 'manifest.txt)');
    for Line in Lines do
    begin
      Fields := SplitFields(Line);
      try
        Name := Fields[0];
        ExpectedChannels := StrToInt(Fields[1]);
        PreSkip := StrToInt(Fields[2]);
        MinimumSnr := StrToFloat(Fields[3]);
        Packets := ReadVectorPackets(Directory + Name + '.packets', False);
        Head := ReadFileBytes(Directory + Name + '.head');
        try
          Decoded := DecodeFixture(Packets, Head, PreSkip, Channels);
        except
          on E: Exception do
          begin
            Check(False, 'opus fixture ' + Name + ': ' + E.Message);
            Continue;
          end;
        end;
        Reference := ReadF32Reference(Directory + Name + '.f32');
        Check(Channels = ExpectedChannels, Format('opus fixture %s: %d channels', [Name, Channels]));
        Check(Abs(Length(Decoded) - Length(Reference)) <= 5760 * Channels,
          Format('opus fixture %s: %d samples (reference %d)', [Name, Length(Decoded), Length(Reference)]));
        Snr := SignalToNoise(TFloatArray(Decoded), Reference);
        Check(Snr >= MinimumSnr, Format('opus fixture %s: SNR %.1f dB against libopus (at least %.0f)',
          [Name, Snr, MinimumSnr]));
      finally
        Fields.Free;
      end;
    end;
  finally
    Lines.Free;
  end;
end;

procedure RunPacketTests;
var
  Decoder: TOpusDecoder;
  Output: array[0..5759] of Single;
  Packet: array[0..3] of Byte;
  Samples: Integer;
begin
  Decoder := TOpusDecoder.Create;
  try
    Decoder.ConfigureRaw(48000, 2);
    { A CELT 20 ms frame of one byte is concealed (no data). }
    Packet[0] := $F8 or $04;
    Samples := Decoder.DecodeRaw(@Packet[0], 1, @Output[0], 5760);
    Check(Samples = 960, 'opus: one-byte CELT frame decodes to 960 samples');
    { Code 3 with zero frames is malformed. }
    Packet[0] := $FB;
    Packet[1] := 0;
    Samples := Decoder.DecodeRaw(@Packet[0], 2, @Output[0], 5760);
    Check(Samples < 0, 'opus: code 3 packet with no frames is refused');
    { Code 1 with an odd payload is malformed. }
    Packet[0] := $F9;
    Packet[1] := 1;
    Packet[2] := 2;
    Samples := Decoder.DecodeRaw(@Packet[0], 2, @Output[0], 5760);
    Check(Samples < 0, 'opus: code 1 packet with an odd payload is refused');
    { A lost packet is concealed for the last duration. }
    Samples := Decoder.DecodeRaw(nil, 0, @Output[0], 5760);
    Check(Samples = 960, 'opus: a lost packet is concealed for 20 ms');
    Decoder.ConfigureRaw(16000, 1);
    Packet[0] := $F8;
    Samples := Decoder.DecodeRaw(@Packet[0], 1, @Output[0], 5760);
    Check(Samples = 320, 'opus: 20 ms at 16 kHz is 320 samples');
  finally
    Decoder.Free;
  end;
end;

procedure RunOpusTests(const FixtureRoot, VectorDirectory: string);
begin
  RunPacketTests;
  RunVectorTests(VectorDirectory);
  RunFixtureTests(FixtureRoot);
end;

end.
