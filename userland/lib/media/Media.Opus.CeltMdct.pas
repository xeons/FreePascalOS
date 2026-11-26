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
  CELT's inverse MDCT (RFC 6716 section 4.3.7): an N/4-point complex FFT
  (mixed radix 2, 3, 4 and 5, as the reference's KISS FFT) between a
  pre- and a post-rotation, then the windowed overlap mirrored for time
  domain aliasing cancellation. One lookup serves the four frame sizes
  (N = 1920 shifted right by 0 to 3).
}
unit Media.Opus.CeltMdct;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

type
  TOpusComplex = record
    Real, Imaginary: Single;
  end;
  POpusComplex = ^TOpusComplex;

  TOpusFft = record
    Size: Integer;
    Factors: array[0..15] of Integer;
    BitReverse: array of SmallInt;
    Twiddles: array of TOpusComplex;
  end;

  TCeltMdct = class
  private
    FSize: Integer;
    FMaximumShift: Integer;
    FFfts: array[0..3] of TOpusFft;
    FTrig: array of Single;
    FWindow: array of Single;
    FOverlap: Integer;
  public
    constructor Create(Size, MaximumShift, Overlap: Integer);
    { Inverse transform of the N/2 coefficients at Input (Stride apart)
      into Output: N/2 + Overlap samples, the first Overlap of them the
      windowed overlap with the previous block. }
    procedure Backward(Input: PSingle; Output: PSingle; Shift, Stride: Integer);
    function WindowValue(Index: Integer): Single; inline;
    function WindowData: PSingle;
    property Overlap: Integer read FOverlap;
  end;

{ Prepares a forward complex FFT of Size points (Size a product of 2, 3,
  4 and 5). }
procedure InitOpusFft(out Fft: TOpusFft; Size: Integer);
procedure OpusFftInPlace(const Fft: TOpusFft; Data: POpusComplex);

implementation

procedure ComputeFactors(Size: Integer; var Factors: array of Integer);
var
  Radix, Stages, Remaining, Index, Swap: Integer;
begin
  Radix := 4;
  Stages := 0;
  Remaining := Size;
  repeat
    while Remaining mod Radix <> 0 do
    begin
      case Radix of
        4: Radix := 2;
        2: Radix := 3;
      else
        Inc(Radix, 2);
      end;
      if (Radix > 32000) or (Radix * Radix > Remaining) then
        Radix := Remaining;
    end;
    Remaining := Remaining div Radix;
    Factors[2 * Stages] := Radix;
    if (Radix = 2) and (Stages > 1) then
    begin
      Factors[2 * Stages] := 4;
      Factors[2] := 2;
    end;
    Inc(Stages);
  until Remaining <= 1;
  for Index := 0 to Stages div 2 - 1 do
  begin
    Swap := Factors[2 * Index];
    Factors[2 * Index] := Factors[2 * (Stages - Index - 1)];
    Factors[2 * (Stages - Index - 1)] := Swap;
  end;
  Remaining := Size;
  for Index := 0 to Stages - 1 do
  begin
    Remaining := Remaining div Factors[2 * Index];
    Factors[2 * Index + 1] := Remaining;
  end;
end;

procedure ComputeBitReverse(Output: Integer; Table: PSmallInt; Stride, InputStride: Integer;
  const Factors: array of Integer; FactorIndex: Integer);
var
  Radix, Count, Index: Integer;
begin
  Radix := Factors[FactorIndex];
  Count := Factors[FactorIndex + 1];
  if Count = 1 then
  begin
    for Index := 0 to Radix - 1 do
    begin
      Table^ := Output + Index;
      Inc(Table, Stride * InputStride);
    end;
  end
  else
    for Index := 0 to Radix - 1 do
    begin
      ComputeBitReverse(Output, Table, Stride * Radix, InputStride, Factors, FactorIndex + 2);
      Inc(Table, Stride * InputStride);
      Inc(Output, Count);
    end;
end;

procedure InitOpusFft(out Fft: TOpusFft; Size: Integer);
var
  Index: Integer;
  Phase: Double;
