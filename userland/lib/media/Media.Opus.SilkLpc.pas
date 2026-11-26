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
  SILK's linear prediction coefficients (RFC 6716 sections 4.2.7.5.1 to
  4.2.7.5.8): the NLSF codebooks, the two-stage NLSF dequantisation and
  stabilisation, NLSF to LPC conversion with the fit to 16 bits and the
  stability check by inverse prediction gain, bandwidth expansion, and
  the LPC analysis filter.
}
unit Media.Opus.SilkLpc;

{$mode objfpc}
{$H+}
{$pointermath on}
{ Fixed-point as in the reference: 32-bit wraparound is intended in the
  filters (the _ovflw macros). }
{$R-}
{$Q-}

interface

const
  SilkMaximumLpcOrder = 16;

type
  TSilkNlsfCodebook = record
    VectorCount: Integer;
    Order: Integer;
    QuantStepSizeQ16: Integer;
    Codebook1Q8: PByte;
    Codebook1WeightsQ9: PSmallInt;
    Codebook1Icdf: PByte;
    PredictionQ8: PByte;
    EntropySelection: PByte;
    EntropyIcdf: PByte;
    DeltaMinimumQ15: PSmallInt;
  end;
  PSilkNlsfCodebook = ^TSilkNlsfCodebook;

  TSilkInt16Order = array[0..SilkMaximumLpcOrder - 1] of SmallInt;

function SilkNlsfCodebookNarrow: PSilkNlsfCodebook;
function SilkNlsfCodebookWide: PSilkNlsfCodebook;
procedure SilkNlsfUnpack(EntropyIndex: PSmallInt; PredictionQ8: PByte; Codebook: PSilkNlsfCodebook;
  Codebook1Index: Integer);
procedure SilkNlsfDecode(NlsfQ15: PSmallInt; Indices: PShortInt; Codebook: PSilkNlsfCodebook);
procedure SilkNlsfToLpc(AQ12: PSmallInt; Nlsf: PSmallInt; Order: Integer);
procedure SilkBandwidthExpander(Coefficients: PSmallInt; Order: Integer; ChirpQ16: LongInt);
procedure SilkBandwidthExpander32(Coefficients: PLongInt; Order: Integer; ChirpQ16: LongInt);
function SilkLpcInversePredictionGain(AQ12: PSmallInt; Order: Integer): LongInt;
procedure SilkLpcAnalysisFilter(Output, Input, Coefficients: PSmallInt; Length, Order: Integer);
procedure SilkSumSquareShift(out Energy: LongInt; out Shift: Integer; X: PSmallInt; Length: Integer);

implementation

uses
  Media.Opus.SilkMath,
  Media.Opus.SilkTables;

const
  NlsfQuantMaximumAmplitude = 4;
  NlsfQuantLevelAdjustQ10 = 102;
  QA = 16;
  MaximumStabilizeIterations = 16;
  InversePredictionQA = 24;
  InversePredictionLimit = 16773022;
  MinimumInverseGainQ30 = 107374;

var
  NarrowCodebook, WideCodebook: TSilkNlsfCodebook;

procedure InitCodebooks; forward;

function SilkNlsfCodebookNarrow: PSilkNlsfCodebook;
begin
  if NarrowCodebook.Order = 0 then
    InitCodebooks;
  Result := @NarrowCodebook;
end;

function SilkNlsfCodebookWide: PSilkNlsfCodebook;
begin
  if WideCodebook.Order = 0 then
    InitCodebooks;
  Result := @WideCodebook;
end;

procedure SilkNlsfUnpack(EntropyIndex: PSmallInt; PredictionQ8: PByte; Codebook: PSilkNlsfCodebook;
  Codebook1Index: Integer);
var
  Index: Integer;
  Entry: Byte;
  Selection: PByte;
