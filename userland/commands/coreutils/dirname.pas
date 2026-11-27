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
  dirname - strip the last component from file names

  dirname NAME...

  Prints each NAME without its last component: "/usr/bin/" gives
  "/usr", and a NAME without a slash gives ".".
}
program dirname;

{$mode objfpc}{$H+}

uses
  Util.CommandLine,
  Util.Messages,
  Sys.Streams,
  Util.Paths;

const
  Usage = 'Usage: dirname [OPTION] NAME...'#10 +
    'Output each NAME with its last non-slash component and trailing slashes'#10 +
    'removed; if NAME contains no /''s, output ''.'' (meaning the current directory).'#10 +
    #10 +
    '  -z, --zero     end each output line with NUL, not newline'#10;

  OptionZero = 1;

var
  CommandLine: TCommandLine;
  Code: Integer;
  Value: string;
  LineEnd: Char;
  Operand: string;
begin
  LineEnd := #10;
  CommandLine := TCommandLine.Create([CommandOption('z', 'zero', False, OptionZero)], Usage);
  while CommandLine.NextOption(Code, Value) do
    if Code = OptionZero then
      LineEnd := #0;
  if CommandLine.OperandCount = 0 then
    FailWithUsageHint('missing operand');
  for Operand in CommandLine.Operands do
    PrintString(DirectoryName(Operand) + LineEnd);
  CommandLine.Free;
end.
