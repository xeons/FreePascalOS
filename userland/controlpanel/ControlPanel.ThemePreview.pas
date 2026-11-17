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
  A small picture of a theme, for the Appearance page: a piece of its
  wallpaper with two windows on it - an inactive one behind, an active
  one in front with its title bar and buttons, a header band, a list
  with a selected line, a progress bar and a button - all drawn in the
  colours of the theme shown (not necessarily the one in use), in a
  sunken frame.
}
unit ControlPanel.ThemePreview;

{$mode objfpc}
{$H+}

interface

uses
  Drawing.Rectangles,
  Drawing.Canvas,
  Windowing.Theme,
  Controls.Base;

type
  TThemePreview = class(TControl)
  private
    FShown: TTheme;
    procedure DrawWindow(var Canvas: TCanvas; const Frame: TRectangle; Active: Boolean);
    procedure DrawTitleBar(var Canvas: TCanvas; const Bar: TRectangle; Active: Boolean);
    procedure DrawContents(var Canvas: TCanvas; const Client: TRectangle);
  public
    procedure Paint(var Canvas: TCanvas); override;
    { Shows Values from now on. }
    procedure ShowTheme(const Values: TTheme);
  end;

implementation

uses
  Drawing.Colors,
  Drawing.Bevels,
  Windowing.Connection,
  Controls.Text;

procedure TThemePreview.ShowTheme(const Values: TTheme);
begin
  FShown := Values;
  Invalidate;
end;

function RaisedOf(const Values: TTheme): TBevelColors;
begin
  Result := RaisedBevel(Values.Highlight, Values.Light, Values.Shadow, Values.DarkShadow);
end;

function SunkenOf(const Values: TTheme): TBevelColors;
begin
  Result := SunkenBevel(Values.Highlight, Values.Light, Values.Shadow, Values.DarkShadow);
end;

procedure TThemePreview.DrawTitleBar(var Canvas: TCanvas; const Bar: TRectangle; Active: Boolean);
var
  StartColor: TColor;
  EndColor: TColor;
  TextColor: TColor;
  ButtonFace: TColor;
  Button: TRectangle;
  Size: LongInt;
  Index: LongInt;
begin
  if Active then
  begin
    StartColor := FShown.ActiveTitleStart;
    EndColor := FShown.ActiveTitleEnd;
    TextColor := FShown.ActiveTitleText;
    ButtonFace := FShown.TitleButtonFace;
  end
  else
  begin
    StartColor := FShown.InactiveTitleStart;
    EndColor := FShown.InactiveTitleEnd;
    TextColor := FShown.InactiveTitleText;
    ButtonFace := FShown.InactiveTitleButtonFace;
  end;
  if FShown.TitleGradientVertical then
    FillVerticalGradient(Canvas, Bar, StartColor, EndColor)
  else
    FillHorizontalGradient(Canvas, Bar, StartColor, EndColor);
  DrawTextInBox(Canvas, ControlBoldFace, 'Window', MakeRectangle(Bar.Left + Scaled(4), Bar.Top,
    RectangleWidth(Bar), RectangleHeight(Bar)), AlignTextLeft, TextColor);
  { Three buttons at the right. }
  Size := RectangleHeight(Bar) - Scaled(4);
  for Index := 1 to 3 do
  begin
    Button := MakeRectangle(Bar.Right - Scaled(2) - Index * (Size + Scaled(2)), Bar.Top + Scaled(2), Size, Size);
    FillRectangle(Canvas, Button, ButtonFace);
    if FShown.TintedTitleButtons and (FShown.TitleButtonFrame <> ColorTransparent) then
      DrawRectangleOutline(Canvas, Button, FShown.TitleButtonFrame)
    else
      DrawBevel(Canvas, Button, RaisedOf(FShown));
  end;
end;

procedure TThemePreview.DrawContents(var Canvas: TCanvas; const Client: TRectangle);
var
  Band: TRectangle;
  List: TRectangle;
  Row: TRectangle;
  Progress: TRectangle;
  Button: TRectangle;
  Line: LongInt;
  X: LongInt;