begin
  Selection := Codebook^.EntropySelection + Codebook1Index * Codebook^.Order div 2;
  Index := 0;
  while Index < Codebook^.Order do
  begin
    Entry := Selection^;
    Inc(Selection);
    EntropyIndex[Index] := ((Entry shr 1) and 7) * (2 * NlsfQuantMaximumAmplitude + 1);
    PredictionQ8[Index] := Codebook^.PredictionQ8[Index + (Entry and 1) * (Codebook^.Order - 1)];
    EntropyIndex[Index + 1] := ((Entry shr 5) and 7) * (2 * NlsfQuantMaximumAmplitude + 1);
    PredictionQ8[Index + 1] := Codebook^.PredictionQ8[Index + ((Entry shr 4) and 1) * (Codebook^.Order - 1) + 1];
    Inc(Index, 2);
  end;
end;

procedure ResidualDequantise(XQ10: PSmallInt; Indices: PShortInt; PredictionQ8: PByte; QuantStepSizeQ16,
  Order: Integer);
var
  Index, OutputQ10, PredictionQ10: Integer;
begin
  OutputQ10 := 0;
  for Index := Order - 1 downto 0 do
  begin
    PredictionQ10 := SarLongint(SilkMulBB(OutputQ10, PredictionQ8[Index]), 8);
    OutputQ10 := Indices[Index] shl 10;
    if OutputQ10 > 0 then
      OutputQ10 := OutputQ10 - NlsfQuantLevelAdjustQ10
    else if OutputQ10 < 0 then
      OutputQ10 := OutputQ10 + NlsfQuantLevelAdjustQ10;
    OutputQ10 := SilkMlaWB(PredictionQ10, OutputQ10, QuantStepSizeQ16);
    XQ10[Index] := SmallInt(OutputQ10);
  end;
end;

procedure InsertionSortIncreasing(A: PSmallInt; Length: Integer);
var
  Index, J: Integer;
  Value: SmallInt;
begin
  for Index := 1 to Length - 1 do
  begin
    Value := A[Index];
    J := Index - 1;
    while (J >= 0) and (Value < A[J]) do
    begin
      A[J + 1] := A[J];
      Dec(J);
    end;
    A[J + 1] := Value;
  end;
end;

procedure NlsfStabilize(Nlsf: PSmallInt; DeltaMinimum: PSmallInt; L: Integer);
var
  Index, Worst, K, Loops: Integer;
  Difference, MinimumDifference, MinimumCentre, MaximumCentre: LongInt;
  CentreFrequency: SmallInt;
begin
  Loops := 0;
  while Loops < 20 do
  begin
    MinimumDifference := Nlsf[0] - DeltaMinimum[0];
    Worst := 0;
    for Index := 1 to L - 1 do
    begin
      Difference := Nlsf[Index] - (Nlsf[Index - 1] + DeltaMinimum[Index]);
      if Difference < MinimumDifference then
      begin
        MinimumDifference := Difference;
        Worst := Index;
      end;
    end;
    Difference := (1 shl 15) - (Nlsf[L - 1] + DeltaMinimum[L]);
    if Difference < MinimumDifference then
    begin
      MinimumDifference := Difference;
      Worst := L;
    end;
    if MinimumDifference >= 0 then
      Exit;
    if Worst = 0 then
      Nlsf[0] := DeltaMinimum[0]
    else if Worst = L then
      Nlsf[L - 1] := (1 shl 15) - DeltaMinimum[L]
    else
    begin
      MinimumCentre := 0;
      for K := 0 to Worst - 1 do
        Inc(MinimumCentre, DeltaMinimum[K]);
      Inc(MinimumCentre, SarLongint(DeltaMinimum[Worst], 1));
      MaximumCentre := 1 shl 15;
      for K := L downto Worst + 1 do
        Dec(MaximumCentre, DeltaMinimum[K]);
      Dec(MaximumCentre, SarLongint(DeltaMinimum[Worst], 1));
      CentreFrequency := SmallInt(SilkLimit(SilkRShiftRound(LongInt(Nlsf[Worst - 1]) + Nlsf[Worst], 1),
        MinimumCentre, MaximumCentre));
      Nlsf[Worst - 1] := CentreFrequency - SarLongint(DeltaMinimum[Worst], 1);
      Nlsf[Worst] := Nlsf[Worst - 1] + DeltaMinimum[Worst];
    end;
    Inc(Loops);
  end;
  InsertionSortIncreasing(Nlsf, L);
  Nlsf[0] := SilkMax(Nlsf[0], DeltaMinimum[0]);
  for Index := 1 to L - 1 do
    Nlsf[Index] := SilkMax(Nlsf[Index], SilkSat16(Nlsf[Index - 1] + DeltaMinimum[Index]));
  Nlsf[L - 1] := SilkMin(Nlsf[L - 1], (1 shl 15) - DeltaMinimum[L]);
  for Index := L - 2 downto 0 do
    Nlsf[Index] := SilkMin(Nlsf[Index], Nlsf[Index + 1] - DeltaMinimum[Index + 1]);