begin
  Fft.Size := Size;
  FillChar(Fft.Factors, SizeOf(Fft.Factors), 0);
  ComputeFactors(Size, Fft.Factors);
  SetLength(Fft.Twiddles, Size);
  for Index := 0 to Size - 1 do
  begin
    Phase := (-2 * Pi / Size) * Index;
    Fft.Twiddles[Index].Real := Cos(Phase);
    Fft.Twiddles[Index].Imaginary := Sin(Phase);
  end;
  SetLength(Fft.BitReverse, Size);
  ComputeBitReverse(0, @Fft.BitReverse[0], 1, 1, Fft.Factors, 0);
end;

procedure Butterfly2(Output: POpusComplex; Count: Integer);
const
  Twiddle = 0.7071067812;
var
  Index: Integer;
  Second: POpusComplex;
  T: TOpusComplex;
begin
  for Index := 0 to Count - 1 do
  begin
    Second := Output + 4;
    T := Second[0];
    Second[0].Real := Output[0].Real - T.Real;
    Second[0].Imaginary := Output[0].Imaginary - T.Imaginary;
    Output[0].Real := Output[0].Real + T.Real;
    Output[0].Imaginary := Output[0].Imaginary + T.Imaginary;

    T.Real := (Second[1].Real + Second[1].Imaginary) * Twiddle;
    T.Imaginary := (Second[1].Imaginary - Second[1].Real) * Twiddle;
    Second[1].Real := Output[1].Real - T.Real;
    Second[1].Imaginary := Output[1].Imaginary - T.Imaginary;
    Output[1].Real := Output[1].Real + T.Real;
    Output[1].Imaginary := Output[1].Imaginary + T.Imaginary;

    T.Real := Second[2].Imaginary;
    T.Imaginary := -Second[2].Real;
    Second[2].Real := Output[2].Real - T.Real;
    Second[2].Imaginary := Output[2].Imaginary - T.Imaginary;
    Output[2].Real := Output[2].Real + T.Real;
    Output[2].Imaginary := Output[2].Imaginary + T.Imaginary;

    T.Real := (Second[3].Imaginary - Second[3].Real) * Twiddle;
    T.Imaginary := -(Second[3].Imaginary + Second[3].Real) * Twiddle;
    Second[3].Real := Output[3].Real - T.Real;
    Second[3].Imaginary := Output[3].Imaginary - T.Imaginary;
    Output[3].Real := Output[3].Real + T.Real;
    Output[3].Imaginary := Output[3].Imaginary + T.Imaginary;
    Inc(Output, 8);
  end;
end;

procedure ComplexMultiply(out Product: TOpusComplex; const A, B: TOpusComplex); inline;
begin
  Product.Real := A.Real * B.Real - A.Imaginary * B.Imaginary;
  Product.Imaginary := A.Real * B.Imaginary + A.Imaginary * B.Real;
end;

procedure Butterfly4(Output: POpusComplex; Stride: Integer; const Fft: TOpusFft; M, Count, MM: Integer);
var
  Index, J: Integer;
  S0, S1, S2, S3, S4, S5: TOpusComplex;
  Start, F: POpusComplex;
  T1, T2, T3: Integer;
