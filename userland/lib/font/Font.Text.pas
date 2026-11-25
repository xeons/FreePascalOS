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
  Text: picking a font face for a size, measuring text and drawing it.

  Sizes are in points (a point is 1/72 inch), in tenths, so a size means
  the same on any display: at Dpi dots per inch a size of P points is
  P * Dpi / 72 pixels. A font set holds the faces of one family in the
  pixel sizes it comes in, regular and bold; SelectFace takes the
  largest that is not larger than the size asks for (the smallest if
  all are), so text never grows past the space laid out for it.

  A set may know its faces before their glyphs are read (Font.Files
  lists a family's files): the set's Loader reads a face the first time
  it is picked, and a face that cannot be read is passed over.

  A face of any size (an outline font, Font.OutlineFaces) gives every
  size exactly: a bitmap face of the very size wanted is taken before
  it, anything else is made from the outline font at that size. Faces
  made so are kept in the set (Instances, each allocated on its own and
  never moved or freed), so a face picked stays valid however many more
  sizes are picked after it.

  Text is UTF-8. Characters below U+0020 take no room and draw nothing,
  nor do the invisible joiners and variation selectors (U+200B to
  U+200F, U+FE00 to U+FE0F, U+E0100 to U+E01EF) when the face lacks
  them. A character the face lacks is measured and drawn with a
  fallback face if the program has a FallbackFaceFinder (Font.Files
  gives one: the families /etc/fonts.conf lists for the character,
  Font.Configuration), at the face's size and weight, on the same
  baseline; no kerning joins it to its neighbours. Colour glyphs
  (emoji) are drawn in their own colours (Font.GlyphDrawing).
  Every character moves the pen by its glyph's advance, and by the
  face's kerning between it and the character before. Bitmap glyphs
  are drawn in the text colour; coverage glyphs (and outline glyphs,
  rendered through the glyph cache) blend it over what is there by how
  much of each pixel they cover, gamma-correct
  (Drawing.CoverageBlending).

  MeasureText and DrawText keep the pen on whole pixels, with advances
  and kerning rounded, which is what layout measures with. The precise
  pair (MeasureTextPrecisely, DrawTextPrecisely) moves an outline
  face's pen by its exact advances and puts each glyph at the nearest
  quarter pixel (subpixel positioning: even spacing in long runs of
  text at small sizes); for other faces they are the same as the plain
  ones.
}
unit Font.Text;

{$mode objfpc}
{$H+}

interface

uses
  Drawing.Colors,
  Drawing.Canvas,
  Font.Faces;

const
  PointsPerInch = 72;

type
  { Reads the glyphs of a face known only by its Source; False if it
    cannot. }
  TFaceLoader = function(var Face: TFontFace): Boolean;
  { A face that has CodePoint, for text in Face (its size and weight);
    nil if there is none. The face stays valid as long as the program
    runs. }
  TFallbackFaceFinder = function(const Face: TFontFace; CodePoint: LongWord): PFontFace;

  TFontSet = record
    { Faces[0 .. Count - 1]. }
    Faces: array of TFontFace;
    Count: LongInt;
    Loader: TFaceLoader;
    { Faces made from faces of any size, Instances[0 .. InstanceCount - 1]. }
    Instances: array of PFontFace;
    InstanceCount: LongInt;
  end;

var
  FallbackFaceFinder: TFallbackFaceFinder = nil;

{ The face CodePoint is drawn with in text of Face when Face lacks it
  (nil when Face has it, or no other face does). }
function FallbackFaceFor(const Face: TFontFace; CodePoint: LongWord): PFontFace;

{ An empty set (with no loader). }
procedure ClearFontSet(out FontSet: TFontSet);
{ Adds Face (its glyphs move into the set). Always True: a set has no
  limit. Faces picked before stay where they were only while no face is
  added, so a set is filled before faces are picked from it. }
function AddFace(var FontSet: TFontSet; const Face: TFontFace): Boolean;
{ The pixel size PointTenths tenths of a point is at Dpi, rounded. }
function PixelHeightFor(PointTenths, Dpi: LongWord): LongInt;
{ The face for a size (see above), its glyphs read; nil if the set has
  none of that weight (then the other weight is tried) or none at all. }
