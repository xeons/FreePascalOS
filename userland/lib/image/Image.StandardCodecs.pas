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
  The library's own formats, registered with Image.Codecs. Formats
  with a real signature first; DIB, recognised only by its header's
  shape, last. Calling RegisterStandardImageCodecs again does nothing;
  Image.Files calls it before it looks for a codec.

  PNG and TIFF use libcompression's deflate. JPEG XL is decoded only.
  ICO's PNG entries find the PNG decoder through the embedded image
  hook (Image.Codecs).
}
unit Image.StandardCodecs;

{$mode objfpc}
{$H+}

interface

procedure RegisterStandardImageCodecs;

implementation

uses
  Image.Codecs,
  Image.Bmp.Codec,
  Image.Ico.Codec,
  Image.Gif.Codec,
  Image.Jpeg.Codec,
  Image.Png.Codec,
  Image.Tiff.Codec,
  Image.WebP.Codec,
  Image.Jxl.Codec;

var
  Registered: Boolean = False;

procedure RegisterStandardImageCodecs;
begin
  if Registered then
    Exit;
  Registered := True;
  RegisterImageDecoder(TPngDecoder);
  RegisterImageDecoder(TBmpDecoder);
  RegisterImageDecoder(TIcoDecoder);
  RegisterImageDecoder(TCurDecoder);
  RegisterImageDecoder(TGifDecoder);
  RegisterImageDecoder(TJpegDecoder);
  RegisterImageDecoder(TTiffDecoder);
  RegisterImageDecoder(TWebPDecoder);
  RegisterImageDecoder(TJxlDecoder);
  RegisterImageDecoder(TDibDecoder);
  RegisterImageEncoder(TBmpEncoder);
  RegisterImageEncoder(TDibEncoder);
  RegisterImageEncoder(TIcoEncoder);
  RegisterImageEncoder(TCurEncoder);
  RegisterImageEncoder(TGifEncoder);
  RegisterImageEncoder(TJpegEncoder);
  RegisterImageEncoder(TPngEncoder);
  RegisterImageEncoder(TTiffEncoder);
  RegisterImageEncoder(TWebPEncoder);
end;

end.
