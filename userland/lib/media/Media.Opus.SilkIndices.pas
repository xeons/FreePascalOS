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
  SILK's bitstream (RFC 6716 sections 4.2.7.3 to 4.2.7.8): a frame's
  side information (signal type, gains, NLSF indices, pitch lag and
  contour, LTP filters, seed), and its excitation pulses (rate level,
  pulse counts per 16-sample block, the shell coder's splits, the low
  bits and the signs); with the gain dequantisation and the pitch lags
  the indices stand for.
}
unit Media.Opus.SilkIndices;

{$mode objfpc}
{$H+}
{$pointermath on}
{$R-}
{$Q-}

interface

uses
  Media.Opus.RangeDecoder,
  Media.Opus.SilkState;

procedure SilkDecodeIndices(var State: TSilkChannelState; Decoder: TOpusRangeDecoder; FrameIndex: Integer;
  DecodeLbrr: Boolean; ConditionalCoding: Integer);
procedure SilkDecodePulses(Decoder: TOpusRangeDecoder; Pulses: PSmallInt; SignalType, QuantOffsetType,
  FrameLength: Integer);
procedure SilkGainsDequantise(GainsQ16: PLongInt; Indices: PShortInt; var PreviousIndex: ShortInt;
  Conditional: Boolean; SubframeCount: Integer);
procedure SilkDecodePitch(LagIndex, ContourIndex: Integer; PitchLags: PInteger; FrequencyKHz, SubframeCount: Integer);

implementation

uses
  Media.Opus.SilkMath,
  Media.Opus.SilkTables,
  Media.Opus.SilkLpc;

const
  NlsfQuantMaximumAmplitude = 4;
  ShellCodecFrameLength = 16;
  Log2ShellCodecFrameLength = 4;
  SilkMaximumPulses = 16;
  RateLevelCount = 10;
  GainOffset = 2090;
  InverseScaleQ16 = 1907825;
  LevelsQGain = 64;
  MaximumDeltaGainQuant = 36;
  MinimumDeltaGainQuant = -4;

function LtpGainIcdf(PeriodicityIndex: Integer): PByte;
begin
  case PeriodicityIndex of
    0: Result := @SilkLTPGainICDF0[0];
    1: Result := @SilkLTPGainICDF1[0];
  else
    Result := @SilkLTPGainICDF2[0];
  end;
end;

procedure SilkDecodeIndices(var State: TSilkChannelState; Decoder: TOpusRangeDecoder; FrameIndex: Integer;
  DecodeLbrr: Boolean; ConditionalCoding: Integer);
var
  Index, K, Symbol, DeltaLagIndex: Integer;
  DecodeAbsoluteLag: Boolean;
  EntropyIndex: array[0..SilkMaximumLpcOrder - 1] of SmallInt;
  PredictionQ8: array[0..SilkMaximumLpcOrder - 1] of Byte;
  Indices: ^TSilkSideInfo;
