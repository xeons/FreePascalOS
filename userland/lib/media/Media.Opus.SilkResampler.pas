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
  SILK's resampler from its internal rate (8, 12 or 16 kHz) to the
  decoder's output rate (8, 12, 16, 24 or 48 kHz): 2x upsampling by
  all-pass filters, then (for other ratios) a fractional FIR interpolator;
  downsampling by a second-order AR filter and an FIR. The reference
  decoder's output depends on it bit for bit, so it follows it exactly,
  with its input delay compensation.
}
unit Media.Opus.SilkResampler;

{$mode objfpc}
{$H+}
{$pointermath on}
{$R-}
{$Q-}

interface

const
  SilkResamplerMaximumFirOrder = 36;
  SilkResamplerMaximumIirOrder = 6;

type
  TSilkResamplerKind = (rkCopy, rkUpTwo, rkIirFir, rkDownFir);

  TSilkResamplerState = record
    Iir: array[0..SilkResamplerMaximumIirOrder - 1] of LongInt;
    Fir32: array[0..SilkResamplerMaximumFirOrder - 1] of LongInt;
    Fir16: array[0..SilkResamplerMaximumFirOrder - 1] of SmallInt;
    DelayBuffer: array[0..47] of SmallInt;
    Kind: TSilkResamplerKind;
    BatchSize: Integer;
    InverseRatioQ16: LongInt;
    FirOrder: Integer;
    FirFractions: Integer;
    InputKHz: Integer;
    OutputKHz: Integer;
    InputDelay: Integer;
    Coefficients: PSmallInt;
  end;

{ Prepares State for the decoder's InputRate to OutputRate; False for an
  unsupported pair. }
function SilkResamplerInit(out State: TSilkResamplerState; InputRate, OutputRate: LongInt): Boolean;
{ Resamples InputLength samples (at least 1 ms) from Input to Output. }
procedure SilkResample(var State: TSilkResamplerState; Output, Input: PSmallInt; InputLength: Integer);

implementation

uses
  Media.Opus.SilkMath,
  Media.Opus.SilkTables;

const
  MaximumBatchSizeMs = 10;
  DownOrderFir0 = 18;
  DownOrderFir1 = 24;
  DownOrderFir2 = 36;
  OrderFir12 = 8;
  DelayMatrix: array[0..2, 0..4] of ShortInt = (
    (4, 0, 2, 0, 0),
    (0, 9, 4, 7, 4),
    (0, 3, 12, 7, 7));

function RateId(Rate: LongInt): Integer;
begin
  case Rate of
    8000: Result := 0;
    12000: Result := 1;
    16000: Result := 2;
    24000: Result := 3;
  else
    Result := 4;
  end;
end;

function SilkResamplerInit(out State: TSilkResamplerState; InputRate, OutputRate: LongInt): Boolean;
var
  UpTwo: Integer;
