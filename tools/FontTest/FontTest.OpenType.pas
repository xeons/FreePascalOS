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
  The OpenType side of libfont against the build machine's fonts (the
  references name them; a font the machine lacks is a "missing" record
  and its checks are skipped, saying so): CFF and CFF2 outlines (their
  glyphs are compared with FreeType's in FontTest.Rendering like every
  other font's), a collection's faces, Noto Color Emoji's colour
  bitmaps decoded through libimage, WOFF2 unwrapped to the font it was
  made from, broken CFF data never doing more than refusing a glyph,
  Liberation Sans having Arial's advances, and the system's font
  configuration (userland/data/etc/fonts.conf).
}
unit FontTest.OpenType;

{$mode objfpc}
{$H+}

interface

uses
  FontTest.References,
  FontTest.Parsing;

procedure TestOpenType(const Directory: string; const References: TReferences; const Fonts: TNamedFonts);

implementation

uses
  SysUtils,
  Classes,
  Font.Outlines,
  Font.TrueType,
  Font.ColorBitmaps,
  Font.GlyphRendering,
  Font.Configuration,
  Image.PictureColors,
  Web.Text.Woff2,
  FontTest.Checks;

procedure ReportMissing(const References: TReferences);
var
  Index: Integer;
begin
  for Index := 0 to High(References) do
    if References[Index].Kind = 'missing' then
      WriteLn('[font] skipped: ', References[Index].Name, ' (', References[Index].Fields[0], ' not on this machine)');
end;

procedure TestCollection(const Fonts: TNamedFonts);
var
  Japanese, Chinese: TTrueTypeFont;
begin
  Japanese := FontNamed(Fonts, 'cjk-jp');
  Chinese := FontNamed(Fonts, 'cjk-sc');
  if (Japanese = nil) or (Chinese = nil) then
    Exit;
  Check('collection: Noto Sans CJK has ten faces', Japanese.FaceIndex = 0);
  Check('collection: faces 0 and 2 are CFF fonts', (Japanese.Kind = CffOutlines) and (Chinese.Kind = CffOutlines) and
    (Chinese.FaceIndex = 2));
  Check('collection: the faces map U+76F4 to their own glyphs', Japanese.GlyphOf($76F4) <> Chinese.GlyphOf($76F4));
end;

procedure TestEmoji(const References: TReferences; const Fonts: TNamedFonts);
var
  Font: TTrueTypeFont;
  Index, Pixel, Opaque, Yellow: Integer;
  Glyph: LongWord;
  Bitmap: TGlyphBitmap;
  Color: LongWord;
  AllRendered: Boolean;
begin
  Font := FontNamed(Fonts, 'emoji');
  if Font = nil then
    Exit;
  Check('emoji: Noto Color Emoji is colour bitmaps alone', Font.Kind = BitmapsOnly);
  ColorBitmapDecoder := nil;
  Check('emoji: without a decoder it cannot be drawn', not Font.CanDraw and not Font.HasColorGlyph(Font.GlyphOf($1F600)));
  ColorBitmapDecoder := @DecodePictureColors;
  Check('emoji: with libimage decoding it can', Font.CanDraw);
  AllRendered := True;
  for Index := 0 to High(References) do
    if References[Index].Kind = 'emoji' then
    begin
      Glyph := Font.GlyphOf(NumberField(References[Index], 0));
      AllRendered := AllRendered and (Glyph <> 0) and Font.HasColorGlyph(Glyph) and
        RenderGlyph(Font, Glyph, 20, 0, False, Bitmap) and (Length(Bitmap.Colors) = Bitmap.Width * Bitmap.Height) and
        (Bitmap.Width >= 18) and (Bitmap.Width <= 30) and (Bitmap.Height >= 16) and (Bitmap.Height <= 28);
    end;
  Check('emoji: every listed emoji renders as a colour glyph of about 20 pixels', AllRendered);
  { The grinning face: mostly yellow, its top above the baseline. }
  Glyph := Font.GlyphOf($1F600);
  if RenderGlyph(Font, Glyph, 32, 0, False, Bitmap) then
  begin
    Opaque := 0;
    Yellow := 0;
    for Pixel := 0 to High(Bitmap.Colors) do
    begin
      Color := Bitmap.Colors[Pixel];
      if (Color shr 24) > 200 then
      begin
        Inc(Opaque);
        if (((Color shr 16) and $FF) > 200) and (((Color shr 8) and $FF) > 140) and ((Color and $FF) < 120) then
          Inc(Yellow);
      end;
    end;
    Check(Format('emoji: U+1F600 at 32 pixels is a yellow face (%dx%d, %d opaque, %d yellow, top %d)',
      [Bitmap.Width, Bitmap.Height, Opaque, Yellow, Bitmap.Top]),
      (Opaque > 400) and (Yellow > Opaque div 2) and (Bitmap.Top < -20) and (Bitmap.Top + Bitmap.Height > 0));
  end
  else
    Check('emoji: U+1F600 renders at 32 pixels', False);
