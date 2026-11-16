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
  display - show what a display is like, list its modes, or fill it

  display [-d NUMBER] [-l] [-m WIDTHxHEIGHT] [-f RRGGBB [-s SECONDS]]

  Without options: the display's size, pixel format, physical size, DPI
  and scale. -d picks a display (0, the console's, by default; 1 is
  /dev/display1). -l lists the modes it can be set to, one a line
  ("1024x768", the one it has marked with *). -m sets a mode for as long
  as the program has the display (what it says and draws is at that
  mode; closing gives back the mode there was). With -f: takes the
  screen (from the text console, for display 0), fills it with the
  colour (hexadecimal red, green, blue) with a white frame a quarter
  inch in from the edges (so it is the same size on any display), waits
  SECONDS (default 2) and gives the screen back.

  Only root may open a display.
}
program ShowDisplay;

{$mode objfpc}
{$H+}

uses
  SysUtils,
  Abi.SystemCalls,
  Sys.Display,
  Sys.Kernel,
  Util.CommandLine,
  Util.Messages,
  Util.Numbers,
  Util.Output;

const
  Usage = 'Usage: display [-d NUMBER] [-l] [-m WIDTHxHEIGHT] [-f RRGGBB [-s SECONDS]]'#10 +
    'Show what a display is like, list its modes, or fill it with a colour.'#10 +
    '  -d NUMBER         the display (0, the first, by default)'#10 +
    '  -l                list the modes it can be set to'#10 +
    '  -m WIDTHxHEIGHT   set this mode while the program runs'#10 +
    '  -f RRGGBB         fill the screen with this colour'#10 +
    '  -s SECONDS        how long to show it (default 2)'#10;
  OptionFill = 1;
  OptionSeconds = 2;
  OptionNumber = 3;
  OptionList = 4;
  OptionMode = 5;
  DefaultSeconds = 2;
  FrameColor = $FFFFFF;
  { A quarter inch, and the frame one point thick. }
  FrameInsetInches = 4;
  PointsPerInch = 72;

function FormatName(Format: LongWord): string;
begin
  if Format = DisplayFormatRedGreenBlue then
    Result := 'red-green-blue'
  else
    Result := 'blue-green-red';
end;

procedure DescribeDisplay(const Display: TDisplay);
begin
  PrintStringLine(Format('%ux%u pixels, %u bytes a line, %s',
    [Display.Width, Display.Height, Display.Pitch, FormatName(Display.Format)]));
  if Display.WidthMillimetres > 0 then
    PrintStringLine(Format('%ux%u mm', [Display.WidthMillimetres, Display.HeightMillimetres]));
  PrintStringLine(Format('%u DPI, scale %u%%', [Display.Dpi, Display.ScalePercent]));
end;

procedure ListModes(const Display: TDisplay);
var
  Index: LongInt;
  Width: LongWord;
  Height: LongWord;
  Mark: string;
begin
  for Index := 0 to DisplayModeCount(Display) - 1 do
    if DisplayModeAt(Display, Index, Width, Height) then
    begin
      Mark := '';
      if (Width = Display.Width) and (Height = Display.Height) then
        Mark := ' *';
      PrintStringLine(Format('%ux%u%s', [Width, Height, Mark]));
    end;
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
  CommandLine: TCommandLine;
  Code: Integer;
  OptionValue: string;
  Fill: Boolean;
  Color: QWord;
  Seconds: QWord;
  Display: TDisplay;
  Error: LongInt;
  Number: QWord;
  List: Boolean;
  ModeWidth: LongWord;
  ModeHeight: LongWord;
begin
  Fill := False;
  Color := 0;
  Seconds := DefaultSeconds;
  Number := 0;
  List := False;
  ModeWidth := 0;
  ModeHeight := 0;
  CommandLine := TCommandLine.Create([CommandOption('f', 'fill', True, OptionFill),
    CommandOption('s', 'seconds', True, OptionSeconds), CommandOption('d', 'display', True, OptionNumber),
    CommandOption('l', 'list', False, OptionList), CommandOption('m', 'mode', True, OptionMode)], Usage);
  while CommandLine.NextOption(Code, OptionValue) do
    case Code of
      OptionFill:
        begin
          if not ParseHexadecimalDigits(OptionValue, Color) or (Color > $FFFFFF) then
            FailWithUsageHint('the colour must be six hexadecimal digits (RRGGBB)');
          Fill := True;
        end;
      OptionSeconds:
        if not ParseUnsignedDecimal(OptionValue, Seconds) then
          FailWithUsageHint('the time must be a whole number of seconds');
      OptionNumber:
        if not ParseUnsignedDecimal(OptionValue, Number) or (Number > 63) then
          FailWithUsageHint('the display must be a number');
      OptionList:
        List := True;
      OptionMode:
        if not ParseWidthAndHeight(OptionValue, ModeWidth, ModeHeight) then
          FailWithUsageHint('the mode must be WIDTHxHEIGHT');
    end;
  if CommandLine.OperandCount <> 0 then
    FailWithUsageHint('no operands are taken');
  Error := OpenDisplay(Display, LongInt(Number));
  if Error <> ErrorNone then
    FailWithError(1, Error, Format('display %u', [Number]));
  if ModeWidth > 0 then
  begin
    Error := SetDisplayMode(Display, ModeWidth, ModeHeight);
    if Error <> ErrorNone then
    begin
      CloseDisplay(Display);
      FailWithError(1, Error, Format('the mode %ux%u', [ModeWidth, ModeHeight]));
    end;
  end;
  if Fill then
  begin
    FillDisplay(Display, LongWord(Color));
    KernelSleep(Seconds * 1000);
  end;
  if List then
    ListModes(Display);
  CloseDisplay(Display);
  if not Fill and not List then
    DescribeDisplay(Display);
end.
