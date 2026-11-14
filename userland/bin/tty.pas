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

  The only terminal is the console, /dev/console.
}
program tty;

{$mode objfpc}

uses
  Abi.SystemCalls,
  Sys.Console,
  Sys.Streams,
  Util.Options;

const
  Usage: PChar = 'Usage: tty [OPTION]...'#10 +
    'Print the file name of the terminal connected to standard input.'#10#10 +
    '  -s, --silent, --quiet   print nothing, only return an exit status'#10;

  OptionSilent = 1;

var
  Parser: TOptionParser;
  Code: Integer;
  Value: PChar;
  Silent: Boolean;
begin
  Silent := False;
  BeginOptions(Parser, [
    OptionDefinition('s', 'silent', False, OptionSilent),
    OptionDefinition(#0, 'quiet', False, OptionSilent)], Usage);
  while NextOption(Parser, Code, Value) do
    Silent := True;
  if IsConsole(StandardInputHandle) then
  begin
    if not Silent then
      PrintLine('/dev/console');
    Halt(0);
  end;
  if not Silent then
    PrintLine('not a tty');
  Halt(1);
end.
