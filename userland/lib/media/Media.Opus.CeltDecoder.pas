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
  The CELT layer's decoder (RFC 6716 section 4.3): one frame of 2.5 to
  20 ms, from the silence flag, the pitch post-filter parameters, the
  transient flag and the energies to the band shapes; then the inverse
  MDCT, the post-filter (a comb filter, cross-faded when its parameters
  change), and de-emphasis to floats between -1 and 1, downsampled for
  outputs below 48 kHz. Lost frames are concealed by pitch repetition
  through an LPC filter, or with shaped noise after long losses.
}
unit Media.Opus.CeltDecoder;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

uses
  Media.Opus.RangeDecoder,
  Media.Opus.CeltMdct;

const
  CeltDecodeBufferSize = 2048;
  CeltLpcOrder = 24;

type
  TCeltDecoder = class
  private
    FMdct: TCeltMdct;
    FChannels: Integer;
    FStreamChannels: Integer;
    FDownsample: Integer;
    FStartBand, FEndBand: Integer;
    FDisableInversion: Boolean;
    FRange: LongWord;
    FError: Boolean;
    FLastPitchIndex: Integer;
    FLossDuration: Integer;
    FSkipPlc: Boolean;
    FPostfilterPeriod, FPostfilterPeriodOld: Integer;
    FPostfilterGain, FPostfilterGainOld: Single;
    FPostfilterTapset, FPostfilterTapsetOld: Integer;
    FPrefilterAndFold: Boolean;
    FPreemphasisMemory: array[0..1] of Single;
    FDecodeMemory: array of Single;
    FLpc: array[0..2 * CeltLpcOrder - 1] of Single;
    FOldBandEnergies: array[0..41] of Single;
    FOldLogEnergies: array[0..41] of Single;
    FOldLogEnergies2: array[0..41] of Single;
    FBackgroundLogEnergies: array[0..41] of Single;
    FOwnDecoder: TOpusRangeDecoder;
    function ChannelMemory(Channel: Integer): PSingle; inline;
    procedure Synthesis(X: PSingle; const OutputSignals: array of PSingle; OldBandEnergies: PSingle;
      StartBand, EffectiveEnd, Channels, OutputChannels: Integer; Transient: Boolean; LM: Integer;
      Silence: Boolean);
    procedure Deemphasis(const Signals: array of PSingle; Pcm: PSingle; N: Integer);
    procedure PrefilterAndFold(N: Integer);
    procedure DecodeLost(N, LM: Integer);
  public
    constructor Create(SampleRate, Channels: Integer);
    destructor Destroy; override;
    procedure Reset;
    { Decodes one frame of FrameSize samples (at the output rate) into Pcm
      (interleaved); Data = nil or Length <= 1 conceals a lost frame.
      Decoder is the range decoder already started on Data (hybrid
      frames), or nil. Returns the samples per channel, or -1. }
    function Decode(Data: PByte; Length: Integer; Pcm: PSingle; FrameSize: Integer;
      Decoder: TOpusRangeDecoder): Integer;
    property StartBand: Integer read FStartBand write FStartBand;
    property EndBand: Integer read FEndBand write FEndBand;
    property StreamChannels: Integer read FStreamChannels write FStreamChannels;
    property FinalRange: LongWord read FRange;
    property Error: Boolean read FError write FError;
    property Channels: Integer read FChannels;
    { The MDCT window (CeltOverlap values), which mode switches fade with. }
    function Window: PSingle;
  end;

{ The ratio of 48 kHz to SampleRate (1, 2, 3, 4, 6), 0 for other rates. }
function CeltResamplingFactor(SampleRate: Integer): Integer;
procedure CeltCombFilter(Y, X: PSingle; T0, T1, N: Integer; G0, G1: Single; Tapset0, Tapset1: Integer;
  Window: TCeltMdct; Overlap: Integer);

implementation

uses
  Math,
  Media.Opus.CeltTables,
  Media.Opus.CeltRate,
  Media.Opus.CeltEnergy,
  Media.Opus.CeltBands,
  Media.Opus.CeltVectors,
  Media.Opus.CeltPitch;

const
  CombFilterMinimumPeriod = 15;
  VerySmall = 1e-30;
  PlcPitchLagMaximum = 720;
  PlcPitchLagMinimum = 100;
  Log2Of2 = 0.6931471805599453094;

function CeltResamplingFactor(SampleRate: Integer): Integer;
begin
  case SampleRate of
    48000: Result := 1;
    24000: Result := 2;
    16000: Result := 3;
    12000: Result := 4;
    8000: Result := 6;
  else
    Result := 0;
  end;
end;

procedure CeltCombFilter(Y, X: PSingle; T0, T1, N: Integer; G0, G1: Single; Tapset0, Tapset1: Integer;
  Window: TCeltMdct; Overlap: Integer);
