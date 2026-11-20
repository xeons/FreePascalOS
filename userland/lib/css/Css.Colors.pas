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
  Colors (CSS Color Module Level 4 and 5): color spaces and the
  conversions between them (through CIE XYZ, with the matrices of the
  spec's sample code), the named and system colors, serialization, and
  color-mix() interpolation.

  A color keeps the space it was written in (sRGB for the legacy
  forms: names, hex, rgb(), hsl(), hwb()); conversion to sRGB for
  drawing clips to the gamut.
}
unit Css.Colors;

{$mode objfpc}
{$H+}

interface

uses
  Css.Keywords;

type
  TCssColorSpace = (csSrgb, csSrgbLinear, csDisplayP3, csA98Rgb, csProphotoRgb, csRec2020,
    csXyzD50, csXyzD65, csHsl, csHwb, csLab, csLch, csOklab, csOklch);

  THueInterpolation = (hiShorter, hiLonger, hiIncreasing, hiDecreasing);

  TCssColor = record
    Space: TCssColorSpace;
    Components: array[0..2] of Double;
    Alpha: Double;
    { Components given as 'none' (bit 3 is the alpha). }
    MissingMask: Byte;
    { Written in a legacy sRGB form: serialized as rgb()/rgba(). }
    Legacy: Boolean;
  end;

  TColorTriple = array[0..2] of Double;

  { 8 bit sRGB with alpha, what drawing uses. }
  TCssRgba8 = packed record
    Red, Green, Blue, Alpha: Byte;
  end;

function MakeRgbColor(Red, Green, Blue, Alpha: Double): TCssColor;
function MakeColor(Space: TCssColorSpace; C0, C1, C2, Alpha: Double): TCssColor;
function TransparentColor: TCssColor;
{ The color converted to Space (missing components as zero). }
function ConvertColor(const Color: TCssColor; Space: TCssColorSpace): TCssColor;
{ sRGB components 0..1, clipped, and alpha. }
procedure ColorToSrgb(const Color: TCssColor; out Red, Green, Blue, Alpha: Double);
function ColorToRgba8(const Color: TCssColor): TCssRgba8;
function SameColor(const A, B: TCssColor): Boolean;

function FindNamedColor(const LowerName: string; out Color: TCssColor): Boolean;
function IsSystemColorKeyword(Keyword: TCssKeyword): Boolean;
{ The system color in the current scheme (SetSystemColor changes them). }
function SystemColor(Keyword: TCssKeyword; Dark: Boolean): TCssColor;
procedure SetSystemColor(Keyword: TCssKeyword; Dark: Boolean; const Color: TCssColor);
function ColorSpaceByKeyword(Keyword: TCssKeyword; out Space: TCssColorSpace): Boolean;
function ColorSpaceName(Space: TCssColorSpace): string;
function IsPolarSpace(Space: TCssColorSpace): Boolean;

{ color-mix(): Weight1 and Weight2 are already normalized to sum 1;
  Scale is the alpha multiplier when the percentages summed below 100%. }
function MixColors(Space: TCssColorSpace; Hue: THueInterpolation; const First: TCssColor;
  Weight1: Double; const Second: TCssColor; Weight2, Scale: Double): TCssColor;

function SerializeColor(const Color: TCssColor): string;

implementation

uses
  Math, SysUtils, Css.Serialization;

type
  TMatrix = array[0..2, 0..2] of Double;

