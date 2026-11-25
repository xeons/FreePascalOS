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
  Drawing a rendered glyph (Font.Outlines' TGlyphBitmap) on a canvas:
  coverage blended in the text colour, gamma-correct
  (Drawing.CoverageBlending), or a colour glyph's own colours (an
  emoji) put over what is there, faded by the text colour's alpha
  only.
}
unit Font.GlyphDrawing;

{$mode objfpc}
{$H+}

interface

uses
  Drawing.Colors,
  Drawing.Canvas,
  Font.Outlines;

{ Bitmap with the pen at (PenX, BaselineY) on the baseline (surface
  coordinates), each row shifted right by RowShift(row) pixels if
  Slant is not 0 (a synthetic oblique: rows above the baseline move
  right by Slant times their height). }
procedure DrawGlyphBitmap(const Canvas: TCanvas; const Bitmap: TGlyphBitmap; PenX, BaselineY: LongInt;
  Color: TColor; Slant: Double = 0);
{ Whether the bitmap is a colour glyph's. }
function IsColorGlyph(const Bitmap: TGlyphBitmap): Boolean;

implementation

uses
  Drawing.CoverageBlending;

function IsColorGlyph(const Bitmap: TGlyphBitmap): Boolean;
begin
  Result := Length(Bitmap.Colors) > 0;
end;

procedure DrawColorRow(const Canvas: TCanvas; const Bitmap: TGlyphBitmap; Row, Left, Y: LongInt; Opacity: Byte);
var
  Column: LongInt;
  Pixel: LongWord;
begin
  for Column := 0 to Bitmap.Width - 1 do
  begin
    Pixel := Bitmap.Colors[Row * Bitmap.Width + Column];
    if AlphaOf(Pixel) = 0 then
      Continue;
    if Opacity < 255 then
      Pixel := FadeColor(Pixel, Opacity);
    FillSpan(Canvas, Y, Left + Column, Left + Column + 1, Pixel);
  end;
end;

procedure DrawGlyphBitmap(const Canvas: TCanvas; const Bitmap: TGlyphBitmap; PenX, BaselineY: LongInt;
  Color: TColor; Slant: Double);
var
  Row: LongInt;
  Shift: LongInt;
  Color_: Boolean;
begin
  if (Bitmap.Width <= 0) or (Bitmap.Height <= 0) then
    Exit;
  Color_ := IsColorGlyph(Bitmap);
  if not Color_ and (Length(Bitmap.Coverage) < Bitmap.Width * Bitmap.Height) then
    Exit;
  for Row := 0 to Bitmap.Height - 1 do
  begin
    Shift := 0;
    if Slant <> 0 then
      Shift := Round(-(Bitmap.Top + Row) * Slant);
    if Color_ then
      DrawColorRow(Canvas, Bitmap, Row, PenX + Bitmap.Left + Shift, BaselineY + Bitmap.Top + Row, AlphaOf(Color))
    else
      BlendCoverageSpan(Canvas, BaselineY + Bitmap.Top + Row, PenX + Bitmap.Left + Shift,
        @Bitmap.Coverage[Row * Bitmap.Width], Bitmap.Width, Color);
  end;
end;

end.
