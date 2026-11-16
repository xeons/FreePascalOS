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
  TIFF (make-tiff-fixtures.py): every compression (none, PackBits, LZW
  new and old style, deflate, JPEG with and without JPEGTables), both
  byte orders, BigTIFF, strips and tiles, separate planes, the
  horizontal predictor, 1- to 16-bit samples, white and black is zero,
  palettes, alpha associated and not, CMYK, YCbCr subsampled; fax
  compression (CCITT RLE, Group 3 one- and two-dimensional, with fill
  bits, Group 4, fill order 2, white is zero), floating point samples
  (16 and 32 bits, the floating point predictor, high dynamic range);
  lossless files exactly as their references, JPEG within 2 (old-style
  JPEG too). Several pages, the
  metadata, a directory linking to itself; writing (uncompressed, LZW,
  deflate, with and without the predictor, several pages) read back
  here and by Pillow (check-with-pillow.py); malformed files refused
  and damaged ones loaded or refused, never anything worse.
}
unit ImageTest.Tiff;

{$mode objfpc}
{$H+}

interface

procedure TestTiff;

implementation

uses
  ImageTest.Random,
  SysUtils,
  Image.Errors,
  Image.Model,
  Image.Metadata,
  Image.Codecs,
  Image.Files,
  Image.Tiff.Codec,
  Image.Tiff.Writing,
  ImageTest.Checks;

const
  JpegTolerance = 2;
  JpegMeanTolerance = 0.1;

  LosslessFixtures: array[0..30] of string = (
    'tiff-none', 'tiff-packbits', 'tiff-lzw', 'tiff-deflate', 'tiff-pillow-rgba', 'tiff-pillow-grey',
    'tiff-pillow-palette', 'tiff-pillow-bilevel', 'tiff-be-lzw-predictor', 'tiff-be-packbits', 'tiff-tiles',
    'tiff-tiles-be-lzw', 'tiff-old-lzw', 'tiff-long-lzw', 'tiff-fill-order', 'tiff-bigtiff', 'tiff-bigtiff-be',
    'tiff-be-rgb16', 'tiff-grey16-predictor', 'tiff-bilevel-white', 'tiff-grey2', 'tiff-grey4',
    'tiff-grey4-white-be', 'tiff-palette4-be', 'tiff-planar-rgba-be', 'tiff-associated', 'tiff-grey-alpha',
    'tiff-cmyk', 'tiff-ycbcr22', 'tiff-ycbcr21-lzw', 'tiff-loop');

  JpegFixtures: array[0..5] of string = (
    'tiff-jpeg-rgb', 'tiff-jpeg-ycbcr', 'tiff-jpeg-strips', 'tiff-jpeg-tiles', 'tiff-old-jpeg',
    'tiff-old-jpeg-strips');

  FaxFixtures: array[0..9] of string = (
    'tiff-g4', 'tiff-g3', 'tiff-g3-2d', 'tiff-g3-fill', 'tiff-ccitt-rle', 'tiff-g4-strips', 'tiff-g4-fill-order',
    'tiff-g3-2d-fill-order', 'tiff-g3-2d-fax-width', 'tiff-g4-white-is-zero');

  FloatFixtures: array[0..6] of string = (
    'tiff-float-predictor-deflate', 'tiff-float-predictor-lzw', 'tiff-float-rgb-be-predictor',
    'tiff-float-rgb-le-predictor', 'tiff-half-grey', 'tiff-half-grey-be-predictor', 'tiff-float-hdr');

  DamagedFixtures: array[0..11] of string = (
    'tiff-lzw', 'tiff-be-lzw-predictor', 'tiff-tiles', 'tiff-planar-rgba-be', 'tiff-ycbcr21-lzw',
    'tiff-jpeg-strips', 'tiff-palette4-be', 'tiff-old-lzw', 'tiff-grey16-predictor', 'tiff-bigtiff', 'tiff-pages',
    'tiff-metadata');

  { Damaged after the others, so that their damage stays as it was. }
  MoreDamagedFixtures: array[0..5] of string = (
    'tiff-g4', 'tiff-g3-2d', 'tiff-ccitt-rle', 'tiff-float-rgb-be-predictor', 'tiff-half-grey-be-predictor',
    'tiff-old-jpeg');

