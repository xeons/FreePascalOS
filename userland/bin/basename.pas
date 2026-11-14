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

{$mode objfpc}
{$pointermath on}

uses
  Sys.Format,
  Runtime.Text,
  Sys.Streams,
  Sys.Text,
  Util.Messages,
  Util.Options,
  Util.Paths;

const
  Usage: PChar = 'Usage: basename NAME [SUFFIX]'#10 +
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
  Parser: TOptionParser;
  Code: Integer;
  Value: PChar;
  Multiple: Boolean;
  Suffix: PChar;
  LineEnd: Char;

procedure PrintBaseName(Name: PChar);
var
  Base: PChar;
  BaseLength: PtrUInt;
  SuffixLength: PtrUInt;
begin
  Base := Util.Paths.BaseName(Name);
  if Suffix <> nil then
  begin
    BaseLength := TextLength(Base);
    SuffixLength := TextLength(Suffix);
    if (SuffixLength < BaseLength) and TextEndsWith(Base, Suffix) then
      Base[BaseLength - SuffixLength] := #0;
  end;
  WriteText(StandardOutput, Base);
  WriteCharacter(StandardOutput, LineEnd);
end;

var
  Index: Integer;
begin
  Multiple := False;
  Suffix := nil;
  LineEnd := #10;
  BeginOptions(Parser, [
    OptionDefinition('a', 'multiple', False, OptionMultiple),
    OptionDefinition('s', 'suffix', True, OptionSuffix),
    OptionDefinition('z', 'zero', False, OptionZero)], Usage);
  while NextOption(Parser, Code, Value) do
    case Code of
      OptionMultiple: Multiple := True;
      OptionSuffix:
        begin
          Suffix := Value;
          Multiple := True;
        end;
      OptionZero: LineEnd := #0;
    end;

  if Parser.OperandCount = 0 then
    FailWithUsageHint('missing operand', []);
  if not Multiple then
  begin
    if Parser.OperandCount > 2 then
      FailWithUsageHint('extra operand ''%s''', [ArgumentText(Parser.Operands[2])]);
    if Parser.OperandCount = 2 then
      Suffix := Parser.Operands[1];
    PrintBaseName(Parser.Operands[0]);
  end
  else
    for Index := 0 to Parser.OperandCount - 1 do
      PrintBaseName(Parser.Operands[Index]);
end.
