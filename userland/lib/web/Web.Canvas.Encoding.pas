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
  A canvas bitmap as a file (HTML Standard 4.12.5.4, "a serialization
  of the bitmap as a file"): PNG unless the type asked for is one the
  encoders of libimage write - image/jpeg (quality 0 to 1, 0.92 when not
  a number in range; JPEG has no alpha, so the pixels are composited
  onto opaque black first, as the standard asks) and image/webp
  (lossless). toDataURL makes a data: URL of it; a bitmap with no pixels
  is "data:,".
}
unit Web.Canvas.Encoding;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Image.Model;

const
  DefaultJpegQuality = 0.92;

{ The bitmap (nil: no pixels) as MimeType (ASCII case-insensitive; other
  types and '' give PNG); ActualType is the type written. Empty when
  there are no pixels. }
function EncodeCanvasBitmap(Bitmap: TImage; const MimeType: string; HasQuality: Boolean; Quality: Double;
  out ActualType: string): TBytes;
function CanvasDataUrl(Bitmap: TImage; const MimeType: string; HasQuality: Boolean; Quality: Double): string;
function Base64Text(const Bytes: TBytes): string;

implementation

uses
  Math,
  Drawing.Colors,
  Image.Png.Writing,
  Image.Jpeg.Encoding,
  Image.WebP.Writing;

function Base64Text(const Bytes: TBytes): string;
const
  Alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
var
  Index, Position, Count: Integer;
  Group: LongWord;
begin
  Count := Length(Bytes);
  Result := '';
  SetLength(Result, ((Count + 2) div 3) * 4);
  Position := 1;
  Index := 0;
  while Index < Count do
  begin
    Group := LongWord(Bytes[Index]) shl 16;
    if Index + 1 < Count then
      Group := Group or (LongWord(Bytes[Index + 1]) shl 8);
    if Index + 2 < Count then
      Group := Group or Bytes[Index + 2];
    Result[Position] := Alphabet[(Group shr 18) and 63 + 1];
    Result[Position + 1] := Alphabet[(Group shr 12) and 63 + 1];
    if Index + 1 < Count then
      Result[Position + 2] := Alphabet[(Group shr 6) and 63 + 1]
    else
      Result[Position + 2] := '=';
    if Index + 2 < Count then
      Result[Position + 3] := Alphabet[Group and 63 + 1]
    else
      Result[Position + 3] := '=';
    Inc(Position, 4);
    Inc(Index, 3);
  end;
end;

{ A copy composited onto opaque black. }
function OnBlack(Bitmap: TImage): TImage;
var
  Index: PtrInt;
begin
  Result := TImage.Create(Bitmap.Width, Bitmap.Height);
  for Index := 0 to PtrInt(Bitmap.Width) * Bitmap.Height - 1 do
    Result.Pixels[Index] := BlendColors(ColorBlack, Bitmap.Pixels[Index]);
end;

function EncodeCanvasBitmap(Bitmap: TImage; const MimeType: string; HasQuality: Boolean; Quality: Double;
  out ActualType: string): TBytes;
var
  Wanted: string;
  Flattened: TImage;
  Options: TPngWriteOptions;
begin
  Result := nil;
  Wanted := LowerCase(MimeType);
  if (Wanted = 'image/jpeg') or (Wanted = 'image/webp') then
    ActualType := Wanted
  else
    ActualType := 'image/png';
  if Bitmap = nil then
    Exit;
  if ActualType = 'image/jpeg' then
  begin
    if not HasQuality or IsNan(Quality) or (Quality < 0) or (Quality > 1) then
      Quality := DefaultJpegQuality;
    Flattened := OnBlack(Bitmap);
    try
      Result := EncodeJpegImage(Flattened, Max(1, Round(Quality * 100)));
    finally
      Flattened.Free;
    end;
  end
  else if ActualType = 'image/webp' then
    Result := EncodeWebPImage(Bitmap)
  else
  begin
    Options := DefaultPngWriteOptions;
    Options.BitsPerPixel := 32;
    Result := EncodePngImage(Bitmap, Options);
  end;
end;

function CanvasDataUrl(Bitmap: TImage; const MimeType: string; HasQuality: Boolean; Quality: Double): string;
var
  Bytes: TBytes;
  ActualType: string;
begin
  if Bitmap = nil then
    Exit('data:,');
  Bytes := EncodeCanvasBitmap(Bitmap, MimeType, HasQuality, Quality, ActualType);
  if Length(Bytes) = 0 then
    Exit('data:,');
  Result := 'data:' + ActualType + ';base64,' + Base64Text(Bytes);
end;

end.