function LoadFixture(const Name: string): TImage;
begin
  try
    Result := LoadImage(FixtureBytes(Name));
  except
    on Error: Exception do
    begin
      Note(Name + ': ' + Error.ClassName + ': ' + Error.Message);
      Result := nil;
    end;
  end;
end;

procedure CheckFixture(const Name: string; Tolerance: LongInt; MeanTolerance: Double);
var
  Image: TImage;
begin
  Image := LoadFixture(Name + '.tif');
  try
    CheckImageMatchesReference('tiff ' + Name, Image, Name + '.rgba', Tolerance, MeanTolerance);
  finally
    Image.Free;
  end;
end;

procedure TestFixtures;
var
  Index: LongInt;
begin
  Check(DetectFileFormat(FixtureBytes('tiff-none.tif')) = ImageFormatTiff, 'a little-endian TIFF is recognised');
  Check(DetectFileFormat(FixtureBytes('tiff-be-packbits.tif')) = ImageFormatTiff, 'a big-endian TIFF is recognised');
  Check(DetectFileFormat(FixtureBytes('tiff-bigtiff.tif')) = ImageFormatTiff, 'a BigTIFF is recognised');
  for Index := 0 to High(LosslessFixtures) do
    CheckFixture(LosslessFixtures[Index], 0, -1);
  for Index := 0 to High(JpegFixtures) do
    CheckFixture(JpegFixtures[Index], JpegTolerance, JpegMeanTolerance);
  for Index := 0 to High(FaxFixtures) do
    CheckFixture(FaxFixtures[Index], 0, -1);
  for Index := 0 to High(FloatFixtures) do
    CheckFixture(FloatFixtures[Index], 0, -1);
end;

procedure TestPages;
var
  Data: TBytes;
  Image: TImage;
  Index: LongInt;
begin
  Data := FixtureBytes('tiff-pages.tif');
  Check(TiffPageCount(Data) = 3, 'a TIFF of three pages');
  Image := LoadFixture('tiff-pages.tif');
  try
    CheckImageMatchesReference('tiff pages: the file loads as its first page', Image, 'tiff-pages-0.rgba', 0);
    Check((Image <> nil) and (Image.Metadata.GetValue(MetadataKeyPageCount) = '3'), 'tiff page count in the metadata');
  finally
    Image.Free;
  end;
  for Index := 1 to 2 do
  begin
    Image := nil;
    try
      try
        Image := DecodeTiffPage(Data, Index);
      except
        on Error: Exception do
          Note('page ' + IntToStr(Index) + ': ' + Error.Message);
      end;
      CheckImageMatchesReference('tiff page ' + IntToStr(Index), Image, 'tiff-pages-' + IntToStr(Index) + '.rgba', 0);
    finally
      Image.Free;
    end;
  end;
  Image := LoadFixture('tiff-loop.tif');
  try
    Check((Image <> nil) and not Image.Metadata.Contains(MetadataKeyPageCount),
      'a directory linking to itself is one page');
  finally
    Image.Free;
  end;
end;

function SameBytes(const First, Second: TBytes): Boolean;
begin
  Result := (Length(First) = Length(Second)) and ((Length(First) = 0) or CompareMem(@First[0], @Second[0],
    Length(First)));
end;

procedure TestMetadata;
var
  Image: TImage;
begin
  Image := LoadFixture('tiff-metadata.tif');
  if Image = nil then
  begin
    Check(False, 'tiff metadata (no image)');
    Exit;
  end;
  try
    Check(Image.SourceFormatName = 'TIFF', 'tiff format name');
    Check(Image.Metadata.GetValue(MetadataKeyDescription) = 'A test picture', 'tiff image description');
    Check(Image.Metadata.GetValue(MetadataKeySoftware) = 'make-tiff-fixtures', 'tiff software');
    Check(Image.Metadata.GetValue(MetadataKeyDateTime) = '2026:11:16 12:00:00', 'tiff date and time');
    Check(Image.Orientation = OrientationRotate90, 'tiff orientation 6');
    Check((Abs(Image.Resolution.HorizontalDpi - 254) < 0.01) and (Abs(Image.Resolution.VerticalDpi - 127) < 0.01),
      'tiff resolution in centimetres as dots per inch');
    Check(SameBytes(Image.IccProfile, FixtureBytes('tiff-metadata.icc')), 'tiff ICC profile');
  finally
    Image.Free;
  end;
