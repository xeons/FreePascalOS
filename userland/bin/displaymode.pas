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
  displaymode - show the displays, list a display's modes, or set one,
  in the display server

  displaymode
  displaymode [-d NUMBER] -l
  displaymode [-d NUMBER] [-r] WIDTHxHEIGHT

  Without an operand: every display, a line each, with its size in
  pixels, its place and size on the desktop in logical units, its scale
  and DPI:

    display N: WxH, at L,T size LWxLH, scale P%, D DPI

  -l lists the modes of the display -d picks (0, the first, by default),
  the one it has marked with *. With a size: asks the display server to
  set that mode (one of the list) while windows are open, and prints the
  display's line then; -r (--remember) has the server keep it in the
  system's settings (Display/N/Mode) for the next time it starts. The server keeps the windows on it in their
  places, moved onto it if it shrank, and the DPI follows the mode.
}
program ShowDisplayModes;

{$mode objfpc}
{$H+}

uses
  SysUtils,
  Abi.SystemCalls,
  Sys.Streams,
  Sys.Text,
  Util.CommandLine,
  Util.Messages,
  Util.Numbers,
  Util.Output,
  Windowing.Connection,
  Windowing.Displays;

const
  Usage = 'Usage: displaymode [-d NUMBER] [-l | [-r] WIDTHxHEIGHT]'#10 +
    'Show the displays, list a display''s modes, or set one, in the display server.'#10 +
    '  -d NUMBER       the display (0, the first, by default)'#10 +
    '  -l              list its modes'#10 +
    '  -r, --remember  keep the mode for the next time the server starts'#10;
  OptionNumber = 1;
  OptionList = 2;
  OptionRemember = 3;

procedure SayDisplay(Number: LongInt; const Information: TDisplayInformation);
begin
  PrintStringLine(Format('display %d: %dx%d, at %d,%d size %dx%d, scale %u%%, %u DPI',
    [Number, Information.Width, Information.Height, Information.Left, Information.Top,
     Information.LogicalWidth, Information.LogicalHeight, Information.ScalePercent, Information.Dpi]));
  FlushStream(StandardOutput);
end;

procedure SayEveryDisplay;
var
  Number: LongInt;
  Information: TDisplayInformation;
begin
  Number := 0;
  while DescribeDisplay(Number, Information) do
  begin
    SayDisplay(Number, Information);
    Inc(Number);
  end;
end;

procedure ListModes(Number: LongInt);
var
  Index: LongInt;
  Width: LongInt;
  Height: LongInt;
  Current: Boolean;
  Mark: string;
begin
  Index := 0;
  while DescribeDisplayMode(Number, Index, Width, Height, Current) do
  begin
    Mark := '';
    if Current then
      Mark := ' *';
    PrintStringLine(Format('%dx%d%s', [Width, Height, Mark]));
    Inc(Index);
  end;
end;

procedure ChangeMode(Number: LongInt; Width, Height: LongWord; Remember: Boolean);
var
  Information: TDisplayInformation;
begin
  if not SetDisplayMode(Number, Width, Height, Information, Remember) then
    Fail(1, Format('there is no display %d', [Number]));
  SayDisplay(Number, Information);
  if (Information.Width <> LongInt(Width)) or (Information.Height <> LongInt(Height)) then
    Fail(1, Format('display %d cannot be set to %ux%u', [Number, Width, Height]));
end;

var
  CommandLine: TCommandLine;
  Code: Integer;
  OptionValue: string;
  Number: QWord;
  List: Boolean;
  Width: LongWord;
  Height: LongWord;
  Error: LongInt;
  Remember: Boolean;
begin
  Number := 0;
  List := False;
  Remember := False;
  CommandLine := TCommandLine.Create([CommandOption('d', 'display', True, OptionNumber),
    CommandOption('l', 'list', False, OptionList),
    CommandOption('r', 'remember', False, OptionRemember)], Usage);
  while CommandLine.NextOption(Code, OptionValue) do
    case Code of
      OptionNumber:
        if not ParseUnsignedDecimal(OptionValue, Number) or (Number > 63) then
          FailWithUsageHint('the display must be a number');
      OptionList:
        List := True;
      OptionRemember:
        Remember := True;
    end;
  if CommandLine.OperandCount > 1 then
    FailWithUsageHint('one mode at most');
  Width := 0;
  Height := 0;
  if (CommandLine.OperandCount = 1) and not ParseSize(PChar(CommandLine.Operands[0]), Width, Height) then
    FailWithUsageHint('the mode must be WIDTHxHEIGHT');
  Error := ConnectToDisplay;
  if Error <> ErrorNone then
    FailWithError(1, Error, 'the display server');
  if Width > 0 then
    ChangeMode(LongInt(Number), Width, Height, Remember)
  else if List then
    ListModes(LongInt(Number))
  else
    SayEveryDisplay;
  FlushStream(StandardOutput);
  DisconnectFromDisplay;
end.
