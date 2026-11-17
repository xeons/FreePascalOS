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
  Window frames: drawing them, and what part of one a point is on.

  Outside in: a raised bevel, the face colour to the border's width, the
  title bar (a gradient, across or down as the theme says, with its edge
  and a shine along its top when the theme has them; the window's icon
  - its owner's if it has none, else the generic picture when the
  theme shows one, Server.TitleIcon - the title, and the minimize, maximize - a
  restore glyph on a maximized window - and close buttons at its right
  end, Server.TitleButtonPainting) above the client area. An inactive
  window's bar and buttons take the theme's inactive colours. Sizes come from the
  theme in logical units; the title's font from its size in points at
  the DPI of the screen the window is on. A title button under the
  pointer is drawn hot (a lighter face), and pressed (sunken, its glyph
  a pixel down and right) while held (Server.TitleButtons).
}
unit Server.Frames;

{$mode objfpc}
{$H+}

interface

uses
  Drawing.Rectangles,
  Drawing.Canvas,
  Font.Faces,
  Server.Windows;

type
  THitArea = (HitNothing, HitClient, HitTitle, HitMinimize, HitMaximize, HitClose,
    HitLeft, HitRight, HitTop, HitBottom, HitTopLeft, HitTopRight, HitBottomLeft, HitBottomRight);

function TitleBarRectangle(Window: TServerWindow): TRectangle;
function TitleButtonRectangle(Window: TServerWindow; Button: THitArea): TRectangle;
procedure DrawFrame(const Canvas: TCanvas; Window: TServerWindow; Active: Boolean);
function HitTest(Window: TServerWindow; X, Y: LongInt): THitArea;

implementation

uses
  Windowing.Theme,
  Drawing.Colors,
  Drawing.Bevels,
  Drawing.Shapes,
  Font.Text,
  Windowing.Protocol,
  Server.Theme,
  Server.Screen,
  Server.TitleButtons,
  Server.TitleButtonPainting,
  Server.TitleIcon;

function TitleBarRectangle(Window: TServerWindow): TRectangle;
var
  Frame: TRectangle;
  Border: LongInt;
begin
  Frame := FrameRectangle(Window);
  Border := WindowMetric(Window, Theme.BorderWidth) - 1;
  Result.Left := Frame.Left + Border;
  Result.Right := Frame.Right - Border;
  Result.Top := Frame.Top + Border;
  Result.Bottom := Window.ClientTop - 1;
end;

function TitleButtonRectangle(Window: TServerWindow; Button: THitArea): TRectangle;
var
  Bar: TRectangle;
  Width: LongInt;
  Height: LongInt;
  Right: LongInt;
  Gap: LongInt;
begin
  Bar := TitleBarRectangle(Window);
  Width := WindowMetric(Window, Theme.TitleButtonWidth);
  Height := WindowMetric(Window, Theme.TitleButtonHeight);
  { The glyph is a square as far from the top as from the bottom; with
    the width and height alike odd or even it is as far from each side
    too, whole pixels at every scale. }
  if Odd(Width - Height) then
    Inc(Width);
  Gap := WindowMetric(Window, Theme.TitleButtonGap);
  Right := Bar.Right - Gap;
  if Button <> HitClose then
  begin
    { Maximize and minimize sit together, a gap left of close. }
    Right := Right - Width - Gap;
    if Button = HitMinimize then
      Right := Right - Width;
  end;
  Result := MakeRectangle(Right - Width, Bar.Top + (RectangleHeight(Bar) - Height) div 2, Width, Height);
end;

function HasSizeButtons(Window: TServerWindow): Boolean;
begin
  Result := (Window.Flags and WindowResizable) <> 0;
end;

{ The leftmost button drawn: the title stops short of it. }
function LeftmostTitleButton(Window: TServerWindow): THitArea;
begin
  if HasSizeButtons(Window) then
    Result := HitMinimize
  else
    Result := HitClose;
end;

