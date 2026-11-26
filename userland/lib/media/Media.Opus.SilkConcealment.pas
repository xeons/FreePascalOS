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
  SILK's packet loss concealment and comfort noise (the reference
  decoder's PLC and CNG): good frames update the pitch and LPC state the
  concealment would use; lost frames are extrapolated by pitch repetition
  with decaying gains and random excitation; the first good frame after a
  loss is faded in from the concealed energy; and during losses comfort
  noise shaped by the smoothed spectrum of past silent frames is added.
}
unit Media.Opus.SilkConcealment;

{$mode objfpc}
{$H+}
{$pointermath on}
{$R-}
{$Q-}

interface

uses
  Media.Opus.SilkState;

procedure SilkConcealmentReset(var State: TSilkChannelState);
procedure SilkComfortNoiseReset(var State: TSilkChannelState);
procedure SilkConcealment(var State: TSilkChannelState; var Control: TSilkDecoderControl; Frame: PSmallInt;
  Lost: Boolean);
procedure SilkGlueFrames(var State: TSilkChannelState; Frame: PSmallInt; Length: Integer);
procedure SilkComfortNoise(var State: TSilkChannelState; var Control: TSilkDecoderControl; Frame: PSmallInt;
  Length: Integer);

implementation

uses
  Media.Opus.SilkMath,
  Media.Opus.SilkLpc;

const
  HarmonicAttenuationQ15: array[0..1] of SmallInt = (32440, 31130);
  RandomAttenuationVoicedQ15: array[0..1] of SmallInt = (31130, 26214);
  RandomAttenuationUnvoicedQ15: array[0..1] of SmallInt = (32440, 29491);
  BandwidthExpansionQ16 = 64881;
  VoicedPitchGainStartMinimumQ14 = 11469;
  VoicedPitchGainStartMaximumQ14 = 15565;
  MaximumPitchLagMs = 18;
  RandomBufferSize = 128;
  RandomBufferMask = RandomBufferSize - 1;
  Log2InverseLpcGainHighThreshold = 3;
  Log2InverseLpcGainLowThreshold = 8;
  PitchDriftFactorQ16 = 655;
  ComfortNoiseBufferMaskMaximum = 255;
  ComfortNoiseGainSmoothingQ16 = 4634;
  ComfortNoiseGainSmoothingThresholdQ16 = 46396;
  ComfortNoiseNlsfSmoothingQ16 = 16348;

procedure SilkConcealmentReset(var State: TSilkChannelState);
begin
  State.Concealment.PitchLagQ8 := SilkShl(State.FrameLength, 8 - 1);
  State.Concealment.PreviousGainQ16[0] := 1 shl 16;
  State.Concealment.PreviousGainQ16[1] := 1 shl 16;
  State.Concealment.SubframeLength := 20;
  State.Concealment.SubframeCount := 2;
end;

procedure SilkComfortNoiseReset(var State: TSilkChannelState);
var
  Index, Step, Accumulator: Integer;
begin
  Step := SilkInt16Max div (State.LpcOrder + 1);
  Accumulator := 0;
  for Index := 0 to State.LpcOrder - 1 do
  begin
    Inc(Accumulator, Step);
    State.ComfortNoise.SmoothedNlsfQ15[Index] := Accumulator;
  end;
  State.ComfortNoise.SmoothedGainQ16 := 0;
  State.ComfortNoise.RandomSeed := 3176576;
end;

procedure ConcealmentUpdate(var State: TSilkChannelState; var Control: TSilkDecoderControl);
var
  LtpGainQ14, TempGainQ14, ScaleQ10, ScaleQ14: LongInt;
  Index, J: Integer;
