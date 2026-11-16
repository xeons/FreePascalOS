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
  Font faces: one font in one size and weight, whatever file it came
  from (Font.Psf, Font.Coverage).

  A face has a line: Height pixels from its top to the next line's,
  the baseline Ascent pixels down. Every glyph has its own advance (how
  far the pen moves after it) and a bitmap placed against the pen: its
  left column LeftBearing pixels right of the pen, its top row Top
  pixels below the top of the line. A monospaced face is just one whose
  advances are all the same. Pairs of characters may be kerned: the
  pen moves by the pair's adjustment between them as well.

  Bitmaps are either bits (a bitmap font: rows of (Width + 7) div 8
  bytes, the leftmost pixel in the top bit) or coverage (a rendered
  font: a byte a pixel, 0 nothing to 255 fully covered, drawn by
  blending the text colour over what is there).

  An outline face (Format GlyphOutline) has no bitmaps of its own: its
  glyphs are rendered from its outline font (Outlines, Font.Outlines)
  when drawn and kept in the glyph cache (Font.GlyphCache). A family
  lists such a font once, as a face of any size (AnySize, Size 0); the
  face picked for a size is made from it at that pixel size (Font.Text,
  Font.OutlineFaces), its advances and kerning the font's scaled and
  rounded to whole pixels, its glyphs hinted (Hinted).

  A face can be known before its glyphs are read: its Size, weight and
  the file they are in (Source), which is all that picking a face
  needs; the glyphs are read the first time it is picked (Font.Text,
  Font.Files), so a program does not read every size of every font.
}
unit Font.Faces;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

uses
  Font.Outlines;