{ A logical unit in pixels at the window's scale, at least 1. }
function WindowPixel(Window: TServerWindow): LongInt;
begin
  Result := WindowMetric(Window, 1);
  if Result < 1 then
    Result := 1;
end;

procedure DrawTitleButton(const Canvas: TCanvas; Window: TServerWindow; Button: THitArea; Active: Boolean);
var
  Look: TTitleButtonLook;
begin
  case Button of
    HitMinimize:
      Look.Glyph := GlyphMinimize;
    HitMaximize:
      if Window.Maximized then
        Look.Glyph := GlyphRestore
      else
        Look.Glyph := GlyphMaximize;
  else
    Look.Glyph := GlyphClose;
  end;
  Look.Hot := TitleButtonIsHot(Window, Button);
  Look.Pressed := TitleButtonIsPressed(Window, Button);
  Look.Active := Active;
  Look.Pixel := WindowPixel(Window);
  Look.GlyphMargin := WindowMetric(Window, 4);
  PaintTitleButton(Canvas, TitleButtonRectangle(Window, Button), Look);
end;

{ The bar's background: the theme's gradient, across or down; running
  down, also its edge (when the theme has one) and a lighter line along
  its top. }
procedure DrawTitleBackground(const Canvas: TCanvas; Window: TServerWindow; const Bar: TRectangle; Active: Boolean);
var
  StartColor: TColor;
  EndColor: TColor;
  EdgeColor: TColor;
  Pixel: LongInt;
  Inside: TRectangle;
begin
  if Active then
  begin
    StartColor := Theme.ActiveTitleStart;
    EndColor := Theme.ActiveTitleEnd;
    EdgeColor := Theme.ActiveTitleEdge;
  end
  else
  begin
    StartColor := Theme.InactiveTitleStart;
    EndColor := Theme.InactiveTitleEnd;
    EdgeColor := Theme.InactiveTitleEdge;
  end;
  if not Theme.TitleGradientVertical then
  begin
    FillHorizontalGradient(Canvas, Bar, StartColor, EndColor);
    Exit;
  end;
  FillVerticalGradient(Canvas, Bar, StartColor, EndColor);
  Pixel := WindowPixel(Window);
  Inside := Bar;
  if EdgeColor <> ColorTransparent then
  begin
    FillRectangle(Canvas, MakeRectangle(Bar.Left, Bar.Top, RectangleWidth(Bar), Pixel), EdgeColor);
    FillRectangle(Canvas, MakeRectangle(Bar.Left, Bar.Bottom - Pixel, RectangleWidth(Bar), Pixel), EdgeColor);
    FillRectangle(Canvas, MakeRectangle(Bar.Left, Bar.Top, Pixel, RectangleHeight(Bar)), EdgeColor);
    FillRectangle(Canvas, MakeRectangle(Bar.Right - Pixel, Bar.Top, Pixel, RectangleHeight(Bar)), EdgeColor);
    Inside := InflateRectangle(Bar, -Pixel);
  end;
  { A shine along the top. }
  FillRectangle(Canvas, MakeRectangle(Inside.Left, Inside.Top, RectangleWidth(Inside), Pixel),
    MixColors(StartColor, Theme.Highlight, 150));
end;

{ Draws the window's icon (its own, or its owner's: Server.WindowIcons)
  at the bar's left, or the generic picture when it has none and the
  theme shows one; returns where the title's text starts (after the
  icon, if any). }
function DrawTitleIconOf(const Canvas: TCanvas; Window: TServerWindow; const Bar: TRectangle): LongInt;
var
  Size: LongInt;
  Indent: LongInt;
  Box: TRectangle;
begin
  Indent := WindowMetric(Window, Theme.TitleTextIndent);
  Result := Bar.Left + Indent;
  Size := WindowMetric(Window, 16);
  if Size > RectangleHeight(Bar) - 2 * WindowMetric(Window, 2) then
    Size := RectangleHeight(Bar) - 2 * WindowMetric(Window, 2);
  Box := MakeRectangle(Bar.Left + Indent, Bar.Top + (RectangleHeight(Bar) - Size) div 2, Size, Size);
  if DrawWindowIcon(Canvas, Window, Box) then
    Result := Box.Right + WindowMetric(Window, 4)
  else if Theme.TitleIcon then
  begin
    DrawTitleIcon(Canvas, Box, WindowPixel(Window));
    Result := Box.Right + WindowMetric(Window, 4);
  end;
end;

procedure DrawFrame(const Canvas: TCanvas; Window: TServerWindow; Active: Boolean);
var
  Frame: TRectangle;
  Bar: TRectangle;
  TextColor: TColor;
  Client: TRectangle;
  TextClip: TCanvas;
  TextLeft: LongInt;
  TextRight: LongInt;
  TitleFace: PFontFace;