function SelectFace(var FontSet: TFontSet; PointTenths, Dpi: LongWord; Bold: Boolean): PFontFace;
{ The pixel size of the face SelectFace would pick, without reading any
  glyphs (0 if none): to list the sizes there are. }
function SelectedFaceSize(const FontSet: TFontSet; PointTenths, Dpi: LongWord; Bold: Boolean): LongInt;

{ Whether a face of the set gives every size (an outline font). }
function FontSetIsScalable(const FontSet: TFontSet): Boolean;

{ How far the pen moves for CodePoint alone (0 for a control character). }
function CharacterAdvance(const Face: TFontFace; CodePoint: LongWord): LongInt;
function MeasureText(const Face: TFontFace; const Text: string): LongInt;
{ Draws Text with the top left of its line at (X, Y), in Color. Returns
  the width. }
function DrawText(const Canvas: TCanvas; const Face: TFontFace; X, Y: LongInt; const Text: string;
  Color: TColor): LongInt;
{ One character with the pen at X and its line's top at Y; returns its
  advance (0 for a control character). }
function DrawCharacter(const Canvas: TCanvas; const Face: TFontFace; X, Y: LongInt; CodePoint: LongWord;
  Color: TColor): LongInt;
{ Text measured and drawn with exact advances and subpixel positions
  (see above); the width is rounded to whole pixels. }
function MeasureTextPrecisely(const Face: TFontFace; const Text: string): LongInt;
function DrawTextPrecisely(const Canvas: TCanvas; const Face: TFontFace; X, Y: LongInt; const Text: string;
  Color: TColor): LongInt;

implementation

uses
  Math,
  Drawing.CoverageBlending,
  Font.Outlines,
  Font.OutlineFaces,
  Font.GlyphCache,
  Font.GlyphDrawing,
  Font.Utf8;

const
  { Pixel sizes an outline face is made in. }
  SmallestOutlineSize = 1;
  LargestOutlineSize = 1024;

const
  FirstPrintable = $20;

procedure ClearFontSet(out FontSet: TFontSet);
begin
  FontSet.Faces := nil;
  FontSet.Count := 0;
  FontSet.Loader := nil;
  FontSet.Instances := nil;
  FontSet.InstanceCount := 0;
end;

function AddFace(var FontSet: TFontSet; const Face: TFontFace): Boolean;
begin
  if FontSet.Count = Length(FontSet.Faces) then
    SetLength(FontSet.Faces, 2 * FontSet.Count + 16);
  FontSet.Faces[FontSet.Count] := Face;
  Inc(FontSet.Count);
  Result := True;
end;

function PixelHeightFor(PointTenths, Dpi: LongWord): LongInt;
begin
  Result := LongInt((QWord(PointTenths) * Dpi + 10 * PointsPerInch div 2) div (10 * PointsPerInch));
end;

function FontSetIsScalable(const FontSet: TFontSet): Boolean;
var
  Index: LongInt;
begin
  Result := False;
  for Index := 0 to FontSet.Count - 1 do
    if FontSet.Faces[Index].AnySize and not FontSet.Faces[Index].Unusable then
      Exit(True);
end;

{ The pixel size an outline face is made in for Wanted. }
function OutlineSizeFor(Wanted: LongInt): LongInt;
begin
  Result := Wanted;
  if Result < SmallestOutlineSize then
    Result := SmallestOutlineSize;
  if Result > LargestOutlineSize then
    Result := LargestOutlineSize;
end;

{ The index of the face to pick among the usable ones of a weight; -1
  if there is none. A bitmap face of exactly the size wanted, else one
  of any size, else the largest not larger (or the smallest). }
function SelectFaceIndex(const FontSet: TFontSet; Wanted: LongInt; Bold: Boolean): LongInt;
var
  Index: LongInt;
  Smallest: LongInt;
  Size: LongInt;
  Scalable: LongInt;
begin
  Result := -1;
  Smallest := -1;
  Scalable := -1;
  for Index := 0 to FontSet.Count - 1 do
  begin
    if (FontSet.Faces[Index].Bold <> Bold) or FontSet.Faces[Index].Unusable then
      Continue;
    if FontSet.Faces[Index].AnySize then
    begin
      if Scalable < 0 then
        Scalable := Index;
      Continue;
    end;
    Size := FontSet.Faces[Index].Size;
    if Size = Wanted then
      Exit(Index);
    if (Size <= Wanted) and ((Result < 0) or (Size > FontSet.Faces[Result].Size)) then
      Result := Index;
    if (Smallest < 0) or (Size < FontSet.Faces[Smallest].Size) then
      Smallest := Index;
  end;
  if Scalable >= 0 then
    Result := Scalable
  else if Result < 0 then
    Result := Smallest;