begin
  State := Default(TSilkResamplerState);
  if not ((InputRate = 8000) or (InputRate = 12000) or (InputRate = 16000)) or
    not ((OutputRate = 8000) or (OutputRate = 12000) or (OutputRate = 16000) or (OutputRate = 24000) or
    (OutputRate = 48000)) then
    Exit(False);
  State.InputDelay := DelayMatrix[RateId(InputRate), RateId(OutputRate)];
  State.InputKHz := InputRate div 1000;
  State.OutputKHz := OutputRate div 1000;
  State.BatchSize := State.InputKHz * MaximumBatchSizeMs;
  UpTwo := 0;
  if OutputRate > InputRate then
  begin
    if OutputRate = InputRate * 2 then
      State.Kind := rkUpTwo
    else
    begin
      State.Kind := rkIirFir;
      UpTwo := 1;
    end;
  end
  else if OutputRate < InputRate then
  begin
    State.Kind := rkDownFir;
    if OutputRate * 4 = InputRate * 3 then
    begin
      State.FirFractions := 3;
      State.FirOrder := DownOrderFir0;
      State.Coefficients := @SilkResampler34COEFS[0];
    end
    else if OutputRate * 3 = InputRate * 2 then
    begin
      State.FirFractions := 2;
      State.FirOrder := DownOrderFir0;
      State.Coefficients := @SilkResampler23COEFS[0];
    end
    else if OutputRate * 2 = InputRate then
    begin
      State.FirFractions := 1;
      State.FirOrder := DownOrderFir1;
      State.Coefficients := @SilkResampler12COEFS[0];
    end
    else if OutputRate * 3 = InputRate then
    begin
      State.FirFractions := 1;
      State.FirOrder := DownOrderFir2;
      State.Coefficients := @SilkResampler13COEFS[0];
    end
    else if OutputRate * 4 = InputRate then
    begin
      State.FirFractions := 1;
      State.FirOrder := DownOrderFir2;
      State.Coefficients := @SilkResampler14COEFS[0];
    end
    else if OutputRate * 6 = InputRate then
    begin
      State.FirFractions := 1;
      State.FirOrder := DownOrderFir2;
      State.Coefficients := @SilkResampler16COEFS[0];
    end
    else
      Exit(False);
  end
  else
    State.Kind := rkCopy;
  State.InverseRatioQ16 := SilkShl((SilkShl(InputRate, 14 + UpTwo) div OutputRate), 2);
  while SilkMulWW(State.InverseRatioQ16, OutputRate) < SilkShl(InputRate, UpTwo) do
    Inc(State.InverseRatioQ16);
  Result := True;
end;

procedure UpTwoHighQuality(State: PLongInt; Output, Input: PSmallInt; Length: Integer);
var
  K: Integer;
  In32, Out32A, Out32B, Y, X: LongInt;
begin
  for K := 0 to Length - 1 do
  begin
    In32 := SilkShl(Input[K], 10);
    Y := In32 - State[0];
    X := SilkMulWB(Y, SilkResamplerUp2Hq0[0]);
    Out32A := State[0] + X;
    State[0] := In32 + X;
    Y := Out32A - State[1];
    X := SilkMulWB(Y, SilkResamplerUp2Hq0[1]);
    Out32B := State[1] + X;
    State[1] := Out32A + X;
    Y := Out32B - State[2];
    X := SilkMlaWB(Y, Y, SilkResamplerUp2Hq0[2]);
    Out32A := State[2] + X;
    State[2] := Out32B + X;
    Output[2 * K] := SmallInt(SilkSat16(SilkRShiftRound(Out32A, 10)));
    Y := In32 - State[3];
    X := SilkMulWB(Y, SilkResamplerUp2Hq1[0]);
    Out32A := State[3] + X;
    State[3] := In32 + X;
    Y := Out32A - State[4];
    X := SilkMulWB(Y, SilkResamplerUp2Hq1[1]);
    Out32B := State[4] + X;
    State[4] := Out32A + X;
    Y := Out32B - State[5];
    X := SilkMlaWB(Y, Y, SilkResamplerUp2Hq1[2]);
    Out32A := State[5] + X;
    State[5] := Out32B + X;
    Output[2 * K + 1] := SmallInt(SilkSat16(SilkRShiftRound(Out32A, 10)));
  end;
end;

function IirFirInterpolate(Output, Buffer: PSmallInt; MaximumIndexQ16, IndexIncrementQ16: LongInt): PSmallInt;
var
  IndexQ16, ResultQ15, TableIndex: LongInt;
  Pointer: PSmallInt;