end;

function OutlinesEqual(First, Second: TOutlineFont; Glyph: LongWord): Boolean;
var
  A, B: TGlyphOutline;
  Index: Integer;
begin
  Result := (First.LoadOutline(Glyph, A) = Second.LoadOutline(Glyph, B)) and (A.PointCount = B.PointCount) and
    (A.ContourCount = B.ContourCount);
  if not Result then
    Exit;
  for Index := 0 to A.PointCount - 1 do
    if (A.Points[Index].X <> B.Points[Index].X) or (A.Points[Index].Y <> B.Points[Index].Y) or
       (A.Points[Index].OnCurve <> B.Points[Index].OnCurve) then
      Exit(False);
  for Index := 0 to A.ContourCount - 1 do
    if A.ContourEnds[Index] <> B.ContourEnds[Index] then
      Exit(False);
end;

procedure TestWoff2(const Directory: string; const References: TReferences; const Fonts: TNamedFonts);
var
  Index, Mapping: Integer;
  Data, Sfnt: TBytes;
  Original, Unwrapped: TTrueTypeFont;
  Glyph: LongWord;
  Same: Boolean;
  Broken: TBytes;
  Cut: Integer;
  Survived: Boolean;
begin
  for Index := 0 to High(References) do
  begin
    if References[Index].Kind <> 'woff2' then
      Continue;
    Original := FontNamed(Fonts, References[Index].Name);
    if not ReadFileBytes(IncludeTrailingPathDelimiter(Directory) + References[Index].Fields[0], Data) or
       (Original = nil) then
    begin
      Check('woff2: fixture readable', False);
      Continue;
    end;
    Sfnt := UnwrapWoff2(Data);
    Unwrapped := nil;
    if Sfnt <> nil then
      Unwrapped := LoadTrueTypeFont(Sfnt);
    Check(Format('woff2: %s unwraps (%d bytes to %d) and opens', [References[Index].Fields[0], Length(Data),
      Length(Sfnt)]), Unwrapped <> nil);
    if Unwrapped = nil then
      Continue;
    Same := (Unwrapped.GlyphCount = Original.GlyphCount) and (Length(Unwrapped.Mappings) = Length(Original.Mappings)) and
      (Unwrapped.UnitsPerEm = Original.UnitsPerEm) and (Unwrapped.Ascender = Original.Ascender);
    if Same then
      for Mapping := 0 to High(Original.Mappings) do
        if Unwrapped.Mappings[Mapping].Glyph <> Original.Mappings[Mapping].Glyph then
          Same := False;
    Check('woff2: the same glyphs, character map and metrics as the original', Same);
    Same := True;
    Glyph := 0;
    while Same and (Glyph < Original.GlyphCount) do
    begin
      Same := (Unwrapped.AdvanceUnits(Glyph) = Original.AdvanceUnits(Glyph)) and OutlinesEqual(Original, Unwrapped, Glyph);
      Inc(Glyph);
    end;
    Check(Format('woff2: every glyph''s advance and outline as the original''s (stopped at %d of %d)',
      [Glyph, Original.GlyphCount]), Same);
    Check('woff2: the kerning survives', Unwrapped.HasKerning = Original.HasKerning);
    Unwrapped.Free;
    { Truncated anywhere: refused, never worse. }
    Survived := True;
    Cut := 1;
    while Cut < Length(Data) do
    begin
      Broken := Copy(Data, 0, Cut);
      try
        if UnwrapWoff2(Broken) <> nil then
          Survived := False;
      except
        Survived := False;
      end;
      Cut := Cut + 97;
    end;
    Check('woff2: every truncation refused', Survived);
  end;
end;

{ Random bytes of a CFF font changed: it opens or not, and its glyphs
  render or are refused, without an exception. }
procedure TestBrokenCff(const References: TReferences);
var
  Index, Round_, Change: Integer;
  Data, Broken: TBytes;
  Font: TTrueTypeFont;
  Bitmap: TGlyphBitmap;
  Survived: Boolean;
  Glyph: LongWord;
