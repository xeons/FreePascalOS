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
  JPEG XL's colour transforms back to RGB (ISO/IEC 18181-1 annex
  L.2 and L.3).

  XYB: X and Y give the L and M "gamma" values (Y + X and Y - X), B the
  S one; each, less the cube root of its bias, is cubed and the bias
  added, and the inverse opsin matrix (scaled so the intensity target
  is 1.0) turns them into linear sRGB, which the sRGB transfer function
  encodes (negative values keep their sign). For a grey image the three
  channels are its luminance.

  YCbCr (from recompressed JPEG files): JPEG's conversion, the planes
  holding Cb, Y and Cr with Y offset by 128/255.
}
unit Image.Jxl.Xyb;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

uses
  SysUtils,
  Math,
  Image.Jxl.Planes,
  Image.Jxl.Headers;

{ Planes 0 to 2 (X, Y, B) become non-linear sRGB red, green and blue. }
procedure ConvertJxlXybToSrgb(const Planes: TJxlPlaneSet; const Transform: TJxlTransformData;
  IntensityTarget: Single; Grey: Boolean = False);
{ Planes 0 to 2 (Cb, Y, Cr) become red, green and blue. }
procedure ConvertJxlYCbCrToRgb(const Planes: TJxlPlaneSet);
{ The sRGB transfer function of a linear value (odd: sign kept). }
function JxlLinearToSrgb(Value: Single): Single;

implementation

function JxlLinearToSrgb(Value: Single): Single;
var
  Magnitude: Single;
begin
  Magnitude := Abs(Value);
  if Magnitude <= 0.0031308 then
    Magnitude := Magnitude * 12.92
  else
    Magnitude := 1.055 * Power(Magnitude, 1 / 2.4) - 0.055;
  if Value < 0 then
    Result := -Magnitude
  else
    Result := Magnitude;
end;

function CubeRoot(Value: Single): Single;
begin
  if Value < 0 then
    Result := -Power(-Value, 1 / 3)
  else if Value = 0 then
    Result := 0
  else
    Result := Power(Value, 1 / 3);
end;

procedure ConvertJxlXybToSrgb(const Planes: TJxlPlaneSet; const Transform: TJxlTransformData;
  IntensityTarget: Single; Grey: Boolean);
var
  Matrix: array[0..2, 0..2] of Single;
  Biases: array[0..2] of Single;
  BiasRoots: array[0..2] of Single;
  Row: LongInt;
  Column: LongInt;
  Index: PtrInt;
  Count: PtrInt;
  PlaneX: PSingle;
  PlaneY: PSingle;
  PlaneB: PSingle;
  GammaR: Single;
  GammaG: Single;
  GammaB: Single;
  MixedR: Single;
  MixedG: Single;
  MixedB: Single;
  Red: Single;
  Green: Single;
  Blue: Single;
  Luminance: Single;
begin
  if Length(Planes) < 3 then
    Exit;
  if IntensityTarget <= 0 then
    IntensityTarget := 255;
  for Row := 0 to 2 do
  begin
    for Column := 0 to 2 do
      Matrix[Row, Column] := Transform.InverseOpsinMatrix[Row, Column] * (255.0 / IntensityTarget);
    Biases[Row] := Transform.OpsinBiases[Row];
    BiasRoots[Row] := CubeRoot(Biases[Row]);
  end;
  Count := PtrInt(Planes[0].Width) * Planes[0].Height;
  PlaneX := Planes[0].Row(0);
  PlaneY := Planes[1].Row(0);
  PlaneB := Planes[2].Row(0);
  for Index := 0 to Count - 1 do
  begin
    GammaR := (PlaneY[Index] + PlaneX[Index]) - BiasRoots[0];
    GammaG := (PlaneY[Index] - PlaneX[Index]) - BiasRoots[1];
    GammaB := PlaneB[Index] - BiasRoots[2];
    MixedR := GammaR * GammaR * GammaR + Biases[0];
    MixedG := GammaG * GammaG * GammaG + Biases[1];
    MixedB := GammaB * GammaB * GammaB + Biases[2];
    Red := Matrix[0, 0] * MixedR + Matrix[0, 1] * MixedG + Matrix[0, 2] * MixedB;
    Green := Matrix[1, 0] * MixedR + Matrix[1, 1] * MixedG + Matrix[1, 2] * MixedB;
    Blue := Matrix[2, 0] * MixedR + Matrix[2, 1] * MixedG + Matrix[2, 2] * MixedB;
    if Grey then
    begin
      Luminance := JxlLinearToSrgb(0.2126 * Red + 0.7152 * Green + 0.0722 * Blue);
      PlaneX[Index] := Luminance;
      PlaneY[Index] := Luminance;
      PlaneB[Index] := Luminance;
    end
    else
    begin
      PlaneX[Index] := JxlLinearToSrgb(Red);
      PlaneY[Index] := JxlLinearToSrgb(Green);
      PlaneB[Index] := JxlLinearToSrgb(Blue);
    end;
  end;
end;

procedure ConvertJxlYCbCrToRgb(const Planes: TJxlPlaneSet);
const
  Offset = 128.0 / 255;
  RedFromCr = 1.402;
  GreenFromCb = -0.114 * 1.772 / 0.587;
  GreenFromCr = -0.299 * 1.402 / 0.587;
  BlueFromCb = 1.772;
var
  Index: PtrInt;
  Count: PtrInt;
  PlaneCb: PSingle;
  PlaneY: PSingle;
  PlaneCr: PSingle;
  Luma: Single;
  Cb: Single;
  Cr: Single;
begin
  if Length(Planes) < 3 then
    Exit;
  Count := PtrInt(Planes[0].Width) * Planes[0].Height;
  PlaneCb := Planes[0].Row(0);
  PlaneY := Planes[1].Row(0);
  PlaneCr := Planes[2].Row(0);
  for Index := 0 to Count - 1 do
  begin
    Luma := PlaneY[Index] + Offset;
    Cb := PlaneCb[Index];
    Cr := PlaneCr[Index];
    PlaneCb[Index] := RedFromCr * Cr + Luma;
    PlaneY[Index] := GreenFromCr * Cr + (GreenFromCb * Cb + Luma);
    PlaneCr[Index] := BlueFromCb * Cb + Luma;
  end;
end;

end.
