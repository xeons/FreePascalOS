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
  The JPEG decoder against Pillow's decoding (make-jpeg-fixtures.py):
  every subsampling, odd sizes, progressive, greyscale, restart
  markers, CMYK, EXIF orientation, an ICC profile in two chunks, JFIF
  density; cjpeg's extra samplings when they were made; a 12 megapixel
  photograph decoded (and timed). Then files cut short (kept up to
  where they end, or refused before the first scan), malformed headers
  refused with the right reason, and a few hundred damaged files that
  must give a picture or an EImageError, never anything worse. Last,
  the encoder: a picture written and read back is close to what was
  written, and keeps its orientation, resolution and ICC profile.
}
unit ImageTest.Jpeg;

{$mode objfpc}
{$H+}

interface

procedure TestJpeg;

implementation

uses
  SysUtils,
  DateUtils,
  Image.Errors,
  Image.Model,
  Image.Metadata,
  Image.Jpeg.Codec,
  ImageTest.Checks;

function MeanPixelDifference(First, Second: TImage): Double;
var
  X: LongInt;
  Y: LongInt;
  A: LongWord;
  B: LongWord;
  Shift: LongInt;
  Total: Double;
begin
  Total := 0;
  for Y := 0 to First.Height - 1 do
    for X := 0 to First.Width - 1 do
    begin
      A := First.Line(Y)[X];
      B := Second.Line(Y)[X];
      Shift := 0;
      while Shift < 24 do
      begin
        Total := Total + Abs(LongInt((A shr Shift) and $FF) - LongInt((B shr Shift) and $FF));
        Inc(Shift, 8);
      end;
    end;
  Result := Total / (3.0 * First.Width * First.Height);
end;

const
  { Pillow uses libjpeg-turbo with the same inverse DCT, upsampling and
    colour conversion, so the pixels should be the same; a little room
    is left for libjpeg-turbo builds whose SIMD code rounds differently. }
  JpegTolerance = 2;
  JpegMeanTolerance = 0.05;

function DecodeBytes(const Data: TBytes): TImage;
var
  Decoder: TJpegDecoder;
begin
  Decoder := TJpegDecoder.Create;
  try
    Result := Decoder.Decode(Data);
  finally
    Decoder.Free;
  end;
end;

function DecodeFixture(const Name: string): TImage;
begin
  try
    Result := DecodeBytes(FixtureBytes(Name));
  except
    on Error: Exception do
    begin
      Note(Name + ': ' + Error.ClassName + ': ' + Error.Message);
      Result := nil;
    end;
  end;
end;

procedure CheckAgainstPillow(const Name: string);
var
  Image: TImage;
begin
  Image := DecodeFixture(Name + '.jpg');
  try
    CheckImageMatchesReference('jpeg ' + Name + ' matches Pillow', Image, Name + '.rgba', JpegTolerance,
      JpegMeanTolerance);
  finally
    Image.Free;
  end;
end;

{ The reason Data is refused with, or ImageErrorNone if it decodes;
  any other exception fails the check named Name. }
function RefusalReason(const Data: TBytes; const Name: string): TImageErrorReason;
var
  Image: TImage;
begin
  Result := ImageErrorNone;
  try
    Image := DecodeBytes(Data);
    Image.Free;
  except
    on Error: EImageError do
      Result := Error.Reason;
    on Error: Exception do
    begin
      Check(False, Name + ' (' + Error.ClassName + ': ' + Error.Message + ')');
      Result := ImageErrorNone;
    end;
  end;
end;

{ The position of the first $FF Marker in Data, or -1. }
function FindMarkerPosition(const Data: TBytes; Marker: Byte): PtrInt;
var
  Index: PtrInt;
begin
  for Index := 0 to Length(Data) - 2 do
    if (Data[Index] = $FF) and (Data[Index + 1] = Marker) then
      Exit(Index);
  Result := -1;
end;

procedure TestPillowFixtures;
var
  Name: string;