end;

procedure SilkNlsfDecode(NlsfQ15: PSmallInt; Indices: PShortInt; Codebook: PSilkNlsfCodebook);
var
  PredictionQ8: array[0..SilkMaximumLpcOrder - 1] of Byte;
  EntropyIndex: array[0..SilkMaximumLpcOrder - 1] of SmallInt;
  ResidualQ10: array[0..SilkMaximumLpcOrder - 1] of SmallInt;
  Index: Integer;
  Value: LongInt;
  Element: PByte;
  Weights: PSmallInt;
begin
  SilkNlsfUnpack(@EntropyIndex[0], @PredictionQ8[0], Codebook, Indices[0]);
  ResidualDequantise(@ResidualQ10[0], Indices + 1, @PredictionQ8[0], Codebook^.QuantStepSizeQ16, Codebook^.Order);
  Element := Codebook^.Codebook1Q8 + Indices[0] * Codebook^.Order;
  Weights := Codebook^.Codebook1WeightsQ9 + Indices[0] * Codebook^.Order;
  for Index := 0 to Codebook^.Order - 1 do
  begin
    Value := (LongInt(ResidualQ10[Index]) shl 14) div Weights[Index] + (LongInt(Element[Index]) shl 7);
    NlsfQ15[Index] := SilkLimit(Value, 0, 32767);
  end;
  NlsfStabilize(NlsfQ15, Codebook^.DeltaMinimumQ15, Codebook^.Order);
end;

procedure SilkBandwidthExpander(Coefficients: PSmallInt; Order: Integer; ChirpQ16: LongInt);
var
  Index: Integer;
  ChirpMinusOneQ16: LongInt;
begin
  ChirpMinusOneQ16 := ChirpQ16 - 65536;
  for Index := 0 to Order - 2 do
  begin
    Coefficients[Index] := SmallInt(SilkRShiftRound(SilkMul(ChirpQ16, Coefficients[Index]), 16));
    Inc(ChirpQ16, SilkRShiftRound(SilkMul(ChirpQ16, ChirpMinusOneQ16), 16));
  end;
  Coefficients[Order - 1] := SmallInt(SilkRShiftRound(SilkMul(ChirpQ16, Coefficients[Order - 1]), 16));
end;

procedure SilkBandwidthExpander32(Coefficients: PLongInt; Order: Integer; ChirpQ16: LongInt);
var
  Index: Integer;
  ChirpMinusOneQ16: LongInt;
begin
  ChirpMinusOneQ16 := ChirpQ16 - 65536;
  for Index := 0 to Order - 2 do
  begin
    Coefficients[Index] := SilkMulWW(ChirpQ16, Coefficients[Index]);
    Inc(ChirpQ16, SilkRShiftRound(SilkMul(ChirpQ16, ChirpMinusOneQ16), 16));
  end;
  Coefficients[Order - 1] := SilkMulWW(ChirpQ16, Coefficients[Order - 1]);
end;

procedure LpcFit(AOut: PSmallInt; AIn: PLongInt; QOut, QIn, Order: Integer);
var
  Iteration, K, Largest: Integer;
  MaximumAbsolute, AbsoluteValue, ChirpQ16: LongInt;
