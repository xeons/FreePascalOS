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
  SILK's reconstruction (RFC 6716 sections 4.2.7.9): a frame's
  parameters from its indices (gains, the LPC filters with their
  interpolation, pitch lags and LTP filters), then the excitation from
  the pulses and the seed, the long-term (pitch) prediction and the
  short-term (LPC) synthesis filter, subframe by subframe.
}
unit Media.Opus.SilkSynthesis;

{$mode objfpc}
{$H+}
{$pointermath on}
{$R-}
{$Q-}

interface

uses
  Media.Opus.SilkState;

procedure SilkDecodeParameters(var State: TSilkChannelState; var Control: TSilkDecoderControl;
  ConditionalCoding: Integer);
procedure SilkDecodeCore(var State: TSilkChannelState; var Control: TSilkDecoderControl; Output: PSmallInt;
  Pulses: PSmallInt);

implementation

uses
  Media.Opus.SilkMath,
  Media.Opus.SilkTables,
  Media.Opus.SilkLpc,
  Media.Opus.SilkIndices;

const
  BandwidthExpansionAfterLossQ16 = 63570;
  QuantLevelAdjustQ10 = 80;

function LtpCodebook(PeriodicityIndex: Integer): PShortInt;
begin
  case PeriodicityIndex of
    0: Result := @SilkLTPGainVq0[0, 0];
    1: Result := @SilkLTPGainVq1[0, 0];
  else
    Result := @SilkLTPGainVq2[0, 0];
  end;
end;

procedure SilkDecodeParameters(var State: TSilkChannelState; var Control: TSilkDecoderControl;
  ConditionalCoding: Integer);
var
  Index, K, CodebookIndex: Integer;
  NlsfQ15, Nlsf0Q15: array[0..SilkMaximumLpcOrder - 1] of SmallInt;
  Codebook: PShortInt;
begin
  SilkGainsDequantise(@Control.GainsQ16[0], @State.Indices.GainsIndices[0], State.LastGainIndex,
    ConditionalCoding = SilkCodeConditionally, State.SubframeCount);
  SilkNlsfDecode(@NlsfQ15[0], @State.Indices.NlsfIndices[0], State.NlsfCodebook);
  SilkNlsfToLpc(@Control.PredictionCoefficientsQ12[1, 0], @NlsfQ15[0], State.LpcOrder);
  if State.FirstFrameAfterReset then
    State.Indices.NlsfInterpolationCoefficientQ2 := 4;
  if State.Indices.NlsfInterpolationCoefficientQ2 < 4 then
  begin
    for Index := 0 to State.LpcOrder - 1 do
      Nlsf0Q15[Index] := State.PreviousNlsfQ15[Index] + SarLongint(SilkMul(State.Indices.NlsfInterpolationCoefficientQ2,
        NlsfQ15[Index] - State.PreviousNlsfQ15[Index]), 2);
    SilkNlsfToLpc(@Control.PredictionCoefficientsQ12[0, 0], @Nlsf0Q15[0], State.LpcOrder);
  end
  else
    Move(Control.PredictionCoefficientsQ12[1, 0], Control.PredictionCoefficientsQ12[0, 0],
      State.LpcOrder * SizeOf(SmallInt));
  Move(NlsfQ15[0], State.PreviousNlsfQ15[0], State.LpcOrder * SizeOf(SmallInt));
  if State.LossCount <> 0 then
  begin
    SilkBandwidthExpander(@Control.PredictionCoefficientsQ12[0, 0], State.LpcOrder, BandwidthExpansionAfterLossQ16);
    SilkBandwidthExpander(@Control.PredictionCoefficientsQ12[1, 0], State.LpcOrder, BandwidthExpansionAfterLossQ16);
  end;
  if State.Indices.SignalType = SilkTypeVoiced then
  begin
    SilkDecodePitch(State.Indices.LagIndex, State.Indices.ContourIndex, @Control.PitchLags[0], State.FrequencyKHz,
      State.SubframeCount);
    Codebook := LtpCodebook(State.Indices.PeriodicityIndex);
    for K := 0 to State.SubframeCount - 1 do
    begin
      CodebookIndex := State.Indices.LtpIndex[K];
      for Index := 0 to SilkLtpOrder - 1 do
        Control.LtpCoefficientsQ14[K * SilkLtpOrder + Index] := Codebook[CodebookIndex * SilkLtpOrder + Index] shl 7;
    end;
    Control.LtpScaleQ14 := SilkLTPScalesTableQ14[State.Indices.LtpScaleIndex];
  end
  else
  begin
    FillChar(Control.PitchLags, SizeOf(Control.PitchLags), 0);
    FillChar(Control.LtpCoefficientsQ14, SizeOf(Control.LtpCoefficientsQ14), 0);
    State.Indices.PeriodicityIndex := 0;
    Control.LtpScaleQ14 := 0;
  end;