begin
  CheckAgainstPillow('jpeg-444');
  CheckAgainstPillow('jpeg-422');
  CheckAgainstPillow('jpeg-420');
  CheckAgainstPillow('jpeg-420-odd');
  CheckAgainstPillow('jpeg-progressive-420');
  CheckAgainstPillow('jpeg-progressive-444');
  CheckAgainstPillow('jpeg-grey');
  CheckAgainstPillow('jpeg-restart');
  CheckAgainstPillow('jpeg-cmyk');
  CheckAgainstPillow('jpeg-orientation-6');
  CheckAgainstPillow('jpeg-icc');
  for Name in TStringArray.Create('jpeg-440', 'jpeg-411', 'jpeg-h1v2') do
    if FileExists(FixturePath(Name + '.jpg')) then
      CheckAgainstPillow(Name)
    else
      Note(Name + '.jpg not made (no cjpeg): skipped');
end;

procedure TestProperties;
var
  Image: TImage;
  Profile: TBytes;
begin
  Image := DecodeFixture('jpeg-grey.jpg');
  try
    Check((Image <> nil) and (Image.SourceBitsPerPixel = 8) and
      (Image.Metadata.GetValue(MetadataKeyColorSpace) = 'Grey') and (Image.SourceFormatName = 'JPEG'),
      'jpeg greyscale is 8 bits, grey');
  finally
    Image.Free;
  end;
  Image := DecodeFixture('jpeg-420.jpg');
  try
    Check((Image <> nil) and (Image.SourceBitsPerPixel = 24) and
      (Image.Metadata.GetValue(MetadataKeyColorSpace) = 'YCbCr') and (Image.Orientation = OrientationNormal) and
      Image.IsOpaque and (Length(Image.IccProfile) = 0), 'jpeg colour is 24 bits, YCbCr, upright, opaque');
  finally
    Image.Free;
  end;
  Image := DecodeFixture('jpeg-cmyk.jpg');
  try
    Check((Image <> nil) and (Image.SourceBitsPerPixel = 32) and
      (Image.Metadata.GetValue(MetadataKeyColorSpace) = 'CMYK'), 'jpeg CMYK is 32 bits, CMYK');
  finally
    Image.Free;
  end;
  Image := DecodeFixture('jpeg-orientation-6.jpg');
  try
    Check((Image <> nil) and (Image.Orientation = OrientationRotate90) and (Image.Width = 40) and
      (Image.Height = 24), 'jpeg EXIF orientation 6 read, pixels as stored');
  finally
    Image.Free;
  end;
  Image := DecodeFixture('jpeg-icc.jpg');
  Profile := FixtureBytes('jpeg-icc.bin');
  try
    Check((Image <> nil) and (Length(Image.IccProfile) = Length(Profile)) and
      (CompareByte(Image.IccProfile[0], Profile[0], Length(Profile)) = 0),
      'jpeg ICC profile put together from its chunks');
  finally
    Image.Free;
  end;
  Image := DecodeFixture('jpeg-density.jpg');
  try
    Check((Image <> nil) and (Round(Image.Resolution.HorizontalDpi) = 300) and
      (Round(Image.Resolution.VerticalDpi) = 150), 'jpeg JFIF density as resolution');
  finally
    Image.Free;
  end;
end;

procedure TestLargePhotograph;
var
  Data: TBytes;
  Started: TDateTime;
  Image: TImage;
  Milliseconds: Int64;
begin
  Data := FixtureBytes('jpeg-large.jpg');
  Started := Now;
  Image := nil;
  try
    try
      Image := DecodeBytes(Data);
    except
      on Error: Exception do
        Note('jpeg-large.jpg: ' + Error.Message);
    end;
    Milliseconds := MilliSecondsBetween(Now, Started);
    Check((Image <> nil) and (Image.Width = 4000) and (Image.Height = 3000), 'jpeg 12 megapixel photograph decoded');
    Note(Format('12 megapixels in %d ms', [Milliseconds]));
  finally
    Image.Free;
  end;
