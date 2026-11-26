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
  The SILK layer's decoder (RFC 6716 section 4.2): one 10 or 20 ms frame
  per call (a packet holds up to three per channel), with the packet's
  voice activity and LBRR flags read on its first call, mid/side stereo
  with its prediction and the conversion to left/right, the frame decoder
  (indices, pulses, parameters, synthesis, concealment, comfort noise),
  and the resampling to the output rate. Output is 16-bit, as the
  reference produces it.
}
unit Media.Opus.SilkDecoder;

{$mode objfpc}
{$H+}
{$pointermath on}
{$R-}
{$Q-}

interface

uses
  Media.Opus.RangeDecoder,
  Media.Opus.SilkState;

type
  TSilkDecodeControl = record
    ApiChannels: Integer;
    InternalChannels: Integer;
    ApiSampleRate: LongInt;
    InternalSampleRate: LongInt;
    PayloadSizeMs: Integer;
    PreviousPitchLag: Integer;
  end;

  TSilkStereoState = record
    PreviousPredictionQ13: array[0..1] of SmallInt;
    Mid: array[0..1] of SmallInt;
    Side: array[0..1] of SmallInt;
  end;

  TSilkDecoder = class
  private
    FChannels: array[0..1] of TSilkChannelState;
    FStereo: TSilkStereoState;
    FApiChannels: Integer;
    FInternalChannels: Integer;
    FPreviousDecodeOnlyMiddle: Boolean;
    procedure SetSampleRate(var State: TSilkChannelState; FrequencyKHz: Integer; ApiRate: LongInt);
    procedure DecodeFrame(var State: TSilkChannelState; Decoder: TOpusRangeDecoder; Output: PSmallInt;
      out SampleCount: Integer; LostFlag, ConditionalCoding: Integer);
  public
    constructor Create;
    procedure Reset;
    { Decodes one SILK frame into Output (interleaved, ApiChannels); returns
      False on an invalid configuration. }
    function Decode(var Control: TSilkDecodeControl; LostFlag: Integer; NewPacket: Boolean;
      Decoder: TOpusRangeDecoder; Output: PSmallInt; out SampleCount: Integer): Boolean;
  end;

implementation

uses
  Media.Opus.SilkMath,
  Media.Opus.SilkTables,
  Media.Opus.SilkLpc,
  Media.Opus.SilkResampler,
  Media.Opus.SilkIndices,
  Media.Opus.SilkSynthesis,
  Media.Opus.SilkConcealment;

const
  StereoInterpolationLengthMs = 8;

