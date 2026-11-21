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
  Parts painted inside the navigation controls (tab strip, breadcrumb
  bar, command bar): small glyphs drawn as anti-aliased strokes as
  thick as the display's scale makes them (a cross, a plus, a chevron,
  three dots, a double chevron), and the flat look of a part under the
  pointer or held down, in the theme's colours: in a theme with header
  bands a filled face with a thin shadow outline, in the classic one
  the flat button's raised or sunken edge.
}
unit Controls.PartPainting;

{$mode objfpc}
{$H+}

interface

uses
  Drawing.Colors,
  Drawing.Rectangles,
  Drawing.Canvas,
  Controls.Painting;

type
  TPartLook = (PartNormal, PartHot, PartPressed);

{ The look of a flat part in Box (nothing for PartNormal). }
procedure DrawPartFace(const Canvas: TCanvas; const Box: TRectangle; Look: TPartLook);
{ A cross (a close button's) in the middle of Box, Size pixels across. }
procedure DrawCrossGlyph(const Canvas: TCanvas; const Box: TRectangle; Size: LongInt; Color: TColor);
procedure DrawPlusGlyph(const Canvas: TCanvas; const Box: TRectangle; Size: LongInt; Color: TColor);
{ An open arrowhead pointing Direction, Size pixels across. }
procedure DrawChevronGlyph(const Canvas: TCanvas; const Box: TRectangle; Direction: TArrowDirection; Size: LongInt;
  Color: TColor);
{ Two chevrons side by side pointing left (an overflow of what is to the
  left). }
procedure DrawDoubleChevronGlyph(const Canvas: TCanvas; const Box: TRectangle; Size: LongInt; Color: TColor);
{ Three dots in a row (more). }
procedure DrawDotsGlyph(const Canvas: TCanvas; const Box: TRectangle; Size: LongInt; Color: TColor);
{ How thick the glyphs' strokes are at the scale now (pixels). }
function GlyphStroke: Double;

implementation

uses
  Drawing.Rasterizer,
  Drawing.SmoothLines,
  Drawing.SmoothShapes,
  Windowing.Theme,
  Windowing.Connection;

function GlyphStroke: Double;
begin
  Result := Scaled(100) / 100 * 1.4;
  if Result < 1 then
    Result := 1;
end;

procedure DrawPartFace(const Canvas: TCanvas; const Box: TRectangle; Look: TPartLook);
var
  Face: TColor;
begin
  if Look = PartNormal then
    Exit;
  if Look = PartPressed then
    Face := Theme.PressedButtonFace
  else
    Face := Theme.HotButtonFace;
  FillRectangle(Canvas, Box, Face);
  if Theme.HeaderBandsShown then
    DrawThickOutline(Canvas, Box, BevelLine, Theme.Shadow)
  else if Look = PartPressed then
    DrawSunkenEdge(Canvas, Box)
  else
    DrawRaisedEdge(Canvas, Box);
end;

procedure MiddleOf(const Box: TRectangle; out X, Y: Double);
begin
  X := (Box.Left + Box.Right) / 2;
  Y := (Box.Top + Box.Bottom) / 2;
end;

procedure DrawCrossGlyph(const Canvas: TCanvas; const Box: TRectangle; Size: LongInt; Color: TColor);
var
  X: Double;
  Y: Double;
  Half: Double;
begin
  MiddleOf(Box, X, Y);
  Half := Size / 2;
  DrawSmoothLine(Canvas, X - Half, Y - Half, X + Half, Y + Half, GlyphStroke, Color);
  DrawSmoothLine(Canvas, X - Half, Y + Half, X + Half, Y - Half, GlyphStroke, Color);
end;

procedure DrawPlusGlyph(const Canvas: TCanvas; const Box: TRectangle; Size: LongInt; Color: TColor);
var
  X: Double;
  Y: Double;
  Half: Double;
begin
  MiddleOf(Box, X, Y);
  Half := Size / 2;
  DrawSmoothLine(Canvas, X - Half, Y, X + Half, Y, GlyphStroke, Color);
  DrawSmoothLine(Canvas, X, Y - Half, X, Y + Half, GlyphStroke, Color);
end;

procedure DrawChevronAt(const Canvas: TCanvas; X, Y: Double; Direction: TArrowDirection; Size: LongInt;
  Color: TColor);
var
  Half: Double;
  Quarter: Double;
  Points: array[0..2] of TPrecisePoint;
begin
  Half := Size / 2;
  Quarter := Size / 4;
  case Direction of
    ArrowRight:
      begin
        Points[0].X := X - Quarter; Points[0].Y := Y - Half;
        Points[1].X := X + Quarter; Points[1].Y := Y;
        Points[2].X := X - Quarter; Points[2].Y := Y + Half;
      end;
    ArrowLeft:
      begin
        Points[0].X := X + Quarter; Points[0].Y := Y - Half;
        Points[1].X := X - Quarter; Points[1].Y := Y;
        Points[2].X := X + Quarter; Points[2].Y := Y + Half;
      end;
    ArrowDown:
      begin
        Points[0].X := X - Half; Points[0].Y := Y - Quarter;
        Points[1].X := X; Points[1].Y := Y + Quarter;
        Points[2].X := X + Half; Points[2].Y := Y - Quarter;
      end;
  else
    begin
      Points[0].X := X - Half; Points[0].Y := Y + Quarter;
      Points[1].X := X; Points[1].Y := Y - Quarter;
      Points[2].X := X + Half; Points[2].Y := Y + Quarter;
    end;
  end;
  DrawSmoothPolyline(Canvas, Points, GlyphStroke, Color);
end;

procedure DrawChevronGlyph(const Canvas: TCanvas; const Box: TRectangle; Direction: TArrowDirection; Size: LongInt;
  Color: TColor);
var
  X: Double;
  Y: Double;
begin
  MiddleOf(Box, X, Y);
  DrawChevronAt(Canvas, X, Y, Direction, Size, Color);
end;

procedure DrawDoubleChevronGlyph(const Canvas: TCanvas; const Box: TRectangle; Size: LongInt; Color: TColor);
var
  X: Double;
  Y: Double;
begin
  MiddleOf(Box, X, Y);
  DrawChevronAt(Canvas, X - Size / 4, Y, ArrowLeft, Size, Color);
  DrawChevronAt(Canvas, X + Size / 4, Y, ArrowLeft, Size, Color);
end;

procedure DrawDotsGlyph(const Canvas: TCanvas; const Box: TRectangle; Size: LongInt; Color: TColor);
var
  X: Double;
  Y: Double;
  Dot: LongInt;
  Step: Double;
  Index: LongInt;
  Left: LongInt;
begin
  MiddleOf(Box, X, Y);
  Dot := Size div 4;
  if Dot < 2 then
    Dot := 2;
  Step := Size * 0.4;
  for Index := -1 to 1 do
  begin
    Left := Round(X + Index * Step - Dot / 2);
    FillSmoothEllipse(Canvas, MakeRectangle(Left, Round(Y - Dot / 2), Dot, Dot), Color);
  end;
end;

end.
