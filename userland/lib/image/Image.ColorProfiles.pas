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
  Colour management basics: an image's colours, described by its ICC
  profile, converted to sRGB (what the screen is taken to show).

    ConvertImageToSrgb(Image)    (also TImage.ConvertToSrgb, and
                                 LoadImage's ImageLoadConvertToSrgb)

  What can be converted:

    RGB matrix/TRC profiles      colorants and tone curves (gamma,
                                 tables, parametric), versions 2 and 4:
                                 Display P3, Adobe RGB, ProPhoto, gamma
                                 1.8 profiles...
    grey profiles                kTRC
    LUT-based profiles           A2B0 of RGB or grey (mft1, mft2, mAB),
                                 evaluated into a grid; when the LUT
                                 cannot be read but there are colorants,
                                 those are used instead and the result
                                 says it is approximate
    CMYK profiles                the decoders have already turned the
                                 inks into RGB by the naive rule (light
                                 = (1 - ink) x (1 - black)); the profile
                                 is not used and the result says the
                                 colours are approximate
    PNG without a profile        gAMA and cHRM (the 'Gamma' and
                                 'Chromaticities' metadata) when there
                                 is no sRGB chunk: a gamma of 1/2.2 with
                                 sRGB's primaries (or none given) is
                                 taken as sRGB, as browsers do

  Anything else (Lab or other colour spaces, a profile that cannot be
  read, a LUT-only profile whose LUT cannot be read) is left as it is:
  ColorConversionUnsupported.

  Once converted, the image has no profile any more, its 'ColorSpace'
  is 'sRGB', 'Gamma' and 'Chromaticities' are gone, and
  'OriginalColorProfile' names the profile it had. An animation's
  frames are converted with it.
}
unit Image.ColorProfiles;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Image.Model,
  Image.ColorProfiles.Reading;

const
  MetadataKeyOriginalColorProfile = 'OriginalColorProfile';

{ Converts Image (and its frames) to sRGB as described above. }
function ConvertImageToSrgb(Image: TImage): TColorConversionResult;
{ A line about a profile: its colour space, kind, version and name. }
function DescribeColorProfile(const Data: TBytes): string;

implementation

uses
  Image.Metadata,
  Image.Frames,
  Image.Png.Ancillary,
  Image.ColorProfiles.Numbers,
  Image.ColorProfiles.Matrices,
  Image.ColorProfiles.Curves,
  Image.ColorProfiles.Luts,
  Image.ColorProfiles.Transforms;

const
  PngGammaOfSrgb = 0.45455;

var
  NumberSettings: TFormatSettings;

function ProfileKind(constref Profile: TIccProfile): string;
begin
  if Profile.HasDeviceToPcs then
  begin
    if Profile.DeviceToPcs.Kind <> IccLutNone then
      Result := 'LUT'
    else
      Result := 'LUT (unreadable)';
    if Profile.HasColorants and Profile.HasRgbCurves then
      Result := Result + ' and matrix/TRC';
  end
  else if Profile.HasColorants and Profile.HasRgbCurves then
    Result := 'matrix/TRC'
  else if Profile.HasGreyCurve then
    Result := 'grey TRC'
  else
    Result := 'no conversion tags';
end;

function DescribeColorProfile(const Data: TBytes): string;
var
  Profile: TIccProfile;
begin
  Profile := ReadIccProfile(Data);
  if not Profile.Valid then
    Exit('not an ICC profile');
  Result := Format('%s, %s, version %d.%d', [Trim(SignatureText(Profile.ColorSpace)), ProfileKind(Profile),
    Profile.VersionMajor, Profile.VersionMinor]);
  if Profile.Description <> '' then
    Result := Result + ', "' + Profile.Description + '"';
end;

{ The transform for an ICC profile; nil with the result saying why
  when there is none. }
function TransformForProfile(constref Profile: TIccProfile; out Outcome: TColorConversionResult): TSrgbTransform;
var
  HasMatrixShaper: Boolean;
  LutUsable: Boolean;
begin
  Result := nil;
  Outcome := ColorConversionUnsupported;
  if not Profile.Valid then
    Exit;
  HasMatrixShaper := Profile.HasColorants and Profile.HasRgbCurves;
  LutUsable := Profile.HasDeviceToPcs and (Profile.DeviceToPcs.Kind <> IccLutNone);
  if IccColorSpaceIsRgb(Profile) then
  begin
    if LutUsable and (Profile.DeviceToPcs.InputChannels = 3) and (Profile.DeviceToPcs.OutputChannels = 3) then
    begin
      Result := TSrgbTransform.CreateFromLut(Profile.DeviceToPcs, IccPcsIsLab(Profile));
      Outcome := ColorConversionDone;
    end
    else if HasMatrixShaper then
    begin
      Result := TSrgbTransform.CreateMatrixShaper(AdaptedColorants(Profile), Profile.RgbCurves);
      if Profile.HasDeviceToPcs then
        Outcome := ColorConversionApproximate
      else
        Outcome := ColorConversionDone;
    end;
  end
  else if IccColorSpaceIsGrey(Profile) then
  begin
    if LutUsable and (Profile.DeviceToPcs.InputChannels = 1) and (Profile.DeviceToPcs.OutputChannels = 3) then
    begin
      Result := TSrgbTransform.CreateFromLut(Profile.DeviceToPcs, IccPcsIsLab(Profile));
      Outcome := ColorConversionDone;
    end
    else if Profile.HasGreyCurve then
    begin
      Result := TSrgbTransform.CreateGrey(Profile.GreyCurve);
      if Profile.HasDeviceToPcs then
        Outcome := ColorConversionApproximate
      else
        Outcome := ColorConversionDone;
    end;
  end
  else if IccColorSpaceIsCmyk(Profile) then
    Outcome := ColorConversionApproximate;
