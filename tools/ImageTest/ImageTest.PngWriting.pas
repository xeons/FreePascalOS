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
  Writing PNG: pictures of every kind (many colours with and without
  alpha, few colours, two colours, grey, grey with alpha) written,
  each in the smallest colour type that keeps it, and read back
  exactly; RGB and RGBA asked for; every compression level; the
  resolution, orientation, profile and text kept; a large picture
  timed. Every file written goes to the written directory, where
  check-with-pillow.py has Pillow decode it too.
}
unit ImageTest.PngWriting;

{$mode objfpc}
{$H+}

interface

procedure TestPngWriting;

implementation

uses
  SysUtils,
  DateUtils,
  Image.Model,
  Image.Metadata,
  Image.Codecs,
  Image.Files,
  Image.Png.Writing,
  ImageTest.Checks;

type
  TPictureKind = (PictureColors, PictureColorsAlpha, PictureFewColors, PictureFewColorsAlpha, PictureTwoColors,
    PictureGrey, PictureGreyAlpha);

const
  KindNames: array[TPictureKind] of string = ('colours', 'colours-alpha', 'few-colours', 'few-colours-alpha',
    'two-colours', 'grey', 'grey-alpha');
  { The bits per pixel each is written with. }
  KindBits: array[TPictureKind] of LongInt = (24, 32, 4, 8, 1, 8, 16);

function Pixel(Alpha, Red, Green, Blue: LongWord): LongWord;
begin
  Result := (Alpha shl 24) or (Red shl 16) or (Green shl 8) or Blue;
end;

function MakePicture(Kind: TPictureKind; Width, Height: LongInt): TImage;
var
  X: LongInt;
  Y: LongInt;
  Value: LongWord;
  Alpha: LongWord;
begin
  Result := TImage.Create(Width, Height);
  for Y := 0 to Height - 1 do
    for X := 0 to Width - 1 do
    begin
      Value := LongWord(X * 5 + Y * 3) and $FF;
      Alpha := LongWord(X * 3 + Y * 7) and $FF;
      case Kind of
        PictureColors:
          Result.Line(Y)[X] := Pixel(255, Value, LongWord(Y * 9) and $FF, LongWord(X * Y) and $FF);
        PictureColorsAlpha:
          Result.Line(Y)[X] := Pixel(Alpha, Value, LongWord(Y * 9) and $FF, LongWord(X * Y) and $FF);
        PictureFewColors:
          Result.Line(Y)[X] := Pixel(255, ((X div 4) mod 4) * 80, ((Y div 3) mod 3) * 100, 50);
        PictureFewColorsAlpha:
          Result.Line(Y)[X] := Pixel(((X + Y) mod 5) * 60, ((X div 4) mod 8) * 30, ((Y div 3) mod 5) * 50, 50);
        PictureTwoColors:
          if (X xor Y) and 4 = 0 then
            Result.Line(Y)[X] := Pixel(255, 10, 20, 30)
          else
            Result.Line(Y)[X] := Pixel(0, 0, 0, 0);
        PictureGrey:
          Result.Line(Y)[X] := Pixel(255, Value, Value, Value);
        PictureGreyAlpha:
          Result.Line(Y)[X] := Pixel(Alpha, Value, Value, Value);
      end;
    end;
end;

function WriteAndReadBack(const Name: string; Image: TImage; constref Options: TPngWriteOptions;
  out Back: TImage): TBytes;
begin
  Back := nil;
  Result := EncodePngImage(Image, Options);
  WriteForPillow(Name, Result, Image);
  try
    Back := LoadImage(Result);
  except
    on Error: Exception do
      Note(Name + ': ' + Error.ClassName + ': ' + Error.Message);
  end;
end;

procedure TestKinds;
var
  Kind: TPictureKind;
  Image: TImage;
  Back: TImage;
  Name: string;
begin
  for Kind := Low(TPictureKind) to High(TPictureKind) do
  begin
    Name := 'written-' + KindNames[Kind] + '.png';
    Image := MakePicture(Kind, 61, 43);
    try
      WriteAndReadBack(Name, Image, DefaultPngWriteOptions, Back);
      try
        Check((Back <> nil) and (LargestPixelDifference(Image, Back) = 0), Name + ' read back exactly');
        if Back <> nil then
          Check(Back.SourceBitsPerPixel = KindBits[Kind], Name + ' written with ' + IntToStr(KindBits[Kind]) +
            ' bits per pixel (' + IntToStr(Back.SourceBitsPerPixel) + ')');
      finally
        Back.Free;
      end;
    finally
      Image.Free;
    end;
  end;
end;

procedure TestAskedDepths;
var
  Image: TImage;
  Back: TImage;
  Options: TPngWriteOptions;