const
  LinearSrgbToXyz: TMatrix = (
    (0.41239079926595934, 0.357584339383878, 0.1804807884018343),
    (0.21263900587151027, 0.715168678767756, 0.07219231536073371),
    (0.01933081871559182, 0.11919477979462598, 0.9505321522496607));
  XyzToLinearSrgb: TMatrix = (
    (3.2409699419045226, -1.537383177570094, -0.4986107602930034),
    (-0.9692436362808796, 1.8759675015077202, 0.04155505740717559),
    (0.05563007969699366, -0.20397695888897652, 1.0569715142428786));
  D65ToD50: TMatrix = (
    (1.0479298208405488, 0.022946793341019088, -0.05019222954313557),
    (0.029627815688159344, 0.990434484573249, -0.01707382502938514),
    (-0.009243058152591178, 0.015055144896577895, 0.7518742899580008));
  D50ToD65: TMatrix = (
    (0.9554734527042182, -0.023098536874261423, 0.0632593086610217),
    (-0.028369706963208136, 1.0099954580058226, 0.021041398966943008),
    (0.012314001688319899, -0.020507696433477912, 1.3303659366080753));
  XyzToLms: TMatrix = (
    (0.8190224379967030, 0.3619062600528904, -0.1288737815209879),
    (0.0329836539323885, 0.9292868615863434, 0.0361446663506424),
    (0.0481771893596242, 0.2642395317527308, 0.6335478284694309));
  LmsToOklab: TMatrix = (
    (0.2104542683093140, 0.7936177747023054, -0.0040720430116193),
    (1.9779985324311684, -2.4285922420485799, 0.4505937096174110),
    (0.0259040424655478, 0.7827717124575296, -0.8086757549230774));
  OklabToLms: TMatrix = (
    (1.0000000000000000, 0.3963377773761749, 0.2158037573099136),
    (1.0000000000000000, -0.1055613458156586, -0.0638541728258133),
    (1.0000000000000000, -0.0894841775298119, -1.2914855480194092));
  LmsToXyz: TMatrix = (
    (1.2268798758459243, -0.5578149944602171, 0.2813910456659647),
    (-0.0405757452148008, 1.1122868032803170, -0.0717110580655164),
    (-0.0763729366746601, -0.4214933324022432, 1.5869240198367816));
  LinearP3ToXyz: TMatrix = (
    (0.4865709486482162, 0.26566769316909306, 0.1982172852343625),
    (0.2289745640697488, 0.6917385218365064, 0.079286914093745),
    (0.0, 0.04511338185890264, 1.043944368900976));
  XyzToLinearP3: TMatrix = (
    (2.493496911941425, -0.9313836179191239, -0.40271078445071684),
    (-0.8294889695615747, 1.7626640603183463, 0.023624685841943577),
    (0.03584583024378447, -0.07617238926804182, 0.9568845240076872));
  LinearA98ToXyz: TMatrix = (
    (0.5766690429101305, 0.1855582379065463, 0.1882286462349947),
    (0.29734497525053605, 0.6273635662554661, 0.07529145849399788),
    (0.02703136138641234, 0.07068885253582723, 0.9913375368376388));
  XyzToLinearA98: TMatrix = (
    (2.0415879038107465, -0.5650069742788596, -0.34473135077832956),
    (-0.9692436362808795, 1.8759675015077202, 0.04155505740717557),
    (0.013444280632031142, -0.11836239223101838, 1.0151749943912054));
  LinearProphotoToXyzD50: TMatrix = (
    (0.7977666449006423, 0.13518129740053308, 0.0313477341283922),
    (0.2880748288194013, 0.711835234241873, 0.00008993693872564),
    (0.0, 0.0, 0.8251046025104602));
  XyzD50ToLinearProphoto: TMatrix = (
    (1.3457868816471583, -0.25557208737979464, -0.05110186497554526),
    (-0.5446307051249019, 1.5082477428451468, 0.02052744743642139),
    (0.0, 0.0, 1.2119675456389452));
  LinearRec2020ToXyz: TMatrix = (
    (0.6369580483012914, 0.14461690358620832, 0.1688809751641721),
    (0.2627002120112671, 0.6779980715188708, 0.05930171646986196),
    (0.0, 0.028072693049087428, 1.060985057710791));
  XyzToLinearRec2020: TMatrix = (
    (1.7166511879712674, -0.35567078377639233, -0.25336628137365974),
    (-0.6666843518324892, 1.6164812366349395, 0.01576854581391113),
    (0.017639857445310783, -0.042770613257808524, 0.9421031212354738));

  { D50 white for Lab. }
  WhiteD50: TColorTriple = (0.3457 / 0.3585, 1.0, (1.0 - 0.3457 - 0.3585) / 0.3585);

function Multiply(const Matrix: TMatrix; const Vector: TColorTriple): TColorTriple;
var
  Row: Integer;
begin
  for Row := 0 to 2 do
    Result[Row] := Matrix[Row, 0] * Vector[0] + Matrix[Row, 1] * Vector[1] + Matrix[Row, 2] * Vector[2];
end;

function SignedPower(Value, Exponent: Double): Double;
begin
  if Value < 0 then
    Result := -Power(-Value, Exponent)
  else if Value = 0 then
    Result := 0
  else
    Result := Power(Value, Exponent);
end;

function SrgbToLinear(Value: Double): Double;
begin
  if Abs(Value) <= 0.04045 then
    Result := Value / 12.92
  else
    Result := SignedPower((Abs(Value) + 0.055) / 1.055, 2.4) * Sign(Value);
end;

function LinearToSrgb(Value: Double): Double;
begin
  if Abs(Value) > 0.0031308 then
    Result := Sign(Value) * (1.055 * Power(Abs(Value), 1 / 2.4) - 0.055)
  else
    Result := 12.92 * Value;
end;

function ProphotoToLinear(Value: Double): Double;
begin
  if Abs(Value) <= 16 / 512 then
    Result := Value / 16
  else
    Result := SignedPower(Abs(Value), 1.8) * Sign(Value);
end;

function LinearToProphoto(Value: Double): Double;
begin
  if Abs(Value) >= 1 / 512 then
    Result := Sign(Value) * Power(Abs(Value), 1 / 1.8)
  else
    Result := 16 * Value;
end;

const
  Rec2020Alpha = 1.09929682680944;
  Rec2020Beta = 0.018053968510807;

