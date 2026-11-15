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
  displaymode [-d NUMBER] WIDTHxHEIGHT

  Without an operand: every display, a line each, with its size in
  pixels, its place and size on the desktop in logical units, its scale
  and DPI:

    display N: WxH, at L,T size LWxLH, scale P%, D DPI

  -l lists the modes of the display -d picks (0, the first, by default),
  the one it has marked with *. With a size: asks the display server to
  set that mode (one of the list) while windows are open, and prints the
  display's line then. The server keeps the windows on it in their
  places, moved onto it if it shrank, and the DPI follows the mode.
}
program ShowDisplayModes;

{$mode objfpc}

uses
  Abi.SystemCalls,
  Sys.Format,
  Sys.Streams,
  Sys.Text,
  Util.Messages,
  Util.Options,
  Windowing.Connection,
  Windowing.Displays;

const
  Usage: PChar = 'Usage: displaymode [-d NUMBER] [-l | WIDTHxHEIGHT]'#10 +
    'Show the displays, list a display''s modes, or set one, in the display server.'#10 +
    '  -d NUMBER  the display (0, the first, by default)'#10 +
    '  -l         list its modes'#10;
  OptionNumber = 1;
  OptionList = 2;

procedure SayDisplay(Number: LongInt; const Information: TDisplayInformation);
begin
  WriteFormatted(StandardOutput, 'display %d: %dx%d, at %d,%d size %dx%d, scale %u%%, %u DPI'#10,
    [ArgumentNumber(Number), ArgumentNumber(Information.Width), ArgumentNumber(Information.Height),
     ArgumentNumber(Information.Left), ArgumentNumber(Information.Top), ArgumentNumber(Information.LogicalWidth),
     ArgumentNumber(Information.LogicalHeight), ArgumentUnsigned(Information.ScalePercent),
     ArgumentUnsigned(Information.Dpi)]);
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
  Mark: PChar;
begin
  Index := 0;
  while DescribeDisplayMode(Number, Index, Width, Height, Current) do
  begin
    Mark := '';
    if Current then
      Mark := ' *';
    WriteFormatted(StandardOutput, '%dx%d%s'#10, [ArgumentNumber(Width), ArgumentNumber(Height), ArgumentText(Mark)]);
    Inc(Index);
  end;
end;

procedure ChangeMode(Number: LongInt; Width, Height: LongWord);
var
  Information: TDisplayInformation;
begin
  if not SetDisplayMode(Number, Width, Height, Information) then
    Fail(1, 'there is no display %d', [ArgumentNumber(Number)]);
  SayDisplay(Number, Information);
  if (Information.Width <> LongInt(Width)) or (Information.Height <> LongInt(Height)) then
    Fail(1, 'display %d cannot be set to %ux%u', [ArgumentNumber(Number), ArgumentUnsigned(Width),
      ArgumentUnsigned(Height)]);
end;

var
  Parser: TOptionParser;
  Code: Integer;
  OptionValue: PChar;
  Number: QWord;
  List: Boolean;
  Width: LongWord;
  Height: LongWord;
  Error: LongInt;
begin
  Number := 0;
  List := False;
  BeginOptions(Parser, [OptionDefinition('d', 'display', True, OptionNumber),
    OptionDefinition('l', 'list', False, OptionList)], Usage);
  while NextOption(Parser, Code, OptionValue) do
    case Code of
      OptionNumber:
        if not ParseUnsigned(OptionValue, Number) or (Number > 63) then
          FailWithUsageHint('the display must be a number', []);
      OptionList:
        List := True;
    end;
  if Parser.OperandCount > 1 then
    FailWithUsageHint('one mode at most', []);
  Width := 0;
  Height := 0;
  if (Parser.OperandCount = 1) and not ParseSize(Parser.Operands[0], Width, Height) then
    FailWithUsageHint('the mode must be WIDTHxHEIGHT', []);
  Error := ConnectToDisplay;
  if Error <> ErrorNone then
    FailWithError(1, Error, 'the display server', []);
  if Width > 0 then
    ChangeMode(LongInt(Number), Width, Height)
  else if List then
    ListModes(LongInt(Number))
  else
    SayEveryDisplay;
  FlushStream(StandardOutput);
  DisconnectFromDisplay;
end.
