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
  CELT's bit allocation (RFC 6716 section 4.3.3): the band caps, the
  interpolation between allocation vectors with the trim tilt and the
  dynamic boosts, the band skipping, intensity and dual stereo flags,
  and the split between fine energy and PVQ bits; with the pulse cache
  lookups the band coder uses (bits to pulses and back).
}
unit Media.Opus.CeltRate;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

uses
  Media.Opus.RangeDecoder;

type
  TCeltBandInts = array[0..20] of Integer;

const
  CeltMaximumFineBits = 8;
  CeltFineOffset = 21;
  CeltQThetaOffset = 4;
  CeltQThetaOffsetTwoPhase = 16;

function CeltGetPulses(Index: Integer): Integer; inline;
function CeltBitsToPulses(Band, LM, Bits: Integer): Integer;
function CeltPulsesToBits(Band, LM, Pulses: Integer): Integer;
{ The pulse cache row of Band at LM (first entry: its largest index). }
function CeltCacheRow(Band, LM: Integer): PByte;
procedure CeltInitCaps(var Caps: TCeltBandInts; LM, Channels: Integer);
function CeltComputeAllocation(StartBand, EndBand: Integer; const Offsets, Caps: TCeltBandInts;
  AllocationTrim: Integer; out Intensity, DualStereo: Integer; Total: Integer; out Balance: Integer;
  out Pulses, FineBits, FinePriority: TCeltBandInts; Channels, LM: Integer;
  Decoder: TOpusRangeDecoder): Integer;

implementation

uses
  Media.Opus.CeltTables;

const
  AllocationSteps = 6;
  LogMaximumPseudo = 6;

function CeltGetPulses(Index: Integer): Integer;
begin
  if Index < 8 then
    Result := Index
  else
    Result := (8 + (Index and 7)) shl ((Index shr 3) - 1);
end;

function CeltCacheRow(Band, LM: Integer): PByte;
begin
  Result := @CeltCacheBits[CeltCacheIndex[(LM + 1) * CeltBandCount + Band]];
end;

function CeltBitsToPulses(Band, LM, Bits: Integer): Integer;
var
  Cache: PByte;
  Low, High, Middle, Index, LowBits: Integer;
begin
  Cache := CeltCacheRow(Band, LM);
  Low := 0;
  High := Cache[0];
  Dec(Bits);
  for Index := 0 to LogMaximumPseudo - 1 do
  begin
    Middle := (Low + High + 1) shr 1;
    if Integer(Cache[Middle]) >= Bits then
      High := Middle
    else
      Low := Middle;
  end;
  if Low = 0 then
    LowBits := -1
  else
    LowBits := Cache[Low];
  if Bits - LowBits <= Integer(Cache[High]) - Bits then
    Result := Low
  else
    Result := High;
end;

function CeltPulsesToBits(Band, LM, Pulses: Integer): Integer;
begin
  if Pulses = 0 then
    Result := 0
  else
    Result := CeltCacheRow(Band, LM)[Pulses] + 1;
end;

procedure CeltInitCaps(var Caps: TCeltBandInts; LM, Channels: Integer);
var
  Band, Width: Integer;
begin
  for Band := 0 to CeltBandCount - 1 do
  begin
    Width := (CeltBandEdges[Band + 1] - CeltBandEdges[Band]) shl LM;
    Caps[Band] := ((CeltCacheCaps[CeltBandCount * (2 * LM + Channels - 1) + Band] + 64) * Channels * Width) shr 2;
  end;
end;

function Imin(A, B: Integer): Integer; inline;
begin
  if A < B then
    Result := A
  else
    Result := B;
end;

function Imax(A, B: Integer): Integer; inline;
begin
  if A > B then
    Result := A
  else
    Result := B;
end;

function InterpolateBitsToPulses(StartBand, EndBand, SkipStart: Integer; const Bits1, Bits2, Thresholds,
  Caps: TCeltBandInts; Total: Integer; out Balance: Integer; SkipReserve: Integer; out Intensity: Integer;
  IntensityReserve: Integer; out DualStereo: Integer; DualStereoReserve: Integer; out Bits, FineBits,
  FinePriority: TCeltBandInts; Channels, LM: Integer; Decoder: TOpusRangeDecoder): Integer;