end;

function MakePicture(Width, Height: LongInt; WithAlpha: Boolean): TImage;
var
  X: LongInt;
  Y: LongInt;
  Alpha: LongWord;
  Color: LongWord;
begin
  Result := TImage.Create(Width, Height);
  for Y := 0 to Height - 1 do
    for X := 0 to Width - 1 do
    begin
      Color := (LongWord((X * 255) div Width) shl 16) or (LongWord((Y * 255) div Height) shl 8) or
        LongWord(((X xor Y) * 37) and $FF);
      if WithAlpha then
        Alpha := LongWord((X * 7 + Y * 3) and $FF)
      else
        Alpha := 255;
      Result.SetPixel(X, Y, (Alpha shl 24) or Color);
    end;
end;

procedure CheckRoundTrip(const Name: string; Image: TImage; constref Options: TTiffWriteOptions);
var
  Data: TBytes;
  Back: TImage;
begin
  Back := nil;
  try
    try
      Data := EncodeTiffImage(Image, Options);
      Back := LoadImage(Data);
      Check(LargestPixelDifference(Back, Image) = 0, 'tiff written and read back: ' + Name);
      WriteForPillow(Name + '.tif', Data, Image);
    except
      on Error: Exception do
        Check(False, 'tiff written and read back: ' + Name + ' (' + Error.Message + ')');
    end;
  finally
    Back.Free;
  end;
end;

procedure TestWriting;
var
  Opaque: TImage;
  Translucent: TImage;
  Pages: TBytes;
  Back: TImage;
  Profile: TBytes;
  Index: LongInt;
begin
  Opaque := MakePicture(203, 157, False);
  Translucent := MakePicture(61, 45, True);
  try
    CheckRoundTrip('written-tiff-uncompressed', Opaque, MakeTiffWriteOptions(TiffWriteUncompressed, False));
    CheckRoundTrip('written-tiff-lzw', Opaque, MakeTiffWriteOptions(TiffWriteLzw, False));
    CheckRoundTrip('written-tiff-lzw-predictor', Opaque, MakeTiffWriteOptions(TiffWriteLzw, True));
    CheckRoundTrip('written-tiff-deflate', Opaque, MakeTiffWriteOptions(TiffWriteDeflate, False));
    CheckRoundTrip('written-tiff-deflate-predictor', Opaque, MakeTiffWriteOptions(TiffWriteDeflate, True));
    CheckRoundTrip('written-tiff-rgba-lzw', Translucent, MakeTiffWriteOptions(TiffWriteLzw, True));
    CheckRoundTrip('written-tiff-rgba-deflate', Translucent, MakeTiffWriteOptions(TiffWriteDeflate, True));
    CheckRoundTrip('written-tiff-rgba-uncompressed', Translucent, MakeTiffWriteOptions(TiffWriteUncompressed, False));

    Opaque.Metadata.SetValue(MetadataKeyDescription, 'written');
    Opaque.Metadata.SetValue(MetadataKeySoftware, 'ImageTest');
    Opaque.Resolution := MakeResolution(300, 150);
    Opaque.Orientation := OrientationRotate180;
    Profile := nil;
    SetLength(Profile, 300);
    for Index := 0 to High(Profile) do
      Profile[Index] := (Index * 13) and $FF;
    Opaque.IccProfile := Profile;
    Back := LoadImage(EncodeImage(Opaque, ImageFormatTiff));
    try
      Check((Back.Metadata.GetValue(MetadataKeyDescription) = 'written') and
        (Back.Metadata.GetValue(MetadataKeySoftware) = 'ImageTest'), 'tiff text written and read back');
      Check((Abs(Back.Resolution.HorizontalDpi - 300) < 0.01) and (Abs(Back.Resolution.VerticalDpi - 150) < 0.01),
        'tiff resolution written and read back');
      Check(Back.Orientation = OrientationRotate180, 'tiff orientation written and read back');
      Check(SameBytes(Back.IccProfile, Profile), 'tiff profile written and read back');
      Check(LargestPixelDifference(Back, Opaque) = 0, 'tiff through the registry');
    finally
      Back.Free;
    end;

    Pages := EncodeTiffPages([Opaque, Translucent], DefaultTiffWriteOptions);
    Check(TiffPageCount(Pages) = 2, 'tiff of two pages written');
    Back := DecodeTiffPage(Pages, 1);
    try
      Check(LargestPixelDifference(Back, Translucent) = 0, 'tiff second page written and read back');
    finally
      Back.Free;
    end;
  finally
    Opaque.Free;
    Translucent.Free;
  end;
