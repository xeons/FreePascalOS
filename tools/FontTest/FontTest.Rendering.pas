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
  Rendering glyphs, checked.

  Unhinted, every glyph the references hold (the fixtures' and
  DejaVu's, at several sizes and pen offsets of quarter pixels) is
  compared with FreeType's rendering pixel by pixel, the two bitmaps
  laid over each other where each says it goes. Both compute exact
  area coverage; they differ only in how finely curves are cut into
  lines and in FreeType's coordinates being rounded to 1/64 pixel, so
  each pixel must be within PixelTolerance and each glyph's coverage
  as a whole within GlyphTolerance (the average difference).

  Hinted (Font.Hinting): the horizontal bars of E and H, and the
  baseline, x height and cap height, fall on whole pixels at small
  sizes (no partly covered rows across them), round letters do not
  overshoot at small sizes, and hinting never changes the advance.
}
unit FontTest.Rendering;

{$mode objfpc}
{$H+}

interface

uses
  FontTest.References,
  FontTest.Parsing;

procedure TestRendering(const References: TReferences; const Fonts: TNamedFonts);

implementation

uses
  SysUtils,
  Math,
  Font.Outlines,
  Font.TrueType,
  Font.GlyphRendering,
  FontTest.Checks;

const
  PixelTolerance = 24;
  GlyphTolerance = 1.5;

type
  TComparison = record
    Glyphs: Integer;
    Failed: Integer;
    WorstPixel: Integer;
    TotalDifference: Double;
    Pixels: Int64;
    FirstFailure: string;
  end;

function CoverageAt(const Bitmap: TGlyphBitmap; X, Y: Integer): Integer;
begin
  X := X - Bitmap.Left;
  Y := Y - Bitmap.Top;
  if (X < 0) or (Y < 0) or (X >= Bitmap.Width) or (Y >= Bitmap.Height) then
    Exit(0);
  Result := Bitmap.Coverage[Y * Bitmap.Width + X];
end;

procedure CompareGlyph(const Reference: TReference; Font: TTrueTypeFont; var Comparison: TComparison);
var
  Expected: TGlyphBitmap;
  Got: TGlyphBitmap;
  Left: Integer;
  Top: Integer;
  Right: Integer;
  Bottom: Integer;
  X: Integer;
  Y: Integer;
  Difference: Integer;
  Worst: Integer;
  Total: Double;
  Count: Integer;
  Rendered: Boolean;
begin
  Expected.Left := NumberField(Reference, 3);
  Expected.Top := NumberField(Reference, 4);
  Expected.Width := NumberField(Reference, 5);
  Expected.Height := NumberField(Reference, 6);
  Expected.Coverage := CoverageField(Reference, 7);
  Rendered := RenderGlyph(Font, NumberField(Reference, 0), NumberField(Reference, 1),
    NumberField(Reference, 2) / 64, False, Got);
  Left := Min(Expected.Left, Got.Left);
  Top := Min(Expected.Top, Got.Top);
  Right := Max(Expected.Left + Expected.Width, Got.Left + Got.Width);
  Bottom := Max(Expected.Top + Expected.Height, Got.Top + Got.Height);
  Worst := 0;
  Total := 0;
  Count := 0;
  for Y := Top to Bottom - 1 do
    for X := Left to Right - 1 do
    begin
      Difference := Abs(CoverageAt(Got, X, Y) - CoverageAt(Expected, X, Y));
      Worst := Max(Worst, Difference);
      Total := Total + Difference;
      Inc(Count);
    end;
  Inc(Comparison.Glyphs);
  Comparison.WorstPixel := Max(Comparison.WorstPixel, Worst);
  Comparison.TotalDifference := Comparison.TotalDifference + Total;
  Comparison.Pixels := Comparison.Pixels + Count;
  if not Rendered or (Worst > PixelTolerance) or ((Count > 0) and (Total / Count > GlyphTolerance)) then
  begin
    Inc(Comparison.Failed);
    if Comparison.FirstFailure = '' then
      Comparison.FirstFailure := Format(' (first: glyph %d at %d pixels, offset %d/64: worst pixel %d, ' +
        'average %.2f)', [NumberField(Reference, 0), NumberField(Reference, 1), NumberField(Reference, 2), Worst,
        Total / Max(Count, 1)]);
  end;