end;

function ReadNumbers(const Text: string): TStringArray;
begin
  Result := Trim(Text).Split([' '], TStringSplitOptions.ExcludeEmpty);
end;

function ChromaticityOf(const Numbers: TStringArray; Index: LongInt): TChromaticity;
begin
  Result.X := StrToFloatDef(Numbers[2 * Index], 0, NumberSettings);
  Result.Y := StrToFloatDef(Numbers[2 * Index + 1], 0, NumberSettings);
end;

{ The transform PNG's gAMA and cHRM describe; nil when they say sRGB
  or nothing. }
function TransformForPngChunks(Image: TImage): TSrgbTransform;
var
  Gamma: Double;
  HasGamma: Boolean;
  Numbers: TStringArray;
  HasChromaticities: Boolean;
  White: TChromaticity;
  ToXyz: TColorMatrix;
  SrgbToXyz: TColorMatrix;
  Curves: array[0..2] of TToneCurve;
  Channel: LongInt;
begin
  Result := nil;
  Gamma := StrToFloatDef(Image.Metadata.GetValue(MetadataKeyGamma), 0, NumberSettings);
  HasGamma := Gamma > 0;
  Numbers := ReadNumbers(Image.Metadata.GetValue(MetadataKeyChromaticities));
  HasChromaticities := Length(Numbers) = 8;
  RgbToXyzMatrix(SrgbRed, SrgbGreen, SrgbBlue, ChromaticityD65, SrgbToXyz);
  if HasChromaticities then
  begin
    White := ChromaticityOf(Numbers, 0);
    if not RgbToXyzMatrix(ChromaticityOf(Numbers, 1), ChromaticityOf(Numbers, 2), ChromaticityOf(Numbers, 3), White,
      ToXyz) then
      HasChromaticities := False
    else
      ToXyz := MultiplyMatrices(BradfordAdaptation(ChromaticityToXyz(White), WhiteD50), ToXyz);
  end;
  if not HasChromaticities then
    ToXyz := MultiplyMatrices(BradfordAdaptation(ChromaticityToXyz(ChromaticityD65), WhiteD50), SrgbToXyz);
  if not HasGamma and not HasChromaticities then
    Exit;
  if (not HasGamma or (Abs(Gamma - PngGammaOfSrgb) < 0.00001)) and
    (MatrixDistance(ToXyz, SrgbToPcsMatrix) < 0.003) then
    Exit;
  for Channel := 0 to 2 do
    if HasGamma then
      Curves[Channel] := GammaCurve(1 / Gamma)
    else
      Curves[Channel] := GammaCurve(1 / PngGammaOfSrgb);
  Result := TSrgbTransform.CreateMatrixShaper(ToXyz, Curves);
end;

procedure ConvertWithTransform(Image: TImage; Transform: TSrgbTransform);
var
  Index: LongInt;
  Frame: TImage;
begin
  Transform.ConvertPixels(Image.Pixels, PtrInt(Image.Width) * Image.Height);
  if Image is TAnimatedImage then
    for Index := 0 to TAnimatedImage(Image).FrameCount - 1 do
    begin
      Frame := TAnimatedImage(Image).Frames[Index].Image;
      if (Frame <> nil) and (Frame <> Image) then
        Transform.ConvertPixels(Frame.Pixels, PtrInt(Frame.Width) * Frame.Height);
    end;
end;

procedure MarkAsSrgb(Image: TImage; const OriginalName: string);
begin
  Image.IccProfile := nil;
  Image.Metadata.SetValue(MetadataKeyColorSpace, 'sRGB');
  Image.Metadata.Remove(MetadataKeyGamma);
  Image.Metadata.Remove(MetadataKeyChromaticities);
  if OriginalName <> '' then
    Image.Metadata.SetValue(MetadataKeyOriginalColorProfile, OriginalName);
end;

{ The transform for the image, nil when there is none (Outcome says
  why); Name names where it came from. }
function TransformForImage(Image: TImage; out Outcome: TColorConversionResult; out Name: string): TSrgbTransform;
var
  Profile: TIccProfile;
begin
  Name := '';
  if Length(Image.IccProfile) > 0 then
  begin
    Profile := ReadIccProfile(Image.IccProfile);
    Result := TransformForProfile(Profile, Outcome);
    Name := Profile.Description;
    if Name = '' then
      Name := 'ICC profile';
    Exit;
  end;
  Outcome := ColorConversionNotNeeded;
  Result := nil;
  if SameText(Image.Metadata.GetValue(MetadataKeyColorSpace), 'sRGB') then
    Exit;
  Result := TransformForPngChunks(Image);
  if Result <> nil then
    Outcome := ColorConversionDone;
  Name := 'PNG gAMA/cHRM';
end;

function ConvertImageToSrgb(Image: TImage): TColorConversionResult;
var
  Transform: TSrgbTransform;
  Name: string;
begin
  Transform := nil;
  try
    Transform := TransformForImage(Image, Result, Name);
  except
    { Numbers in a damaged profile that no arithmetic can use. }
    on EMathError do
      Exit(ColorConversionUnsupported);
  end;
  if Result in [ColorConversionUnsupported, ColorConversionNotNeeded] then
  begin
    Transform.Free;
    Exit;
  end;
  try
    if (Transform <> nil) and (Transform.Kind <> SrgbTransformNone) then
      ConvertWithTransform(Image, Transform)
    else if Result = ColorConversionDone then
      Result := ColorConversionNotNeeded;
    MarkAsSrgb(Image, Name);
  finally
    Transform.Free;
  end;
end;

initialization
  NumberSettings := DefaultFormatSettings;
  NumberSettings.DecimalSeparator := '.';
end.