end;

procedure CheckRefused(const Name: string; Expected: TImageErrorReason);
var
  Image: TImage;
  Reason: TImageErrorReason;
begin
  Image := nil;
  try
    if TryLoadImage(FixtureBytes(Name), Image, Reason) then
      Check(False, Name + ' refused (it was read)')
    else
      Check(Reason = Expected, Name + ' refused: ' + ImageErrorReasonText(Reason));
  except
    on Error: Exception do
      Check(False, Name + ' refused (' + Error.ClassName + ')');
  end;
  Image.Free;
end;

procedure TestMalformed;
begin
  CheckRefused('bad-tiff-truncated.tif', ImageErrorTruncated);
  CheckRefused('bad-tiff-header-only.tif', ImageErrorTruncated);
  CheckRefused('bad-tiff-huge.tif', ImageErrorTooLarge);
  CheckRefused('bad-tiff-compression.tif', ImageErrorUnsupported);
  CheckRefused('bad-tiff-ccitt.tif', ImageErrorUnsupported);
  CheckRefused('bad-tiff-photometric.tif', ImageErrorUnsupported);
  CheckRefused('bad-tiff-strip-offset.tif', ImageErrorTruncated);
  CheckRefused('bad-tiff-old-jpeg.tif', ImageErrorUnsupported);
end;

var
  DamageRandom: TTestRandom = (State: 24680);

{ An empty string when Data loads or is refused properly. }
function TryDamaged(const Data: TBytes): string;
var
  Image: TImage;
begin
  Result := '';
  Image := nil;
  try
    Image := LoadImage(Data);
  except
    on EImageError do
      ;
    on Error: Exception do
      Result := Error.ClassName + ': ' + Error.Message;
  end;
  Image.Free;
end;

procedure TestDamaged(const Name: string);
const
  Cuts = 24;
  Damages = 40;
var
  Good: TBytes;
  Damaged: TBytes;
  Index: LongInt;
  Change: LongInt;
  Problem: string;
  Description: string;
begin
  Good := FixtureBytes(Name + '.tif');
  Problem := '';
  Description := '';
  for Index := 1 to Cuts do
  begin
    if Problem <> '' then
      Break;
    Damaged := Copy(Good, 0, (Int64(Length(Good)) * Index) div (Cuts + 1));
    Problem := TryDamaged(Damaged);
    Description := 'cut at ' + IntToStr(Length(Damaged));
  end;
  for Index := 1 to Damages do
  begin
    if Problem <> '' then
      Break;
    Damaged := Copy(Good);
    for Change := 0 to NextRandom(DamageRandom, 8) do
      Damaged[NextRandom(DamageRandom, Length(Damaged))] := NextRandom(DamageRandom, 256);
    Problem := TryDamaged(Damaged);
    Description := 'damage ' + IntToStr(Index);
  end;
  Check(Problem = '', 'damaged ' + Name + '.tif loads or is refused');
  if Problem <> '' then
    Note(Description + ': ' + Problem);
end;

procedure TestTiff;
var
  Index: LongInt;
begin
  TestFixtures;
  TestPages;
  TestMetadata;
  TestWriting;
  TestMalformed;
  for Index := 0 to High(DamagedFixtures) do
    TestDamaged(DamagedFixtures[Index]);
  for Index := 0 to High(MoreDamagedFixtures) do
    TestDamaged(MoreDamagedFixtures[Index]);
end;

end.
