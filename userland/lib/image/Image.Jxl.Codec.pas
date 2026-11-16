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
  JPEG XL in the codec registry: a bare codestream ($FF $0A) or the
  container's signature box; Image.Jxl.Decoder decodes it. There is no
  encoder.
}
unit Image.Jxl.Codec;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Image.Model,
  Image.Codecs;

type
  TJxlDecoder = class(TImageDecoder)
  public
    class function Format: TImageFormat; override;
    class function CanDecode(const Data: TBytes): Boolean; override;
    function Decode(const Data: TBytes): TImage; override;
  end;

implementation

uses
  Image.Jxl.Container,
  Image.Jxl.Decoder;

class function TJxlDecoder.Format: TImageFormat;
begin
  Result := ImageFormatJxl;
end;

class function TJxlDecoder.CanDecode(const Data: TBytes): Boolean;
begin
  Result := IsJxlFile(Data);
end;

function TJxlDecoder.Decode(const Data: TBytes): TImage;
begin
  Result := DecodeJxlImage(Data);
end;

end.
