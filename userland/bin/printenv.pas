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
  printenv - print all or part of environment

  printenv [-0] [VARIABLE]...

  Exits with 1 if a named variable is not set.
}
program printenv;

{$mode objfpc}{$H+}
{$pointermath on}

uses
  Sys.Environment,
  Util.CommandLine,
  Util.Output;

const
  Usage = 'Usage: printenv [OPTION]... [VARIABLE]...'#10 +
    'Print the values of the specified environment VARIABLE(s).'#10 +
    'If no VARIABLE is specified, print name and value pairs for them all.'#10#10 +
    '  -0, --null     end each output line with NUL, not newline'#10;

  OptionNull = 1;

var
  CommandLine: TCommandLine;
  Code: Integer;
  Value: string;
  LineEnd: Char;
  Index: Integer;
  Block: PPChar;
  Operand: string;
  VariableValue: string;
  ExitStatus: LongInt;
begin
  LineEnd := #10;
  CommandLine := TCommandLine.Create([CommandOption('0', 'null', False, OptionNull)], Usage);
  while CommandLine.NextOption(Code, Value) do
    LineEnd := #0;
  if CommandLine.OperandCount = 0 then
  begin
    Block := EnvironmentBlock;
    Index := 0;
    while Block[Index] <> nil do
    begin
      PrintString(string(Block[Index]) + LineEnd);
      Inc(Index);
    end;
    Halt(0);
  end;
  ExitStatus := 0;
  for Operand in CommandLine.Operands do
  begin
    if not FindVariable(Operand, VariableValue) then
    begin
      ExitStatus := 1;
      Continue;
    end;
    PrintString(VariableValue + LineEnd);
  end;
  Halt(ExitStatus);
end.
