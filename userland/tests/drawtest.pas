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
  drawtest - draw a sample window on the display

  drawtest [-s SECONDS]

  Takes the screen and draws a desktop with a window on it, using
  libdrawing and the interface's font (libfont): a raised frame, a title
  bar with a gradient and bold text, a sunken text box, a button with a
  focus frame. Everything is sized for the display: lengths are in
  logical units (1/96 inch) scaled by the display's scale, text in
  points at its DPI. Shows it SECONDS (default 2), then gives the
  screen back. Prints the pixel sizes of the faces it picked.

  Only root may open the display.
}
program DrawTest;

{$mode objfpc}{$H+}

uses
  SysUtils,
  Abi.SystemCalls,
  Sys.Display,
  Sys.Kernel,
  Sys.Streams,
  Util.CommandLine,
  Util.Messages,
  Util.Numbers,
  Drawing.Colors,
  Drawing.Rectangles,
  Drawing.Surfaces,
  Drawing.Canvas,
  Drawing.Bevels,
  Font.Faces,
  Font.Text,
  Font.Files;

const
  Usage: PChar = 'Usage: drawtest [-s SECONDS]'#10 +
    'Draw a sample window on the display.'#10 +
    '  -s SECONDS  how long to show it (default 2)'#10;
  OptionSeconds = 1;
  DefaultSeconds = 2;

  DesktopColor = $FF3A6EA5;
  FaceColor = $FFC8C4BC;
  HighlightColor = $FFFFFFFF;
  ShadowColor = $FF7C786F;
  DarkShadowColor = $FF34312C;
  TitleStartColor = $FF1C3F6E;
  TitleEndColor = $FF7FA6D6;
  TitleTextColor = $FFFFFFFF;
  TextColor = $FF000000;
  { Sizes in points (tenths). }
  TitlePoints = 90;
  TextPoints = 90;

var
  Scale: LongWord;

{ A length in logical units (1/96 inch) in pixels. }
function Scaled(Length: LongInt): LongInt;
begin
  Result := (Length * LongInt(Scale) + 50) div 100;
end;

function ScaledRectangle(Left, Top, Width, Height: LongInt): TRectangle;
begin
  Result := MakeRectangle(Scaled(Left), Scaled(Top), Scaled(Width), Scaled(Height));
end;

procedure DrawSample(const Canvas: TCanvas; const Display: TDisplay; Title, Text: PFontFace);
var
  Window: TRectangle;
  TitleBar: TRectangle;
  TextBox: TRectangle;
  Button: TRectangle;
  Raised: TBevelColors;
  Sunken: TBevelColors;
begin
  Raised := RaisedBevel(HighlightColor, FaceColor, ShadowColor, DarkShadowColor);
  Sunken := SunkenBevel(HighlightColor, FaceColor, ShadowColor, DarkShadowColor);
  FillRectangle(Canvas, MakeRectangle(0, 0, Display.Width, Display.Height), DesktopColor);
  Window := ScaledRectangle(80, 60, 400, 220);
  FillRectangle(Canvas, Window, FaceColor);
  DrawBevel(Canvas, Window, Raised);
  TitleBar := MakeRectangle(Window.Left + 3, Window.Top + 3, RectangleWidth(Window) - 6, Scaled(18));
  FillHorizontalGradient(Canvas, TitleBar, TitleStartColor, TitleEndColor);
  DrawText(Canvas, Title^, TitleBar.Left + Scaled(4), TitleBar.Top + (RectangleHeight(TitleBar) - Title^.Height) div 2,
    'Sample window', TitleTextColor);
  TextBox := ScaledRectangle(100, 110, 200, 22);
  FillRectangle(Canvas, TextBox, $FFFFFFFF);
  DrawBevel(Canvas, TextBox, Sunken);
  DrawText(Canvas, Text^, TextBox.Left + Scaled(4), TextBox.Top + (RectangleHeight(TextBox) - Text^.Height) div 2,
    'caf'#$C3#$A9' '#$E2#$82#$AC'5', TextColor);
  Button := ScaledRectangle(380, 240, 80, 26);
  DrawBevel(Canvas, Button, Raised);
  DrawText(Canvas, Text^, Button.Left + (RectangleWidth(Button) - MeasureText(Text^, 'OK')) div 2,
    Button.Top + (RectangleHeight(Button) - Text^.Height) div 2, 'OK', TextColor);
  DrawFocusFrame(Canvas, InflateRectangle(Button, -Scaled(4)), TextColor);
end;

var
  CommandLine: TCommandLine;
  Code: Integer;
  Value: string;
  Seconds: QWord;
  Display: TDisplay;
  Error: LongInt;
  Fonts: TFontSet;
  Title: PFontFace;
  Text: PFontFace;
  Screen: TSurface;
  Drawing: TSurface;
  Canvas: TCanvas;
begin
  Seconds := DefaultSeconds;
  CommandLine := TCommandLine.Create([CommandOption('s', 'seconds', True, OptionSeconds)], Usage);
  while CommandLine.NextOption(Code, Value) do
    if Code = OptionSeconds then
      if not ParseUnsignedDecimal(Value, Seconds) then
        FailWithUsageHint('the time must be a whole number of seconds');
  if CommandLine.OperandCount <> 0 then
    FailWithUsageHint('no operands are taken');
  CommandLine.Free;
  if not LoadFontFamily(DejaVuSansFamily, Fonts) then
    Fail(1, Format('no fonts in %s/%s', [FontDirectory, DejaVuSansFamily]));
  Error := OpenDisplay(Display);
  if Error <> ErrorNone then
    FailWithError(1, Error, '/dev/display');
  Scale := Display.ScalePercent;
  Title := SelectFace(Fonts, TitlePoints, Display.Dpi, True);
  Text := SelectFace(Fonts, TextPoints, Display.Dpi, False);
  Screen := SurfaceOnPixels(Display.Pixels, Display.Width, Display.Height, Display.Pitch);
  if Display.Format = DisplayFormatBlueGreenRed then
  begin
    BeginCanvas(Canvas, Screen);
    DrawSample(Canvas, Display, Title, Text);
  end
  else if CreateSurface(Drawing, Display.Width, Display.Height, ColorBlack) then
  begin
    BeginCanvas(Canvas, Drawing);
    DrawSample(Canvas, Display, Title, Text);
    CopySurfaceSwappingRedAndBlue(Drawing, Screen);
    FreeSurface(Drawing);
  end;
  FlushDisplay(Display, 0, 0, Display.Width, Display.Height);
  KernelSleep(Seconds * 1000);
  CloseDisplay(Display);
  WriteString(StandardOutput, Format('%u DPI: title %u px bold, text %u px'#10,
    [Display.Dpi, Title^.Size, Text^.Size]));
end.