begin
  Indices := @State.Indices;
  if DecodeLbrr or (State.VadFlags[FrameIndex] <> 0) then
    Symbol := Decoder.DecodeIcdf(@SilkTypeOffsetVADICDF[0], 8) + 2
  else
    Symbol := Decoder.DecodeIcdf(@SilkTypeOffsetNoVADICDF[0], 8);
  Indices^.SignalType := Symbol shr 1;
  Indices^.QuantOffsetType := Symbol and 1;
  if ConditionalCoding = SilkCodeConditionally then
    Indices^.GainsIndices[0] := Decoder.DecodeIcdf(@SilkDeltaGainICDF[0], 8)
  else
  begin
    Indices^.GainsIndices[0] := ShortInt(Decoder.DecodeIcdf(@SilkGainICDF[Indices^.SignalType, 0], 8) shl 3);
    Indices^.GainsIndices[0] := ShortInt(Indices^.GainsIndices[0] + Decoder.DecodeIcdf(@SilkUniform8ICDF[0], 8));
  end;
  for Index := 1 to State.SubframeCount - 1 do
    Indices^.GainsIndices[Index] := Decoder.DecodeIcdf(@SilkDeltaGainICDF[0], 8);
  Indices^.NlsfIndices[0] := Decoder.DecodeIcdf(State.NlsfCodebook^.Codebook1Icdf +
    (Indices^.SignalType shr 1) * State.NlsfCodebook^.VectorCount, 8);
  SilkNlsfUnpack(@EntropyIndex[0], @PredictionQ8[0], State.NlsfCodebook, Indices^.NlsfIndices[0]);
  for Index := 0 to State.NlsfCodebook^.Order - 1 do
  begin
    Symbol := Decoder.DecodeIcdf(State.NlsfCodebook^.EntropyIcdf + EntropyIndex[Index], 8);
    if Symbol = 0 then
      Dec(Symbol, Decoder.DecodeIcdf(@SilkNLSFEXTICDF[0], 8))
    else if Symbol = 2 * NlsfQuantMaximumAmplitude then
      Inc(Symbol, Decoder.DecodeIcdf(@SilkNLSFEXTICDF[0], 8));
    Indices^.NlsfIndices[Index + 1] := Symbol - NlsfQuantMaximumAmplitude;
  end;
  if State.SubframeCount = SilkMaximumSubframes then
    Indices^.NlsfInterpolationCoefficientQ2 := Decoder.DecodeIcdf(@SilkNLSFInterpolationFactorICDF[0], 8)
  else
    Indices^.NlsfInterpolationCoefficientQ2 := 4;
  if Indices^.SignalType = SilkTypeVoiced then
  begin
    DecodeAbsoluteLag := True;
    if (ConditionalCoding = SilkCodeConditionally) and (State.EntropyPreviousSignalType = SilkTypeVoiced) then
    begin
      DeltaLagIndex := Decoder.DecodeIcdf(@SilkPitchDeltaICDF[0], 8);
      if DeltaLagIndex > 0 then
      begin
        DeltaLagIndex := DeltaLagIndex - 9;
        Indices^.LagIndex := State.EntropyPreviousLagIndex + DeltaLagIndex;
        DecodeAbsoluteLag := False;
      end;
    end;
    if DecodeAbsoluteLag then
    begin
      Indices^.LagIndex := Decoder.DecodeIcdf(@SilkPitchLagICDF[0], 8) * (State.FrequencyKHz shr 1);
      Indices^.LagIndex := Indices^.LagIndex + Decoder.DecodeIcdf(State.PitchLagLowBitsIcdf, 8);
    end;
    State.EntropyPreviousLagIndex := Indices^.LagIndex;
    Indices^.ContourIndex := Decoder.DecodeIcdf(State.PitchContourIcdf, 8);
    Indices^.PeriodicityIndex := Decoder.DecodeIcdf(@SilkLTPPerIndexICDF[0], 8);
    for K := 0 to State.SubframeCount - 1 do
      Indices^.LtpIndex[K] := Decoder.DecodeIcdf(LtpGainIcdf(Indices^.PeriodicityIndex), 8);
    if ConditionalCoding = SilkCodeIndependently then
      Indices^.LtpScaleIndex := Decoder.DecodeIcdf(@SilkLTPscaleICDF[0], 8)
    else
      Indices^.LtpScaleIndex := 0;
  end;
  State.EntropyPreviousSignalType := Indices^.SignalType;
  Indices^.Seed := Decoder.DecodeIcdf(@SilkUniform4ICDF[0], 8);
end;

procedure DecodeSplit(out Child1, Child2: SmallInt; Decoder: TOpusRangeDecoder; P: Integer; ShellTable: PByte);
begin
  if P > 0 then
  begin
    Child1 := Decoder.DecodeIcdf(ShellTable + SilkShellCodeTableOffsets[P], 8);
    Child2 := P - Child1;
  end
  else
  begin
    Child1 := 0;
    Child2 := 0;
  end;
end;

procedure ShellDecoder(Pulses0: PSmallInt; Decoder: TOpusRangeDecoder; Pulses4: Integer);
var
  Pulses3: array[0..1] of SmallInt;
  Pulses2: array[0..3] of SmallInt;
  Pulses1: array[0..7] of SmallInt;
