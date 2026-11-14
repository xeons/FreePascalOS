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
  nohup - run a command immune to hangups

  nohup COMMAND [ARG]...

  There are no hangups to ignore on this system; what remains is the
  output handling: when standard output is the console, the command's
  output is appended to nohup.out instead, and standard error follows it.
}
program nohup;

{$mode objfpc}
{$pointermath on}

uses
  Abi.SystemCalls,
  Runtime.Text,
  Sys.Console,
  Sys.Environment,
  Sys.Errors,
  Sys.Files,
  Sys.Format,
  Sys.Processes,
  Sys.Streams,
  Util.Commands,
  Util.Messages,
  Util.Paths;

const
  Usage: PChar = 'Usage: nohup COMMAND [ARG]...'#10 +
    'Run COMMAND, ignoring hangup signals.'#10#10 +
    'If standard output is a terminal, append output to ''nohup.out'' if possible,'#10 +
    '''$HOME/nohup.out'' otherwise.'#10;

  StatusNohupFailed = 125;

var
  First: Integer;
  Options: TProcessOptions;
  OutputHandle: Int64;
  HomePath: PChar;
  Path: PChar;
begin
  First := 1;
  if (ArgumentTotal > 1) and TextIsEqual(Argument(1), '--help') then
  begin
    Print(Usage);
    Halt(0);
  end;
  if (ArgumentTotal > 1) and TextIsEqual(Argument(1), '--') then
    Inc(First);
  if First >= ArgumentTotal then
  begin
    Report('missing operand', []);
    Halt(StatusNohupFailed);
  end;

  DefaultProcessOptions(Options);
  if IsConsole(StandardOutputHandle) then
  begin
    Path := 'nohup.out';
    OutputHandle := OpenFile(Path, OpenWrite or OpenCreate or OpenAppend);
    if OutputHandle < 0 then
    begin
      HomePath := GetVariable('HOME');
      if HomePath = nil then
        HomePath := '/';
      Path := JoinPath(HomePath, 'nohup.out');
      OutputHandle := OpenFile(Path, OpenWrite or OpenCreate or OpenAppend);
    end;
    if OutputHandle < 0 then
      FailWithError(StatusNohupFailed, ErrorCodeOf(OutputHandle), 'failed to open ''nohup.out''', []);
    Report('ignoring input and appending output to ''%s''', [ArgumentText(Path)]);
    Options.OutputHandle := OutputHandle;
    if IsConsole(StandardErrorHandle) then
      Options.ErrorHandle := OutputHandle;
  end;
  RunCommandAndExit(ArgumentValues + First, Options);
end.
