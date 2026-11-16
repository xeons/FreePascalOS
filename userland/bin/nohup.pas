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
{$H+}

uses
  SysUtils,
  Abi.SystemCalls,
  Sys.Console,
  Sys.Environment,
  Sys.Errors,
  Sys.Files,
  Sys.Processes,
  Sys.Streams,
  Util.CommandLine,
  Util.Commands,
  Util.Messages;

const
  Usage = 'Usage: nohup COMMAND [ARG]...'#10 +
    'Run COMMAND, ignoring hangup signals.'#10#10 +
    'If standard output is a terminal, append output to ''nohup.out'' if possible,'#10 +
    '''$HOME/nohup.out'' otherwise.'#10;

  StatusNohupFailed = 125;
  OutputName = 'nohup.out';

{ $HOME/nohup.out, or /nohup.out when HOME is not set. }
function HomeOutputPath: string;
begin
  if not FindVariable('HOME', Result) then
    Result := '/';
  if (Result <> '') and (Result[Length(Result)] <> '/') then
    Result := Result + '/';
  Result := Result + OutputName;
end;

var
  Arguments: TStringArray;
  First: Integer;
  Options: TProcessOptions;
  OutputHandle: Int64;
  Path: string;
begin
  Arguments := ProgramArguments;
  First := 0;
  if (Length(Arguments) > 0) and (Arguments[0] = '--help') then
  begin
    PrintString(Usage);
    Halt(0);
  end;
  if (Length(Arguments) > 0) and (Arguments[0] = '--') then
    Inc(First);
  if First >= Length(Arguments) then
  begin
    Report('missing operand');
    Halt(StatusNohupFailed);
  end;

  DefaultProcessOptions(Options);
  if IsConsole(StandardOutputHandle) then
  begin
    Path := OutputName;
    OutputHandle := OpenFile(PChar(Path), OpenWrite or OpenCreate or OpenAppend);
    if OutputHandle < 0 then
    begin
      Path := HomeOutputPath;
      OutputHandle := OpenFile(PChar(Path), OpenWrite or OpenCreate or OpenAppend);
    end;
    if OutputHandle < 0 then
      FailWithError(StatusNohupFailed, ErrorCodeOf(OutputHandle), 'failed to open ''nohup.out''');
    Report(Format('ignoring input and appending output to ''%s''', [Path]));
    Options.OutputHandle := OutputHandle;
    if IsConsole(StandardErrorHandle) then
      Options.ErrorHandle := OutputHandle;
  end;
  RunCommandAndExit(Copy(Arguments, First, MaxInt), Options);
end.