end;

{ The face made from FontSet.Faces[Source] (of any size) at Size,
  made now if it was not. }
function InstanceOf(var FontSet: TFontSet; Source, Size: LongInt): PFontFace;
var
  Index: LongInt;
  Face: PFontFace;
begin
  for Index := 0 to FontSet.InstanceCount - 1 do
  begin
    Face := FontSet.Instances[Index];
    if (Face^.Outlines = FontSet.Faces[Source].Outlines) and (Face^.Size = Size) and
       (Face^.Bold = FontSet.Faces[Source].Bold) then
      Exit(Face);
  end;
  New(Result);
  MakeOutlineFace(FontSet.Faces[Source], Size, Result^);
  if FontSet.InstanceCount = Length(FontSet.Instances) then
    SetLength(FontSet.Instances, 2 * FontSet.InstanceCount + 8);
  FontSet.Instances[FontSet.InstanceCount] := Result;
  Inc(FontSet.InstanceCount);
end;

{ The face to pick of a weight, read if it was not; faces that cannot be
  read are marked and passed over. }
function SelectFaceOfWeight(var FontSet: TFontSet; Wanted: LongInt; Bold: Boolean): PFontFace;
var
  Index: LongInt;
begin
  repeat
    Index := SelectFaceIndex(FontSet, Wanted, Bold);
    if Index < 0 then
      Exit(nil);
    Result := @FontSet.Faces[Index];
    if not Result^.Loaded and not ((FontSet.Loader <> nil) and FontSet.Loader(Result^) and Result^.Loaded) then
    begin
      Result^.Unusable := True;
      Continue;
    end;
    if Result^.AnySize then
    begin
      if Result^.Outlines = nil then
      begin
        Result^.Unusable := True;
        Continue;
      end;
      Result := InstanceOf(FontSet, Index, OutlineSizeFor(Wanted));
    end;
    Exit;
  until False;
end;

function SelectFace(var FontSet: TFontSet; PointTenths, Dpi: LongWord; Bold: Boolean): PFontFace;
var
  Wanted: LongInt;
begin
  Wanted := PixelHeightFor(PointTenths, Dpi);
  Result := SelectFaceOfWeight(FontSet, Wanted, Bold);
  if Result = nil then
    Result := SelectFaceOfWeight(FontSet, Wanted, not Bold);
end;

function SelectedFaceSize(const FontSet: TFontSet; PointTenths, Dpi: LongWord; Bold: Boolean): LongInt;
var
  Wanted: LongInt;
  Index: LongInt;
begin
  Wanted := PixelHeightFor(PointTenths, Dpi);
  Index := SelectFaceIndex(FontSet, Wanted, Bold);
  if Index < 0 then
    Index := SelectFaceIndex(FontSet, Wanted, not Bold);
  if Index < 0 then
    Result := 0
  else if FontSet.Faces[Index].AnySize then
    Result := OutlineSizeFor(Wanted)
  else
    Result := FontSet.Faces[Index].Size;
end;

{ Characters that take no room when the face has no glyph for them:
  zero width spaces and joiners, direction marks, variation selectors. }
function IsInvisibleCharacter(CodePoint: LongWord): Boolean;
begin
  Result := ((CodePoint >= $200B) and (CodePoint <= $200F)) or ((CodePoint >= $FE00) and (CodePoint <= $FE0F)) or
    ((CodePoint >= $E0100) and (CodePoint <= $E01EF)) or (CodePoint = $FEFF) or (CodePoint = $2060);
end;

function FallbackFaceFor(const Face: TFontFace; CodePoint: LongWord): PFontFace;
begin
  Result := nil;
  if (CodePoint < FirstPrintable) or (FallbackFaceFinder = nil) or HasGlyphFor(Face, CodePoint) or
     IsInvisibleCharacter(CodePoint) then
    Exit;
  Result := FallbackFaceFinder(Face, CodePoint);
  if (Result <> nil) and not HasGlyphFor(Result^, CodePoint) then
    Result := nil;
end;