begin
  State.PreviousSignalType := State.Indices.SignalType;
  LtpGainQ14 := 0;
  if State.Indices.SignalType = SilkTypeVoiced then
  begin
    J := 0;
    while J * State.SubframeLength < Control.PitchLags[State.SubframeCount - 1] do
    begin
      if J = State.SubframeCount then
        Break;
      TempGainQ14 := 0;
      for Index := 0 to SilkLtpOrder - 1 do
        Inc(TempGainQ14, Control.LtpCoefficientsQ14[(State.SubframeCount - 1 - J) * SilkLtpOrder + Index]);
      if TempGainQ14 > LtpGainQ14 then
      begin
        LtpGainQ14 := TempGainQ14;
        Move(Control.LtpCoefficientsQ14[(State.SubframeCount - 1 - J) * SilkLtpOrder],
          State.Concealment.LtpCoefficientsQ14[0], SilkLtpOrder * SizeOf(SmallInt));
        State.Concealment.PitchLagQ8 := SilkShl(Control.PitchLags[State.SubframeCount - 1 - J], 8);
      end;
      Inc(J);
    end;
    FillChar(State.Concealment.LtpCoefficientsQ14, SizeOf(State.Concealment.LtpCoefficientsQ14), 0);
    State.Concealment.LtpCoefficientsQ14[SilkLtpOrder div 2] := LtpGainQ14;
    if LtpGainQ14 < VoicedPitchGainStartMinimumQ14 then
    begin
      ScaleQ10 := (VoicedPitchGainStartMinimumQ14 shl 10) div SilkMax(LtpGainQ14, 1);
      for Index := 0 to SilkLtpOrder - 1 do
        State.Concealment.LtpCoefficientsQ14[Index] :=
          SarLongint(SilkMulBB(State.Concealment.LtpCoefficientsQ14[Index], ScaleQ10), 10);
    end
    else if LtpGainQ14 > VoicedPitchGainStartMaximumQ14 then
    begin
      ScaleQ14 := (VoicedPitchGainStartMaximumQ14 shl 14) div SilkMax(LtpGainQ14, 1);
      for Index := 0 to SilkLtpOrder - 1 do
        State.Concealment.LtpCoefficientsQ14[Index] :=
          SarLongint(SilkMulBB(State.Concealment.LtpCoefficientsQ14[Index], ScaleQ14), 14);
    end;
  end
  else
  begin
    State.Concealment.PitchLagQ8 := SilkShl(SilkMulBB(State.FrequencyKHz, 18), 8);
    FillChar(State.Concealment.LtpCoefficientsQ14, SizeOf(State.Concealment.LtpCoefficientsQ14), 0);
  end;
  Move(Control.PredictionCoefficientsQ12[1, 0], State.Concealment.PreviousLpcQ12[0], State.LpcOrder * SizeOf(SmallInt));
  State.Concealment.PreviousLtpScaleQ14 := Control.LtpScaleQ14;
  State.Concealment.PreviousGainQ16[0] := Control.GainsQ16[State.SubframeCount - 2];
  State.Concealment.PreviousGainQ16[1] := Control.GainsQ16[State.SubframeCount - 1];
  State.Concealment.SubframeLength := State.SubframeLength;
  State.Concealment.SubframeCount := State.SubframeCount;
end;

procedure ConcealmentEnergy(out Energy1: LongInt; out Shift1: Integer; out Energy2: LongInt; out Shift2: Integer;
  ExcitationQ14: PLongInt; const PreviousGainQ10: array of LongInt; SubframeLength, SubframeCount: Integer);
var
  Buffer: array[0..2 * 80 - 1] of SmallInt;
  Index, K: Integer;
begin
  for K := 0 to 1 do
    for Index := 0 to SubframeLength - 1 do
      Buffer[K * SubframeLength + Index] := SmallInt(SilkSat16(SarLongint(SilkMulWW(
        ExcitationQ14[Index + (K + SubframeCount - 2) * SubframeLength], PreviousGainQ10[K]), 8)));
  SilkSumSquareShift(Energy1, Shift1, @Buffer[0], SubframeLength);
  SilkSumSquareShift(Energy2, Shift2, @Buffer[SubframeLength], SubframeLength);
end;