begin
  for Index := 0 to High(References) do
    if (References[Index].Kind = 'font') and (References[Index].Name = 'source-sans') then
    begin
      if not ReadFileBytes(References[Index].Fields[0], Data) then
        Exit;
      RandSeed := 1234;
      Survived := True;
      for Round_ := 1 to 120 do
      begin
        Broken := Copy(Data);
        for Change := 1 to 20 do
          Broken[Random(Length(Broken))] := Random(256);
        try
          Font := LoadTrueTypeFont(Broken);
          if Font <> nil then
          begin
            for Glyph := 0 to 40 do
              RenderGlyph(Font, Glyph * 7, 17, 0, Round_ mod 2 = 0, Bitmap);
            Font.Free;
          end;
        except
          on E: Exception do
          begin
            Survived := False;
            WriteLn('[font] broken CFF raised ', E.ClassName, ': ', E.Message);
          end;
        end;
      end;
      Check('cff: 120 randomly damaged copies of Source Sans open or not, render or not, never raise', Survived);
    end;
end;

{ Liberation Sans is metric-compatible with Arial: these are Arial's
  advances (2048 units to the em). }
procedure TestArialMetrics(const Fonts: TNamedFonts);
const
  Characters: array[0..7] of LongWord = (Ord(' '), Ord('A'), Ord('a'), Ord('W'), Ord('i'), Ord('m'), Ord('0'), Ord('.'));
  ArialAdvances: array[0..7] of LongInt = (569, 1366, 1139, 1933, 455, 1706, 1139, 569);
var
  Font: TTrueTypeFont;
  Index: Integer;
  Same: Boolean;
begin
  Font := FontNamed(Fonts, 'liberation-sans');
  if Font = nil then
    Exit;
  Same := Font.UnitsPerEm = 2048;
  for Index := 0 to High(Characters) do
    Same := Same and (Font.AdvanceUnits(Font.GlyphOf(Characters[Index])) = ArialAdvances[Index]);
  Check('liberation sans: Arial''s advances', Same);
end;

procedure TestConfiguration;
var
  Configuration: TFontConfiguration;
  Families: TFamilyList;
begin
  Configuration := TFontConfiguration.Create;
  try
    Families := Configuration.FamiliesFor('Arial');
    Check('configuration: built in, Arial is DejaVu Sans', (Length(Families) = 1) and (Families[0] = 'DejaVu Sans'));
    Check('configuration: userland/data/etc/fonts.conf reads', Configuration.LoadFromFile('userland/data/etc/fonts.conf'));
    Families := Configuration.FamiliesFor('ARIAL');
    Check('configuration: Arial is Liberation Sans first', (Length(Families) >= 1) and (Families[0] = 'Liberation Sans'));
    Families := Configuration.FamiliesFor('times new roman');
    Check('configuration: Times New Roman is Liberation Serif', (Length(Families) >= 1) and
      (Families[0] = 'Liberation Serif'));
    Families := Configuration.FamiliesFor('monospace');
    Check('configuration: monospace is Liberation Mono', (Length(Families) >= 1) and (Families[0] = 'Liberation Mono'));
    Families := Configuration.FamiliesFor('system-ui');
    Check('configuration: system-ui stays DejaVu Sans', (Length(Families) >= 1) and (Families[0] = 'DejaVu Sans'));
    Families := Configuration.FallbackFamilies($65E5);
    Check('configuration: CJK falls back to Noto Sans CJK first', (Length(Families) > 2) and
      (Families[0] = 'Noto Sans CJK') and (Configuration.ScriptOf($65E5) = 'cjk'));
    Families := Configuration.FallbackFamilies($1F600);
    Check('configuration: emoji fall back to Noto Color Emoji first', (Length(Families) > 2) and
      (Families[0] = 'Noto Color Emoji'));
    Families := Configuration.FallbackFamilies($0627);
    Check('configuration: Arabic falls back to Noto Sans Arabic', (Length(Families) > 2) and
      (Families[0] = 'Noto Sans Arabic'));
    Check('configuration: family directories', FamilyDirectoryName('Noto Sans CJK') = 'noto-sans-cjk');
  finally
    Configuration.Free;
  end;
end;

procedure TestOpenType(const Directory: string; const References: TReferences; const Fonts: TNamedFonts);
begin
  ReportMissing(References);
  TestCollection(Fonts);
  TestEmoji(References, Fonts);
  TestWoff2(Directory, References, Fonts);
  TestBrokenCff(References);
  TestArialMetrics(Fonts);
  TestConfiguration;
end;

end.
