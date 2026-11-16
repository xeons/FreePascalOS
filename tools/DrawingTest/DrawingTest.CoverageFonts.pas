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
  Coverage fonts (Font.Coverage) and proportional text, checked: a small
  font built here, measured and drawn pixel by pixel (each pixel the
  text colour blended gamma-correct by the glyph's coverage), kerned;
  every way of breaking it refused; then the system's DejaVu Sans, a
  TrueType font made into faces at pixel sizes (its metrics, kerning,
  glyphs drawn exactly as rendered, every ASCII glyph within the line),
  and a family of faces read only when picked, giving every size.
  (tools/FontTest checks the TrueType reading and rendering itself,
  against FreeType.)
}
unit DrawingTest.CoverageFonts;

{$mode objfpc}
{$H+}

interface

uses
  Font.Faces;

procedure TestCoverageFonts(Directory: string);
{ The TrueType font Name in Directory made into a face of Size pixels. }
function LoadOutlineFace(Directory, Name: string; Size: LongInt; out Face: TFontFace): Boolean;

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
  Font.Coverage,
  Font.TrueType,
  Font.OutlineFaces,
  Font.GlyphRendering,
  Font.Text,
  DrawingTest.Checks;

const
  HeaderSize = 40;
  GlyphEntrySize = 20;
  KerningEntrySize = 12;

{ The TrueType font at Path as a face of any size. }
function LoadScalableFace(Path: string; out Face: TFontFace): Boolean;
var
  Data: TBytes;
  Font: TTrueTypeFont;
begin
  ClearFace(Face);
  Font := nil;
  if ReadFileBytes(Path, Data) then
    Font := LoadTrueTypeFont(Data);
  Result := Font <> nil;
  if Result then
    DescribeOutlineFont(Font, Face);
end;

function LoadOutlineFace(Directory, Name: string; Size: LongInt; out Face: TFontFace): Boolean;
var
  Scalable: TFontFace;
begin
  ClearFace(Face);
  Result := LoadScalableFace(IncludeTrailingPathDelimiter(Directory) + Name, Scalable);
  if Result then
    MakeOutlineFace(Scalable, Size, Face);
end;

{ --- A font built here ---------------------------------------------------------- }

procedure Put16(var Data: TBytes; Position: Integer; Value: LongInt);
begin
  Data[Position] := Byte(Value);
  Data[Position + 1] := Byte(Value shr 8);
end;

procedure Put32(var Data: TBytes; Position: Integer; Value: LongWord);
begin
  Data[Position] := Byte(Value);
  Data[Position + 1] := Byte(Value shr 8);
  Data[Position + 2] := Byte(Value shr 16);
  Data[Position + 3] := Byte(Value shr 24);
end;

procedure PutGlyph(var Data: TBytes; Index: Integer; CodePoint, Offset: LongWord; Advance, LeftBearing, Top, Width,
  Height: LongInt);
var
  Position: Integer;
begin
  Position := HeaderSize + Index * GlyphEntrySize;
  Put32(Data, Position, CodePoint);
  Put32(Data, Position + 4, Offset);
  Put16(Data, Position + 8, Advance);
  Put16(Data, Position + 10, LeftBearing);
  Put16(Data, Position + 12, Top);
  Put16(Data, Position + 14, Width);
  Put16(Data, Position + 16, Height);
end;

{ A 6 pixel font, line 8 high, baseline at 6: "A" (advance 5, a 2x2
  bitmap 255 128 / 64 0 one right of the pen and two down), "V"
  (advance 4, a 1x1 bitmap of 200 at the pen, three down) and "?" (the
  fallback, advance 3, no bitmap); "AV" kerned by -1. }
function BuildSmallFont: TBytes;
const
  GlyphCount = 3;
  KerningCount = 1;
  CoverageSize = 5;
var
  KerningOffset: Integer;
  CoverageOffset: Integer;