begin
  Largest := 0;
  Iteration := 0;
  while Iteration < 10 do
  begin
    MaximumAbsolute := 0;
    for K := 0 to Order - 1 do
    begin
      AbsoluteValue := SilkAbs(AIn[K]);
      if AbsoluteValue > MaximumAbsolute then
      begin
        MaximumAbsolute := AbsoluteValue;
        Largest := K;
      end;
    end;
    MaximumAbsolute := SilkRShiftRound(MaximumAbsolute, QIn - QOut);
    if MaximumAbsolute > SilkInt16Max then
    begin
      MaximumAbsolute := SilkMin(MaximumAbsolute, 163838);
      ChirpQ16 := 65470 - ((MaximumAbsolute - SilkInt16Max) shl 14) div
        SarLongint(SilkMul(MaximumAbsolute, Largest + 1), 2);
      SilkBandwidthExpander32(AIn, Order, ChirpQ16);
    end
    else
      Break;
    Inc(Iteration);
  end;
  if Iteration = 10 then
    for K := 0 to Order - 1 do
    begin
      AOut[K] := SmallInt(SilkSat16(SilkRShiftRound(AIn[K], QIn - QOut)));
      AIn[K] := LongInt(AOut[K]) shl (QIn - QOut);
    end
  else
    for K := 0 to Order - 1 do
      AOut[K] := SmallInt(SilkRShiftRound(AIn[K], QIn - QOut));
end;

function InversePredictionGainQA(A: PLongInt; Order: Integer): LongInt;
var
  K, N, Mult2Q: Integer;
  InverseGainQ30, ReflectionQ31, ReflectionMult1Q30, ReflectionMult2, Temp1, Temp2: LongInt;
  Temp64: Int64;
begin
  InverseGainQ30 := 1 shl 30;
  K := Order - 1;
  while K > 0 do
  begin
    if (A[K] > InversePredictionLimit) or (A[K] < -InversePredictionLimit) then
      Exit(0);
    ReflectionQ31 := -SilkShl(A[K], 31 - InversePredictionQA);
    ReflectionMult1Q30 := (1 shl 30) - SilkSMMul(ReflectionQ31, ReflectionQ31);
    InverseGainQ30 := SilkShl(SilkSMMul(InverseGainQ30, ReflectionMult1Q30), 2);
    if InverseGainQ30 < MinimumInverseGainQ30 then
      Exit(0);
    Mult2Q := 32 - SilkClz32(SilkAbs(ReflectionMult1Q30));
    ReflectionMult2 := SilkInverse32VarQ(ReflectionMult1Q30, Mult2Q + 30);
    for N := 0 to ((K + 1) shr 1) - 1 do
    begin
      Temp1 := A[N];
      Temp2 := A[K - N - 1];
      Temp64 := SilkRShiftRound64(Int64(SilkSubSat32(Temp1,
        LongInt(SilkRShiftRound64(Int64(Temp2) * ReflectionQ31, 31)))) * ReflectionMult2, Mult2Q);
      if (Temp64 > SilkInt32Max) or (Temp64 < SilkInt32Min) then
        Exit(0);
      A[N] := LongInt(Temp64);
      Temp64 := SilkRShiftRound64(Int64(SilkSubSat32(Temp2,
        LongInt(SilkRShiftRound64(Int64(Temp1) * ReflectionQ31, 31)))) * ReflectionMult2, Mult2Q);
      if (Temp64 > SilkInt32Max) or (Temp64 < SilkInt32Min) then
        Exit(0);
      A[K - N - 1] := LongInt(Temp64);
    end;
    Dec(K);
  end;
  if (A[K] > InversePredictionLimit) or (A[K] < -InversePredictionLimit) then
    Exit(0);
  ReflectionQ31 := -SilkShl(A[0], 31 - InversePredictionQA);
  ReflectionMult1Q30 := (1 shl 30) - SilkSMMul(ReflectionQ31, ReflectionQ31);
  InverseGainQ30 := SilkShl(SilkSMMul(InverseGainQ30, ReflectionMult1Q30), 2);
  if InverseGainQ30 < MinimumInverseGainQ30 then
    Exit(0);
  Result := InverseGainQ30;
end;

function SilkLpcInversePredictionGain(AQ12: PSmallInt; Order: Integer): LongInt;
var
  K: Integer;
  ATemp: array[0..SilkMaximumLpcOrder - 1] of LongInt;
  DcResponse: LongInt;
