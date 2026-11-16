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
  tty - print the file name of the terminal connected to standard input

  tty [-s]

  The console is /dev/console; a pseudo-terminal (a terminal window's)
  is /dev/ptsN.
}
program tty;

{$mode objfpc}
{$H+}

uses
  Abi.SystemCalls,
  Sys.Console,
  Sys.PseudoTerminals,
  Sys.Streams,
  Util.CommandLine,
  Util.Output;

const
  Usage = 'Usage: tty [OPTION]...'#10 +
    'Print the file name of the terminal connected to standard input.'#10#10 +
    '  -s, --silent, --quiet   print nothing, only return an exit status'#10;

  OptionSilent = 1;

var
  Path: array[0..15] of Char;
  CommandLine: TCommandLine;
  Code: Integer;
  Value: string;
  Silent: Boolean;
begin
  Silent := False;
  CommandLine := TCommandLine.Create([
    CommandOption('s', 'silent', False, OptionSilent),
    CommandOption(#0, 'quiet', False, OptionSilent)], Usage);
  while CommandLine.NextOption(Code, Value) do
    Silent := True;
  if IsConsole(StandardInputHandle) then
  begin
    if Silent then
      Halt(0);
    if TerminalNumber(StandardInputHandle) >= 0 then
    begin
      PseudoTerminalPath(TerminalNumber(StandardInputHandle), @Path[0]);
      PrintStringLine(PChar(@Path[0]));
    end
    else
      PrintStringLine('/dev/console');
    Halt(0);
  end;
  if not Silent then
    PrintStringLine('not a tty');
  Halt(1);
end.
