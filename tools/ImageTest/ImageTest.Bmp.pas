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
  BMP and DIB (make-fixtures.py): every depth, the OS/2 core header,
  top-down lines, 16 and 32-bit masks in every header that has them,
  RLE4 and RLE8 (with moves), alpha, an embedded profile, Pillow's own
  files, headerless DIBs; writing 24 and 32 bits and reading back;
  malformed files refused with the right reason.
}
unit ImageTest.Bmp;

{$mode objfpc}
{$H+}

interface

procedure TestBmp;

implementation

uses
  SysUtils,
  Image.Errors,
  Image.Model,
  Image.Codecs,
  Image.Files,
  Image.Bmp.Codec,
  Image.Bmp.Writing,
  ImageTest.Checks;

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

procedure CheckFixture(const Name: string; ExpectedBits: LongInt);
var
  Image: TImage;
  ReferenceName: string;
begin
  Image := LoadFixture(Name);
  try
    ReferenceName := ChangeFileExt(Name, '.rgba');
    CheckImageMatchesReference(Name + ' pixels', Image, ReferenceName, 0);
    if (Image <> nil) and (ExpectedBits > 0) then
      Check(Image.SourceBitsPerPixel = ExpectedBits, Name + ' bits per pixel ' + IntToStr(Image.SourceBitsPerPixel));
  finally
    Image.Free;
  end;
end;

procedure TestDepths;
begin
  CheckFixture('bmp1.bmp', 1);
  CheckFixture('bmp4.bmp', 4);
  CheckFixture('bmp8.bmp', 8);
  CheckFixture('bmp8-topdown.bmp', 8);
  CheckFixture('bmp8-core.bmp', 8);
  CheckFixture('bmp4-core.bmp', 4);
  CheckFixture('bmp16-555.bmp', 16);
  CheckFixture('bmp16-565.bmp', 16);
  CheckFixture('bmp16-4444-v3.bmp', 16);
  CheckFixture('bmp24.bmp', 24);
  CheckFixture('bmp24-topdown.bmp', 24);
  CheckFixture('bmp32-reserved.bmp', 32);
  CheckFixture('bmp32-alpha.bmp', 32);
  CheckFixture('bmp32-v5.bmp', 32);
  CheckFixture('bmp32-v4-rgba.bmp', 32);
  CheckFixture('bmp32-alphabitfields.bmp', 32);
  CheckFixture('bmp32-101010.bmp', 32);
  CheckFixture('bmp-rle8.bmp', 8);
  CheckFixture('bmp-rle4.bmp', 4);
  CheckFixture('bmp-rle8-moves.bmp', 8);
  CheckFixture('pillow-rgb.bmp', 24);
  CheckFixture('pillow-p.bmp', 8);
  CheckFixture('pillow-1.bmp', 1);
  CheckFixture('pillow-l.bmp', 8);
end;

procedure TestProperties;
var
  Image: TImage;
  Profile: TBytes;
begin
  Image := LoadFixture('bmp32-profile.bmp');
  try
    CheckImageMatchesReference('V5 with a profile: pixels', Image, 'bmp32-profile.rgba', 0);
    if Image <> nil then
    begin
      Profile := FixtureBytes('bmp32-profile.icc');
      Check((Length(Image.IccProfile) = Length(Profile)) and (Length(Profile) > 0) and
        CompareMem(@Image.IccProfile[0], @Profile[0], Length(Profile)), 'V5 embedded profile read');
      Check(Image.Metadata.GetValue('ColorSpace') = 'embedded profile', 'V5 colour space');
      Check(Image.SourceHasAlpha, 'V5 has alpha');
    end;
  finally
    Image.Free;
  end;
  Image := LoadFixture('bmp24.bmp');
  try
    if Image <> nil then
    begin
      Check(Abs(Image.Resolution.HorizontalDpi - 72.0) < 0.1, 'resolution from pixels per metre');
      Check(not Image.SourceHasAlpha, '24 bits has no alpha');
      Check(Image.SourceFormatName = 'BMP', 'format name BMP');
    end;
  finally
    Image.Free;
  end;
  Image := LoadFixture('bmp32-reserved.bmp');
  try
    if Image <> nil then
      Check(not Image.SourceHasAlpha and Image.IsOpaque, '32 bits with a zero fourth byte is opaque');
  finally
    Image.Free;
  end;
end;

procedure TestDib;
var
  Image: TImage;
