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
  display - show what the display is like, or fill it

  display
  display -f RRGGBB [-s SECONDS]

  Without options: the display's size, pixel format, physical size, DPI
  and scale. With -f: takes the screen from the text console, fills it
  with the colour (hexadecimal red, green, blue) with a white frame a
  quarter inch in from the edges (so it is the same size on any
  display), waits SECONDS (default 2) and gives the screen back.

  Only root may open the display.
}
program ShowDisplay;

{$mode objfpc}

uses
  Abi.SystemCalls,
  Sys.Display,
  Sys.Format,
  Sys.Kernel,
  Sys.Streams,
  Sys.Text,
  Util.Messages,
  Util.Options;

const
  Usage: PChar = 'Usage: display [-f RRGGBB [-s SECONDS]]'#10 +
    'Show what the display is like, or fill it with a colour.'#10 +
    '  -f RRGGBB   fill the screen with this colour'#10 +
    '  -s SECONDS  how long to show it (default 2)'#10;
  OptionFill = 1;
  OptionSeconds = 2;
  DefaultSeconds = 2;
  FrameColor = $FFFFFF;
  { A quarter inch, and the frame one point thick. }
  FrameInsetInches = 4;
  PointsPerInch = 72;

function FormatName(Format: LongWord): PChar;
begin
  if Format = DisplayFormatRedGreenBlue then
    Result := 'red-green-blue'
  else
    Result := 'blue-green-red';
end;

procedure DescribeDisplay(const Display: TDisplay);
begin
  WriteFormatted(StandardOutput, '%ux%u pixels, %u bytes a line, %s'#10,
    [ArgumentUnsigned(Display.Width), ArgumentUnsigned(Display.Height), ArgumentUnsigned(Display.Pitch),
     ArgumentText(FormatName(Display.Format))]);
  if Display.WidthMillimetres > 0 then
    WriteFormatted(StandardOutput, '%ux%u mm'#10, [ArgumentUnsigned(Display.WidthMillimetres),
      ArgumentUnsigned(Display.HeightMillimetres)]);
  WriteFormatted(StandardOutput, '%u DPI, scale %u%%'#10, [ArgumentUnsigned(Display.Dpi),
    ArgumentUnsigned(Display.ScalePercent)]);
end;

procedure FillRectangle(const Display: TDisplay; Left, Top, Width, Height: LongWord; Pixel: LongWord);
var
  Row: LongWord;
  Column: LongWord;
  Line: PLongWord;
begin
  if (Width = 0) or (Height = 0) then
    Exit;
  for Row := Top to Top + Height - 1 do
  begin
    Line := PLongWord(PByte(Display.Pixels) + QWord(Row) * Display.Pitch);
    for Column := Left to Left + Width - 1 do
      Line[Column] := Pixel;
  end;
end;

procedure FillDisplay(const Display: TDisplay; Color: LongWord);
var
  Inset: LongWord;
  Thickness: LongWord;
  Frame: LongWord;
begin
  FillRectangle(Display, 0, 0, Display.Width, Display.Height, DisplayPixel(Display, Color));
  Inset := Display.Dpi div FrameInsetInches;
  Thickness := (Display.Dpi + PointsPerInch - 1) div PointsPerInch;
  if (2 * (Inset + Thickness) >= Display.Width) or (2 * (Inset + Thickness) >= Display.Height) then
    Exit;
  Frame := DisplayPixel(Display, FrameColor);
  FillRectangle(Display, Inset, Inset, Display.Width - 2 * Inset, Thickness, Frame);
  FillRectangle(Display, Inset, Display.Height - Inset - Thickness, Display.Width - 2 * Inset, Thickness, Frame);
  FillRectangle(Display, Inset, Inset, Thickness, Display.Height - 2 * Inset, Frame);
  FillRectangle(Display, Display.Width - Inset - Thickness, Inset, Thickness, Display.Height - 2 * Inset, Frame);
end;

var
  Parser: TOptionParser;
  Code: Integer;
  OptionValue: PChar;
  Fill: Boolean;
  Color: QWord;
  Seconds: QWord;
  Display: TDisplay;
  Error: LongInt;
begin
  Fill := False;
  Color := 0;
  Seconds := DefaultSeconds;
  BeginOptions(Parser, [OptionDefinition('f', 'fill', True, OptionFill),
    OptionDefinition('s', 'seconds', True, OptionSeconds)], Usage);
  while NextOption(Parser, Code, OptionValue) do
    case Code of
      OptionFill:
        begin
          if not ParseHexadecimal(OptionValue, Color) or (Color > $FFFFFF) then
            FailWithUsageHint('the colour must be six hexadecimal digits (RRGGBB)', []);
          Fill := True;
        end;
      OptionSeconds:
        if not ParseUnsigned(OptionValue, Seconds) then
          FailWithUsageHint('the time must be a whole number of seconds', []);
    end;
  if Parser.OperandCount <> 0 then
    FailWithUsageHint('no operands are taken', []);
  Error := OpenDisplay(Display);
  if Error <> ErrorNone then
    FailWithError(1, Error, '/dev/display', []);
  if Fill then
  begin
    FillDisplay(Display, LongWord(Color));
    KernelSleep(Seconds * 1000);
  end;
  CloseDisplay(Display);
  if not Fill then
    DescribeDisplay(Display);
end.
