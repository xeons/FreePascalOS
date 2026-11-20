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
  Makes the decoder for an encoding.
}
unit Web.Encoding.DecoderFactory;

{$mode objfpc}
{$H+}

interface

uses
  Web.Encoding.Labels,
  Web.Encoding.Decoders;

{ A new decoder, or nil for an encoding libweb cannot decode yet (the
  multi-byte CJK encodings: IsDecodableEncoding). }
function CreateDecoder(Encoding: TTextEncoding): TTextDecoder;
{ Decodes all of Bytes (no BOM handling) with a decoder for Encoding. }
function DecodeBytes(const Bytes: string; Encoding: TTextEncoding): string;

implementation

uses
  SysUtils,
  Web.Encoding.Utf8Decoder,
  Web.Encoding.Utf16Decoder,
  Web.Encoding.SingleByteDecoder;

function CreateDecoder(Encoding: TTextEncoding): TTextDecoder;
begin
  case Encoding of
    TextEncodingUtf8:
      Result := TUtf8Decoder.Create(Encoding);
    TextEncodingUtf16Be, TextEncodingUtf16Le:
      Result := TUtf16Decoder.Create(Encoding);
    TextEncodingXUserDefined:
      Result := TUserDefinedDecoder.Create(Encoding);
    TextEncodingReplacement:
      Result := TReplacementDecoder.Create(Encoding);
  else
    if IsSingleByteEncoding(Encoding) then
      Result := TSingleByteDecoder.Create(Encoding)
    else
      Result := nil;
  end;
end;

function DecodeBytes(const Bytes: string; Encoding: TTextEncoding): string;
var
  Decoder: TTextDecoder;
begin
  Decoder := CreateDecoder(Encoding);
  if Decoder = nil then
    raise Exception.CreateFmt('The %s encoding cannot be decoded yet', [EncodingName(Encoding)]);
  try
    Result := Decoder.DecodeAll(Bytes);
  finally
    Decoder.Free;
  end;
end;

end.