type
  TGlyphFormat = (GlyphBits, GlyphCoverage, GlyphOutline);

  TGlyph = record
    Advance: LongInt;
    LeftBearing: LongInt;
    Top: LongInt;
    Width: LongInt;
    Height: LongInt;
    { Where its bitmap starts in the face's Bitmaps. }
    BitmapOffset: PtrUInt;
  end;

  TCodePointGlyph = record
    CodePoint: LongWord;
    Glyph: LongWord;
  end;

  TKerningPair = record
    Left: LongWord;
    Right: LongWord;
    Adjustment: LongInt;
  end;

  TFontFace = record
    { The pixel size the face is picked by: the em, for a bitmap font
      the em its height stands for (Font.Psf). }
    Size: LongInt;
    Bold: Boolean;
    { The file the glyphs are read from; empty for a face built in
      memory. }
    Source: string;
    { Whether the glyphs are there; and whether reading them failed
      (the face is then never picked). }
    Loaded: Boolean;
    Unusable: Boolean;
    { The line. }
    Height: LongInt;
    Ascent: LongInt;
    UnderlineTop: LongInt;
    UnderlineThickness: LongInt;
    { The widest advance: every advance for a monospaced face. }
    Width: LongInt;
    Format: TGlyphFormat;
    GlyphCount: LongWord;
    Glyphs: array of TGlyph;
    Bitmaps: array of Byte;
    { Sorted by code point. }
    Map: array of TCodePointGlyph;
    MapCount: LongInt;
    { What is drawn for a character the face lacks. }
    FallbackGlyph: LongWord;
    { Sorted by left, then right code point. }
    Kerning: array of TKerningPair;
    KerningCount: LongInt;
    { An outline face: the font its glyphs come from (shared by every
      size made from it, never freed); whether it stands for every size
      (a family's listing) and whether its glyphs are hinted. }
    Outlines: TOutlineFont;
    AnySize: Boolean;
    Hinted: Boolean;
  end;
  PFontFace = ^TFontFace;

{ An empty face: no glyphs, nothing known. }
procedure ClearFace(out Face: TFontFace);
{ Building a face's map: code points in any order (AddMapping), then
  FinishMap sorts them (the first glyph given for a code point stays)
  and picks the fallback glyph (U+FFFD, else "?", else glyph 0). }
procedure AddMapping(var Face: TFontFace; CodePoint, Glyph: LongWord);
procedure FinishMap(var Face: TFontFace);

{ The glyph for CodePoint, or the fallback. }
function GlyphFor(const Face: TFontFace; CodePoint: LongWord): LongWord;
function HasGlyphFor(const Face: TFontFace; CodePoint: LongWord): Boolean;
{ How many bytes one row of Glyph's bitmap takes. }
function GlyphRowBytes(const Face: TFontFace; Glyph: LongWord): LongInt;
{ The glyph's row Row (0 at its top). }
function GlyphRow(const Face: TFontFace; Glyph: LongWord; Row: LongInt): PByte;
{ How far the pen moves between Left and Right besides their advances:
  the pair's kerning, 0 if it has none. }
function KerningBetween(const Face: TFontFace; Left, Right: LongWord): LongInt;
{ Whether any pair of the face's characters is kerned at all. }
function FaceHasKerning(const Face: TFontFace): Boolean;

implementation

const
  ReplacementCharacter = $FFFD;
  QuestionMark = Ord('?');

procedure ClearFace(out Face: TFontFace);
begin
  Face.Size := 0;
  Face.Bold := False;
  Face.Source := '';
  Face.Loaded := False;
  Face.Unusable := False;
  Face.Height := 0;
  Face.Ascent := 0;
  Face.UnderlineTop := 0;
  Face.UnderlineThickness := 0;
  Face.Width := 0;
  Face.Format := GlyphBits;
  Face.GlyphCount := 0;
  Face.Glyphs := nil;
  Face.Bitmaps := nil;
  Face.Map := nil;
  Face.MapCount := 0;
  Face.FallbackGlyph := 0;
  Face.Kerning := nil;
  Face.KerningCount := 0;
  Face.Outlines := nil;
  Face.AnySize := False;
  Face.Hinted := False;
end;

procedure AddMapping(var Face: TFontFace; CodePoint, Glyph: LongWord);
begin
  if Face.MapCount = System.Length(Face.Map) then
    SetLength(Face.Map, 2 * Face.MapCount + 256);
  Face.Map[Face.MapCount].CodePoint := CodePoint;
  Face.Map[Face.MapCount].Glyph := Glyph;
  Inc(Face.MapCount);
end;

{ The map sorted by code point (a font's table is nearly in order, so
  insertion sort is quick), repeated code points dropped. }
procedure SortMap(var Face: TFontFace);
var
  Index: LongInt;
  Sorted: LongInt;
  Entry: TCodePointGlyph;
  Kept: LongInt;
begin
  for Index := 1 to Face.MapCount - 1 do
  begin
    Entry := Face.Map[Index];
    Sorted := Index - 1;
    while (Sorted >= 0) and (Face.Map[Sorted].CodePoint > Entry.CodePoint) do
    begin
      Face.Map[Sorted + 1] := Face.Map[Sorted];
      Dec(Sorted);
    end;
    Face.Map[Sorted + 1] := Entry;
  end;
  Kept := 0;
  for Index := 0 to Face.MapCount - 1 do
    if (Kept = 0) or (Face.Map[Kept - 1].CodePoint <> Face.Map[Index].CodePoint) then
    begin
      Face.Map[Kept] := Face.Map[Index];
      Inc(Kept);
    end;
  Face.MapCount := Kept;
end;

procedure FinishMap(var Face: TFontFace);
begin
  SortMap(Face);
  Face.FallbackGlyph := 0;
  if HasGlyphFor(Face, ReplacementCharacter) then
    Face.FallbackGlyph := GlyphFor(Face, ReplacementCharacter)
  else if HasGlyphFor(Face, QuestionMark) then
    Face.FallbackGlyph := GlyphFor(Face, QuestionMark);
end;

{ The map entry for CodePoint, or -1. }
function FindMapping(const Face: TFontFace; CodePoint: LongWord): LongInt;
var
  Low: LongInt;
  High: LongInt;
  Middle: LongInt;
begin
  Low := 0;
  High := Face.MapCount - 1;
  while Low <= High do
  begin
    Middle := (Low + High) div 2;
    if Face.Map[Middle].CodePoint = CodePoint then
      Exit(Middle);
    if Face.Map[Middle].CodePoint < CodePoint then
      Low := Middle + 1
    else
      High := Middle - 1;
  end;
  Result := -1;
end;

function HasGlyphFor(const Face: TFontFace; CodePoint: LongWord): Boolean;
begin
  Result := FindMapping(Face, CodePoint) >= 0;
end;

function GlyphFor(const Face: TFontFace; CodePoint: LongWord): LongWord;
var
  Index: LongInt;
begin
  Index := FindMapping(Face, CodePoint);
  if Index < 0 then
    Result := Face.FallbackGlyph
  else
    Result := Face.Map[Index].Glyph;
end;

function GlyphRowBytes(const Face: TFontFace; Glyph: LongWord): LongInt;
begin
  if Face.Format = GlyphOutline then
    Exit(0);
  if Glyph >= Face.GlyphCount then
    Glyph := Face.FallbackGlyph;
  if Face.Format = GlyphBits then
    Result := (Face.Glyphs[Glyph].Width + 7) div 8
  else
    Result := Face.Glyphs[Glyph].Width;
end;

function GlyphRow(const Face: TFontFace; Glyph: LongWord; Row: LongInt): PByte;
begin
  if Face.Format = GlyphOutline then
    Exit(nil);
  if Glyph >= Face.GlyphCount then
    Glyph := Face.FallbackGlyph;
  Result := @Face.Bitmaps[Face.Glyphs[Glyph].BitmapOffset + PtrUInt(Row) * PtrUInt(GlyphRowBytes(Face, Glyph))];
end;

{ An outline face's kerning: the font's, in pixels at the face's size. }
function OutlineKerning(const Face: TFontFace; Left, Right: LongWord): LongInt;
var
  Units: LongInt;
begin
  Result := 0;
  if (Face.Outlines = nil) or (Face.Size <= 0) or not Face.Outlines.HasKerning then
    Exit;
  Units := Face.Outlines.KerningUnits(GlyphFor(Face, Left), GlyphFor(Face, Right));
  if Units <> 0 then
    Result := RoundHalfUp(Units * Face.Size / Face.Outlines.UnitsPerEm);
end;

function FaceHasKerning(const Face: TFontFace): Boolean;
begin
  if Face.Format = GlyphOutline then
    Result := (Face.Outlines <> nil) and Face.Outlines.HasKerning
  else
    Result := Face.KerningCount > 0;
end;

function KerningBetween(const Face: TFontFace; Left, Right: LongWord): LongInt;
var
  Low: LongInt;
  High: LongInt;
  Middle: LongInt;
  Pair: TKerningPair;
begin
  if Face.Format = GlyphOutline then
    Exit(OutlineKerning(Face, Left, Right));
  Low := 0;
  High := Face.KerningCount - 1;
  while Low <= High do
  begin
    Middle := (Low + High) div 2;
    Pair := Face.Kerning[Middle];
    if (Pair.Left = Left) and (Pair.Right = Right) then
      Exit(Pair.Adjustment);
    if (Pair.Left < Left) or ((Pair.Left = Left) and (Pair.Right < Right)) then
      Low := Middle + 1
    else
      High := Middle - 1;
  end;
  Result := 0;
end;

end.