{ Whether a character takes no room and draws nothing in Face. }
function TakesNoRoom(const Face: TFontFace; CodePoint: LongWord): Boolean;
begin
  Result := (CodePoint < FirstPrintable) or (Face.GlyphCount = 0) or
    (IsInvisibleCharacter(CodePoint) and not HasGlyphFor(Face, CodePoint));
end;

function CharacterAdvance(const Face: TFontFace; CodePoint: LongWord): LongInt;
var
  Fallback: PFontFace;
begin
  if TakesNoRoom(Face, CodePoint) then
    Exit(0);
  Fallback := FallbackFaceFor(Face, CodePoint);
  if Fallback <> nil then
    Result := CharacterAdvance(Fallback^, CodePoint)
  else if Face.Format = GlyphOutline then
    Result := OutlineAdvance(Face, GlyphFor(Face, CodePoint))
  else
    Result := Face.Glyphs[GlyphFor(Face, CodePoint)].Advance;
end;

{ The kerning between two characters one after the other (none after a
  control character or at the start, where Previous is 0). }
function KerningStep(const Face: TFontFace; Previous, CodePoint: LongWord): LongInt;
begin
  Result := 0;
  if (Previous >= FirstPrintable) and (CodePoint >= FirstPrintable) and FaceHasKerning(Face) and
     HasGlyphFor(Face, Previous) and HasGlyphFor(Face, CodePoint) then
    Result := KerningBetween(Face, Previous, CodePoint);
end;

function MeasureText(const Face: TFontFace; const Text: string): LongInt;
var
  Cursor: PChar;
  CodePoint: LongWord;
  Previous: LongWord;
begin
  Result := 0;
  Cursor := PChar(Text);
  Previous := 0;
  while NextCharacter(Cursor, CodePoint) do
  begin
    Result := Result + KerningStep(Face, Previous, CodePoint) + CharacterAdvance(Face, CodePoint);
    Previous := CodePoint;
  end;
end;