function Rec2020ToLinear(Value: Double): Double;
begin
  if Abs(Value) < Rec2020Beta * 4.5 then
    Result := Value / 4.5
  else
    Result := Sign(Value) * Power((Abs(Value) + Rec2020Alpha - 1) / Rec2020Alpha, 1 / 0.45);
end;

function LinearToRec2020(Value: Double): Double;
begin
  if Abs(Value) > Rec2020Beta then
    Result := Sign(Value) * (Rec2020Alpha * Power(Abs(Value), 0.45) - (Rec2020Alpha - 1))
  else
    Result := 4.5 * Value;
end;

function HslToSrgb(Hue, Saturation, Lightness: Double): TColorTriple;
var
  Index: Integer;
  K, A: Double;
const
  Offsets: array[0..2] of Double = (0, 8, 4);
begin
  Hue := Hue - 360 * Floor(Hue / 360);
  Saturation := Saturation / 100;
  Lightness := Lightness / 100;
  A := Saturation * Min(Lightness, 1 - Lightness);
  for Index := 0 to 2 do
  begin
    K := Offsets[Index] + Hue / 30;
    K := K - 12 * Floor(K / 12);
    Result[Index] := Lightness - A * Max(-1, Min(Min(K - 3, 9 - K), 1));
  end;
end;

function SrgbToHsl(Red, Green, Blue: Double): TColorTriple;
var
  Maximum, Minimum, Delta, Hue, Saturation, Lightness: Double;
begin
  Maximum := Max(Red, Max(Green, Blue));
  Minimum := Min(Red, Min(Green, Blue));
  Delta := Maximum - Minimum;
  Lightness := (Minimum + Maximum) / 2;
  Hue := NaN;
  Saturation := 0;
  if Delta <> 0 then
  begin
    if (Lightness = 0) or (Lightness = 1) then
      Saturation := 0
    else
      Saturation := (Maximum - Lightness) / Min(Lightness, 1 - Lightness);
    if Maximum = Red then
      Hue := (Green - Blue) / Delta + IfThen(Green < Blue, 6, 0)
    else if Maximum = Green then
      Hue := (Blue - Red) / Delta + 2
    else
      Hue := (Red - Green) / Delta + 4;
    Hue := Hue * 60;
  end;
  if Saturation < 0 then
  begin
    Hue := Hue + 180;
    Saturation := Abs(Saturation);
  end;
  if not IsNan(Hue) and (Hue >= 360) then
    Hue := Hue - 360;
  Result[0] := Hue;
  Result[1] := Saturation * 100;
  Result[2] := Lightness * 100;
end;

function HwbToSrgb(Hue, Whiteness, Blackness: Double): TColorTriple;
var
  Index: Integer;
  Gray: Double;
begin
  Whiteness := Whiteness / 100;
  Blackness := Blackness / 100;
  if Whiteness + Blackness >= 1 then
  begin
    Gray := Whiteness / (Whiteness + Blackness);
    Result[0] := Gray;
    Result[1] := Gray;
    Result[2] := Gray;
    Exit;
  end;
  Result := HslToSrgb(Hue, 100, 50);
  for Index := 0 to 2 do
    Result[Index] := Result[Index] * (1 - Whiteness - Blackness) + Whiteness;
end;

function SrgbToHwb(Red, Green, Blue: Double): TColorTriple;
var
  Hsl: TColorTriple;
begin
  Hsl := SrgbToHsl(Red, Green, Blue);
  Result[0] := Hsl[0];
  Result[1] := Min(Red, Min(Green, Blue)) * 100;
  Result[2] := (1 - Max(Red, Max(Green, Blue))) * 100;
end;

function LabToXyzD50(const Lab: TColorTriple): TColorTriple;
const
  Kappa = 24389 / 27;
  Epsilon = 216 / 24389;
var
  F0, F1, F2: Double;
  X, Y, Z: Double;
begin
  F1 := (Lab[0] + 16) / 116;
  F0 := Lab[1] / 500 + F1;
  F2 := F1 - Lab[2] / 200;
  if Power(F0, 3) > Epsilon then X := Power(F0, 3) else X := (116 * F0 - 16) / Kappa;
  if Lab[0] > Kappa * Epsilon then Y := Power((Lab[0] + 16) / 116, 3) else Y := Lab[0] / Kappa;
  if Power(F2, 3) > Epsilon then Z := Power(F2, 3) else Z := (116 * F2 - 16) / Kappa;
  Result[0] := X * WhiteD50[0];
  Result[1] := Y * WhiteD50[1];
  Result[2] := Z * WhiteD50[2];
end;

function XyzD50ToLab(const Xyz: TColorTriple): TColorTriple;
const
  Kappa = 24389 / 27;
  Epsilon = 216 / 24389;
var
  F: TColorTriple;
  Index: Integer;
  Scaled: Double;
