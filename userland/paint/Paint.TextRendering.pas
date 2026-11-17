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
  Text as a picture of its own, for the text tool to float over the
  picture: a line in a family, size and weight (Windowing.Fonts: the
  size in points at the display's DPI, so text looks on the picture as
  large as the same size does in a window), in a colour, on
  transparency. The glyphs' coverage (libfont's, anti-aliased) becomes
  the alpha, so the text blends onto whatever it is put down on.
}
unit Paint.TextRendering;

{$mode objfpc}
{$H+}

interface

uses
  Drawing.Colors,
  Image.Model;

{ The text drawn (nil if there is no such font, or no text). Family is
  a Windowing.Fonts TFontFamily, as its number. }
function RenderTextImage(const Text: string; Family: LongInt; PointTenths: LongWord; Bold: Boolean;
  Color: TColor): TImage;

implementation

uses
  Drawing.Canvas,
  Font.Faces,
  Font.Text,
  Windowing.Fonts,
  Image.Surfaces;

function RenderTextImage(const Text: string; Family: LongInt; PointTenths: LongWord; Bold: Boolean;
  Color: TColor): TImage;
var
  Face: PFontFace;
  Width: LongInt;
  Canvas: TCanvas;
  Index: PtrUInt;
  Coverage: Byte;
begin
  Result := nil;
  if Text = '' then
    Exit;
  if (Family < Ord(Low(TFontFamily))) or (Family > Ord(High(TFontFamily))) then
    Family := Ord(FontFamilyText);
  Face := FamilyFontFace(TFontFamily(Family), PointTenths, Bold);
  if Face = nil then
    Exit;
  Width := MeasureTextPrecisely(Face^, Text) + 2;
  if (Width <= 2) or (Face^.Height <= 0) then
    Exit;
  { White on black: the white is how much of each pixel the glyphs
    cover. }
  Result := TImage.Create(Width, Face^.Height);
  Result.Fill(ColorBlack);
  BeginCanvas(Canvas, ImageSurface(Result));
  DrawTextPrecisely(Canvas, Face^, 1, 0, Text, ColorWhite);
  for Index := 0 to PtrUInt(Result.Width) * PtrUInt(Result.Height) - 1 do
  begin
    Coverage := RedOf(Result.Pixels[Index]);
    Result.Pixels[Index] := WithAlpha(Color, (LongWord(Coverage) * AlphaOf(Color) + 127) div 255);
  end;
end;

end.
