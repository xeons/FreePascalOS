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
  Reading a DIB's pixels: 1, 4 and 8 bits through the palette (RLE4
  and RLE8 through Image.Bmp.Rle), 16 and 32 bits through the colour
  masks, 24 bits as blue, green, red.

  Alpha: from the alpha mask when the file gives one (BITFIELDS in a V3
  to V5 header, ALPHABITFIELDS); for 32 bits without masks the fourth
  byte, which the format calls reserved but icons and many programs use
  for alpha, unless it is zero everywhere (then the picture is opaque).
  Everything else is opaque.

  DecodeDib reads a whole DIB (header, masks, palette, pixels);
  DecodeBmpPixels only the pixels, for icons, whose entries are DIBs of
  twice their height with a mask after the colours.
}
unit Image.Bmp.Reading;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

uses
  SysUtils,
  Drawing.Colors,
  Image.Errors,
  Image.Model,
  Image.Metadata,
  Image.Bmp.Headers,
  Image.Bmp.Masks,
  Image.Bmp.Rle;

{ The pixels of Info's DIB, at PixelOffset of Data, into Image (Info's
  width and height). Raises ImageErrorTruncated when lines are missing.
  Returns whether the pixels carry alpha. }
function DecodeBmpPixels(const Data: TBytes; PixelOffset: PtrInt; const Info: TBmpInfo; Image: TImage): Boolean;
{ The DIB at DibStart of Data; its pixels at PixelOffset, or right after
  the palette when PixelOffset is negative. }
function DecodeDib(const Data: TBytes; DibStart, PixelOffset: PtrInt): TImage;
{ The bytes the uncompressed pixels need, the last line unpadded. }
function BmpPixelBytesNeeded(const Info: TBmpInfo): Int64;

implementation

function BmpPixelBytesNeeded(const Info: TBmpInfo): Int64;
begin
  Result := BmpRowStride(Info.Width, Info.BitsPerPixel) * (Info.Height - 1) +
    (Int64(Info.Width) * Info.BitsPerPixel + 7) div 8;
end;

function PaletteColor(const Info: TBmpInfo; PaletteIndex: LongInt): TColor; inline;
begin
  if PaletteIndex < Length(Info.Palette) then
    Result := Info.Palette[PaletteIndex]
  else
    Result := ColorBlack;
end;

procedure DecodeIndexedLine(Source: PByte; Target: PLongWord; const Info: TBmpInfo);
var
  X: LongInt;
  BitsPerPixel: LongInt;
  PaletteIndex: LongInt;
  Shift: LongInt;
begin
  BitsPerPixel := Info.BitsPerPixel;
  for X := 0 to Info.Width - 1 do
  begin
    case BitsPerPixel of
      1:
        begin
          Shift := 7 - (X and 7);
          PaletteIndex := (Source[X shr 3] shr Shift) and 1;
        end;
      4:
        if (X and 1) = 0 then
          PaletteIndex := Source[X shr 1] shr 4
        else
          PaletteIndex := Source[X shr 1] and 15;
    else
      PaletteIndex := Source[X];
    end;
    Target[X] := PaletteColor(Info, PaletteIndex);
  end;
end;

procedure DecodeMaskedLine(Source: PByte; Target: PLongWord; const Info: TBmpInfo;
  const Red, Green, Blue, Alpha: TColorField);
var
  X: LongInt;
  Pixel: LongWord;
  AlphaValue: Byte;
begin
  for X := 0 to Info.Width - 1 do
  begin
    if Info.BitsPerPixel = 16 then
      Pixel := Source[2 * X] or (LongWord(Source[2 * X + 1]) shl 8)
    else
      Pixel := PLongWord(Source)[X];
    {$ifdef ENDIAN_BIG}
    if Info.BitsPerPixel = 32 then
      Pixel := SwapEndian(Pixel);
    {$endif}
    if Alpha.Bits = 0 then
      AlphaValue := AlphaOpaque
    else
      AlphaValue := ExtractField(Alpha, Pixel);
    Target[X] := ArgbColor(AlphaValue, ExtractField(Red, Pixel), ExtractField(Green, Pixel),
      ExtractField(Blue, Pixel));
  end;
end;

procedure DecodeTrueColorLine(Source: PByte; Target: PLongWord; const Info: TBmpInfo);
var
  X: LongInt;
begin
  if Info.BitsPerPixel = 24 then
    for X := 0 to Info.Width - 1 do
      Target[X] := ArgbColor(AlphaOpaque, Source[3 * X + 2], Source[3 * X + 1], Source[3 * X])
  else
    for X := 0 to Info.Width - 1 do
      Target[X] := ArgbColor(Source[4 * X + 3], Source[4 * X + 2], Source[4 * X + 1], Source[4 * X]);
end;

