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
  The JPEG XL checks. The fixtures (make-jxl-fixtures.py) are encoded
  by libjxl's cjxl and their references are djxl's decoding; without
  cjxl on the host none are made and every check here is skipped.

  Lossless files must match exactly (16-bit samples rounded to 8 bits
  as the PNG decoder rounds them). Lossy files are decoded in floating
  point by both decoders, so a little room is left: libjxl rounds its
  float pipeline differently in places (and uses SIMD approximations of
  the cube root and the transfer function).
}
unit ImageTest.Jxl;

{$mode objfpc}
{$H+}

interface

procedure TestJxl;

implementation

uses
  SysUtils,
  Classes,
  Image.Errors,
  Image.Model,
  Image.Metadata,
  Image.Frames,
  Image.Orientation,
  Image.Codecs,
  Image.Files,
  Image.Jxl.Codec,
  ImageTest.Random,
  ImageTest.Checks;

const
  { distance 2 and below }
  LossyTolerance = 4;
  LossyMeanTolerance = 0.5;
  { distance 3 and 4, strong edge-preserving filtering }
  CoarseTolerance = 8;
  CoarseMeanTolerance = 1.0;
  { noise synthesis is optional: without it the noise djxl adds is the
    difference }
  NoiseTolerance = 64;
  NoiseMeanTolerance = 6.0;

  ContainerSignature: array[0..11] of Byte = (0, 0, 0, $0C, Ord('J'), Ord('X'), Ord('L'), Ord(' '), $0D, $0A, $87,
    $0A);

  RobustnessFixtures: array[0..9] of string = (
    'jxl-lossless-e1', 'jxl-lossless-e7', 'jxl-lossless-p6', 'jxl-lossless-alpha', 'jxl-lossless-palette',
    'jxl-modular-lossy', 'jxl-vardct-odd', 'jxl-vardct-alpha', 'jxl-animation', 'jxl-boxes');
  CutsPerFile = 16;
  DamagesPerFile = 24;

var
  DamageRandom: TTestRandom = (State: 4242);

function FixtureMade(const Name: string): Boolean;
begin
  Result := FileExists(FixturePath(Name + '.jxl'));
  if not Result then
    Note(Name + '.jxl not made (no cjxl): skipped');
end;

function DecodeBytes(const Data: TBytes): TImage;
var
  Decoder: TJxlDecoder;
begin
  Decoder := TJxlDecoder.Create;
  try
    Result := Decoder.Decode(Data);
  finally
    Decoder.Free;
  end;
end;

function DecodeFixture(const Name: string): TImage;
begin
  try
    Result := DecodeBytes(FixtureBytes(Name + '.jxl'));
  except
    on Error: Exception do
    begin
      Note(Name + '.jxl: ' + Error.ClassName + ': ' + Error.Message);
      Result := nil;
    end;
  end;
end;

procedure CheckAgainstDjxl(const Name: string; Tolerance: LongInt; MeanTolerance: Double = -1);
var
  Image: TImage;
begin
  if not FixtureMade(Name) then
    Exit;
  Image := DecodeFixture(Name);
  try
    CheckImageMatchesReference(Name + ' matches djxl', Image, Name + '.rgba', Tolerance, MeanTolerance);
  finally
    Image.Free;
  end;
end;

procedure CheckLossless(const Name: string);
begin
  CheckAgainstDjxl(Name, 0);
end;

procedure TestLossless;
var
  Predictor: LongInt;
begin
  CheckLossless('jxl-lossless-e1');
  CheckLossless('jxl-lossless-e3');
  CheckLossless('jxl-lossless-e7');
  CheckLossless('jxl-lossless-e9');
  CheckLossless('jxl-lossless-palette');
  for Predictor := 0 to 13 do
    CheckLossless('jxl-lossless-p' + IntToStr(Predictor));
  CheckLossless('jxl-lossless-grey');
  CheckLossless('jxl-lossless-16bit');
  CheckLossless('jxl-lossless-alpha');
  CheckLossless('jxl-lossless-grey-alpha');
  CheckLossless('jxl-lossless-groups');
  CheckLossless('jxl-lossless-group128');
  CheckLossless('jxl-lossless-group1024');
  CheckLossless('jxl-lossless-rct');
  CheckLossless('jxl-lossless-large');
