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
  P * Dpi / 72 pixels high. A font set holds the faces of one family in
  the pixel heights it comes in, regular and bold; SelectFace takes the
  tallest that is not taller than the size asks for (the smallest if
  all are), so text never grows past the space laid out for it.

  Text is UTF-8. Characters below U+0020 take no room and draw nothing.
  Every face here is a bitmap face of one width, so a text's width is
  its character count times the face's width; MeasureText is still the
  way to ask, for when faces are not.

  PSF faces carry no baseline, so FaceBaseline finds it in the face's
  own letters: the row under the feet of an H.
}
unit Font.Text;

{$mode objfpc}

interface

uses
  Drawing.Colors,
  Drawing.Canvas,
  Font.Psf;

const
  PointsPerInch = 72;
  MaximumFaces = 32;

type
  TFontSet = record
    Faces: array[0..MaximumFaces - 1] of TFontFace;
    Count: LongInt;
  end;

{ Adds Face (its glyphs move into the set). False if the set is full. }
function AddFace(var FontSet: TFontSet; const Face: TFontFace): Boolean;
{ The pixel height PointTenths tenths of a point is at Dpi, rounded. }
function PixelHeightFor(PointTenths, Dpi: LongWord): LongInt;
{ The face for a size (see above); nil if the set has none of that
  weight (then the other weight is tried) or none at all. }
function SelectFace(const FontSet: TFontSet; PointTenths, Dpi: LongWord; Bold: Boolean): PFontFace;

function MeasureText(const Face: TFontFace; Text: PChar): LongInt;
{ Draws Text with its top left at (X, Y), in Color. Returns the width. }
function DrawText(const Canvas: TCanvas; const Face: TFontFace; X, Y: LongInt; Text: PChar; Color: TColor): LongInt;
{ One character; returns its width (0 for a control character). }
function DrawCharacter(const Canvas: TCanvas; const Face: TFontFace; X, Y: LongInt; CodePoint: LongWord;
  Color: TColor): LongInt;
{ The first row (from the top of a line) below the letters that stand on
  the baseline: where an underline goes so it touches them. }
function FaceBaseline(const Face: TFontFace): LongInt;

implementation

uses
  Font.Utf8;

const
  FirstPrintable = $20;

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

function SelectFaceOfWeight(const FontSet: TFontSet; Wanted: LongInt; Bold: Boolean): PFontFace;
var
  Index: LongInt;
  Best: LongInt;
  Smallest: LongInt;
  Height: LongInt;
begin
  Best := -1;
  Smallest := -1;
  for Index := 0 to FontSet.Count - 1 do
  begin
    if FontSet.Faces[Index].Bold <> Bold then
      Continue;
    Height := FontSet.Faces[Index].Height;
    if (Height <= Wanted) and ((Best < 0) or (Height > FontSet.Faces[Best].Height)) then
      Best := Index;
    if (Smallest < 0) or (Height < FontSet.Faces[Smallest].Height) then
      Smallest := Index;
  end;
  if Best < 0 then
    Best := Smallest;
  if Best < 0 then
    Exit(nil);
  Result := @FontSet.Faces[Best];
end;

function SelectFace(const FontSet: TFontSet; PointTenths, Dpi: LongWord; Bold: Boolean): PFontFace;
var
  Wanted: LongInt;
begin
  Wanted := PixelHeightFor(PointTenths, Dpi);
  Result := SelectFaceOfWeight(FontSet, Wanted, Bold);
  if Result = nil then
    Result := SelectFaceOfWeight(FontSet, Wanted, not Bold);
end;

function CharacterWidth(const Face: TFontFace; CodePoint: LongWord): LongInt;
begin
  if CodePoint < FirstPrintable then
    Result := 0
  else
    Result := Face.Width;
end;

function MeasureText(const Face: TFontFace; Text: PChar): LongInt;
var
  CodePoint: LongWord;
begin
  Result := 0;
  if Text = nil then
    Exit;
  while NextCharacter(Text, CodePoint) do
    Result := Result + CharacterWidth(Face, CodePoint);
end;

function DrawCharacter(const Canvas: TCanvas; const Face: TFontFace; X, Y: LongInt; CodePoint: LongWord;
  Color: TColor): LongInt;
var
  Glyph: LongWord;
  Row: LongInt;
  Bits: PByte;
  Column: LongInt;
  RunStart: LongInt;
  SurfaceX: LongInt;
  SurfaceY: LongInt;

  function PixelIsSet(Index: LongInt): Boolean;
  begin
    Result := (Bits[Index div 8] and ($80 shr (Index mod 8))) <> 0;
  end;

begin
  Result := CharacterWidth(Face, CodePoint);
  if Result = 0 then
    Exit;
  Glyph := GlyphFor(Face, CodePoint);
  SurfaceX := X + Canvas.OriginX;
  SurfaceY := Y + Canvas.OriginY;
  for Row := 0 to Face.Height - 1 do
  begin
    Bits := GlyphRow(Face, Glyph, Row);
    { Each run of set pixels is one span. }
    Column := 0;
    while Column < Face.Width do
    begin
      if not PixelIsSet(Column) then
      begin
        Inc(Column);
        Continue;
      end;
      RunStart := Column;
      while (Column < Face.Width) and PixelIsSet(Column) do
        Inc(Column);
      FillSpan(Canvas, SurfaceY + Row, SurfaceX + RunStart, SurfaceX + Column, Color);
    end;
  end;
end;

function FaceBaseline(const Face: TFontFace): LongInt;
const
  { A capital that has no part below the baseline. }
  BaselineLetter = Ord('H');
var
  Glyph: LongWord;
  Row: LongInt;
  Bits: PByte;
  ByteIndex: LongInt;
begin
  { Without the letter: where it usually is, three sixteenths up. }
  Result := Face.Height - (3 * Face.Height) div 16;
  if not HasGlyphFor(Face, BaselineLetter) then
    Exit;
  Glyph := GlyphFor(Face, BaselineLetter);
  for Row := Face.Height - 1 downto 0 do
  begin
    Bits := GlyphRow(Face, Glyph, Row);
    for ByteIndex := 0 to Face.BytesPerRow - 1 do
      if Bits[ByteIndex] <> 0 then
        Exit(Row + 1);
  end;
end;

function DrawText(const Canvas: TCanvas; const Face: TFontFace; X, Y: LongInt; Text: PChar; Color: TColor): LongInt;
var
  CodePoint: LongWord;
begin
  Result := 0;
  if Text = nil then
    Exit;
  while NextCharacter(Text, CodePoint) do
    Result := Result + DrawCharacter(Canvas, Face, X + Result, Y, CodePoint, Color);
end;

end.
