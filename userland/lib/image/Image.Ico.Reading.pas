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
  Decoding one entry of an icon or cursor.

  A DIB entry's header gives twice the picture's height: the colours
  (any BMP depth) and then a mask, one bit a pixel, lines padded to four
  bytes and in the same order, 1 where the picture is transparent. A
  32-bit entry carries alpha of its own, and the mask counts only when
  that alpha is zero everywhere. A mask that is missing leaves the
  picture opaque.

  A PNG entry is decoded through Image.Codecs' embedded image hook, by
  the PNG decoder Image.StandardCodecs registers (a program that
  registers codecs of its own without it gets ImageErrorNeedsPng).

  For a cursor the entry's hotspot goes into the metadata (HotspotX,
  HotspotY).
}
unit Image.Ico.Reading;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

uses
  SysUtils,
  Image.Errors,
  Image.Model,
  Image.Metadata,
  Image.Codecs,
  Image.Bmp.Headers,
  Image.Bmp.Reading,
  Image.Ico.Directory;

function DecodeIconEntry(Directory: TIconDirectory; Index: LongInt): TImage;
{ Applies a 1-bit mask (1 transparent) at MaskOffset of Data to Image,
  lines from the bottom up unless TopDown; nothing if it is cut short. }
procedure ApplyIconMask(const Data: TBytes; MaskOffset: PtrInt; Image: TImage; TopDown: Boolean);

implementation

procedure ApplyIconMask(const Data: TBytes; MaskOffset: PtrInt; Image: TImage; TopDown: Boolean);
var
  Stride: Int64;
  Row: LongInt;
  Y: LongInt;
  X: LongInt;
  Line: PLongWord;
  MaskByte: Byte;
begin
  Stride := BmpRowStride(Image.Width, 1);
  if (MaskOffset < 0) or (MaskOffset + Stride * (Image.Height - 1) + (Image.Width + 7) div 8 > Length(Data)) then
    Exit;
  for Row := 0 to Image.Height - 1 do
  begin
    if TopDown then
      Y := Row
    else
      Y := Image.Height - 1 - Row;
    Line := Image.Line(Y);
    for X := 0 to Image.Width - 1 do
    begin
      MaskByte := Data[MaskOffset + Stride * Row + X shr 3];
      if ((MaskByte shr (7 - (X and 7))) and 1) <> 0 then
        Line[X] := 0;
    end;
  end;
end;

function DecodeDibEntry(const Data: TBytes): TImage;
var
  Info: TBmpInfo;
  PixelOffset: PtrInt;
  MaskOffset: Int64;
  HasAlpha: Boolean;
begin
  PixelOffset := ReadBmpInfo(Data, 0, Info);
  Info.Height := Info.Height div 2;
  if Info.Height < 1 then
    RaiseImageError(ImageErrorMalformed, 'icon height');
  Result := TImage.Create(Info.Width, Info.Height);
  try
    HasAlpha := DecodeBmpPixels(Data, PixelOffset, Info, Result);
    if not (Info.Compression in [BmpCompressionRle4, BmpCompressionRle8]) and not HasAlpha then
    begin
      MaskOffset := PixelOffset + BmpRowStride(Info.Width, Info.BitsPerPixel) * Info.Height;
      if MaskOffset <= Length(Data) then
        ApplyIconMask(Data, MaskOffset, Result, Info.TopDown);
    end;
    Result.SourceBitsPerPixel := Info.BitsPerPixel;
    Result.SourceHasAlpha := not Result.IsOpaque;
  except
    Result.Free;
    raise;
  end;
end;

function DecodeIconEntry(Directory: TIconDirectory; Index: LongInt): TImage;
var
  Entry: TIconEntry;
  Bytes: TBytes;
begin
  Entry := Directory.Entries[Index];
  Bytes := Directory.EntryBytes(Index);
  if Entry.IsPng then
    Result := DecodeEmbeddedImage(Bytes)
  else
    Result := DecodeDibEntry(Bytes);
  if Directory.IsCursor then
  begin
    Result.SourceFormatName := ImageFormatName(ImageFormatCur);
    Result.Metadata.SetValue(MetadataKeyHotspotX, IntToStr(Entry.HotspotX));
    Result.Metadata.SetValue(MetadataKeyHotspotY, IntToStr(Entry.HotspotY));
  end
  else
    Result.SourceFormatName := ImageFormatName(ImageFormatIco);
end;

end.
