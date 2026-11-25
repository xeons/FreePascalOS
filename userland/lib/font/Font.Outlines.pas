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
  Outline fonts: fonts whose glyphs are shapes, drawn at any size.

  TOutlineFont is what the rest of libfont knows of one (Font.TrueType
  reads TrueType files into one): its metrics in font units (UnitsPerEm
  to the em, y upwards from the baseline), which glyph each character
  has, each glyph's advance and outline, and the kerning between two
  glyphs.

  An outline is contours of points, each contour closed. Points on the
  curve are joined by straight lines; a point off the curve between two
  on it is the control point of a quadratic curve, and between two off
  the curve there is an on-curve point implied halfway (TrueType's
  quadratic B-splines). A point marked Cubic is off the curve too, but
  one of the two control points of a cubic curve (CFF outlines,
  Font.CffCharStrings): two such points always come together, between
  two points on the curve.

  A rendered glyph (TGlyphBitmap) is coverage, a byte a pixel, placed
  against the pen on the baseline: its left column Left pixels right of
  the pen, its top row Top pixels below the baseline (negative above).
}
unit Font.Outlines;

{$mode objfpc}
{$H+}

interface

type
  TOutlinePoint = record
    X: Double;
    Y: Double;
    OnCurve: Boolean;
    Cubic: Boolean;
  end;

  TGlyphOutline = record
    Points: array of TOutlinePoint;
    PointCount: LongInt;
    { The index of each contour's last point. }
    ContourEnds: array of LongInt;
    ContourCount: LongInt;
  end;

  TCharacterMapping = record
    CodePoint: LongWord;
    Glyph: LongWord;
  end;
  TCharacterMappings = array of TCharacterMapping;

  { Coverage for an outline glyph; for a colour glyph (an emoji from a
    font's colour bitmaps, Font.ColorBitmaps) Colors instead, a colour
    a pixel ($AARRGGBB, not premultiplied), drawn as it is whatever the
    text's colour. }
  TGlyphBitmap = record
    Left: LongInt;
    Top: LongInt;
    Width: LongInt;
    Height: LongInt;
    Coverage: array of Byte;
    Colors: array of LongWord;
  end;
  PGlyphBitmap = ^TGlyphBitmap;

  { A height the hinter keeps on a whole pixel (font units): flat
    letters reach Reference (the baseline, the top of an x), round ones
    overshoot it a little, to Overshoot (the bottom of an o). Top zones
    hold the tops of strokes, the others their bottoms. }
  TBlueZone = record
    Reference: LongInt;
    Overshoot: LongInt;
    IsTop: Boolean;
  end;

  TBlueZones = record
    Measured: Boolean;
    Count: LongInt;
    Zones: array[0..7] of TBlueZone;
  end;

  TOutlineFont = class
  protected
    FUnitsPerEm: LongInt;
    FAscender: LongInt;
    FDescender: LongInt;
    FLineGap: LongInt;
    FMaximumAdvance: LongInt;
    FGlyphCount: LongWord;
    FBold: Boolean;
    FUnderlinePosition: LongInt;
    FUnderlineThickness: LongInt;
    FMappings: TCharacterMappings;
  public
    { Filled by Font.Hinting the first time the font is hinted. }
    BlueZones: TBlueZones;
    { How far the pen moves after Glyph (font units); 0 for a glyph the
      font does not have. }
    function AdvanceUnits(Glyph: LongWord): LongInt; virtual; abstract;
    { Glyph's outline in font units; False (and no points) if the glyph
      is not there or its data is broken. An empty glyph (a space) has
      no points and is True. }
    function LoadOutline(Glyph: LongWord; out Outline: TGlyphOutline): Boolean; virtual; abstract;
    { How far the pen moves between two glyphs besides their advances
      (font units, negative brings them closer). }
    function KerningUnits(LeftGlyph, RightGlyph: LongWord): LongInt; virtual; abstract;
    function HasKerning: Boolean; virtual; abstract;
    { Whether Glyph is drawn from a colour bitmap rather than its
      outline, and that bitmap at PixelSize pixels to the em (scaled
      from the nearest size the font has), placed as a rendered
      outline is. }
    function HasColorGlyph(Glyph: LongWord): Boolean; virtual;
    function RenderColorGlyph(Glyph: LongWord; PixelSize: LongInt; out Bitmap: TGlyphBitmap): Boolean; virtual;
    { The glyph for CodePoint followed by the variation selector
      Selector (U+FE00 to U+FE0F, U+E0100 to U+E01EF), from the
      character map's format 14 subtable; GlyphOf(CodePoint) when the
      font has no such variant. }
    function GlyphOfVariation(CodePoint, Selector: LongWord): LongWord; virtual;
    { Whether its glyphs can be drawn here (a font of colour bitmaps
      alone cannot without a decoder for them). }
    function CanDraw: Boolean; virtual;
    { The glyph for CodePoint; 0 (the missing glyph) if it has none. }
    function GlyphOf(CodePoint: LongWord): LongWord;
    { Whether the font has a glyph for CodePoint. }
    function HasCharacter(CodePoint: LongWord): Boolean;
    property UnitsPerEm: LongInt read FUnitsPerEm;
    { From the baseline up to the top of the line, and down to its
      bottom (positive both), and the space between lines. }
    property Ascender: LongInt read FAscender;
    property Descender: LongInt read FDescender;
    property LineGap: LongInt read FLineGap;
    property MaximumAdvance: LongInt read FMaximumAdvance;
    property GlyphCount: LongWord read FGlyphCount;
    property Bold: Boolean read FBold;
    { The underline's top below the baseline (positive downwards) and
      its thickness; 0 if the font does not say. }
    property UnderlinePosition: LongInt read FUnderlinePosition;
    property UnderlineThickness: LongInt read FUnderlineThickness;
    { Every character the font has, by increasing code point. }
    property Mappings: TCharacterMappings read FMappings;
  end;

{ Value rounded to the nearest whole number, halves upwards (as FreeType
  rounds; Round rounds halves to even). }
function RoundHalfUp(Value: Double): LongInt;
{ An outline with no points. }
procedure ClearOutline(out Outline: TGlyphOutline);
procedure AddOutlinePoint(var Outline: TGlyphOutline; X, Y: Double; OnCurve: Boolean);
{ A control point of a cubic curve (two in a row, then the end). }
procedure AddCubicControlPoint(var Outline: TGlyphOutline; X, Y: Double);
{ Ends the contour at the last point added. }
procedure EndOutlineContour(var Outline: TGlyphOutline);

implementation

uses
  Math;

function RoundHalfUp(Value: Double): LongInt;
begin
  Result := Floor(Value + 0.5);
end;

procedure ClearOutline(out Outline: TGlyphOutline);
begin
  Outline.Points := nil;
  Outline.PointCount := 0;
  Outline.ContourEnds := nil;
  Outline.ContourCount := 0;
end;

procedure AddOutlinePoint(var Outline: TGlyphOutline; X, Y: Double; OnCurve: Boolean);
begin
  if Outline.PointCount = Length(Outline.Points) then
    SetLength(Outline.Points, 2 * Outline.PointCount + 32);
  Outline.Points[Outline.PointCount].X := X;
  Outline.Points[Outline.PointCount].Y := Y;
  Outline.Points[Outline.PointCount].OnCurve := OnCurve;
  Outline.Points[Outline.PointCount].Cubic := False;
  Inc(Outline.PointCount);
end;

procedure AddCubicControlPoint(var Outline: TGlyphOutline; X, Y: Double);
begin
  AddOutlinePoint(Outline, X, Y, False);
  Outline.Points[Outline.PointCount - 1].Cubic := True;
end;

function TOutlineFont.HasColorGlyph(Glyph: LongWord): Boolean;
begin
  Result := False;
end;

function TOutlineFont.RenderColorGlyph(Glyph: LongWord; PixelSize: LongInt; out Bitmap: TGlyphBitmap): Boolean;
begin
  Bitmap.Left := 0;
  Bitmap.Top := 0;
  Bitmap.Width := 0;
  Bitmap.Height := 0;
  Bitmap.Coverage := nil;
  Bitmap.Colors := nil;
  Result := False;
end;

function TOutlineFont.GlyphOfVariation(CodePoint, Selector: LongWord): LongWord;
begin
  Result := GlyphOf(CodePoint);
end;

function TOutlineFont.CanDraw: Boolean;
begin
  Result := True;
end;

function TOutlineFont.HasCharacter(CodePoint: LongWord): Boolean;
begin
  Result := GlyphOf(CodePoint) <> 0;
end;

procedure EndOutlineContour(var Outline: TGlyphOutline);
begin
  if Outline.ContourCount = Length(Outline.ContourEnds) then
    SetLength(Outline.ContourEnds, 2 * Outline.ContourCount + 8);
  Outline.ContourEnds[Outline.ContourCount] := Outline.PointCount - 1;
  Inc(Outline.ContourCount);
end;

function TOutlineFont.GlyphOf(CodePoint: LongWord): LongWord;
var
  Low: LongInt;
  High: LongInt;
  Middle: LongInt;
begin
  Low := 0;
  High := Length(FMappings) - 1;
  while Low <= High do
  begin
    Middle := (Low + High) div 2;
    if FMappings[Middle].CodePoint = CodePoint then
      Exit(FMappings[Middle].Glyph);
    if FMappings[Middle].CodePoint < CodePoint then
      Low := Middle + 1
    else
      High := Middle - 1;
  end;
  Result := 0;
end;

end.
