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
  Colour management (make-color-fixtures.py): PNGs with ICC profiles of
  every kind converted to sRGB and compared with LittleCMS's conversion
  (matrix/TRC and grey within 2, LUTs within 3); the sRGB profile left
  alone, an abstract Lab profile refused, a CMYK JPEG called
  approximate; PNG gAMA and cHRM; what the profiles are read as; old
  colorants not adapted to D50; an animation's frames; damaged profiles
  never worse than refused.
}
unit ImageTest.ColorProfiles;

{$mode objfpc}
{$H+}

interface

procedure TestColorProfiles;

implementation

uses
  SysUtils,
  Image.Model,
  Image.Metadata,
  Image.Frames,
  Image.Files,
  Image.ColorProfiles,
  Image.ColorProfiles.Matrices,
  Image.ColorProfiles.Curves,
  Image.ColorProfiles.Luts,
  Image.ColorProfiles.Reading,
  Image.ColorProfiles.Transforms,
  ImageTest.Random,
  ImageTest.Checks;

const
  MatrixTolerance = 2;
  MatrixMeanTolerance = 0.3;
  LutTolerance = 3;
  LutMeanTolerance = 0.5;

  ResultNames: array[TColorConversionResult] of string = ('not needed', 'done', 'approximate', 'unsupported');

function LoadFixture(const Name: string; Options: TImageLoadOptions = []): TImage;
begin
  try
    Result := LoadImage(FixtureBytes(Name), Options);
  except
    on Error: Exception do
    begin
      Note(Name + ': ' + Error.ClassName + ': ' + Error.Message);
      Result := nil;
    end;
  end;
end;

procedure CheckConversion(const Name: string; Expected: TColorConversionResult; Tolerance: LongInt;
  MeanTolerance: Double);
var
  Image: TImage;
  Outcome: TColorConversionResult;
begin
  Image := LoadFixture(Name + '.png');
  if Image = nil then
  begin
    Check(False, 'colour ' + Name + ' (no image)');
    Exit;
  end;
  try
    Outcome := Image.ConvertToSrgb;
    Check(Outcome = Expected, 'colour ' + Name + ': ' + ResultNames[Outcome]);
    CheckImageMatchesReference('colour ' + Name + ' as sRGB', Image, Name + '.rgba', Tolerance, MeanTolerance);
    if Outcome = ColorConversionDone then
      Check((Length(Image.IccProfile) = 0) and (Image.Metadata.GetValue(MetadataKeyColorSpace) = 'sRGB'),
        'colour ' + Name + ': marked as sRGB');
  finally
    Image.Free;
  end;
end;

procedure TestConversions;
var
  Image: TImage;
begin
  CheckConversion('icc-display-p3', ColorConversionDone, MatrixTolerance, MatrixMeanTolerance);
  CheckConversion('icc-adobe-rgb', ColorConversionDone, MatrixTolerance, MatrixMeanTolerance);
  CheckConversion('icc-gamma18', ColorConversionDone, MatrixTolerance, MatrixMeanTolerance);
  CheckConversion('icc-prophoto-table', ColorConversionDone, MatrixTolerance, MatrixMeanTolerance);
  CheckConversion('icc-grey22', ColorConversionDone, MatrixTolerance, MatrixMeanTolerance);
  CheckConversion('icc-grey-linear', ColorConversionDone, MatrixTolerance, MatrixMeanTolerance);
  CheckConversion('icc-lut16-xyz', ColorConversionDone, LutTolerance, LutMeanTolerance);
  CheckConversion('icc-mab-lab', ColorConversionDone, LutTolerance, LutMeanTolerance);
  CheckConversion('icc-srgb', ColorConversionNotNeeded, 0, -1);
  CheckConversion('icc-lab-unsupported', ColorConversionUnsupported, 0, -1);
  CheckConversion('png-gamma10', ColorConversionDone, MatrixTolerance, MatrixMeanTolerance);
  CheckConversion('png-gamma-srgb', ColorConversionNotNeeded, 0, -1);
  CheckConversion('png-chrm-p3', ColorConversionDone, MatrixTolerance, MatrixMeanTolerance);

  Image := LoadFixture('icc-lab-unsupported.png');
  try
    Check((Image <> nil) and (Length(Image.IccProfile) > 0) and (Image.ConvertToSrgb = ColorConversionUnsupported) and
      (Length(Image.IccProfile) > 0), 'colour: an unsupported profile is kept');
  finally
    Image.Free;
  end;

  Image := LoadFixture('icc-display-p3.png', [ImageLoadConvertToSrgb]);
  try
    CheckImageMatchesReference('colour: converted as it is loaded', Image, 'icc-display-p3.rgba', MatrixTolerance,
      MatrixMeanTolerance);
    Check((Image <> nil) and (Image.Metadata.GetValue(MetadataKeyOriginalColorProfile) = 'Display P3 test'),
      'colour: the original profile is named');
  finally
    Image.Free;
  end;