end;

procedure TestLossy;
begin
  CheckAgainstDjxl('jxl-modular-lossy', LossyTolerance, LossyMeanTolerance);
  CheckAgainstDjxl('jxl-vardct-d05', LossyTolerance, LossyMeanTolerance);
  CheckAgainstDjxl('jxl-vardct-d1', LossyTolerance, LossyMeanTolerance);
  CheckAgainstDjxl('jxl-vardct-d2', LossyTolerance, LossyMeanTolerance);
  CheckAgainstDjxl('jxl-vardct-d4', CoarseTolerance, CoarseMeanTolerance);
  CheckAgainstDjxl('jxl-vardct-alpha', LossyTolerance, LossyMeanTolerance);
  CheckAgainstDjxl('jxl-vardct-grey', LossyTolerance, LossyMeanTolerance);
  CheckAgainstDjxl('jxl-vardct-odd', LossyTolerance, LossyMeanTolerance);
  CheckAgainstDjxl('jxl-vardct-resampling2', LossyTolerance, LossyMeanTolerance);
  CheckAgainstDjxl('jxl-vardct-e3', LossyTolerance, LossyMeanTolerance);
  CheckAgainstDjxl('jxl-vardct-e9', LossyTolerance, LossyMeanTolerance);
  CheckAgainstDjxl('jxl-vardct-large', LossyTolerance, LossyMeanTolerance);
  CheckAgainstDjxl('jxl-vardct-progressive', LossyTolerance, LossyMeanTolerance);
  CheckAgainstDjxl('jxl-vardct-noepf', LossyTolerance, LossyMeanTolerance);
  CheckAgainstDjxl('jxl-vardct-epf3', CoarseTolerance, CoarseMeanTolerance);
  CheckAgainstDjxl('jxl-vardct-noise', NoiseTolerance, NoiseMeanTolerance);
end;

