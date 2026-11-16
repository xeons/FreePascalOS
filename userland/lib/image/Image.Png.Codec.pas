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
  PNG and APNG as a decoder and an encoder for the registry.

  The decoder takes any file with the PNG signature
  (Image.Png.Decoder); an APNG comes back as a TAnimatedImage. The
  encoder (Image.Png.Writing) writes the smallest colour type that
  keeps the pixels, or RGB or RGBA when BitsPerPixel is 24 or 32, at
  zlib level CompressionLevel (6 unless set; Quality is not used, PNG
  being lossless), and an APNG for a TAnimatedImage.
}
unit Image.Png.Codec;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Image.Model,
  Image.Codecs;

type
  TPngDecoder = class(TImageDecoder)
  public
    class function Format: TImageFormat; override;
    class function CanDecode(const Data: TBytes): Boolean; override;
    function Decode(const Data: TBytes): TImage; override;
  end;

  TPngEncoder = class(TImageEncoder)
  private
    FCompressionLevel: Integer;
  public
    constructor Create; override;
    class function Format: TImageFormat; override;
    function Encode(Image: TImage): TBytes; override;
    { zlib's 0 (stored) to 9 (smallest). }
    property CompressionLevel: Integer read FCompressionLevel write FCompressionLevel;
  end;

implementation

uses
  Image.Png.Chunks,
  Image.Png.Decoder,
  Image.Png.Writing;

class function TPngDecoder.Format: TImageFormat;
begin
  Result := ImageFormatPng;
end;

class function TPngDecoder.CanDecode(const Data: TBytes): Boolean;
begin
  Result := HasPngSignature(Data);
end;

function TPngDecoder.Decode(const Data: TBytes): TImage;
begin
  Result := DecodePngImage(Data);
end;

constructor TPngEncoder.Create;
begin
  inherited Create;
  FCompressionLevel := 6;
end;

class function TPngEncoder.Format: TImageFormat;
begin
  Result := ImageFormatPng;
end;

function TPngEncoder.Encode(Image: TImage): TBytes;
var
  Options: TPngWriteOptions;
begin
  Options := DefaultPngWriteOptions;
  Options.Level := FCompressionLevel;
  Options.BitsPerPixel := BitsPerPixel;
  Result := EncodePngImage(Image, Options);
end;

end.
