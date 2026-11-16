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
  WebP in the codec registry: files that start with RIFF and say WEBP,
  read lossy, lossless, with alpha and animated (Image.WebP.Decoder);
  written lossless (Image.WebP.Writing), so the quality is not used.
}
unit Image.WebP.Codec;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Image.Model,
  Image.Codecs;

type
  TWebPDecoder = class(TImageDecoder)
  public
    class function Format: TImageFormat; override;
    class function CanDecode(const Data: TBytes): Boolean; override;
    function Decode(const Data: TBytes): TImage; override;
  end;

  TWebPEncoder = class(TImageEncoder)
  public
    class function Format: TImageFormat; override;
    function Encode(Image: TImage): TBytes; override;
  end;

implementation

uses
  Image.WebP.Container,
  Image.WebP.Decoder,
  Image.WebP.Writing;

class function TWebPDecoder.Format: TImageFormat;
begin
  Result := ImageFormatWebp;
end;

class function TWebPDecoder.CanDecode(const Data: TBytes): Boolean;
begin
  Result := HasWebPSignature(Data);
end;

function TWebPDecoder.Decode(const Data: TBytes): TImage;
begin
  Result := DecodeWebPImage(Data);
end;

class function TWebPEncoder.Format: TImageFormat;
begin
  Result := ImageFormatWebp;
end;

function TWebPEncoder.Encode(Image: TImage): TBytes;
begin
  Result := EncodeWebPImage(Image);
end;

end.
