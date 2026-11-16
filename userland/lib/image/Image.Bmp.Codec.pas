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
  BMP and DIB as decoders and encoders for the registry.

  A BMP file starts 'BM', its size, two reserved words and where the
  pixels are, then a DIB. A DIB on its own (the clipboard's) has no
  signature but its header's size; it is recognised by a known header
  size, one plane and a known bit depth, which is weak, so the DIB
  decoder is registered after every format with a real signature. A
  BMP is 'BM' and a known header size; what follows is checked as it
  is read, so a broken one is refused with the reason.
}
unit Image.Bmp.Codec;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Image.Errors,
  Image.Model,
  Image.Codecs,
  Image.ByteReaders,
  Image.Bmp.Headers,
  Image.Bmp.Reading,
  Image.Bmp.Writing;

type
  TBmpDecoder = class(TImageDecoder)
  public
    class function Format: TImageFormat; override;
    class function CanDecode(const Data: TBytes): Boolean; override;
    function Decode(const Data: TBytes): TImage; override;
  end;

  TDibDecoder = class(TImageDecoder)
  public
    class function Format: TImageFormat; override;
    class function CanDecode(const Data: TBytes): Boolean; override;
    function Decode(const Data: TBytes): TImage; override;
  end;

  TBmpEncoder = class(TImageEncoder)
  public
    class function Format: TImageFormat; override;
    function Encode(Image: TImage): TBytes; override;
  end;

  TDibEncoder = class(TImageEncoder)
  public
    class function Format: TImageFormat; override;
    function Encode(Image: TImage): TBytes; override;
  end;

{ True when a DIB header that makes sense starts at Offset of Data. }
function LooksLikeDib(const Data: TBytes; Offset: PtrInt): Boolean;

implementation

function LooksLikeDib(const Data: TBytes; Offset: PtrInt): Boolean;
var
  HeaderSize: LongWord;
  Planes: LongWord;
  BitsPerPixel: LongWord;
begin
  HeaderSize := PeekLongLittle(Data, Offset);
  if not BmpHeaderSizeKnown(HeaderSize) then
    Exit(False);
  if HeaderSize = BmpCoreHeaderSize then
  begin
    Planes := PeekWordLittle(Data, Offset + 8);
    BitsPerPixel := PeekWordLittle(Data, Offset + 10);
  end
  else
  begin
    Planes := PeekWordLittle(Data, Offset + 12);
    BitsPerPixel := PeekWordLittle(Data, Offset + 14);
  end;
  Result := (Planes = 1) and (BitsPerPixel in [1, 4, 8, 16, 24, 32]);
end;

class function TBmpDecoder.Format: TImageFormat;
begin
  Result := ImageFormatBmp;
end;

class function TBmpDecoder.CanDecode(const Data: TBytes): Boolean;
begin
  Result := BytesStartWith(Data, [Ord('B'), Ord('M')]) and
    BmpHeaderSizeKnown(PeekLongLittle(Data, BmpFileHeaderSize));
end;

function TBmpDecoder.Decode(const Data: TBytes): TImage;
var
  PixelOffset: LongWord;
begin
  if Length(Data) < BmpFileHeaderSize + 4 then
    RaiseImageError(ImageErrorTruncated, 'BMP header');
  if not BytesStartWith(Data, [Ord('B'), Ord('M')]) then
    RaiseImageError(ImageErrorMalformed, 'not a BMP file');
  PixelOffset := PeekLongLittle(Data, 10);
  Result := DecodeDib(Data, BmpFileHeaderSize, PixelOffset);
  Result.SourceFormatName := ImageFormatName(ImageFormatBmp);
end;

class function TDibDecoder.Format: TImageFormat;
begin
  Result := ImageFormatDib;
end;

class function TDibDecoder.CanDecode(const Data: TBytes): Boolean;
begin
  Result := LooksLikeDib(Data, 0);
end;

function TDibDecoder.Decode(const Data: TBytes): TImage;
begin
  Result := DecodeDib(Data, 0, -1);
  Result.SourceFormatName := ImageFormatName(ImageFormatDib);
end;

class function TBmpEncoder.Format: TImageFormat;
begin
  Result := ImageFormatBmp;
end;

function TBmpEncoder.Encode(Image: TImage): TBytes;
begin
  Result := EncodeBmp(Image, BitsPerPixel, True);
end;

class function TDibEncoder.Format: TImageFormat;
begin
  Result := ImageFormatDib;
end;

function TDibEncoder.Encode(Image: TImage): TBytes;
begin
  Result := EncodeBmp(Image, BitsPerPixel, False);
end;

end.