begin
  Frame := FrameRectangle(Window);
  Client := ClientRectangle(Window);
  { The face around the client area (the client area is drawn over it). }
  FillRectangle(Canvas, MakeRectangle(Frame.Left, Frame.Top, RectangleWidth(Frame), Client.Top - Frame.Top), Theme.Face);
  FillRectangle(Canvas, MakeRectangle(Frame.Left, Client.Top, Client.Left - Frame.Left, RectangleHeight(Client)), Theme.Face);
  FillRectangle(Canvas, MakeRectangle(Client.Right, Client.Top, Frame.Right - Client.Right, RectangleHeight(Client)),
    Theme.Face);
  FillRectangle(Canvas, MakeRectangle(Frame.Left, Client.Bottom, RectangleWidth(Frame), Frame.Bottom - Client.Bottom),
    Theme.Face);
  DrawBevel(Canvas, Frame, RaisedThemeBevel);
  Bar := TitleBarRectangle(Window);
  DrawTitleBackground(Canvas, Window, Bar, Active);
  if Active then
    TextColor := Theme.ActiveTitleText
  else
    TextColor := Theme.InactiveTitleText;
  TextLeft := DrawTitleIconOf(Canvas, Window, Bar);
  TitleFace := WindowScreen(Window)^.TitleFace;
  if TitleFace <> nil then
  begin
    { The title stops before the buttons. }
    TextClip := Canvas;
    TextRight := TitleButtonRectangle(Window, LeftmostTitleButton(Window)).Left - WindowMetric(Window, 2);
    NarrowCanvasClip(TextClip, MakeRectangle(Bar.Left, Bar.Top, TextRight - Bar.Left, RectangleHeight(Bar)));
    DrawText(TextClip, TitleFace^, TextLeft, Bar.Top + (RectangleHeight(Bar) - TitleFace^.Height) div 2, Window.Title,
      TextColor);
  end;
  DrawTitleButton(Canvas, Window, HitClose, Active);
  if HasSizeButtons(Window) then
  begin
    DrawTitleButton(Canvas, Window, HitMaximize, Active);
    DrawTitleButton(Canvas, Window, HitMinimize, Active);
  end;
end;

function HitTest(Window: TServerWindow; X, Y: LongInt): THitArea;
var
  Frame: TRectangle;
  Corner: LongInt;
  Border: LongInt;
  Left: Boolean;
  Right: Boolean;
  Top: Boolean;
  Bottom: Boolean;
begin
  Frame := FrameRectangle(Window);
  if not RectangleContainsPoint(Frame, X, Y) then
    Exit(HitNothing);
  if RectangleContainsPoint(ClientRectangle(Window), X, Y) then
    Exit(HitClient);
  if not IsFramed(Window) then
    Exit(HitNothing);
  if RectangleContainsPoint(TitleButtonRectangle(Window, HitClose), X, Y) then
    Exit(HitClose);
  if HasSizeButtons(Window) then
  begin
    if RectangleContainsPoint(TitleButtonRectangle(Window, HitMaximize), X, Y) then
      Exit(HitMaximize);
    if RectangleContainsPoint(TitleButtonRectangle(Window, HitMinimize), X, Y) then
      Exit(HitMinimize);
  end;
  Border := WindowMetric(Window, Theme.BorderWidth);
  if HasSizeButtons(Window) and not Window.Maximized then
  begin
    { The corners reach a title bar's height along each edge. }
    Corner := WindowMetric(Window, Theme.TitleHeight);
    Left := X < Frame.Left + Border;
    Right := X >= Frame.Right - Border;
    Top := Y < Frame.Top + Border;
    Bottom := Y >= Frame.Bottom - Border;
    if (Left or Right) and (Y < Frame.Top + Corner) then
      Top := True;
    if (Left or Right) and (Y >= Frame.Bottom - Corner) then
      Bottom := True;
    if (Top or Bottom) and (X < Frame.Left + Corner) then
      Left := True;
    if (Top or Bottom) and (X >= Frame.Right - Corner) then
      Right := True;
    if Top and Left then
      Exit(HitTopLeft);
    if Top and Right then
      Exit(HitTopRight);
    if Bottom and Left then
      Exit(HitBottomLeft);
    if Bottom and Right then
      Exit(HitBottomRight);
    if Left then
      Exit(HitLeft);
    if Right then
      Exit(HitRight);
    if Top then
      Exit(HitTop);
    if Bottom then
      Exit(HitBottom);
  end;
  Result := HitTitle;
end;

end.