end;

procedure TestTruncated;
var
  Whole: TBytes;
  Data: TBytes;
  Image: TImage;
  Reason: TImageErrorReason;
begin
  Whole := FixtureBytes('jpeg-420.jpg');
  Data := Copy(Whole, 0, (Length(Whole) * 6) div 10);
  Image := nil;
  try
    try
      Image := DecodeBytes(Data);
    except
      on Error: Exception do
        Note('cut jpeg-420.jpg: ' + Error.Message);
    end;
    Check((Image <> nil) and (Image.Width = 64) and (Image.Height = 48) and
      (Image.GetPixel(63, 47) = $FF808080), 'jpeg cut short keeps what is there, the rest grey');
  finally
    Image.Free;
  end;

  Whole := FixtureBytes('jpeg-progressive-420.jpg');
  Data := Copy(Whole, 0, Length(Whole) div 2);
  Image := nil;
  try
    try
      Image := DecodeBytes(Data);
    except
      on Error: Exception do
        Note('cut jpeg-progressive-420.jpg: ' + Error.Message);
    end;
    Check((Image <> nil) and (Image.Width = 70) and (Image.Height = 50), 'progressive jpeg cut short keeps its scans');
  finally
    Image.Free;
  end;

  Whole := FixtureBytes('jpeg-444.jpg');
  Data := Copy(Whole, 0, FindMarkerPosition(Whole, $C4) + 10);
  Reason := RefusalReason(Data, 'jpeg cut in the headers');
  Check(Reason = ImageErrorTruncated, 'jpeg cut in the headers is truncated');
  Data := Copy(Whole, 0, 3);
  Check(RefusalReason(Data, 'jpeg of three bytes') = ImageErrorTruncated, 'jpeg of three bytes is truncated');
end;

procedure TestMalformed;
var
  Whole: TBytes;
  Data: TBytes;
  Position: PtrInt;
begin
  Whole := FixtureBytes('jpeg-444.jpg');

  Data := Copy(Whole);
  Data[4] := 0;
  Data[5] := 1;
  Check(RefusalReason(Data, 'jpeg segment length 1') = ImageErrorMalformed, 'jpeg segment length 1 refused');

  Data := Copy(Whole);
  Position := FindMarkerPosition(Data, $C0);
  Data[Position + 7] := 0;
  Data[Position + 8] := 0;
  Check(RefusalReason(Data, 'jpeg width 0') = ImageErrorMalformed, 'jpeg width 0 refused');

  Data := Copy(Whole);
  Data[Position + 5] := 0;
  Data[Position + 6] := 0;
  Check(RefusalReason(Data, 'jpeg height 0') = ImageErrorUnsupported, 'jpeg height 0 (DNL) refused');

  Data := Copy(Whole);
  Data[Position + 4] := 12;
  Check(RefusalReason(Data, 'jpeg 12-bit') = ImageErrorUnsupported, 'jpeg 12-bit samples refused');

  Data := Copy(Whole);
  Data[Position + 1] := $C9;
  Check(RefusalReason(Data, 'jpeg arithmetic') = ImageErrorUnsupported, 'jpeg arithmetic coding refused');

  Data := Copy(Whole);
  Data[Position + 9] := 2;
  Check(RefusalReason(Data, 'jpeg two components') = ImageErrorUnsupported, 'jpeg of two components refused');

  Data := Copy(Whole);
  Position := FindMarkerPosition(Data, $C4);
  Data[Position + 5] := 3;
  Check(RefusalReason(Data, 'jpeg Huffman overflow') = ImageErrorMalformed, 'jpeg Huffman code overflow refused');

  Data := Copy(Whole);
  Position := FindMarkerPosition(Data, $DB);
  Data[Position + 4] := $07;
  Check(RefusalReason(Data, 'jpeg quantization index') = ImageErrorMalformed,
    'jpeg quantization table index 7 refused');

  Data := Copy(Whole);
  Position := FindMarkerPosition(Data, $DA);
  Data[Position + 5] := $77;
  Check(RefusalReason(Data, 'jpeg scan component') = ImageErrorMalformed, 'jpeg scan of an unknown component refused');

  SetLength(Data, 3);
  Data[0] := 0;
  Data[1] := 1;
  Data[2] := 2;
  Check(RefusalReason(Data, 'not a jpeg') = ImageErrorUnknownFormat, 'not a jpeg refused');