begin
  Line := Scaled(14);
  { A header band (or a plain heading). }
  Band := MakeRectangle(Client.Left + Scaled(4), Client.Top + Scaled(4), RectangleWidth(Client) - Scaled(8), Line);
  if FShown.BandedGroupBoxes then
  begin
    FillVerticalGradient(Canvas, Band, FShown.HeaderBandStart, FShown.HeaderBandEnd);
    DrawTextInBox(Canvas, ControlBoldFace, ' Section', Band, AlignTextLeft, FShown.HeaderBandText);
  end
  else
    DrawTextInBox(Canvas, ControlFace, 'Section', Band, AlignTextLeft, FShown.FaceText);
  { A list with its second line selected. }
  List := MakeRectangle(Band.Left, Band.Bottom + Scaled(4), RectangleWidth(Band) div 2, 3 * Line + Scaled(4));
  FillRectangle(Canvas, List, FShown.Field);
  DrawBevel(Canvas, List, SunkenOf(FShown));
  Row := MakeRectangle(List.Left + Scaled(2), List.Top + Scaled(2), RectangleWidth(List) - Scaled(4), Line);
  DrawTextInBox(Canvas, ControlFace, ' Item', Row, AlignTextLeft, FShown.FieldText);
  Row := OffsetRectangle(Row, 0, Line);
  FillRectangle(Canvas, Row, FShown.Selection);
  DrawTextInBox(Canvas, ControlFace, ' Chosen', Row, AlignTextLeft, FShown.SelectionText);
  { A progress bar and a button beside it. }
  Progress := MakeRectangle(List.Right + Scaled(6), List.Top, Band.Right - List.Right - Scaled(6), Line);
  FillRectangle(Canvas, Progress, FShown.ProgressTrough);
  DrawEdge(Canvas, Progress, FShown.Shadow, FShown.Highlight);
  X := Progress.Left + Scaled(2);
  while X + Scaled(6) < Progress.Left + RectangleWidth(Progress) * 2 div 3 do
  begin
    FillVerticalGradient(Canvas, MakeRectangle(X, Progress.Top + Scaled(2), Scaled(6), Line - Scaled(4)),
      FShown.ProgressSegmentLight, FShown.ProgressSegmentDark);
    X := X + Scaled(8);
  end;
  Button := MakeRectangle(Progress.Left, List.Bottom - Line - Scaled(6), RectangleWidth(Progress), Line + Scaled(6));
  FillRectangle(Canvas, Button, FShown.Face);
  DrawBevel(Canvas, Button, RaisedOf(FShown));
  DrawTextInBox(Canvas, ControlFace, 'Button', Button, AlignTextCenter, FShown.FaceText);
end;

procedure TThemePreview.DrawWindow(var Canvas: TCanvas; const Frame: TRectangle; Active: Boolean);
var
  Bar: TRectangle;
  Client: TRectangle;
begin
  FillRectangle(Canvas, Frame, FShown.Face);
  DrawBevel(Canvas, Frame, RaisedOf(FShown));
  Bar := MakeRectangle(Frame.Left + Scaled(3), Frame.Top + Scaled(3), RectangleWidth(Frame) - Scaled(6), Scaled(18));
  DrawTitleBar(Canvas, Bar, Active);
  Client := MakeRectangle(Bar.Left, Bar.Bottom + Scaled(1), RectangleWidth(Bar), Frame.Bottom - Scaled(3) - Bar.Bottom
    - Scaled(1));
  if Active then
    DrawContents(Canvas, Client);
end;

procedure TThemePreview.Paint(var Canvas: TCanvas);
var
  Box: TRectangle;
  Inside: TRectangle;
  Width: LongInt;
  Height: LongInt;
begin
  Box := MakeRectangle(0, 0, RectangleWidth(PixelBounds), RectangleHeight(PixelBounds));
  Inside := InflateRectangle(Box, -2);
  FillVerticalGradient(Canvas, Inside, FShown.WallpaperTop, FShown.WallpaperBottom);
  Width := RectangleWidth(Inside);
  Height := RectangleHeight(Inside);
  DrawWindow(Canvas, MakeRectangle(Inside.Left + Width div 16, Inside.Top + Height div 12, Width * 5 div 8,
    Height div 2), False);
  DrawWindow(Canvas, MakeRectangle(Inside.Left + Width * 3 div 16, Inside.Top + Height * 3 div 12, Width * 3 div 4,
    Height * 2 div 3), True);
  DrawBevel(Canvas, Box, SunkenOf(Theme));
end;

end.
