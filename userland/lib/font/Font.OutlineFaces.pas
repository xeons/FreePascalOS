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
  Faces of outline fonts (Font.Faces, Font.Outlines): the one a family
  lists for a font (of any size), and the face made from it for a pixel
  size.

  At a size, a font unit is Size / UnitsPerEm pixels. The line is the
  font's ascender and descender, each rounded up to whole pixels (as
  FreeType gives them), plus its line gap; the underline sits just
  under the baseline, about a fourteenth of the em thick, as the
  interface's text always had it. Advances and kerning are the font's
  scaled and rounded to whole pixels, so text measures in whole pixels
  and the pen stays on them; the unrounded advance is there too for
  placing glyphs more precisely (Font.Text's subpixel drawing).
}
unit Font.OutlineFaces;

{$mode objfpc}
{$H+}

interface

uses
  Font.Outlines,
  Font.Faces;

{ The face a family lists for Font: any size, glyphs ready (Loaded). }
procedure DescribeOutlineFont(Font: TOutlineFont; out Face: TFontFace);
{ The face of Source (a face of any size) at PixelSize pixels. }
procedure MakeOutlineFace(const Source: TFontFace; PixelSize: LongInt; out Face: TFontFace);
{ How far the pen moves after Glyph: whole pixels, and exactly. }
function OutlineAdvance(const Face: TFontFace; Glyph: LongWord): LongInt;
function PreciseOutlineAdvance(const Face: TFontFace; Glyph: LongWord): Double;
{ The kerning between two glyphs, exactly (pixels). }
function PreciseOutlineKerning(const Face: TFontFace; LeftGlyph, RightGlyph: LongWord): Double;

implementation

uses
  Math;

procedure DescribeOutlineFont(Font: TOutlineFont; out Face: TFontFace);
var
  Index: LongInt;
  Mappings: TCharacterMappings;
begin
  ClearFace(Face);
  Face.Format := GlyphOutline;
  Face.Outlines := Font;
  Face.AnySize := True;
  Face.Hinted := True;
  Face.Bold := Font.Bold;
  Face.GlyphCount := Font.GlyphCount;
  Mappings := Font.Mappings;
  SetLength(Face.Map, Length(Mappings));
  for Index := 0 to High(Mappings) do
    AddMapping(Face, Mappings[Index].CodePoint, Mappings[Index].Glyph);
  FinishMap(Face);
  Face.Loaded := True;
end;

procedure MakeOutlineFace(const Source: TFontFace; PixelSize: LongInt; out Face: TFontFace);
var
  Font: TOutlineFont;
  Scale: Double;
  Descent: LongInt;
begin
  ClearFace(Face);
  Font := Source.Outlines;
  Face.Format := GlyphOutline;
  Face.Outlines := Font;
  Face.Hinted := Source.Hinted;
  Face.Bold := Source.Bold;
  Face.Source := Source.Source;
  Face.Size := PixelSize;
  Face.GlyphCount := Source.GlyphCount;
  { The map is shared, not copied. }
  Face.Map := Source.Map;
  Face.MapCount := Source.MapCount;
  Face.FallbackGlyph := Source.FallbackGlyph;
  Scale := PixelSize / Font.UnitsPerEm;
  Face.Ascent := Ceil(Font.Ascender * Scale - 1E-9);
  Descent := Ceil(Font.Descender * Scale - 1E-9);
  Face.Height := Face.Ascent + Descent + RoundHalfUp(Font.LineGap * Scale);
  if Face.Height < 1 then
    Face.Height := 1;
  Face.UnderlineThickness := RoundHalfUp(PixelSize / 14);
  if Face.UnderlineThickness < 1 then
    Face.UnderlineThickness := 1;
  Face.UnderlineTop := Face.Ascent + Max(1, RoundHalfUp(PixelSize / 12));
  if Face.UnderlineTop + Face.UnderlineThickness > Face.Height then
    Face.UnderlineTop := Face.Height - Face.UnderlineThickness;
  Face.Width := RoundHalfUp(Font.MaximumAdvance * Scale);
  Face.Loaded := True;
end;

function PreciseOutlineAdvance(const Face: TFontFace; Glyph: LongWord): Double;
begin
  if (Face.Outlines = nil) or (Face.Size <= 0) then
    Exit(0);
  Result := Face.Outlines.AdvanceUnits(Glyph) * Face.Size / Face.Outlines.UnitsPerEm;
end;

function OutlineAdvance(const Face: TFontFace; Glyph: LongWord): LongInt;
begin
  Result := RoundHalfUp(PreciseOutlineAdvance(Face, Glyph));
end;

function PreciseOutlineKerning(const Face: TFontFace; LeftGlyph, RightGlyph: LongWord): Double;
begin
  if (Face.Outlines = nil) or (Face.Size <= 0) or not Face.Outlines.HasKerning then
    Exit(0);
  Result := Face.Outlines.KerningUnits(LeftGlyph, RightGlyph) * Face.Size / Face.Outlines.UnitsPerEm;
end;

end.
