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
  Warped motion (specification sections 7.11.3.5 to 7.11.3.8): the block
  warp process (an 8x8 piece of a prediction through an affine model,
  with the Warped_Filters), the setup shear process, the resolve divisor
  process and the warp estimation process (the local warp model fitted
  by least squares to the samples find_warp_samples collected).
}
unit Av1.Warp;

{$mode objfpc}

interface

uses
  Av1.Common, Av1.Constants, Av1.Tables, Av1.Picture, Av1.TileContext;

type
  TWarpParams = array[0..5] of Integer;

{ The setup shear process: Valid and the shears Alpha, Beta, Gamma, Delta. }
procedure SetupShear(const WarpParams: array of Integer; out Valid: Boolean;
  out Alpha, Beta, Gamma, Delta: Integer);
{ The resolve divisor process for D (not 0). }
procedure ResolveDivisor(D: Int64; out DivShift: Integer; out DivFactor: Int64);
{ The warp estimation process: Tile.LocalWarpParams and Tile.LocalValid. }
procedure EstimateWarp(Tile: TTileContext);
{ The block warp process: the 8x8 piece (I8, J8) of the W by H prediction
  at (X, Y) of Plane, from Reference (LastX, LastY its last sample),
  into Pred (PredStride values per row). }
procedure WarpBlock(Tile: TTileContext; const WarpParams: array of Integer; Plane: Integer;
  Reference: TPicture; LastX, LastY, X, Y, I8, J8, W, H: Integer; Pred: PInteger; PredStride: Integer);

implementation

procedure ResolveDivisor(D: Int64; out DivShift: Integer; out DivFactor: Int64);
var
  N: Integer;
  Magnitude, E, F: Int64;
begin
  Magnitude := Abs(D);
  N := 0;
  while (Magnitude shr (N + 1)) <> 0 do
    Inc(N);
  E := Magnitude - (Int64(1) shl N);
  if N > DIV_LUT_BITS then
    F := Round2Int64(E, N - DIV_LUT_BITS)
  else
    F := E shl (DIV_LUT_BITS - N);
  DivShift := N + DIV_LUT_PREC_BITS;
  if D < 0 then
    DivFactor := -Int64(Div_Lut[F])
  else
    DivFactor := Div_Lut[F];
end;

{ Round2Signed for shifts the 64-bit arithmetic cannot take. }
function Round2SignedWide(Value: Int64; Bits: Integer): Int64;
begin
  if Bits >= 63 then
    Result := 0
  else
    Result := Round2SignedInt64(Value, Bits);
end;

{ Clip3( -32768, 32767, value ) of a 64-bit value. }
function ClipToShear(Value: Int64): Integer;
begin
  if Value < -32768 then
    Result := -32768
  else if Value > 32767 then
    Result := 32767
  else
    Result := Value;
end;

procedure SetupShear(const WarpParams: array of Integer; out Valid: Boolean;
  out Alpha, Beta, Gamma, Delta: Integer);
var
  Alpha0, Beta0, Gamma0, Delta0, DivShift: Integer;
  DivFactor, V, W: Int64;
begin
  Alpha0 := Clip3(-32768, 32767, WarpParams[2] - (1 shl WARPEDMODEL_PREC_BITS));
  Beta0 := Clip3(-32768, 32767, WarpParams[3]);
  ResolveDivisor(WarpParams[2], DivShift, DivFactor);
  V := Int64(WarpParams[4]) shl WARPEDMODEL_PREC_BITS;
  Gamma0 := ClipToShear(Round2SignedWide(V * DivFactor, DivShift));
  W := Int64(WarpParams[3]) * WarpParams[4];
  Delta0 := ClipToShear(WarpParams[5] - Round2SignedWide(W * DivFactor, DivShift)
    - (1 shl WARPEDMODEL_PREC_BITS));
  Alpha := Round2Signed(Alpha0, WARP_PARAM_REDUCE_BITS) * (1 shl WARP_PARAM_REDUCE_BITS);
  Beta := Round2Signed(Beta0, WARP_PARAM_REDUCE_BITS) * (1 shl WARP_PARAM_REDUCE_BITS);
  Gamma := Round2Signed(Gamma0, WARP_PARAM_REDUCE_BITS) * (1 shl WARP_PARAM_REDUCE_BITS);
  Delta := Round2Signed(Delta0, WARP_PARAM_REDUCE_BITS) * (1 shl WARP_PARAM_REDUCE_BITS);
  Valid := True;
  if 4 * Abs(Alpha) + 7 * Abs(Beta) >= (1 shl WARPEDMODEL_PREC_BITS) then
    Valid := False;
  if 4 * Abs(Gamma) + 4 * Abs(Delta) >= (1 shl WARPEDMODEL_PREC_BITS) then
    Valid := False;
end;

function LeastSquaresProduct(A, B: Integer): Integer; inline;
begin
  Result := SarLongint(A * B, 2) + (A + B);
end;

