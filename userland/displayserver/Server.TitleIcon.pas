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
  The icon at the left of a title bar: the window's own (or its
  owner's, Server.WindowIcons), at the box's size in pixels - so at the
  scale of the display the window is on. A window with none gets, when
  the theme has it (TTheme.TitleIcon), the generic application picture
  - a little window with a navy title strip, a light body and a shaded
  edge, drawn in the square it is given, its lines a logical unit wide.
}
unit Server.TitleIcon;

{$mode objfpc}

interface

uses
  Drawing.Rectangles,
  Drawing.Canvas,
  Server.Windows;

{ Draws the icon in Box (a square); Pixel is a logical unit in pixels,
  at least 1. }
procedure DrawTitleIcon(const Canvas: TCanvas; const Box: TRectangle; Pixel: LongInt);
{ Draws the icon Window shows in Box (a square); False (nothing drawn)
  if it has none. }
function DrawWindowIcon(const Canvas: TCanvas; Window: TServerWindow; const Box: TRectangle): Boolean;

implementation

uses
  Drawing.Colors,
  Image.Model,
  Image.Surfaces,
  Windowing.Theme,
  Server.WindowIcons;

function DrawWindowIcon(const Canvas: TCanvas; Window: TServerWindow; const Box: TRectangle): Boolean;
var
  Picture: TImage;
begin
  Picture := WindowIconPicture(Window, RectangleWidth(Box));
  Result := Picture <> nil;
  if Result then
    DrawSurface(Canvas, ImageSurface(Picture), MakeRectangle(0, 0, Picture.Width, Picture.Height), Box.Left, Box.Top,
      True, AlphaOpaque);
end;

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
  FillVerticalGradient(Canvas, Strip, Theme.SectionBandTop, Theme.SectionBandBottom);
  { A spot of gold at the strip's right: the window's buttons. }
  FillRectangle(Canvas, MakeRectangle(Strip.Right - 2 * Pixel - Pixel, Strip.Top + (StripHeight - 2 * Pixel) div 2,
    2 * Pixel, 2 * Pixel), Theme.HeaderBandTop);
end;

end.
