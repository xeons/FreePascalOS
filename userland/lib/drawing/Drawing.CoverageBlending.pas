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
  Blending a colour by coverage, gamma-correct: what anti-aliased text
  is drawn with.

  A pixel half covered by a glyph should give off half the light of
  one fully covered, but pixel values are not proportional to light:
  mixing them halfway gives a pixel too dark for light text on a dark
  ground and too light for dark text on a light one, so text changes
  weight with its colours. Here both colours are turned into light
  (value / 255 to the power of the gamma), mixed by the coverage, and
  turned back. The gamma is 1.8, not the display's 2.2: the value
  FreeType's documentation suggests for text without stem darkening,
  which keeps dark text on a light ground from looking thin.

  Coverage 0 leaves a pixel as it is and 255 (with an opaque colour)
  replaces it, exactly. A colour's own alpha is not coverage: the
  colour is first put over the pixel the usual way (as browsers blend
  translucent colours, in pixel values), and that is mixed by the
  coverage, so fully covered pixels of translucent text get the value
  other browsers give them. Masks that are not anti-aliasing (a box
  shadow's blur) are blended without the gamma (BlendMaskSpan). Where
  the surface is not opaque (a pixel with alpha below 255) light cannot
  be mixed by itself, so the colour is blended over it the usual way
  (Drawing.Colors' BlendColors, faded by the coverage).
}
unit Drawing.CoverageBlending;

{$mode objfpc}
{$pointermath on}

interface

uses
  Drawing.Colors,
  Drawing.Canvas;

const
  TextGamma = 1.8;

{ Color put on Destination over Coverage (0 to 255) of the pixel. }
function BlendCoverage(Destination, Color: TColor; Coverage: Byte): TColor;
{ Count pixels from (Left, Y) (surface coordinates, no origin), each
  blended by its own coverage, Coverage[0] the leftmost; clipped. }
procedure BlendMaskSpan(const Canvas: TCanvas; Y, Left: LongInt; Mask: PByte; Count: LongInt; Color: TColor);
{ The same, gamma-correct (anti-aliased text). }
procedure BlendCoverageSpan(const Canvas: TCanvas; Y, Left: LongInt; Coverage: PByte; Count: LongInt;
  Color: TColor);

implementation

uses
  Math,
  Drawing.Rectangles,
  Drawing.Surfaces;

const
  LinearMaximum = 65535;

var
  TablesMade: Boolean = False;
  { A pixel value's light, 0 to LinearMaximum. }
  ToLinear: array[0..255] of LongWord;
  { The pixel value nearest a light (rounded in pixel values). }
  FromLinear: array[0..LinearMaximum] of Byte;

procedure MakeTables;
var
  Value: LongInt;
  Light: LongInt;
  Boundary: LongInt;
begin
  for Value := 0 to 255 do
    ToLinear[Value] := LongWord(Round(LinearMaximum * Power(Value / 255, TextGamma)));
  { Light below the boundary between two values goes to the lower one:
    the boundary is the light of the halfway value. }
  Light := 0;
  for Value := 0 to 254 do
  begin
    Boundary := Ceil(LinearMaximum * Power((Value + 0.5) / 255, TextGamma));
    while (Light < Boundary) and (Light <= LinearMaximum) do
    begin
      FromLinear[Light] := Value;
      Inc(Light);
    end;
  end;
  while Light <= LinearMaximum do
  begin
    FromLinear[Light] := 255;
    Inc(Light);
  end;
  TablesMade := True;
end;

{ One channel: the light of both mixed by Weight / 255, back as a value. }
function MixChannel(DestinationValue, ColorValue, Weight: LongWord): LongWord; inline;
begin
  Result := FromLinear[(ToLinear[DestinationValue] * (255 - Weight) + ToLinear[ColorValue] * Weight + 127) div 255];
end;

function BlendCoverage(Destination, Color: TColor; Coverage: Byte): TColor;
var
  Weight: LongWord;
begin
  if (Coverage = 0) or (AlphaOf(Color) = 0) then
    Exit(Destination);
  if AlphaOf(Destination) <> AlphaOpaque then
    Exit(BlendColors(Destination, FadeColor(Color, Coverage)));
  { A translucent colour over the pixel, then mixed by the coverage. }
  if AlphaOf(Color) <> AlphaOpaque then
    Color := BlendColors(Destination, Color);
  Weight := Coverage;
  if Weight = 255 then
    Exit(Color);
  if not TablesMade then
    MakeTables;
  Result := ArgbColor(AlphaOpaque, MixChannel(RedOf(Destination), RedOf(Color), Weight),
    MixChannel(GreenOf(Destination), GreenOf(Color), Weight), MixChannel(BlueOf(Destination), BlueOf(Color), Weight));
end;

procedure BlendMaskSpan(const Canvas: TCanvas; Y, Left: LongInt; Mask: PByte; Count: LongInt; Color: TColor);
var
  Index, Start, Finish, X: LongInt;
  Piece: TRectangle;
  Line: PLongWord;
begin
  if (Count <= 0) or (AlphaOf(Color) = 0) then
    Exit;
  Line := SurfaceLine(Canvas.Surface, Y);
  for Index := 0 to Canvas.Clip.Count - 1 do
  begin
    Piece := Canvas.Clip.Rectangles[Index];
    if (Y < Piece.Top) or (Y >= Piece.Bottom) then
      Continue;
    Start := Max(Left, Piece.Left);
    Finish := Min(Left + Count, Piece.Right);
    for X := Start to Finish - 1 do
      if Mask[X - Left] <> 0 then
        Line[X] := BlendColors(Line[X], FadeColor(Color, Mask[X - Left]));
  end;
end;

procedure BlendCoverageSpan(const Canvas: TCanvas; Y, Left: LongInt; Coverage: PByte; Count: LongInt;
  Color: TColor);
var
  Index: LongInt;
  Piece: TRectangle;
  Start: LongInt;
  Finish: LongInt;
  Line: PLongWord;
  X: LongInt;
begin
  if (Count <= 0) or (AlphaOf(Color) = 0) then
    Exit;
  Line := SurfaceLine(Canvas.Surface, Y);
  for Index := 0 to Canvas.Clip.Count - 1 do
  begin
    Piece := Canvas.Clip.Rectangles[Index];
    if (Y < Piece.Top) or (Y >= Piece.Bottom) then
      Continue;
    Start := Left;
    if Start < Piece.Left then
      Start := Piece.Left;
    Finish := Left + Count;
    if Finish > Piece.Right then
      Finish := Piece.Right;
    for X := Start to Finish - 1 do
      if Coverage[X - Left] <> 0 then
        Line[X] := BlendCoverage(Line[X], Color, Coverage[X - Left]);
  end;
end;

end.
