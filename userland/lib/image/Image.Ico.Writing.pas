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
  Writing ICO and CUR files from images, one entry each (a 16, 32 and
  48 pixel version of a picture make one icon).

  Every entry is a DIB: a 40-byte header of twice the height, 32 bits
  per pixel with alpha, lines from the bottom up, then the mask (1 where
  alpha is zero) for programs that do not read alpha. Sides are 1 to
  256. A cursor's entries carry the hotspot, from each image's metadata
  (HotspotX, HotspotY; 0 when not set).
}
unit Image.Ico.Writing;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

uses
  SysUtils,
  Image.Errors,
  Image.Model,
  Image.Metadata,
  Image.ByteWriters,
  Image.Bmp.Headers,
  Image.Ico.Directory;

{ Images as an icon file (or a cursor file with IsCursor). }
function EncodeIconFile(const Images: array of TImage; IsCursor: Boolean): TBytes;

implementation

function DibEntrySize(Image: TImage): LongWord;
begin
  Result := BmpInfoHeaderSize + LongWord(Image.Width) * LongWord(Image.Height) * 4 +
    LongWord(BmpRowStride(Image.Width, 1)) * LongWord(Image.Height);
end;

procedure WriteDibEntry(Writer: TImageByteWriter; Image: TImage);
var
  Y: LongInt;
  X: LongInt;
  Line: PLongWord;
  MaskStride: LongInt;
  MaskLine: TBytes;
  Pixel: LongWord;
begin
  Writer.WriteLongLittle(BmpInfoHeaderSize);
  Writer.WriteLongLittle(LongWord(Image.Width));
  Writer.WriteLongLittle(LongWord(Image.Height * 2));
  Writer.WriteWordLittle(1);
  Writer.WriteWordLittle(32);
  Writer.WriteLongLittle(BmpCompressionRgb);
  Writer.WriteLongLittle(LongWord(Image.Width) * LongWord(Image.Height) * 4);
  Writer.WriteZeros(16);
  for Y := Image.Height - 1 downto 0 do
  begin
    Line := Image.Line(Y);
    for X := 0 to Image.Width - 1 do
    begin
      Pixel := Line[X];
      Writer.WriteByte(Pixel and $FF);
      Writer.WriteByte((Pixel shr 8) and $FF);
      Writer.WriteByte((Pixel shr 16) and $FF);
      Writer.WriteByte(Pixel shr 24);
    end;
  end;
  MaskStride := BmpRowStride(Image.Width, 1);
  MaskLine := nil;
  SetLength(MaskLine, MaskStride);
  for Y := Image.Height - 1 downto 0 do
  begin
    FillChar(MaskLine[0], MaskStride, 0);
    Line := Image.Line(Y);
    for X := 0 to Image.Width - 1 do
      if (Line[X] shr 24) = 0 then
        MaskLine[X shr 3] := MaskLine[X shr 3] or ($80 shr (X and 7));
    Writer.WriteBytes(MaskLine);
  end;
end;

function HotspotOf(Image: TImage; const Key: string): LongInt;
begin
  Result := StrToIntDef(Image.Metadata.GetValue(Key, '0'), 0);
  if Result < 0 then
    Result := 0;
end;

function EncodeIconFile(const Images: array of TImage; IsCursor: Boolean): TBytes;
var
  Writer: TImageByteWriter;
  Index: LongInt;
  Image: TImage;
  Offset: LongWord;
begin
  if Length(Images) = 0 then
    RaiseImageError(ImageErrorUnsupported, 'an icon needs an image');
  if Length(Images) > 65535 then
    RaiseImageError(ImageErrorTooLarge, 'too many icon entries');
  for Index := 0 to High(Images) do
    if (Images[Index].Width > 256) or (Images[Index].Height > 256) then
      RaiseImageError(ImageErrorTooLarge, 'icon entries are 256 pixels at most');
  Writer := TImageByteWriter.Create;
  try
    Writer.WriteWordLittle(0);
    if IsCursor then
      Writer.WriteWordLittle(IconTypeCursor)
    else
      Writer.WriteWordLittle(IconTypeIcon);
    Writer.WriteWordLittle(Length(Images));
    Offset := IconDirectoryHeaderSize + IconDirectoryEntrySize * LongWord(Length(Images));
    for Index := 0 to High(Images) do
    begin
      Image := Images[Index];
      Writer.WriteByte(Image.Width and $FF);
      Writer.WriteByte(Image.Height and $FF);
      Writer.WriteByte(0);
      Writer.WriteByte(0);
      if IsCursor then
      begin
        Writer.WriteWordLittle(HotspotOf(Image, MetadataKeyHotspotX));
        Writer.WriteWordLittle(HotspotOf(Image, MetadataKeyHotspotY));
      end
      else
      begin
        Writer.WriteWordLittle(1);
        Writer.WriteWordLittle(32);
      end;
      Writer.WriteLongLittle(DibEntrySize(Image));
      Writer.WriteLongLittle(Offset);
      Inc(Offset, DibEntrySize(Image));
    end;
    for Index := 0 to High(Images) do
      WriteDibEntry(Writer, Images[Index]);
    Result := Writer.ToBytes;
  finally
    Writer.Free;
  end;
end;

end.