begin
  Check(DetectFileFormat(FixtureBytes('dib24.dib')) = ImageFormatDib, 'a headerless DIB is recognised');
  CheckFixture('dib24.dib', 24);
  CheckFixture('dib32-bitfields.dib', 32);
  CheckFixture('dib4.dib', 4);
  Image := LoadFixture('dib24.dib');
  try
    if Image <> nil then
      Check(Image.SourceFormatName = 'DIB', 'format name DIB');
  finally
    Image.Free;
  end;
end;

function RoundTrip(Image: TImage; Format: TImageFormat; BitsPerPixel: LongInt): TImage;
var
  Encoder: TImageEncoder;
  Data: TBytes;
begin
  if Format = ImageFormatBmp then
    Encoder := TBmpEncoder.Create
  else
    Encoder := TDibEncoder.Create;
  try
    Encoder.BitsPerPixel := BitsPerPixel;
    Data := Encoder.Encode(Image);
  finally
    Encoder.Free;
  end;
  Result := LoadImage(Data);
end;

procedure TestWriting;
var
  Source: TImage;
  Opaque: TImage;
  Back: TImage;
  X: LongInt;
  Y: LongInt;
begin
  Source := LoadFixture('bmp32-alpha.bmp');
  Opaque := LoadFixture('bmp24.bmp');
  if (Source = nil) or (Opaque = nil) then
  begin
    Check(False, 'writing: fixtures');
    Source.Free;
    Opaque.Free;
    Exit;
  end;
  try
    Back := RoundTrip(Source, ImageFormatBmp, 32);
    Check(LargestPixelDifference(Source, Back) = 0, 'BMP 32 bits written and read back');
    Check(Back.SourceBitsPerPixel = 32, 'BMP 32 bits written as 32');
    Back.Free;
    Back := RoundTrip(Opaque, ImageFormatBmp, 24);
    Check(LargestPixelDifference(Opaque, Back) = 0, 'BMP 24 bits written and read back');
    Back.Free;
    Back := RoundTrip(Source, ImageFormatBmp, 0);
    Check(Back.SourceBitsPerPixel = 32, 'translucent pictures are written in 32 bits');
    Back.Free;
    Back := RoundTrip(Opaque, ImageFormatBmp, 0);
    Check(Back.SourceBitsPerPixel = 24, 'opaque pictures are written in 24 bits');
    Back.Free;
    Back := RoundTrip(Source, ImageFormatDib, 32);
    Check((LargestPixelDifference(Source, Back) = 0) and (Back.SourceFormatName = 'DIB'),
      'DIB 32 bits written and read back');
    Back.Free;
    Back := RoundTrip(Opaque, ImageFormatDib, 24);
    Check(LargestPixelDifference(Opaque, Back) = 0, 'DIB 24 bits written and read back');
    Back.Free;
    { Odd widths need padding in 24 bits. }
    Back := TImage.Create(3, 2);
    try
      for Y := 0 to 1 do
        for X := 0 to 2 do
          Back.SetPixel(X, Y, $FF000000 or LongWord(X * 80 + Y * 7));
      Source.Free;
      Source := RoundTrip(Back, ImageFormatBmp, 24);
      Check(LargestPixelDifference(Source, Back) = 0, 'BMP 24 bits of an odd width');
    finally
      Back.Free;
    end;
  finally
    Source.Free;
    Opaque.Free;
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
      Check(False, Name + ' refused (' + Error.ClassName + ': ' + Error.Message + ')');
  end;
  Image.Free;
end;

procedure TestMalformed;
var
  Image: TImage;
  Reason: TImageErrorReason;
begin
  CheckRefused('bad-bmp-truncated.bmp', ImageErrorTruncated);
  CheckRefused('bad-bmp-header-only.bmp', ImageErrorTruncated);
  CheckRefused('bad-bmp-header-size.bmp', ImageErrorUnknownFormat);
  CheckRefused('bad-bmp-huge.bmp', ImageErrorTooLarge);
  CheckRefused('bad-bmp-depth.bmp', ImageErrorMalformed);
  CheckRefused('bad-bmp-palette.bmp', ImageErrorMalformed);
  CheckRefused('bad-bmp-offset.bmp', ImageErrorTruncated);
  { Damaged runs decode to something, never past the picture. }
  Image := nil;
  Check(TryLoadImage(FixtureBytes('bad-bmp-rle-garbage.bmp'), Image, Reason) or (Reason <> ImageErrorNone),
    'damaged RLE gives a picture or a reason');
  Image.Free;
end;

procedure TestBmp;
begin
  TestDepths;
  TestProperties;
  TestDib;
  TestWriting;
  TestMalformed;
end;

end.