begin
  DcResponse := 0;
  for K := 0 to Order - 1 do
  begin
    Inc(DcResponse, AQ12[K]);
    ATemp[K] := LongInt(AQ12[K]) shl (InversePredictionQA - 12);
  end;
  if DcResponse >= 4096 then
    Exit(0);
  Result := InversePredictionGainQA(@ATemp[0], Order);
end;

procedure FindPolynomial(Output: PLongInt; Cosines: PLongInt; HalfOrder: Integer);
var
  K, N: Integer;
  Value: LongInt;
begin
  Output[0] := 1 shl QA;
  Output[1] := -Cosines[0];
  for K := 1 to HalfOrder - 1 do
  begin
    Value := Cosines[2 * K];
    Output[K + 1] := SilkShl(Output[K - 1], 1) - LongInt(SilkRShiftRound64(Int64(Value) * Output[K], QA));
    for N := K downto 2 do
      Inc(Output[N], Output[N - 2] - LongInt(SilkRShiftRound64(Int64(Value) * Output[N - 1], QA)));
    Dec(Output[1], Value);
  end;
end;

procedure SilkNlsfToLpc(AQ12: PSmallInt; Nlsf: PSmallInt; Order: Integer);
const
  Ordering16: array[0..15] of Byte = (0, 15, 8, 7, 4, 11, 12, 3, 2, 13, 10, 5, 6, 9, 14, 1);
  Ordering10: array[0..9] of Byte = (0, 9, 6, 3, 4, 5, 8, 1, 2, 7);
var
  K, Index, HalfOrder: Integer;
  CosinesQA: array[0..SilkMaximumLpcOrder - 1] of LongInt;
  P, Q: array[0..SilkMaximumLpcOrder div 2] of LongInt;
  AQA1: array[0..SilkMaximumLpcOrder - 1] of LongInt;
  PTemp, QTemp, IntegerPart, FractionPart, CosineValue, Delta: LongInt;
  Position: Integer;
begin
  for K := 0 to Order - 1 do
  begin
    IntegerPart := SarLongint(Nlsf[K], 15 - 7);
    FractionPart := Nlsf[K] - (IntegerPart shl (15 - 7));
    CosineValue := SilkLSFCosTabFIXQ12[IntegerPart];
    Delta := SilkLSFCosTabFIXQ12[IntegerPart + 1] - CosineValue;
    if Order = 16 then
      Position := Ordering16[K]
    else
      Position := Ordering10[K];
    CosinesQA[Position] := SilkRShiftRound((CosineValue shl 8) + Delta * FractionPart, 20 - QA);
  end;
  HalfOrder := Order shr 1;
  FindPolynomial(@P[0], @CosinesQA[0], HalfOrder);
  FindPolynomial(@Q[0], @CosinesQA[1], HalfOrder);
  for K := 0 to HalfOrder - 1 do
  begin
    PTemp := P[K + 1] + P[K];
    QTemp := Q[K + 1] - Q[K];
    AQA1[K] := -QTemp - PTemp;
    AQA1[Order - K - 1] := QTemp - PTemp;
  end;
  LpcFit(AQ12, @AQA1[0], 12, QA + 1, Order);
  Index := 0;
  while (SilkLpcInversePredictionGain(AQ12, Order) = 0) and (Index < MaximumStabilizeIterations) do
  begin
    SilkBandwidthExpander32(@AQA1[0], Order, 65536 - SilkShl(2, Index));
    for K := 0 to Order - 1 do
      AQ12[K] := SmallInt(SilkRShiftRound(AQA1[K], QA + 1 - 12));
    Inc(Index);
  end;
end;

procedure SilkLpcAnalysisFilter(Output, Input, Coefficients: PSmallInt; Length, Order: Integer);
var
  Index, J: Integer;
  Sum, Value: LongInt;
  Pointer: PSmallInt;