end;

procedure TestDamagedFiles;
var
  Sources: array[0..2] of TBytes;
  Data: TBytes;
  Attempt: LongInt;
  Changes: LongInt;
  Change: LongInt;
  Survived: Boolean;
  Image: TImage;
begin
  Sources[0] := FixtureBytes('jpeg-420.jpg');
  Sources[1] := FixtureBytes('jpeg-progressive-420.jpg');
  Sources[2] := FixtureBytes('jpeg-restart.jpg');
  RandSeed := 12345;
  Survived := True;
  for Attempt := 1 to 600 do
  begin
    Data := Copy(Sources[Attempt mod 3]);
    Changes := 1 + Random(6);
    for Change := 1 to Changes do
      Data[Random(Length(Data))] := Random(256);
    if Attempt mod 5 = 0 then
      SetLength(Data, Random(Length(Data)));
    try
      Image := DecodeBytes(Data);
      Image.Free;
    except
      on EImageError do
        ;
      on Error: Exception do
      begin
        Survived := False;
        Note(Format('damaged file %d: %s: %s', [Attempt, Error.ClassName, Error.Message]));
      end;
    end;
  end;
  Check(Survived, 'jpeg damaged files give a picture or EImageError');
end;

procedure TestEncoding;
var
  Source: TImage;
  Encoder: TJpegEncoder;
  Encoded: TBytes;
  Decoded: TImage;
  Profile: TBytes;
begin
  Source := DecodeFixture('jpeg-420-odd.jpg');
  Decoded := nil;
  Encoder := TJpegEncoder.Create;
  try
    if Source = nil then
    begin
      Check(False, 'jpeg encoding (no source)');
      Exit;
    end;
    SetLength(Profile, 1000);
    FillChar(Profile[0], Length(Profile), $5A);
    Source.IccProfile := Profile;
    Source.Orientation := OrientationRotate270;
    Source.Resolution := MakeResolution(144, 72);
    Encoder.Quality := 95;
    Encoded := Encoder.Encode(Source);
    try
      Decoded := DecodeBytes(Encoded);
    except
      on Error: Exception do
        Note('encoded jpeg: ' + Error.Message);
    end;
    Check((Decoded <> nil) and (Decoded.Width = 37) and (Decoded.Height = 29), 'jpeg written is read back');
    if Decoded = nil then
      Exit;
    Check((LargestPixelDifference(Source, Decoded) <= 32) and (MeanPixelDifference(Source, Decoded) < 3.5),
      'jpeg written at quality 95 is close to its source');
    Note(Format('quality 95: largest difference %d, mean %.3f',
      [LargestPixelDifference(Source, Decoded), MeanPixelDifference(Source, Decoded)]));
    Check((Decoded.Orientation = OrientationRotate270) and (Round(Decoded.Resolution.HorizontalDpi) = 144) and
      (Round(Decoded.Resolution.VerticalDpi) = 72), 'jpeg written keeps orientation and resolution');
    Check((Length(Decoded.IccProfile) = 1000) and (Decoded.IccProfile[999] = $5A), 'jpeg written keeps its ICC profile');
  finally
    Encoder.Free;
    Decoded.Free;
    Source.Free;
  end;
end;

procedure TestJpeg;
begin
  TestPillowFixtures;
  TestProperties;
  TestLargePhotograph;
  TestTruncated;
  TestMalformed;
  TestDamagedFiles;
  TestEncoding;
end;

end.