begin
  IndexQ16 := 0;
  while IndexQ16 < MaximumIndexQ16 do
  begin
    TableIndex := SilkMulWB(IndexQ16 and $FFFF, 12);
    Pointer := Buffer + (IndexQ16 shr 16);
    ResultQ15 := SilkMulBB(Pointer[0], SilkResamplerFracFIR12[TableIndex, 0]);
    ResultQ15 := SilkMlaBB(ResultQ15, Pointer[1], SilkResamplerFracFIR12[TableIndex, 1]);
    ResultQ15 := SilkMlaBB(ResultQ15, Pointer[2], SilkResamplerFracFIR12[TableIndex, 2]);
    ResultQ15 := SilkMlaBB(ResultQ15, Pointer[3], SilkResamplerFracFIR12[TableIndex, 3]);
    ResultQ15 := SilkMlaBB(ResultQ15, Pointer[4], SilkResamplerFracFIR12[11 - TableIndex, 3]);
    ResultQ15 := SilkMlaBB(ResultQ15, Pointer[5], SilkResamplerFracFIR12[11 - TableIndex, 2]);
    ResultQ15 := SilkMlaBB(ResultQ15, Pointer[6], SilkResamplerFracFIR12[11 - TableIndex, 1]);
    ResultQ15 := SilkMlaBB(ResultQ15, Pointer[7], SilkResamplerFracFIR12[11 - TableIndex, 0]);
    Output^ := SmallInt(SilkSat16(SilkRShiftRound(ResultQ15, 15)));
    Inc(Output);
    Inc(IndexQ16, IndexIncrementQ16);
  end;
  Result := Output;
end;

procedure ResampleIirFir(var State: TSilkResamplerState; Output, Input: PSmallInt; InputLength: Integer);
var
  Buffer: array[0..2 * 480 + OrderFir12 - 1] of SmallInt;
  SamplesIn: Integer;
  MaximumIndexQ16: LongInt;
begin
  Move(State.Fir16[0], Buffer[0], OrderFir12 * SizeOf(SmallInt));
  repeat
    SamplesIn := SilkMin(InputLength, State.BatchSize);
    UpTwoHighQuality(@State.Iir[0], @Buffer[OrderFir12], Input, SamplesIn);
    MaximumIndexQ16 := SilkShl(SamplesIn, 16 + 1);
    Output := IirFirInterpolate(Output, @Buffer[0], MaximumIndexQ16, State.InverseRatioQ16);
    Inc(Input, SamplesIn);
    Dec(InputLength, SamplesIn);
    if InputLength > 0 then
      Move(Buffer[SamplesIn shl 1], Buffer[0], OrderFir12 * SizeOf(SmallInt))
    else
      Break;
  until False;
  Move(Buffer[SamplesIn shl 1], State.Fir16[0], OrderFir12 * SizeOf(SmallInt));
end;

procedure SecondOrderAr(State, OutputQ8: PLongInt; Input, AQ14: PSmallInt; Length: Integer);
var
  K: Integer;
  Out32: LongInt;
begin
  for K := 0 to Length - 1 do
  begin
    Out32 := State[0] + SilkShl(Input[K], 8);
    OutputQ8[K] := Out32;
    Out32 := SilkShl(Out32, 2);
    State[0] := SilkMlaWB(State[1], Out32, AQ14[0]);
    State[1] := SilkMulWB(Out32, AQ14[1]);
  end;
end;

function DownFirInterpolate(Output: PSmallInt; Buffer: PLongInt; Coefficients: PSmallInt; FirOrder,
  FirFractions: Integer; MaximumIndexQ16, IndexIncrementQ16: LongInt): PSmallInt;
var
  IndexQ16, ResultQ6, InterpolationIndex: LongInt;
  Pointer: PLongInt;
  Coefficient: PSmallInt;
  Tap: Integer;
