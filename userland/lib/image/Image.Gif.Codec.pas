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
  GIF as a decoder and an encoder for the registry. Decoding always
  gives a TAnimatedImage (one frame for a still picture); encoding
  writes one frame (Image.Gif.Writing).
}
unit Image.Gif.Codec;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Image.Model,
  Image.Codecs,
  Image.Gif.Blocks,
  Image.Gif.Reading,
  Image.Gif.Writing;

type
  TGifDecoder = class(TImageDecoder)
  public
    class function Format: TImageFormat; override;
    class function CanDecode(const Data: TBytes): Boolean; override;
    function Decode(const Data: TBytes): TImage; override;
  end;

  TGifEncoder = class(TImageEncoder)
  public
    class function Format: TImageFormat; override;
    function Encode(Image: TImage): TBytes; override;
  end;

implementation

class function TGifDecoder.Format: TImageFormat;
begin
  Result := ImageFormatGif;
end;

class function TGifDecoder.CanDecode(const Data: TBytes): Boolean;
begin
  Result := IsGifSignature(Data);
end;

function TGifDecoder.Decode(const Data: TBytes): TImage;
begin
  Result := DecodeGif(Data);
end;

class function TGifEncoder.Format: TImageFormat;
begin
  Result := ImageFormatGif;
end;

function TGifEncoder.Encode(Image: TImage): TBytes;
begin
  Result := EncodeGif(Image);
end;

end.