var
  Sum, Low, High, Index, J, LogM, Stereo, CodedBands, AllocationFloor: Integer;
  Left, PerCoefficient, Middle, Value, BandWidth, BandBits, Remainder: Integer;
  Done: Boolean;
  N0, N, Denominator, Offset, NClogN, Excess, Bit, ExtraFine, ExtraBits, CurrentBalance: Integer;
begin
  AllocationFloor := Channels shl BitResolution;
  if Channels > 1 then
    Stereo := 1
  else
    Stereo := 0;
  LogM := LM shl BitResolution;
  Low := 0;
  High := 1 shl AllocationSteps;
  for Index := 0 to AllocationSteps - 1 do
  begin
    Middle := (Low + High) shr 1;
    Sum := 0;
    Done := False;
    J := EndBand;
    while J > StartBand do
    begin
      Dec(J);
      Value := Bits1[J] + ((Middle * Bits2[J]) shr AllocationSteps);
      if (Value >= Thresholds[J]) or Done then
      begin
        Done := True;
        Inc(Sum, Imin(Value, Caps[J]));
      end
      else if Value >= AllocationFloor then
        Inc(Sum, AllocationFloor);
    end;
    if Sum > Total then
      High := Middle
    else
      Low := Middle;
  end;
  Sum := 0;
  Done := False;
  J := EndBand;
  while J > StartBand do
  begin
    Dec(J);
    Value := Bits1[J] + ((Low * Bits2[J]) shr AllocationSteps);
    if (Value < Thresholds[J]) and not Done then
    begin
      if Value >= AllocationFloor then
        Value := AllocationFloor
      else
        Value := 0;
    end
    else
      Done := True;
    Value := Imin(Value, Caps[J]);
    Bits[J] := Value;
    Inc(Sum, Value);
  end;
  { Band skipping, from the end. }
  CodedBands := EndBand;
  while True do
  begin
    J := CodedBands - 1;
    if J <= SkipStart then
    begin
      Inc(Total, SkipReserve);
      Break;
    end;
    Left := Total - Sum;
    PerCoefficient := Left div (CeltBandEdges[CodedBands] - CeltBandEdges[StartBand]);
    Dec(Left, (CeltBandEdges[CodedBands] - CeltBandEdges[StartBand]) * PerCoefficient);
    Remainder := Imax(Left - (CeltBandEdges[J] - CeltBandEdges[StartBand]), 0);
    BandWidth := CeltBandEdges[CodedBands] - CeltBandEdges[J];
    BandBits := Bits[J] + PerCoefficient * BandWidth + Remainder;
    if BandBits >= Imax(Thresholds[J], AllocationFloor + (1 shl BitResolution)) then
    begin
      if Decoder.DecodeBitLogP(1) then
        Break;
      Inc(Sum, 1 shl BitResolution);
      Dec(BandBits, 1 shl BitResolution);
    end;
    Dec(Sum, Bits[J] + IntensityReserve);
    if IntensityReserve > 0 then
      IntensityReserve := CeltLog2FractionTable[J - StartBand];
    Inc(Sum, IntensityReserve);
    if BandBits >= AllocationFloor then
    begin
      Inc(Sum, AllocationFloor);
      Bits[J] := AllocationFloor;
    end
    else
      Bits[J] := 0;
    Dec(CodedBands);
  end;
  if IntensityReserve > 0 then
    Intensity := StartBand + Integer(Decoder.DecodeUInt(CodedBands + 1 - StartBand))
  else
    Intensity := 0;
  if Intensity <= StartBand then
  begin
    Inc(Total, DualStereoReserve);
    DualStereoReserve := 0;
  end;
  if DualStereoReserve > 0 then
    DualStereo := Ord(Decoder.DecodeBitLogP(1))
  else
    DualStereo := 0;
  Left := Total - Sum;
  PerCoefficient := Left div (CeltBandEdges[CodedBands] - CeltBandEdges[StartBand]);
  Dec(Left, (CeltBandEdges[CodedBands] - CeltBandEdges[StartBand]) * PerCoefficient);
  for J := StartBand to CodedBands - 1 do
    Inc(Bits[J], PerCoefficient * (CeltBandEdges[J + 1] - CeltBandEdges[J]));
  for J := StartBand to CodedBands - 1 do
  begin
    Value := Imin(Left, CeltBandEdges[J + 1] - CeltBandEdges[J]);
    Inc(Bits[J], Value);
    Dec(Left, Value);
  end;
  CurrentBalance := 0;
  J := StartBand;
  while J < CodedBands do
  begin
    N0 := CeltBandEdges[J + 1] - CeltBandEdges[J];
    N := N0 shl LM;
    Bit := Bits[J] + CurrentBalance;
    if N > 1 then
    begin
      Excess := Imax(Bit - Caps[J], 0);
      Bits[J] := Bit - Excess;
      Denominator := Channels * N;
      if (Channels = 2) and (N > 2) and (DualStereo = 0) and (J < Intensity) then
        Inc(Denominator);
      NClogN := Denominator * (CeltLogN[J] + LogM);
      Offset := SarLongint(NClogN, 1) - Denominator * CeltFineOffset;
      if N = 2 then
        Inc(Offset, (Denominator shl BitResolution) shr 2);
      if Bits[J] + Offset < (Denominator * 2) shl BitResolution then
        Inc(Offset, SarLongint(NClogN, 2))
      else if Bits[J] + Offset < (Denominator * 3) shl BitResolution then
        Inc(Offset, SarLongint(NClogN, 3));
      FineBits[J] := Imax(0, Bits[J] + Offset + (Denominator shl (BitResolution - 1)));
      FineBits[J] := (FineBits[J] div Denominator) shr BitResolution;
      if Channels * FineBits[J] > SarLongint(Bits[J], BitResolution) then
        FineBits[J] := SarLongint(SarLongint(Bits[J], Stereo), BitResolution);
      FineBits[J] := Imin(FineBits[J], CeltMaximumFineBits);
      FinePriority[J] := Ord(FineBits[J] * (Denominator shl BitResolution) >= Bits[J] + Offset);
      Dec(Bits[J], (Channels * FineBits[J]) shl BitResolution);
    end
    else
    begin
      Excess := Imax(0, Bit - (Channels shl BitResolution));
      Bits[J] := Bit - Excess;
      FineBits[J] := 0;
      FinePriority[J] := 1;
    end;
    if Excess > 0 then
    begin
      ExtraFine := Imin(SarLongint(Excess, Stereo + BitResolution), CeltMaximumFineBits - FineBits[J]);
      Inc(FineBits[J], ExtraFine);
      ExtraBits := (ExtraFine * Channels) shl BitResolution;
      FinePriority[J] := Ord(ExtraBits >= Excess - CurrentBalance);
      Dec(Excess, ExtraBits);
    end;
    CurrentBalance := Excess;
    Inc(J);
  end;
  Balance := CurrentBalance;
  while J < EndBand do
  begin
    FineBits[J] := SarLongint(SarLongint(Bits[J], Stereo), BitResolution);
    Bits[J] := 0;
    FinePriority[J] := Ord(FineBits[J] < 1);
    Inc(J);
  end;
  Result := CodedBands;