{ The values after Keyword on its line of the animation's description. }
function DescriptionNumbers(const Lines: TStringList; const Keyword: string): TStringArray;
var
  Line: string;
begin
  Result := nil;
  for Line in Lines do
    if Pos(Keyword + ' ', Line) = 1 then
      Exit(Trim(Copy(Line, Length(Keyword) + 2, MaxInt)).Split([' ']));
end;

procedure CheckAnimation(const Name: string; Tolerance: LongInt; MeanTolerance: Double);
var
  Image: TImage;
  Animation: TAnimatedImage;
  Description: TStringList;
  Delays: TStringArray;
  Loops: TStringArray;
  Index: LongInt;
  Frame: TImageFrame;
  DelaysMatch: Boolean;
begin
  if not FixtureMade(Name) then
    Exit;
  Description := TStringList.Create;
  Image := DecodeFixture(Name);
  try
    Description.LoadFromFile(FixturePath(Name + '.txt'));
    Delays := DescriptionNumbers(Description, 'delays');
    Loops := DescriptionNumbers(Description, 'loops');
    Check(Image is TAnimatedImage, Name + ' is an animation');
    if not (Image is TAnimatedImage) then
      Exit;
    Animation := TAnimatedImage(Image);
    Check(Animation.FrameCount = Length(Delays), Name + ' has ' + IntToStr(Length(Delays)) + ' frames (' +
      IntToStr(Animation.FrameCount) + ')');
    if Length(Loops) > 0 then
      Check(Animation.LoopCount = StrToInt(Loops[0]), Name + ' loop count ' + Loops[0] + ' (' +
        IntToStr(Animation.LoopCount) + ')');
    CheckImageMatchesReference(Name + ' own pixels are the first frame', Image, Name + '-frame0.rgba', Tolerance,
      MeanTolerance);
    DelaysMatch := True;
    for Index := 0 to Animation.FrameCount - 1 do
    begin
      if Index >= Length(Delays) then
        Break;
      Frame := Animation.Frames[Index];
      if Frame.Delay <> StrToInt(Delays[Index]) then
      begin
        DelaysMatch := False;
        Note(Format('%s frame %d delay %d, expected %s', [Name, Index, Frame.Delay, Delays[Index]]));
      end;
      Check((Frame.Left = 0) and (Frame.Top = 0) and (Frame.Image.Width = Image.Width) and
        (Frame.Image.Height = Image.Height), Format('%s frame %d covers the canvas', [Name, Index]));
      CheckImageMatchesReference(Format('%s frame %d matches djxl', [Name, Index]), Frame.Image,
        Format('%s-frame%d.rgba', [Name, Index]), Tolerance, MeanTolerance);
    end;
    Check(DelaysMatch, Name + ' delays');
  finally
    Image.Free;
    Description.Free;
  end;
end;

procedure TestAnimations;
begin
  CheckAnimation('jxl-animation', 0, -1);
  CheckAnimation('jxl-animation-lossy', LossyTolerance, LossyMeanTolerance);
end;

procedure TestOrientation;
var
  Image: TImage;
  Upright: TImage;
begin
  if not FixtureMade('jxl-orientation') then
    Exit;
  Image := DecodeFixture('jxl-orientation');
  Upright := nil;
  try
    if Image = nil then
    begin
      Check(False, 'jxl-orientation decodes');
      Exit;
    end;
    Check(Image.Orientation = OrientationRotate90, 'jxl-orientation is orientation 6');
    Check((Image.Width = 40) and (Image.Height = 20), 'jxl-orientation keeps the stored pixels (40 x 20)');
    CheckImageMatchesReference('jxl-orientation stored pixels', Image, 'jxl-orientation-stored.rgba', 0);
    Upright := OrientedImage(Image);
    { djxl turns the picture upright }
    CheckImageMatchesReference('jxl-orientation turned upright matches djxl', Upright, 'jxl-orientation.rgba', 0);
  finally
    Upright.Free;
    Image.Free;
  end;
end;

function BytesEqual(const First, Second: TBytes): Boolean;
begin
  Result := (Length(First) = Length(Second)) and
    ((Length(First) = 0) or CompareMem(@First[0], @Second[0], Length(First)));
end;

procedure TestColourAndMetadata;
var
  Image: TImage;
  Boxes: string;
begin
  if FixtureMade('jxl-icc') then
  begin
    Image := DecodeFixture('jxl-icc');
    try
      if Image <> nil then
      begin
        Check(BytesEqual(Image.IccProfile, FixtureBytes('jxl-icc.icc')), 'jxl-icc carries the ICC profile (' +
          IntToStr(Length(Image.IccProfile)) + ' bytes)');
        Check(Image.Metadata.GetValue(MetadataKeyColorSpace) = 'ICC', 'jxl-icc colour space is ICC (' +
          Image.Metadata.GetValue(MetadataKeyColorSpace) + ')');
      end
      else
        Check(False, 'jxl-icc decodes');
    finally
      Image.Free;
    end;
  end;
  if FixtureMade('jxl-lossless-alpha') then
  begin
    Image := DecodeFixture('jxl-lossless-alpha');
    try
      if Image <> nil then
      begin
        Check(Image.SourceFormatName = 'JPEG XL', 'jxl source format name (' + Image.SourceFormatName + ')');
        Check(Image.SourceHasAlpha, 'jxl-lossless-alpha has alpha');
        Check(Image.SourceBitsPerPixel = 32, 'jxl-lossless-alpha 32 bits per pixel (' +
          IntToStr(Image.SourceBitsPerPixel) + ')');
        Check(Image.Metadata.GetValue('JxlEncoding') = 'Modular', 'jxl-lossless-alpha is modular (' +
          Image.Metadata.GetValue('JxlEncoding') + ')');
        Check(Image.Metadata.GetValue(MetadataKeyColorSpace) = 'sRGB', 'jxl-lossless-alpha is sRGB (' +
          Image.Metadata.GetValue(MetadataKeyColorSpace) + ')');
        Check(Length(Image.IccProfile) = 0, 'jxl-lossless-alpha has no profile');
      end
      else
        Check(False, 'jxl-lossless-alpha decodes');
    finally
      Image.Free;
    end;
  end;
  if FixtureMade('jxl-lossless-16bit') then
  begin
    Image := DecodeFixture('jxl-lossless-16bit');
    try
      if Image <> nil then
      begin
        Check(Image.SourceBitsPerPixel = 48, 'jxl-lossless-16bit 48 bits per pixel (' +
          IntToStr(Image.SourceBitsPerPixel) + ')');
        Check(not Image.SourceHasAlpha, 'jxl-lossless-16bit has no alpha');
      end;
    finally
      Image.Free;
    end;
  end;
  if FixtureMade('jxl-vardct-d1') then
  begin
    Image := DecodeFixture('jxl-vardct-d1');
    try
      if Image <> nil then
      begin
        Check(Image.Metadata.GetValue('JxlEncoding') = 'VarDCT', 'jxl-vardct-d1 is VarDCT (' +
          Image.Metadata.GetValue('JxlEncoding') + ')');
        Check(Length(Image.IccProfile) = 0, 'jxl-vardct-d1 (XYB, turned into sRGB) has no profile');
        Check(Image.SourceBitsPerPixel = 24, 'jxl-vardct-d1 24 bits per pixel (' +
          IntToStr(Image.SourceBitsPerPixel) + ')');
      end;
    finally
      Image.Free;
    end;
  end;
  if FixtureMade('jxl-boxes') then
  begin
    Image := DecodeFixture('jxl-boxes');
    try
      if Image <> nil then
      begin
        Boxes := Image.Metadata.GetValue('JxlBoxes');
        Check((Pos('Exif', Boxes) > 0) and (Pos('xml', Boxes) > 0), 'jxl-boxes lists Exif and xml boxes (' +
          Boxes + ')');
      end;
      CheckImageMatchesReference('jxl-boxes matches djxl', Image, 'jxl-boxes.rgba', 0);
    finally
      Image.Free;
    end;
  end;
end;

{ A JPEG recompressed losslessly decodes as its pixels (VarDCT in
  YCbCr) or is refused as unsupported; either is acceptable. }
procedure TestJpegReconstruction;
var
  Image: TImage;
begin
  if not FixtureMade('jxl-jpeg-reconstruction') then
    Exit;
  Image := nil;
  try
    try
      Image := DecodeBytes(FixtureBytes('jxl-jpeg-reconstruction.jxl'));
      CheckImageMatchesReference('jxl-jpeg-reconstruction matches djxl', Image, 'jxl-jpeg-reconstruction.rgba',
        LossyTolerance, LossyMeanTolerance);
    except
      on Error: EImageError do
      begin
        Check(Error.Reason = ImageErrorUnsupported, 'jxl-jpeg-reconstruction refused as unsupported (' +
          Error.Message + ')');
      end;
    end;
  finally
    Image.Free;
  end;
end;

procedure TestSignatures;
var
  Data: TBytes;
  Image: TImage;
begin
  Data := TBytes.Create($FF, $0A, 0, 0);
  Check(TJxlDecoder.CanDecode(Data), 'jxl CanDecode a bare codestream');
  SetLength(Data, Length(ContainerSignature) + 4);
  FillChar(Data[0], Length(Data), 0);
  Move(ContainerSignature[0], Data[0], Length(ContainerSignature));
  Check(TJxlDecoder.CanDecode(Data), 'jxl CanDecode the container signature');
  Data := TBytes.Create($FF, $D8, $FF, $E0);
  Check(not TJxlDecoder.CanDecode(Data), 'jxl CanDecode refuses a JPEG');
  Check(TJxlDecoder.Format = ImageFormatJxl, 'jxl decoder format');
  Check(ImageFormatName(ImageFormatJxl) = 'JPEG XL', 'jxl format name');
  if not FixtureMade('jxl-lossless-e1') then
    Exit;
  Data := FixtureBytes('jxl-lossless-e1.jxl');
  Check(DetectImageFormat(Data) = ImageFormatJxl, 'a JPEG XL file is detected through the registry');
  Image := nil;
  try
    try
      Image := LoadImage(Data);
      Check(Image.SourceFormatName = 'JPEG XL', 'LoadImage reads JPEG XL');
    except
      on Error: Exception do
        Check(False, 'LoadImage reads JPEG XL (' + Error.ClassName + ': ' + Error.Message + ')');
    end;
  finally
    Image.Free;
  end;
  { a codestream cut right after its signature }
  Data := TBytes.Create($FF, $0A);
  try
    Image := DecodeBytes(Data);
    Image.Free;
    Check(False, 'a bare JPEG XL signature is refused');
  except
    on Error: EImageError do
      Check(Error.Reason = ImageErrorTruncated, 'a bare JPEG XL signature is cut short (' + Error.Message + ')');
    on Error: Exception do
      Check(False, 'a bare JPEG XL signature is refused (' + Error.ClassName + ')');
  end;
end;

{ An empty string when Data decodes or is refused properly; what went
  wrong otherwise. }
function TryDamaged(const Data: TBytes): string;
var
  Image: TImage;
begin
  Result := '';
  Image := nil;
  try
    Image := DecodeBytes(Data);
  except
    on EImageError do
      ;
    on Error: Exception do
      Result := Error.ClassName + ': ' + Error.Message;
  end;
  Image.Free;
end;

procedure TestDamagedFixture(const Name: string);
var
  Good: TBytes;
  Damaged: TBytes;
  Index: LongInt;
  Changes: LongInt;
  Change: LongInt;
  Problem: string;
  Description: string;
begin
  Good := FixtureBytes(Name + '.jxl');
  Problem := '';
  Description := '';
  for Index := 1 to CutsPerFile do
  begin
    if Problem <> '' then
      Break;
    Damaged := Copy(Good, 0, (Int64(Length(Good)) * Index) div (CutsPerFile + 1));
    Problem := TryDamaged(Damaged);
    Description := 'cut at ' + IntToStr(Length(Damaged));
  end;
  for Index := 1 to DamagesPerFile do
  begin
    if Problem <> '' then
      Break;
    Damaged := Copy(Good);
    Changes := 1 + NextRandom(DamageRandom, 6);
    for Change := 1 to Changes do
      Damaged[NextRandom(DamageRandom, Length(Damaged))] := NextRandom(DamageRandom, 256);
    Problem := TryDamaged(Damaged);
    Description := 'damage ' + IntToStr(Index);
  end;
  Check(Problem = '', 'damaged ' + Name + '.jxl decodes or is refused');
  if Problem <> '' then
    Note(Description + ': ' + Problem);
end;

procedure TestRobustness;
var
  Index: LongInt;
begin
  for Index := Low(RobustnessFixtures) to High(RobustnessFixtures) do
    if FixtureMade(RobustnessFixtures[Index]) then
      TestDamagedFixture(RobustnessFixtures[Index]);
end;

procedure TestJxl;
begin
  TestSignatures;
  TestLossless;
  TestLossy;
  TestAnimations;
  TestOrientation;
  TestColourAndMetadata;
  TestJpegReconstruction;
  TestRobustness;
end;

end.