begin
  if M = 1 then
  begin
    F := Output;
    for Index := 0 to Count - 1 do
    begin
      S0.Real := F[0].Real - F[2].Real;
      S0.Imaginary := F[0].Imaginary - F[2].Imaginary;
      F[0].Real := F[0].Real + F[2].Real;
      F[0].Imaginary := F[0].Imaginary + F[2].Imaginary;
      S1.Real := F[1].Real + F[3].Real;
      S1.Imaginary := F[1].Imaginary + F[3].Imaginary;
      F[2].Real := F[0].Real - S1.Real;
      F[2].Imaginary := F[0].Imaginary - S1.Imaginary;
      F[0].Real := F[0].Real + S1.Real;
      F[0].Imaginary := F[0].Imaginary + S1.Imaginary;
      S1.Real := F[1].Real - F[3].Real;
      S1.Imaginary := F[1].Imaginary - F[3].Imaginary;
      F[1].Real := S0.Real + S1.Imaginary;
      F[1].Imaginary := S0.Imaginary - S1.Real;
      F[3].Real := S0.Real - S1.Imaginary;
      F[3].Imaginary := S0.Imaginary + S1.Real;
      Inc(F, 4);
    end;
    Exit;
  end;
  Start := Output;
  for Index := 0 to Count - 1 do
  begin
    F := Start + Index * MM;
    T1 := 0;
    T2 := 0;
    T3 := 0;
    for J := 0 to M - 1 do
    begin
      ComplexMultiply(S0, F[M], Fft.Twiddles[T1]);
      ComplexMultiply(S1, F[2 * M], Fft.Twiddles[T2]);
      ComplexMultiply(S2, F[3 * M], Fft.Twiddles[T3]);
      S5.Real := F[0].Real - S1.Real;
      S5.Imaginary := F[0].Imaginary - S1.Imaginary;
      F[0].Real := F[0].Real + S1.Real;
      F[0].Imaginary := F[0].Imaginary + S1.Imaginary;
      S3.Real := S0.Real + S2.Real;
      S3.Imaginary := S0.Imaginary + S2.Imaginary;
      S4.Real := S0.Real - S2.Real;
      S4.Imaginary := S0.Imaginary - S2.Imaginary;
      F[2 * M].Real := F[0].Real - S3.Real;
      F[2 * M].Imaginary := F[0].Imaginary - S3.Imaginary;
      Inc(T1, Stride);
      Inc(T2, Stride * 2);
      Inc(T3, Stride * 3);
      F[0].Real := F[0].Real + S3.Real;
      F[0].Imaginary := F[0].Imaginary + S3.Imaginary;
      F[M].Real := S5.Real + S4.Imaginary;
      F[M].Imaginary := S5.Imaginary - S4.Real;
      F[3 * M].Real := S5.Real - S4.Imaginary;
      F[3 * M].Imaginary := S5.Imaginary + S4.Real;
      Inc(F);
    end;
  end;
end;

procedure Butterfly3(Output: POpusComplex; Stride: Integer; const Fft: TOpusFft; M, Count, MM: Integer);
var
  Index, K: Integer;
  S0, S1, S2, S3: TOpusComplex;
  Epi3: TOpusComplex;
  Start, F: POpusComplex;
  T1, T2: Integer;
begin
  Epi3 := Fft.Twiddles[Stride * M];
  Start := Output;
  for Index := 0 to Count - 1 do
  begin
    F := Start + Index * MM;
    T1 := 0;
    T2 := 0;
    for K := 0 to M - 1 do
    begin
      ComplexMultiply(S1, F[M], Fft.Twiddles[T1]);
      ComplexMultiply(S2, F[2 * M], Fft.Twiddles[T2]);
      S3.Real := S1.Real + S2.Real;
      S3.Imaginary := S1.Imaginary + S2.Imaginary;
      S0.Real := S1.Real - S2.Real;
      S0.Imaginary := S1.Imaginary - S2.Imaginary;
      Inc(T1, Stride);
      Inc(T2, Stride * 2);
      F[M].Real := F[0].Real - S3.Real * 0.5;
      F[M].Imaginary := F[0].Imaginary - S3.Imaginary * 0.5;
      S0.Real := S0.Real * Epi3.Imaginary;
      S0.Imaginary := S0.Imaginary * Epi3.Imaginary;
      F[0].Real := F[0].Real + S3.Real;
      F[0].Imaginary := F[0].Imaginary + S3.Imaginary;
      F[2 * M].Real := F[M].Real + S0.Imaginary;
      F[2 * M].Imaginary := F[M].Imaginary - S0.Real;
      F[M].Real := F[M].Real - S0.Imaginary;
      F[M].Imaginary := F[M].Imaginary + S0.Real;
      Inc(F);
    end;
  end;
end;

procedure Butterfly5(Output: POpusComplex; Stride: Integer; const Fft: TOpusFft; M, Count, MM: Integer);
var
  Index, U: Integer;
  S: array[0..12] of TOpusComplex;
  Ya, Yb: TOpusComplex;
  Start, F0, F1, F2, F3, F4: POpusComplex;
