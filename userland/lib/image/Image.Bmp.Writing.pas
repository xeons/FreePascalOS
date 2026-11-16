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
  Writing BMP files and DIBs.

  24 bits: the usual 40-byte header, blue, green, red, lines from the
  bottom up padded to four bytes. 32 bits: a V5 header with BITFIELDS
  masks for all four channels (alpha included, which programs that know
  V5 honour), sRGB, pixels as they are in memory. A BMP file is the
  14-byte file header ('BM', the size, where the pixels are) before the
  DIB; a DIB alone is what the clipboard holds.

  The resolution, if the image has one, is written in pixels per metre.
}
unit Image.Bmp.Writing;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

uses
  SysUtils,
  Image.Errors,
  Image.Model,
  Image.ByteWriters,
  Image.Bmp.Headers;

{ Image as a BMP file (WithFileHeader) or a DIB, of 24 or 32 bits per
  pixel (0: 32 when the image has any transparency, else 24). }
function EncodeBmp(Image: TImage; BitsPerPixel: LongInt; WithFileHeader: Boolean): TBytes;
{ The bits per pixel EncodeBmp uses for BitsPerPixel 0. }
function ChooseBmpBitsPerPixel(Image: TImage): LongInt;

implementation

function ChooseBmpBitsPerPixel(Image: TImage): LongInt;
begin
  if Image.IsOpaque then
    Result := 24
  else
    Result := 32;
end;

function PixelsPerMeter(DotsPerInch: Double): LongWord;
begin
  if DotsPerInch <= 0 then
    Exit(0);
  Result := Round(DotsPerInch / 0.0254);
end;

procedure WriteInfoHeader(Writer: TImageByteWriter; Image: TImage; BitsPerPixel: LongInt; PixelBytes: LongWord);
var
  HeaderSize: LongWord;
  Index: LongInt;
begin
  if BitsPerPixel = 32 then
    HeaderSize := BmpV5HeaderSize
  else
    HeaderSize := BmpInfoHeaderSize;
  Writer.WriteLongLittle(HeaderSize);
  Writer.WriteLongLittle(LongWord(Image.Width));
  Writer.WriteLongLittle(LongWord(Image.Height));
  Writer.WriteWordLittle(1);
  Writer.WriteWordLittle(BitsPerPixel);
  if BitsPerPixel = 32 then
    Writer.WriteLongLittle(BmpCompressionBitfields)
  else
    Writer.WriteLongLittle(BmpCompressionRgb);
  Writer.WriteLongLittle(PixelBytes);
  Writer.WriteLongLittle(PixelsPerMeter(Image.Resolution.HorizontalDpi));
  Writer.WriteLongLittle(PixelsPerMeter(Image.Resolution.VerticalDpi));
  { Colours used and important. }
  Writer.WriteLongLittle(0);
  Writer.WriteLongLittle(0);
  if BitsPerPixel <> 32 then
    Exit;
  Writer.WriteLongLittle($00FF0000);
  Writer.WriteLongLittle($0000FF00);
  Writer.WriteLongLittle($000000FF);
  Writer.WriteLongLittle($FF000000);
  Writer.WriteLongLittle(BmpColorSpaceSrgb);
  { Endpoints and gamma, unused for sRGB. }
  for Index := 1 to 12 do
    Writer.WriteLongLittle(0);
  { Intent (LCS_GM_IMAGES), profile data and size, reserved. }
  Writer.WriteLongLittle(4);
  Writer.WriteLongLittle(0);
  Writer.WriteLongLittle(0);
  Writer.WriteLongLittle(0);
end;

procedure WritePixels(Writer: TImageByteWriter; Image: TImage; BitsPerPixel: LongInt);
var
  Stride: Int64;
  Padding: LongInt;
  Line: TBytes;
  Y: LongInt;
  X: LongInt;
  Source: PLongWord;
  Pixel: LongWord;
begin
  Stride := BmpRowStride(Image.Width, BitsPerPixel);
  Line := nil;
  SetLength(Line, Stride);
  for Y := Image.Height - 1 downto 0 do
  begin
    Source := Image.Line(Y);
    if BitsPerPixel = 32 then
      for X := 0 to Image.Width - 1 do
      begin
        Pixel := Source[X];
        Line[4 * X] := Pixel and $FF;
        Line[4 * X + 1] := (Pixel shr 8) and $FF;
        Line[4 * X + 2] := (Pixel shr 16) and $FF;
        Line[4 * X + 3] := Pixel shr 24;
      end
    else
    begin
      for X := 0 to Image.Width - 1 do
      begin
        Pixel := Source[X];
        Line[3 * X] := Pixel and $FF;
        Line[3 * X + 1] := (Pixel shr 8) and $FF;
        Line[3 * X + 2] := (Pixel shr 16) and $FF;
      end;
      Padding := Stride - 3 * Image.Width;
      if Padding > 0 then
        FillChar(Line[3 * Image.Width], Padding, 0);
    end;
    Writer.WriteBuffer(Line[0], Stride);
  end;
end;

function EncodeBmp(Image: TImage; BitsPerPixel: LongInt; WithFileHeader: Boolean): TBytes;
var
  Writer: TImageByteWriter;
  PixelBytes: Int64;
  HeaderSize: LongWord;
  PixelOffset: LongWord;
begin
  if BitsPerPixel = 0 then
    BitsPerPixel := ChooseBmpBitsPerPixel(Image);
  if (BitsPerPixel <> 24) and (BitsPerPixel <> 32) then
    RaiseImageError(ImageErrorUnsupported, 'writing ' + IntToStr(BitsPerPixel) + ' bits per pixel');
  PixelBytes := BmpRowStride(Image.Width, BitsPerPixel) * Image.Height;
  if BitsPerPixel = 32 then
    HeaderSize := BmpV5HeaderSize
  else
    HeaderSize := BmpInfoHeaderSize;
  PixelOffset := HeaderSize;
  if WithFileHeader then
    Inc(PixelOffset, BmpFileHeaderSize);
  Writer := TImageByteWriter.Create(PixelOffset + PixelBytes);
  try
    if WithFileHeader then
    begin
      Writer.WriteByte(Ord('B'));
      Writer.WriteByte(Ord('M'));
      Writer.WriteLongLittle(LongWord(PixelOffset + PixelBytes));
      Writer.WriteLongLittle(0);
      Writer.WriteLongLittle(PixelOffset);
    end;
    WriteInfoHeader(Writer, Image, BitsPerPixel, LongWord(PixelBytes));
    WritePixels(Writer, Image, BitsPerPixel);
    Result := Writer.ToBytes;
  finally
    Writer.Free;
  end;
end;

end.