begin
  IndexQ16 := 0;
  while IndexQ16 < MaximumIndexQ16 do
  begin
    Pointer := Buffer + SarLongint(IndexQ16, 16);
    case FirOrder of
      DownOrderFir0:
        begin
          InterpolationIndex := SilkMulWB(IndexQ16 and $FFFF, FirFractions);
          Coefficient := Coefficients + (DownOrderFir0 div 2) * InterpolationIndex;
          ResultQ6 := SilkMulWB(Pointer[0], Coefficient[0]);
          for Tap := 1 to 8 do
            ResultQ6 := SilkMlaWB(ResultQ6, Pointer[Tap], Coefficient[Tap]);
          Coefficient := Coefficients + (DownOrderFir0 div 2) * (FirFractions - 1 - InterpolationIndex);
          for Tap := 0 to 8 do
            ResultQ6 := SilkMlaWB(ResultQ6, Pointer[17 - Tap], Coefficient[Tap]);
        end;
      DownOrderFir1:
        begin
          ResultQ6 := SilkMulWB(Pointer[0] + Pointer[23], Coefficients[0]);
          for Tap := 1 to 11 do
            ResultQ6 := SilkMlaWB(ResultQ6, Pointer[Tap] + Pointer[23 - Tap], Coefficients[Tap]);
        end;
    else
      begin
        ResultQ6 := SilkMulWB(Pointer[0] + Pointer[35], Coefficients[0]);
        for Tap := 1 to 17 do
          ResultQ6 := SilkMlaWB(ResultQ6, Pointer[Tap] + Pointer[35 - Tap], Coefficients[Tap]);
      end;
    end;
    Output^ := SmallInt(SilkSat16(SilkRShiftRound(ResultQ6, 6)));
    Inc(Output);
    Inc(IndexQ16, IndexIncrementQ16);
  end;
  Result := Output;
end;

procedure ResampleDownFir(var State: TSilkResamplerState; Output, Input: PSmallInt; InputLength: Integer);
var
  Buffer: array[0..160 + SilkResamplerMaximumFirOrder - 1] of LongInt;
  SamplesIn: Integer;
  MaximumIndexQ16: LongInt;
  FirCoefficients: PSmallInt;
begin
  Move(State.Fir32[0], Buffer[0], State.FirOrder * SizeOf(LongInt));
  FirCoefficients := State.Coefficients + 2;
  repeat
    SamplesIn := SilkMin(InputLength, State.BatchSize);
    SecondOrderAr(@State.Iir[0], @Buffer[State.FirOrder], Input, State.Coefficients, SamplesIn);
    MaximumIndexQ16 := SilkShl(SamplesIn, 16);
    Output := DownFirInterpolate(Output, @Buffer[0], FirCoefficients, State.FirOrder, State.FirFractions,
      MaximumIndexQ16, State.InverseRatioQ16);
    Inc(Input, SamplesIn);
    Dec(InputLength, SamplesIn);
    if InputLength > 1 then
      Move(Buffer[SamplesIn], Buffer[0], State.FirOrder * SizeOf(LongInt))
    else
      Break;
  until False;
  Move(Buffer[SamplesIn], State.Fir32[0], State.FirOrder * SizeOf(LongInt));
end;

procedure ResampleBlock(var State: TSilkResamplerState; Output, Input: PSmallInt; Length: Integer);
begin
  case State.Kind of
    rkUpTwo: UpTwoHighQuality(@State.Iir[0], Output, Input, Length);
    rkIirFir: ResampleIirFir(State, Output, Input, Length);
    rkDownFir: ResampleDownFir(State, Output, Input, Length);
  else
    Move(Input^, Output^, Length * SizeOf(SmallInt));
  end;
end;

procedure SilkResample(var State: TSilkResamplerState; Output, Input: PSmallInt; InputLength: Integer);
var
  SampleCount: Integer;
begin
  SampleCount := State.InputKHz - State.InputDelay;
  Move(Input^, State.DelayBuffer[State.InputDelay], SampleCount * SizeOf(SmallInt));
  ResampleBlock(State, Output, @State.DelayBuffer[0], State.InputKHz);
  ResampleBlock(State, Output + State.OutputKHz, Input + SampleCount, InputLength - State.InputKHz);
  Move(Input[InputLength - State.InputDelay], State.DelayBuffer[0], State.InputDelay * SizeOf(SmallInt));
end;

end.
