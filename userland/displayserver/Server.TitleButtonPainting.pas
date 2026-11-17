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
  Drawing one title button (minimize, maximize, restore or close) in a
  box, in the theme's way:

    plain (Classic)   a face button: the face (lighter when hot), a
                      raised bevel, sunken while pressed, a thin glyph
    tinted (Sunrise)  a small square in the title buttons' own colours:
                      a dark frame, a face shading down from a lighter
                      top, a one-line bevel of its own, and a heavy
                      black glyph; pale on an inactive window

  Either way a pressed button's glyph moves down and right as if pushed
  in. Pixel is a logical unit in pixels (at least 1): lines and glyphs
  grow with the scale.
}
unit Server.TitleButtonPainting;

{$mode objfpc}

interface

uses
  Drawing.Rectangles,
  Drawing.Canvas;

type
  TTitleGlyph = (GlyphMinimize, GlyphMaximize, GlyphRestore, GlyphClose);

  TTitleButtonLook = record
    Glyph: TTitleGlyph;
    Hot: Boolean;
    Pressed: Boolean;
    { On the active window's title bar. }
    Active: Boolean;
    { A logical unit in pixels, at least 1. }
    Pixel: LongInt;
    { How far the glyph's square is from the box's top and bottom. }
    GlyphMargin: LongInt;
  end;

procedure PaintTitleButton(const Canvas: TCanvas; const Box: TRectangle; const Look: TTitleButtonLook);

implementation

uses
  Drawing.Colors,
  Drawing.Bevels,
  Drawing.Shapes,
  Windowing.Theme;

{ A diagonal line Thickness pixels wide (from left to right). }
procedure DrawThickLine(const Canvas: TCanvas; FromX, FromY, ToX, ToY, Thickness: LongInt; Color: TColor);
var
  Offset: LongInt;
begin
  for Offset := 0 to Thickness - 1 do
    DrawLine(Canvas, FromX + Offset, FromY, ToX + Offset, ToY, Color);
end;

{ The outline of Box, Side pixels wide at the sides and bottom, Top at
  the top. }
procedure DrawWindowOutline(const Canvas: TCanvas; const Box: TRectangle; Side, Top: LongInt; Color: TColor);
var
  Width: LongInt;
  Height: LongInt;
begin
  Width := RectangleWidth(Box);
  Height := RectangleHeight(Box);
  FillRectangle(Canvas, MakeRectangle(Box.Left, Box.Top, Width, Top), Color);
  FillRectangle(Canvas, MakeRectangle(Box.Left, Box.Bottom - Side, Width, Side), Color);
  FillRectangle(Canvas, MakeRectangle(Box.Left, Box.Top, Side, Height), Color);
  FillRectangle(Canvas, MakeRectangle(Box.Right - Side, Box.Top, Side, Height), Color);
end;

{ The glyph in the square Glyph: Line is a line's width (the cross's
  strokes, a window's sides), Heavy what a window's title bar and the
  minimize bar have on top of it; Fill is the face (what the front window of the
  restore glyph hides behind it). }
procedure DrawGlyph(const Canvas: TCanvas; const Glyph: TRectangle; Kind: TTitleGlyph; Line, Heavy: LongInt;
  Color, Fill: TColor);
var
  Size: LongInt;
  Back: TRectangle;
  Front: TRectangle;
  Part: LongInt;
begin
  Size := RectangleWidth(Glyph);
  case Kind of
    GlyphClose:
      begin
        DrawThickLine(Canvas, Glyph.Left, Glyph.Top, Glyph.Right - Line, Glyph.Bottom - 1, Line, Color);
        DrawThickLine(Canvas, Glyph.Right - Line, Glyph.Top, Glyph.Left, Glyph.Bottom - 1, Line, Color);
      end;
    GlyphMaximize:
      DrawWindowOutline(Canvas, Glyph, Line, Heavy + Line, Color);
    GlyphRestore:
      begin
        { Two windows: one behind at the top right, one in front at the
          bottom left. }
        Part := Size - Size div 4;
        Back := MakeRectangle(Glyph.Right - Part, Glyph.Top, Part, Part);
        Front := MakeRectangle(Glyph.Left, Glyph.Bottom - Part, Part, Part);
        DrawWindowOutline(Canvas, Back, Line, Line + Heavy, Color);
        FillRectangle(Canvas, InflateRectangle(Front, -Line), Fill);
        DrawWindowOutline(Canvas, Front, Line, Line + Heavy, Color);
      end;
    GlyphMinimize:
      FillRectangle(Canvas, MakeRectangle(Glyph.Left + Size div 8, Glyph.Bottom - Heavy - Line,
        Size - 2 * (Size div 8), Heavy + Line), Color);
  end;
end;

{ The square the glyph is drawn in: in the middle, pushed in when
  pressed. }
function GlyphSquare(const Box: TRectangle; const Look: TTitleButtonLook): TRectangle;
var
  Size: LongInt;
begin
  Size := RectangleHeight(Box) - 2 * Look.GlyphMargin;
  Result := MakeRectangle(Box.Left + (RectangleWidth(Box) - Size) div 2, Box.Top + (RectangleHeight(Box) - Size) div 2,
    Size, Size);
  if Look.Pressed then
    Result := OffsetRectangle(Result, Look.Pixel, Look.Pixel);
end;

procedure PaintPlainButton(const Canvas: TCanvas; const Box: TRectangle; const Look: TTitleButtonLook);
var
  Glyph: TRectangle;
  Size: LongInt;
  Line: LongInt;
begin
  if Look.Hot then
    FillRectangle(Canvas, Box, Theme.TitleButtonHotFace)
  else if Look.Pressed then
    FillRectangle(Canvas, Box, Theme.TitleButtonPressedFace)
  else
    FillRectangle(Canvas, Box, Theme.TitleButtonFace);
  if Look.Pressed then
    DrawBevel(Canvas, Box, SunkenThemeBevel)
  else
    DrawBevel(Canvas, Box, RaisedThemeBevel);
  Glyph := GlyphSquare(Box, Look);
  Size := RectangleWidth(Glyph);
  Line := Look.Pixel;
  case Look.Glyph of
    GlyphClose:
      DrawGlyph(Canvas, Glyph, GlyphClose, Line, Line, Theme.TitleButtonGlyph, Theme.TitleButtonFace);
    GlyphMaximize, GlyphRestore:
      { The plain look has no restore glyph of its own. }
      DrawWindowOutline(Canvas, Glyph, Line, 2 * Line, Theme.TitleButtonGlyph);
    GlyphMinimize:
      FillRectangle(Canvas, MakeRectangle(Glyph.Left, Glyph.Bottom - 2 * Line, Size - Size div 4, 2 * Line),
        Theme.TitleButtonGlyph);
  end;
end;

{ A one-line edge Width pixels wide: Light at the top and left, Shade at
  the bottom and right. }
procedure DrawWideEdge(const Canvas: TCanvas; const Box: TRectangle; Width: LongInt; Light, Shade: TColor);
begin
  FillRectangle(Canvas, MakeRectangle(Box.Left, Box.Top, RectangleWidth(Box), Width), Light);
  FillRectangle(Canvas, MakeRectangle(Box.Left, Box.Top, Width, RectangleHeight(Box)), Light);
  FillRectangle(Canvas, MakeRectangle(Box.Left, Box.Bottom - Width, RectangleWidth(Box), Width), Shade);
  FillRectangle(Canvas, MakeRectangle(Box.Right - Width, Box.Top, Width, RectangleHeight(Box)), Shade);
end;

procedure PaintTintedButton(const Canvas: TCanvas; const Box: TRectangle; const Look: TTitleButtonLook);
var
  Inner: TRectangle;
  Face: TColor;
  GlyphColor: TColor;
  FrameColor: TColor;
  HighlightColor: TColor;
  ShadowColor: TColor;
  Pixel: LongInt;
begin
  Pixel := Look.Pixel;
  if Look.Active then
  begin
    Face := Theme.TitleButtonFace;
    GlyphColor := Theme.TitleButtonGlyph;
    FrameColor := Theme.TitleButtonFrame;
    HighlightColor := Theme.TitleButtonHighlight;
    ShadowColor := Theme.TitleButtonShadow;
  end
  else
  begin
    { Pale, edged in the inactive bar's colours. }
    Face := Theme.InactiveTitleButtonFace;
    GlyphColor := Theme.InactiveTitleButtonGlyph;
    FrameColor := Theme.InactiveTitleEdge;
    HighlightColor := Theme.Highlight;
    ShadowColor := Theme.InactiveTitleEdge;
  end;
  if Look.Hot then
    Face := Theme.TitleButtonHotFace
  else if Look.Pressed then
    Face := Theme.TitleButtonPressedFace;
  Inner := Box;
  if FrameColor <> ColorTransparent then
  begin
    DrawWindowOutline(Canvas, Box, Pixel, Pixel, FrameColor);
    Inner := InflateRectangle(Box, -Pixel);
  end;
  if Look.Pressed then
  begin
    FillRectangle(Canvas, Inner, Face);
    DrawWideEdge(Canvas, Inner, Pixel, ShadowColor, Face);
  end
  else
  begin
    FillVerticalGradient(Canvas, Inner, MixColors(Face, HighlightColor, 150), Face);
    DrawWideEdge(Canvas, Inner, Pixel, HighlightColor, ShadowColor);
  end;
  { Heavy glyphs: the cross's strokes a pixel wider than a window's
    sides. }
  if Look.Glyph = GlyphClose then
    DrawGlyph(Canvas, GlyphSquare(Box, Look), GlyphClose, 3 * Pixel, Pixel, GlyphColor, Face)
  else
    DrawGlyph(Canvas, GlyphSquare(Box, Look), Look.Glyph, 2 * Pixel, Pixel, GlyphColor, Face);
end;

procedure PaintTitleButton(const Canvas: TCanvas; const Box: TRectangle; const Look: TTitleButtonLook);
begin
  if Theme.TintedTitleButtons then
    PaintTintedButton(Canvas, Box, Look)
  else
    PaintPlainButton(Canvas, Box, Look);
end;

end.
