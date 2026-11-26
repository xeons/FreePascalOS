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
  What CELT's packet loss concealment analyses the last good audio with:
  the pitch search (downsampled by 2 and 4, correlation peaks refined by
  pseudo-interpolation) and linear prediction (autocorrelation, the
  Levinson-Durbin recursion, FIR and IIR filters).
}
unit Media.Opus.CeltPitch;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

{ Halves Length samples of Channels signals into LowPass, whitened. }
procedure CeltPitchDownsample(Signals: array of PSingle; LowPass: PSingle; Length, Channels: Integer);
{ The pitch period (in samples of the halved signal, doubled) of X in Y. }
function CeltPitchSearch(X, Y: PSingle; Length, MaximumPitch: Integer): Integer;
procedure CeltAutocorrelation(X, Correlation, Window: PSingle; Overlap, Lag, N: Integer);
procedure CeltLpc(Lpc, Correlation: PSingle; Order: Integer);
{ Y = X filtered by 1 + sum Coefficients[j] z^-(j+1); X needs Order samples of history before it. }
procedure CeltFir(X, Coefficients, Y: PSingle; N, Order: Integer);
{ Y = X through 1 / (1 + sum Coefficients[j] z^-(j+1)), Memory the last outputs (newest first). }
procedure CeltIir(X, Coefficients, Y: PSingle; N, Order: Integer; Memory: PSingle);

implementation

procedure PitchCorrelation(X, Y, Correlation: PSingle; Length, MaximumPitch: Integer);
var
  Index, J: Integer;
  Sum: Single;
begin
  for Index := 0 to MaximumPitch - 1 do
  begin
    Sum := 0;
    for J := 0 to Length - 1 do
      Sum := Sum + X[J] * Y[Index + J];
    Correlation[Index] := Sum;
  end;
end;

procedure CeltAutocorrelation(X, Correlation, Window: PSingle; Overlap, Lag, N: Integer);
var
  Windowed: array of Single;
  Source: PSingle;
  Index, K, FastN: Integer;
  Sum: Single;
begin
  Windowed := nil;
  FastN := N - Lag;
  if Overlap = 0 then
    Source := X
  else
  begin
    SetLength(Windowed, N);
    for Index := 0 to N - 1 do
      Windowed[Index] := X[Index];
    for Index := 0 to Overlap - 1 do
    begin
      Windowed[Index] := X[Index] * Window[Index];
      Windowed[N - Index - 1] := X[N - Index - 1] * Window[Index];
    end;
    Source := @Windowed[0];
  end;
  PitchCorrelation(Source, Source, Correlation, FastN, Lag + 1);
  for K := 0 to Lag do
  begin
    Sum := 0;
    for Index := K + FastN to N - 1 do
      Sum := Sum + Source[Index] * Source[Index - K];
    Correlation[K] := Correlation[K] + Sum;
  end;
end;

procedure CeltLpc(Lpc, Correlation: PSingle; Order: Integer);
var
  Index, J: Integer;
  Reflection, Error, Sum, Temp1, Temp2: Single;
begin
  Error := Correlation[0];
  for Index := 0 to Order - 1 do
    Lpc[Index] := 0;
  if Correlation[0] > 1e-10 then
    for Index := 0 to Order - 1 do
    begin
      Sum := 0;
      for J := 0 to Index - 1 do
        Sum := Sum + Lpc[J] * Correlation[Index - J];
      Sum := Sum + Correlation[Index + 1];
      Reflection := -Sum / Error;
      Lpc[Index] := Reflection;
      for J := 0 to ((Index + 1) shr 1) - 1 do
      begin
        Temp1 := Lpc[J];
        Temp2 := Lpc[Index - 1 - J];
        Lpc[J] := Temp1 + Reflection * Temp2;
        Lpc[Index - 1 - J] := Temp2 + Reflection * Temp1;
      end;
      Error := Error - Reflection * Reflection * Error;
      if Error <= 0.001 * Correlation[0] then
        Break;
    end;
end;

procedure CeltFir(X, Coefficients, Y: PSingle; N, Order: Integer);
var
  Index, J: Integer;
  Sum: Single;
begin
  for Index := 0 to N - 1 do
  begin
    Sum := X[Index];
    for J := 0 to Order - 1 do
      Sum := Sum + Coefficients[J] * X[Index - J - 1];
    Y[Index] := Sum;
  end;
end;

procedure CeltIir(X, Coefficients, Y: PSingle; N, Order: Integer; Memory: PSingle);
var
  Index, J: Integer;
  Sum: Single;
begin
  for Index := 0 to N - 1 do
  begin
    Sum := X[Index];
    for J := 0 to Order - 1 do
      Sum := Sum - Coefficients[J] * Memory[J];
    for J := Order - 1 downto 1 do
      Memory[J] := Memory[J - 1];
    Memory[0] := Sum;
    Y[Index] := Sum;
  end;
end;

procedure Fir5(X, Coefficients: PSingle; N: Integer);
var
  Index: Integer;
  Memory: array[0..4] of Single;
  Sum: Single;
begin
  FillChar(Memory, SizeOf(Memory), 0);
  for Index := 0 to N - 1 do
  begin
    Sum := X[Index] + Coefficients[0] * Memory[0] + Coefficients[1] * Memory[1] + Coefficients[2] * Memory[2]
      + Coefficients[3] * Memory[3] + Coefficients[4] * Memory[4];
    Memory[4] := Memory[3];
    Memory[3] := Memory[2];
    Memory[2] := Memory[1];
    Memory[1] := Memory[0];
    Memory[0] := X[Index];
    X[Index] := Sum;
  end;
end;