end;

procedure TestAgainstFreeType(const References: TReferences; const Fonts: TNamedFonts);
var
  FontIndex: Integer;
  Index: Integer;
  Comparison: TComparison;
begin
  for FontIndex := 0 to High(Fonts) do
  begin
    if Fonts[FontIndex].Font = nil then
      Continue;
    Comparison.Glyphs := 0;
    Comparison.Failed := 0;
    Comparison.WorstPixel := 0;
    Comparison.TotalDifference := 0;
    Comparison.Pixels := 0;
    Comparison.FirstFailure := '';
    for Index := 0 to High(References) do
      if (References[Index].Kind = 'glyph') and (References[Index].Name = Fonts[FontIndex].Name) then
        CompareGlyph(References[Index], Fonts[FontIndex].Font, Comparison);
    if Comparison.Glyphs = 0 then
      Continue;
    Check(Format('%s: %d glyphs rendered as FreeType renders them (worst pixel %d, average %.3f; %d off)%s',
      [Fonts[FontIndex].Name, Comparison.Glyphs, Comparison.WorstPixel,
      Comparison.TotalDifference / Max(Comparison.Pixels, 1), Comparison.Failed, Comparison.FirstFailure]),
      Comparison.Failed = 0);
  end;
end;

{ --- Hinting ------------------------------------------------------------ }

function Hinted(Font: TTrueTypeFont; CodePoint: LongWord; Size: Integer): TGlyphBitmap;
begin
  RenderGlyph(Font, Font.GlyphOf(CodePoint), Size, 0, True, Result);
end;

function Unhinted(Font: TTrueTypeFont; CodePoint: LongWord; Size: Integer): TGlyphBitmap;
begin
  RenderGlyph(Font, Font.GlyphOf(CodePoint), Size, 0, False, Result);
end;

{ Whether every pixel of the bitmap's column at X pixels right of the
  pen is empty or full. }
function ColumnIsCrisp(const Bitmap: TGlyphBitmap; X: Integer): Boolean;
var
  Row: Integer;
  Value: Byte;
  Column: Integer;
begin
  Column := X - Bitmap.Left;
  Result := (Column >= 0) and (Column < Bitmap.Width);
  if not Result then
    Exit;
  for Row := 0 to Bitmap.Height - 1 do
  begin
    Value := Bitmap.Coverage[Row * Bitmap.Width + Column];
    if (Value <> 0) and (Value <> 255) then
      Exit(False);
  end;
end;

{ The topmost row with any coverage, relative to the baseline. }
function InkTop(const Bitmap: TGlyphBitmap): Integer;
var
  Row: Integer;
  Column: Integer;
begin
  for Row := 0 to Bitmap.Height - 1 do
    for Column := 0 to Bitmap.Width - 1 do
      if Bitmap.Coverage[Row * Bitmap.Width + Column] <> 0 then
        Exit(Bitmap.Top + Row);
  Result := 0;
end;

{ The row below the lowest one with any coverage, relative to the baseline. }
function InkBottom(const Bitmap: TGlyphBitmap): Integer;
var
  Row: Integer;
  Column: Integer;
begin
  for Row := Bitmap.Height - 1 downto 0 do
    for Column := 0 to Bitmap.Width - 1 do
      if Bitmap.Coverage[Row * Bitmap.Width + Column] <> 0 then
        Exit(Bitmap.Top + Row + 1);
  Result := 0;
end;