begin
  for Index := 0 to 2 do
  begin
    Scaled := Xyz[Index] / WhiteD50[Index];
    if Scaled > Epsilon then
      F[Index] := SignedPower(Scaled, 1 / 3)
    else
      F[Index] := (Kappa * Scaled + 16) / 116;
  end;
  Result[0] := 116 * F[1] - 16;
  Result[1] := 500 * (F[0] - F[1]);
  Result[2] := 200 * (F[1] - F[2]);
end;

function PolarToRectangular(const Polar: TColorTriple): TColorTriple;
var
  Hue: Double;
begin
  Hue := Polar[2];
  if IsNan(Hue) then
    Hue := 0;
  Result[0] := Polar[0];
  Result[1] := Polar[1] * Cos(DegToRad(Hue));
  Result[2] := Polar[1] * Sin(DegToRad(Hue));
end;

function RectangularToPolar(const Rectangular: TColorTriple; Epsilon: Double): TColorTriple;
var
  Hue: Double;
begin
  Result[0] := Rectangular[0];
  Result[1] := Sqrt(Sqr(Rectangular[1]) + Sqr(Rectangular[2]));
  Hue := RadToDeg(ArcTan2(Rectangular[2], Rectangular[1]));
  if Hue < 0 then
    Hue := Hue + 360;
  if Result[1] <= Epsilon then
    Hue := NaN;
  Result[2] := Hue;
end;

function OklabToXyz(const Lab: TColorTriple): TColorTriple;
var
  Lms: TColorTriple;
  Index: Integer;
begin
  Lms := Multiply(OklabToLms, Lab);
  for Index := 0 to 2 do
    Lms[Index] := Lms[Index] * Lms[Index] * Lms[Index];
  Result := Multiply(LmsToXyz, Lms);
end;

function XyzToOklab(const Xyz: TColorTriple): TColorTriple;
var
  Lms: TColorTriple;
  Index: Integer;
begin
  Lms := Multiply(XyzToLms, Xyz);
  for Index := 0 to 2 do
    Lms[Index] := SignedPower(Lms[Index], 1 / 3);
  Result := Multiply(LmsToOklab, Lms);
end;

function ApplyEach(const Values: TColorTriple; Transfer: Integer): TColorTriple;
var
  Index: Integer;
begin
  for Index := 0 to 2 do
    case Transfer of
      0: Result[Index] := SrgbToLinear(Values[Index]);
      1: Result[Index] := LinearToSrgb(Values[Index]);
      2: Result[Index] := SignedPower(Values[Index], 563 / 256);
      3: Result[Index] := SignedPower(Values[Index], 256 / 563);
      4: Result[Index] := ProphotoToLinear(Values[Index]);
      5: Result[Index] := LinearToProphoto(Values[Index]);
      6: Result[Index] := Rec2020ToLinear(Values[Index]);
      7: Result[Index] := LinearToRec2020(Values[Index]);
    end;
end;

function Triple(const Color: TCssColor): TColorTriple;
var
  Index: Integer;
begin
  for Index := 0 to 2 do
    if (Color.MissingMask and (1 shl Index)) <> 0 then
      Result[Index] := 0
    else
      Result[Index] := Color.Components[Index];
  { A missing hue is NaN for the polar conversions. }
  if (Color.Space in [csHsl, csHwb]) and ((Color.MissingMask and 1) <> 0) then
    Result[0] := 0;
  if (Color.Space in [csLch, csOklch]) and ((Color.MissingMask and 4) <> 0) then
    Result[2] := 0;
end;

function ToXyzD65(const Color: TCssColor): TColorTriple;
var
  Values: TColorTriple;
begin
  Values := Triple(Color);
  case Color.Space of
    csSrgb: Result := Multiply(LinearSrgbToXyz, ApplyEach(Values, 0));
    csSrgbLinear: Result := Multiply(LinearSrgbToXyz, Values);
    csDisplayP3: Result := Multiply(LinearP3ToXyz, ApplyEach(Values, 0));
    csA98Rgb: Result := Multiply(LinearA98ToXyz, ApplyEach(Values, 2));
    csProphotoRgb: Result := Multiply(D50ToD65, Multiply(LinearProphotoToXyzD50, ApplyEach(Values, 4)));
    csRec2020: Result := Multiply(LinearRec2020ToXyz, ApplyEach(Values, 6));
    csXyzD50: Result := Multiply(D50ToD65, Values);
    csXyzD65: Result := Values;
    csHsl: Result := Multiply(LinearSrgbToXyz, ApplyEach(HslToSrgb(Values[0], Values[1], Values[2]), 0));
    csHwb: Result := Multiply(LinearSrgbToXyz, ApplyEach(HwbToSrgb(Values[0], Values[1], Values[2]), 0));
    csLab: Result := Multiply(D50ToD65, LabToXyzD50(Values));
    csLch: Result := Multiply(D50ToD65, LabToXyzD50(PolarToRectangular(Values)));
    csOklab: Result := OklabToXyz(Values);
    csOklch: Result := OklabToXyz(PolarToRectangular(Values));
  end;
