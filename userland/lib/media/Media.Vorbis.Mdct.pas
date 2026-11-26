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
}

{
  The inverse MDCT of Vorbis (specification section 1.3.2, unscaled):

    y[n] = sum over k < N/2 of X[k] cos(2 pi / N (n + 1/2 + N/4)(k + 1/2))

  for n < N. It is the DCT-IV of size M = N/2 unfolded with its
  symmetries (with u the DCT-IV of X):
    y[n] =  u[n + M/2]            for n < M/2
    y[n] = -u[3M/2 - 1 - n]       for M/2 <= n < 3M/2
    y[n] = -u[n - 3M/2]           for 3M/2 <= n < 2M
  and the DCT-IV is one complex FFT of size M/2: the inputs paired as
  x[2n] + i x[M-1-2n] are turned by exp(-i pi (4n+1) / 4M), transformed,
  and turned by exp(-i pi k / M); the real parts are u[2k] and the
  negated imaginary parts u[M-1-2k].

  The FFT is radix 2, in place, with precomputed twiddles; all the work
  is in double precision.
}
unit Media.Vorbis.Mdct;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

uses
  SysUtils;

type
  TVorbisMdct = class
  private
    FSize: Integer;
    FFftSize: Integer;
    FPreCos, FPreSin, FPostCos, FPostSin: array of Double;
    FTwiddleCos, FTwiddleSin: array of Double;
    FBitReverse: array of Integer;
    FReal, FImaginary: array of Double;
    FDct: array of Double;
    procedure Fft;
  public
    { Size is N, the block size (a power of two, 64 or more). }
    constructor Create(Size: Integer);
    { N/2 coefficients at Input to N samples at Output. }
    procedure Inverse(Input: PSingle; Output: PSingle);
    property Size: Integer read FSize;
  end;

implementation

constructor TVorbisMdct.Create(Size: Integer);
var
  Half, Index, Bits, Reversed, Value, Bit: Integer;
  Angle: Double;
begin
  inherited Create;
  FSize := Size;
  Half := Size div 2;
  FFftSize := Size div 4;
  SetLength(FPreCos, FFftSize);
  SetLength(FPreSin, FFftSize);
  SetLength(FPostCos, FFftSize);
  SetLength(FPostSin, FFftSize);
  for Index := 0 to FFftSize - 1 do
  begin
    Angle := -Pi * (4 * Index + 1) / (4 * Half);
    FPreCos[Index] := Cos(Angle);
    FPreSin[Index] := Sin(Angle);
    Angle := -Pi * Index / Half;
    FPostCos[Index] := Cos(Angle);
    FPostSin[Index] := Sin(Angle);
  end;
  SetLength(FTwiddleCos, FFftSize div 2 + 1);
  SetLength(FTwiddleSin, FFftSize div 2 + 1);
  for Index := 0 to FFftSize div 2 do
  begin
    Angle := -2 * Pi * Index / FFftSize;
    FTwiddleCos[Index] := Cos(Angle);
    FTwiddleSin[Index] := Sin(Angle);
  end;
  Bits := 0;
  while (1 shl Bits) < FFftSize do
    Inc(Bits);
  SetLength(FBitReverse, FFftSize);
  for Index := 0 to FFftSize - 1 do
  begin
    Reversed := 0;
    Value := Index;
    for Bit := 1 to Bits do
    begin
      Reversed := (Reversed shl 1) or (Value and 1);
      Value := Value shr 1;
    end;
    FBitReverse[Index] := Reversed;
  end;
  SetLength(FReal, FFftSize);
  SetLength(FImaginary, FFftSize);
  SetLength(FDct, Half);
end;

procedure TVorbisMdct.Fft;
var
  Index, Partner, Span, Start, Pair, TwiddleStep, TwiddleIndex: Integer;
  Swap, TwiddleReal, TwiddleImaginary, ProductReal, ProductImaginary: Double;
begin
  for Index := 0 to FFftSize - 1 do
  begin
    Partner := FBitReverse[Index];
    if Partner > Index then
    begin
      Swap := FReal[Index];
      FReal[Index] := FReal[Partner];
      FReal[Partner] := Swap;
      Swap := FImaginary[Index];
      FImaginary[Index] := FImaginary[Partner];
      FImaginary[Partner] := Swap;
    end;
  end;
  Span := 1;
  while Span < FFftSize do
  begin
    TwiddleStep := FFftSize div (2 * Span);
    Start := 0;
    while Start < FFftSize do
    begin
      TwiddleIndex := 0;
      for Pair := Start to Start + Span - 1 do
      begin
        TwiddleReal := FTwiddleCos[TwiddleIndex];
        TwiddleImaginary := FTwiddleSin[TwiddleIndex];
        Partner := Pair + Span;
        ProductReal := FReal[Partner] * TwiddleReal - FImaginary[Partner] * TwiddleImaginary;
        ProductImaginary := FReal[Partner] * TwiddleImaginary + FImaginary[Partner] * TwiddleReal;
        FReal[Partner] := FReal[Pair] - ProductReal;
        FImaginary[Partner] := FImaginary[Pair] - ProductImaginary;
        FReal[Pair] := FReal[Pair] + ProductReal;
        FImaginary[Pair] := FImaginary[Pair] + ProductImaginary;
        Inc(TwiddleIndex, TwiddleStep);
      end;
      Inc(Start, 2 * Span);
    end;
    Span := Span * 2;
  end;
end;

procedure TVorbisMdct.Inverse(Input: PSingle; Output: PSingle);
var
  Half, Quarter, Index: Integer;
  InputReal, InputImaginary, ResultReal, ResultImaginary: Double;
begin
  Half := FSize div 2;
  Quarter := Half div 2;
  for Index := 0 to FFftSize - 1 do
  begin
    InputReal := Input[2 * Index];
    InputImaginary := Input[Half - 1 - 2 * Index];
    FReal[Index] := InputReal * FPreCos[Index] - InputImaginary * FPreSin[Index];
    FImaginary[Index] := InputReal * FPreSin[Index] + InputImaginary * FPreCos[Index];
  end;
  Fft;
  for Index := 0 to FFftSize - 1 do
  begin
    ResultReal := FReal[Index] * FPostCos[Index] - FImaginary[Index] * FPostSin[Index];
    ResultImaginary := FReal[Index] * FPostSin[Index] + FImaginary[Index] * FPostCos[Index];
    FDct[2 * Index] := ResultReal;
    FDct[Half - 1 - 2 * Index] := -ResultImaginary;
  end;
  for Index := 0 to Quarter - 1 do
    Output[Index] := FDct[Index + Quarter];
  for Index := Quarter to 3 * Quarter - 1 do
    Output[Index] := -FDct[3 * Quarter - 1 - Index];
  for Index := 3 * Quarter to FSize - 1 do
    Output[Index] := -FDct[Index - 3 * Quarter];
end;

end.
