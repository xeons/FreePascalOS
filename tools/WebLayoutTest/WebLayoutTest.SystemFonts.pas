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
  Font matching with the system's fonts and configuration: the fonts
  kept in the source tree (the directory in WEB_HOST_FONTS,
  userland/data/fonts) and userland/data/etc/fonts.conf.
  Arial must be Liberation Sans with Arial's advances, Times New Roman
  Liberation Serif, monospace Liberation Mono, system-ui DejaVu Sans;
  text mixing Latin, Japanese and emoji must find a face with a glyph
  for every character (Noto Sans CJK, Noto Color Emoji drawn in
  colour), and painting it must put colour on the page. Skipped, with a
  message, when WEB_HOST_FONTS is not set or lacks those fonts.
}
unit WebLayoutTest.SystemFonts;

{$mode objfpc}
{$H+}

interface

procedure CheckSystemFonts;

implementation

uses
  SysUtils, TestChecks, Font.Configuration, Font.Outlines, Font.GlyphCache, Font.GlyphRendering,
  Web.Text.Fonts, Web.Text.FontInstances, WebLayoutTest.Pages;

procedure CheckMatching;
var
  Font: TTextFont;
  Glyphs: TPlacedGlyphArray;
  Count, Index: Integer;
  AllFound, AnyCjk, AnyEmoji: Boolean;
  Width: Double;
  Bitmap: TGlyphBitmap;
begin
  Font := MakeTextFont(['Arial', 'sans-serif'], 2048, 400, False);
  Check((Font.Primary <> nil) and (Font.Primary.Family = 'liberation sans'), 'fonts: Arial is Liberation Sans');
  Check(Abs(Font.AdvanceOf(Ord('A')) - 1366) < 0.01, 'fonts: Arial''s A is 1366 units wide');
  Width := Font.MeasureText('Arial', 1, 5);
  Check(Abs(Width - (1366 + 682 + 455 + 1139 + 455)) < 0.5, Format('fonts: "Arial" measures as in Arial (%.1f)', [Width]));
  Font := MakeTextFont(['Helvetica'], 16, 700, False);
  Check((Font.Primary <> nil) and (Font.Primary.Family = 'nimbus sans') and (Font.Primary.Weight = 700),
    'fonts: bold Helvetica is Nimbus Sans Bold');
  Font := MakeTextFont(['Times New Roman', 'serif'], 16, 400, True);
  Check((Font.Primary <> nil) and (Font.Primary.Family = 'liberation serif') and Font.Primary.Italic,
    'fonts: italic Times New Roman is Liberation Serif Italic');
  Font := MakeTextFont(['monospace'], 16, 400, False);
  Check((Font.Primary <> nil) and (Font.Primary.Family = 'liberation mono'), 'fonts: monospace is Liberation Mono');
  Font := MakeTextFont(['system-ui'], 16, 400, False);
  Check((Font.Primary <> nil) and (Font.Primary.Family = 'dejavu sans'), 'fonts: system-ui stays DejaVu Sans');
  Font := MakeTextFont(['Courier New'], 16, 400, False);
  Check((Font.Primary <> nil) and (Font.Primary.Family = 'liberation mono'), 'fonts: Courier New is Liberation Mono');
  { Mixed scripts: every character a face with its glyph. }
  Font := MakeTextFont(['sans-serif'], 16, 400, False);
  Glyphs := nil;
  Font.PlaceGlyphs('Wiki 日本語 Ελληνικά العربية हिन्दी 한국어 ☺😀👍', 1,
    Length('Wiki 日本語 Ελληνικά العربية हिन्दी 한국어 ☺😀👍'), Glyphs, Count);
  AllFound := Count > 20;
  AnyCjk := False;
  AnyEmoji := False;
  for Index := 0 to Count - 1 do
  begin
    if Glyphs[Index].CodePoint = 32 then
      Continue;
    if (Glyphs[Index].Face = nil) or (Glyphs[Index].Glyph = 0) then
    begin
      AllFound := False;
      WriteLn('no glyph for U+', IntToHex(Glyphs[Index].CodePoint, 4));
    end
    else
    begin
      if (Glyphs[Index].CodePoint = $65E5) and (Glyphs[Index].Face.Family = 'noto sans cjk') then
        AnyCjk := True;
      if (Glyphs[Index].CodePoint = $1F600) and (Glyphs[Index].Face.Family = 'noto color emoji') then
        AnyEmoji := True;
    end;
  end;
  Check(AllFound, 'fonts: Latin, Japanese, Greek, Arabic, Devanagari, Korean and emoji all have glyphs (no boxes)');
  Check(AnyCjk, 'fonts: 日 is drawn from Noto Sans CJK');
  Check(AnyEmoji, 'fonts: 😀 is drawn from Noto Color Emoji');
  for Index := 0 to Count - 1 do
    if Glyphs[Index].CodePoint = $1F600 then
    begin
      Check(RenderGlyph(Glyphs[Index].Face.Font, Glyphs[Index].Glyph, 20, 0, False, Bitmap) and
        (Length(Bitmap.Colors) > 100), 'fonts: 😀 renders in colour');
      Break;
    end;
  { U+FE0F asks for emoji presentation; the selector itself takes no room. }
  Glyphs := nil;
  Font.PlaceGlyphs('☺'#$EF#$B8#$8F, 1, 6, Glyphs, Count);
  Check((Count = 1) and (Glyphs[0].Face <> nil) and (Glyphs[0].Face.Family = 'noto color emoji'),
    'fonts: ☺ with U+FE0F is the colour emoji, the selector placed nowhere');
end;

procedure CheckSystemFonts;
var
  Directory: string;
begin
  Directory := GetEnvironmentVariable('WEB_HOST_FONTS');
  if (Directory = '') or not DirectoryExists(IncludeTrailingPathDelimiter(Directory) + 'liberation-sans') or
     not DirectoryExists(IncludeTrailingPathDelimiter(Directory) + 'noto-sans-cjk') or
     not DirectoryExists(IncludeTrailingPathDelimiter(Directory) + 'noto-color-emoji') then
  begin
    WriteLn('skipped: the system fonts (WEB_HOST_FONTS=', Directory, ' lacks Liberation, Noto Sans CJK or emoji)');
    Exit;
  end;
  ClearTextFonts;
  FontConfigurationPath := 'userland/data/etc/fonts.conf';
  ResetSystemFontConfiguration;
  SetFontDirectory(Directory);
  try
    CheckMatching;
  finally
    ClearTextFonts;
    ClearGlyphCache;
    FontConfigurationPath := '/etc/fonts.conf';
    ResetSystemFontConfiguration;
  end;
end;

end.