end;

function FromXyzD65(const Xyz: TColorTriple; Space: TCssColorSpace): TColorTriple;
var
  Srgb: TColorTriple;
begin
  case Space of
    csSrgb: Result := ApplyEach(Multiply(XyzToLinearSrgb, Xyz), 1);
    csSrgbLinear: Result := Multiply(XyzToLinearSrgb, Xyz);
    csDisplayP3: Result := ApplyEach(Multiply(XyzToLinearP3, Xyz), 1);
    csA98Rgb: Result := ApplyEach(Multiply(XyzToLinearA98, Xyz), 3);
    csProphotoRgb: Result := ApplyEach(Multiply(XyzD50ToLinearProphoto, Multiply(D65ToD50, Xyz)), 5);
    csRec2020: Result := ApplyEach(Multiply(XyzToLinearRec2020, Xyz), 7);
    csXyzD50: Result := Multiply(D65ToD50, Xyz);
    csXyzD65: Result := Xyz;
    csHsl:
      begin
        Srgb := ApplyEach(Multiply(XyzToLinearSrgb, Xyz), 1);
        Result := SrgbToHsl(Srgb[0], Srgb[1], Srgb[2]);
      end;
    csHwb:
      begin
        Srgb := ApplyEach(Multiply(XyzToLinearSrgb, Xyz), 1);
        Result := SrgbToHwb(Srgb[0], Srgb[1], Srgb[2]);
      end;
    csLab: Result := XyzD50ToLab(Multiply(D65ToD50, Xyz));
    csLch: Result := RectangularToPolar(XyzD50ToLab(Multiply(D65ToD50, Xyz)), 0.0015);
    csOklab: Result := XyzToOklab(Xyz);
    csOklch: Result := RectangularToPolar(XyzToOklab(Xyz), 0.000004);
  end;
end;

function MakeColor(Space: TCssColorSpace; C0, C1, C2, Alpha: Double): TCssColor;
begin
  Result.Space := Space;
  Result.Components[0] := C0;
  Result.Components[1] := C1;
  Result.Components[2] := C2;
  Result.Alpha := Alpha;
  Result.MissingMask := 0;
  Result.Legacy := False;
end;

function MakeRgbColor(Red, Green, Blue, Alpha: Double): TCssColor;
begin
  Result := MakeColor(csSrgb, Red, Green, Blue, Alpha);
  Result.Legacy := True;
end;

function TransparentColor: TCssColor;
begin
  Result := MakeRgbColor(0, 0, 0, 0);
end;

function ConvertColor(const Color: TCssColor; Space: TCssColorSpace): TCssColor;
var
  Values: TColorTriple;
  Index: Integer;
begin
  if Color.Space = Space then
    Exit(Color);
  try
    Values := FromXyzD65(ToXyzD65(Color), Space);
  except
    on EMathError do
      Values := Default(TColorTriple);
  end;
  Result := MakeColor(Space, Values[0], Values[1], Values[2], Color.Alpha);
  for Index := 0 to 2 do
    if IsNan(Result.Components[Index]) then
    begin
      Result.Components[Index] := 0;
      Result.MissingMask := Result.MissingMask or (1 shl Index);
    end;
  if (Color.MissingMask and 8) <> 0 then
    Result.MissingMask := Result.MissingMask or 8;
end;

function Clip01(Value: Double): Double;
begin
  if IsNan(Value) or (Value < 0) then
    Result := 0
  else if Value > 1 then
    Result := 1
  else
    Result := Value;
end;

procedure ColorToSrgb(const Color: TCssColor; out Red, Green, Blue, Alpha: Double);
var
  Srgb: TCssColor;
begin
  Srgb := ConvertColor(Color, csSrgb);
  Red := Clip01(Srgb.Components[0]);
  Green := Clip01(Srgb.Components[1]);
  Blue := Clip01(Srgb.Components[2]);
  if (Color.MissingMask and 8) <> 0 then
    Alpha := 0
  else
    Alpha := Clip01(Color.Alpha);
end;

function ColorToRgba8(const Color: TCssColor): TCssRgba8;
var
  Red, Green, Blue, Alpha: Double;
begin
  ColorToSrgb(Color, Red, Green, Blue, Alpha);
  Result.Red := Round(Red * 255);
  Result.Green := Round(Green * 255);
  Result.Blue := Round(Blue * 255);
  Result.Alpha := Round(Alpha * 255);
end;

function SameColor(const A, B: TCssColor): Boolean;
begin
  Result := (A.Space = B.Space) and (A.Components[0] = B.Components[0]) and
    (A.Components[1] = B.Components[1]) and (A.Components[2] = B.Components[2]) and
    (A.Alpha = B.Alpha) and (A.MissingMask = B.MissingMask) and (A.Legacy = B.Legacy);
