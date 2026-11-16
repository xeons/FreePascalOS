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
  env - run a program in a modified environment

  env [-i] [-u NAME]... [NAME=VALUE]... [COMMAND [ARG]...]

  Without COMMAND, prints the resulting environment.
}
program env;

{$mode objfpc}{$H+}

uses
  SysUtils,
  StrUtils,
  Sys.Environment,
  Sys.Errors,
  Sys.Processes,
  Sys.Streams,
  Util.CommandLine,
  Util.Commands,
  Util.Messages,
  Util.Output;

const
  Usage = 'Usage: env [OPTION]... [-] [NAME=VALUE]... [COMMAND [ARG]...]'#10 +
    'Set each NAME to VALUE in the environment and run COMMAND.'#10 +
    #10 +
    '  -i, --ignore-environment  start with an empty environment'#10 +
    '  -u, --unset=NAME          remove variable from the environment'#10 +
    '  -0, --null                end each output line with NUL, not newline'#10;

  OptionIgnore = 1;
  OptionUnset = 2;
  OptionNull = 3;

procedure ClearEnvironment;
var
  Entry: string;
begin
  while EnvironmentCount > 0 do
  begin
    Entry := EnvironmentBlock[0];
    RemoveVariable(Copy(Entry, 1, Pos('=', Entry) - 1));
  end;
end;

{ Lets the option parser handle --help, --version and errors. }
procedure RejectOption(const Text: string);
var
  CommandLine: TCommandLine;
  Code: Integer;
  Value: string;
begin
  CommandLine := TCommandLine.Create([
    CommandOption('i', 'ignore-environment', False, OptionIgnore),
    CommandOption('u', 'unset', True, OptionUnset),
    CommandOption('0', 'null', False, OptionNull)], Usage);
  CommandLine.NextOption(Code, Value);
  FailWithUsageHint(Format('invalid option ''%s''', [Text]));
end;

procedure PrintEnvironment(LineEnd: Char);
var
  Block: PPChar;
  Index: Integer;
begin
  Block := EnvironmentBlock;
  Index := 0;
  while Block[Index] <> nil do
  begin
    PrintString(string(Block[Index]) + LineEnd);
    Inc(Index);
  end;
end;

var
  Arguments: TStringArray;
  CommandVector: TTextVector;
  LineEnd: Char;
  First: Integer;
  Text: string;
  EqualsPosition: Integer;
  ProgramPath: string;
  Status: LongInt;
begin
  LineEnd := #10;
  Arguments := ProgramArguments;
  { Options end at the first operand, so the command's own options are
    left alone: parse by hand up to it. }
  First := 0;
  while (First < Length(Arguments)) and (Length(Arguments[First]) >= 2) and (Arguments[First][1] = '-') do
  begin
    Text := Arguments[First];
    if Text = '--' then
    begin
      Inc(First);
      Break;
    end;
    if (Text = '-i') or (Text = '--ignore-environment') then
      ClearEnvironment
    else if (Text = '-u') and (First + 1 < Length(Arguments)) then
    begin
      Inc(First);
      RemoveVariable(Arguments[First]);
    end
    else if StartsStr('--unset=', Text) then
      RemoveVariable(Copy(Text, 9, MaxInt))
    else if (Text = '-0') or (Text = '--null') then
      LineEnd := #0
    else
      RejectOption(Text);
    Inc(First);
  end;
  if (First < Length(Arguments)) and (Arguments[First] = '-') then
  begin
    ClearEnvironment;
    Inc(First);
  end;

  while First < Length(Arguments) do
  begin
    EqualsPosition := Pos('=', Arguments[First]);
    if EqualsPosition <= 1 then
      Break;
    SetVariable(Copy(Arguments[First], 1, EqualsPosition - 1), Copy(Arguments[First], EqualsPosition + 1, MaxInt));
    Inc(First);
  end;

  if First >= Length(Arguments) then
  begin
    PrintEnvironment(LineEnd);
    Halt(0);
  end;

  if not FindProgramPath(Arguments[First], ProgramPath) then
  begin
    Report(Format('''%s'': No such file or directory', [Arguments[First]]));
    Halt(127);
  end;
  FlushStandardStreams;
  Arguments := Copy(Arguments, First, MaxInt);
  CommandVector := TextVector(Arguments);
  Status := RunProgram(PChar(ProgramPath), PPChar(@CommandVector[0]));
  if Status < 0 then
  begin
    ReportError(ErrorCodeOf(Status), Format('''%s''', [Arguments[0]]));
    Halt(126);
  end;
  Halt(Status);
end.
