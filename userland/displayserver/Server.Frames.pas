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
  title bar (a gradient, the title, and the minimize, maximize and close
  buttons at its right end) above the client area. Sizes come from the
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
  Server.TitleButtons;

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
  Gap := WindowMetric(Window, 2);
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

procedure DrawGlyphLine(const Canvas: TCanvas; const Box: TRectangle; FromX, FromY, ToX, ToY, Thickness: LongInt);
var
  Offset: LongInt;
begin
  for Offset := 0 to Thickness - 1 do
    DrawLine(Canvas, Box.Left + FromX + Offset, Box.Top + FromY, Box.Left + ToX + Offset, Box.Top + ToY,
      Theme.FaceText);
end;

procedure DrawTitleButton(const Canvas: TCanvas; Window: TServerWindow; Button: THitArea);
var
  Box: TRectangle;
  Glyph: TRectangle;
  Thickness: LongInt;
  Size: LongInt;
  Pressed: Boolean;
begin
  Box := TitleButtonRectangle(Window, Button);
  Pressed := TitleButtonIsPressed(Window, Button);
  if TitleButtonIsHot(Window, Button) then
    FillRectangle(Canvas, Box, Theme.Light)
  else
    FillRectangle(Canvas, Box, Theme.Face);
  if Pressed then
    DrawBevel(Canvas, Box, SunkenBevel(Theme.Highlight, Theme.Light, Theme.Shadow, Theme.DarkShadow))
  else
    DrawBevel(Canvas, Box, RaisedBevel(Theme.Highlight, Theme.Light, Theme.Shadow, Theme.DarkShadow));
  Thickness := WindowMetric(Window, 1);
  if Thickness < 1 then
    Thickness := 1;
  { The glyph in a square in the middle; pressed, it moves as if pushed
    in. }
  Size := RectangleHeight(Box) - 2 * WindowMetric(Window, 4);
  Glyph := MakeRectangle(Box.Left + (RectangleWidth(Box) - Size) div 2, Box.Top + (RectangleHeight(Box) - Size) div 2,
    Size, Size);
  if Pressed then
    Glyph := OffsetRectangle(Glyph, Thickness, Thickness);
  case Button of
    HitClose:
      begin
        DrawGlyphLine(Canvas, Glyph, 0, 0, Size - Thickness, Size - 1, Thickness);
        DrawGlyphLine(Canvas, Glyph, Size - Thickness, 0, 0, Size - 1, Thickness);
      end;
    HitMaximize:
      begin
        DrawRectangleOutline(Canvas, Glyph, Theme.FaceText);
        FillRectangle(Canvas, MakeRectangle(Glyph.Left, Glyph.Top, Size, 2 * Thickness), Theme.FaceText);
      end;
    HitMinimize:
      FillRectangle(Canvas, MakeRectangle(Glyph.Left, Glyph.Bottom - 2 * Thickness, Size - Size div 4, 2 * Thickness),
        Theme.FaceText);
  end;
end;

procedure DrawFrame(const Canvas: TCanvas; Window: TServerWindow; Active: Boolean);
var
  Frame: TRectangle;
  Bar: TRectangle;
  TextColor: TColor;
  Client: TRectangle;
  TextClip: TCanvas;
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
  DrawBevel(Canvas, Frame, RaisedBevel(Theme.Highlight, Theme.Light, Theme.Shadow, Theme.DarkShadow));
  Bar := TitleBarRectangle(Window);
  if Active then
  begin
    FillHorizontalGradient(Canvas, Bar, Theme.ActiveTitleStart, Theme.ActiveTitleEnd);
    TextColor := Theme.ActiveTitleText;
  end
  else
  begin
    FillHorizontalGradient(Canvas, Bar, Theme.InactiveTitleStart, Theme.InactiveTitleEnd);
    TextColor := Theme.InactiveTitleText;
  end;
  TitleFace := WindowScreen(Window)^.TitleFace;
  if TitleFace <> nil then
  begin
    { The title stops before the buttons. }
    TextClip := Canvas;
    NarrowCanvasClip(TextClip, MakeRectangle(Bar.Left, Bar.Top,
      TitleButtonRectangle(Window, HitMinimize).Left - Bar.Left - WindowMetric(Window, 2), RectangleHeight(Bar)));
    DrawText(TextClip, TitleFace^, Bar.Left + WindowMetric(Window, Theme.TitleTextIndent),
      Bar.Top + (RectangleHeight(Bar) - TitleFace^.Height) div 2, Window.Title, TextColor);
  end;
  DrawTitleButton(Canvas, Window, HitClose);
  if HasSizeButtons(Window) then
  begin
    DrawTitleButton(Canvas, Window, HitMaximize);
    DrawTitleButton(Canvas, Window, HitMinimize);
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