procedure TestHinting(const Fonts: TNamedFonts);
var
  Font: TTrueTypeFont;
  Size: Integer;
  E: TGlyphBitmap;
  H: TGlyphBitmap;
  X: TGlyphBitmap;
  O: TGlyphBitmap;
  BarsCrisp: Boolean;
  HeightsWhole: Boolean;
  NoOvershoot: Boolean;
  SomeBlurUnhinted: Boolean;
  Scale: Double;
  CapHeight: Integer;
  XHeight: Integer;
begin
  Font := FontNamed(Fonts, 'sans');
  if Font = nil then
    Exit;
  BarsCrisp := True;
  HeightsWhole := True;
  NoOvershoot := True;
  SomeBlurUnhinted := False;
  { DejaVu Sans: H is 1493 units high, x 1120; E's arms run from 403 to
    1114 units right of the pen (at least), H's bar from 403 to 1137: the
    columns at 760 are in them whole from 9 pixels up. }
  for Size := 9 to 24 do
  begin
    Scale := Size / Font.UnitsPerEm;
    CapHeight := RoundHalfUp(1493 * Scale);
    XHeight := RoundHalfUp(1120 * Scale);
    E := Hinted(Font, Ord('E'), Size);
    H := Hinted(Font, Ord('H'), Size);
    X := Hinted(Font, Ord('x'), Size);
    O := Hinted(Font, Ord('o'), Size);
    { E's arms and H's bar, across the middle of the letter. }
    BarsCrisp := BarsCrisp and ColumnIsCrisp(E, Floor(760 * Scale)) and ColumnIsCrisp(H, Floor(760 * Scale));
    HeightsWhole := HeightsWhole and (InkBottom(H) = 0) and (InkTop(H) = -CapHeight) and (InkTop(X) = -XHeight) and
      (InkBottom(X) = 0) and (InkBottom(E) = 0);
    if Size <= 16 then
      NoOvershoot := NoOvershoot and (InkTop(O) = InkTop(X)) and (InkBottom(O) = 0);
    if not ColumnIsCrisp(Unhinted(Font, Ord('E'), Size), Floor(760 * Scale)) then
      SomeBlurUnhinted := True;
  end;
  Check('hinted: the bars of E and H fall on whole pixels, 9 to 24 pixels', BarsCrisp);
  Check('hinted: baseline, x height and cap height on whole pixels', HeightsWhole);
  Check('hinted: o no taller than x up to 16 pixels', NoOvershoot);
  Check('unhinted, E is blurred at some sizes (so hinting does something)', SomeBlurUnhinted);
  Check('hinting keeps the advance', Font.AdvanceUnits(Font.GlyphOf(Ord('E'))) = 1294);
end;

procedure TestRenderingLimits(const Fonts: TNamedFonts);
var
  Font: TTrueTypeFont;
  Bitmap: TGlyphBitmap;
begin
  Font := FontNamed(Fonts, 'sans');
  if Font = nil then
    Exit;
  Check('no size of 0 pixels', not RenderGlyph(Font, Font.GlyphOf(Ord('A')), 0, 0, True, Bitmap) and
    (Bitmap.Width = 0));
  Check('no size past the largest', not RenderGlyph(Font, Font.GlyphOf(Ord('A')), MaximumRenderedSize + 1, 0, True,
    Bitmap));
  Check('a space renders as nothing', RenderGlyph(Font, Font.GlyphOf(32), 12, 0, True, Bitmap) and
    (Bitmap.Width = 0) and (Bitmap.Height = 0));
  Check('a large size renders', RenderGlyph(Font, Font.GlyphOf(Ord('W')), 300, 0, True, Bitmap) and
    (Bitmap.Width > 250) and (Bitmap.Height > 200));
end;

procedure TestRendering(const References: TReferences; const Fonts: TNamedFonts);
begin
  TestAgainstFreeType(References, Fonts);
  TestHinting(Fonts);
  TestRenderingLimits(Fonts);
end;

end.