const
  Gains: array[0..2, 0..2] of Single = (
    (0.3066406250, 0.2170410156, 0.1296386719),
    (0.4638671875, 0.2680664062, 0),
    (0.7998046875, 0.1000976562, 0));
var
  Index: Integer;
  G00, G01, G02, G10, G11, G12, X0, X1, X2, X3, X4, F, OneMinusF: Single;
begin
  if (G0 = 0) and (G1 = 0) then
  begin
    if X <> Y then
      Move(X^, Y^, N * SizeOf(Single));
    Exit;
  end;
  T0 := Max(T0, CombFilterMinimumPeriod);
  T1 := Max(T1, CombFilterMinimumPeriod);
  G00 := G0 * Gains[Tapset0, 0];
  G01 := G0 * Gains[Tapset0, 1];
  G02 := G0 * Gains[Tapset0, 2];
  G10 := G1 * Gains[Tapset1, 0];
  G11 := G1 * Gains[Tapset1, 1];
  G12 := G1 * Gains[Tapset1, 2];
  X1 := X[-T1 + 1];
  X2 := X[-T1];
  X3 := X[-T1 - 1];
  X4 := X[-T1 - 2];
  if (G0 = G1) and (T0 = T1) and (Tapset0 = Tapset1) then
    Overlap := 0;
  for Index := 0 to Overlap - 1 do
  begin
    X0 := X[Index - T1 + 2];
    F := Window.WindowValue(Index) * Window.WindowValue(Index);
    OneMinusF := 1 - F;
    Y[Index] := X[Index] + (OneMinusF * G00) * X[Index - T0]
      + (OneMinusF * G01) * (X[Index - T0 + 1] + X[Index - T0 - 1])
      + (OneMinusF * G02) * (X[Index - T0 + 2] + X[Index - T0 - 2])
      + (F * G10) * X2 + (F * G11) * (X1 + X3) + (F * G12) * (X0 + X4);
    X4 := X3;
    X3 := X2;
    X2 := X1;
    X1 := X0;
  end;
  if G1 = 0 then
  begin
    if X <> Y then
      Move(X[Overlap], Y[Overlap], (N - Overlap) * SizeOf(Single));
    Exit;
  end;
  { The constant part. }
  X4 := X[Overlap - T1 - 2];
  X3 := X[Overlap - T1 - 1];
  X2 := X[Overlap - T1];
  X1 := X[Overlap - T1 + 1];
  for Index := Overlap to N - 1 do
  begin
    X0 := X[Index - T1 + 2];
    Y[Index] := X[Index] + G10 * X2 + G11 * (X1 + X3) + G12 * (X0 + X4);
    X4 := X3;
    X3 := X2;
    X2 := X1;
    X1 := X0;
  end;
end;

constructor TCeltDecoder.Create(SampleRate, Channels: Integer);
begin
  inherited Create;
  FMdct := TCeltMdct.Create(2 * CeltShortMdctSize * 8, CeltMaximumLM, CeltOverlap);
  FChannels := Channels;
  FStreamChannels := Channels;
  FDownsample := CeltResamplingFactor(SampleRate);
  if FDownsample = 0 then
    FDownsample := 1;
  FStartBand := 0;
  FEndBand := CeltBandCount;
  FDisableInversion := Channels = 1;
  SetLength(FDecodeMemory, Channels * (CeltDecodeBufferSize + CeltOverlap));
  FOwnDecoder := TOpusRangeDecoder.Create;
  Reset;
end;

destructor TCeltDecoder.Destroy;
begin
  FMdct.Free;
  FOwnDecoder.Free;
  inherited Destroy;
end;

procedure TCeltDecoder.Reset;
var
  Index: Integer;
begin
  FRange := 0;
  FError := False;
  FLastPitchIndex := 0;
  FLossDuration := 0;
  FPostfilterPeriod := 0;
  FPostfilterPeriodOld := 0;
  FPostfilterGain := 0;
  FPostfilterGainOld := 0;
  FPostfilterTapset := 0;
  FPostfilterTapsetOld := 0;
  FPrefilterAndFold := False;
  FPreemphasisMemory[0] := 0;
  FPreemphasisMemory[1] := 0;
  FillChar(FDecodeMemory[0], Length(FDecodeMemory) * SizeOf(Single), 0);
  FillChar(FLpc, SizeOf(FLpc), 0);
  FillChar(FOldBandEnergies, SizeOf(FOldBandEnergies), 0);
  FillChar(FBackgroundLogEnergies, SizeOf(FBackgroundLogEnergies), 0);
  for Index := 0 to 41 do
  begin
    FOldLogEnergies[Index] := -28;
    FOldLogEnergies2[Index] := -28;
  end;
  FSkipPlc := True;
end;