{ A bitmap glyph's row: each run of set pixels is one span. }
procedure DrawBitsRow(const Canvas: TCanvas; Bits: PByte; Width, SurfaceX, SurfaceY: LongInt; Color: TColor);
var
  Column: LongInt;
  RunStart: LongInt;

  function PixelIsSet(Index: LongInt): Boolean;
  begin
    Result := (Bits[Index div 8] and ($80 shr (Index mod 8))) <> 0;
  end;

begin
  Column := 0;
  while Column < Width do
  begin
    if not PixelIsSet(Column) then
    begin
      Inc(Column);
      Continue;
    end;
    RunStart := Column;
    while (Column < Width) and PixelIsSet(Column) do
      Inc(Column);
    FillSpan(Canvas, SurfaceY, SurfaceX + RunStart, SurfaceX + Column, Color);
  end;
end;

{ An outline glyph from the glyph cache, its pen at (PenX, BaselineY)
  on the baseline (surface coordinates), Subpixel quarters further
  right. }
procedure DrawOutlineGlyph(const Canvas: TCanvas; const Face: TFontFace; Glyph: LongWord; PenX, BaselineY,
  Subpixel: LongInt; Color: TColor);
var
  Bitmap: PGlyphBitmap;
begin
  Bitmap := CachedGlyph(Face.Outlines, Face.Size, Glyph, Subpixel, Face.Hinted);
  if (Bitmap = nil) or (Bitmap^.Width = 0) then
    Exit;
  DrawGlyphBitmap(Canvas, Bitmap^, PenX, BaselineY, Color);
end;

function DrawCharacter(const Canvas: TCanvas; const Face: TFontFace; X, Y: LongInt; CodePoint: LongWord;
  Color: TColor): LongInt;
var
  Glyph: LongWord;
  Row: LongInt;
  Left: LongInt;
  Top: LongInt;
  Fallback: PFontFace;
begin
  if TakesNoRoom(Face, CodePoint) then
    Exit(0);
  Fallback := FallbackFaceFor(Face, CodePoint);
  if Fallback <> nil then
    Exit(DrawCharacter(Canvas, Fallback^, X, Y + Face.Ascent - Fallback^.Ascent, CodePoint, Color));
  Result := CharacterAdvance(Face, CodePoint);
  Glyph := GlyphFor(Face, CodePoint);
  if Face.Format = GlyphOutline then
  begin
    DrawOutlineGlyph(Canvas, Face, Glyph, X + Canvas.OriginX, Y + Face.Ascent + Canvas.OriginY, 0, Color);
    Exit;
  end;
  Left := X + Face.Glyphs[Glyph].LeftBearing + Canvas.OriginX;
  Top := Y + Face.Glyphs[Glyph].Top + Canvas.OriginY;
  for Row := 0 to Face.Glyphs[Glyph].Height - 1 do
    if Face.Format = GlyphBits then
      DrawBitsRow(Canvas, GlyphRow(Face, Glyph, Row), Face.Glyphs[Glyph].Width, Left, Top + Row, Color)
    else
      BlendCoverageSpan(Canvas, Top + Row, Left, GlyphRow(Face, Glyph, Row), Face.Glyphs[Glyph].Width, Color);
end;

function DrawText(const Canvas: TCanvas; const Face: TFontFace; X, Y: LongInt; const Text: string;
  Color: TColor): LongInt;
var
  Cursor: PChar;
  CodePoint: LongWord;
  Previous: LongWord;
begin
  Result := 0;
  Cursor := PChar(Text);
  Previous := 0;
  while NextCharacter(Cursor, CodePoint) do
  begin
    Result := Result + KerningStep(Face, Previous, CodePoint);
    Result := Result + DrawCharacter(Canvas, Face, X + Result, Y, CodePoint, Color);
    Previous := CodePoint;
  end;
end;

{ Where the pen ends after Text, exactly (pixels from the start),
  drawing each glyph at the nearest quarter pixel on the way if Draw. }
function PrecisePen(const Face: TFontFace; const Text: string; Draw: Boolean; const Canvas: TCanvas;
  X, Y: LongInt; Color: TColor): Double;
var
  Cursor: PChar;
  CodePoint: LongWord;
  Previous: LongWord;
  Glyph: LongWord;
  PreviousGlyph: LongWord;
  Quarters: LongInt;
  WholePixels: LongInt;
  Fallback: PFontFace;
begin
  Result := 0;
  Cursor := PChar(Text);
  Previous := 0;
  PreviousGlyph := 0;
  while NextCharacter(Cursor, CodePoint) do
  begin
    if TakesNoRoom(Face, CodePoint) then
    begin
      Previous := 0;
      Continue;
    end;
    Fallback := FallbackFaceFor(Face, CodePoint);
    if Fallback <> nil then
    begin
      { Another face's glyph, at the nearest whole pixel, with no
        kerning on either side. }
      if Draw then
        Result := Result + DrawCharacter(Canvas, Fallback^, X + RoundHalfUp(Result), Y + Face.Ascent - Fallback^.Ascent,
          CodePoint, Color)
      else
        Result := Result + CharacterAdvance(Fallback^, CodePoint);
      Previous := 0;
      Continue;
    end;
    Glyph := GlyphFor(Face, CodePoint);
    if Previous >= FirstPrintable then
      Result := Result + PreciseOutlineKerning(Face, PreviousGlyph, Glyph);
    if Draw then
    begin
      Quarters := Floor(Result * SubpixelSteps + 0.5);
      WholePixels := Floor(Quarters / SubpixelSteps);
      DrawOutlineGlyph(Canvas, Face, Glyph, X + Canvas.OriginX + WholePixels, Y + Face.Ascent + Canvas.OriginY,
        Quarters - SubpixelSteps * WholePixels, Color);
    end;
    Result := Result + PreciseOutlineAdvance(Face, Glyph);
    Previous := CodePoint;
    PreviousGlyph := Glyph;
  end;
end;

function MeasureTextPrecisely(const Face: TFontFace; const Text: string): LongInt;
var
  Unused: TCanvas;
begin
  if Face.Format <> GlyphOutline then
    Exit(MeasureText(Face, Text));
  FillChar(Unused, SizeOf(Unused), 0);
  Result := RoundHalfUp(PrecisePen(Face, Text, False, Unused, 0, 0, 0));
end;

function DrawTextPrecisely(const Canvas: TCanvas; const Face: TFontFace; X, Y: LongInt; const Text: string;
  Color: TColor): LongInt;
begin
  if Face.Format <> GlyphOutline then
    Exit(DrawText(Canvas, Face, X, Y, Text, Color));
  Result := RoundHalfUp(PrecisePen(Face, Text, True, Canvas, X, Y, Color));
end;

end.