end;

{ ---- named and system colors ---- }

const
  NamedColorTable =
    'aliceblue f0f8ff antiquewhite faebd7 aqua 00ffff aquamarine 7fffd4 azure f0ffff ' +
    'beige f5f5dc bisque ffe4c4 black 000000 blanchedalmond ffebcd blue 0000ff ' +
    'blueviolet 8a2be2 brown a52a2a burlywood deb887 cadetblue 5f9ea0 chartreuse 7fff00 ' +
    'chocolate d2691e coral ff7f50 cornflowerblue 6495ed cornsilk fff8dc crimson dc143c ' +
    'cyan 00ffff darkblue 00008b darkcyan 008b8b darkgoldenrod b8860b darkgray a9a9a9 ' +
    'darkgreen 006400 darkgrey a9a9a9 darkkhaki bdb76b darkmagenta 8b008b ' +
    'darkolivegreen 556b2f darkorange ff8c00 darkorchid 9932cc darkred 8b0000 ' +
    'darksalmon e9967a darkseagreen 8fbc8f darkslateblue 483d8b darkslategray 2f4f4f ' +
    'darkslategrey 2f4f4f darkturquoise 00ced1 darkviolet 9400d3 deeppink ff1493 ' +
    'deepskyblue 00bfff dimgray 696969 dimgrey 696969 dodgerblue 1e90ff firebrick b22222 ' +
    'floralwhite fffaf0 forestgreen 228b22 fuchsia ff00ff gainsboro dcdcdc ' +
    'ghostwhite f8f8ff gold ffd700 goldenrod daa520 gray 808080 green 008000 ' +
    'greenyellow adff2f grey 808080 honeydew f0fff0 hotpink ff69b4 indianred cd5c5c ' +
    'indigo 4b0082 ivory fffff0 khaki f0e68c lavender e6e6fa lavenderblush fff0f5 ' +
    'lawngreen 7cfc00 lemonchiffon fffacd lightblue add8e6 lightcoral f08080 ' +
    'lightcyan e0ffff lightgoldenrodyellow fafad2 lightgray d3d3d3 lightgreen 90ee90 ' +
    'lightgrey d3d3d3 lightpink ffb6c1 lightsalmon ffa07a lightseagreen 20b2aa ' +
    'lightskyblue 87cefa lightslategray 778899 lightslategrey 778899 ' +
    'lightsteelblue b0c4de lightyellow ffffe0 lime 00ff00 limegreen 32cd32 linen faf0e6 ' +
    'magenta ff00ff maroon 800000 mediumaquamarine 66cdaa mediumblue 0000cd ' +
    'mediumorchid ba55d3 mediumpurple 9370db mediumseagreen 3cb371 ' +
    'mediumslateblue 7b68ee mediumspringgreen 00fa9a mediumturquoise 48d1cc ' +
    'mediumvioletred c71585 midnightblue 191970 mintcream f5fffa mistyrose ffe4e1 ' +
    'moccasin ffe4b5 navajowhite ffdead navy 000080 oldlace fdf5e6 olive 808000 ' +
    'olivedrab 6b8e23 orange ffa500 orangered ff4500 orchid da70d6 palegoldenrod eee8aa ' +
    'palegreen 98fb98 paleturquoise afeeee palevioletred db7093 papayawhip ffefd5 ' +
    'peachpuff ffdab9 peru cd853f pink ffc0cb plum dda0dd powderblue b0e0e6 ' +
    'purple 800080 rebeccapurple 663399 red ff0000 rosybrown bc8f8f royalblue 4169e1 ' +
    'saddlebrown 8b4513 salmon fa8072 sandybrown f4a460 seagreen 2e8b57 ' +
    'seashell fff5ee sienna a0522d silver c0c0c0 skyblue 87ceeb slateblue 6a5acd ' +
    'slategray 708090 slategrey 708090 snow fffafa springgreen 00ff7f steelblue 4682b4 ' +
    'tan d2b48c teal 008080 thistle d8bfd8 tomato ff6347 turquoise 40e0d0 violet ee82ee ' +
    'wheat f5deb3 white ffffff whitesmoke f5f5f5 yellow ffff00 yellowgreen 9acd32 ';

var
  NamedColorNames: array of string;
  NamedColorValues: array of LongWord;
  SystemColors: array[Boolean, kwCanvas..kwAccentcolortext] of TCssColor;

procedure LoadNamedColors;
var
  Position, Space, Count: Integer;
  Name, Hex: string;
