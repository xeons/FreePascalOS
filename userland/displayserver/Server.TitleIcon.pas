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
  The icon at the left of a title bar (when the theme has one,
  TTheme.TitleIcon): windows do not give the server an icon, so every
  window gets the same small application picture - a little window
  with a navy title strip, a light body and a shaded edge, drawn in
  the square it is given, its lines a logical unit wide.
}
unit Server.TitleIcon;

{$mode objfpc}

interface

uses
  Drawing.Rectangles,
  Drawing.Canvas;

{ Draws the icon in Box (a square); Pixel is a logical unit in pixels,
  at least 1. }
procedure DrawTitleIcon(const Canvas: TCanvas; const Box: TRectangle; Pixel: LongInt);

implementation

uses
  Drawing.Colors,
  Windowing.Theme;

procedure DrawTitleIcon(const Canvas: TCanvas; const Box: TRectangle; Pixel: LongInt);
var
  Size: LongInt;
  Body: TRectangle;
  Inner: TRectangle;
  Strip: TRectangle;
  StripHeight: LongInt;
begin
  Size := RectangleWidth(Box);
  if Size < 6 * Pixel then
    Exit;
  { A shadow down and right, then the window over it. }
  Body := MakeRectangle(Box.Left, Box.Top + Size div 8, Size - Pixel, Size - Size div 8 - Pixel);
  FillRectangle(Canvas, OffsetRectangle(Body, Pixel, Pixel), WithAlpha(Theme.DarkShadow, 90));
  FillRectangle(Canvas, Body, Theme.DarkShadow);
  Inner := InflateRectangle(Body, -Pixel);
  FillVerticalGradient(Canvas, Inner, Theme.Field, Theme.Face);
  StripHeight := RectangleHeight(Inner) div 3;
  Strip := MakeRectangle(Inner.Left, Inner.Top, RectangleWidth(Inner), StripHeight);
  FillVerticalGradient(Canvas, Strip, Theme.NavyBandStart, Theme.NavyBandEnd);
  { A spot of gold at the strip's right: the window's buttons. }
  FillRectangle(Canvas, MakeRectangle(Strip.Right - 2 * Pixel - Pixel, Strip.Top + (StripHeight - 2 * Pixel) div 2,
    2 * Pixel, 2 * Pixel), Theme.HeaderBandStart);
end;

end.