procedure ResetChannel(var State: TSilkChannelState);
begin
  { As the reference: all of the channel's state is cleared. }
  State := Default(TSilkChannelState);
  State.FirstFrameAfterReset := True;
  State.PreviousGainQ16 := 65536;
  SilkComfortNoiseReset(State);
  SilkConcealmentReset(State);
end;

constructor TSilkDecoder.Create;
begin
  inherited Create;
  Reset;
end;

procedure TSilkDecoder.Reset;
begin
  ResetChannel(FChannels[0]);
  ResetChannel(FChannels[1]);
  FStereo := Default(TSilkStereoState);
  FPreviousDecodeOnlyMiddle := False;
  FApiChannels := 0;
  FInternalChannels := 0;
end;

procedure TSilkDecoder.SetSampleRate(var State: TSilkChannelState; FrequencyKHz: Integer; ApiRate: LongInt);
var
  FrameLength: Integer;
begin
  State.SubframeLength := SilkSubframeLengthMs * FrequencyKHz;
  FrameLength := State.SubframeCount * State.SubframeLength;
  if (State.FrequencyKHz <> FrequencyKHz) or (State.ApiSampleRate <> ApiRate) then
  begin
    SilkResamplerInit(State.Resampler, FrequencyKHz * 1000, ApiRate);
    State.ApiSampleRate := ApiRate;
  end;
  if (State.FrequencyKHz <> FrequencyKHz) or (FrameLength <> State.FrameLength) then
  begin
    if FrequencyKHz = 8 then
    begin
      if State.SubframeCount = SilkMaximumSubframes then
        State.PitchContourIcdf := @SilkPitchContourNBICDF[0]
      else
        State.PitchContourIcdf := @SilkPitchContour10MsNBICDF[0];
    end
    else if State.SubframeCount = SilkMaximumSubframes then
      State.PitchContourIcdf := @SilkPitchContourICDF[0]
    else
      State.PitchContourIcdf := @SilkPitchContour10MsICDF[0];
    if State.FrequencyKHz <> FrequencyKHz then
    begin
      State.LtpMemoryLength := SilkLtpMemoryLengthMs * FrequencyKHz;
      if (FrequencyKHz = 8) or (FrequencyKHz = 12) then
      begin
        State.LpcOrder := 10;
        State.NlsfCodebook := SilkNlsfCodebookNarrow;
      end
      else
      begin
        State.LpcOrder := 16;
        State.NlsfCodebook := SilkNlsfCodebookWide;
      end;
      case FrequencyKHz of
        16: State.PitchLagLowBitsIcdf := @SilkUniform8ICDF[0];
        12: State.PitchLagLowBitsIcdf := @SilkUniform6ICDF[0];
      else
        State.PitchLagLowBitsIcdf := @SilkUniform4ICDF[0];
      end;
      State.FirstFrameAfterReset := True;
      State.PreviousLag := 100;
      State.LastGainIndex := 10;
      State.PreviousSignalType := SilkTypeNoVoiceActivity;
      FillChar(State.OutputBuffer, SizeOf(State.OutputBuffer), 0);
      FillChar(State.LpcStateQ14, SizeOf(State.LpcStateQ14), 0);
    end;
    State.FrequencyKHz := FrequencyKHz;
    State.FrameLength := FrameLength;
  end;
end;

procedure TSilkDecoder.DecodeFrame(var State: TSilkChannelState; Decoder: TOpusRangeDecoder; Output: PSmallInt;
  out SampleCount: Integer; LostFlag, ConditionalCoding: Integer);
var
  Control: TSilkDecoderControl;
  Pulses: array[0..SilkMaximumFrameLength + 15] of SmallInt;
  Length, MoveLength: Integer;
begin
  Length := State.FrameLength;
  Control := Default(TSilkDecoderControl);
  Control.LtpScaleQ14 := 0;
  if (LostFlag = SilkDecodeNormal) or ((LostFlag = SilkDecodeLbrr) and
    (State.LbrrFlags[State.FramesDecoded] = 1)) then
  begin
    SilkDecodeIndices(State, Decoder, State.FramesDecoded, LostFlag <> SilkDecodeNormal, ConditionalCoding);
    SilkDecodePulses(Decoder, @Pulses[0], State.Indices.SignalType, State.Indices.QuantOffsetType, State.FrameLength);
    SilkDecodeParameters(State, Control, ConditionalCoding);
    SilkDecodeCore(State, Control, Output, @Pulses[0]);
    MoveLength := State.LtpMemoryLength - State.FrameLength;
    Move(State.OutputBuffer[State.FrameLength], State.OutputBuffer[0], MoveLength * SizeOf(SmallInt));
    Move(Output^, State.OutputBuffer[MoveLength], State.FrameLength * SizeOf(SmallInt));
    SilkConcealment(State, Control, Output, False);
    State.LossCount := 0;
    State.PreviousSignalType := State.Indices.SignalType;
    State.FirstFrameAfterReset := False;
  end
  else
  begin
    SilkConcealment(State, Control, Output, True);
    MoveLength := State.LtpMemoryLength - State.FrameLength;
    Move(State.OutputBuffer[State.FrameLength], State.OutputBuffer[0], MoveLength * SizeOf(SmallInt));
    Move(Output^, State.OutputBuffer[MoveLength], State.FrameLength * SizeOf(SmallInt));
  end;
  SilkComfortNoise(State, Control, Output, Length);
  SilkGlueFrames(State, Output, Length);
  State.PreviousLag := Control.PitchLags[State.SubframeCount - 1];
  SampleCount := Length;
end;

procedure StereoDecodePrediction(Decoder: TOpusRangeDecoder; out PredictionQ13: array of LongInt);
var
  N: Integer;
  Indices: array[0..1, 0..2] of Integer;
  LowQ13, StepQ13: LongInt;
begin
  N := Decoder.DecodeIcdf(@SilkStereoPredJointICDF[0], 8);
  Indices[0, 2] := N div 5;
  Indices[1, 2] := N - 5 * Indices[0, 2];
  for N := 0 to 1 do
  begin
    Indices[N, 0] := Decoder.DecodeIcdf(@SilkUniform3ICDF[0], 8);
    Indices[N, 1] := Decoder.DecodeIcdf(@SilkUniform5ICDF[0], 8);
  end;
  for N := 0 to 1 do
  begin
    Inc(Indices[N, 0], 3 * Indices[N, 2]);
    LowQ13 := SilkStereoPredQuantQ13[Indices[N, 0]];
    StepQ13 := SilkMulWB(SilkStereoPredQuantQ13[Indices[N, 0] + 1] - LowQ13, 6554);
    PredictionQ13[N] := SilkMlaBB(LowQ13, StepQ13, 2 * Indices[N, 1] + 1);
  end;
  PredictionQ13[0] := PredictionQ13[0] - PredictionQ13[1];
end;

procedure StereoMidSideToLeftRight(var Stereo: TSilkStereoState; X1, X2: PSmallInt;
  const PredictionQ13: array of LongInt; FrequencyKHz, FrameLength: Integer);
var
  N, DenominatorQ16, Delta0Q13, Delta1Q13: Integer;
  Sum, Difference, Prediction0Q13, Prediction1Q13: LongInt;
begin
  Move(Stereo.Mid[0], X1[0], 2 * SizeOf(SmallInt));
  Move(Stereo.Side[0], X2[0], 2 * SizeOf(SmallInt));
  Move(X1[FrameLength], Stereo.Mid[0], 2 * SizeOf(SmallInt));
  Move(X2[FrameLength], Stereo.Side[0], 2 * SizeOf(SmallInt));
  Prediction0Q13 := Stereo.PreviousPredictionQ13[0];
  Prediction1Q13 := Stereo.PreviousPredictionQ13[1];
  DenominatorQ16 := (1 shl 16) div (StereoInterpolationLengthMs * FrequencyKHz);
  Delta0Q13 := SilkRShiftRound(SilkMulBB(PredictionQ13[0] - Stereo.PreviousPredictionQ13[0], DenominatorQ16), 16);
  Delta1Q13 := SilkRShiftRound(SilkMulBB(PredictionQ13[1] - Stereo.PreviousPredictionQ13[1], DenominatorQ16), 16);
  for N := 0 to StereoInterpolationLengthMs * FrequencyKHz - 1 do
  begin
    Inc(Prediction0Q13, Delta0Q13);
    Inc(Prediction1Q13, Delta1Q13);
    Sum := SilkShl((X1[N] + LongInt(X1[N + 2])) + SilkShl(X1[N + 1], 1), 9);
    Sum := SilkMlaWB(SilkShl(X2[N + 1], 8), Sum, Prediction0Q13);
    Sum := SilkMlaWB(Sum, SilkShl(X1[N + 1], 11), Prediction1Q13);
    X2[N + 1] := SmallInt(SilkSat16(SilkRShiftRound(Sum, 8)));
  end;
  Prediction0Q13 := PredictionQ13[0];
  Prediction1Q13 := PredictionQ13[1];
  for N := StereoInterpolationLengthMs * FrequencyKHz to FrameLength - 1 do
  begin
    Sum := SilkShl((X1[N] + LongInt(X1[N + 2])) + SilkShl(X1[N + 1], 1), 9);
    Sum := SilkMlaWB(SilkShl(X2[N + 1], 8), Sum, Prediction0Q13);
    Sum := SilkMlaWB(Sum, SilkShl(X1[N + 1], 11), Prediction1Q13);
    X2[N + 1] := SmallInt(SilkSat16(SilkRShiftRound(Sum, 8)));
  end;
  Stereo.PreviousPredictionQ13[0] := PredictionQ13[0];
  Stereo.PreviousPredictionQ13[1] := PredictionQ13[1];
  for N := 0 to FrameLength - 1 do
  begin
    Sum := X1[N + 1] + LongInt(X2[N + 1]);
    Difference := X1[N + 1] - LongInt(X2[N + 1]);
    X1[N + 1] := SmallInt(SilkSat16(Sum));
    X2[N + 1] := SmallInt(SilkSat16(Difference));
  end;
end;

function TSilkDecoder.Decode(var Control: TSilkDecodeControl; LostFlag: Integer; NewPacket: Boolean;
  Decoder: TOpusRangeDecoder; Output: PSmallInt; out SampleCount: Integer): Boolean;
const
  PitchMultipliers: array[0..2] of Integer = (6, 4, 3);
var
  Index, N, FrequencyKHz, LbrrSymbol, FrameIndex, ConditionalCoding, DecodedSamples: Integer;
  DecodeOnlyMiddle, HasSide, StereoToMono: Boolean;
  MidSidePredictionQ13: array[0..1] of LongInt;
  Pulses: array[0..SilkMaximumFrameLength + 15] of SmallInt;
  Temporary: array[0..1, 0..SilkMaximumFrameLength + 1] of SmallInt;
  Resampled: array[0..960 - 1] of SmallInt;
  MiddleOnly: Integer;
begin
  SampleCount := 0;
  DecodeOnlyMiddle := False;
  MidSidePredictionQ13[0] := 0;
  MidSidePredictionQ13[1] := 0;
  DecodedSamples := 0;
  if NewPacket then
    for N := 0 to Control.InternalChannels - 1 do
      FChannels[N].FramesDecoded := 0;
  if Control.InternalChannels > FInternalChannels then
    ResetChannel(FChannels[1]);
  StereoToMono := (Control.InternalChannels = 1) and (FInternalChannels = 2) and
    (Control.InternalSampleRate = 1000 * FChannels[0].FrequencyKHz);
  if FChannels[0].FramesDecoded = 0 then
    for N := 0 to Control.InternalChannels - 1 do
    begin
      case Control.PayloadSizeMs of
        0, 10:
          begin
            FChannels[N].FramesPerPacket := 1;
            FChannels[N].SubframeCount := 2;
          end;
        20:
          begin
            FChannels[N].FramesPerPacket := 1;
            FChannels[N].SubframeCount := 4;
          end;
        40:
          begin
            FChannels[N].FramesPerPacket := 2;
            FChannels[N].SubframeCount := 4;
          end;
        60:
          begin
            FChannels[N].FramesPerPacket := 3;
            FChannels[N].SubframeCount := 4;
          end;
      else
        Exit(False);
      end;
      FrequencyKHz := (Control.InternalSampleRate shr 10) + 1;
      if (FrequencyKHz <> 8) and (FrequencyKHz <> 12) and (FrequencyKHz <> 16) then
        Exit(False);
      SetSampleRate(FChannels[N], FrequencyKHz, Control.ApiSampleRate);
    end;
  if (Control.ApiChannels = 2) and (Control.InternalChannels = 2) and ((FApiChannels = 1) or
    (FInternalChannels = 1)) then
  begin
    FStereo.PreviousPredictionQ13[0] := 0;
    FStereo.PreviousPredictionQ13[1] := 0;
    FStereo.Side[0] := 0;
    FStereo.Side[1] := 0;
    FChannels[1].Resampler := FChannels[0].Resampler;
  end;
  FApiChannels := Control.ApiChannels;
  FInternalChannels := Control.InternalChannels;
  if (Control.ApiSampleRate > 48000) or (Control.ApiSampleRate < 8000) then
    Exit(False);
  if (LostFlag <> SilkPacketLost) and (FChannels[0].FramesDecoded = 0) then
  begin
    for N := 0 to Control.InternalChannels - 1 do
    begin
      for Index := 0 to FChannels[N].FramesPerPacket - 1 do
        FChannels[N].VadFlags[Index] := Ord(Decoder.DecodeBitLogP(1));
      FChannels[N].LbrrFlag := Ord(Decoder.DecodeBitLogP(1));
    end;
    for N := 0 to Control.InternalChannels - 1 do
    begin
      FillChar(FChannels[N].LbrrFlags, SizeOf(FChannels[N].LbrrFlags), 0);
      if FChannels[N].LbrrFlag <> 0 then
      begin
        if FChannels[N].FramesPerPacket = 1 then
          FChannels[N].LbrrFlags[0] := 1
        else
        begin
          if FChannels[N].FramesPerPacket = 2 then
            LbrrSymbol := Decoder.DecodeIcdf(@SilkLBRRFlags2ICDF[0], 8) + 1
          else
            LbrrSymbol := Decoder.DecodeIcdf(@SilkLBRRFlags3ICDF[0], 8) + 1;
          for Index := 0 to FChannels[N].FramesPerPacket - 1 do
            FChannels[N].LbrrFlags[Index] := (LbrrSymbol shr Index) and 1;
        end;
      end;
    end;
    if LostFlag = SilkDecodeNormal then
      for Index := 0 to FChannels[0].FramesPerPacket - 1 do
        for N := 0 to Control.InternalChannels - 1 do
          if FChannels[N].LbrrFlags[Index] <> 0 then
          begin
            if (Control.InternalChannels = 2) and (N = 0) then
            begin
              StereoDecodePrediction(Decoder, MidSidePredictionQ13);
              if FChannels[1].LbrrFlags[Index] = 0 then
                DecodeOnlyMiddle := Decoder.DecodeIcdf(@SilkStereoOnlyCodeMidICDF[0], 8) <> 0;
            end;
            if (Index > 0) and (FChannels[N].LbrrFlags[Index - 1] <> 0) then
              ConditionalCoding := SilkCodeConditionally
            else
              ConditionalCoding := SilkCodeIndependently;
            SilkDecodeIndices(FChannels[N], Decoder, Index, True, ConditionalCoding);
            SilkDecodePulses(Decoder, @Pulses[0], FChannels[N].Indices.SignalType,
              FChannels[N].Indices.QuantOffsetType, FChannels[N].FrameLength);
          end;
  end;
  if Control.InternalChannels = 2 then
  begin
    if (LostFlag = SilkDecodeNormal) or ((LostFlag = SilkDecodeLbrr) and
      (FChannels[0].LbrrFlags[FChannels[0].FramesDecoded] = 1)) then
    begin
      StereoDecodePrediction(Decoder, MidSidePredictionQ13);
      if ((LostFlag = SilkDecodeNormal) and (FChannels[1].VadFlags[FChannels[0].FramesDecoded] = 0)) or
        ((LostFlag = SilkDecodeLbrr) and (FChannels[1].LbrrFlags[FChannels[0].FramesDecoded] = 0)) then
      begin
        MiddleOnly := Decoder.DecodeIcdf(@SilkStereoOnlyCodeMidICDF[0], 8);
        DecodeOnlyMiddle := MiddleOnly <> 0;
      end
      else
        DecodeOnlyMiddle := False;
    end
    else
      for N := 0 to 1 do
        MidSidePredictionQ13[N] := FStereo.PreviousPredictionQ13[N];
  end;
  if (Control.InternalChannels = 2) and not DecodeOnlyMiddle and FPreviousDecodeOnlyMiddle then
  begin
    FillChar(FChannels[1].OutputBuffer, SizeOf(FChannels[1].OutputBuffer), 0);
    FillChar(FChannels[1].LpcStateQ14, SizeOf(FChannels[1].LpcStateQ14), 0);
    FChannels[1].PreviousLag := 100;
    FChannels[1].LastGainIndex := 10;
    FChannels[1].PreviousSignalType := SilkTypeNoVoiceActivity;
    FChannels[1].FirstFrameAfterReset := True;
  end;
  if LostFlag = SilkDecodeNormal then
    HasSide := not DecodeOnlyMiddle
  else
    HasSide := not FPreviousDecodeOnlyMiddle or ((Control.InternalChannels = 2) and (LostFlag = SilkDecodeLbrr) and
      (FChannels[1].LbrrFlags[FChannels[1].FramesDecoded] = 1));
  FillChar(Temporary, SizeOf(Temporary), 0);
  for N := 0 to Control.InternalChannels - 1 do
  begin
    if (N = 0) or HasSide then
    begin
      FrameIndex := FChannels[0].FramesDecoded - N;
      if FrameIndex <= 0 then
        ConditionalCoding := SilkCodeIndependently
      else if LostFlag = SilkDecodeLbrr then
      begin
        if FChannels[N].LbrrFlags[FrameIndex - 1] <> 0 then
          ConditionalCoding := SilkCodeConditionally
        else
          ConditionalCoding := SilkCodeIndependently;
      end
      else if (N > 0) and FPreviousDecodeOnlyMiddle then
        ConditionalCoding := SilkCodeIndependentlyNoLtpScaling
      else
        ConditionalCoding := SilkCodeConditionally;
      DecodeFrame(FChannels[N], Decoder, @Temporary[N, 2], DecodedSamples, LostFlag, ConditionalCoding);
    end
    else
      FillChar(Temporary[N, 2], DecodedSamples * SizeOf(SmallInt), 0);
    Inc(FChannels[N].FramesDecoded);
  end;
  if (Control.ApiChannels = 2) and (Control.InternalChannels = 2) then
    StereoMidSideToLeftRight(FStereo, @Temporary[0, 0], @Temporary[1, 0], MidSidePredictionQ13,
      FChannels[0].FrequencyKHz, DecodedSamples)
  else
  begin
    Move(FStereo.Mid[0], Temporary[0, 0], 2 * SizeOf(SmallInt));
    Move(Temporary[0, DecodedSamples], FStereo.Mid[0], 2 * SizeOf(SmallInt));
  end;
  SampleCount := (DecodedSamples * Control.ApiSampleRate) div (FChannels[0].FrequencyKHz * 1000);
  for N := 0 to SilkMin(Control.ApiChannels, Control.InternalChannels) - 1 do
  begin
    SilkResample(FChannels[N].Resampler, @Resampled[0], @Temporary[N, 1], DecodedSamples);
    if Control.ApiChannels = 2 then
      for Index := 0 to SampleCount - 1 do
        Output[N + 2 * Index] := Resampled[Index]
    else
      Move(Resampled[0], Output^, SampleCount * SizeOf(SmallInt));
  end;
  if (Control.ApiChannels = 2) and (Control.InternalChannels = 1) then
  begin
    if StereoToMono then
    begin
      SilkResample(FChannels[1].Resampler, @Resampled[0], @Temporary[0, 1], DecodedSamples);
      for Index := 0 to SampleCount - 1 do
        Output[1 + 2 * Index] := Resampled[Index];
    end
    else
      for Index := 0 to SampleCount - 1 do
        Output[1 + 2 * Index] := Output[2 * Index];
  end;
  if FChannels[0].PreviousSignalType = SilkTypeVoiced then
    Control.PreviousPitchLag := FChannels[0].PreviousLag * PitchMultipliers[(FChannels[0].FrequencyKHz - 8) shr 2]
  else
    Control.PreviousPitchLag := 0;
  if LostFlag = SilkPacketLost then
  begin
    for Index := 0 to FInternalChannels - 1 do
      FChannels[Index].LastGainIndex := 10;
  end
  else
    FPreviousDecodeOnlyMiddle := DecodeOnlyMiddle;
  Result := True;
end;

end.