procedure ConcealmentConceal(var State: TSilkChannelState; var Control: TSilkDecoderControl; Frame: PSmallInt);
var
  Index, J, K, Lag, Position, LtpBufferIndex, Shift1, Shift2: Integer;
  RandomSeed, HarmonicGainQ15, RandomGainQ15, InverseGainQ30, Energy1, Energy2: LongInt;
  LpcPredictionQ10, LtpPredictionQ12, InverseGain, DownScaleQ30: LongInt;
  RandomScaleQ14: SmallInt;
  RandomPointer, PredictionLag, LpcPointer: PLongInt;
  BQ14: PSmallInt;
  AQ12: array[0..SilkMaximumLpcOrder - 1] of SmallInt;
  Ltp: array[0..SilkLtpMemoryLengthMs * SilkMaximumFrequencyKHz - 1] of SmallInt;
  LtpQ14: array[0..SilkLtpMemoryLengthMs * SilkMaximumFrequencyKHz + SilkMaximumFrameLength - 1] of LongInt;
  PreviousGainQ10: array[0..1] of LongInt;
  Concealment: ^TSilkConcealmentState;
begin
  Concealment := @State.Concealment;
  PreviousGainQ10[0] := SarLongint(Concealment^.PreviousGainQ16[0], 6);
  PreviousGainQ10[1] := SarLongint(Concealment^.PreviousGainQ16[1], 6);
  if State.FirstFrameAfterReset then
    FillChar(Concealment^.PreviousLpcQ12, SizeOf(Concealment^.PreviousLpcQ12), 0);
  ConcealmentEnergy(Energy1, Shift1, Energy2, Shift2, @State.ExcitationQ14[0], PreviousGainQ10, State.SubframeLength,
    State.SubframeCount);
  if SarLongint(Energy1, Shift2) < SarLongint(Energy2, Shift1) then
    RandomPointer := @State.ExcitationQ14[SilkMax(0, (Concealment^.SubframeCount - 1) * Concealment^.SubframeLength -
      RandomBufferSize)]
  else
    RandomPointer := @State.ExcitationQ14[SilkMax(0, Concealment^.SubframeCount * Concealment^.SubframeLength -
      RandomBufferSize)];
  BQ14 := @Concealment^.LtpCoefficientsQ14[0];
  RandomScaleQ14 := Concealment^.RandomScaleQ14;
  HarmonicGainQ15 := HarmonicAttenuationQ15[SilkMin(1, State.LossCount)];
  if State.PreviousSignalType = SilkTypeVoiced then
    RandomGainQ15 := RandomAttenuationVoicedQ15[SilkMin(1, State.LossCount)]
  else
    RandomGainQ15 := RandomAttenuationUnvoicedQ15[SilkMin(1, State.LossCount)];
  SilkBandwidthExpander(@Concealment^.PreviousLpcQ12[0], State.LpcOrder, BandwidthExpansionQ16);
  Move(Concealment^.PreviousLpcQ12[0], AQ12[0], State.LpcOrder * SizeOf(SmallInt));
  if State.LossCount = 0 then
  begin
    RandomScaleQ14 := 1 shl 14;
    if State.PreviousSignalType = SilkTypeVoiced then
    begin
      for Index := 0 to SilkLtpOrder - 1 do
        RandomScaleQ14 := RandomScaleQ14 - BQ14[Index];
      RandomScaleQ14 := SilkMax(3277, RandomScaleQ14);
      RandomScaleQ14 := SmallInt(SarLongint(SilkMulBB(RandomScaleQ14, Concealment^.PreviousLtpScaleQ14), 14));
    end
    else
    begin
      InverseGain := SilkLpcInversePredictionGain(@Concealment^.PreviousLpcQ12[0], State.LpcOrder);
      DownScaleQ30 := SilkMin(SarLongint(1 shl 30, Log2InverseLpcGainHighThreshold), InverseGain);
      DownScaleQ30 := SilkMax(SarLongint(1 shl 30, Log2InverseLpcGainLowThreshold), DownScaleQ30);
      DownScaleQ30 := SilkShl(DownScaleQ30, Log2InverseLpcGainHighThreshold);
      RandomGainQ15 := SarLongint(SilkMulWB(DownScaleQ30, RandomGainQ15), 14);
    end;
  end;
  RandomSeed := Concealment^.RandomSeed;
  Lag := SilkRShiftRound(Concealment^.PitchLagQ8, 8);
  LtpBufferIndex := State.LtpMemoryLength;
  Position := State.LtpMemoryLength - Lag - State.LpcOrder - SilkLtpOrder div 2;
  SilkLpcAnalysisFilter(@Ltp[Position], @State.OutputBuffer[Position], @AQ12[0], State.LtpMemoryLength - Position,
    State.LpcOrder);
  InverseGainQ30 := SilkInverse32VarQ(Concealment^.PreviousGainQ16[1], 46);
  InverseGainQ30 := SilkMin(InverseGainQ30, SilkInt32Max shr 1);
  for Index := Position + State.LpcOrder to State.LtpMemoryLength - 1 do
    LtpQ14[Index] := SilkMulWB(InverseGainQ30, Ltp[Index]);
  for K := 0 to State.SubframeCount - 1 do
  begin
    PredictionLag := @LtpQ14[LtpBufferIndex - Lag + SilkLtpOrder div 2];
    for Index := 0 to State.SubframeLength - 1 do
    begin
      LtpPredictionQ12 := 2;
      LtpPredictionQ12 := SilkMlaWB(LtpPredictionQ12, PredictionLag[0], BQ14[0]);
      LtpPredictionQ12 := SilkMlaWB(LtpPredictionQ12, PredictionLag[-1], BQ14[1]);
      LtpPredictionQ12 := SilkMlaWB(LtpPredictionQ12, PredictionLag[-2], BQ14[2]);
      LtpPredictionQ12 := SilkMlaWB(LtpPredictionQ12, PredictionLag[-3], BQ14[3]);
      LtpPredictionQ12 := SilkMlaWB(LtpPredictionQ12, PredictionLag[-4], BQ14[4]);
      Inc(PredictionLag);
      RandomSeed := SilkRand(RandomSeed);
      J := SarLongint(RandomSeed, 25) and RandomBufferMask;
      LtpQ14[LtpBufferIndex] := SilkShl(SilkMlaWB(LtpPredictionQ12, RandomPointer[J], RandomScaleQ14), 2);
      Inc(LtpBufferIndex);
    end;
    for J := 0 to SilkLtpOrder - 1 do
      BQ14[J] := SarLongint(SilkMulBB(HarmonicGainQ15, BQ14[J]), 15);
    RandomScaleQ14 := SarLongint(SilkMulBB(RandomScaleQ14, RandomGainQ15), 15);
    Concealment^.PitchLagQ8 := SilkMlaWB(Concealment^.PitchLagQ8, Concealment^.PitchLagQ8, PitchDriftFactorQ16);
    Concealment^.PitchLagQ8 := SilkMin(Concealment^.PitchLagQ8, SilkShl(SilkMulBB(MaximumPitchLagMs,
      State.FrequencyKHz), 8));
    Lag := SilkRShiftRound(Concealment^.PitchLagQ8, 8);
  end;
  LpcPointer := @LtpQ14[State.LtpMemoryLength - SilkMaximumLpcOrder];
  Move(State.LpcStateQ14[0], LpcPointer^, SilkMaximumLpcOrder * SizeOf(LongInt));
  for Index := 0 to State.FrameLength - 1 do
  begin
    LpcPredictionQ10 := SarLongint(State.LpcOrder, 1);
    for J := 0 to State.LpcOrder - 1 do
      LpcPredictionQ10 := SilkMlaWB(LpcPredictionQ10, LpcPointer[SilkMaximumLpcOrder + Index - J - 1], AQ12[J]);
    LpcPointer[SilkMaximumLpcOrder + Index] := SilkAddSat32(LpcPointer[SilkMaximumLpcOrder + Index],
      SilkLShiftSat32(LpcPredictionQ10, 4));
    Frame[Index] := SmallInt(SilkSat16(SilkRShiftRound(SilkMulWW(LpcPointer[SilkMaximumLpcOrder + Index],
      PreviousGainQ10[1]), 8)));
  end;
  Move(LpcPointer[State.FrameLength], State.LpcStateQ14[0], SilkMaximumLpcOrder * SizeOf(LongInt));
  Concealment^.RandomSeed := RandomSeed;
  Concealment^.RandomScaleQ14 := RandomScaleQ14;
  for Index := 0 to SilkMaximumSubframes - 1 do
    Control.PitchLags[Index] := Lag;
