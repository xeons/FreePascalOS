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
  Outline fonts behind libfont's text API, checked: faces made at a
  size (line metrics as FreeType gives them), measuring with advances
  and kerning, drawing exactly what the glyph cache holds blended
  gamma-correct, subpixel positioning, the cache's limits and order of
  use, and font sets mixing a font of any size with bitmap faces.
}
unit FontTest.Text;

{$mode objfpc}
{$H+}

interface

uses
  FontTest.References,
  FontTest.Parsing;

procedure TestText(const References: TReferences; const Fonts: TNamedFonts);

implementation

uses
  SysUtils,
  Math,
  Drawing.Colors,
  Drawing.Rectangles,
  Drawing.Surfaces,
  Drawing.Canvas,
  Drawing.CoverageBlending,
  Font.Outlines,
  Font.Faces,
  Font.TrueType,
  Font.OutlineFaces,
  Font.GlyphRendering,
  Font.GlyphCache,
  Font.Text,
  FontTest.Checks;

function ScalableFace(Font: TTrueTypeFont): TFontFace;
begin
  DescribeOutlineFont(Font, Result);
end;

function FaceAt(Font: TTrueTypeFont; Size: Integer): TFontFace;
var
  Source: TFontFace;
begin
  Source := ScalableFace(Font);
  MakeOutlineFace(Source, Size, Result);
end;

procedure TestMetrics(const References: TReferences; const Fonts: TNamedFonts);
var
  Index: Integer;
  Font: TTrueTypeFont;
  Face: TFontFace;
  Count: Integer;
  Wrong: Integer;
  First: string;
  Ascent: Integer;
  Descent: Integer;
begin
  Count := 0;
  Wrong := 0;
  First := '';
  for Index := 0 to High(References) do
  begin
    if References[Index].Kind <> 'metrics' then
      Continue;
    Font := FontNamed(Fonts, References[Index].Name);
    if Font = nil then
      Continue;
    Face := FaceAt(Font, NumberField(References[Index], 0));
    Ascent := NumberField(References[Index], 1);
    Descent := NumberField(References[Index], 2);
    Inc(Count);
    if (Face.Ascent <> Ascent) or (Face.Height <> Ascent + Descent) then
    begin
      Inc(Wrong);
      if First = '' then
        First := Format(' (first: %s at %d: ascent %d, height %d; expected %d, %d)', [References[Index].Name,
          Face.Size, Face.Ascent, Face.Height, Ascent, Ascent + Descent]);
    end;
  end;
  Check(Format('line metrics as FreeType gives them: %d sizes, %d wrong%s', [Count, Wrong, First]),
    (Count > 0) and (Wrong = 0));
  Font := FontNamed(Fonts, 'sans');
  if Font = nil then
    Exit;
  Face := FaceAt(Font, 12);
  Check('DejaVu Sans at 12 pixels: the line of the interface (15 high, baseline 12 down)', (Face.Height = 15) and
    (Face.Ascent = 12) and (Face.UnderlineTop = 13) and (Face.UnderlineThickness = 1) and
    (Face.Format = GlyphOutline) and Face.Hinted and not Face.AnySize);
  Check('DejaVu Sans: Latin-1, the euro, the fallback for what it lacks', HasGlyphFor(Face, $E9) and
    HasGlyphFor(Face, $20AC) and (GlyphFor(Face, $10FFFF) = Face.FallbackGlyph) and
    (Face.FallbackGlyph = Font.GlyphOf($FFFD)));
end;

procedure TestMeasuring(const Fonts: TNamedFonts);
var
  Font: TTrueTypeFont;
  Face: TFontFace;
  Mono: TFontFace;
  Bold: TFontFace;
  A: LongInt;
  V: LongInt;
  Kern: LongInt;