begin
  Image := MakePicture(PictureGrey, 30, 20);
  try
    Options := DefaultPngWriteOptions;
    Options.BitsPerPixel := 32;
    WriteAndReadBack('written-asked-rgba.png', Image, Options, Back);
    try
      Check((Back <> nil) and (Back.SourceBitsPerPixel = 32) and (LargestPixelDifference(Image, Back) = 0),
        'RGBA asked for a grey picture');
    finally
      Back.Free;
    end;
    Options.BitsPerPixel := 24;
    WriteAndReadBack('written-asked-rgb.png', Image, Options, Back);
    try
      Check((Back <> nil) and (Back.SourceBitsPerPixel = 24) and (LargestPixelDifference(Image, Back) = 0),
        'RGB asked for a grey picture');
    finally
      Back.Free;
    end;
  finally
    Image.Free;
  end;
end;

procedure TestLevels;
var
  Image: TImage;
  Back: TImage;
  Options: TPngWriteOptions;
  Level: LongInt;
  Sizes: array[0..9] of PtrInt;
  AllMatch: Boolean;
begin
  Image := MakePicture(PictureColorsAlpha, 97, 71);
  AllMatch := True;
  try
    for Level := 0 to 9 do
    begin
      Options := DefaultPngWriteOptions;
      Options.Level := Level;
      Sizes[Level] := Length(WriteAndReadBack('written-level-' + IntToStr(Level) + '.png', Image, Options, Back));
      AllMatch := AllMatch and (Back <> nil) and (LargestPixelDifference(Image, Back) = 0);
      Back.Free;
    end;
    Check(AllMatch, 'every compression level read back exactly');
    Check(Sizes[9] < Sizes[0], 'level 9 smaller than stored');
    Note(Format('sizes at levels 0, 1, 6, 9: %d, %d, %d, %d', [Sizes[0], Sizes[1], Sizes[6], Sizes[9]]));
  finally
    Image.Free;
  end;
end;

function SameBytes(const First, Second: TBytes): Boolean;
begin
  Result := (Length(First) = Length(Second)) and ((Length(First) = 0) or CompareMem(@First[0], @Second[0],
    Length(First)));
end;

procedure TestProperties;
var
  Image: TImage;
  Back: TImage;
  Profile: TBytes;
  Index: LongInt;
begin
  Image := MakePicture(PictureColors, 20, 10);
  try
    Image.Resolution := MakeResolution(300, 150);
    Image.Orientation := OrientationRotate270;
    Profile := nil;
    SetLength(Profile, 2000);
    for Index := 0 to High(Profile) do
      Profile[Index] := (Index * 7) and $FF;
    Image.IccProfile := Profile;
    Image.Metadata.SetValue('Title', 'Written');
    Image.Metadata.SetValue(MetadataKeyComment, 'gr'#$C3#$BC'n');
    Image.Metadata.SetValue(MetadataKeyHotspotX, '3');
    WriteAndReadBack('written-properties.png', Image, DefaultPngWriteOptions, Back);
    if Back = nil then
    begin
      Check(False, 'a picture with properties read back');
      Exit;
    end;
    try
      Check((Round(Back.Resolution.HorizontalDpi) = 300) and (Round(Back.Resolution.VerticalDpi) = 150),
        'the resolution written as pHYs');
      Check(Back.Orientation = OrientationRotate270, 'the orientation written as eXIf');
      Check(SameBytes(Back.IccProfile, Profile), 'the profile written as iCCP');
      Check(Back.Metadata.GetValue('Title') = 'Written', 'text written as tEXt');
      Check(Back.Metadata.GetValue(MetadataKeyComment) = 'gr'#$C3#$BC'n', 'UTF-8 text written as iTXt');
      Check(not Back.Metadata.Contains(MetadataKeyHotspotX), 'hotspots not written as text');
    finally
      Back.Free;
    end;
  finally
    Image.Free;
  end;
end;

procedure TestLarge;
var
  Image: TImage;
  Back: TImage;
  Started: TDateTime;
  Data: TBytes;
begin
  Image := MakePicture(PictureColors, 1600, 1200);
  try
    Started := Now;
    Data := EncodeImage(Image, ImageFormatPng);
    Note(Format('1600 x 1200 RGB written in %d ms, %d bytes', [MilliSecondsBetween(Now, Started), Length(Data)]));
    Back := LoadImage(Data);
    try
      Check(LargestPixelDifference(Image, Back) = 0, 'a large picture read back exactly');
    finally
      Back.Free;
    end;
  finally
    Image.Free;
  end;
end;

procedure TestPngWriting;
begin
  TestKinds;
  TestAskedDepths;
  TestLevels;
  TestProperties;
  TestLarge;
end;

end.