function TCeltDecoder.Window: PSingle;
begin
  Result := FMdct.WindowData;
end;

function TCeltDecoder.ChannelMemory(Channel: Integer): PSingle;
begin
  Result := @FDecodeMemory[Channel * (CeltDecodeBufferSize + CeltOverlap)];
end;

procedure TCeltDecoder.Synthesis(X: PSingle; const OutputSignals: array of PSingle; OldBandEnergies: PSingle;
  StartBand, EffectiveEnd, Channels, OutputChannels: Integer; Transient: Boolean; LM: Integer; Silence: Boolean);
var
  Frequencies: array[0..959] of Single;
  Frequencies2: PSingle;
  M, BlockCount, NB, Shift, N, Block, Channel, Index: Integer;
begin
  N := CeltShortMdctSize shl LM;
  M := 1 shl LM;
  if Transient then
  begin
    BlockCount := M;
    NB := CeltShortMdctSize;
    Shift := CeltMaximumLM;
  end
  else
  begin
    BlockCount := 1;
    NB := CeltShortMdctSize shl LM;
    Shift := CeltMaximumLM - LM;
  end;
  if (OutputChannels = 2) and (Channels = 1) then
  begin
    CeltDenormaliseBands(X, @Frequencies[0], OldBandEnergies, StartBand, EffectiveEnd, M, FDownsample, Silence);
    Frequencies2 := OutputSignals[1] + CeltOverlap div 2;
    Move(Frequencies[0], Frequencies2^, N * SizeOf(Single));
    for Block := 0 to BlockCount - 1 do
      FMdct.Backward(Frequencies2 + Block, OutputSignals[0] + NB * Block, Shift, BlockCount);
    for Block := 0 to BlockCount - 1 do
      FMdct.Backward(@Frequencies[Block], OutputSignals[1] + NB * Block, Shift, BlockCount);
  end
  else if (OutputChannels = 1) and (Channels = 2) then
  begin
    Frequencies2 := OutputSignals[0] + CeltOverlap div 2;
    CeltDenormaliseBands(X, @Frequencies[0], OldBandEnergies, StartBand, EffectiveEnd, M, FDownsample, Silence);
    CeltDenormaliseBands(X + N, Frequencies2, OldBandEnergies + CeltBandCount, StartBand, EffectiveEnd, M,
      FDownsample, Silence);
    for Index := 0 to N - 1 do
      Frequencies[Index] := 0.5 * Frequencies[Index] + 0.5 * Frequencies2[Index];
    for Block := 0 to BlockCount - 1 do
      FMdct.Backward(@Frequencies[Block], OutputSignals[0] + NB * Block, Shift, BlockCount);
  end
  else
    for Channel := 0 to OutputChannels - 1 do
    begin
      CeltDenormaliseBands(X + Channel * N, @Frequencies[0], OldBandEnergies + Channel * CeltBandCount, StartBand,
        EffectiveEnd, M, FDownsample, Silence);
      for Block := 0 to BlockCount - 1 do
        FMdct.Backward(@Frequencies[Block], OutputSignals[Channel] + NB * Block, Shift, BlockCount);
    end;
end;

procedure TCeltDecoder.Deemphasis(const Signals: array of PSingle; Pcm: PSingle; N: Integer);
var
  Channel, Index: Integer;
  Memory, Value: Single;
  X: PSingle;
begin
  for Channel := 0 to FChannels - 1 do
  begin
    Memory := FPreemphasisMemory[Channel];
    X := Signals[Channel];
    if FDownsample > 1 then
    begin
      for Index := 0 to N - 1 do
      begin
        Value := X[Index] + VerySmall + Memory;
        Memory := CeltPreemphasis * Value;
        if Index mod FDownsample = 0 then
          Pcm[(Index div FDownsample) * FChannels + Channel] := Value * (1 / 32768);
      end;
    end
    else
      for Index := 0 to N - 1 do
      begin
        Value := X[Index] + VerySmall + Memory;
        Memory := CeltPreemphasis * Value;
        Pcm[Index * FChannels + Channel] := Value * (1 / 32768);
      end;
    FPreemphasisMemory[Channel] := Memory;
  end;
end;

procedure TCeltDecoder.PrefilterAndFold(N: Integer);
var
  Temp: array[0..CeltOverlap - 1] of Single;
  Channel, Index: Integer;
  Memory: PSingle;
begin
  for Channel := 0 to FChannels - 1 do
  begin
    Memory := ChannelMemory(Channel);
    CeltCombFilter(@Temp[0], Memory + CeltDecodeBufferSize - N, FPostfilterPeriodOld, FPostfilterPeriod,
      CeltOverlap, -FPostfilterGainOld, -FPostfilterGain, FPostfilterTapsetOld, FPostfilterTapset, nil, 0);
    for Index := 0 to CeltOverlap div 2 - 1 do
      Memory[CeltDecodeBufferSize - N + Index] := FMdct.WindowValue(Index) * Temp[CeltOverlap - 1 - Index]
        + FMdct.WindowValue(CeltOverlap - Index - 1) * Temp[Index];
  end;