end;

procedure SilkConcealment(var State: TSilkChannelState; var Control: TSilkDecoderControl; Frame: PSmallInt;
  Lost: Boolean);
begin
  if State.FrequencyKHz <> State.Concealment.FrequencyKHz then
  begin
    SilkConcealmentReset(State);
    State.Concealment.FrequencyKHz := State.FrequencyKHz;
  end;
  if Lost then
  begin
    ConcealmentConceal(State, Control, Frame);
    Inc(State.LossCount);
  end
  else
    ConcealmentUpdate(State, Control);
end;

procedure SilkGlueFrames(var State: TSilkChannelState; Frame: PSmallInt; Length: Integer);
var
  Index, EnergyShift: Integer;
  Energy, FractionQ24, LeadingZeros, GainQ16, SlopeQ16: LongInt;
  Concealment: ^TSilkConcealmentState;
begin
  Concealment := @State.Concealment;
  if State.LossCount <> 0 then
  begin
    SilkSumSquareShift(Concealment^.ConcealedEnergy, Concealment^.ConcealedEnergyShift, Frame, Length);
    Concealment^.LastFrameLost := True;
  end
  else
  begin
    if Concealment^.LastFrameLost then
    begin
      SilkSumSquareShift(Energy, EnergyShift, Frame, Length);
      if EnergyShift > Concealment^.ConcealedEnergyShift then
        Concealment^.ConcealedEnergy := SarLongint(Concealment^.ConcealedEnergy,
          EnergyShift - Concealment^.ConcealedEnergyShift)
      else if EnergyShift < Concealment^.ConcealedEnergyShift then
        Energy := SarLongint(Energy, Concealment^.ConcealedEnergyShift - EnergyShift);
      if Energy > Concealment^.ConcealedEnergy then
      begin
        LeadingZeros := SilkClz32(Concealment^.ConcealedEnergy) - 1;
        Concealment^.ConcealedEnergy := SilkShl(Concealment^.ConcealedEnergy, LeadingZeros);
        Energy := SarLongint(Energy, SilkMax(24 - LeadingZeros, 0));
        FractionQ24 := Concealment^.ConcealedEnergy div SilkMax(Energy, 1);
        GainQ16 := SilkShl(SilkSqrtApprox(FractionQ24), 4);
        SlopeQ16 := ((1 shl 16) - GainQ16) div Length;
        SlopeQ16 := SilkShl(SlopeQ16, 2);
        for Index := 0 to Length - 1 do
        begin
          Frame[Index] := SmallInt(SilkMulWB(GainQ16, Frame[Index]));
          Inc(GainQ16, SlopeQ16);
          if GainQ16 > 1 shl 16 then
            Break;
        end;
      end;
    end;
    Concealment^.LastFrameLost := False;
  end;