function DivideNonDiagonal(V, DivFactor: Int64; DivShift: Integer): Integer;
var
  Quotient: Int64;
begin
  Quotient := Round2SignedWide(V * DivFactor, DivShift);
  if Quotient < -WARPEDMODEL_NONDIAGAFFINE_CLAMP + 1 then
    Result := -WARPEDMODEL_NONDIAGAFFINE_CLAMP + 1
  else if Quotient > WARPEDMODEL_NONDIAGAFFINE_CLAMP - 1 then
    Result := WARPEDMODEL_NONDIAGAFFINE_CLAMP - 1
  else
    Result := Quotient;
end;

function DivideDiagonal(V, DivFactor: Int64; DivShift: Integer): Integer;
var
  Quotient: Int64;
begin
  Quotient := Round2SignedWide(V * DivFactor, DivShift);
  if Quotient < (1 shl WARPEDMODEL_PREC_BITS) - WARPEDMODEL_NONDIAGAFFINE_CLAMP + 1 then
    Result := (1 shl WARPEDMODEL_PREC_BITS) - WARPEDMODEL_NONDIAGAFFINE_CLAMP + 1
  else if Quotient > (1 shl WARPEDMODEL_PREC_BITS) + WARPEDMODEL_NONDIAGAFFINE_CLAMP - 1 then
    Result := (1 shl WARPEDMODEL_PREC_BITS) + WARPEDMODEL_NONDIAGAFFINE_CLAMP - 1
  else
    Result := Quotient;
end;

function ClampTranslation(Value: Int64): Integer;
begin
  if Value < -WARPEDMODEL_TRANS_CLAMP then
    Result := -WARPEDMODEL_TRANS_CLAMP
  else if Value > WARPEDMODEL_TRANS_CLAMP - 1 then
    Result := WARPEDMODEL_TRANS_CLAMP - 1
  else
    Result := Value;
end;

procedure EstimateWarp(Tile: TTileContext);
var
  A00, A01, A11, Bx0, Bx1, By0, By1, Det, DivFactor, Vx, Vy: Int64;
  Index, W4, H4, MidY, MidX, Suy, Sux, Duy, Dux, Sy, Sx, Dy, Dx, DivShift: Integer;
  Params: ^TWarpParams;
begin
  A00 := 0;
  A01 := 0;
  A11 := 0;
  Bx0 := 0;
  Bx1 := 0;
  By0 := 0;
  By1 := 0;
  W4 := Num_4x4_Blocks_Wide[Tile.MiSize];
  H4 := Num_4x4_Blocks_High[Tile.MiSize];
  MidY := Tile.MiRow * 4 + H4 * 2 - 1;
  MidX := Tile.MiCol * 4 + W4 * 2 - 1;
  Suy := MidY * 8;
  Sux := MidX * 8;
  Duy := Suy + Tile.Mv[0][0];
  Dux := Sux + Tile.Mv[0][1];
  for Index := 0 to Tile.NumSamples - 1 do
  begin
    Sy := Tile.CandList[Index, 0] - Suy;
    Sx := Tile.CandList[Index, 1] - Sux;
    Dy := Tile.CandList[Index, 2] - Duy;
    Dx := Tile.CandList[Index, 3] - Dux;
    if (Abs(Sx - Dx) < LS_MV_MAX) and (Abs(Sy - Dy) < LS_MV_MAX) then
    begin
      Inc(A00, LeastSquaresProduct(Sx, Sx) + 8);
      Inc(A01, LeastSquaresProduct(Sx, Sy) + 4);
      Inc(A11, LeastSquaresProduct(Sy, Sy) + 8);
      Inc(Bx0, LeastSquaresProduct(Sx, Dx) + 8);
      Inc(Bx1, LeastSquaresProduct(Sy, Dx) + 4);
      Inc(By0, LeastSquaresProduct(Sx, Dy) + 4);
      Inc(By1, LeastSquaresProduct(Sy, Dy) + 8);
    end;
  end;
  Det := A00 * A11 - A01 * A01;
  Tile.LocalValid := Det <> 0;
  if Det = 0 then
    Exit;
  ResolveDivisor(Det, DivShift, DivFactor);
  Dec(DivShift, WARPEDMODEL_PREC_BITS);
  if DivShift < 0 then
  begin
    DivFactor := DivFactor shl (-DivShift);
    DivShift := 0;
  end;
  Params := @Tile.LocalWarpParams;
  Params^[2] := DivideDiagonal(A11 * Bx0 - A01 * Bx1, DivFactor, DivShift);
  Params^[3] := DivideNonDiagonal(-A01 * Bx0 + A00 * Bx1, DivFactor, DivShift);
  Params^[4] := DivideNonDiagonal(A11 * By0 - A01 * By1, DivFactor, DivShift);
  Params^[5] := DivideDiagonal(-A01 * By0 + A00 * By1, DivFactor, DivShift);
  Vx := Int64(Tile.Mv[0][1]) * (1 shl (WARPEDMODEL_PREC_BITS - 3)) -
    (Int64(MidX) * (Params^[2] - (1 shl WARPEDMODEL_PREC_BITS)) + Int64(MidY) * Params^[3]);
  Vy := Int64(Tile.Mv[0][0]) * (1 shl (WARPEDMODEL_PREC_BITS - 3)) -
    (Int64(MidX) * Params^[4] + Int64(MidY) * (Params^[5] - (1 shl WARPEDMODEL_PREC_BITS)));
  Params^[0] := ClampTranslation(Vx);
  Params^[1] := ClampTranslation(Vy);
