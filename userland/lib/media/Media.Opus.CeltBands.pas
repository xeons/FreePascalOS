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
  CELT's band shapes (RFC 6716 section 4.3.4): every band's normalised
  spectrum decoded with its share of the bits, by recursive splitting
  (the theta angle between halves, or between mid and side in stereo),
  PVQ, or folding from lower bands when there are no pulses; the
  time-frequency resolution changes (Haar transforms, Hadamard
  interleaving), anti-collapse noise for short blocks, and the bands
  scaled back to their energies.
}
unit Media.Opus.CeltBands;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

uses
  Media.Opus.RangeDecoder,
  Media.Opus.CeltRate;

type
  TCeltCollapseMasks = array[0..41] of Byte;

{ Decodes all bands' shapes into X (and Y for stereo, else nil). }
procedure CeltDecodeAllBands(StartBand, EndBand: Integer; X, Y: PSingle; var CollapseMasks: TCeltCollapseMasks;
  const Pulses: TCeltBandInts; ShortBlocks: Boolean; Spread, DualStereo, Intensity: Integer;
  const TfResolution: TCeltBandInts; TotalBits, Balance: Integer; Decoder: TOpusRangeDecoder; LM,
  CodedBands: Integer; var Seed: LongWord; DisableInversion: Boolean);
procedure CeltAntiCollapse(X: PSingle; const CollapseMasks: TCeltCollapseMasks; LM, Channels, Size,
  StartBand, EndBand: Integer; LogEnergies, Previous1, Previous2: PSingle; const Pulses: TCeltBandInts;
  Seed: LongWord);
{ Scales the normalised bands of X by their energies into Frequencies. }
procedure CeltDenormaliseBands(X, Frequencies, LogEnergies: PSingle; StartBand, EndBand, M, Downsample: Integer;
  Silence: Boolean);
function CeltRandom(Seed: LongWord): LongWord; inline;

implementation

uses
  Math,
  Media.Opus.CeltTables,
  Media.Opus.CeltVectors;

type
  TBandContext = record
    BandIndex: Integer;
    Intensity: Integer;
    Spread: Integer;
    TfChange: Integer;
    Decoder: TOpusRangeDecoder;
    RemainingBits: Integer;
    Seed: LongWord;
    DisableInversion: Boolean;
    AvoidSplitNoise: Boolean;
  end;

  TSplitContext = record
    Inverted: Boolean;
    IMid, ISide, Delta, ITheta, QAllocation: Integer;
  end;

const
  OrderTable: array[0..29] of Integer = (
    1, 0,
    3, 0, 2, 1,
    7, 0, 4, 3, 6, 1, 5, 2,
    15, 0, 8, 7, 12, 3, 11, 4, 14, 1, 9, 6, 13, 2, 10, 5);
  BitInterleaveTable: array[0..15] of Byte = (0, 1, 1, 1, 2, 3, 3, 3, 2, 3, 3, 3, 2, 3, 3, 3);
  BitDeinterleaveTable: array[0..15] of Byte = ($00, $03, $0C, $0F, $30, $33, $3C, $3F, $C0, $C3, $CC, $CF,
    $F0, $F3, $FC, $FF);
  MaximumBandSize = 176;

{$push}
{$R-}
{$Q-}
function CeltRandom(Seed: LongWord): LongWord;
begin
  Result := LongWord(1664525) * Seed + LongWord(1013904223);
end;
{$pop}

function FracMul16(A, B: Integer): Integer; inline;
begin
  Result := SarLongint(16384 + LongInt(SmallInt(A)) * LongInt(SmallInt(B)), 15);
end;

function BitExactCos(X: Integer): Integer;
var
  Temp, X2: Integer;
begin
  Temp := SarLongint(4096 + X * X, 13);
  X2 := Temp;
  X2 := (32767 - X2) + FracMul16(X2, -7651 + FracMul16(X2, 8277 + FracMul16(-626, X2)));
  Result := 1 + X2;
end;

function BitExactLog2Tan(ISin, ICos: Integer): Integer;
var
  LogCos, LogSin: Integer;
begin
  LogCos := IntegerLog(ICos);
  LogSin := IntegerLog(ISin);
  ICos := ICos shl (15 - LogCos);
  ISin := ISin shl (15 - LogSin);
  Result := (LogSin - LogCos) * (1 shl 11) + FracMul16(ISin, FracMul16(ISin, -2597) + 7932)
    - FracMul16(ICos, FracMul16(ICos, -2597) + 7932);
end;

function IntegerSqrt32(Value: LongWord): LongWord;
var
  Bit, Guess, Trial: LongWord;
  Shift: Integer;
begin
  Guess := 0;
  Shift := (IntegerLog(Value) - 1) shr 1;
  Bit := LongWord(1) shl Shift;
  repeat
    Trial := ((Guess shl 1) + Bit) shl Shift;
    if Trial <= Value then
    begin
      Inc(Guess, Bit);
      Dec(Value, Trial);
    end;
    Bit := Bit shr 1;
    Dec(Shift);
  until Shift < 0;
  Result := Guess;
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

procedure DeinterleaveHadamard(X: PSingle; N0, Stride: Integer; Hadamard: Boolean);
var
  Temp: array[0..MaximumBandSize - 1] of Single;
  Index, J: Integer;
begin
  if Hadamard then
  begin
    for Index := 0 to Stride - 1 do
      for J := 0 to N0 - 1 do
        Temp[OrderTable[Stride - 2 + Index] * N0 + J] := X[J * Stride + Index];
  end
  else
    for Index := 0 to Stride - 1 do
      for J := 0 to N0 - 1 do
        Temp[Index * N0 + J] := X[J * Stride + Index];
  Move(Temp[0], X^, N0 * Stride * SizeOf(Single));
end;

procedure InterleaveHadamard(X: PSingle; N0, Stride: Integer; Hadamard: Boolean);
var
  Temp: array[0..MaximumBandSize - 1] of Single;
  Index, J: Integer;
begin
  if Hadamard then
  begin
    for Index := 0 to Stride - 1 do
      for J := 0 to N0 - 1 do
        Temp[J * Stride + Index] := X[OrderTable[Stride - 2 + Index] * N0 + J];
  end
  else
    for Index := 0 to Stride - 1 do
      for J := 0 to N0 - 1 do
        Temp[J * Stride + Index] := X[Index * N0 + J];
  Move(Temp[0], X^, N0 * Stride * SizeOf(Single));
end;

procedure Haar1(X: PSingle; N0, Stride: Integer);
var
  Index, J: Integer;
  T1, T2: Single;
begin
  N0 := N0 shr 1;
  for Index := 0 to Stride - 1 do
    for J := 0 to N0 - 1 do
    begin
      T1 := 0.70710678 * X[Stride * 2 * J + Index];
      T2 := 0.70710678 * X[Stride * (2 * J + 1) + Index];
      X[Stride * 2 * J + Index] := T1 + T2;
      X[Stride * (2 * J + 1) + Index] := T1 - T2;
    end;
end;

function ComputeQn(N, B, Offset, PulseCap: Integer; Stereo: Boolean): Integer;
const
  Exp2Table8: array[0..7] of Integer = (16384, 17866, 19483, 21247, 23170, 25267, 27554, 30048);
var
  N2, QB: Integer;
begin
  N2 := 2 * N - 1;
  if Stereo and (N = 2) then
    Dec(N2);
  QB := (B + N2 * Offset) div N2;
  QB := Imin(B - PulseCap - (4 shl BitResolution), QB);
  QB := Imin(8 shl BitResolution, QB);
  if QB < ((1 shl BitResolution) shr 1) then
    Result := 1
  else
  begin
    Result := Exp2Table8[QB and 7] shr (14 - (QB shr BitResolution));
    Result := ((Result + 1) shr 1) shl 1;
  end;
end;

procedure StereoMerge(X, Y: PSingle; Mid: Single; N: Integer);
var
  Index: Integer;
  CrossProduct, Side, LeftEnergy, RightEnergy, LeftGain, RightGain, Left, Right: Single;
begin
  CrossProduct := 0;
  Side := 0;
  for Index := 0 to N - 1 do
  begin
    CrossProduct := CrossProduct + Y[Index] * X[Index];
    Side := Side + Y[Index] * Y[Index];
  end;
  CrossProduct := Mid * CrossProduct;
  LeftEnergy := Mid * Mid + Side - 2 * CrossProduct;
  RightEnergy := Mid * Mid + Side + 2 * CrossProduct;
  if (RightEnergy < 6e-4) or (LeftEnergy < 6e-4) then
  begin
    Move(X^, Y^, N * SizeOf(Single));
    Exit;
  end;
  LeftGain := 1 / Sqrt(LeftEnergy);
  RightGain := 1 / Sqrt(RightEnergy);
  for Index := 0 to N - 1 do
  begin
    Left := Mid * X[Index];
    Right := Y[Index];
    X[Index] := LeftGain * (Left - Right);
    Y[Index] := RightGain * (Left + Right);
  end;
end;

procedure ComputeTheta(var Context: TBandContext; out Split: TSplitContext; N: Integer; var B: Integer;
  BlockCount, BlockCount0, LM: Integer; Stereo: Boolean; var Fill: Integer);
var
  Qn, ITheta, Delta, IMid, ISide, QAllocation, PulseCap, Offset: Integer;
  Tell: LongWord;
  Inverted: Boolean;
  P0, XValue, X0, Total, Symbol, Low, Frequency, Middle: Integer;
  Decoder: TOpusRangeDecoder;
begin
  Decoder := Context.Decoder;
  ITheta := 0;
  Inverted := False;
  PulseCap := CeltLogN[Context.BandIndex] + LM * (1 shl BitResolution);
  if Stereo and (N = 2) then
    Offset := (PulseCap shr 1) - CeltQThetaOffsetTwoPhase
  else
    Offset := (PulseCap shr 1) - CeltQThetaOffset;
  Qn := ComputeQn(N, B, Offset, PulseCap, Stereo);
  if Stereo and (Context.BandIndex >= Context.Intensity) then
    Qn := 1;
  Tell := Decoder.TellFraction;
  if Qn <> 1 then
  begin
    if Stereo and (N > 2) then
    begin
      P0 := 3;
      X0 := Qn div 2;
      Total := P0 * (X0 + 1) + X0;
      Symbol := Decoder.Decode(Total);
      if Symbol < (X0 + 1) * P0 then
        XValue := Symbol div P0
      else
        XValue := X0 + 1 + (Symbol - (X0 + 1) * P0);
      if XValue <= X0 then
        Decoder.Update(P0 * XValue, P0 * (XValue + 1), Total)
      else
        Decoder.Update((XValue - 1 - X0) + (X0 + 1) * P0, (XValue - X0) + (X0 + 1) * P0, Total);
      ITheta := XValue;
    end
    else if (BlockCount0 > 1) or Stereo then
      ITheta := Decoder.DecodeUInt(Qn + 1)
    else
    begin
      Total := ((Qn shr 1) + 1) * ((Qn shr 1) + 1);
      Middle := Decoder.Decode(Total);
      if Middle < (((Qn shr 1) * ((Qn shr 1) + 1)) shr 1) then
      begin
        ITheta := (Integer(IntegerSqrt32(8 * LongWord(Middle) + 1)) - 1) shr 1;
        Frequency := ITheta + 1;
        Low := (ITheta * (ITheta + 1)) shr 1;
      end
      else
      begin
        ITheta := (2 * (Qn + 1) - Integer(IntegerSqrt32(8 * LongWord(Total - Middle - 1) + 1))) shr 1;
        Frequency := Qn + 1 - ITheta;
        Low := Total - (((Qn + 1 - ITheta) * (Qn + 2 - ITheta)) shr 1);
      end;
      Decoder.Update(Low, Low + Frequency, Total);
    end;
    ITheta := (ITheta * 16384) div Qn;
  end
  else if Stereo then
  begin
    if (B > 2 shl BitResolution) and (Context.RemainingBits > 2 shl BitResolution) then
      Inverted := Decoder.DecodeBitLogP(2)
    else
      Inverted := False;
    if Context.DisableInversion then
      Inverted := False;
    ITheta := 0;
  end;
  QAllocation := Integer(Decoder.TellFraction - Tell);
  Dec(B, QAllocation);
  if ITheta = 0 then
  begin
    IMid := 32767;
    ISide := 0;
    Fill := Fill and ((1 shl BlockCount) - 1);
    Delta := -16384;
  end
  else if ITheta = 16384 then
  begin
    IMid := 0;
    ISide := 32767;
    Fill := Fill and (((1 shl BlockCount) - 1) shl BlockCount);
    Delta := 16384;
  end
  else
  begin
    IMid := BitExactCos(ITheta);
    ISide := BitExactCos(16384 - ITheta);
    Delta := FracMul16((N - 1) shl 7, BitExactLog2Tan(ISide, IMid));
  end;
  Split.Inverted := Inverted;
  Split.IMid := IMid;
  Split.ISide := ISide;
  Split.Delta := Delta;
  Split.ITheta := ITheta;
  Split.QAllocation := QAllocation;
end;

function DecodeBandN1(var Context: TBandContext; X, Y, LowbandOut: PSingle): LongWord;
var
  Channel, ChannelCount: Integer;
  Target: PSingle;
  Sign: LongWord;
begin
  if Y <> nil then
    ChannelCount := 2
  else
    ChannelCount := 1;
  Target := X;
  for Channel := 0 to ChannelCount - 1 do
  begin
    Sign := 0;
    if Context.RemainingBits >= 1 shl BitResolution then
    begin
      Sign := Context.Decoder.DecodeBits(1);
      Dec(Context.RemainingBits, 1 shl BitResolution);
    end;
    if Sign <> 0 then
      Target[0] := -1
    else
      Target[0] := 1;
    Target := Y;
  end;
  if LowbandOut <> nil then
    LowbandOut[0] := X[0];
  Result := 1;
end;

function DecodePartition(var Context: TBandContext; X: PSingle; N, B, BlockCount: Integer; Lowband: PSingle;
  LM: Integer; Gain: Single; Fill: Integer): LongWord;
var
  Cache: PByte;
  Q, CurrentBits, MBits, SBits, Delta, ITheta, QAllocation, BlockCount0, J: Integer;
  Mid, Side, Value: Single;
  CollapseMask, Mask: LongWord;
  Y, NextLowband2: PSingle;
  Split: TSplitContext;
  Rebalance: Integer;
begin
  BlockCount0 := BlockCount;
  CollapseMask := 0;
  Cache := CeltCacheRow(Context.BandIndex, LM);
  if (LM <> -1) and (B > Cache[Cache[0]] + 12) and (N > 2) then
  begin
    NextLowband2 := nil;
    N := N shr 1;
    Y := X + N;
    Dec(LM);
    if BlockCount = 1 then
      Fill := (Fill and 1) or (Fill shl 1);
    BlockCount := (BlockCount + 1) shr 1;
    ComputeTheta(Context, Split, N, B, BlockCount, BlockCount0, LM, False, Fill);
    Delta := Split.Delta;
    ITheta := Split.ITheta;
    QAllocation := Split.QAllocation;
    Mid := (1 / 32768) * Split.IMid;
    Side := (1 / 32768) * Split.ISide;
    if (BlockCount0 > 1) and ((ITheta and $3FFF) <> 0) then
    begin
      if ITheta > 8192 then
        Dec(Delta, SarLongint(Delta, 4 - LM))
      else
        Delta := Imin(0, Delta + ((N shl BitResolution) shr (5 - LM)));
    end;
    MBits := Imax(0, Imin(B, (B - Delta) div 2));
    SBits := B - MBits;
    Dec(Context.RemainingBits, QAllocation);
    if Lowband <> nil then
      NextLowband2 := Lowband + N;
    Rebalance := Context.RemainingBits;
    if MBits >= SBits then
    begin
      CollapseMask := DecodePartition(Context, X, N, MBits, BlockCount, Lowband, LM, Gain * Mid, Fill);
      Rebalance := MBits - (Rebalance - Context.RemainingBits);
      if (Rebalance > 3 shl BitResolution) and (ITheta <> 0) then
        Inc(SBits, Rebalance - (3 shl BitResolution));
      CollapseMask := CollapseMask or (DecodePartition(Context, Y, N, SBits, BlockCount, NextLowband2, LM,
        Gain * Side, Fill shr BlockCount) shl (BlockCount0 shr 1));
    end
    else
    begin
      CollapseMask := DecodePartition(Context, Y, N, SBits, BlockCount, NextLowband2, LM, Gain * Side,
        Fill shr BlockCount) shl (BlockCount0 shr 1);
      Rebalance := SBits - (Rebalance - Context.RemainingBits);
      if (Rebalance > 3 shl BitResolution) and (ITheta <> 16384) then
        Inc(MBits, Rebalance - (3 shl BitResolution));
      CollapseMask := CollapseMask or DecodePartition(Context, X, N, MBits, BlockCount, Lowband, LM, Gain * Mid, Fill);
    end;
  end
  else
  begin
    Q := CeltBitsToPulses(Context.BandIndex, LM, B);
    CurrentBits := CeltPulsesToBits(Context.BandIndex, LM, Q);
    Dec(Context.RemainingBits, CurrentBits);
    while (Context.RemainingBits < 0) and (Q > 0) do
    begin
      Inc(Context.RemainingBits, CurrentBits);
      Dec(Q);
      CurrentBits := CeltPulsesToBits(Context.BandIndex, LM, Q);
      Dec(Context.RemainingBits, CurrentBits);
    end;
    if Q <> 0 then
      CollapseMask := CeltDecodeVector(X, N, CeltGetPulses(Q), Context.Spread, BlockCount, Context.Decoder, Gain)
    else
    begin
      Mask := (LongWord(1) shl BlockCount) - 1;
      Fill := Fill and Integer(Mask);
      if Fill = 0 then
        FillChar(X^, N * SizeOf(Single), 0)
      else
      begin
        if Lowband = nil then
        begin
          for J := 0 to N - 1 do
          begin
            Context.Seed := CeltRandom(Context.Seed);
            X[J] := SarLongint(LongInt(Context.Seed), 20);
          end;
          CollapseMask := Mask;
        end
        else
        begin
          for J := 0 to N - 1 do
          begin
            Context.Seed := CeltRandom(Context.Seed);
            if (Context.Seed and $8000) <> 0 then
              Value := 1 / 256
            else
              Value := -1 / 256;
            X[J] := Lowband[J] + Value;
          end;
          CollapseMask := LongWord(Fill);
        end;
        CeltRenormaliseVector(X, N, Gain);
      end;
    end;
  end;
  Result := CollapseMask;
end;

function DecodeBand(var Context: TBandContext; X: PSingle; N, B, BlockCount: Integer; Lowband: PSingle;
  LM: Integer; LowbandOut: PSingle; Gain: Single; LowbandScratch: PSingle; Fill: Integer): LongWord;
var
  N0, NB, NB0, BlockCount0, TimeDivide, Recombine, K, TfChange, J: Integer;
  LongBlocks: Boolean;
  CollapseMask: LongWord;
  Scale: Single;
begin
  N0 := N;
  BlockCount0 := BlockCount;
  TimeDivide := 0;
  Recombine := 0;
  TfChange := Context.TfChange;
  LongBlocks := BlockCount0 = 1;
  NB := N div BlockCount;
  if N = 1 then
    Exit(DecodeBandN1(Context, X, nil, LowbandOut));
  if TfChange > 0 then
    Recombine := TfChange;
  if (LowbandScratch <> nil) and (Lowband <> nil) and ((Recombine <> 0) or (((NB and 1) = 0) and (TfChange < 0))
    or (BlockCount0 > 1)) then
  begin
    Move(Lowband^, LowbandScratch^, N * SizeOf(Single));
    Lowband := LowbandScratch;
  end;
  for K := 0 to Recombine - 1 do
  begin
    if Lowband <> nil then
      Haar1(Lowband, N shr K, 1 shl K);
    Fill := BitInterleaveTable[Fill and $F] or (BitInterleaveTable[Fill shr 4] shl 2);
  end;
  BlockCount := BlockCount shr Recombine;
  NB := NB shl Recombine;
  while ((NB and 1) = 0) and (TfChange < 0) do
  begin
    if Lowband <> nil then
      Haar1(Lowband, NB, BlockCount);
    Fill := Fill or (Fill shl BlockCount);
    BlockCount := BlockCount shl 1;
    NB := NB shr 1;
    Inc(TimeDivide);
    Inc(TfChange);
  end;
  BlockCount0 := BlockCount;
  NB0 := NB;
  if (BlockCount0 > 1) and (Lowband <> nil) then
    DeinterleaveHadamard(Lowband, NB shr Recombine, BlockCount0 shl Recombine, LongBlocks);
  CollapseMask := DecodePartition(Context, X, N, B, BlockCount, Lowband, LM, Gain, Fill);
  if BlockCount0 > 1 then
    InterleaveHadamard(X, NB shr Recombine, BlockCount0 shl Recombine, LongBlocks);
  NB := NB0;
  BlockCount := BlockCount0;
  for K := 0 to TimeDivide - 1 do
  begin
    BlockCount := BlockCount shr 1;
    NB := NB shl 1;
    CollapseMask := CollapseMask or (CollapseMask shr BlockCount);
    Haar1(X, NB, BlockCount);
  end;
  for K := 0 to Recombine - 1 do
  begin
    CollapseMask := BitDeinterleaveTable[CollapseMask];
    Haar1(X, N0 shr K, 1 shl K);
  end;
  BlockCount := BlockCount shl Recombine;
  if LowbandOut <> nil then
  begin
    Scale := Sqrt(N0);
    for J := 0 to N0 - 1 do
      LowbandOut[J] := Scale * X[J];
  end;
  CollapseMask := CollapseMask and ((LongWord(1) shl BlockCount) - 1);
  Result := CollapseMask;
end;

function DecodeBandStereo(var Context: TBandContext; X, Y: PSingle; N, B, BlockCount: Integer; Lowband: PSingle;
  LM: Integer; LowbandOut, LowbandScratch: PSingle; Fill: Integer): LongWord;
var
  Mid, Side, Temp: Single;
  CollapseMask: LongWord;
  MBits, SBits, Delta, ITheta, QAllocation, OriginalFill, Sign, Rebalance, J: Integer;
  Split: TSplitContext;
  Inverted, SwapChannels: Boolean;
  X2, Y2: PSingle;
begin
  if N = 1 then
    Exit(DecodeBandN1(Context, X, Y, LowbandOut));
  OriginalFill := Fill;
  ComputeTheta(Context, Split, N, B, BlockCount, BlockCount, LM, True, Fill);
  Inverted := Split.Inverted;
  Delta := Split.Delta;
  ITheta := Split.ITheta;
  QAllocation := Split.QAllocation;
  Mid := (1 / 32768) * Split.IMid;
  Side := (1 / 32768) * Split.ISide;
  if N = 2 then
  begin
    MBits := B;
    SBits := 0;
    if (ITheta <> 0) and (ITheta <> 16384) then
      SBits := 1 shl BitResolution;
    Dec(MBits, SBits);
    SwapChannels := ITheta > 8192;
    Dec(Context.RemainingBits, QAllocation + SBits);
    if SwapChannels then
    begin
      X2 := Y;
      Y2 := X;
    end
    else
    begin
      X2 := X;
      Y2 := Y;
    end;
    Sign := 0;
    if SBits <> 0 then
      Sign := Context.Decoder.DecodeBits(1);
    Sign := 1 - 2 * Sign;
    CollapseMask := DecodeBand(Context, X2, N, MBits, BlockCount, Lowband, LM, LowbandOut, 1, LowbandScratch,
      OriginalFill);
    Y2[0] := -Sign * X2[1];
    Y2[1] := Sign * X2[0];
    X[0] := Mid * X[0];
    X[1] := Mid * X[1];
    Y[0] := Side * Y[0];
    Y[1] := Side * Y[1];
    Temp := X[0];
    X[0] := Temp - Y[0];
    Y[0] := Temp + Y[0];
    Temp := X[1];
    X[1] := Temp - Y[1];
    Y[1] := Temp + Y[1];
  end
  else
  begin
    MBits := Imax(0, Imin(B, (B - Delta) div 2));
    SBits := B - MBits;
    Dec(Context.RemainingBits, QAllocation);
    Rebalance := Context.RemainingBits;
    if MBits >= SBits then
    begin
      CollapseMask := DecodeBand(Context, X, N, MBits, BlockCount, Lowband, LM, LowbandOut, 1, LowbandScratch, Fill);
      Rebalance := MBits - (Rebalance - Context.RemainingBits);
      if (Rebalance > 3 shl BitResolution) and (ITheta <> 0) then
        Inc(SBits, Rebalance - (3 shl BitResolution));
      CollapseMask := CollapseMask or DecodeBand(Context, Y, N, SBits, BlockCount, nil, LM, nil, Side, nil,
        Fill shr BlockCount);
    end
    else
    begin
      CollapseMask := DecodeBand(Context, Y, N, SBits, BlockCount, nil, LM, nil, Side, nil, Fill shr BlockCount);
      Rebalance := SBits - (Rebalance - Context.RemainingBits);
      if (Rebalance > 3 shl BitResolution) and (ITheta <> 16384) then
        Inc(MBits, Rebalance - (3 shl BitResolution));
      CollapseMask := CollapseMask or DecodeBand(Context, X, N, MBits, BlockCount, Lowband, LM, LowbandOut, 1,
        LowbandScratch, Fill);
    end;
  end;
  if N <> 2 then
    StereoMerge(X, Y, Mid, N);
  if Inverted then
    for J := 0 to N - 1 do
      Y[J] := -Y[J];
  Result := CollapseMask;
end;

procedure SpecialHybridFolding(Norm, Norm2: PSingle; StartBand, M: Integer; DualStereo: Boolean);
var
  N1, N2: Integer;
begin
  N1 := M * (CeltBandEdges[StartBand + 1] - CeltBandEdges[StartBand]);
  N2 := M * (CeltBandEdges[StartBand + 2] - CeltBandEdges[StartBand + 1]);
  if N2 > N1 then
  begin
    Move(Norm[2 * N1 - N2], Norm[N1], (N2 - N1) * SizeOf(Single));
    if DualStereo then
      Move(Norm2[2 * N1 - N2], Norm2[N1], (N2 - N1) * SizeOf(Single));
  end;
end;

procedure CeltDecodeAllBands(StartBand, EndBand: Integer; X, Y: PSingle; var CollapseMasks: TCeltCollapseMasks;
  const Pulses: TCeltBandInts; ShortBlocks: Boolean; Spread, DualStereo, Intensity: Integer;
  const TfResolution: TCeltBandInts; TotalBits, Balance: Integer; Decoder: TOpusRangeDecoder; LM,
  CodedBands: Integer; var Seed: LongWord; DisableInversion: Boolean);
var
  Context: TBandContext;
  NormBuffer: array[0..2 * 8 * 100 - 1] of Single;
  Norm, Norm2, LowbandScratch, BandX, BandY, LowbandPointer, Norm2Lowband, OutPointer, Out2Pointer: PSingle;
  M, BlockCount, NormOffset, LowbandOffset, Channels, Band, Tell, B, N, CurrentBalance, EffectiveLowband: Integer;
  FoldStart, FoldEnd, FoldIndex, J, RemainingBits: Integer;
  UpdateLowband, Last, Dual: Boolean;
  XMask, YMask: LongWord;
begin
  M := 1 shl LM;
  if ShortBlocks then
    BlockCount := M
  else
    BlockCount := 1;
  if Y <> nil then
    Channels := 2
  else
    Channels := 1;
  NormOffset := M * CeltBandEdges[StartBand];
  Norm := @NormBuffer[0];
  Norm2 := Norm + M * CeltBandEdges[CeltBandCount - 1] - NormOffset;
  LowbandScratch := X + M * CeltBandEdges[CeltBandCount - 1];
  LowbandOffset := 0;
  UpdateLowband := True;
  Dual := DualStereo <> 0;
  Context.Decoder := Decoder;
  Context.Intensity := Intensity;
  Context.Seed := Seed;
  Context.Spread := Spread;
  Context.DisableInversion := DisableInversion;
  Context.AvoidSplitNoise := BlockCount > 1;
  for Band := StartBand to EndBand - 1 do
  begin
    Context.BandIndex := Band;
    Last := Band = EndBand - 1;
    BandX := X + M * CeltBandEdges[Band];
    if Y <> nil then
      BandY := Y + M * CeltBandEdges[Band]
    else
      BandY := nil;
    N := M * CeltBandEdges[Band + 1] - M * CeltBandEdges[Band];
    Tell := Integer(Decoder.TellFraction);
    if Band <> StartBand then
      Dec(Balance, Tell);
    RemainingBits := TotalBits - Tell - 1;
    Context.RemainingBits := RemainingBits;
    if Band <= CodedBands - 1 then
    begin
      CurrentBalance := Balance div Imin(3, CodedBands - Band);
      B := Imax(0, Imin(16383, Imin(RemainingBits + 1, Pulses[Band] + CurrentBalance)));
    end
    else
      B := 0;
    if ((M * CeltBandEdges[Band] - N >= M * CeltBandEdges[StartBand]) or (Band = StartBand + 1))
      and (UpdateLowband or (LowbandOffset = 0)) then
      LowbandOffset := Band;
    if Band = StartBand + 1 then
      SpecialHybridFolding(Norm, Norm2, StartBand, M, Dual);
    Context.TfChange := TfResolution[Band];
    if Last then
      LowbandScratch := nil;
    EffectiveLowband := -1;
    if (LowbandOffset <> 0) and ((Spread <> CeltSpreadAggressive) or (BlockCount > 1) or (Context.TfChange < 0)) then
    begin
      EffectiveLowband := Imax(0, M * CeltBandEdges[LowbandOffset] - NormOffset - N);
      FoldStart := LowbandOffset;
      repeat
        Dec(FoldStart);
      until M * CeltBandEdges[FoldStart] <= EffectiveLowband + NormOffset;
      FoldEnd := LowbandOffset - 1;
      repeat
        Inc(FoldEnd);
      until not ((FoldEnd < Band) and (M * CeltBandEdges[FoldEnd] < EffectiveLowband + NormOffset + N));
      XMask := 0;
      YMask := 0;
      FoldIndex := FoldStart;
      repeat
        XMask := XMask or CollapseMasks[FoldIndex * Channels];
        YMask := YMask or CollapseMasks[FoldIndex * Channels + Channels - 1];
        Inc(FoldIndex);
      until FoldIndex >= FoldEnd;
    end
    else
    begin
      XMask := (LongWord(1) shl BlockCount) - 1;
      YMask := XMask;
    end;
    if Dual and (Band = Intensity) then
    begin
      Dual := False;
      for J := 0 to M * CeltBandEdges[Band] - NormOffset - 1 do
        Norm[J] := 0.5 * (Norm[J] + Norm2[J]);
    end;
    if EffectiveLowband <> -1 then
    begin
      LowbandPointer := Norm + EffectiveLowband;
      Norm2Lowband := Norm2 + EffectiveLowband;
    end
    else
    begin
      LowbandPointer := nil;
      Norm2Lowband := nil;
    end;
    if Last then
    begin
      OutPointer := nil;
      Out2Pointer := nil;
    end
    else
    begin
      OutPointer := Norm + M * CeltBandEdges[Band] - NormOffset;
      Out2Pointer := Norm2 + M * CeltBandEdges[Band] - NormOffset;
    end;
    if Dual then
    begin
      XMask := DecodeBand(Context, BandX, N, B div 2, BlockCount, LowbandPointer, LM, OutPointer, 1,
        LowbandScratch, XMask);
      YMask := DecodeBand(Context, BandY, N, B div 2, BlockCount, Norm2Lowband, LM, Out2Pointer, 1,
        LowbandScratch, YMask);
    end
    else
    begin
      if BandY <> nil then
        XMask := DecodeBandStereo(Context, BandX, BandY, N, B, BlockCount, LowbandPointer, LM, OutPointer,
          LowbandScratch, XMask or YMask)
      else
        XMask := DecodeBand(Context, BandX, N, B, BlockCount, LowbandPointer, LM, OutPointer, 1, LowbandScratch,
          XMask or YMask);
      YMask := XMask;
    end;
    CollapseMasks[Band * Channels] := Byte(XMask);
    CollapseMasks[Band * Channels + Channels - 1] := Byte(YMask);
    Inc(Balance, Pulses[Band] + Tell);
    UpdateLowband := B > (N shl BitResolution);
    Context.AvoidSplitNoise := False;
  end;
  Seed := Context.Seed;
end;

procedure CeltAntiCollapse(X: PSingle; const CollapseMasks: TCeltCollapseMasks; LM, Channels, Size,
  StartBand, EndBand: Integer; LogEnergies, Previous1, Previous2: PSingle; const Pulses: TCeltBandInts;
  Seed: LongWord);
var
  Band, Channel, K, J, N0, Depth: Integer;
  Threshold, InverseSqrt, Prev1, Prev2, EnergyDifference, R: Single;
  BandX: PSingle;
  Renormalize: Boolean;
begin
  for Band := StartBand to EndBand - 1 do
  begin
    N0 := CeltBandEdges[Band + 1] - CeltBandEdges[Band];
    Depth := ((1 + Pulses[Band]) div N0) shr LM;
    Threshold := 0.5 * Exp(0.6931471805599453094 * (-0.125 * Depth));
    InverseSqrt := 1 / Sqrt(N0 shl LM);
    for Channel := 0 to Channels - 1 do
    begin
      Renormalize := False;
      Prev1 := Previous1[Channel * CeltBandCount + Band];
      Prev2 := Previous2[Channel * CeltBandCount + Band];
      if Channels = 1 then
      begin
        Prev1 := Max(Prev1, Previous1[CeltBandCount + Band]);
        Prev2 := Max(Prev2, Previous2[CeltBandCount + Band]);
      end;
      EnergyDifference := LogEnergies[Channel * CeltBandCount + Band] - Min(Prev1, Prev2);
      if EnergyDifference < 0 then
        EnergyDifference := 0;
      R := 2 * Exp(0.6931471805599453094 * (-EnergyDifference));
      if LM = 3 then
        R := R * 1.41421356;
      R := Min(Threshold, R);
      R := R * InverseSqrt;
      BandX := X + Channel * Size + (CeltBandEdges[Band] shl LM);
      for K := 0 to (1 shl LM) - 1 do
        if (CollapseMasks[Band * Channels + Channel] and (1 shl K)) = 0 then
        begin
          for J := 0 to N0 - 1 do
          begin
            Seed := CeltRandom(Seed);
            if (Seed and $8000) <> 0 then
              BandX[(J shl LM) + K] := R
            else
              BandX[(J shl LM) + K] := -R;
          end;
          Renormalize := True;
        end;
      if Renormalize then
        CeltRenormaliseVector(BandX, N0 shl LM, 1);
    end;
  end;
end;

procedure CeltDenormaliseBands(X, Frequencies, LogEnergies: PSingle; StartBand, EndBand, M, Downsample: Integer;
  Silence: Boolean);
var
  N, Bound, Band, J, BandEnd: Integer;
  F, Source: PSingle;
  LogGain, Gain: Single;
begin
  N := M * CeltShortMdctSize;
  Bound := M * CeltBandEdges[EndBand];
  if Downsample <> 1 then
    Bound := Imin(Bound, N div Downsample);
  if Silence then
  begin
    Bound := 0;
    StartBand := 0;
    EndBand := 0;
  end;
  F := Frequencies;
  Source := X + M * CeltBandEdges[StartBand];
  for J := 0 to M * CeltBandEdges[StartBand] - 1 do
  begin
    F^ := 0;
    Inc(F);
  end;
  for Band := StartBand to EndBand - 1 do
  begin
    J := M * CeltBandEdges[Band];
    BandEnd := M * CeltBandEdges[Band + 1];
    LogGain := LogEnergies[Band] + CeltEnergyMeans[Band];
    if LogGain > 32 then
      LogGain := 32;
    Gain := Exp(0.6931471805599453094 * LogGain);
    repeat
      F^ := Source^ * Gain;
      Inc(F);
      Inc(Source);
      Inc(J);
    until J >= BandEnd;
  end;
  if N > Bound then
    FillChar(Frequencies[Bound], (N - Bound) * SizeOf(Single), 0);
end;

end.