{ For 32 bits without masks: an alpha byte of zero everywhere means
  there is no alpha. Returns whether there was. }
function SettleReservedAlpha(Image: TImage): Boolean;
var
  Index: PtrUInt;
  Count: PtrUInt;
begin
  Count := PtrUInt(Image.Width) * PtrUInt(Image.Height);
  Index := 0;
  while Index < Count do
  begin
    if (Image.Pixels[Index] shr 24) <> 0 then
      Exit(True);
    Inc(Index);
  end;
  Index := 0;
  while Index < Count do
  begin
    Image.Pixels[Index] := Image.Pixels[Index] or $FF000000;
    Inc(Index);
  end;
  Result := False;
end;

function DecodeBmpPixels(const Data: TBytes; PixelOffset: PtrInt; const Info: TBmpInfo; Image: TImage): Boolean;
var
  Stride: Int64;
  Row: LongInt;
  Y: LongInt;
  Source: PByte;
  Target: PLongWord;
  Red: TColorField;
  Green: TColorField;
  Blue: TColorField;
  Alpha: TColorField;
  UsesMasks: Boolean;
begin
  if (PixelOffset < 0) or (PixelOffset > Length(Data)) then
    RaiseImageError(ImageErrorTruncated, 'pixels');
  if Info.Compression in [BmpCompressionRle4, BmpCompressionRle8] then
  begin
    DecodeBmpRle(Data, PixelOffset, Info, Image);
    { Pixels the runs skip are transparent. }
    Exit(not Image.IsOpaque);
  end;
  if BmpPixelBytesNeeded(Info) > Length(Data) - PixelOffset then
    RaiseImageError(ImageErrorTruncated, 'pixels');
  Stride := BmpRowStride(Info.Width, Info.BitsPerPixel);
  UsesMasks := (Info.BitsPerPixel = 16) or ((Info.BitsPerPixel = 32) and Info.HasMasks);
  Red := MakeColorField(Info.RedMask);
  Green := MakeColorField(Info.GreenMask);
  Blue := MakeColorField(Info.BlueMask);
  Alpha := MakeColorField(Info.AlphaMask);
  for Row := 0 to Info.Height - 1 do
  begin
    if Info.TopDown then
      Y := Row
    else
      Y := Info.Height - 1 - Row;
    Source := @Data[PixelOffset + Stride * Row];
    Target := Image.Line(Y);
    if Info.BitsPerPixel <= 8 then
      DecodeIndexedLine(Source, Target, Info)
    else if UsesMasks then
      DecodeMaskedLine(Source, Target, Info, Red, Green, Blue, Alpha)
    else
      DecodeTrueColorLine(Source, Target, Info);
  end;
  if (Info.BitsPerPixel = 32) and not Info.HasMasks then
    Result := SettleReservedAlpha(Image)
  else
    Result := UsesMasks and (Alpha.Bits > 0);
end;

function ColorSpaceName(ColorSpaceType: LongWord): string;
begin
  case ColorSpaceType of
    BmpColorSpaceCalibrated: Result := 'calibrated RGB';
    BmpColorSpaceSrgb: Result := 'sRGB';
    BmpColorSpaceWindows: Result := 'sRGB';
    BmpColorSpaceLinked: Result := 'linked profile';
    BmpColorSpaceEmbedded: Result := 'embedded profile';
  else
    Result := '';
  end;
end;

function DecodeDib(const Data: TBytes; DibStart, PixelOffset: PtrInt): TImage;
var
  Info: TBmpInfo;
  PaletteEnd: PtrInt;
  HasAlpha: Boolean;
begin
  PaletteEnd := ReadBmpInfo(Data, DibStart, Info);
  if PixelOffset < 0 then
    PixelOffset := PaletteEnd;
  Result := TImage.Create(Info.Width, Info.Height);
  try
    HasAlpha := DecodeBmpPixels(Data, PixelOffset, Info, Result);
    Result.SourceBitsPerPixel := Info.BitsPerPixel;
    Result.SourceHasAlpha := HasAlpha;
    if (Info.HorizontalPixelsPerMeter > 0) and (Info.VerticalPixelsPerMeter > 0) then
      Result.Resolution := BmpResolution(Info);
    if Info.HeaderSize >= BmpV4HeaderSize then
      Result.Metadata.SetValue(MetadataKeyColorSpace, ColorSpaceName(Info.ColorSpaceType));
    if (Info.ProfileOffset > 0) and (Info.ProfileSize > 0) and (Info.ProfileOffset < Length(Data)) and
      (Info.ProfileSize <= Length(Data) - Info.ProfileOffset) then
      Result.IccProfile := Copy(Data, Info.ProfileOffset, Info.ProfileSize);
  except
    Result.Free;
    raise;
  end;
end;

end.
