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
  JPEG in the codec registry: a file starting with SOI and another
  marker ($FF $D8 $FF) is a JPEG; Image.Jpeg.Decoder decodes it
  (baseline, extended and progressive Huffman coded frames, 8-bit).
  Image.Jpeg.Encoding writes baseline 4:2:0 files at the encoder's
  quality.
}
unit Image.Jpeg.Codec;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Image.Model,
  Image.Codecs;

type
  TJpegDecoder = class(TImageDecoder)
  public
    class function Format: TImageFormat; override;
    class function CanDecode(const Data: TBytes): Boolean; override;
    function Decode(const Data: TBytes): TImage; override;
  end;

  TJpegEncoder = class(TImageEncoder)
  public
    class function Format: TImageFormat; override;
    function Encode(Image: TImage): TBytes; override;
  end;

implementation

uses
  Image.Jpeg.Decoder,
  Image.Jpeg.Encoding;

class function TJpegDecoder.Format: TImageFormat;
begin
  Result := ImageFormatJpeg;
end;

class function TJpegDecoder.CanDecode(const Data: TBytes): Boolean;
begin
  Result := (Length(Data) >= 3) and (Data[0] = $FF) and (Data[1] = $D8) and (Data[2] = $FF);
end;

function TJpegDecoder.Decode(const Data: TBytes): TImage;
begin
  Result := DecodeJpegImage(Data);
end;

class function TJpegEncoder.Format: TImageFormat;
begin
  Result := ImageFormatJpeg;
end;

function TJpegEncoder.Encode(Image: TImage): TBytes;
begin
  Result := EncodeJpegImage(Image, Quality);
end;

end.
