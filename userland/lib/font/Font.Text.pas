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

  Text is UTF-8. Characters below U+0020 take no room and draw nothing.
  Every character moves the pen by its glyph's advance, and by the
  face's kerning between it and the character before. Bitmap glyphs
  are drawn in the text colour; coverage glyphs blend it over what is
  there by how much of each pixel they cover.
}
unit Font.Text;

{$mode objfpc}

interface

uses
  Drawing.Colors,
  Drawing.Canvas,
  Font.Faces;

const
  PointsPerInch = 72;
  MaximumFaces = 128;

type
  { Reads the glyphs of a face known only by its Source; False if it
    cannot. }
  TFaceLoader = function(var Face: TFontFace): Boolean;

  TFontSet = record
    Faces: array[0..MaximumFaces - 1] of TFontFace;
    Count: LongInt;
    Loader: TFaceLoader;
  end;

{ An empty set (with no loader). }
procedure ClearFontSet(out FontSet: TFontSet);
{ Adds Face (its glyphs move into the set). False if the set is full. }
function AddFace(var FontSet: TFontSet; const Face: TFontFace): Boolean;
{ The pixel size PointTenths tenths of a point is at Dpi, rounded. }
function PixelHeightFor(PointTenths, Dpi: LongWord): LongInt;
{ The face for a size (see above), its glyphs read; nil if the set has
  none of that weight (then the other weight is tried) or none at all. }
function SelectFace(var FontSet: TFontSet; PointTenths, Dpi: LongWord; Bold: Boolean): PFontFace;
{ The pixel size of the face SelectFace would pick, without reading any
  glyphs (0 if none): to list the sizes there are. }
function SelectedFaceSize(const FontSet: TFontSet; PointTenths, Dpi: LongWord; Bold: Boolean): LongInt;

{ How far the pen moves for CodePoint alone (0 for a control character). }
function CharacterAdvance(const Face: TFontFace; CodePoint: LongWord): LongInt;
function MeasureText(const Face: TFontFace; Text: PChar): LongInt;
{ Draws Text with the top left of its line at (X, Y), in Color. Returns
  the width. }
function DrawText(const Canvas: TCanvas; const Face: TFontFace; X, Y: LongInt; Text: PChar; Color: TColor): LongInt;
{ One character with the pen at X and its line's top at Y; returns its
  advance (0 for a control character). }
function DrawCharacter(const Canvas: TCanvas; const Face: TFontFace; X, Y: LongInt; CodePoint: LongWord;
  Color: TColor): LongInt;

implementation

uses
  Font.Utf8;

const
  FirstPrintable = $20;

procedure ClearFontSet(out FontSet: TFontSet);
var
  Index: LongInt;
begin
  for Index := 0 to MaximumFaces - 1 do
    ClearFace(FontSet.Faces[Index]);
  FontSet.Count := 0;
  FontSet.Loader := nil;
end;

function AddFace(var FontSet: TFontSet; const Face: TFontFace): Boolean;
begin
  if FontSet.Count = MaximumFaces then
    Exit(False);
  FontSet.Faces[FontSet.Count] := Face;
  Inc(FontSet.Count);
  Result := True;
end;

function PixelHeightFor(PointTenths, Dpi: LongWord): LongInt;
begin
  Result := LongInt((QWord(PointTenths) * Dpi + 10 * PointsPerInch div 2) div (10 * PointsPerInch));
end;

{ The index of the face to pick among the usable ones of a weight; -1
  if there is none. }
function SelectFaceIndex(const FontSet: TFontSet; Wanted: LongInt; Bold: Boolean): LongInt;
var
  Index: LongInt;
  Smallest: LongInt;
  Size: LongInt;