begin
  KerningOffset := HeaderSize + GlyphCount * GlyphEntrySize;
  CoverageOffset := KerningOffset + KerningCount * KerningEntrySize;
  Result := nil;
  SetLength(Result, CoverageOffset + CoverageSize);
  FillChar(Result[0], Length(Result), 0);
  Result[0] := Ord('C');
  Result[1] := Ord('V');
  Result[2] := Ord('F');
  Result[3] := Ord('1');
  Put16(Result, 4, HeaderSize);
  Put16(Result, 6, 0);
  Put16(Result, 8, 6);
  Put16(Result, 10, 8);
  Put16(Result, 12, 6);
  Put16(Result, 14, 7);
  Put16(Result, 16, 1);
  Put16(Result, 18, GlyphCount);
  Put32(Result, 20, KerningCount);
  Put32(Result, 24, HeaderSize);
  Put32(Result, 28, KerningOffset);
  Put32(Result, 32, CoverageOffset);
  Put32(Result, 36, CoverageSize);
  PutGlyph(Result, 0, Ord('?'), 0, 3, 0, 0, 0, 0);
  PutGlyph(Result, 1, Ord('A'), 0, 5, 1, 2, 2, 2);
  PutGlyph(Result, 2, Ord('V'), 4, 4, 0, 3, 1, 1);
  Put32(Result, KerningOffset, Ord('A'));
  Put32(Result, KerningOffset + 4, Ord('V'));
  Put16(Result, KerningOffset + 8, -1);
  Result[CoverageOffset] := 255;
  Result[CoverageOffset + 1] := 128;
  Result[CoverageOffset + 2] := 64;
  Result[CoverageOffset + 3] := 0;
  Result[CoverageOffset + 4] := 200;
end;

function Grey(Value: Byte): TColor;
begin
  Result := RgbColor(Value, Value, Value);
end;

{ One channel of Color drawn over Ground by Coverage, gamma-correct:
  the light of both mixed (Drawing.CoverageBlending), worked out here
  in floating point. }
function GammaChannel(Ground, Color, Coverage: Byte): Byte;
var
  Light: Double;
begin
  Light := (1 - Coverage / 255) * Power(Ground / 255, TextGamma) + Coverage / 255 * Power(Color / 255, TextGamma);
  Result := Floor(255 * Power(Light, 1 / TextGamma) + 0.5);
end;

{ White over black by Coverage. }
function GammaGrey(Coverage: Byte): TColor;
begin
  Result := Grey(GammaChannel(0, 255, Coverage));
end;

procedure TestSmallFont;
var
  Data: TBytes;
  Broken: TBytes;
  Face: TFontFace;
  Surface: TSurface;
  Canvas: TCanvas;
  Length: Integer;
  AllRefused: Boolean;
  Size: LongInt;
  Bold: Boolean;