end;

procedure ComfortNoiseExcitation(ExcitationQ14, Buffer: PLongInt; Length: Integer; var RandomSeed: LongInt);
var
  Seed: LongInt;
  Index, Position, Mask: Integer;
begin
  Mask := ComfortNoiseBufferMaskMaximum;
  while Mask > Length do
    Mask := Mask shr 1;
  Seed := RandomSeed;
  for Index := 0 to Length - 1 do
  begin
    Seed := SilkRand(Seed);
    Position := SarLongint(Seed, 24) and Mask;
    ExcitationQ14[Index] := Buffer[Position];
  end;
  RandomSeed := Seed;
end;

procedure SilkComfortNoise(var State: TSilkChannelState; var Control: TSilkDecoderControl; Frame: PSmallInt;
  Length: Integer);
var
  Index, Subframe, J: Integer;
  LpcPredictionQ10, MaximumGainQ16, GainQ16, GainQ10: LongInt;
  AQ12: array[0..SilkMaximumLpcOrder - 1] of SmallInt;
  Signal: array[0..SilkMaximumFrameLength + SilkMaximumLpcOrder - 1] of LongInt;
  Noise: ^TSilkComfortNoiseState;
begin
  Noise := @State.ComfortNoise;
  if State.FrequencyKHz <> Noise^.FrequencyKHz then
  begin
    SilkComfortNoiseReset(State);
    Noise^.FrequencyKHz := State.FrequencyKHz;
  end;
  if (State.LossCount = 0) and (State.PreviousSignalType = SilkTypeNoVoiceActivity) then
  begin
    for Index := 0 to State.LpcOrder - 1 do
      Noise^.SmoothedNlsfQ15[Index] := Noise^.SmoothedNlsfQ15[Index] + SilkMulWB(LongInt(State.PreviousNlsfQ15[Index]) -
        Noise^.SmoothedNlsfQ15[Index], ComfortNoiseNlsfSmoothingQ16);
    MaximumGainQ16 := 0;
    Subframe := 0;
    for Index := 0 to State.SubframeCount - 1 do
      if Control.GainsQ16[Index] > MaximumGainQ16 then
      begin
        MaximumGainQ16 := Control.GainsQ16[Index];
        Subframe := Index;
      end;
    Move(Noise^.ExcitationBufferQ14[0], Noise^.ExcitationBufferQ14[State.SubframeLength],
      (State.SubframeCount - 1) * State.SubframeLength * SizeOf(LongInt));
    Move(State.ExcitationQ14[Subframe * State.SubframeLength], Noise^.ExcitationBufferQ14[0],
      State.SubframeLength * SizeOf(LongInt));
    for Index := 0 to State.SubframeCount - 1 do
    begin
      Inc(Noise^.SmoothedGainQ16, SilkMulWB(Control.GainsQ16[Index] - Noise^.SmoothedGainQ16,
        ComfortNoiseGainSmoothingQ16));
      if SilkMulWW(Noise^.SmoothedGainQ16, ComfortNoiseGainSmoothingThresholdQ16) > Control.GainsQ16[Index] then
        Noise^.SmoothedGainQ16 := Control.GainsQ16[Index];
    end;
  end;
  if State.LossCount <> 0 then
  begin
    GainQ16 := SilkMulWW(State.Concealment.RandomScaleQ14, State.Concealment.PreviousGainQ16[1]);
    if (GainQ16 >= 1 shl 21) or (Noise^.SmoothedGainQ16 > 1 shl 23) then
    begin
      GainQ16 := SarLongint(GainQ16, 16) * SarLongint(GainQ16, 16);
      GainQ16 := SarLongint(Noise^.SmoothedGainQ16, 16) * SarLongint(Noise^.SmoothedGainQ16, 16) - SilkShl(GainQ16, 5);
      GainQ16 := SilkShl(SilkSqrtApprox(GainQ16), 16);
    end
    else
    begin
      GainQ16 := SilkMulWW(GainQ16, GainQ16);
      GainQ16 := SilkMulWW(Noise^.SmoothedGainQ16, Noise^.SmoothedGainQ16) - SilkShl(GainQ16, 5);
      GainQ16 := SilkShl(SilkSqrtApprox(GainQ16), 8);
    end;
    GainQ10 := SarLongint(GainQ16, 6);
    ComfortNoiseExcitation(@Signal[SilkMaximumLpcOrder], @Noise^.ExcitationBufferQ14[0], Length, Noise^.RandomSeed);
    SilkNlsfToLpc(@AQ12[0], @Noise^.SmoothedNlsfQ15[0], State.LpcOrder);
    Move(Noise^.SynthesisState[0], Signal[0], SilkMaximumLpcOrder * SizeOf(LongInt));
    for Index := 0 to Length - 1 do
    begin
      LpcPredictionQ10 := SarLongint(State.LpcOrder, 1);
      for J := 0 to State.LpcOrder - 1 do
        LpcPredictionQ10 := SilkMlaWB(LpcPredictionQ10, Signal[SilkMaximumLpcOrder + Index - J - 1], AQ12[J]);
      Signal[SilkMaximumLpcOrder + Index] := SilkAddSat32(Signal[SilkMaximumLpcOrder + Index],
        SilkLShiftSat32(LpcPredictionQ10, 4));
      Frame[Index] := SmallInt(SilkSat16(Frame[Index] + SilkSat16(SilkRShiftRound(SilkMulWW(
        Signal[SilkMaximumLpcOrder + Index], GainQ10), 8))));
    end;
    Move(Signal[Length], Noise^.SynthesisState[0], SilkMaximumLpcOrder * SizeOf(LongInt));
  end
  else
    FillChar(Noise^.SynthesisState[0], State.LpcOrder * SizeOf(LongInt), 0);
end;

end.