end;

procedure TCeltDecoder.DecodeLost(N, LM: Integer);
var
  Channel, Index, J, Band, Offset, BandLength, EffectiveEnd, PitchIndex, ExcitationLength: Integer;
  DecayLength, ExtrapolationOffset, ExtrapolationLength: Integer;
  X: array[0..2 * 960 - 1] of Single;
  Excitation: array[0..CeltMaximumPeriod + CeltLpcOrder - 1] of Single;
  FirTemp: array[0..CeltMaximumPeriod - 1] of Single;
  Correlation: array[0..CeltLpcOrder] of Single;
  LpcMemory: array[0..CeltLpcOrder - 1] of Single;
  LowPass: array[0..CeltDecodeBufferSize div 2 - 1] of Single;
  Seed: LongWord;
  Decay, Fade, Attenuation, E1, E2, S1, S2, Ratio, Value, Gain: Single;
  NoiseBased: Boolean;
  Memories: array[0..1] of PSingle;
  OutputSignals: array[0..1] of PSingle;
  Buffer, Exc: PSingle;
begin
  for Channel := 0 to FChannels - 1 do
  begin
    Memories[Channel] := ChannelMemory(Channel);
    OutputSignals[Channel] := Memories[Channel] + CeltDecodeBufferSize - N;
  end;
  if FChannels = 1 then
  begin
    Memories[1] := Memories[0];
    OutputSignals[1] := OutputSignals[0];
  end;
  NoiseBased := (FLossDuration >= 40) or (FStartBand <> 0) or FSkipPlc;
  if NoiseBased then
  begin
    EffectiveEnd := Max(FStartBand, Min(FEndBand, CeltBandCount));
    for Channel := 0 to FChannels - 1 do
      Move(Memories[Channel][N], Memories[Channel][0], (CeltDecodeBufferSize - N + CeltOverlap) * SizeOf(Single));
    if FPrefilterAndFold then
      PrefilterAndFold(N);
    if FLossDuration = 0 then
      Decay := 1.5
    else
      Decay := 0.5;
    for Channel := 0 to FChannels - 1 do
      for Band := FStartBand to FEndBand - 1 do
        FOldBandEnergies[Channel * CeltBandCount + Band] := Max(FBackgroundLogEnergies[Channel * CeltBandCount + Band],
          FOldBandEnergies[Channel * CeltBandCount + Band] - Decay);
    Seed := FRange;
    for Channel := 0 to FChannels - 1 do
      for Band := FStartBand to EffectiveEnd - 1 do
      begin
        Offset := N * Channel + (CeltBandEdges[Band] shl LM);
        BandLength := (CeltBandEdges[Band + 1] - CeltBandEdges[Band]) shl LM;
        for J := 0 to BandLength - 1 do
        begin
          Seed := CeltRandom(Seed);
          X[Offset + J] := SarLongint(LongInt(Seed), 20);
        end;
        CeltRenormaliseVector(@X[Offset], BandLength, 1);
      end;
    FRange := Seed;
    Synthesis(@X[0], OutputSignals, @FOldBandEnergies[0], FStartBand, EffectiveEnd, FChannels, FChannels, False, LM,
      False);
    FPrefilterAndFold := False;
    FSkipPlc := True;
  end
  else
  begin
    Fade := 1;
    if FLossDuration = 0 then
    begin
      CeltPitchDownsample(Memories, @LowPass[0], CeltDecodeBufferSize, FChannels);
      PitchIndex := CeltPitchSearch(@LowPass[PlcPitchLagMaximum shr 1], @LowPass[0],
        CeltDecodeBufferSize - PlcPitchLagMaximum, PlcPitchLagMaximum - PlcPitchLagMinimum);
      PitchIndex := PlcPitchLagMaximum - PitchIndex;
      FLastPitchIndex := PitchIndex;
    end
    else
    begin
      PitchIndex := FLastPitchIndex;
      Fade := 0.8;
    end;
    ExcitationLength := Min(2 * PitchIndex, CeltMaximumPeriod);
    Exc := @Excitation[CeltLpcOrder];
    for Channel := 0 to FChannels - 1 do
    begin
      S1 := 0;
      Buffer := Memories[Channel];
      for Index := 0 to CeltMaximumPeriod + CeltLpcOrder - 1 do
        Excitation[Index] := Buffer[CeltDecodeBufferSize - CeltMaximumPeriod - CeltLpcOrder + Index];
      if FLossDuration = 0 then
      begin
        CeltAutocorrelation(Exc, @Correlation[0], FMdct.WindowData, CeltOverlap, CeltLpcOrder, CeltMaximumPeriod);
        Correlation[0] := Correlation[0] * 1.0001;
        for Index := 1 to CeltLpcOrder do
          Correlation[Index] := Correlation[Index] - Correlation[Index] * (0.008 * 0.008) * Index * Index;
        CeltLpc(@FLpc[Channel * CeltLpcOrder], @Correlation[0], CeltLpcOrder);
      end;
      CeltFir(Exc + CeltMaximumPeriod - ExcitationLength, @FLpc[Channel * CeltLpcOrder], @FirTemp[0], ExcitationLength,
        CeltLpcOrder);
      Move(FirTemp[0], Exc[CeltMaximumPeriod - ExcitationLength], ExcitationLength * SizeOf(Single));
      E1 := 1;
      E2 := 1;
      DecayLength := ExcitationLength shr 1;
      for Index := 0 to DecayLength - 1 do
      begin
        Value := Exc[CeltMaximumPeriod - DecayLength + Index];
        E1 := E1 + Value * Value;
        Value := Exc[CeltMaximumPeriod - 2 * DecayLength + Index];
        E2 := E2 + Value * Value;
      end;
      E1 := Min(E1, E2);
      Decay := Sqrt(0.5 * E1 / E2);
      Move(Buffer[N], Buffer[0], (CeltDecodeBufferSize - N) * SizeOf(Single));
      ExtrapolationOffset := CeltMaximumPeriod - PitchIndex;
      ExtrapolationLength := N + CeltOverlap;
      Attenuation := Fade * Decay;
      J := 0;
      for Index := 0 to ExtrapolationLength - 1 do
      begin
        if J >= PitchIndex then
        begin
          Dec(J, PitchIndex);
          Attenuation := Attenuation * Decay;
        end;
        Buffer[CeltDecodeBufferSize - N + Index] := Attenuation * Exc[ExtrapolationOffset + J];
        Value := Buffer[CeltDecodeBufferSize - CeltMaximumPeriod - N + ExtrapolationOffset + J];
        S1 := S1 + Value * Value;
        Inc(J);
      end;
      for Index := 0 to CeltLpcOrder - 1 do
        LpcMemory[Index] := Buffer[CeltDecodeBufferSize - N - 1 - Index];
      CeltIir(Buffer + CeltDecodeBufferSize - N, @FLpc[Channel * CeltLpcOrder], Buffer + CeltDecodeBufferSize - N,
        ExtrapolationLength, CeltLpcOrder, @LpcMemory[0]);
      S2 := 0;
      for Index := 0 to ExtrapolationLength - 1 do
      begin
        Value := Buffer[CeltDecodeBufferSize - N + Index];
        S2 := S2 + Value * Value;
      end;
      if not (S1 > 0.2 * S2) then
      begin
        for Index := 0 to ExtrapolationLength - 1 do
          Buffer[CeltDecodeBufferSize - N + Index] := 0;
      end
      else if S1 < S2 then
      begin
        Ratio := Sqrt((0.5 * S1 + 1) / (S2 + 1));
        for Index := 0 to CeltOverlap - 1 do
        begin
          Gain := 1 - FMdct.WindowValue(Index) * (1 - Ratio);
          Buffer[CeltDecodeBufferSize - N + Index] := Gain * Buffer[CeltDecodeBufferSize - N + Index];
        end;
        for Index := CeltOverlap to ExtrapolationLength - 1 do
          Buffer[CeltDecodeBufferSize - N + Index] := Ratio * Buffer[CeltDecodeBufferSize - N + Index];
      end;
    end;
    FPrefilterAndFold := True;
  end;
  FLossDuration := Min(10000, FLossDuration + (1 shl LM));