begin
  Ya := Fft.Twiddles[Stride * M];
  Yb := Fft.Twiddles[Stride * 2 * M];
  Start := Output;
  for Index := 0 to Count - 1 do
  begin
    F0 := Start + Index * MM;
    F1 := F0 + M;
    F2 := F0 + 2 * M;
    F3 := F0 + 3 * M;
    F4 := F0 + 4 * M;
    for U := 0 to M - 1 do
    begin
      S[0] := F0^;
      ComplexMultiply(S[1], F1^, Fft.Twiddles[U * Stride]);
      ComplexMultiply(S[2], F2^, Fft.Twiddles[2 * U * Stride]);
      ComplexMultiply(S[3], F3^, Fft.Twiddles[3 * U * Stride]);
      ComplexMultiply(S[4], F4^, Fft.Twiddles[4 * U * Stride]);
      S[7].Real := S[1].Real + S[4].Real;
      S[7].Imaginary := S[1].Imaginary + S[4].Imaginary;
      S[10].Real := S[1].Real - S[4].Real;
      S[10].Imaginary := S[1].Imaginary - S[4].Imaginary;
      S[8].Real := S[2].Real + S[3].Real;
      S[8].Imaginary := S[2].Imaginary + S[3].Imaginary;
      S[9].Real := S[2].Real - S[3].Real;
      S[9].Imaginary := S[2].Imaginary - S[3].Imaginary;
      F0^.Real := F0^.Real + (S[7].Real + S[8].Real);
      F0^.Imaginary := F0^.Imaginary + (S[7].Imaginary + S[8].Imaginary);
      S[5].Real := S[0].Real + (S[7].Real * Ya.Real + S[8].Real * Yb.Real);
      S[5].Imaginary := S[0].Imaginary + (S[7].Imaginary * Ya.Real + S[8].Imaginary * Yb.Real);
      S[6].Real := S[10].Imaginary * Ya.Imaginary + S[9].Imaginary * Yb.Imaginary;
      S[6].Imaginary := -(S[10].Real * Ya.Imaginary + S[9].Real * Yb.Imaginary);
      F1^.Real := S[5].Real - S[6].Real;
      F1^.Imaginary := S[5].Imaginary - S[6].Imaginary;
      F4^.Real := S[5].Real + S[6].Real;
      F4^.Imaginary := S[5].Imaginary + S[6].Imaginary;
      S[11].Real := S[0].Real + (S[7].Real * Yb.Real + S[8].Real * Ya.Real);
      S[11].Imaginary := S[0].Imaginary + (S[7].Imaginary * Yb.Real + S[8].Imaginary * Ya.Real);
      S[12].Real := S[9].Imaginary * Ya.Imaginary - S[10].Imaginary * Yb.Imaginary;
      S[12].Imaginary := S[10].Real * Yb.Imaginary - S[9].Real * Ya.Imaginary;
      F2^.Real := S[11].Real + S[12].Real;
      F2^.Imaginary := S[11].Imaginary + S[12].Imaginary;
      F3^.Real := S[11].Real - S[12].Real;
      F3^.Imaginary := S[11].Imaginary - S[12].Imaginary;
      Inc(F0);
      Inc(F1);
      Inc(F2);
      Inc(F3);
      Inc(F4);
    end;
  end;
end;

procedure OpusFftInPlace(const Fft: TOpusFft; Data: POpusComplex);
var
  Strides: array[0..8] of Integer;
  Stages, Index, M, M2, Radix: Integer;
begin
  Strides[0] := 1;
  Stages := 0;
  repeat
    Radix := Fft.Factors[2 * Stages];
    M := Fft.Factors[2 * Stages + 1];
    Strides[Stages + 1] := Strides[Stages] * Radix;
    Inc(Stages);
  until M = 1;
  M := Fft.Factors[2 * Stages - 1];
  Index := Stages - 1;
  while Index >= 0 do
  begin
    if Index <> 0 then
      M2 := Fft.Factors[2 * Index - 1]
    else
      M2 := 1;
    case Fft.Factors[2 * Index] of
      2: Butterfly2(Data, Strides[Index]);
      4: Butterfly4(Data, Strides[Index], Fft, M, Strides[Index], M2);
      3: Butterfly3(Data, Strides[Index], Fft, M, Strides[Index], M2);
      5: Butterfly5(Data, Strides[Index], Fft, M, Strides[Index], M2);
    end;
    M := M2;
    Dec(Index);
  end;
end;

constructor TCeltMdct.Create(Size, MaximumShift, Overlap: Integer);
var
  Shift, Index, Half, Offset, Length: Integer;
  Value: Double;
