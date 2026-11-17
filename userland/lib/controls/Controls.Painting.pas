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
  The pieces controls are painted from, in the theme's look: bevels and
  edges whose lines grow with the display scale (when the theme says
  so: Theme.ScaledBevelLines; one pixel each otherwise), etched lines,
  vertical gradients (a colour per pixel row, nothing allocated), the
  golden and navy header bands, arrows, and grips.

  BevelLine is the width of one line in pixels, BevelWidth that of a
  whole two-line bevel: what a sunken field keeps clear inside its
  edge.
}
unit Controls.Painting;

{$mode objfpc}
{$H+}

interface

uses
  Drawing.Colors,
  Drawing.Rectangles,
  Drawing.Canvas,
  Drawing.Bevels;

type
  TArrowDirection = (ArrowUp, ArrowDown, ArrowLeft, ArrowRight);
  { A header band's colours: golden (a header) or navy (a section). }
  TBandKind = (BandHeader, BandSection);

function BevelLine: LongInt;
function BevelWidth: LongInt;

{ One edge, BevelLine pixels thick, inside Rectangle: lit along the top
  and left, shaded along the bottom and right (each line's corners as
  Drawing.Bevels' DrawEdge). }
procedure DrawThemeEdge(const Canvas: TCanvas; const Rectangle: TRectangle; Light, Shade: TColor);
{ A two-line bevel inside Rectangle (BevelWidth pixels). }
procedure DrawThemeBevel(const Canvas: TCanvas; const Rectangle: TRectangle; const Colors: TBevelColors);
procedure DrawRaisedBevel(const Canvas: TCanvas; const Rectangle: TRectangle);
procedure DrawSunkenBevel(const Canvas: TCanvas; const Rectangle: TRectangle);
{ The one-line edges of a panel: highlight and shadow. }
procedure DrawRaisedEdge(const Canvas: TCanvas; const Rectangle: TRectangle);
procedure DrawSunkenEdge(const Canvas: TCanvas; const Rectangle: TRectangle);
{ A groove: a shadow line with a highlight line below (right of) it,
  each BevelLine thick, starting at Top (Left). }
procedure DrawEtchedHorizontalLine(const Canvas: TCanvas; Left, Right, Top: LongInt);
procedure DrawEtchedVerticalLine(const Canvas: TCanvas; Left, Top, Bottom: LongInt);
{ The outline of Rectangle, Thickness pixels wide inside it. }
procedure DrawThickOutline(const Canvas: TCanvas; const Rectangle: TRectangle; Thickness: LongInt; Color: TColor);
{ Rectangle filled from TopColor in its first row to BottomColor in its
  last. }
procedure FillVerticalGradient(const Canvas: TCanvas; const Rectangle: TRectangle; TopColor, BottomColor: TColor);
{ A header band filling Rectangle: the gradient of its kind with a lit
  top line and a darker edge along the bottom. }
procedure DrawHeaderBand(const Canvas: TCanvas; const Rectangle: TRectangle; Kind: TBandKind);
function HeaderBandText(Kind: TBandKind): TColor;
{ A solid triangle pointing Direction in the middle of Box, Size pixels
  from its middle to its tip side (half its base). }
procedure DrawArrowGlyph(const Canvas: TCanvas; const Box: TRectangle; Direction: TArrowDirection; Size: LongInt;
  Color: TColor);
{ The size grip of a status bar: diagonal rows of raised dots in the
  bottom right corner of Box. }
procedure DrawSizeGrip(const Canvas: TCanvas; const Box: TRectangle);
{ A short row (Vertical: a column) of raised dots in the middle of Box,
  a splitter's grip. }
procedure DrawGripDots(const Canvas: TCanvas; const Box: TRectangle; Vertical: Boolean);

implementation

uses
  Drawing.Shapes,
  Windowing.Theme,
  Windowing.Connection;

function BevelLine: LongInt;
begin
  Result := BevelLineWidth(DisplayScale);
end;

function BevelWidth: LongInt;
begin
  Result := 2 * BevelLine;
end;

procedure DrawThemeEdge(const Canvas: TCanvas; const Rectangle: TRectangle; Light, Shade: TColor);
var
  Line: LongInt;
begin
  for Line := 0 to BevelLine - 1 do
    DrawEdge(Canvas, InflateRectangle(Rectangle, -Line), Light, Shade);
end;

procedure DrawThemeBevel(const Canvas: TCanvas; const Rectangle: TRectangle; const Colors: TBevelColors);
begin
  DrawThemeEdge(Canvas, Rectangle, Colors.OuterLight, Colors.OuterShade);
  DrawThemeEdge(Canvas, InflateRectangle(Rectangle, -BevelLine), Colors.InnerLight, Colors.InnerShade);
end;

procedure DrawRaisedBevel(const Canvas: TCanvas; const Rectangle: TRectangle);
begin
  DrawThemeBevel(Canvas, Rectangle, RaisedThemeBevel);
end;

procedure DrawSunkenBevel(const Canvas: TCanvas; const Rectangle: TRectangle);
begin
  DrawThemeBevel(Canvas, Rectangle, SunkenThemeBevel);
end;

procedure DrawRaisedEdge(const Canvas: TCanvas; const Rectangle: TRectangle);
begin
  DrawThemeEdge(Canvas, Rectangle, Theme.Highlight, Theme.Shadow);
end;

procedure DrawSunkenEdge(const Canvas: TCanvas; const Rectangle: TRectangle);
begin
  DrawThemeEdge(Canvas, Rectangle, Theme.Shadow, Theme.Highlight);
end;

procedure DrawEtchedHorizontalLine(const Canvas: TCanvas; Left, Right, Top: LongInt);
begin
  FillRectangle(Canvas, MakeRectangle(Left, Top, Right - Left, BevelLine), Theme.Shadow);
  FillRectangle(Canvas, MakeRectangle(Left, Top + BevelLine, Right - Left, BevelLine), Theme.Highlight);
end;

procedure DrawEtchedVerticalLine(const Canvas: TCanvas; Left, Top, Bottom: LongInt);
begin
  FillRectangle(Canvas, MakeRectangle(Left, Top, BevelLine, Bottom - Top), Theme.Shadow);
  FillRectangle(Canvas, MakeRectangle(Left + BevelLine, Top, BevelLine, Bottom - Top), Theme.Highlight);
end;

procedure DrawThickOutline(const Canvas: TCanvas; const Rectangle: TRectangle; Thickness: LongInt; Color: TColor);
var
  Width: LongInt;
  Height: LongInt;
begin
  Width := RectangleWidth(Rectangle);
  Height := RectangleHeight(Rectangle);
  FillRectangle(Canvas, MakeRectangle(Rectangle.Left, Rectangle.Top, Width, Thickness), Color);
  FillRectangle(Canvas, MakeRectangle(Rectangle.Left, Rectangle.Bottom - Thickness, Width, Thickness), Color);
  FillRectangle(Canvas, MakeRectangle(Rectangle.Left, Rectangle.Top, Thickness, Height), Color);
  FillRectangle(Canvas, MakeRectangle(Rectangle.Right - Thickness, Rectangle.Top, Thickness, Height), Color);
end;

procedure FillVerticalGradient(const Canvas: TCanvas; const Rectangle: TRectangle; TopColor, BottomColor: TColor);
var
  Height: LongInt;
  Row: LongInt;
  Weight: LongInt;
begin
  Height := RectangleHeight(Rectangle);
  if (Height <= 0) or (RectangleWidth(Rectangle) <= 0) then
    Exit;
  if TopColor = BottomColor then
  begin
    FillRectangle(Canvas, Rectangle, TopColor);
    Exit;
  end;
  for Row := 0 to Height - 1 do
  begin
    Weight := 0;
    if Height > 1 then
      Weight := (Row * 255 + (Height - 1) div 2) div (Height - 1);
    FillSpan(Canvas, Rectangle.Top + Row, Rectangle.Left, Rectangle.Right, MixColors(TopColor, BottomColor, Weight));
  end;
end;

procedure DrawHeaderBand(const Canvas: TCanvas; const Rectangle: TRectangle; Kind: TBandKind);
var
  TopColor: TColor;
  BottomColor: TColor;
  Edge: TColor;
  Line: LongInt;
begin
  if Kind = BandSection then
  begin
    TopColor := Theme.SectionBandTop;
    BottomColor := Theme.SectionBandBottom;
    Edge := Theme.SectionBandEdge;
  end
  else
  begin
    TopColor := Theme.HeaderBandTop;
    BottomColor := Theme.HeaderBandBottom;
    Edge := Theme.HeaderBandEdge;
  end;
  Line := BevelLine;
  FillVerticalGradient(Canvas, Rectangle, TopColor, BottomColor);
  { A sheen along the top, the edge along the bottom. }
  FillRectangle(Canvas, MakeRectangle(Rectangle.Left, Rectangle.Top, RectangleWidth(Rectangle), Line),
    MixColors(TopColor, $FFFFFFFF, 140));
  FillRectangle(Canvas, MakeRectangle(Rectangle.Left, Rectangle.Bottom - Line, RectangleWidth(Rectangle), Line), Edge);
end;

function HeaderBandText(Kind: TBandKind): TColor;
begin
  if Kind = BandSection then
    Result := Theme.SectionBandText
  else
    Result := Theme.HeaderBandText;
end;

procedure DrawArrowGlyph(const Canvas: TCanvas; const Box: TRectangle; Direction: TArrowDirection; Size: LongInt;
  Color: TColor);
var
  CentreX: LongInt;
  CentreY: LongInt;
  Points: array[0..2] of TPoint;
  Half: LongInt;
begin
  if Size < 1 then
    Size := 1;
  CentreX := Box.Left + RectangleWidth(Box) div 2;
  CentreY := Box.Top + RectangleHeight(Box) div 2;
  Half := Size div 2;
  case Direction of
    ArrowUp:
      begin
        Points[0] := MakePoint(CentreX - Size, CentreY + Half);
        Points[1] := MakePoint(CentreX + Size, CentreY + Half);
        Points[2] := MakePoint(CentreX, CentreY - Half - 1);
      end;
    ArrowDown:
      begin
        Points[0] := MakePoint(CentreX - Size, CentreY - Half);
        Points[1] := MakePoint(CentreX + Size, CentreY - Half);
        Points[2] := MakePoint(CentreX, CentreY + Half + 1);
      end;
    ArrowLeft:
      begin
        Points[0] := MakePoint(CentreX + Half, CentreY - Size);
        Points[1] := MakePoint(CentreX + Half, CentreY + Size);
        Points[2] := MakePoint(CentreX - Half - 1, CentreY);
      end;
  else
    begin
      Points[0] := MakePoint(CentreX - Half, CentreY - Size);
      Points[1] := MakePoint(CentreX - Half, CentreY + Size);
      Points[2] := MakePoint(CentreX + Half + 1, CentreY);
    end;
  end;
  FillPolygon(Canvas, Points, Color);
end;

{ A raised dot: a highlight square with its shadow down and right. }
procedure DrawGripDot(const Canvas: TCanvas; X, Y, Size: LongInt);
begin
  FillRectangle(Canvas, MakeRectangle(X + Size div 2, Y + Size div 2, Size, Size), Theme.Shadow);
  FillRectangle(Canvas, MakeRectangle(X, Y, Size, Size), Theme.Highlight);
end;

procedure DrawSizeGrip(const Canvas: TCanvas; const Box: TRectangle);
var
  Dot: LongInt;
  Step: LongInt;
  Row: LongInt;
  Column: LongInt;
begin
  Dot := Scaled(2);
  Step := Scaled(4);
  { Three rows: one dot at the top, three along the bottom. }
  for Row := 0 to 2 do
    for Column := 2 - Row to 2 do
      DrawGripDot(Canvas, Box.Right - Scaled(2) - (3 - Column) * Step, Box.Bottom - Scaled(2) - (3 - Row) * Step,
        Dot);
end;

procedure DrawGripDots(const Canvas: TCanvas; const Box: TRectangle; Vertical: Boolean);
var
  Dot: LongInt;
  Step: LongInt;
  Index: LongInt;
  X: LongInt;
  Y: LongInt;
begin
  Dot := Scaled(2);
  Step := Scaled(4);
  for Index := -2 to 2 do
  begin
    if Vertical then
    begin
      X := Box.Left + (RectangleWidth(Box) - Dot) div 2;
      Y := Box.Top + RectangleHeight(Box) div 2 + Index * Step - Dot div 2;
    end
    else
    begin
      X := Box.Left + RectangleWidth(Box) div 2 + Index * Step - Dot div 2;
      Y := Box.Top + (RectangleHeight(Box) - Dot) div 2;
    end;
    DrawGripDot(Canvas, X, Y, Dot);
  end;
end;

end.
