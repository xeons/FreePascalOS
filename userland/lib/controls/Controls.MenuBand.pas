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
  The band down a pop-up menu's left side (a menu with a SideBand text,
  as the desktop's Start menu has, when the theme draws one:
  TTheme.StartMenuBand): the theme's band gradient from top to bottom,
  edged like the menu's raised border, with the text in bold reading
  upwards from the bottom.

  Fonts are drawn upright only, so the text is drawn once into a small
  surface of its own (white on black: its coverage) and laid on the
  band turned a quarter left, the coverage blending the text's colour
  over the gradient.
}
unit Controls.MenuBand;

{$mode objfpc}
{$H+}

interface

uses
  Drawing.Canvas,
  Controls.Base;

type
  TMenuBand = class(TControl)
  private
    FText: string;
    procedure DrawTurnedText(var Canvas: TCanvas);
  public
    procedure Paint(var Canvas: TCanvas); override;
    property Text: string read FText write FText;
  end;

implementation

uses
  Drawing.Colors,
  Drawing.Rectangles,
  Drawing.Surfaces,
  Font.Faces,
  Font.Text,
  Windowing.Theme,
  Windowing.Connection,
  Controls.Text;

procedure TMenuBand.Paint(var Canvas: TCanvas);
var
  Box: TRectangle;
begin
  Box := MakeRectangle(0, 0, RectangleWidth(PixelBounds), RectangleHeight(PixelBounds));
  FillVerticalGradient(Canvas, Box, Theme.StartMenuBandStart, Theme.StartMenuBandEnd);
  { The menu's raised border goes on round the band: light at the top
    and left, dark at the bottom. }
  DrawHorizontalLine(Canvas, Box.Left, Box.Right, Box.Top, Theme.Highlight);
  DrawVerticalLine(Canvas, Box.Left, Box.Top, Box.Bottom, Theme.Highlight);
  DrawHorizontalLine(Canvas, Box.Left, Box.Right, Box.Bottom - 1, Theme.DarkShadow);
  DrawTurnedText(Canvas);
end;

procedure TMenuBand.DrawTurnedText(var Canvas: TCanvas);
var
  Face: PFontFace;
  Upright: TSurface;
  UprightCanvas: TCanvas;
  Width: LongInt;
  Height: LongInt;
  Column: LongInt;
  Row: LongInt;
  Coverage: Byte;
  Left: LongInt;
  Bottom: LongInt;
begin
  Face := ControlBoldFace;
  if (Face = nil) or (FText = '') then
    Exit;
  Width := MeasureText(Face^, FText);
  Height := Face^.Height;
  if not CreateSurface(Upright, Width, Height, $FF000000) then
    Exit;
  try
    BeginCanvas(UprightCanvas, Upright);
    DrawText(UprightCanvas, Face^, 0, 0, FText, $FFFFFFFF);
    { Turned a quarter left: the upright text's column X becomes the
      band's row Bottom - X, its row Y the band's column Left + Y. }
    Left := (RectangleWidth(PixelBounds) - Height) div 2;
    Bottom := RectangleHeight(PixelBounds) - Scaled(8);
    for Row := 0 to Height - 1 do
      for Column := 0 to Width - 1 do
      begin
        Coverage := Byte(SurfaceLine(Upright, Row)[Column]);
        if Coverage <> 0 then
          DrawPixel(Canvas, Left + Row, Bottom - Column, WithAlpha(Theme.StartMenuBandText, Coverage));
      end;
  finally
    FreeSurface(Upright);
  end;
end;

end.