begin
  inherited Create;
  FSize := Size;
  FMaximumShift := MaximumShift;
  FOverlap := Overlap;
  for Shift := 0 to MaximumShift do
    InitOpusFft(FFfts[Shift], (Size shr 2) shr Shift);
  SetLength(FTrig, Size - ((Size shr 1) shr MaximumShift));
  Offset := 0;
  Length := Size;
  for Shift := 0 to MaximumShift do
  begin
    Half := Length shr 1;
    for Index := 0 to Half - 1 do
      FTrig[Offset + Index] := Cos(2 * Pi * (Index + 0.125) / Length);
    Inc(Offset, Half);
    Length := Length shr 1;
  end;
  SetLength(FWindow, Overlap);
  for Index := 0 to Overlap - 1 do
  begin
    Value := Sin(0.5 * Pi * (Index + 0.5) / Overlap);
    FWindow[Index] := Sin(0.5 * Pi * Value * Value);
  end;
end;

function TCeltMdct.WindowValue(Index: Integer): Single;
begin
  Result := FWindow[Index];
end;

function TCeltMdct.WindowData: PSingle;
begin
  Result := @FWindow[0];
end;

procedure TCeltMdct.Backward(Input: PSingle; Output: PSingle; Shift, Stride: Integer);
var
  N, N2, N4, Index, Reversed: Integer;
  Trig: PSingle;
  X1, X2, Y: PSingle;
  Y0, Y1: PSingle;
  Re, Im, YR, YI, T0, T1: Single;
  WindowStart, WindowEnd: PSingle;
  Value1, Value2: Single;
  Mirror1, Mirror2: PSingle;
begin
  N := FSize;
  Trig := @FTrig[0];
  for Index := 0 to Shift - 1 do
  begin
    N := N shr 1;
    Inc(Trig, N);
  end;
  N2 := N shr 1;
  N4 := N shr 2;
  { Pre-rotation, stored in bit-reversed order. }
  X1 := Input;
  X2 := Input + Stride * (N2 - 1);
  Y := Output + (FOverlap shr 1);
  for Index := 0 to N4 - 1 do
  begin
    Reversed := FFfts[Shift].BitReverse[Index];
    YR := X2^ * Trig[Index] + X1^ * Trig[N4 + Index];
    YI := X1^ * Trig[Index] - X2^ * Trig[N4 + Index];
    Y[2 * Reversed + 1] := YR;
    Y[2 * Reversed] := YI;
    Inc(X1, 2 * Stride);
    Dec(X2, 2 * Stride);
  end;
  OpusFftInPlace(FFfts[Shift], POpusComplex(Output + (FOverlap shr 1)));
  { Post-rotation from both ends at once. }
  Y0 := Output + (FOverlap shr 1);
  Y1 := Output + (FOverlap shr 1) + N2 - 2;
  for Index := 0 to ((N4 + 1) shr 1) - 1 do
  begin
    Re := Y0[1];
    Im := Y0[0];
    T0 := Trig[Index];
    T1 := Trig[N4 + Index];
    YR := Re * T0 + Im * T1;
    YI := Re * T1 - Im * T0;
    Re := Y1[1];
    Im := Y1[0];
    Y0[0] := YR;
    Y1[1] := YI;
    T0 := Trig[N4 - Index - 1];
    T1 := Trig[N2 - Index - 1];
    YR := Re * T0 + Im * T1;
    YI := Re * T1 - Im * T0;
    Y1[0] := YR;
    Y0[1] := YI;
    Inc(Y0, 2);
    Dec(Y1, 2);
  end;
  { Mirror on both sides for TDAC. }
  Mirror1 := Output + FOverlap - 1;
  Mirror2 := Output;
  WindowStart := @FWindow[0];
  WindowEnd := @FWindow[FOverlap - 1];
  for Index := 0 to FOverlap div 2 - 1 do
  begin
    Value1 := Mirror1^;
    Value2 := Mirror2^;
    Mirror2^ := WindowEnd^ * Value2 - WindowStart^ * Value1;
    Mirror1^ := WindowStart^ * Value2 + WindowEnd^ * Value1;
    Inc(Mirror2);
    Dec(Mirror1);
    Inc(WindowStart);
    Dec(WindowEnd);
  end;
end;

end.