end;

procedure TestCmyk;
var
  Naive: TImage;
  Converted: TImage;
begin
  Naive := LoadFixture('icc-cmyk.jpg');
  Converted := LoadFixture('icc-cmyk.jpg');
  try
    if (Naive = nil) or (Converted = nil) then
    begin
      Check(False, 'colour CMYK JPEG (no image)');
      Exit;
    end;
    Check(Length(Converted.IccProfile) > 0, 'colour CMYK JPEG: the profile is read');
    Check(Converted.ConvertToSrgb = ColorConversionApproximate, 'colour CMYK JPEG: approximate');
    Check(LargestPixelDifference(Naive, Converted) = 0, 'colour CMYK JPEG: the naive inks to RGB');
    Check(Length(Converted.IccProfile) = 0, 'colour CMYK JPEG: no profile left');
  finally
    Naive.Free;
    Converted.Free;
  end;
end;

function NearlyEqual(First, Second, Tolerance: Double): Boolean;
begin
  Result := Abs(First - Second) <= Tolerance;
end;

procedure TestReading;
var
  Profile: TIccProfile;
  Description: string;
begin
  Profile := ReadIccProfile(FixtureBytes('icc-display-p3.icc'));
  Check(Profile.Valid and (Profile.VersionMajor = 4) and (Profile.VersionMinor = 3) and IccColorSpaceIsRgb(Profile),
    'profile: P3 header');
  Check(Profile.HasColorants and Profile.HasRgbCurves and (Profile.RgbCurves[0].Kind = ToneCurveParametric) and
    (Profile.RgbCurves[0].FunctionType = 3), 'profile: P3 colorants and parametric curves');
  Check(Profile.HasAdaptation and (MatrixDistance(Profile.Adaptation, BradfordAdaptation(ChromaticityToXyz(
    ChromaticityD65), WhiteD50)) < 0.001), 'profile: P3 chromatic adaptation (chad)');
  Check(Profile.Description = 'Display P3 test', 'profile: v4 description (mluc): ' + Profile.Description);
  Check(NearlyEqual(EvaluateToneCurve(Profile.RgbCurves[1], 0.5), SrgbToLinear(0.5), 0.0005),
    'profile: the parametric curve evaluated');

  Profile := ReadIccProfile(FixtureBytes('icc-adobe-rgb.icc'));
  Check(Profile.Valid and (Profile.RgbCurves[0].Kind = ToneCurveGamma) and
    NearlyEqual(Profile.RgbCurves[0].Gamma, 563 / 256, 1e-9), 'profile: Adobe RGB gamma curve');
  Check(Profile.HasMediaWhite and NearlyEqual(Profile.MediaWhite[2], 1.08905, 0.0001),
    'profile: Adobe RGB media white point');
  Check(Profile.Description = 'Adobe RGB test', 'profile: v2 description: ' + Profile.Description);

  Profile := ReadIccProfile(FixtureBytes('icc-prophoto-table.icc'));
  Check(Profile.Valid and (Profile.RgbCurves[2].Kind = ToneCurveTable) and (Length(Profile.RgbCurves[2].Table) = 256),
    'profile: table curves');

  Profile := ReadIccProfile(FixtureBytes('icc-lut16-xyz.icc'));
  Check(Profile.Valid and Profile.HasDeviceToPcs and (Profile.DeviceToPcs.Kind = IccLut16) and
    (Profile.DeviceToPcs.GridPoints[0] = 17) and (Length(Profile.DeviceToPcs.InputCurves) = 3) and
    not IccPcsIsLab(Profile), 'profile: lut16 A2B0');

  Profile := ReadIccProfile(FixtureBytes('icc-mab-lab.icc'));
  Check(Profile.Valid and (Profile.DeviceToPcs.Kind = IccLutAToB) and IccPcsIsLab(Profile) and
    (Length(Profile.DeviceToPcs.OutputCurves) = 3) and (Length(Profile.DeviceToPcs.InputCurves) = 3) and
    (Length(Profile.DeviceToPcs.Grid) = 17 * 17 * 17 * 3), 'profile: mAB A2B0 to Lab');

  Description := DescribeColorProfile(FixtureBytes('icc-display-p3.icc'));
  Check(Pos('matrix/TRC', Description) > 0, 'profile described: ' + Description);
  Description := DescribeColorProfile(FixtureBytes('icc-lut16-xyz.icc'));
  Check(Pos('LUT', Description) > 0, 'profile described: ' + Description);
  Check(not ReadIccProfile(nil).Valid, 'profile: nothing is not a profile');
end;

{ Colorants left under D65 by an old profile (adding up to its media
  white point) are adapted to D50. }
procedure TestUnadaptedColorants;
var
  Profile: TIccProfile;
  ToXyz: TColorMatrix;
