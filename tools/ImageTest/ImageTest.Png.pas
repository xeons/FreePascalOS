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
  Decoding PNG (make-png-fixtures.py): every colour type at every depth,
  plain and interlaced; tRNS of each kind; tiny interlaced pictures;
  each filter alone; image data in one-byte and empty chunks, stored,
  without IEND; a suggested palette, a short palette, unknown ancillary
  chunks; every ancillary chunk read into the image; files Pillow
  wrote, one of them large (timed); broken files refused with the
  reason they deserve; and image data damaged with the CRCs put right,
  so the damage reaches the decompressor and the filters, which must
  load or be refused, never crash. Every lossless picture must equal
  its reference exactly.
}
unit ImageTest.Png;

{$mode objfpc}
{$H+}

interface

procedure TestPng;

implementation

uses
  SysUtils,
  DateUtils,
  StrUtils,
  Image.Errors,
  Image.Model,
  Image.Metadata,
  Image.Codecs,
  Image.Files,
  Image.Png.Ancillary,
  Compression.Checksums,
  ImageTest.Checks;

{ Loads Name and compares it with Name's reference; True when it loaded. }
function CheckPng(const Name: string; ExpectedBits: LongInt = 0): Boolean;
var
  Image: TImage;
begin
  Image := nil;
  try
    try
      Image := LoadImage(FixtureBytes(Name));
    except
      on Error: Exception do
        Note(Name + ': ' + Error.ClassName + ': ' + Error.Message);
    end;
    CheckImageMatchesReference(Name, Image, ChangeFileExt(Name, '.rgba'), 0);
    if (Image <> nil) and (ExpectedBits > 0) then
      Check(Image.SourceBitsPerPixel = ExpectedBits, Name + ' is ' + IntToStr(ExpectedBits) + ' bits per pixel');
    Result := Image <> nil;
  finally
    Image.Free;
  end;
end;

procedure TestColorTypes;
const
  Channels: array[0..6] of LongInt = (1, 0, 3, 1, 2, 0, 4);
  Depths: array[0..4] of LongInt = (1, 2, 4, 8, 16);
  ColorTypes: array[0..4] of LongInt = (0, 2, 3, 4, 6);
var
  TypeIndex: LongInt;
  DepthIndex: LongInt;
  ColorType: LongInt;
  Depth: LongInt;
  Name: string;
begin
  for TypeIndex := 0 to High(ColorTypes) do
    for DepthIndex := 0 to High(Depths) do
    begin
      ColorType := ColorTypes[TypeIndex];
      Depth := Depths[DepthIndex];
      Name := Format('png-c%d-d%d', [ColorType, Depth]);
      if not FileExists(FixturePath(Name + '.png')) then
        Continue;
      CheckPng(Name + '.png', Channels[ColorType] * Depth);
      CheckPng(Name + '-i.png', Channels[ColorType] * Depth);
    end;
end;

procedure TestTransparency;
const
  Names: array[0..7] of string = ('png-trns-grey1.png', 'png-trns-grey4.png', 'png-trns-grey8.png',
    'png-trns-grey16.png', 'png-trns-rgb8.png', 'png-trns-rgb16.png', 'png-trns-palette4.png',
    'png-trns-palette8.png');
var
  Index: LongInt;
  Image: TImage;
begin
  for Index := 0 to High(Names) do
    CheckPng(Names[Index]);
  Image := LoadImage(FixtureBytes('png-trns-rgb8.png'));
  try
    Check(Image.SourceHasAlpha, 'a tRNS colour counts as alpha');
  finally
    Image.Free;
  end;
  Image := LoadImage(FixtureBytes('png-c2-d8.png'));
  try
    Check(not Image.SourceHasAlpha, 'RGB without tRNS has no alpha');
  finally
    Image.Free;
  end;
end;

procedure TestSizes;
const
  Sizes: array[0..9, 0..1] of LongInt = ((1, 1), (2, 2), (3, 3), (4, 4), (5, 5), (7, 1), (1, 9), (8, 8), (9, 9),
    (33, 2));
  ColorTypes: array[0..2] of LongInt = (6, 3, 0);
var
  SizeIndex: LongInt;
  TypeIndex: LongInt;
  AllMatch: Boolean;
  Name: string;
  Image: TImage;
begin
  AllMatch := True;
  for SizeIndex := 0 to High(Sizes) do
    for TypeIndex := 0 to High(ColorTypes) do
    begin
      Name := Format('png-size-%dx%d-c%d.png', [Sizes[SizeIndex, 0], Sizes[SizeIndex, 1], ColorTypes[TypeIndex]]);
      Image := nil;
      try
        try
          Image := LoadImage(FixtureBytes(Name));
        except
          on Error: Exception do
            Note(Name + ': ' + Error.Message);
        end;
        if Image = nil then
          AllMatch := False
        else
          CheckImageMatchesReference(Name, Image, ChangeFileExt(Name, '.rgba'), 0);
      finally
        Image.Free;
      end;
    end;
  Check(AllMatch, 'every tiny interlaced picture loads');
end;

procedure TestChunking;
var
  Kind: LongInt;
begin
  for Kind := 0 to 4 do
    CheckPng('png-filter-' + IntToStr(Kind) + '.png');
  CheckPng('png-idat-bytes.png');
  CheckPng('png-idat-empty.png');
  CheckPng('png-stored.png');
  CheckPng('png-no-end.png');
  CheckPng('png-rgb-palette.png');
  CheckPng('png-short-palette.png', 4);
  CheckPng('png-unknown-ancillary.png');
end;

procedure TestPillowFiles;
var
  Started: TDateTime;
  Image: TImage;
begin
  CheckPng('pillow-rgb.png');
  CheckPng('pillow-palette.png');
  CheckPng('pillow-grey.png', 8);
  CheckPng('pillow-grey-alpha.png', 16);
  CheckPng('pillow-bilevel.png', 1);
  CheckPng('pillow-rgba.png', 32);
  Started := Now;
  Image := LoadImage(FixtureBytes('pillow-large.png'));
  try
    Note(Format('1600 x 1200 RGB decoded in %d ms', [MilliSecondsBetween(Now, Started)]));
    CheckImageMatchesReference('a large picture', Image, 'pillow-large.rgba', 0);
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
  Image := LoadImage(FixtureBytes('png-metadata.png'));
  try
    CheckImageMatchesReference('a picture with every ancillary chunk', Image, 'png-metadata.rgba', 0);
    Check((Round(Image.Resolution.HorizontalDpi) = 300) and (Round(Image.Resolution.VerticalDpi) = 150),
      'pHYs as 300 x 150 dpi');
    Check(SameBytes(Image.IccProfile, FixtureBytes('png-metadata.icc')), 'iCCP profile decompressed');
    Check(Image.Orientation = OrientationRotate90, 'eXIf orientation 6');
    Check(Image.Metadata.GetValue('Title') = 'A test picture', 'tEXt title');
    Check(Image.Metadata.GetValue('Author') = 'Gr'#$C3#$BC'n', 'tEXt Latin-1 as UTF-8');
    Check(Image.Metadata.GetValue(MetadataKeyDescription) = DupeString('Compressed text ', 20), 'zTXt');
    Check(Image.Metadata.GetValue(MetadataKeyComment) = #$E6#$97#$A5#$E6#$9C#$AC#$E8#$AA#$9E, 'iTXt UTF-8');
    Check(Image.Metadata.GetValue(MetadataKeySoftware) = 'caf'#$C3#$A9' writer', 'compressed iTXt');
    Check(Image.Metadata.GetValue('Disclaimer') = 'after the image data', 'text after the image data');
    Check(Image.Metadata.GetValue(MetadataKeyGamma) = '0.45455', 'gAMA');
    Check(Image.Metadata.GetValue(MetadataKeyChromaticities) =
      '0.31270 0.32900 0.64000 0.33000 0.30000 0.60000 0.15000 0.06000', 'cHRM');
    Check(Image.Metadata.GetValue(MetadataKeyModificationTime) = '2026-11-16 12:30:05', 'tIME');
    Check(Image.SourceFormatName = 'PNG', 'format name PNG');
  finally
    Image.Free;
  end;
  Image := LoadImage(FixtureBytes('png-srgb.png'));
  try
    Check((Image.Metadata.GetValue(MetadataKeyColorSpace) = 'sRGB') and
      (Image.Metadata.GetValue(MetadataKeyRenderingIntent) = 'RelativeColorimetric'), 'sRGB and its intent');
  finally
    Image.Free;
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

procedure TestBroken;
begin
  CheckRefused('bad-png-signature.png', ImageErrorUnknownFormat);
  CheckRefused('bad-png-header-crc.png', ImageErrorMalformed);
  CheckRefused('bad-png-data-crc.png', ImageErrorMalformed);
  CheckRefused('bad-png-color-type.png', ImageErrorMalformed);
  CheckRefused('bad-png-depth.png', ImageErrorMalformed);
  CheckRefused('bad-png-interlace.png', ImageErrorMalformed);
  CheckRefused('bad-png-compression.png', ImageErrorMalformed);
  CheckRefused('bad-png-zero-width.png', ImageErrorMalformed);
  CheckRefused('bad-png-huge.png', ImageErrorTooLarge);
  CheckRefused('bad-png-no-palette.png', ImageErrorMalformed);
  CheckRefused('bad-png-no-data.png', ImageErrorMalformed);
  CheckRefused('bad-png-filter-type.png', ImageErrorMalformed);
  CheckRefused('bad-png-adler.png', ImageErrorMalformed);
  CheckRefused('bad-png-short-data.png', ImageErrorMalformed);
  CheckRefused('bad-png-garbage-data.png', ImageErrorMalformed);
  CheckRefused('bad-png-truncated.png', ImageErrorTruncated);
  CheckRefused('bad-png-critical.png', ImageErrorUnsupported);
  CheckRefused('bad-png-chunk-name.png', ImageErrorMalformed);
  Check(DetectFileFormat(FixtureBytes('png-c2-d8.png')) = ImageFormatPng, 'a PNG file is recognised');
end;

{ --- Damage behind correct CRCs ------------------------------------- }

var
  RandomState: LongWord = 271828;

function NextRandom(Limit: LongWord): LongWord;
begin
  RandomState := RandomState * 1103515245 + 12345;
  Result := (RandomState shr 8) mod Limit;
end;

function BigLongAt(const Data: TBytes; Offset: PtrInt): LongWord;
begin
  Result := (LongWord(Data[Offset]) shl 24) or (LongWord(Data[Offset + 1]) shl 16) or
    (LongWord(Data[Offset + 2]) shl 8) or Data[Offset + 3];
end;

procedure PutBigLong(var Data: TBytes; Offset: PtrInt; Value: LongWord);
begin
  Data[Offset] := Value shr 24;
  Data[Offset + 1] := (Value shr 16) and $FF;
  Data[Offset + 2] := (Value shr 8) and $FF;
  Data[Offset + 3] := Value and $FF;
end;

{ Changes a few bytes inside the data of chunks other than IHDR and
  puts every CRC right again. }
procedure DamageBehindCrcs(var Data: TBytes);
var
  Position: PtrInt;
  ChunkLength: PtrInt;
  Changes: LongInt;
begin
  Position := 8;
  while Position + 12 <= Length(Data) do
  begin
    ChunkLength := BigLongAt(Data, Position);
    if Position + 12 + ChunkLength > Length(Data) then
      Break;
    if (ChunkLength > 0) and (Position > 8) then
    begin
      Changes := NextRandom(3);
      while Changes > 0 do
      begin
        Data[Position + 8 + NextRandom(ChunkLength)] := NextRandom(256);
        Dec(Changes);
      end;
    end;
    PutBigLong(Data, Position + 8 + ChunkLength, Crc32(Crc32Initial, @Data[Position + 4], ChunkLength + 4));
    Position := Position + 12 + ChunkLength;
  end;
end;

procedure TestDamageBehindCrcs;
const
  Names: array[0..7] of string = ('png-c0-d2-i.png', 'png-c3-d8.png', 'png-c4-d16.png', 'png-c6-d8-i.png',
    'png-metadata.png', 'png-trns-palette4.png', 'apng-default-frame.png', 'apng-palette.png');
  Rounds = 30;
var
  NameIndex: LongInt;
  Attempt: LongInt;
  Good: TBytes;
  Damaged: TBytes;
  Image: TImage;
  Problem: string;
begin
  for NameIndex := 0 to High(Names) do
  begin
    Good := FixtureBytes(Names[NameIndex]);
    Problem := '';
    for Attempt := 1 to Rounds do
    begin
      Damaged := Copy(Good);
      DamageBehindCrcs(Damaged);
      Image := nil;
      try
        Image := LoadImage(Damaged);
      except
        on EImageError do
          ;
        on Error: Exception do
          Problem := Format('round %d: %s: %s', [Attempt, Error.ClassName, Error.Message]);
      end;
      Image.Free;
      if Problem <> '' then
        Break;
    end;
    Check(Problem = '', Names[NameIndex] + ' damaged behind good CRCs loads or is refused');
    if Problem <> '' then
      Note(Problem);
  end;
end;

procedure TestPng;
begin
  TestColorTypes;
  TestTransparency;
  TestSizes;
  TestChunking;
  TestPillowFiles;
  TestMetadata;
  TestBroken;
  TestDamageBehindCrcs;
end;

end.
