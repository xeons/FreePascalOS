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
  displayscale - show or change a display's scale in the display server

  displayscale [-d NUMBER] [-r] [PERCENT]

  Without an operand: the display's scale and DPI. With one: asks the
  display server for that scale (100 to 400 percent) while windows are
  open; the server draws its frames and pointer on that display at it,
  and every window on it is laid out again at the same logical size. -d
  picks the display (0, the first, by default); -r (--remember) has the
  server keep the scale in the system's settings (Display/N/Scale) for
  the next time it starts. Prints the scale it is then:

    scale P%, D DPI
}
program ShowDisplayScale;

{$mode objfpc}
{$H+}

uses
  SysUtils,
  Abi.SystemCalls,
  Sys.Streams,
  Util.CommandLine,
  Util.Messages,
  Util.Numbers,
  Windowing.Connection,
  Windowing.Displays;

const
  Usage = 'Usage: displayscale [-d NUMBER] [-r] [PERCENT]'#10 +
    'Show a display''s scale in the display server, or change it (100 to 400 percent).'#10 +
    '  -d NUMBER       the display (0, the first, by default)'#10 +
    '  -r, --remember  keep the scale for the next time the server starts'#10;
  OptionNumber = 1;
  OptionRemember = 2;
  MinimumPercent = 100;
  MaximumPercent = 400;

procedure SayScale(const Information: TDisplayInformation);
begin
  PrintStringLine(Format('scale %u%%, %u DPI', [Information.ScalePercent, Information.Dpi]));
  FlushStream(StandardOutput);
end;

var
  CommandLine: TCommandLine;
  Code: Integer;
  OptionValue: string;
  Percent: Int64;
  Number: QWord;
  Error: LongInt;
  Information: TDisplayInformation;
  Answered: Boolean;
  Remember: Boolean;
begin
  Number := 0;
  Remember := False;
  CommandLine := TCommandLine.Create([CommandOption('d', 'display', True, OptionNumber),
    CommandOption('r', 'remember', False, OptionRemember)], Usage);
  while CommandLine.NextOption(Code, OptionValue) do
    if Code = OptionRemember then
      Remember := True
    else if Code = OptionNumber then
      if not ParseUnsignedDecimal(OptionValue, Number) or (Number > 63) then
        FailWithUsageHint('the display must be a number');
  if CommandLine.OperandCount > 1 then
    FailWithUsageHint('one scale at most');
  Percent := 0;
  if CommandLine.OperandCount = 1 then
    if not ParseDecimal(CommandLine.Operands[0], Percent) or (Percent < MinimumPercent)
      or (Percent > MaximumPercent) then
      FailWithUsageHint(Format('the scale must be a percentage from %d to %d', [MinimumPercent, MaximumPercent]));
  Error := ConnectToDisplay;
  if Error <> ErrorNone then
    FailWithError(1, Error, 'the display server');
  if Percent <> 0 then
    Answered := SetDisplayScale(LongInt(Number), LongWord(Percent), Information, Remember)
  else
    Answered := DescribeDisplay(LongInt(Number), Information);
  if not Answered then
    Fail(1, Format('there is no display %u', [Number]));
  SayScale(Information);
  DisconnectFromDisplay;
end.