end;

function CeltComputeAllocation(StartBand, EndBand: Integer; const Offsets, Caps: TCeltBandInts;
  AllocationTrim: Integer; out Intensity, DualStereo: Integer; Total: Integer; out Balance: Integer;
  out Pulses, FineBits, FinePriority: TCeltBandInts; Channels, LM: Integer;
  Decoder: TOpusRangeDecoder): Integer;
var
  Low, High, J, SkipStart, SkipReserve, IntensityReserve, DualStereoReserve: Integer;
  Bits1, Bits2, Thresholds, TrimOffsets: TCeltBandInts;
  Done: Boolean;
  Sum, Middle, BitsJ, N, Bits1J, Bits2J: Integer;
begin
  FillChar(Pulses, SizeOf(Pulses), 0);
  FillChar(FineBits, SizeOf(FineBits), 0);
  FillChar(FinePriority, SizeOf(FinePriority), 0);
  FillChar(Bits1, SizeOf(Bits1), 0);
  FillChar(Bits2, SizeOf(Bits2), 0);
  FillChar(Thresholds, SizeOf(Thresholds), 0);
  FillChar(TrimOffsets, SizeOf(TrimOffsets), 0);
  Total := Imax(Total, 0);
  SkipStart := StartBand;
  if Total >= 1 shl BitResolution then
    SkipReserve := 1 shl BitResolution
  else
    SkipReserve := 0;
  Dec(Total, SkipReserve);
  IntensityReserve := 0;
  DualStereoReserve := 0;
  if Channels = 2 then
  begin
    IntensityReserve := CeltLog2FractionTable[EndBand - StartBand];
    if IntensityReserve > Total then
      IntensityReserve := 0
    else
    begin
      Dec(Total, IntensityReserve);
      if Total >= 1 shl BitResolution then
        DualStereoReserve := 1 shl BitResolution;
      Dec(Total, DualStereoReserve);
    end;
  end;
  for J := StartBand to EndBand - 1 do
  begin
    Thresholds[J] := Imax(Channels shl BitResolution,
      ((3 * (CeltBandEdges[J + 1] - CeltBandEdges[J])) shl LM shl BitResolution) shr 4);
    TrimOffsets[J] := SarLongint(Channels * (CeltBandEdges[J + 1] - CeltBandEdges[J]) * (AllocationTrim - 5 - LM) *
      (EndBand - J - 1) * (1 shl (LM + BitResolution)), 6);
    if (CeltBandEdges[J + 1] - CeltBandEdges[J]) shl LM = 1 then
      Dec(TrimOffsets[J], Channels shl BitResolution);
  end;
  Low := 1;
  High := CeltAllocationVectorCount - 1;
  repeat
    Done := False;
    Sum := 0;
    Middle := (Low + High) shr 1;
    J := EndBand;
    while J > StartBand do
    begin
      Dec(J);
      N := CeltBandEdges[J + 1] - CeltBandEdges[J];
      BitsJ := ((Channels * N * CeltBandAllocation[Middle * CeltBandCount + J]) shl LM) shr 2;
      if BitsJ > 0 then
        BitsJ := Imax(0, BitsJ + TrimOffsets[J]);
      Inc(BitsJ, Offsets[J]);
      if (BitsJ >= Thresholds[J]) or Done then
      begin
        Done := True;
        Inc(Sum, Imin(BitsJ, Caps[J]));
      end
      else if BitsJ >= Channels shl BitResolution then
        Inc(Sum, Channels shl BitResolution);
    end;
    if Sum > Total then
      High := Middle - 1
    else
      Low := Middle + 1;
  until Low > High;
  High := Low;
  Dec(Low);
  for J := StartBand to EndBand - 1 do
  begin
    N := CeltBandEdges[J + 1] - CeltBandEdges[J];
    Bits1J := ((Channels * N * CeltBandAllocation[Low * CeltBandCount + J]) shl LM) shr 2;
    if High >= CeltAllocationVectorCount then
      Bits2J := Caps[J]
    else
      Bits2J := ((Channels * N * CeltBandAllocation[High * CeltBandCount + J]) shl LM) shr 2;
    if Bits1J > 0 then
      Bits1J := Imax(0, Bits1J + TrimOffsets[J]);
    if Bits2J > 0 then
      Bits2J := Imax(0, Bits2J + TrimOffsets[J]);
    if Low > 0 then
      Inc(Bits1J, Offsets[J]);
    Inc(Bits2J, Offsets[J]);
    if Offsets[J] > 0 then
      SkipStart := J;
    Bits2J := Imax(0, Bits2J - Bits1J);
    Bits1[J] := Bits1J;
    Bits2[J] := Bits2J;
  end;
  Result := InterpolateBitsToPulses(StartBand, EndBand, SkipStart, Bits1, Bits2, Thresholds, Caps, Total, Balance,
    SkipReserve, Intensity, IntensityReserve, DualStereo, DualStereoReserve, Pulses, FineBits, FinePriority,
    Channels, LM, Decoder);
end;

end.