procedure CeltPitchDownsample(Signals: array of PSingle; LowPass: PSingle; Length, Channels: Integer);
var
  Index, Channel: Integer;
  Correlation: array[0..4] of Single;
  Lpc: array[0..3] of Single;
  Lpc2: array[0..4] of Single;
  Taper: Single;
  X: PSingle;
begin
  for Index := 0 to (Length shr 1) - 1 do
    LowPass[Index] := 0;
  for Channel := 0 to Channels - 1 do
  begin
    X := Signals[Channel];
    for Index := 1 to (Length shr 1) - 1 do
      LowPass[Index] := LowPass[Index] + 0.25 * X[2 * Index - 1] + 0.25 * X[2 * Index + 1] + 0.5 * X[2 * Index];
    LowPass[0] := LowPass[0] + 0.25 * X[1] + 0.5 * X[0];
  end;
  CeltAutocorrelation(LowPass, @Correlation[0], nil, 0, 4, Length shr 1);
  Correlation[0] := Correlation[0] * 1.0001;
  for Index := 1 to 4 do
    Correlation[Index] := Correlation[Index] - Correlation[Index] * (0.008 * Index) * (0.008 * Index);
  CeltLpc(@Lpc[0], @Correlation[0], 4);
  Taper := 1;
  for Index := 0 to 3 do
  begin
    Taper := 0.9 * Taper;
    Lpc[Index] := Lpc[Index] * Taper;
  end;
  Lpc2[0] := Lpc[0] + 0.8;
  Lpc2[1] := Lpc[1] + 0.8 * Lpc[0];
  Lpc2[2] := Lpc[2] + 0.8 * Lpc[1];
  Lpc2[3] := Lpc[3] + 0.8 * Lpc[2];
  Lpc2[4] := 0.8 * Lpc[3];
  Fir5(LowPass, @Lpc2[0], Length shr 1);
end;

procedure FindBestPitch(Correlation, Y: PSingle; Length, MaximumPitch: Integer; var BestPitch: array of Integer);
var
  Index, J: Integer;
  Syy, Scaled, Numerator: Single;
  BestNumerator, BestDenominator: array[0..1] of Single;
begin
  Syy := 1;
  BestNumerator[0] := -1;
  BestNumerator[1] := -1;
  BestDenominator[0] := 0;
  BestDenominator[1] := 0;
  BestPitch[0] := 0;
  BestPitch[1] := 1;
  for J := 0 to Length - 1 do
    Syy := Syy + Y[J] * Y[J];
  for Index := 0 to MaximumPitch - 1 do
  begin
    if Correlation[Index] > 0 then
    begin
      Scaled := Correlation[Index] * 1e-12;
      Numerator := Scaled * Scaled;
      if Numerator * BestDenominator[1] > BestNumerator[1] * Syy then
      begin
        if Numerator * BestDenominator[0] > BestNumerator[0] * Syy then
        begin
          BestNumerator[1] := BestNumerator[0];
          BestDenominator[1] := BestDenominator[0];
          BestPitch[1] := BestPitch[0];
          BestNumerator[0] := Numerator;
          BestDenominator[0] := Syy;
          BestPitch[0] := Index;
        end
        else
        begin
          BestNumerator[1] := Numerator;
          BestDenominator[1] := Syy;
          BestPitch[1] := Index;
        end;
      end;
    end;
    Syy := Syy + Y[Index + Length] * Y[Index + Length] - Y[Index] * Y[Index];
    if Syy < 1 then
      Syy := 1;
  end;
end;

function CeltPitchSearch(X, Y: PSingle; Length, MaximumPitch: Integer): Integer;
var
  Lag, Index, J, Offset: Integer;
  BestPitch: array[0..1] of Integer;
  X4, Y4, Correlation: array of Single;
  Sum, A, B, C: Single;
begin
  Lag := Length + MaximumPitch;
  X4 := nil;
  Y4 := nil;
  Correlation := nil;
  SetLength(X4, Length shr 2);
  SetLength(Y4, Lag shr 2);
  SetLength(Correlation, MaximumPitch shr 1);
  for J := 0 to (Length shr 2) - 1 do
    X4[J] := X[2 * J];
  for J := 0 to (Lag shr 2) - 1 do
    Y4[J] := Y[2 * J];
  PitchCorrelation(@X4[0], @Y4[0], @Correlation[0], Length shr 2, MaximumPitch shr 2);
  FindBestPitch(@Correlation[0], @Y4[0], Length shr 2, MaximumPitch shr 2, BestPitch);
  for Index := 0 to (MaximumPitch shr 1) - 1 do
  begin
    Correlation[Index] := 0;
    if (Abs(Index - 2 * BestPitch[0]) > 2) and (Abs(Index - 2 * BestPitch[1]) > 2) then
      Continue;
    Sum := 0;
    for J := 0 to (Length shr 1) - 1 do
      Sum := Sum + X[J] * Y[Index + J];
    if Sum < -1 then
      Sum := -1;
    Correlation[Index] := Sum;
  end;
  FindBestPitch(@Correlation[0], Y, Length shr 1, MaximumPitch shr 1, BestPitch);
  if (BestPitch[0] > 0) and (BestPitch[0] < (MaximumPitch shr 1) - 1) then
  begin
    A := Correlation[BestPitch[0] - 1];
    B := Correlation[BestPitch[0]];
    C := Correlation[BestPitch[0] + 1];
    if (C - A) > 0.7 * (B - A) then
      Offset := 1
    else if (A - C) > 0.7 * (B - C) then
      Offset := -1
    else
      Offset := 0;
  end
  else
    Offset := 0;
  Result := 2 * BestPitch[0] - Offset;
end;

end.