end;

procedure WarpBlock(Tile: TTileContext; const WarpParams: array of Integer; Plane: Integer;
  Reference: TPicture; LastX, LastY, X, Y, I8, J8, W, H: Integer; Pred: PInteger; PredStride: Integer);
var
  Intermediate: array[0..14, 0..7] of Integer;
  SubX, SubY, SourceX, SourceY, Ix4, Sx4, Iy4, Sy4: Integer;
  Alpha, Beta, Gamma, Delta, I1, I2, I3, Sx, Sy, Offset, Sum, SampleRow, Round0, Round1: Integer;
  RowLimit, ColumnLimit, BaseColumn: Integer;
  Valid, Inside: Boolean;
  DestinationX, DestinationY, X4, Y4: Int64;
  Samples, SourceRow: PWord;
  Stride: Integer;
  Taps: PShortInt;
  Output: PInteger;
begin
  SubX := Tile.SubsamplingX(Plane);
  SubY := Tile.SubsamplingY(Plane);
  Round0 := Tile.InterRound0;
  Round1 := Tile.InterRound1;
  SourceX := (X + J8 * 8 + 4) shl SubX;
  SourceY := (Y + I8 * 8 + 4) shl SubY;
  DestinationX := Int64(WarpParams[2]) * SourceX + Int64(WarpParams[3]) * SourceY + WarpParams[0];
  DestinationY := Int64(WarpParams[4]) * SourceX + Int64(WarpParams[5]) * SourceY + WarpParams[1];
  SetupShear(WarpParams, Valid, Alpha, Beta, Gamma, Delta);
  X4 := SarInt64(DestinationX, SubX);
  Y4 := SarInt64(DestinationY, SubY);
  Ix4 := SarInt64(X4, WARPEDMODEL_PREC_BITS);
  Sx4 := X4 and ((1 shl WARPEDMODEL_PREC_BITS) - 1);
  Iy4 := SarInt64(Y4, WARPEDMODEL_PREC_BITS);
  Sy4 := Y4 and ((1 shl WARPEDMODEL_PREC_BITS) - 1);
  Samples := @Reference.Planes[Plane].Samples[0];
  Stride := Reference.Planes[Plane].Stride;
  Inside := (Iy4 - 7 >= 0) and (Iy4 + 7 <= LastY) and (Ix4 - 7 >= 0) and (Ix4 + 7 <= LastX);
  for I1 := -7 to 7 do
  begin
    if Inside then
      SampleRow := Iy4 + I1
    else
      SampleRow := Clip3(0, LastY, Iy4 + I1);
    SourceRow := Samples + SampleRow * Stride;
    for I2 := -4 to 3 do
    begin
      Sx := Sx4 + Alpha * I2 + Beta * I1;
      Offset := Round2(Sx, WARPEDDIFF_PREC_BITS) + WARPEDPIXEL_PREC_SHIFTS;
      Taps := @Warped_Filters[Offset, 0];
      BaseColumn := Ix4 + I2 - 3;
      Sum := 0;
      if Inside then
        for I3 := 0 to 7 do
          Sum := Sum + Taps[I3] * SourceRow[BaseColumn + I3]
      else
        for I3 := 0 to 7 do
          Sum := Sum + Taps[I3] * SourceRow[Clip3(0, LastX, BaseColumn + I3)];
      Intermediate[I1 + 7, I2 + 4] := Round2(Sum, Round0);
    end;
  end;
  RowLimit := Min(4, H - I8 * 8 - 4);
  ColumnLimit := Min(4, W - J8 * 8 - 4);
  for I1 := -4 to RowLimit - 1 do
  begin
    Output := Pred + (I8 * 8 + I1 + 4) * PredStride + J8 * 8 + 4;
    for I2 := -4 to ColumnLimit - 1 do
    begin
      Sy := Sy4 + Gamma * I2 + Delta * I1;
      Offset := Round2(Sy, WARPEDDIFF_PREC_BITS) + WARPEDPIXEL_PREC_SHIFTS;
      Taps := @Warped_Filters[Offset, 0];
      Sum := 0;
      for I3 := 0 to 7 do
        Sum := Sum + Taps[I3] * Intermediate[I1 + I3 + 4, I2 + 4];
      Output[I2] := Round2(Sum, Round1);
    end;
  end;
end;

end.