begin
  DecodeSplit(Pulses3[0], Pulses3[1], Decoder, Pulses4, @SilkShellCodeTable3[0]);
  DecodeSplit(Pulses2[0], Pulses2[1], Decoder, Pulses3[0], @SilkShellCodeTable2[0]);
  DecodeSplit(Pulses1[0], Pulses1[1], Decoder, Pulses2[0], @SilkShellCodeTable1[0]);
  DecodeSplit(Pulses0[0], Pulses0[1], Decoder, Pulses1[0], @SilkShellCodeTable0[0]);
  DecodeSplit(Pulses0[2], Pulses0[3], Decoder, Pulses1[1], @SilkShellCodeTable0[0]);
  DecodeSplit(Pulses1[2], Pulses1[3], Decoder, Pulses2[1], @SilkShellCodeTable1[0]);
  DecodeSplit(Pulses0[4], Pulses0[5], Decoder, Pulses1[2], @SilkShellCodeTable0[0]);
  DecodeSplit(Pulses0[6], Pulses0[7], Decoder, Pulses1[3], @SilkShellCodeTable0[0]);
  DecodeSplit(Pulses2[2], Pulses2[3], Decoder, Pulses3[1], @SilkShellCodeTable2[0]);
  DecodeSplit(Pulses1[4], Pulses1[5], Decoder, Pulses2[2], @SilkShellCodeTable1[0]);
  DecodeSplit(Pulses0[8], Pulses0[9], Decoder, Pulses1[4], @SilkShellCodeTable0[0]);
  DecodeSplit(Pulses0[10], Pulses0[11], Decoder, Pulses1[5], @SilkShellCodeTable0[0]);
  DecodeSplit(Pulses1[6], Pulses1[7], Decoder, Pulses2[3], @SilkShellCodeTable1[0]);
  DecodeSplit(Pulses0[12], Pulses0[13], Decoder, Pulses1[6], @SilkShellCodeTable0[0]);
  DecodeSplit(Pulses0[14], Pulses0[15], Decoder, Pulses1[7], @SilkShellCodeTable0[0]);
end;

procedure DecodeSigns(Decoder: TOpusRangeDecoder; Pulses: PSmallInt; Length, SignalType, QuantOffsetType: Integer;
  const SumPulses: array of Integer);
var
  Index, J, P: Integer;
  Icdf: array[0..1] of Byte;
  IcdfBase: PByte;
  Q: PSmallInt;
begin
  Icdf[1] := 0;
  Q := Pulses;
  IcdfBase := @SilkSignICDF[7 * (QuantOffsetType + (SignalType shl 1))];
  Length := SarLongint(Length + ShellCodecFrameLength div 2, Log2ShellCodecFrameLength);
  for Index := 0 to Length - 1 do
  begin
    P := SumPulses[Index];
    if P > 0 then
    begin
      Icdf[0] := IcdfBase[SilkMin(P and $1F, 6)];
      for J := 0 to ShellCodecFrameLength - 1 do
        if Q[J] > 0 then
          Q[J] := Q[J] * ((Decoder.DecodeIcdf(@Icdf[0], 8) shl 1) - 1);
    end;
    Inc(Q, ShellCodecFrameLength);
  end;
end;

procedure SilkDecodePulses(Decoder: TOpusRangeDecoder; Pulses: PSmallInt; SignalType, QuantOffsetType,
  FrameLength: Integer);
var
  Index, J, K, Iterations, AbsoluteValue, LeftShifts, RateLevelIndex: Integer;
  SumPulses, LeftShiftCounts: array[0..SilkMaximumFrameLength div ShellCodecFrameLength] of Integer;
  Block: PSmallInt;
  Cdf: PByte;
