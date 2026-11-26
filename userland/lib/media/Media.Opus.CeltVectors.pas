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
  CELT's pyramid vector quantiser on the decoding side (RFC 6716 section
  4.3.4): the index of a K-pulse N-dimensional vector decoded and turned
  into the vector (combinations with signs, counted by the U(N,K)
  recurrence), normalised, with the spreading rotation undone; and the
  renormalisation the band coder uses after folding.
}
unit Media.Opus.CeltVectors;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

uses
  Media.Opus.RangeDecoder;

const
  CeltSpreadNone = 0;
  CeltSpreadLight = 1;
  CeltSpreadNormal = 2;
  CeltSpreadAggressive = 3;

{ Decodes the K pulses of an N-vector into X scaled to Gain; returns the
  collapse mask of its B blocks. }
function CeltDecodeVector(X: PSingle; N, K, Spread, Blocks: Integer; Decoder: TOpusRangeDecoder;
  Gain: Single): LongWord;
procedure CeltRenormaliseVector(X: PSingle; N: Integer; Gain: Single);
procedure CeltExpRotation(X: PSingle; Length, Direction, Stride, K, Spread: Integer);

implementation

const
  MaximumPulses = 256;

{ The counting arrays wrap modulo 2^32 like the reference's. }
{$push}
{$R-}
{$Q-}
procedure NextRow(U: PLongWord; Length: Integer; First: LongWord);
var
  J: Integer;
  Next: LongWord;
begin
  J := 1;
  repeat
    Next := U[J] + U[J - 1] + First;
    U[J - 1] := First;
    First := Next;
    Inc(J);
  until J >= Length;
  U[J - 1] := First;
end;

procedure PreviousRow(U: PLongWord; Length: Integer; First: LongWord);
var
  J: Integer;
  Next: LongWord;
begin
  J := 1;
  repeat
    Next := U[J] - U[J - 1] - First;
    U[J - 1] := First;
    First := Next;
    Inc(J);
  until J >= Length;
  U[J - 1] := First;
end;

function CountCombinations(N, K: Integer; U: PLongWord): LongWord;
var
  Index: Integer;
begin
  U[0] := 0;
  U[1] := 1;
  for Index := 2 to K + 1 do
    U[Index] := LongWord(Index shl 1) - 1;
  for Index := 2 to N - 1 do
    NextRow(U + 1, K + 1, 1);
  Result := U[K] + U[K + 1];
end;

function CombinationToPulses(N, K: Integer; Index: LongWord; Y: PInteger; U: PLongWord): Single;
var
  J, Sign, Pulse: Integer;
  P: LongWord;
  Energy: Single;
begin
  Energy := 0;
  for J := 0 to N - 1 do
  begin
    P := U[K + 1];
    if Index >= P then
    begin
      Sign := -1;
      Index := Index - P;
    end
    else
      Sign := 0;
    Pulse := K;
    P := U[K];
    while P > Index do
    begin
      Dec(K);
      P := U[K];
    end;
    Index := Index - P;
    Dec(Pulse, K);
    Pulse := (Pulse + Sign) xor Sign;
    Y[J] := Pulse;
    Energy := Energy + Pulse * Pulse;
    PreviousRow(U, K + 2, 0);
  end;
  Result := Energy;
end;
{$pop}

procedure ExpRotationStep(X: PSingle; Length, Stride: Integer; C, S: Single);
var
  Index: Integer;
  Pointer: PSingle;
  X1, X2, MinusS: Single;
begin
  Pointer := X;
  MinusS := -S;
  for Index := 0 to Length - Stride - 1 do
  begin
    X1 := Pointer[0];
    X2 := Pointer[Stride];
    Pointer[Stride] := C * X2 + S * X1;
    Pointer^ := C * X1 + MinusS * X2;
    Inc(Pointer);
  end;
  Pointer := @X[Length - 2 * Stride - 1];
  Index := Length - 2 * Stride - 1;
  while Index >= 0 do
  begin
    X1 := Pointer[0];
    X2 := Pointer[Stride];
    Pointer[Stride] := C * X2 + S * X1;
    Pointer^ := C * X1 + MinusS * X2;
    Dec(Pointer);
    Dec(Index);
  end;
end;

procedure CeltExpRotation(X: PSingle; Length, Direction, Stride, K, Spread: Integer);
const
  SpreadFactors: array[1..3] of Integer = (15, 10, 5);
var
  Index, Stride2, Factor: Integer;
  C, S, Gain, Theta: Single;
begin
  if (2 * K >= Length) or (Spread = CeltSpreadNone) then
    Exit;
  Factor := SpreadFactors[Spread];
  Gain := Length / (Length + Factor * K);
  Theta := 0.5 * (Gain * Gain);
  C := Cos(0.5 * Pi * Theta);
  S := Cos(0.5 * Pi * (1 - Theta));
  Stride2 := 0;
  if Length >= 8 * Stride then
  begin
    Stride2 := 1;
    while (Stride2 * Stride2 + Stride2) * Stride + (Stride shr 2) < Length do
      Inc(Stride2);
  end;
  Length := Length div Stride;
  for Index := 0 to Stride - 1 do
    if Direction < 0 then
    begin
      if Stride2 <> 0 then
        ExpRotationStep(X + Index * Length, Length, Stride2, S, C);
      ExpRotationStep(X + Index * Length, Length, 1, C, S);
    end
    else
    begin
      ExpRotationStep(X + Index * Length, Length, 1, C, -S);
      if Stride2 <> 0 then
        ExpRotationStep(X + Index * Length, Length, Stride2, S, -C);
    end;
end;

procedure CeltRenormaliseVector(X: PSingle; N: Integer; Gain: Single);
var
  Index: Integer;
  Energy, Scale: Single;
begin
  Energy := 1e-15;
  for Index := 0 to N - 1 do
    Energy := Energy + X[Index] * X[Index];
  Scale := (1 / Sqrt(Energy)) * Gain;
  for Index := 0 to N - 1 do
    X[Index] := Scale * X[Index];
end;

function CeltDecodeVector(X: PSingle; N, K, Spread, Blocks: Integer; Decoder: TOpusRangeDecoder;
  Gain: Single): LongWord;
var
  Pulses: array[0..351] of Integer;
  Counts: array[0..MaximumPulses + 2] of LongWord;
  Energy, Scale: Single;
  Index, J, BlockLength: Integer;
  Collapse, Any: LongWord;
begin
  Energy := CombinationToPulses(N, K, Decoder.DecodeUInt(CountCombinations(N, K, @Counts[0])), @Pulses[0],
    @Counts[0]);
  Scale := (1 / Sqrt(Energy)) * Gain;
  for Index := 0 to N - 1 do
    X[Index] := Scale * Pulses[Index];
  CeltExpRotation(X, N, -1, Blocks, K, Spread);
  if Blocks <= 1 then
    Exit(1);
  BlockLength := N div Blocks;
  Collapse := 0;
  for Index := 0 to Blocks - 1 do
  begin
    Any := 0;
    for J := 0 to BlockLength - 1 do
      Any := Any or LongWord(Pulses[Index * BlockLength + J]);
    if Any <> 0 then
      Collapse := Collapse or (LongWord(1) shl Index);
  end;
  Result := Collapse;
end;

end.