begin
  Count := 0;
  SetLength(NamedColorNames, 160);
  SetLength(NamedColorValues, 160);
  Position := 1;
  while Position < Length(NamedColorTable) do
  begin
    Space := Position;
    while NamedColorTable[Space] <> ' ' do
      Inc(Space);
    Name := Copy(NamedColorTable, Position, Space - Position);
    Hex := Copy(NamedColorTable, Space + 1, 6);
    NamedColorNames[Count] := Name;
    NamedColorValues[Count] := StrToInt('$' + Hex);
    Inc(Count);
    Position := Space + 8;
  end;
  SetLength(NamedColorNames, Count);
  SetLength(NamedColorValues, Count);
end;

function RgbFromHex(Value: LongWord): TCssColor;
begin
  Result := MakeRgbColor(((Value shr 16) and 255) / 255, ((Value shr 8) and 255) / 255,
    (Value and 255) / 255, 1);
end;

function FindNamedColor(const LowerName: string; out Color: TCssColor): Boolean;
var
  Low, High, Middle: Integer;
begin
  Low := 0;
  High := System.High(NamedColorNames);
  while Low <= High do
  begin
    Middle := (Low + High) div 2;
    if NamedColorNames[Middle] = LowerName then
    begin
      Color := RgbFromHex(NamedColorValues[Middle]);
      Exit(True);
    end;
    if NamedColorNames[Middle] < LowerName then
      Low := Middle + 1
    else
      High := Middle - 1;
  end;
  Color := TransparentColor;
  Result := False;
end;

function IsSystemColorKeyword(Keyword: TCssKeyword): Boolean;
begin
  Result := (Keyword >= kwCanvas) and (Keyword <= kwAccentcolortext);
end;

function SystemColor(Keyword: TCssKeyword; Dark: Boolean): TCssColor;
begin
  if IsSystemColorKeyword(Keyword) then
    Result := SystemColors[Dark, Keyword]
  else
    Result := TransparentColor;
end;

procedure SetSystemColor(Keyword: TCssKeyword; Dark: Boolean; const Color: TCssColor);
begin
  if IsSystemColorKeyword(Keyword) then
    SystemColors[Dark, Keyword] := Color;
end;

procedure LoadSystemColors;
  procedure Put(Keyword: TCssKeyword; Light, Dark: LongWord);
  begin
    SystemColors[False, Keyword] := RgbFromHex(Light);
    SystemColors[True, Keyword] := RgbFromHex(Dark);
  end;
begin
  Put(kwCanvas, $FFFFFF, $121212);
  Put(kwCanvastext, $000000, $FFFFFF);
  Put(kwLinktext, $0000EE, $9E9EFF);
  Put(kwVisitedtext, $551A8B, $D0ADF0);
  Put(kwActivetext, $FF0000, $FF6666);
  Put(kwButtonface, $EFEFEF, $6B6B6B);
  Put(kwButtontext, $000000, $FFFFFF);
  Put(kwButtonborder, $767676, $6B6B6B);
  Put(kwField, $FFFFFF, $3B3B3B);
  Put(kwFieldtext, $000000, $FFFFFF);
  Put(kwHighlight, $1F2A6B, $99C8FF);
  Put(kwHighlighttext, $FFFFFF, $000000);
  Put(kwSelecteditem, $1F2A6B, $99C8FF);
  Put(kwSelecteditemtext, $FFFFFF, $000000);
  Put(kwMark, $FFFF00, $FFFF00);
  Put(kwMarktext, $000000, $000000);
  Put(kwGraytext, $808080, $A0A0A0);
  Put(kwAccentcolor, $1F2A6B, $99C8FF);
  Put(kwAccentcolortext, $FFFFFF, $000000);
end;

function ColorSpaceByKeyword(Keyword: TCssKeyword; out Space: TCssColorSpace): Boolean;
begin
  Result := True;
  case Keyword of
    kwSrgb: Space := csSrgb;
    kwSrgbLinear: Space := csSrgbLinear;
    kwDisplayP3: Space := csDisplayP3;
    kwA98Rgb: Space := csA98Rgb;
    kwProphotoRgb: Space := csProphotoRgb;
    kwRec2020: Space := csRec2020;
    kwXyz, kwXyzD65: Space := csXyzD65;
    kwXyzD50: Space := csXyzD50;
    kwHsl: Space := csHsl;
    kwHwb: Space := csHwb;
    kwLab: Space := csLab;
    kwLch: Space := csLch;
    kwOklab: Space := csOklab;
    kwOklch: Space := csOklch;
  else
    Space := csSrgb;
    Result := False;
  end;
end;

function ColorSpaceName(Space: TCssColorSpace): string;
const
  Names: array[TCssColorSpace] of string = ('srgb', 'srgb-linear', 'display-p3', 'a98-rgb',
    'prophoto-rgb', 'rec2020', 'xyz-d50', 'xyz-d65', 'hsl', 'hwb', 'lab', 'lch', 'oklab', 'oklch');
begin
  Result := Names[Space];
end;

function IsPolarSpace(Space: TCssColorSpace): Boolean;
begin
  Result := Space in [csHsl, csHwb, csLch, csOklch];
end;

{ ---- color-mix() ---- }