begin
  RateLevelIndex := Decoder.DecodeIcdf(@SilkRateLevelsICDF[SignalType shr 1, 0], 8);
  Iterations := FrameLength shr Log2ShellCodecFrameLength;
  if Iterations * ShellCodecFrameLength < FrameLength then
    Inc(Iterations);
  Cdf := @SilkPulsesPerBlockICDF[RateLevelIndex, 0];
  for Index := 0 to Iterations - 1 do
  begin
    LeftShiftCounts[Index] := 0;
    SumPulses[Index] := Decoder.DecodeIcdf(Cdf, 8);
    while SumPulses[Index] = SilkMaximumPulses + 1 do
    begin
      Inc(LeftShiftCounts[Index]);
      SumPulses[Index] := Decoder.DecodeIcdf(@SilkPulsesPerBlockICDF[RateLevelCount - 1,
        Ord(LeftShiftCounts[Index] = 10)], 8);
    end;
  end;
  for Index := 0 to Iterations - 1 do
    if SumPulses[Index] > 0 then
      ShellDecoder(Pulses + Index * ShellCodecFrameLength, Decoder, SumPulses[Index])
    else
      FillChar(Pulses[Index * ShellCodecFrameLength], ShellCodecFrameLength * SizeOf(SmallInt), 0);
  for Index := 0 to Iterations - 1 do
    if LeftShiftCounts[Index] > 0 then
    begin
      LeftShifts := LeftShiftCounts[Index];
      Block := Pulses + Index * ShellCodecFrameLength;
      for K := 0 to ShellCodecFrameLength - 1 do
      begin
        AbsoluteValue := Block[K];
        for J := 0 to LeftShifts - 1 do
        begin
          AbsoluteValue := AbsoluteValue shl 1;
          Inc(AbsoluteValue, Decoder.DecodeIcdf(@SilkLsbICDF[0], 8));
        end;
        Block[K] := AbsoluteValue;
      end;
      SumPulses[Index] := SumPulses[Index] or (LeftShifts shl 5);
    end;
  DecodeSigns(Decoder, Pulses, FrameLength, SignalType, QuantOffsetType, SumPulses);
end;

procedure SilkGainsDequantise(GainsQ16: PLongInt; Indices: PShortInt; var PreviousIndex: ShortInt;
  Conditional: Boolean; SubframeCount: Integer);
var
  K, IndexTemp, DoubleStepSizeThreshold, Previous: Integer;
begin
  for K := 0 to SubframeCount - 1 do
  begin
    Previous := PreviousIndex;
    if (K = 0) and not Conditional then
      Previous := SilkMax(Indices[K], Previous - 16)
    else
    begin
      IndexTemp := Indices[K] + MinimumDeltaGainQuant;
      DoubleStepSizeThreshold := 2 * MaximumDeltaGainQuant - LevelsQGain + Previous;
      if IndexTemp > DoubleStepSizeThreshold then
        Inc(Previous, (IndexTemp shl 1) - DoubleStepSizeThreshold)
      else
        Inc(Previous, IndexTemp);
    end;
    Previous := SilkLimit(Previous, 0, LevelsQGain - 1);
    PreviousIndex := Previous;
    GainsQ16[K] := SilkLogToLin(SilkMin(SilkMulWB(InverseScaleQ16, Previous) + GainOffset, 3967));
  end;
end;

procedure SilkDecodePitch(LagIndex, ContourIndex: Integer; PitchLags: PInteger; FrequencyKHz, SubframeCount: Integer);
var
  Lag, K, MinimumLag, MaximumLag, Offset: Integer;
begin
  MinimumLag := 2 * FrequencyKHz;
  MaximumLag := 18 * FrequencyKHz;
  Lag := MinimumLag + LagIndex;
  for K := 0 to SubframeCount - 1 do
  begin
    if FrequencyKHz = 8 then
    begin
      if SubframeCount = SilkMaximumSubframes then
        Offset := SilkCBLagsStage2[K, ContourIndex]
      else
        Offset := SilkCBLagsStage210Ms[K, ContourIndex];
    end
    else if SubframeCount = SilkMaximumSubframes then
      Offset := SilkCBLagsStage3[K, ContourIndex]
    else
      Offset := SilkCBLagsStage310Ms[K, ContourIndex];
    PitchLags[K] := SilkLimit(Lag + Offset, MinimumLag, MaximumLag);
  end;
end;

end.
