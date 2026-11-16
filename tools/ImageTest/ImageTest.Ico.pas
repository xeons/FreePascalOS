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
  ICO and CUR (make-fixtures.py): a directory of four sizes and depths
  with masks and alpha, every entry decoded; picking the entry nearest
  a size and scale; PNG entries reported as needing PNG, and a file
  with a DIB beside them still loading; Pillow's BMP icons; a cursor's
  hotspots; writing several sizes and reading them back; malformed
  directories refused.
}
unit ImageTest.Ico;

{$mode objfpc}
{$H+}

interface

procedure TestIco;

implementation

uses
  SysUtils,
  Image.Errors,
  Image.Model,
  Image.Metadata,
  Image.Codecs,
  Image.Files,
  Image.Ico.Directory,
  Image.Ico.Reading,
  Image.Ico.Writing,
  ImageTest.Checks;

function EntryWithSide(Directory: TIconDirectory; Side: LongInt): LongInt;
var
  Index: LongInt;
begin
  for Index := 0 to Directory.Count - 1 do
    if Directory.Entries[Index].Width = Side then
      Exit(Index);
  Result := -1;
end;

procedure CheckEntry(Directory: TIconDirectory; Side: LongInt; const ReferenceName: string);
var
  Index: LongInt;
  Image: TImage;
begin
  Index := EntryWithSide(Directory, Side);
  if Index < 0 then
  begin
    Check(False, ReferenceName + ': no entry of ' + IntToStr(Side));
    Exit;
  end;
  Image := nil;
  try
    try
      Image := DecodeIconEntry(Directory, Index);
    except
      on Error: Exception do
        Note(ReferenceName + ': ' + Error.Message);
    end;
    CheckImageMatchesReference(ReferenceName + ' entry pixels', Image, ReferenceName, 0);
  finally
    Image.Free;
  end;
end;

procedure TestDirectory;
var
  Directory: TIconDirectory;
  Image: TImage;
begin
  Directory := TIconDirectory.Create(FixtureBytes('icon-multi.ico'));
  try
    Check(Directory.Count = 4, 'icon directory of four entries');
    Check(not Directory.IsCursor, 'an icon is not a cursor');
    CheckEntry(Directory, 16, 'icon-multi-16.rgba');
    CheckEntry(Directory, 24, 'icon-multi-24.rgba');
    CheckEntry(Directory, 32, 'icon-multi-32.rgba');
    CheckEntry(Directory, 48, 'icon-multi-48.rgba');
    Check(Directory.Entries[EntryWithSide(Directory, 24)].BitsPerPixel = 1, 'entry depth from its DIB header');
    Check(Directory.Entries[Directory.NearestEntry(16)].Width = 16, 'nearest to 16: 16');
    Check(Directory.Entries[Directory.NearestEntry(20)].Width = 24, 'nearest to 20: the next larger, 24');
    Check(Directory.Entries[Directory.NearestEntry(16, 2.0)].Width = 32, 'nearest to 16 at 200 %: 32');
    Check(Directory.Entries[Directory.NearestEntry(16, 1.5)].Width = 24, 'nearest to 16 at 150 %: 24');
    Check(Directory.Entries[Directory.NearestEntry(64)].Width = 48, 'nearest to 64: the largest, 48');
    Check(Directory.Entries[Directory.NearestEntry(1)].Width = 16, 'nearest to 1: the smallest, 16');
    Check(Directory.Entries[Directory.LargestEntry].Width = 48, 'largest entry 48');
  finally
    Directory.Free;
  end;
  Image := LoadImage(FixtureBytes('icon-multi.ico'));
  try
    CheckImageMatchesReference('an icon loads as its largest entry', Image, 'icon-multi-48.rgba', 0);
    Check(Image.SourceFormatName = 'ICO', 'format name ICO');
  finally
    Image.Free;
  end;
  Image := LoadImage(FixtureBytes('pillow-bmp.ico'));
  try
    CheckImageMatchesReference('Pillow''s BMP icon', Image, 'pillow-bmp.rgba', 0);
  finally
    Image.Free;
  end;
end;

procedure TestPngEntries;
var
  Directory: TIconDirectory;
  Image: TImage;
  Reason: TImageErrorReason;
  PngIndex: LongInt;
begin
  Directory := TIconDirectory.Create(FixtureBytes('icon-png-mixed.ico'));
  try
    PngIndex := EntryWithSide(Directory, 64);
    Check((PngIndex >= 0) and Directory.Entries[PngIndex].IsPng, 'a PNG entry is recognised, with its size');
    Reason := ImageErrorNone;
    try
      DecodeIconEntry(Directory, PngIndex).Free;
    except
      on Error: EImageError do
        Reason := Error.Reason;
    end;
    Check(Reason = ImageErrorNeedsPng, 'a PNG entry needs PNG');
  finally
    Directory.Free;
  end;
  Image := LoadImage(FixtureBytes('icon-png-mixed.ico'));
  try
    Check((Image.Width = 16) and (Image.Height = 16), 'beside a PNG entry the DIB entry is loaded');
  finally
    Image.Free;
  end;
  Image := nil;
  Check(not TryLoadImage(FixtureBytes('icon-png-only.ico'), Image, Reason) and (Reason = ImageErrorNeedsPng),
    'an icon of PNG entries only needs PNG');
  Image.Free;
