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
  A picture file in memory decoded to plain colours: what libfont's
  colour glyphs (emoji in PNG, Font.ColorBitmaps) need, without libfont
  having to know libimage. A program that draws colour glyphs sets
  Font.ColorBitmaps.ColorBitmapDecoder to DecodePictureColors (the
  toolkit and the web engine do).
}
unit Image.PictureColors;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Types;

{ Data (PNG, or any format libimage reads) as Width x Height colours,
  $AARRGGBB not premultiplied, row by row from the top; False if it
  cannot be decoded. }
function DecodePictureColors(const Data: TBytes; out Width, Height: LongInt; out Pixels: TLongWordDynArray): Boolean;

implementation

uses
  Image.Model,
  Image.Errors,
  Image.Files;

function DecodePictureColors(const Data: TBytes; out Width, Height: LongInt; out Pixels: TLongWordDynArray): Boolean;
var
  Picture: TImage;
  Reason: TImageErrorReason;
begin
  Result := False;
  Width := 0;
  Height := 0;
  Pixels := nil;
  Picture := nil;
  try
    if not TryLoadImage(Data, Picture, Reason) or (Picture = nil) or (Picture.Width < 1) or (Picture.Height < 1) then
      Exit;
    Width := Picture.Width;
    Height := Picture.Height;
    SetLength(Pixels, Width * Height);
    Move(Picture.Pixels^, Pixels[0], SizeInt(Width) * Height * SizeOf(LongWord));
    Result := True;
  finally
    Picture.Free;
  end;
end;

end.