begin
  Font := FontNamed(Fonts, 'sans');
  if (Font = nil) or (FontNamed(Fonts, 'mono') = nil) or (FontNamed(Fonts, 'sans-bold') = nil) then
    Exit;
  Face := FaceAt(Font, 12);
  A := CharacterAdvance(Face, Ord('A'));
  V := CharacterAdvance(Face, Ord('V'));
  Kern := RoundHalfUp(Font.KerningUnits(Font.GlyphOf(Ord('A')), Font.GlyphOf(Ord('V'))) * 12 / 2048);
  Check('advances are the font''s rounded', (A = RoundHalfUp(1401 * 12 / 2048)) and
    (CharacterAdvance(Face, Ord('i')) < CharacterAdvance(Face, Ord('W'))) and (CharacterAdvance(Face, 9) = 0));
  Check('kerned: AV is shorter than A and V apart', FaceHasKerning(Face) and (Kern < 0) and
    (KerningBetween(Face, Ord('A'), Ord('V')) = Kern) and (MeasureText(Face, 'AV') = A + V + Kern) and
    (MeasureText(Face, 'A'#9'V') = A + V));
  Mono := FaceAt(FontNamed(Fonts, 'mono'), 15);
  Check('DejaVu Sans Mono: every advance the same, no kerning', (CharacterAdvance(Mono, Ord('i')) = Mono.Width) and
    (CharacterAdvance(Mono, Ord('W')) = Mono.Width) and (MeasureText(Mono, 'AVAV') = 4 * Mono.Width) and
    not FaceHasKerning(Mono));
  Bold := FaceAt(FontNamed(Fonts, 'sans-bold'), 12);
  Check('DejaVu Sans Bold is bold and wider', Bold.Bold and (MeasureText(Bold, 'Sample') > MeasureText(Face, 'Sample')));
  Check('precise measuring sums exact advances', (MeasureTextPrecisely(Face, 'iiiiiiiiii') =
    RoundHalfUp(10 * PreciseOutlineAdvance(Face, Font.GlyphOf(Ord('i'))))) and
    (MeasureTextPrecisely(Face, 'iiiiiiiiii') <> MeasureText(Face, 'iiiiiiiiii')));
end;

{ Draws CodePoint white on black and compares every pixel with the
  cached glyph blended at the pen. }
function GlyphDrawsAsCached(const Face: TFontFace; CodePoint: LongWord; Color, Ground: TColor): Boolean;
var
  Surface: TSurface;
  Canvas: TCanvas;
  Bitmap: TGlyphBitmap;
  Row: Integer;
  Column: Integer;
  PenX: Integer;
  PenY: Integer;
  Expected: TColor;
  Inked: Integer;
begin
  Result := CreateSurface(Surface, 3 * Face.Size + 8, 2 * Face.Height + 8, Ground);
  if not Result then
    Exit;
  BeginCanvas(Canvas, Surface);
  PenX := 4;
  PenY := 4;
  Result := DrawCharacter(Canvas, Face, PenX, PenY, CodePoint, Color) = CharacterAdvance(Face, CodePoint);
  RenderGlyph(Face.Outlines, GlyphFor(Face, CodePoint), Face.Size, 0, True, Bitmap);
  Inked := 0;
  for Row := 0 to Surface.Height - 1 do
    for Column := 0 to Surface.Width - 1 do
    begin
      if (Column - PenX - Bitmap.Left >= 0) and (Column - PenX - Bitmap.Left < Bitmap.Width) and
         (Row - PenY - Face.Ascent - Bitmap.Top >= 0) and (Row - PenY - Face.Ascent - Bitmap.Top < Bitmap.Height) then
        Expected := BlendCoverage(Ground, Color, Bitmap.Coverage[(Row - PenY - Face.Ascent - Bitmap.Top) *
          Bitmap.Width + Column - PenX - Bitmap.Left])
      else
        Expected := Ground;
      if Expected <> Ground then
        Inc(Inked);
      Result := Result and (GetSurfacePixel(Surface, Column, Row) = Expected);
    end;
  Result := Result and (Inked > 0);
  FreeSurface(Surface);
end;

procedure TestDrawing(const Fonts: TNamedFonts);
var
  Font: TTrueTypeFont;
  Face: TFontFace;
  Surface: TSurface;
  Canvas: TCanvas;
  Quarter: TGlyphBitmap;
  Cached: PGlyphBitmap;
  Same: Boolean;
  Index: Integer;
begin
  Font := FontNamed(Fonts, 'sans');
  if Font = nil then
    Exit;
  Face := FaceAt(Font, 12);
  Check('g drawn as the cache holds it, white on black', GlyphDrawsAsCached(Face, Ord('g'), ColorWhite, ColorBlack));
  Check('e acute (composite) drawn as cached, black on white',
    GlyphDrawsAsCached(Face, $E9, ColorBlack, ColorWhite));
  Check('W drawn as cached in a colour over a colour', GlyphDrawsAsCached(FaceAt(Font, 23), Ord('W'), $FFC03010,
    $FF2050A0));
  { Text stays within its line. }
  if CreateSurface(Surface, 200, 40, ColorBlack) then
  begin
    BeginCanvas(Canvas, Surface);
    NarrowCanvasClip(Canvas, MakeRectangle(10, 10, 180, Face.Height));
    Check('drawing returns the measured width', DrawText(Canvas, Face, 10, 10, 'Ag(j)|', ColorWhite) =
      MeasureText(Face, 'Ag(j)|'));
    FreeSurface(Surface);
  end;
  { Subpixel positions: a quarter pixel further is rendered so. }
  RenderGlyph(Font, Font.GlyphOf(Ord('l')), 12, 0.5, True, Quarter);
  Cached := CachedGlyph(Font, 12, Font.GlyphOf(Ord('l')), 2, True);
  Same := (Cached <> nil) and (Cached^.Left = Quarter.Left) and (Cached^.Width = Quarter.Width) and
    (Length(Cached^.Coverage) = Length(Quarter.Coverage));
  if Same then
    for Index := 0 to High(Quarter.Coverage) do
      Same := Same and (Cached^.Coverage[Index] = Quarter.Coverage[Index]);
  Check('subpixel: the cache''s half-pixel glyph is the glyph rendered half a pixel along', Same);
  RenderGlyph(Font, Font.GlyphOf(Ord('l')), 12, 0, True, Quarter);
  Check('subpixel: and not the whole-pixel one', (Cached <> nil) and (Cached^.Coverage[0] <> Quarter.Coverage[0]));
  if CreateSurface(Surface, 300, 40, ColorBlack) then
  begin
    BeginCanvas(Canvas, Surface);
    Check('precise drawing returns the precise width', DrawTextPrecisely(Canvas, Face, 2, 2, 'illusion ill', ColorWhite)
      = MeasureTextPrecisely(Face, 'illusion ill'));
    FreeSurface(Surface);
  end;
end;

procedure TestBlending;
var
  Expected: Byte;
begin
  Expected := RoundHalfUp(255 * Power(128 / 255, 1 / TextGamma));
  Check('gamma: half covered white over black is lighter than halfway',
    BlendCoverage(ColorBlack, ColorWhite, 128) = RgbColor(Expected, Expected, Expected));
  Expected := RoundHalfUp(255 * Power(1 - 128 / 255, 1 / TextGamma));
  Check('gamma: half covered black over white is lighter too (the light mixed)',
    BlendCoverage(ColorWhite, ColorBlack, 128) = RgbColor(Expected, Expected, Expected));
  Check('gamma: nothing covered leaves, all covered replaces', (BlendCoverage($FF123456, ColorWhite, 0) = $FF123456)
    and (BlendCoverage($FF123456, $FF654321, 255) = $FF654321));
  Check('gamma: a colour''s alpha scales the coverage', BlendCoverage(ColorBlack, $80FFFFFF, 255) =
    BlendCoverage(ColorBlack, ColorWhite, 128));
  Check('gamma: over a translucent pixel, the usual blend', BlendCoverage($80000000, ColorWhite, 128) =
    BlendColors($80000000, FadeColor(ColorWhite, 128)));
end;

procedure TestCache(const Fonts: TNamedFonts);
var
  Font: TTrueTypeFont;
  First: PGlyphBitmap;
  Index: Integer;
  Bytes: Int64;
begin
  Font := FontNamed(Fonts, 'sans');
  if Font = nil then
    Exit;
  ClearGlyphCache;
  SetGlyphCacheLimits(3, DefaultCachedBytes);
  CachedGlyph(Font, 12, Font.GlyphOf(Ord('A')), 0, True);
  CachedGlyph(Font, 12, Font.GlyphOf(Ord('B')), 0, True);
  CachedGlyph(Font, 12, Font.GlyphOf(Ord('C')), 0, True);
  Check('cache: three rendered', (CachedGlyphCount = 3) and (GlyphCacheMisses = 3) and (GlyphCacheHits = 0));
  First := CachedGlyph(Font, 12, Font.GlyphOf(Ord('A')), 0, True);
  Check('cache: found again', (First <> nil) and (GlyphCacheHits = 1) and (GlyphCacheMisses = 3));
  { A is now the newest: D pushes out B, the oldest. }
  CachedGlyph(Font, 12, Font.GlyphOf(Ord('D')), 0, True);
  CachedGlyph(Font, 12, Font.GlyphOf(Ord('A')), 0, True);
  Check('cache: at its limit, the least recently used goes', (CachedGlyphCount = 3) and (GlyphCacheHits = 2) and
    (GlyphCacheMisses = 4));
  CachedGlyph(Font, 12, Font.GlyphOf(Ord('B')), 0, True);
  Check('cache: the glyph pushed out is rendered again', GlyphCacheMisses = 5);
  CachedGlyph(Font, 13, Font.GlyphOf(Ord('B')), 0, True);
  CachedGlyph(Font, 12, Font.GlyphOf(Ord('B')), 1, True);
  CachedGlyph(Font, 12, Font.GlyphOf(Ord('B')), 0, False);
  Check('cache: size, subpixel offset and hinting each tell glyphs apart', GlyphCacheMisses = 8);
  ClearGlyphCache;
  SetGlyphCacheLimits(DefaultCachedGlyphs, 600);
  for Index := 0 to 25 do
    CachedGlyph(Font, 20, Font.GlyphOf(Ord('a') + Index), 0, True);
  Bytes := CachedGlyphBytes;
  Check('cache: within its byte limit', (Bytes <= 600) and (CachedGlyphCount < 26) and (CachedGlyphCount > 0));
  ForgetFontGlyphs(Font);
  Check('cache: a font''s glyphs forgotten', (CachedGlyphCount = 0) and (CachedGlyphBytes = 0));
  Check('cache: no glyph for a bad subpixel offset', CachedGlyph(Font, 12, 1, SubpixelSteps, True) = nil);
  SetGlyphCacheLimits(DefaultCachedGlyphs, DefaultCachedBytes);
  ClearGlyphCache;
end;

{ A host loader for font sets: nothing to read, the faces come loaded. }
function NoLoader(var Face: TFontFace): Boolean;
begin
  Result := Face.Loaded;
end;

procedure TestFontSets(const Fonts: TNamedFonts);
var
  FontSet: TFontSet;
  Bitmap: TFontFace;
  Picked: PFontFace;
  Again: PFontFace;
  Other: PFontFace;
  Index: Integer;
begin
  if (FontNamed(Fonts, 'sans') = nil) or (FontNamed(Fonts, 'sans-bold') = nil) then
    Exit;
  ClearFontSet(FontSet);
  FontSet.Loader := @NoLoader;
  AddFace(FontSet, ScalableFace(FontNamed(Fonts, 'sans')));
  AddFace(FontSet, ScalableFace(FontNamed(Fonts, 'sans-bold')));
  Check('a set with a font of any size is scalable', FontSetIsScalable(FontSet));
  Check('every size there is: 9 points at 96, 120 and 144 DPI, 47 at 96', (SelectedFaceSize(FontSet, 90, 96, False) = 12)
    and (SelectedFaceSize(FontSet, 90, 120, False) = 15) and (SelectedFaceSize(FontSet, 90, 144, True) = 18) and
    (SelectedFaceSize(FontSet, 470, 96, False) = 63));
  Picked := SelectFace(FontSet, 90, 96, False);
  Check('9 points at 96 DPI: DejaVu Sans made at 12 pixels', (Picked <> nil) and (Picked^.Size = 12) and
    (Picked^.Height = 15) and not Picked^.Bold and (FontSet.InstanceCount = 1));
  for Index := 1 to 40 do
    SelectFace(FontSet, 10 * Index, 96, Odd(Index));
  Again := SelectFace(FontSet, 90, 96, False);
  Check('a face picked stays where it was however many more are made', (Again = Picked) and (Picked^.Size = 12) and
    (FontSet.InstanceCount > 30));
  Other := SelectFace(FontSet, 90, 96, True);
  Check('bold picked by weight', (Other <> nil) and Other^.Bold and (Other^.Size = 12));
  { A bitmap face of exactly the size wanted comes first. }
  ClearFace(Bitmap);
  Bitmap.Size := 16;
  Bitmap.Height := 16;
  Bitmap.Loaded := True;
  AddFace(FontSet, Bitmap);
  Check('a bitmap face of the very size wanted is taken before the outline', SelectFace(FontSet, 120, 96, False)^.Format
    = GlyphBits);
  Check('other sizes still from the outline', SelectFace(FontSet, 110, 96, False)^.Format = GlyphOutline);
end;

procedure TestText(const References: TReferences; const Fonts: TNamedFonts);
begin
  TestMetrics(References, Fonts);
  TestMeasuring(Fonts);
  TestDrawing(Fonts);
  TestBlending;
  TestCache(Fonts);
  TestFontSets(Fonts);
end;

end.