begin
  RgbToXyzMatrix(SrgbRed, SrgbGreen, SrgbBlue, ChromaticityD65, ToXyz);
  Profile := Default(TIccProfile);
  Profile.RedColorant := MakeVector(ToXyz[0, 0], ToXyz[1, 0], ToXyz[2, 0]);
  Profile.GreenColorant := MakeVector(ToXyz[0, 1], ToXyz[1, 1], ToXyz[2, 1]);
  Profile.BlueColorant := MakeVector(ToXyz[0, 2], ToXyz[1, 2], ToXyz[2, 2]);
  Profile.HasMediaWhite := True;
  Profile.MediaWhite := ChromaticityToXyz(ChromaticityD65);
  Check(MatrixDistance(AdaptedColorants(Profile), SrgbToPcsMatrix) < 0.0005,
    'colorants under the media white point adapted to D50');
  Profile.HasAdaptation := True;
  Profile.Adaptation := BradfordAdaptation(ChromaticityToXyz(ChromaticityD65), WhiteD50);
  Check(MatrixDistance(AdaptedColorants(Profile), SrgbToPcsMatrix) < 0.0005, 'colorants adapted by chad');
  Profile.RedColorant := MakeVector(SrgbToPcsMatrix[0, 0], SrgbToPcsMatrix[1, 0], SrgbToPcsMatrix[2, 0]);
  Profile.GreenColorant := MakeVector(SrgbToPcsMatrix[0, 1], SrgbToPcsMatrix[1, 1], SrgbToPcsMatrix[2, 1]);
  Profile.BlueColorant := MakeVector(SrgbToPcsMatrix[0, 2], SrgbToPcsMatrix[1, 2], SrgbToPcsMatrix[2, 2]);
  Check(MatrixDistance(AdaptedColorants(Profile), SrgbToPcsMatrix) < 0.0005, 'colorants adapted already are kept');
end;

procedure TestAnimation;
var
  Animation: TAnimatedImage;
  Frame: TImage;
  Still: TImage;
begin
  Animation := TAnimatedImage.Create(4, 4);
  Still := TImage.Create(4, 4);
  try
    Frame := TImage.Create(2, 2);
    Frame.Fill($FF336699);
    Animation.AddFrame(TImageFrame.Create(Frame));
    Animation.Fill($FF336699);
    Animation.IccProfile := FixtureBytes('icc-gamma18.icc');
    Still.Fill($FF336699);
    Still.IccProfile := FixtureBytes('icc-gamma18.icc');
    Check((Animation.ConvertToSrgb = ColorConversionDone) and (Still.ConvertToSrgb = ColorConversionDone),
      'colour of an animation converted');
    Check((Animation.GetPixel(0, 0) = Still.GetPixel(0, 0)) and (Frame.GetPixel(1, 1) = Still.GetPixel(0, 0)) and
      (Still.GetPixel(0, 0) <> $FF336699), 'colour: its frames converted with it');
  finally
    Animation.Free;
    Still.Free;
  end;
end;

{ Damaged profiles: converted or refused, never an exception. }
procedure TestDamagedProfiles;
const
  Names: array[0..3] of string = ('icc-display-p3.icc', 'icc-lut16-xyz.icc', 'icc-mab-lab.icc',
    'icc-prophoto-table.icc');
var
  Random: TTestRandom;
  Good: TBytes;
  Damaged: TBytes;
  Image: TImage;
  NameIndex: LongInt;
  Attempt: LongInt;
  Change: LongInt;
  Problem: string;
begin
  Random := NewTestRandom(97531);
  Image := TImage.Create(8, 8);
  try
    for NameIndex := 0 to High(Names) do
    begin
      Good := FixtureBytes(Names[NameIndex]);
      Problem := '';
      for Attempt := 1 to 60 do
      begin
        if Attempt <= 20 then
          Damaged := Copy(Good, 0, (Int64(Length(Good)) * Attempt) div 21)
        else
        begin
          Damaged := Copy(Good);
          for Change := 0 to NextRandom(Random, 6) do
            Damaged[NextRandom(Random, Length(Damaged))] := NextRandom(Random, 256);
        end;
        Image.Fill($FF808080);
        Image.IccProfile := Damaged;
        try
          Image.ConvertToSrgb;
        except
          on Error: Exception do
          begin
            Problem := Format('attempt %d: %s: %s', [Attempt, Error.ClassName, Error.Message]);
            Break;
          end;
        end;
      end;
      Check(Problem = '', 'damaged profile ' + Names[NameIndex] + ' converted or refused');
      if Problem <> '' then
        Note(Problem);
    end;
  finally
    Image.Free;
  end;
end;

procedure TestColorProfiles;
begin
  TestConversions;
  TestCmyk;
  TestReading;
  TestUnadaptedColorants;
  TestAnimation;
  TestDamagedProfiles;
end;

end.