begin
  for Index := Order to Length - 1 do
  begin
    Pointer := Input + Index - 1;
    Sum := SilkMulBB(Pointer[0], Coefficients[0]);
    for J := 1 to Order - 1 do
      Sum := SilkMlaBB(Sum, Pointer[-J], Coefficients[J]);
    Sum := LongInt(LongWord(LongInt(Pointer[1]) shl 12) - LongWord(Sum));
    Value := SilkRShiftRound(Sum, 12);
    Output[Index] := SmallInt(SilkSat16(Value));
  end;
  FillChar(Output^, Order * SizeOf(SmallInt), 0);
end;

procedure SilkSumSquareShift(out Energy: LongInt; out Shift: Integer; X: PSmallInt; Length: Integer);
var
  Index, ShiftValue: Integer;
  EnergyTemp: LongWord;
  Sum: LongInt;
begin
  ShiftValue := 31 - SilkClz32(Length);
  Sum := Length;
  Index := 0;
  while Index < Length - 1 do
  begin
    EnergyTemp := LongWord(SilkMulBB(X[Index], X[Index]));
    EnergyTemp := LongWord(SilkMlaBB(LongInt(EnergyTemp), X[Index + 1], X[Index + 1]));
    Sum := LongInt(LongWord(Sum) + (EnergyTemp shr ShiftValue));
    Inc(Index, 2);
  end;
  if Index < Length then
  begin
    EnergyTemp := LongWord(SilkMulBB(X[Index], X[Index]));
    Sum := LongInt(LongWord(Sum) + (EnergyTemp shr ShiftValue));
  end;
  ShiftValue := SilkMax(0, ShiftValue + 3 - SilkClz32(Sum));
  Sum := 0;
  Index := 0;
  while Index < Length - 1 do
  begin
    EnergyTemp := LongWord(SilkMulBB(X[Index], X[Index]));
    EnergyTemp := LongWord(SilkMlaBB(LongInt(EnergyTemp), X[Index + 1], X[Index + 1]));
    Sum := LongInt(LongWord(Sum) + (EnergyTemp shr ShiftValue));
    Inc(Index, 2);
  end;
  if Index < Length then
  begin
    EnergyTemp := LongWord(SilkMulBB(X[Index], X[Index]));
    Sum := LongInt(LongWord(Sum) + (EnergyTemp shr ShiftValue));
  end;
  Shift := ShiftValue;
  Energy := Sum;
end;

procedure InitCodebooks;
begin
  NarrowCodebook.VectorCount := 32;
  NarrowCodebook.Order := 10;
  NarrowCodebook.QuantStepSizeQ16 := 11796;
  NarrowCodebook.Codebook1Q8 := @SilkNLSFCB1NBMBQ8[0];
  NarrowCodebook.Codebook1WeightsQ9 := @SilkNLSFCB1WghtQ9[0];
  NarrowCodebook.Codebook1Icdf := @SilkNLSFCB1ICDFNBMB[0];
  NarrowCodebook.PredictionQ8 := @SilkNLSFPREDNBMBQ8[0];
  NarrowCodebook.EntropySelection := @SilkNLSFCB2SELECTNBMB[0];
  NarrowCodebook.EntropyIcdf := @SilkNLSFCB2ICDFNBMB[0];
  NarrowCodebook.DeltaMinimumQ15 := @SilkNLSFDELTAMINNBMBQ15[0];
  WideCodebook.VectorCount := 32;
  WideCodebook.Order := 16;
  WideCodebook.QuantStepSizeQ16 := 9830;
  WideCodebook.Codebook1Q8 := @SilkNLSFCB1WBQ8[0];
  WideCodebook.Codebook1WeightsQ9 := @SilkNLSFCB1WBWghtQ9[0];
  WideCodebook.Codebook1Icdf := @SilkNLSFCB1ICDFWB[0];
  WideCodebook.PredictionQ8 := @SilkNLSFPREDWBQ8[0];
  WideCodebook.EntropySelection := @SilkNLSFCB2SELECTWB[0];
  WideCodebook.EntropyIcdf := @SilkNLSFCB2ICDFWB[0];
  WideCodebook.DeltaMinimumQ15 := @SilkNLSFDELTAMINWBQ15[0];
end;

end.
