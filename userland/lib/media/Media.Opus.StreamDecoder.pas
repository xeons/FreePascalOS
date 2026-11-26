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

  This file follows the Opus reference decoder (RFC 6716, libopus 1.5.2),
  which carries this notice:

  Copyright (c) 2001-2011 Xiph.Org, Skype Limited, Octasic,
                          Jean-Marc Valin, Timothy B. Terriberry,
                          CSIRO, Gregory Maxwell, Mark Borgerding,
                          Erik de Castro Lopo

  Redistribution and use in source and binary forms, with or without
  modification, are permitted provided that the following conditions
  are met:
  - Redistributions of source code must retain the above copyright
    notice, this list of conditions and the following disclaimer.
  - Redistributions in binary form must reproduce the above copyright
    notice, this list of conditions and the following disclaimer in the
    documentation and/or other materials provided with the distribution.
  - Neither the name of Internet Society, IETF or IETF Trust, nor the
    names of specific contributors, may be used to endorse or promote
    products derived from this software without specific prior written
    permission.

  THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
  "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
  LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
  A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
  OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
  SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
  LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
  DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
  THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
  (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
  OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
}

{
  One Opus stream's decoder (RFC 6716 section 4): each frame through
  SILK, CELT or both (hybrid: SILK below 8 kHz, CELT above from band 17),
  the redundant CELT frames that smooth switches between modes, the
  transitions concealed with a cross-fade, and the output gain; packet
  loss concealment for missing packets. Output is floats at 8 to 48 kHz,
  one or two channels. FinalRange is the range coder's state after the
  last frame (XORed with the redundant frame's), which conformance
  checks compare with the encoder's.
}
unit Media.Opus.StreamDecoder;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

uses
  Media.Opus.RangeDecoder,
  Media.Opus.CeltDecoder,
  Media.Opus.SilkDecoder,
  Media.Opus.Packets;

type
  TOpusStreamDecoder = class
  private
    FCelt: TCeltDecoder;
    FSilk: TSilkDecoder;
    FRangeDecoder: TOpusRangeDecoder;
    FChannels: Integer;
    FSampleRate: LongInt;
    FSilkControl: TSilkDecodeControl;
    FDecodeGain: Integer;
    FStreamChannels: Integer;
    FBandwidth: Integer;
    FMode: Integer;
    FPreviousMode: Integer;
    FFrameSize: Integer;
    FPreviousRedundancy: Boolean;
    FLastPacketDuration: Integer;
    FFinalRange: LongWord;
    function DecodeFrame(Data: PByte; Length: LongInt; Pcm: PSingle; FrameSize: Integer;
      DecodeFec: Boolean): Integer;
    procedure SmoothFade(In1, In2, Output: PSingle; Overlap: Integer);
  public
    constructor Create(SampleRate: LongInt; Channels: Integer);
    destructor Destroy; override;
    procedure Reset;
    { Decodes a packet (Data = nil or Length = 0: a lost one, FrameSize
      samples concealed) into Pcm, room for FrameSize samples per
      channel; with SelfDelimited, the packet is a multistream one's
      non-final stream and PacketLength says how much of Data it took.
      Returns the samples per channel, or -1 for a broken packet. }
    function Decode(Data: PByte; Length: LongInt; Pcm: PSingle; FrameSize: Integer; DecodeFec,
      SelfDelimited: Boolean; out PacketLength: LongInt): Integer;
    property Channels: Integer read FChannels;
    property SampleRate: LongInt read FSampleRate;
    property FinalRange: LongWord read FFinalRange;
    { The output gain in 1/256 dB (OpusHead's). }
    property DecodeGain: Integer read FDecodeGain write FDecodeGain;
    property LastPacketDuration: Integer read FLastPacketDuration;
  end;

implementation

uses
  Math;

constructor TOpusStreamDecoder.Create(SampleRate: LongInt; Channels: Integer);
begin
  inherited Create;
  FSampleRate := SampleRate;
  FChannels := Channels;
  FCelt := TCeltDecoder.Create(SampleRate, Channels);
  FSilk := TSilkDecoder.Create;
  FRangeDecoder := TOpusRangeDecoder.Create;
  FSilkControl := Default(TSilkDecodeControl);
  FSilkControl.ApiSampleRate := SampleRate;
  FSilkControl.ApiChannels := Channels;
  Reset;
end;

destructor TOpusStreamDecoder.Destroy;
begin
  FCelt.Free;
  FSilk.Free;
  FRangeDecoder.Free;
  inherited Destroy;
end;

procedure TOpusStreamDecoder.Reset;
begin
  FStreamChannels := FChannels;
  FBandwidth := 0;
  FMode := 0;
  FPreviousMode := 0;
  FPreviousRedundancy := False;
  FLastPacketDuration := 0;
  FFinalRange := 0;
  FFrameSize := FSampleRate div 400;
  FSilk.Reset;
  FCelt.Reset;
end;

procedure TOpusStreamDecoder.SmoothFade(In1, In2, Output: PSingle; Overlap: Integer);
var
  Index, Channel, Increment: Integer;
  Weight, WindowValue: Single;
  Window: PSingle;
begin
  Increment := 48000 div FSampleRate;
  Window := FCelt.Window;
  for Channel := 0 to FChannels - 1 do
    for Index := 0 to Overlap - 1 do
    begin
      WindowValue := Window[Index * Increment];
      Weight := WindowValue * WindowValue;
      Output[Index * FChannels + Channel] := Weight * In2[Index * FChannels + Channel] +
        (1 - Weight) * In1[Index * FChannels + Channel];
    end;
end;

function TOpusStreamDecoder.DecodeFrame(Data: PByte; Length: LongInt; Pcm: PSingle; FrameSize: Integer;
  DecodeFec: Boolean): Integer;
var
  Index, Channel, F2_5, F5, F10, F20, AudioSize, Mode, Bandwidth, StartBand, EndBand, LostFlag: Integer;
  DecodedSamples, SilkFrameSize, CeltFrameSize, CeltResult, RedundancyBytes, Returned: Integer;
  Transition, Redundancy, CeltToSilk, HaveData: Boolean;
  RedundantRange: LongWord;
  PcmSilk: array of SmallInt;
  PcmTransition: array of Single;
  RedundantAudio: array of Single;
  SilkPointer: PSmallInt;
  Silence: array[0..1] of Byte;
  Gain: Single;
begin
  PcmSilk := nil;
  PcmTransition := nil;
  RedundantAudio := nil;
  F20 := FSampleRate div 50;
  F10 := F20 shr 1;
  F5 := F10 shr 1;
  F2_5 := F5 shr 1;
  if FrameSize < F2_5 then
    Exit(-1);
  FrameSize := Min(FrameSize, FSampleRate div 25 * 3);
  if Length <= 1 then
  begin
    Data := nil;
    FrameSize := Min(FrameSize, FFrameSize);
  end;
  HaveData := Data <> nil;
  Transition := False;
  Redundancy := False;
  CeltToSilk := False;
  RedundancyBytes := 0;
  RedundantRange := 0;
  CeltResult := 0;
  if HaveData then
  begin
    AudioSize := FFrameSize;
    Mode := FMode;
    Bandwidth := FBandwidth;
    FRangeDecoder.Init(Data, Length);
  end
  else
  begin
    AudioSize := FrameSize;
    if FPreviousRedundancy then
      Mode := OpusModeCeltOnly
    else
      Mode := FPreviousMode;
    Bandwidth := 0;
    if Mode = 0 then
    begin
      FillChar(Pcm^, AudioSize * FChannels * SizeOf(Single), 0);
      Exit(AudioSize);
    end;
    if AudioSize > F20 then
    begin
      repeat
        Returned := DecodeFrame(nil, 0, Pcm, Min(AudioSize, F20), False);
        if Returned < 0 then
          Exit(Returned);
        Inc(Pcm, Returned * FChannels);
        Dec(AudioSize, Returned);
      until AudioSize <= 0;
      Exit(FrameSize);
    end
    else if AudioSize < F20 then
    begin
      if AudioSize > F10 then
        AudioSize := F10
      else if (Mode <> OpusModeSilkOnly) and (AudioSize > F5) and (AudioSize < F10) then
        AudioSize := F5;
    end;
  end;
  if HaveData and (FPreviousMode > 0) and (((Mode = OpusModeCeltOnly) and (FPreviousMode <> OpusModeCeltOnly) and
    not FPreviousRedundancy) or ((Mode <> OpusModeCeltOnly) and (FPreviousMode = OpusModeCeltOnly))) then
  begin
    Transition := True;
    SetLength(PcmTransition, F5 * FChannels);
  end;
  if Transition and (Mode = OpusModeCeltOnly) then
    DecodeFrame(nil, 0, @PcmTransition[0], Min(F5, AudioSize), False);
  if AudioSize > FrameSize then
    Exit(-1);
  FrameSize := AudioSize;
  if Mode <> OpusModeCeltOnly then
  begin
    SetLength(PcmSilk, Max(F10, FrameSize) * FChannels);
    SilkPointer := @PcmSilk[0];
    if FPreviousMode = OpusModeCeltOnly then
      FSilk.Reset;
    FSilkControl.PayloadSizeMs := Max(10, 1000 * AudioSize div FSampleRate);
    if HaveData then
    begin
      FSilkControl.InternalChannels := FStreamChannels;
      if Mode = OpusModeSilkOnly then
        case Bandwidth of
          OpusBandwidthNarrowband: FSilkControl.InternalSampleRate := 8000;
          OpusBandwidthMediumband: FSilkControl.InternalSampleRate := 12000;
        else
          FSilkControl.InternalSampleRate := 16000;
        end
      else
        FSilkControl.InternalSampleRate := 16000;
    end;
    if not HaveData then
      LostFlag := 1
    else if DecodeFec then
      LostFlag := 2
    else
      LostFlag := 0;
    DecodedSamples := 0;
    repeat
      if not FSilk.Decode(FSilkControl, LostFlag, DecodedSamples = 0, FRangeDecoder, SilkPointer, SilkFrameSize) then
      begin
        if LostFlag <> 0 then
        begin
          SilkFrameSize := FrameSize;
          FillChar(SilkPointer^, FrameSize * FChannels * SizeOf(SmallInt), 0);
        end
        else
          Exit(-1);
      end;
      Inc(SilkPointer, SilkFrameSize * FChannels);
      Inc(DecodedSamples, SilkFrameSize);
    until DecodedSamples >= FrameSize;
  end;
  StartBand := 0;
  if not DecodeFec and (Mode <> OpusModeCeltOnly) and HaveData and
    (FRangeDecoder.Tell + 17 + 20 * Ord(Mode = OpusModeHybrid) <= 8 * Length) then
  begin
    if Mode = OpusModeHybrid then
      Redundancy := FRangeDecoder.DecodeBitLogP(12)
    else
      Redundancy := True;
    if Redundancy then
    begin
      CeltToSilk := FRangeDecoder.DecodeBitLogP(1);
      if Mode = OpusModeHybrid then
        RedundancyBytes := Integer(FRangeDecoder.DecodeUInt(256)) + 2
      else
        RedundancyBytes := Length - ((FRangeDecoder.Tell + 7) shr 3);
      Dec(Length, RedundancyBytes);
      if Length * 8 < FRangeDecoder.Tell then
      begin
        Length := 0;
        RedundancyBytes := 0;
        Redundancy := False;
      end;
      FRangeDecoder.SetStorage(FRangeDecoder.Storage - LongWord(RedundancyBytes));
    end;
  end;
  if Mode <> OpusModeCeltOnly then
    StartBand := 17;
  if Redundancy then
  begin
    Transition := False;
    PcmTransition := nil;
  end;
  if Transition and (Mode <> OpusModeCeltOnly) then
  begin
    SetLength(PcmTransition, F5 * FChannels);
    DecodeFrame(nil, 0, @PcmTransition[0], Min(F5, AudioSize), False);
  end;
  if Bandwidth <> 0 then
  begin
    case Bandwidth of
      OpusBandwidthNarrowband: EndBand := 13;
      OpusBandwidthMediumband, OpusBandwidthWideband: EndBand := 17;
      OpusBandwidthSuperWideband: EndBand := 19;
    else
      EndBand := 21;
    end;
    FCelt.EndBand := EndBand;
  end;
  FCelt.StreamChannels := FStreamChannels;
  if Redundancy then
    SetLength(RedundantAudio, F5 * FChannels);
  if Redundancy and CeltToSilk then
  begin
    FCelt.StartBand := 0;
    FCelt.Decode(Data + Length, RedundancyBytes, @RedundantAudio[0], F5, nil);
    RedundantRange := FCelt.FinalRange;
  end;
  FCelt.StartBand := StartBand;
  if Mode <> OpusModeSilkOnly then
  begin
    CeltFrameSize := Min(F20, FrameSize);
    if (Mode <> FPreviousMode) and (FPreviousMode > 0) and not FPreviousRedundancy then
      FCelt.Reset;
    if DecodeFec then
      CeltResult := FCelt.Decode(nil, Length, Pcm, CeltFrameSize, FRangeDecoder)
    else
      CeltResult := FCelt.Decode(Data, Length, Pcm, CeltFrameSize, FRangeDecoder);
  end
  else
  begin
    Silence[0] := $FF;
    Silence[1] := $FF;
    FillChar(Pcm^, FrameSize * FChannels * SizeOf(Single), 0);
    if (FPreviousMode = OpusModeHybrid) and not (Redundancy and CeltToSilk and FPreviousRedundancy) then
    begin
      FCelt.StartBand := 0;
      FCelt.Decode(@Silence[0], 2, Pcm, F2_5, nil);
    end;
  end;
  if Mode <> OpusModeCeltOnly then
    for Index := 0 to FrameSize * FChannels - 1 do
      Pcm[Index] := Pcm[Index] + (1 / 32768) * PcmSilk[Index];
  if Redundancy and not CeltToSilk then
  begin
    FCelt.Reset;
    FCelt.StartBand := 0;
    FCelt.Decode(Data + Length, RedundancyBytes, @RedundantAudio[0], F5, nil);
    RedundantRange := FCelt.FinalRange;
    SmoothFade(Pcm + FChannels * (FrameSize - F2_5), @RedundantAudio[FChannels * F2_5],
      Pcm + FChannels * (FrameSize - F2_5), F2_5);
  end;
  if Redundancy and CeltToSilk and ((FPreviousMode <> OpusModeSilkOnly) or FPreviousRedundancy) then
  begin
    for Channel := 0 to FChannels - 1 do
      for Index := 0 to F2_5 - 1 do
        Pcm[FChannels * Index + Channel] := RedundantAudio[FChannels * Index + Channel];
    SmoothFade(@RedundantAudio[FChannels * F2_5], Pcm + FChannels * F2_5, Pcm + FChannels * F2_5, F2_5);
  end;
  if Transition then
  begin
    if AudioSize >= F5 then
    begin
      for Index := 0 to FChannels * F2_5 - 1 do
        Pcm[Index] := PcmTransition[Index];
      SmoothFade(@PcmTransition[FChannels * F2_5], Pcm + FChannels * F2_5, Pcm + FChannels * F2_5, F2_5);
    end
    else
      SmoothFade(@PcmTransition[0], Pcm, Pcm, F2_5);
  end;
  if FDecodeGain <> 0 then
  begin
    Gain := Exp(0.6931471805599453094 * (6.48814081e-4 * FDecodeGain));
    for Index := 0 to FrameSize * FChannels - 1 do
      Pcm[Index] := Pcm[Index] * Gain;
  end;
  if Length <= 1 then
    FFinalRange := 0
  else
    FFinalRange := FRangeDecoder.Range xor RedundantRange;
  FPreviousMode := Mode;
  FPreviousRedundancy := Redundancy and not CeltToSilk;
  if CeltResult < 0 then
    Result := CeltResult
  else
    Result := AudioSize;
end;

function TOpusStreamDecoder.Decode(Data: PByte; Length: LongInt; Pcm: PSingle; FrameSize: Integer; DecodeFec,
  SelfDelimited: Boolean; out PacketLength: LongInt): Integer;
var
  Index, SampleCount, Count, Offset, Returned, PacketMode, PacketBandwidth, PacketFrameSize,
    PacketStreamChannels, PcmCount, DurationCopy: Integer;
  Sizes: TOpusFrameSizes;
  Dummy: LongInt;
begin
  PacketLength := 0;
  if (DecodeFec or (Length = 0) or (Data = nil)) and (FrameSize mod (FSampleRate div 400) <> 0) then
    Exit(-1);
  if (Length = 0) or (Data = nil) then
  begin
    PcmCount := 0;
    repeat
      Returned := DecodeFrame(nil, 0, Pcm + PcmCount * FChannels, FrameSize - PcmCount, False);
      if Returned < 0 then
        Exit(Returned);
      Inc(PcmCount, Returned);
    until PcmCount >= FrameSize;
    FLastPacketDuration := PcmCount;
    Exit(PcmCount);
  end
  else if Length < 0 then
    Exit(-1);
  PacketMode := OpusPacketMode(Data);
  PacketBandwidth := OpusPacketBandwidth(Data);
  PacketFrameSize := OpusPacketSamplesPerFrame(Data, FSampleRate);
  PacketStreamChannels := OpusPacketChannels(Data);
  Count := OpusParsePacket(Data, Length, SelfDelimited, Sizes, Offset, PacketLength);
  if Count < 0 then
    Exit(-1);
  Inc(Data, Offset);
  if DecodeFec then
  begin
    if (FrameSize < PacketFrameSize) or (PacketMode = OpusModeCeltOnly) or (FMode = OpusModeCeltOnly) then
      Exit(Decode(nil, 0, Pcm, FrameSize, False, False, Dummy));
    DurationCopy := FLastPacketDuration;
    if FrameSize - PacketFrameSize <> 0 then
    begin
      Returned := Decode(nil, 0, Pcm, FrameSize - PacketFrameSize, False, False, Dummy);
      if Returned < 0 then
      begin
        FLastPacketDuration := DurationCopy;
        Exit(Returned);
      end;
    end;
    FMode := PacketMode;
    FBandwidth := PacketBandwidth;
    FFrameSize := PacketFrameSize;
    FStreamChannels := PacketStreamChannels;
    Returned := DecodeFrame(Data, Sizes[0], Pcm + FChannels * (FrameSize - PacketFrameSize), PacketFrameSize, True);
    if Returned < 0 then
      Exit(Returned);
    FLastPacketDuration := FrameSize;
    Exit(FrameSize);
  end;
  if Count * PacketFrameSize > FrameSize then
    Exit(-1);
  FMode := PacketMode;
  FBandwidth := PacketBandwidth;
  FFrameSize := PacketFrameSize;
  FStreamChannels := PacketStreamChannels;
  SampleCount := 0;
  for Index := 0 to Count - 1 do
  begin
    Returned := DecodeFrame(Data, Sizes[Index], Pcm + SampleCount * FChannels, FrameSize - SampleCount, False);
    if Returned < 0 then
      Exit(Returned);
    Inc(Data, Sizes[Index]);
    Inc(SampleCount, Returned);
  end;
  FLastPacketDuration := SampleCount;
  Result := SampleCount;
end;

end.