function HueIndex(Space: TCssColorSpace): Integer;
begin
  if Space in [csHsl, csHwb] then
    Result := 0
  else if Space in [csLch, csOklch] then
    Result := 2
  else
    Result := -1;
end;

function MixColors(Space: TCssColorSpace; Hue: THueInterpolation; const First: TCssColor;
  Weight1: Double; const Second: TCssColor; Weight2, Scale: Double): TCssColor;
var
  A, B: TCssColor;
  Index, HueAt: Integer;
  AlphaA, AlphaB, Alpha, HueA, HueB, Difference: Double;
  MissingA, MissingB: Boolean;
begin
  A := ConvertColor(First, Space);
  B := ConvertColor(Second, Space);
  { A component missing in one color takes the other's. }
  for Index := 0 to 3 do
  begin
    MissingA := (A.MissingMask and (1 shl Index)) <> 0;
    MissingB := (B.MissingMask and (1 shl Index)) <> 0;
    if MissingA and not MissingB then
    begin
      if Index = 3 then A.Alpha := B.Alpha else A.Components[Index] := B.Components[Index];
    end
    else if MissingB and not MissingA then
    begin
      if Index = 3 then B.Alpha := A.Alpha else B.Components[Index] := A.Components[Index];
    end;
  end;
  AlphaA := A.Alpha;
  AlphaB := B.Alpha;
  Alpha := AlphaA * Weight1 + AlphaB * Weight2;
  HueAt := HueIndex(Space);
  Result := MakeColor(Space, 0, 0, 0, Alpha * Scale);
  for Index := 0 to 2 do
  begin
    if Index = HueAt then
    begin
      HueA := A.Components[Index] - 360 * Floor(A.Components[Index] / 360);
      HueB := B.Components[Index] - 360 * Floor(B.Components[Index] / 360);
      Difference := HueB - HueA;
      case Hue of
        hiShorter:
          if Difference > 180 then HueA := HueA + 360
          else if Difference < -180 then HueB := HueB + 360;
        hiLonger:
          if (Difference > 0) and (Difference < 180) then HueA := HueA + 360
          else if (Difference > -180) and (Difference <= 0) then HueB := HueB + 360;
        hiIncreasing:
          if Difference < 0 then HueB := HueB + 360;
        hiDecreasing:
          if Difference > 0 then HueA := HueA + 360;
      end;
      Result.Components[Index] := HueA * Weight1 + HueB * Weight2;
      Result.Components[Index] := Result.Components[Index] - 360 * Floor(Result.Components[Index] / 360);
    end
    else if Alpha = 0 then
      Result.Components[Index] := A.Components[Index] * Weight1 + B.Components[Index] * Weight2
    else
      { Premultiplied interpolation. }
      Result.Components[Index] := (A.Components[Index] * AlphaA * Weight1 +
        B.Components[Index] * AlphaB * Weight2) / Alpha;
  end;
end;

{ ---- serialization ---- }

function SerializeComponent(const Color: TCssColor; Index: Integer): string;
begin
  if (Color.MissingMask and (1 shl Index)) <> 0 then
    Result := 'none'
  else
    Result := SerializeNumber(Color.Components[Index]);
end;

function SerializeAlpha(Alpha: Double): string;
begin
  Result := SerializeNumber(Round(Alpha * 1000) / 1000);
end;

function SerializeColor(const Color: TCssColor): string;
var
  Red, Green, Blue, Alpha: Double;
  Suffix: string;
begin
  if Color.Legacy or (Color.Space in [csHsl, csHwb]) then
  begin
    ColorToSrgb(Color, Red, Green, Blue, Alpha);
    if Alpha >= 1 then
      Result := Format('rgb(%d, %d, %d)', [Round(Red * 255), Round(Green * 255), Round(Blue * 255)])
    else
      Result := Format('rgba(%d, %d, %d, %s)', [Round(Red * 255), Round(Green * 255),
        Round(Blue * 255), SerializeAlpha(Alpha)]);
    Exit;
  end;
  Suffix := '';
  if (Color.MissingMask and 8) <> 0 then
    Suffix := ' / none'
  else if Color.Alpha < 1 then
    Suffix := ' / ' + SerializeAlpha(Max(0, Color.Alpha));
  case Color.Space of
    csLab, csLch, csOklab, csOklch:
      Result := ColorSpaceName(Color.Space) + '(' + SerializeComponent(Color, 0) + ' ' +
        SerializeComponent(Color, 1) + ' ' + SerializeComponent(Color, 2) + Suffix + ')';
  else
    Result := 'color(' + ColorSpaceName(Color.Space) + ' ' + SerializeComponent(Color, 0) + ' ' +
      SerializeComponent(Color, 1) + ' ' + SerializeComponent(Color, 2) + Suffix + ')';
  end;
end;

initialization
  LoadNamedColors;
  LoadSystemColors;
end.