end;

procedure TestCursor;
var
  Directory: TIconDirectory;
  Image: TImage;
  Index: LongInt;
begin
  Check(DetectFileFormat(FixtureBytes('pointer.cur')) = ImageFormatCur, 'a cursor file is recognised');
  Directory := TIconDirectory.Create(FixtureBytes('pointer.cur'));
  try
    Check(Directory.IsCursor, 'a cursor directory');
    CheckEntry(Directory, 32, 'pointer-32.rgba');
    CheckEntry(Directory, 48, 'pointer-48.rgba');
    Index := EntryWithSide(Directory, 32);
    Check((Directory.Entries[Index].HotspotX = 5) and (Directory.Entries[Index].HotspotY = 7), 'cursor hotspot 5, 7');
    Image := DecodeIconEntry(Directory, EntryWithSide(Directory, 48));
    try
      Check((Image.Metadata.GetValue(MetadataKeyHotspotX) = '8') and
        (Image.Metadata.GetValue(MetadataKeyHotspotY) = '10'), 'cursor hotspot in the metadata');
      Check(Image.SourceFormatName = 'CUR', 'format name CUR');
    finally
      Image.Free;
    end;
  finally
    Directory.Free;
  end;
end;

procedure TestWriting;
var
  Images: array[0..2] of TImage;
  Data: TBytes;
  Directory: TIconDirectory;
  Back: TImage;
  Index: LongInt;
  Side: LongInt;
  X: LongInt;
  Y: LongInt;
  AllMatch: Boolean;
begin
  for Index := 0 to 2 do
  begin
    Side := 16 * (Index + 1);
    Images[Index] := TImage.Create(Side, Side);
    for Y := 0 to Side - 1 do
      for X := 0 to Side - 1 do
        if (X + Y) mod 5 = 0 then
          Images[Index].SetPixel(X, Y, 0)
        else
          Images[Index].SetPixel(X, Y, (LongWord((X * 16) and $FF) shl 24) or LongWord(Y * 1000 + X));
    Images[Index].Metadata.SetValue(MetadataKeyHotspotX, IntToStr(Index + 1));
    Images[Index].Metadata.SetValue(MetadataKeyHotspotY, IntToStr(Index + 2));
  end;
  try
    for Index := 0 to 2 do
      for Y := 0 to Images[Index].Height - 1 do
        for X := 0 to Images[Index].Width - 1 do
          if (Images[Index].GetPixel(X, Y) shr 24) = 0 then
            Images[Index].SetPixel(X, Y, 0);
    Data := EncodeIconFile(Images, False);
    Directory := TIconDirectory.Create(Data);
    try
      AllMatch := Directory.Count = 3;
      for Index := 0 to Directory.Count - 1 do
      begin
        Back := DecodeIconEntry(Directory, Index);
        try
          AllMatch := AllMatch and (LargestPixelDifference(Back, Images[Index]) = 0);
        finally
          Back.Free;
        end;
      end;
      Check(AllMatch, 'an icon of three sizes written and read back');
    finally
      Directory.Free;
    end;
    Data := EncodeIconFile(Images, True);
    Directory := TIconDirectory.Create(Data);
    try
      Check(Directory.IsCursor and (Directory.Entries[1].HotspotX = 2) and (Directory.Entries[1].HotspotY = 3),
        'a cursor written with its hotspots');
    finally
      Directory.Free;
    end;
  finally
    for Index := 0 to 2 do
      Images[Index].Free;
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
var
  Directory: TIconDirectory;
  Reason: TImageErrorReason;
begin
  CheckRefused('bad-ico-offset.ico', ImageErrorTruncated);
  CheckRefused('bad-ico-count.ico', ImageErrorTruncated);
  CheckRefused('bad-ico-truncated.ico', ImageErrorTruncated);
  { The first entry's DIB says a height of 0. }
  Directory := TIconDirectory.Create(FixtureBytes('bad-ico-height.ico'));
  try
    Reason := ImageErrorNone;
    try
      DecodeIconEntry(Directory, 0).Free;
    except
      on Error: EImageError do
        Reason := Error.Reason;
    end;
    Check(Reason = ImageErrorMalformed, 'an icon entry of no height refused');
  finally
    Directory.Free;
  end;
end;

procedure TestIco;
begin
  TestDirectory;
  TestPngEntries;
  TestCursor;
  TestWriting;
  TestMalformed;
end;

end.