end;

function TCeltDecoder.Decode(Data: PByte; Length: Integer; Pcm: PSingle; FrameSize: Integer;
  Decoder: TOpusRangeDecoder): Integer;
var
  LM, M, N, Channel, Index, CC, C, EffectiveEnd, TotalBits, Tell, PostfilterPitch, PostfilterTapset: Integer;
  Octave, QuantisedGain, SpreadDecision, DynamicAllocationLogP, Width, Quanta, LoopLogP, Boost: Integer;
  AllocationTrim, Bits, AntiCollapseReserve, Intensity, DualStereo, Balance, CodedBands, Missing: Integer;
  Silence, Transient, IntraEnergy, AntiCollapseOn, Flag: Boolean;
  PostfilterGain, Safety, Slope, E0, E1, E2, MaximumBackgroundIncrease: Single;
  Memories, OutputSignals: array[0..1] of PSingle;
  TfResolution, Caps, Offsets, FineQuant, Pulses, FinePriority: TCeltBandInts;
  CollapseMasks: TCeltCollapseMasks;
  X: array[0..2 * 960 - 1] of Single;
  TellFraction: LongWord;
  TfSelect, TfChanged, Current, LogP, TfSelectReserve: Integer;
  Budget, TellTf: Integer;
begin
  CC := FChannels;
  C := FStreamChannels;
  FrameSize := FrameSize * FDownsample;
  LM := 0;
  while (LM <= CeltMaximumLM) and ((CeltShortMdctSize shl LM) <> FrameSize) do
    Inc(LM);
  if LM > CeltMaximumLM then
    Exit(-1);
  M := 1 shl LM;
  if (Length < 0) or (Length > 1275) then
    Exit(-1);
  N := M * CeltShortMdctSize;
  for Channel := 0 to CC - 1 do
  begin
    Memories[Channel] := ChannelMemory(Channel);
    OutputSignals[Channel] := Memories[Channel] + CeltDecodeBufferSize - N;
  end;
  if CC = 1 then
  begin
    Memories[1] := Memories[0];
    OutputSignals[1] := OutputSignals[0];
  end;
  EffectiveEnd := FEndBand;
  if EffectiveEnd > CeltBandCount then
    EffectiveEnd := CeltBandCount;
  if (Data = nil) or (Length <= 1) then
  begin
    DecodeLost(N, LM);
    Deemphasis(OutputSignals, Pcm, N);
    Exit(FrameSize div FDownsample);
  end;
  if FLossDuration = 0 then
    FSkipPlc := False;
  if Decoder = nil then
  begin
    FOwnDecoder.Init(Data, Length);
    Decoder := FOwnDecoder;
  end;
  if C = 1 then
    for Index := 0 to CeltBandCount - 1 do
      FOldBandEnergies[Index] := Max(FOldBandEnergies[Index], FOldBandEnergies[CeltBandCount + Index]);
  TotalBits := Length * 8;
  Tell := Decoder.Tell;
  if Tell >= TotalBits then
    Silence := True
  else if Tell = 1 then
    Silence := Decoder.DecodeBitLogP(15)
  else
    Silence := False;
  if Silence then
  begin
    Tell := Length * 8;
    Decoder.TotalBits := Decoder.TotalBits + Tell - Decoder.Tell;
  end;
  PostfilterGain := 0;
  PostfilterPitch := 0;
  PostfilterTapset := 0;
  if (FStartBand = 0) and (Tell + 16 <= TotalBits) then
  begin
    if Decoder.DecodeBitLogP(1) then
    begin
      Octave := Decoder.DecodeUInt(6);
      PostfilterPitch := (16 shl Octave) + Integer(Decoder.DecodeBits(4 + Octave)) - 1;
      QuantisedGain := Decoder.DecodeBits(3);
      if Decoder.Tell + 2 <= TotalBits then
        PostfilterTapset := Decoder.DecodeIcdf(@CeltTapsetIcdf[0], 2);
      PostfilterGain := 0.09375 * (QuantisedGain + 1);
    end;
    Tell := Decoder.Tell;
  end;
  if (LM > 0) and (Tell + 3 <= TotalBits) then
  begin
    Transient := Decoder.DecodeBitLogP(3);
    Tell := Decoder.Tell;
  end
  else
    Transient := False;
  if Tell + 3 <= TotalBits then
    IntraEnergy := Decoder.DecodeBitLogP(3)
  else
    IntraEnergy := False;
  if not IntraEnergy and (FLossDuration <> 0) then
    for Channel := 0 to 1 do
    begin
      Safety := 0;
      Missing := Min(10, FLossDuration shr LM);
      if LM = 0 then
        Safety := 1.5
      else if LM = 1 then
        Safety := 0.5;
      for Index := FStartBand to FEndBand - 1 do
      begin
        if FOldBandEnergies[Channel * CeltBandCount + Index] < Max(FOldLogEnergies[Channel * CeltBandCount + Index],
          FOldLogEnergies2[Channel * CeltBandCount + Index]) then
        begin
          E0 := FOldBandEnergies[Channel * CeltBandCount + Index];
          E1 := FOldLogEnergies[Channel * CeltBandCount + Index];
          E2 := FOldLogEnergies2[Channel * CeltBandCount + Index];
          Slope := Max(E1 - E0, 0.5 * (E2 - E0));
          E0 := E0 - Max(0, (1 + Missing) * Slope);
          FOldBandEnergies[Channel * CeltBandCount + Index] := Max(-20, E0);
        end
        else
          FOldBandEnergies[Channel * CeltBandCount + Index] := Min(Min(FOldBandEnergies[Channel * CeltBandCount + Index],
            FOldLogEnergies[Channel * CeltBandCount + Index]), FOldLogEnergies2[Channel * CeltBandCount + Index]);
        FOldBandEnergies[Channel * CeltBandCount + Index] := FOldBandEnergies[Channel * CeltBandCount + Index] - Safety;
      end;
    end;
  CeltDecodeCoarseEnergy(FStartBand, FEndBand, @FOldBandEnergies[0], IntraEnergy, Decoder, C, LM);
  { Time-frequency resolution. }
  FillChar(TfResolution, SizeOf(TfResolution), 0);
  Budget := Integer(Decoder.Storage) * 8;
  TellTf := Decoder.Tell;
  if Transient then
    LogP := 2
  else
    LogP := 4;
  if (LM > 0) and (TellTf + LogP + 1 <= Budget) then
    TfSelectReserve := 1
  else
    TfSelectReserve := 0;
  Dec(Budget, TfSelectReserve);
  TfChanged := 0;
  Current := 0;
  for Index := FStartBand to FEndBand - 1 do
  begin
    if TellTf + LogP <= Budget then
    begin
      Current := Current xor Ord(Decoder.DecodeBitLogP(LogP));
      TellTf := Decoder.Tell;
      TfChanged := TfChanged or Current;
    end;
    TfResolution[Index] := Current;
    if Transient then
      LogP := 4
    else
      LogP := 5;
  end;
  TfSelect := 0;
  if (TfSelectReserve <> 0) and (CeltTfSelectTable[LM, 4 * Ord(Transient) + 0 + TfChanged] <>
    CeltTfSelectTable[LM, 4 * Ord(Transient) + 2 + TfChanged]) then
    TfSelect := Ord(Decoder.DecodeBitLogP(1));
  for Index := FStartBand to FEndBand - 1 do
    TfResolution[Index] := CeltTfSelectTable[LM, 4 * Ord(Transient) + 2 * TfSelect + TfResolution[Index]];
  Tell := Decoder.Tell;
  SpreadDecision := CeltSpreadNormal;
  if Tell + 4 <= TotalBits then
    SpreadDecision := Decoder.DecodeIcdf(@CeltSpreadIcdf[0], 5);
  CeltInitCaps(Caps, LM, C);
  FillChar(Offsets, SizeOf(Offsets), 0);
  DynamicAllocationLogP := 6;
  TotalBits := TotalBits shl BitResolution;
  TellFraction := Decoder.TellFraction;
  for Index := FStartBand to FEndBand - 1 do
  begin
    Width := (C * (CeltBandEdges[Index + 1] - CeltBandEdges[Index])) shl LM;
    Quanta := Min(Width shl BitResolution, Max(6 shl BitResolution, Width));
    LoopLogP := DynamicAllocationLogP;
    Boost := 0;
    while (Integer(TellFraction) + (LoopLogP shl BitResolution) < TotalBits) and (Boost < Caps[Index]) do
    begin
      Flag := Decoder.DecodeBitLogP(LoopLogP);
      TellFraction := Decoder.TellFraction;
      if not Flag then
        Break;
      Inc(Boost, Quanta);
      Dec(TotalBits, Quanta);
      LoopLogP := 1;
    end;
    Offsets[Index] := Boost;
    if Boost > 0 then
      DynamicAllocationLogP := Max(2, DynamicAllocationLogP - 1);
  end;
  if Integer(TellFraction) + (6 shl BitResolution) <= TotalBits then
    AllocationTrim := Decoder.DecodeIcdf(@CeltTrimIcdf[0], 7)
  else
    AllocationTrim := 5;
  Bits := ((Length * 8) shl BitResolution) - Integer(Decoder.TellFraction) - 1;
  if Transient and (LM >= 2) and (Bits >= (LM + 2) shl BitResolution) then
    AntiCollapseReserve := 1 shl BitResolution
  else
    AntiCollapseReserve := 0;
  Dec(Bits, AntiCollapseReserve);
  CodedBands := CeltComputeAllocation(FStartBand, FEndBand, Offsets, Caps, AllocationTrim, Intensity, DualStereo,
    Bits, Balance, Pulses, FineQuant, FinePriority, C, LM, Decoder);
  CeltDecodeFineEnergy(FStartBand, FEndBand, @FOldBandEnergies[0], FineQuant, Decoder, C);
  for Channel := 0 to CC - 1 do
    Move(Memories[Channel][N], Memories[Channel][0], (CeltDecodeBufferSize - N + CeltOverlap) * SizeOf(Single));
  FillChar(CollapseMasks, SizeOf(CollapseMasks), 0);
  FillChar(X, SizeOf(X), 0);
  if C = 2 then
    CeltDecodeAllBands(FStartBand, FEndBand, @X[0], @X[N], CollapseMasks, Pulses, Transient, SpreadDecision,
      DualStereo, Intensity, TfResolution, Length * (8 shl BitResolution) - AntiCollapseReserve, Balance, Decoder, LM,
      CodedBands, FRange, FDisableInversion)
  else
    CeltDecodeAllBands(FStartBand, FEndBand, @X[0], nil, CollapseMasks, Pulses, Transient, SpreadDecision,
      DualStereo, Intensity, TfResolution, Length * (8 shl BitResolution) - AntiCollapseReserve, Balance, Decoder, LM,
      CodedBands, FRange, FDisableInversion);
  AntiCollapseOn := False;
  if AntiCollapseReserve > 0 then
    AntiCollapseOn := Decoder.DecodeBits(1) <> 0;
  CeltFinaliseEnergy(FStartBand, FEndBand, @FOldBandEnergies[0], FineQuant, FinePriority, Length * 8 - Decoder.Tell,
    Decoder, C);
  if AntiCollapseOn then
    CeltAntiCollapse(@X[0], CollapseMasks, LM, C, N, FStartBand, FEndBand, @FOldBandEnergies[0], @FOldLogEnergies[0],
      @FOldLogEnergies2[0], Pulses, FRange);
  if Silence then
    for Index := 0 to C * CeltBandCount - 1 do
      FOldBandEnergies[Index] := -28;
  if FPrefilterAndFold then
    PrefilterAndFold(N);
  Synthesis(@X[0], OutputSignals, @FOldBandEnergies[0], FStartBand, EffectiveEnd, C, CC, Transient, LM, Silence);
  for Channel := 0 to CC - 1 do
  begin
    FPostfilterPeriod := Max(FPostfilterPeriod, CombFilterMinimumPeriod);
    FPostfilterPeriodOld := Max(FPostfilterPeriodOld, CombFilterMinimumPeriod);
    CeltCombFilter(OutputSignals[Channel], OutputSignals[Channel], FPostfilterPeriodOld, FPostfilterPeriod,
      CeltShortMdctSize, FPostfilterGainOld, FPostfilterGain, FPostfilterTapsetOld, FPostfilterTapset, FMdct,
      CeltOverlap);
    if LM <> 0 then
      CeltCombFilter(OutputSignals[Channel] + CeltShortMdctSize, OutputSignals[Channel] + CeltShortMdctSize,
        FPostfilterPeriod, PostfilterPitch, N - CeltShortMdctSize, FPostfilterGain, PostfilterGain, FPostfilterTapset,
        PostfilterTapset, FMdct, CeltOverlap);
  end;
  FPostfilterPeriodOld := FPostfilterPeriod;
  FPostfilterGainOld := FPostfilterGain;
  FPostfilterTapsetOld := FPostfilterTapset;
  FPostfilterPeriod := PostfilterPitch;
  FPostfilterGain := PostfilterGain;
  FPostfilterTapset := PostfilterTapset;
  if LM <> 0 then
  begin
    FPostfilterPeriodOld := FPostfilterPeriod;
    FPostfilterGainOld := FPostfilterGain;
    FPostfilterTapsetOld := FPostfilterTapset;
  end;
  if C = 1 then
    Move(FOldBandEnergies[0], FOldBandEnergies[CeltBandCount], CeltBandCount * SizeOf(Single));
  if not Transient then
  begin
    Move(FOldLogEnergies[0], FOldLogEnergies2[0], SizeOf(FOldLogEnergies));
    Move(FOldBandEnergies[0], FOldLogEnergies[0], SizeOf(FOldBandEnergies));
  end
  else
    for Index := 0 to 2 * CeltBandCount - 1 do
      FOldLogEnergies[Index] := Min(FOldLogEnergies[Index], FOldBandEnergies[Index]);
  MaximumBackgroundIncrease := Min(160, FLossDuration + M) * 0.001;
  for Index := 0 to 2 * CeltBandCount - 1 do
    FBackgroundLogEnergies[Index] := Min(FBackgroundLogEnergies[Index] + MaximumBackgroundIncrease,
      FOldBandEnergies[Index]);
  for Channel := 0 to 1 do
  begin
    for Index := 0 to FStartBand - 1 do
    begin
      FOldBandEnergies[Channel * CeltBandCount + Index] := 0;
      FOldLogEnergies[Channel * CeltBandCount + Index] := -28;
      FOldLogEnergies2[Channel * CeltBandCount + Index] := -28;
    end;
    for Index := FEndBand to CeltBandCount - 1 do
    begin
      FOldBandEnergies[Channel * CeltBandCount + Index] := 0;
      FOldLogEnergies[Channel * CeltBandCount + Index] := -28;
      FOldLogEnergies2[Channel * CeltBandCount + Index] := -28;
    end;
  end;
  FRange := Decoder.Range;
  Deemphasis(OutputSignals, Pcm, N);
  FLossDuration := 0;
  FPrefilterAndFold := False;
  if Decoder.Tell > 8 * Length then
    Exit(-1);
  if Decoder.Error then
    FError := True;
  Result := FrameSize div FDownsample;
end;

end.
