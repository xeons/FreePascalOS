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
  basename - strip directory and suffix from file names

  basename NAME [SUFFIX]
  basename -a [-s SUFFIX] NAME...

  Prints NAME without its leading directories. If SUFFIX is given and
  NAME ends with it (and is not just the suffix), it is removed too.
}
program basename;

{$mode objfpc}{$H+}

uses
  SysUtils,
  StrUtils,
  Util.CommandLine,
  Util.Messages,
  Sys.Streams,
  Util.Paths;

const
  Usage = 'Usage: basename NAME [SUFFIX]'#10 +
    '  or:  basename OPTION... NAME...'#10 +
    'Print NAME with any leading directory components removed.'#10 +
    #10 +
    '  -a, --multiple       support multiple arguments and treat each as a NAME'#10 +
    '  -s, --suffix=SUFFIX  remove a trailing SUFFIX; implies -a'#10 +
    '  -z, --zero           end each output line with NUL, not newline'#10;

  OptionMultiple = 1;
  OptionSuffix = 2;
  OptionZero = 3;

var
  Multiple: Boolean;
  Suffix: string;
  LineEnd: Char;

procedure PrintBaseName(const Name: string);
var
  Base: string;
begin
  Base := Util.Paths.BaseName(Name);
  if (Length(Suffix) < Length(Base)) and EndsStr(Suffix, Base) then
    SetLength(Base, Length(Base) - Length(Suffix));
  PrintString(Base + LineEnd);
end;

var
  CommandLine: TCommandLine;
  Code: Integer;
  Value: string;
  Operand: string;
begin
  Multiple := False;
  Suffix := '';
  LineEnd := #10;
  CommandLine := TCommandLine.Create([
    CommandOption('a', 'multiple', False, OptionMultiple),
    CommandOption('s', 'suffix', True, OptionSuffix),
    CommandOption('z', 'zero', False, OptionZero)], Usage);
  while CommandLine.NextOption(Code, Value) do
    case Code of
      OptionMultiple: Multiple := True;
      OptionSuffix:
        begin
          Suffix := Value;
          Multiple := True;
        end;
      OptionZero: LineEnd := #0;
    end;

  if CommandLine.OperandCount = 0 then
    FailWithUsageHint('missing operand');
  if not Multiple then
  begin
    if CommandLine.OperandCount > 2 then
      FailWithUsageHint(Format('extra operand ''%s''', [CommandLine.Operands[2]]));
    if CommandLine.OperandCount = 2 then
      Suffix := CommandLine.Operands[1];
    PrintBaseName(CommandLine.Operands[0]);
  end
  else
    for Operand in CommandLine.Operands do
      PrintBaseName(Operand);
  CommandLine.Free;
end.