begin
  Result := -1;
  Smallest := -1;
  for Index := 0 to FontSet.Count - 1 do
  begin
    if (FontSet.Faces[Index].Bold <> Bold) or FontSet.Faces[Index].Unusable then
      Continue;
    Size := FontSet.Faces[Index].Size;
    if (Size <= Wanted) and ((Result < 0) or (Size > FontSet.Faces[Result].Size)) then
      Result := Index;
    if (Smallest < 0) or (Size < FontSet.Faces[Smallest].Size) then
      Smallest := Index;
  end;
  if Result < 0 then
    Result := Smallest;
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
    if Result^.Loaded then
      Exit;
    if (FontSet.Loader <> nil) and FontSet.Loader(Result^) and Result^.Loaded then
      Exit;
    Result^.Unusable := True;
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
  else
    Result := FontSet.Faces[Index].Size;
end;

function CharacterAdvance(const Face: TFontFace; CodePoint: LongWord): LongInt;
begin
  if (CodePoint < FirstPrintable) or (Face.GlyphCount = 0) then
    Result := 0
  else
    Result := Face.Glyphs[GlyphFor(Face, CodePoint)].Advance;
end;

{ The kerning between two characters one after the other (none after a
  control character or at the start, where Previous is 0). }
function KerningStep(const Face: TFontFace; Previous, CodePoint: LongWord): LongInt;
begin
  Result := 0;
  if (Previous >= FirstPrintable) and (CodePoint >= FirstPrintable) and (Face.KerningCount > 0) then
    Result := KerningBetween(Face, Previous, CodePoint);
end;

function MeasureText(const Face: TFontFace; Text: PChar): LongInt;
var
  CodePoint: LongWord;
  Previous: LongWord;
begin
  Result := 0;
  if Text = nil then
    Exit;
  Previous := 0;
  while NextCharacter(Text, CodePoint) do
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

{ A coverage glyph's row: each run of pixels covered alike is one span
  of the colour faded by that coverage. }
procedure DrawCoverageRow(const Canvas: TCanvas; Coverage: PByte; Width, SurfaceX, SurfaceY: LongInt;
  Color: TColor);
var
  Column: LongInt;
  RunStart: LongInt;
  Value: Byte;
begin
  Column := 0;
  while Column < Width do
  begin
    Value := Coverage[Column];
    RunStart := Column;
    while (Column < Width) and (Coverage[Column] = Value) do
      Inc(Column);
    if Value <> 0 then
      FillSpan(Canvas, SurfaceY, SurfaceX + RunStart, SurfaceX + Column, FadeColor(Color, Value));
  end;
end;

function DrawCharacter(const Canvas: TCanvas; const Face: TFontFace; X, Y: LongInt; CodePoint: LongWord;
  Color: TColor): LongInt;
var
  Glyph: LongWord;
  Row: LongInt;
  Left: LongInt;
  Top: LongInt;
begin
  Result := CharacterAdvance(Face, CodePoint);
  if (CodePoint < FirstPrintable) or (Face.GlyphCount = 0) then
    Exit;
  Glyph := GlyphFor(Face, CodePoint);
  Left := X + Face.Glyphs[Glyph].LeftBearing + Canvas.OriginX;
  Top := Y + Face.Glyphs[Glyph].Top + Canvas.OriginY;
  for Row := 0 to Face.Glyphs[Glyph].Height - 1 do
    if Face.Format = GlyphBits then
      DrawBitsRow(Canvas, GlyphRow(Face, Glyph, Row), Face.Glyphs[Glyph].Width, Left, Top + Row, Color)
    else
      DrawCoverageRow(Canvas, GlyphRow(Face, Glyph, Row), Face.Glyphs[Glyph].Width, Left, Top + Row, Color);
end;

function DrawText(const Canvas: TCanvas; const Face: TFontFace; X, Y: LongInt; Text: PChar; Color: TColor): LongInt;
var
  CodePoint: LongWord;
  Previous: LongWord;
begin
  Result := 0;
  if Text = nil then
    Exit;
  Previous := 0;
  while NextCharacter(Text, CodePoint) do
  begin
    Result := Result + KerningStep(Face, Previous, CodePoint);
    Result := Result + DrawCharacter(Canvas, Face, X + Result, Y, CodePoint, Color);
    Previous := CodePoint;
  end;
end;

end.
