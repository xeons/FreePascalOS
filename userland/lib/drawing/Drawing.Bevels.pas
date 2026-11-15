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
  Bevels: the two pixel edges that make a rectangle look raised (a
  button) or sunken (a text box), and the dotted focus frame.

  The outer edge is the rectangle's outermost pixels, the inner one the
  ring just inside. Each is lit along the top and left and shaded along
  the bottom and right; the corner where the two meet (top right,
  bottom left) belongs to the shade. The colours come from the theme:
  RaisedBevel and SunkenBevel arrange four of them the usual way.
}
unit Drawing.Bevels;

{$mode objfpc}

interface

uses
  Drawing.Colors,
  Drawing.Rectangles,
  Drawing.Canvas;

type
  TBevelColors = record
    OuterLight: TColor;
    OuterShade: TColor;
    InnerLight: TColor;
    InnerShade: TColor;
  end;

{ Raised: brightest and darkest outside. Sunken: the other way round. }
function RaisedBevel(Highlight, Light, Shadow, DarkShadow: TColor): TBevelColors;
function SunkenBevel(Highlight, Light, Shadow, DarkShadow: TColor): TBevelColors;

{ The bevel just inside Rectangle (two pixels wide). }
procedure DrawBevel(const Canvas: TCanvas; const Rectangle: TRectangle; const Colors: TBevelColors);
{ A one pixel edge: lit top and left, shaded bottom and right. }
procedure DrawEdge(const Canvas: TCanvas; const Rectangle: TRectangle; Light, Shade: TColor);
{ Every other pixel of a frame just inside Rectangle, starting with its
  top left corner. }
procedure DrawFocusFrame(const Canvas: TCanvas; const Rectangle: TRectangle; Color: TColor);

implementation

function RaisedBevel(Highlight, Light, Shadow, DarkShadow: TColor): TBevelColors;
begin
  Result.OuterLight := Light;
  Result.InnerLight := Highlight;
  Result.InnerShade := Shadow;
  Result.OuterShade := DarkShadow;
end;

function SunkenBevel(Highlight, Light, Shadow, DarkShadow: TColor): TBevelColors;
begin
  Result.OuterLight := Shadow;
  Result.InnerLight := DarkShadow;
  Result.InnerShade := Light;
  Result.OuterShade := Highlight;
end;

procedure DrawEdge(const Canvas: TCanvas; const Rectangle: TRectangle; Light, Shade: TColor);
begin
  if RectangleIsEmpty(Rectangle) then
    Exit;
  { Lit: the top row and left column, short of the far corners. }
  DrawHorizontalLine(Canvas, Rectangle.Left, Rectangle.Right - 1, Rectangle.Top, Light);
  DrawVerticalLine(Canvas, Rectangle.Left, Rectangle.Top + 1, Rectangle.Bottom - 1, Light);
  { Shaded: the bottom row and right column, corners included. }
  DrawHorizontalLine(Canvas, Rectangle.Left, Rectangle.Right, Rectangle.Bottom - 1, Shade);
  DrawVerticalLine(Canvas, Rectangle.Right - 1, Rectangle.Top, Rectangle.Bottom - 1, Shade);
end;

procedure DrawBevel(const Canvas: TCanvas; const Rectangle: TRectangle; const Colors: TBevelColors);
begin
  DrawEdge(Canvas, Rectangle, Colors.OuterLight, Colors.OuterShade);
  DrawEdge(Canvas, InflateRectangle(Rectangle, -1), Colors.InnerLight, Colors.InnerShade);
end;

procedure DrawFocusFrame(const Canvas: TCanvas; const Rectangle: TRectangle; Color: TColor);
var
  X: LongInt;
  Y: LongInt;
begin
  if RectangleIsEmpty(Rectangle) then
    Exit;
  { The dots follow the whole frame's pixels in a checkerboard, so the
    pattern is the same whichever side is looked at. }
  for X := Rectangle.Left to Rectangle.Right - 1 do
  begin
    if ((X - Rectangle.Left) mod 2) = 0 then
      DrawPixel(Canvas, X, Rectangle.Top, Color);
    if ((X - Rectangle.Left + RectangleHeight(Rectangle) - 1) mod 2) = 0 then
      DrawPixel(Canvas, X, Rectangle.Bottom - 1, Color);
  end;
  for Y := Rectangle.Top + 1 to Rectangle.Bottom - 2 do
  begin
    if ((Y - Rectangle.Top) mod 2) = 0 then
      DrawPixel(Canvas, Rectangle.Left, Y, Color);
    if ((Y - Rectangle.Top + RectangleWidth(Rectangle) - 1) mod 2) = 0 then
      DrawPixel(Canvas, Rectangle.Right - 1, Y, Color);
  end;
end;

end.