begin
  Data := BuildSmallFont;
  Check('coverage font: parsed', ParseCoverageFont(@Data[0], System.Length(Data), Face) and (Face.Size = 6) and
    (Face.Height = 8) and (Face.Ascent = 6) and (Face.UnderlineTop = 7) and (Face.GlyphCount = 3) and
    (Face.KerningCount = 1) and (Face.Format = GlyphCoverage) and not Face.Bold);
  Check('coverage font: summary from the header alone', ReadCoverageFontSummary(@Data[0], HeaderSize, Size, Bold) and
    (Size = 6) and not Bold);
  Check('coverage font: advances of their own', (CharacterAdvance(Face, Ord('A')) = 5) and
    (CharacterAdvance(Face, Ord('V')) = 4) and (CharacterAdvance(Face, Ord('Z')) = 3));
  Check('coverage font: kerning', (KerningBetween(Face, Ord('A'), Ord('V')) = -1) and
    (KerningBetween(Face, Ord('V'), Ord('A')) = 0));
  Check('measure: kerned pairs', (MeasureText(Face, 'AV') = 8) and (MeasureText(Face, 'VA') = 9) and
    (MeasureText(Face, 'A'#9'V') = 9));
  { Drawn white on black from (2, 1): "A"'s bitmap at (3, 3), each pixel
    its coverage; "V" at the kerned pen 2 + 5 - 1, three down. }
  Surface := NewSurface(16, 10, ColorBlack);
  BeginCanvas(Canvas, Surface);
  Check('draw: returns the kerned width', DrawText(Canvas, Face, 2, 1, 'AV', ColorWhite) = 8);
  Check('draw: coverage blended exactly, gamma-correct', (GetSurfacePixel(Surface, 3, 3) = ColorWhite) and
    (GetSurfacePixel(Surface, 4, 3) = GammaGrey(128)) and (GetSurfacePixel(Surface, 3, 4) = GammaGrey(64)) and
    (GetSurfacePixel(Surface, 4, 4) = ColorBlack) and (GetSurfacePixel(Surface, 6, 4) = GammaGrey(200)) and
    (CountPixels(Surface, ColorBlack) = 16 * 10 - 4));
  Check('draw: half covered white on black is lighter than halfway (174)', GammaGrey(128) = Grey(174));
  { Over a colour, half coverage is half the light of each. }
  FillRectangle(Canvas, SurfaceBounds(Surface), $FF0000FF);
  DrawText(Canvas, Face, 2, 1, 'A', $FFFF0000);
  CheckColor('draw: blended over what is there', GetSurfacePixel(Surface, 4, 3),
    RgbColor(GammaChannel(0, 255, 128), 0, GammaChannel(255, 0, 128)));
  FreeSurface(Surface);

  { Every way of breaking it is refused. }
  AllRefused := True;
  for Length := 0 to System.Length(Data) - 1 do
    AllRefused := AllRefused and not ParseCoverageFont(@Data[0], Length, Face);
  Check('coverage font: every truncation refused', AllRefused);
  Broken := Copy(Data);
  Broken[0] := Ord('X');
  Check('coverage font: bad magic refused', not ParseCoverageFont(@Broken[0], System.Length(Broken), Face));
  Broken := Copy(Data);
  Put32(Broken, HeaderSize + GlyphEntrySize + 4, 4);
  Check('coverage font: a bitmap past the data refused', not ParseCoverageFont(@Broken[0], System.Length(Broken), Face));
  Broken := Copy(Data);
  Put16(Broken, HeaderSize + GlyphEntrySize + 14, $FFFF);
  Check('coverage font: a huge bitmap refused', not ParseCoverageFont(@Broken[0], System.Length(Broken), Face));
  Broken := Copy(Data);
  Put32(Broken, HeaderSize + 2 * GlyphEntrySize, Ord('A'));
  Check('coverage font: code points out of order refused',
    not ParseCoverageFont(@Broken[0], System.Length(Broken), Face));
  Broken := Copy(Data);
  Put32(Broken, 20, 2);
  Check('coverage font: a kerning table past the end refused',
    not ParseCoverageFont(@Broken[0], System.Length(Broken), Face));
  Broken := Copy(Data);
  Put32(Broken, 24, $FFFFFFF0);
  Check('coverage font: a glyph table past the end refused',
    not ParseCoverageFont(@Broken[0], System.Length(Broken), Face));
  Broken := Copy(Data);
  Put16(Broken, 18, 0);
  Check('coverage font: no glyphs refused', not ParseCoverageFont(@Broken[0], System.Length(Broken), Face));
  Check('coverage font: nothing refused', not ParseCoverageFont(nil, 0, Face));
end;

{ --- DejaVu Sans ------------------------------------------------------------------ }

{ Draws CodePoint white on black and compares every pixel with the
  glyph as rendered (hinted), blended. }
function OutlineGlyphDrawsExactly(const Face: TFontFace; CodePoint: LongWord): Boolean;
var
  Surface: TSurface;
  Canvas: TCanvas;
  Glyph: LongWord;
  Bitmap: TGlyphBitmap;
  Row: Integer;
  Column: Integer;
  Left: Integer;
  Top: Integer;
  Drawn: Integer;
begin
  Glyph := GlyphFor(Face, CodePoint);
  Surface := NewSurface(Face.Width + 8, Face.Height + 8, ColorBlack);
  BeginCanvas(Canvas, Surface);
  Result := DrawCharacter(Canvas, Face, 4, 4, CodePoint, ColorWhite) = CharacterAdvance(Face, CodePoint);
  Result := Result and RenderGlyph(Face.Outlines, Glyph, Face.Size, 0, True, Bitmap);
  Left := 4 + Bitmap.Left;
  Top := 4 + Face.Ascent + Bitmap.Top;
  Drawn := 0;
  for Row := 0 to Bitmap.Height - 1 do
    for Column := 0 to Bitmap.Width - 1 do
    begin
      Result := Result and (GetSurfacePixel(Surface, Left + Column, Top + Row) =
        GammaGrey(Bitmap.Coverage[Row * Bitmap.Width + Column]));
      if Bitmap.Coverage[Row * Bitmap.Width + Column] <> 0 then
        Inc(Drawn);
    end;
  Result := Result and (Drawn > 0) and (CountPixels(Surface, ColorBlack) = Surface.Width * Surface.Height - Drawn);
  FreeSurface(Surface);
end;

{ The glyph of CodePoint as rendered (hinted) at the face's size. }
function RenderedGlyph(const Face: TFontFace; CodePoint: LongWord): TGlyphBitmap;
begin
  RenderGlyph(Face.Outlines, GlyphFor(Face, CodePoint), Face.Size, 0, True, Result);
end;

{ Whether every printable ASCII glyph lies within the line, so text
  drawn in a box its line high loses no descender or accent. }
function AsciiFitsTheLine(const Face: TFontFace): Boolean;
var
  CodePoint: LongWord;
  Bitmap: TGlyphBitmap;
begin
  Result := True;
  for CodePoint := $21 to $7E do
  begin
    Bitmap := RenderedGlyph(Face, CodePoint);
    if (Face.Ascent + Bitmap.Top < 0) or (Face.Ascent + Bitmap.Top + Bitmap.Height > Face.Height) then
      Result := False;
  end;
end;

{ The host's loader for a font set: the face's file read with the
  normal runtime library. }
function LoadHostFace(var Face: TFontFace): Boolean;
var
  Loaded: TFontFace;
begin
  Result := LoadScalableFace(Face.Source, Loaded) and (Loaded.Bold = Face.Bold) and Loaded.AnySize;
  if Result then
  begin
    Loaded.Source := Face.Source;
    Face := Loaded;
  end;
end;

{ A face of any size known by its file only, as Font.Files lists them. }
function KnownFace(Path: string; Bold: Boolean): TFontFace;
begin
  ClearFace(Result);
  Result.Format := GlyphOutline;
  Result.AnySize := True;
  Result.Bold := Bold;
  Result.Source := Path;
end;

procedure TestDejaVuSans(Directory: string);
var
  Face: TFontFace;
  Bold: TFontFace;
  FontSet: TFontSet;
  Selected: PFontFace;
  Regular: string;
  BoldPath: string;
begin
  Regular := IncludeTrailingPathDelimiter(Directory) + 'DejaVuSans.ttf';
  BoldPath := IncludeTrailingPathDelimiter(Directory) + 'DejaVuSans-Bold.ttf';
  Check('DejaVu Sans at 12 pixels', LoadOutlineFace(Directory, 'DejaVuSans.ttf', 12, Face) and (Face.Size = 12) and
    (Face.Height = 15) and (Face.Ascent = 12) and not Face.Bold and (Face.Format = GlyphOutline));
  Check('DejaVu Sans 12: Latin-1 and the euro', HasGlyphFor(Face, $E9) and HasGlyphFor(Face, $20AC) and
    HasGlyphFor(Face, $FFFD) and (GlyphFor(Face, $10FFFF) = Face.FallbackGlyph));
  Check('DejaVu Sans 12: proportional', (CharacterAdvance(Face, Ord('i')) < CharacterAdvance(Face, Ord('W'))) and
    (CharacterAdvance(Face, Ord('W')) <= Face.Width));
  Check('DejaVu Sans 12: kerned (AV, To)',
    (MeasureText(Face, 'AV') < CharacterAdvance(Face, Ord('A')) + CharacterAdvance(Face, Ord('V'))) and
    (MeasureText(Face, 'To') < CharacterAdvance(Face, Ord('T')) + CharacterAdvance(Face, Ord('o'))));
  Check('DejaVu Sans 12: g drawn exactly', OutlineGlyphDrawsExactly(Face, Ord('g')));
  Check('DejaVu Sans 12: e acute drawn exactly', OutlineGlyphDrawsExactly(Face, $E9));
  Check('DejaVu Sans 12: g reaches below the baseline',
    RenderedGlyph(Face, Ord('g')).Top + RenderedGlyph(Face, Ord('g')).Height > 0);
  Check('DejaVu Sans 12: ASCII within the line', AsciiFitsTheLine(Face));
  Check('DejaVu Sans Bold at 13 pixels', LoadOutlineFace(Directory, 'DejaVuSans-Bold.ttf', 13, Bold) and Bold.Bold and
    (Bold.Size = 13) and OutlineGlyphDrawsExactly(Bold, Ord('W')) and AsciiFitsTheLine(Bold));
  Check('DejaVu Sans Bold 13: wider than regular', MeasureText(Bold, 'Sample') > MeasureText(Face, 'Sample'));

  { A family known by its files, read only when picked, in every size. }
  ClearFontSet(FontSet);
  FontSet.Loader := @LoadHostFace;
  AddFace(FontSet, KnownFace(Regular, False));
  AddFace(FontSet, KnownFace(BoldPath, True));
  Check('family: every size, without reading', (SelectedFaceSize(FontSet, 90, 96, False) = 12) and
    (SelectedFaceSize(FontSet, 90, 144, True) = 18) and (SelectedFaceSize(FontSet, 60, 72, False) = 6) and
    (SelectedFaceSize(FontSet, 400, 144, False) = 80) and not FontSet.Faces[0].Loaded);
  Selected := SelectFace(FontSet, 90, 96, False);
  Check('family: 9 points at 96 DPI is 12 pixels, the only font read', (Selected <> nil) and
    (Selected^.Size = 12) and Selected^.Loaded and (Selected^.Height = 15) and FontSet.Faces[0].Loaded and
    not FontSet.Faces[1].Loaded);
  Selected := SelectFace(FontSet, 90, 144, True);
  Check('family: 9 points bold at 144 DPI is 18 pixels', (Selected <> nil) and Selected^.Bold and (Selected^.Size = 18));
  { A face that cannot be read is passed over for the next. }
  ClearFontSet(FontSet);
  FontSet.Loader := @LoadHostFace;
  AddFace(FontSet, KnownFace(IncludeTrailingPathDelimiter(Directory) + 'missing.ttf', False));
  AddFace(FontSet, KnownFace(Regular, False));
  Selected := SelectFace(FontSet, 100, 96, False);
  Check('family: an unreadable font is passed over', (Selected <> nil) and (Selected^.Size = 13) and
    FontSet.Faces[0].Unusable);
  { A file whose weight is not what it was listed as is not taken. }
  ClearFontSet(FontSet);
  FontSet.Loader := @LoadHostFace;
  AddFace(FontSet, KnownFace(Regular, True));
  Check('family: a font that is not what was listed is refused', SelectFace(FontSet, 100, 96, True) = nil);
end;

procedure TestCoverageFonts(Directory: string);
begin
  TestSmallFont;
  TestDejaVuSans(Directory);
end;

end.