end;

procedure SilkDecodeCore(var State: TSilkChannelState; var Control: TSilkDecoderControl; Output: PSmallInt;
  Pulses: PSmallInt);
var
  Index, K, Lag, StartIndex, LtpBufferIndex, SignalType, J: Integer;
  NlsfInterpolation: Boolean;
  AQ12: PSmallInt;
  BQ14, OutputPointer: PSmallInt;
  ATempQ12: array[0..SilkMaximumLpcOrder - 1] of SmallInt;
  Ltp: array[0..SilkLtpMemoryLengthMs * SilkMaximumFrequencyKHz - 1] of SmallInt;
  LtpQ15: array[0..SilkLtpMemoryLengthMs * SilkMaximumFrequencyKHz + SilkMaximumFrameLength - 1] of LongInt;
  ResidualQ14: array[0..SilkMaximumSubframeLength - 1] of LongInt;
  LpcQ14: array[0..SilkMaximumSubframeLength + SilkMaximumLpcOrder - 1] of LongInt;
  LtpPredictionQ13, LpcPredictionQ10, GainQ10, InverseGainQ31, GainAdjustQ16, RandomSeed, OffsetQ10: LongInt;
  PredictionLag, ExcitationQ14, Residual: PLongInt;
begin
  OffsetQ10 := SilkQuantizationOffsetsQ10[State.Indices.SignalType shr 1, State.Indices.QuantOffsetType];
  NlsfInterpolation := State.Indices.NlsfInterpolationCoefficientQ2 < 4;
  RandomSeed := State.Indices.Seed;
  for Index := 0 to State.FrameLength - 1 do
  begin
    RandomSeed := SilkRand(RandomSeed);
    State.ExcitationQ14[Index] := LongInt(Pulses[Index]) shl 14;
    if State.ExcitationQ14[Index] > 0 then
      Dec(State.ExcitationQ14[Index], QuantLevelAdjustQ10 shl 4)
    else if State.ExcitationQ14[Index] < 0 then
      Inc(State.ExcitationQ14[Index], QuantLevelAdjustQ10 shl 4);
    Inc(State.ExcitationQ14[Index], OffsetQ10 shl 4);
    if RandomSeed < 0 then
      State.ExcitationQ14[Index] := -State.ExcitationQ14[Index];
    RandomSeed := LongInt(LongWord(RandomSeed) + LongWord(LongInt(Pulses[Index])));
  end;
  Move(State.LpcStateQ14[0], LpcQ14[0], SilkMaximumLpcOrder * SizeOf(LongInt));
  ExcitationQ14 := @State.ExcitationQ14[0];
  OutputPointer := Output;
  LtpBufferIndex := State.LtpMemoryLength;
  Lag := 0;
  for K := 0 to State.SubframeCount - 1 do
  begin
    Residual := @ResidualQ14[0];
    AQ12 := @Control.PredictionCoefficientsQ12[K shr 1, 0];
    Move(AQ12^, ATempQ12[0], State.LpcOrder * SizeOf(SmallInt));
    BQ14 := @Control.LtpCoefficientsQ14[K * SilkLtpOrder];
    SignalType := State.Indices.SignalType;
    GainQ10 := SarLongint(Control.GainsQ16[K], 6);
    InverseGainQ31 := SilkInverse32VarQ(Control.GainsQ16[K], 47);
    if Control.GainsQ16[K] <> State.PreviousGainQ16 then
    begin
      GainAdjustQ16 := SilkDiv32VarQ(State.PreviousGainQ16, Control.GainsQ16[K], 16);
      for Index := 0 to SilkMaximumLpcOrder - 1 do
        LpcQ14[Index] := SilkMulWW(GainAdjustQ16, LpcQ14[Index]);
    end
    else
      GainAdjustQ16 := 1 shl 16;
    State.PreviousGainQ16 := Control.GainsQ16[K];
    if (State.LossCount <> 0) and (State.PreviousSignalType = SilkTypeVoiced) and
      (State.Indices.SignalType <> SilkTypeVoiced) and (K < SilkMaximumSubframes div 2) then
    begin
      FillChar(BQ14^, SilkLtpOrder * SizeOf(SmallInt), 0);
      BQ14[SilkLtpOrder div 2] := 4096;
      SignalType := SilkTypeVoiced;
      Control.PitchLags[K] := State.PreviousLag;
    end;
    if SignalType = SilkTypeVoiced then
    begin
      Lag := Control.PitchLags[K];
      if (K = 0) or ((K = 2) and NlsfInterpolation) then
      begin
        StartIndex := State.LtpMemoryLength - Lag - State.LpcOrder - SilkLtpOrder div 2;
        if K = 2 then
          Move(Output^, State.OutputBuffer[State.LtpMemoryLength], 2 * State.SubframeLength * SizeOf(SmallInt));
        SilkLpcAnalysisFilter(@Ltp[StartIndex], @State.OutputBuffer[StartIndex + K * State.SubframeLength], AQ12,
          State.LtpMemoryLength - StartIndex, State.LpcOrder);
        if K = 0 then
          InverseGainQ31 := SilkShl(SilkMulWB(InverseGainQ31, Control.LtpScaleQ14), 2);
        for Index := 0 to Lag + SilkLtpOrder div 2 - 1 do
          LtpQ15[LtpBufferIndex - Index - 1] := SilkMulWB(InverseGainQ31, Ltp[State.LtpMemoryLength - Index - 1]);
      end
      else if GainAdjustQ16 <> 1 shl 16 then
        for Index := 0 to Lag + SilkLtpOrder div 2 - 1 do
          LtpQ15[LtpBufferIndex - Index - 1] := SilkMulWW(GainAdjustQ16, LtpQ15[LtpBufferIndex - Index - 1]);
    end;
    if SignalType = SilkTypeVoiced then
    begin
      PredictionLag := @LtpQ15[LtpBufferIndex - Lag + SilkLtpOrder div 2];
      for Index := 0 to State.SubframeLength - 1 do
      begin
        LtpPredictionQ13 := 2;
        LtpPredictionQ13 := SilkMlaWB(LtpPredictionQ13, PredictionLag[0], BQ14[0]);
        LtpPredictionQ13 := SilkMlaWB(LtpPredictionQ13, PredictionLag[-1], BQ14[1]);
        LtpPredictionQ13 := SilkMlaWB(LtpPredictionQ13, PredictionLag[-2], BQ14[2]);
        LtpPredictionQ13 := SilkMlaWB(LtpPredictionQ13, PredictionLag[-3], BQ14[3]);
        LtpPredictionQ13 := SilkMlaWB(LtpPredictionQ13, PredictionLag[-4], BQ14[4]);
        Inc(PredictionLag);
        Residual[Index] := ExcitationQ14[Index] + SilkShl(LtpPredictionQ13, 1);
        LtpQ15[LtpBufferIndex] := SilkShl(Residual[Index], 1);
        Inc(LtpBufferIndex);
      end;
    end
    else
      Residual := ExcitationQ14;
    for Index := 0 to State.SubframeLength - 1 do
    begin
      LpcPredictionQ10 := SarLongint(State.LpcOrder, 1);
      for J := 0 to State.LpcOrder - 1 do
        LpcPredictionQ10 := SilkMlaWB(LpcPredictionQ10, LpcQ14[SilkMaximumLpcOrder + Index - J - 1], ATempQ12[J]);
      LpcQ14[SilkMaximumLpcOrder + Index] := SilkAddSat32(Residual[Index], SilkLShiftSat32(LpcPredictionQ10, 4));
      OutputPointer[Index] := SmallInt(SilkSat16(SilkRShiftRound(SilkMulWW(LpcQ14[SilkMaximumLpcOrder + Index],
        GainQ10), 8)));
    end;
    Move(LpcQ14[State.SubframeLength], LpcQ14[0], SilkMaximumLpcOrder * SizeOf(LongInt));
    Inc(ExcitationQ14, State.SubframeLength);
    Inc(OutputPointer, State.SubframeLength);
  end;
  Move(LpcQ14[0], State.LpcStateQ14[0], SilkMaximumLpcOrder * SizeOf(LongInt));
end;

end.
