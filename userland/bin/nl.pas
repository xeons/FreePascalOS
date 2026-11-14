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
  nl - number lines of files

  nl [-b STYLE] [-i INCREMENT] [-s SEPARATOR] [-v START] [-w WIDTH] [FILE]...

  STYLE is a (all lines), t (non-empty lines, the default) or n (none).
}
program nl;

{$mode objfpc}
{$pointermath on}

uses
  Sys.Format,
  Sys.Memory,
  Sys.Streams,
  Sys.Text,
  Util.Input,
  Util.Messages,
  Util.Options;

const
  Usage: PChar = 'Usage: nl [OPTION]... [FILE]...'#10 +
    'Write each FILE to standard output, with line numbers added.'#10 +
    #10 +
    '  -b, --body-numbering=STYLE      use STYLE for numbering body lines'#10 +
    '  -i, --line-increment=NUMBER     line number increment at each line'#10 +
    '  -s, --number-separator=STRING   add STRING after (possible) line number'#10 +
    '  -v, --starting-line-number=NUMBER  first line number for each section'#10 +
    '  -w, --number-width=NUMBER       use NUMBER columns for line numbers'#10 +
    #10 +
    'STYLE is one of: a (number all lines), t (number only nonempty lines),'#10 +
    'n (number no lines).'#10;

  OptionStyle = 1;
  OptionIncrement = 2;
  OptionSeparator = 3;
  OptionStart = 4;
  OptionWidth = 5;

function ParseNumber(Text: PChar): Int64;
begin
  if not ParseInteger(Text, Result) then
    Fail(1, 'invalid number: ''%s''', [ArgumentText(Text)]);
end;

var
  Parser: TOptionParser;
  Code: Integer;
  Value: PChar;
  Style: Char;
  Increment: Int64;
  Separator: PChar;
  LineNumber: Int64;
  Width: Int64;
  Index: Integer;
  Stream: PInputStream;
  Line: PChar;
  HadLineEnd: Boolean;
  Numbered: Boolean;
  ExitStatus: LongInt;
begin
  Style := 't';
  Increment := 1;
  Separator := #9;
  LineNumber := 1;
  Width := 6;
  BeginOptions(Parser, [
    OptionDefinition('b', 'body-numbering', True, OptionStyle),
    OptionDefinition('i', 'line-increment', True, OptionIncrement),
    OptionDefinition('s', 'number-separator', True, OptionSeparator),
    OptionDefinition('v', 'starting-line-number', True, OptionStart),
    OptionDefinition('w', 'number-width', True, OptionWidth)], Usage);
  while NextOption(Parser, Code, Value) do
    case Code of
      OptionStyle:
        begin
          if not (Value[0] in ['a', 't', 'n']) or (Value[1] <> #0) then
            Fail(1, 'invalid body numbering style: ''%s''', [ArgumentText(Value)]);
          Style := Value[0];
        end;
      OptionIncrement: Increment := ParseNumber(Value);
      OptionSeparator: Separator := Value;
      OptionStart: LineNumber := ParseNumber(Value);
      OptionWidth: Width := ParseNumber(Value);
    end;

  if Parser.OperandCount = 0 then
  begin
    Parser.Operands[0] := '-';
    Parser.OperandCount := 1;
  end;
  ExitStatus := 0;
  for Index := 0 to Parser.OperandCount - 1 do
  begin
    Stream := OpenInput(Parser.Operands[Index]);
    if Stream = nil then
    begin
      ExitStatus := 1;
      Continue;
    end;
    while ReadLine(Stream, Line, HadLineEnd) do
    begin
      case Style of
        'a': Numbered := True;
        't': Numbered := Line^ <> #0;
      else
        Numbered := False;
      end;
      if Numbered then
      begin
        WriteFormatted(StandardOutput, '%*d%s', [ArgumentNumber(Width), ArgumentNumber(LineNumber),
          ArgumentText(Separator)]);
        LineNumber := LineNumber + Increment;
      end
      else
        WriteFormatted(StandardOutput, '%*s', [ArgumentNumber(Width + 1), ArgumentText('')]);
      WriteLine(StandardOutput, Line);
      FreeMemory(Line);
    end;
    CloseInput(Stream);
  end;
  Halt(ExitStatus);
end.
