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
  seq - print a sequence of numbers

  seq [-s SEPARATOR] [-w] [FIRST [INCREMENT]] LAST

  Integers only. -w pads with leading zeros to equal width.
}
program seq;

{$mode objfpc}
{$H+}

uses
  SysUtils,
  Sys.Format,
  Sys.Streams,
  Sys.Text,
  Util.Messages,
  Util.Options;

const
  Usage: PChar = 'Usage: seq [OPTION]... LAST'#10 +
    '  or:  seq [OPTION]... FIRST LAST'#10 +
    '  or:  seq [OPTION]... FIRST INCREMENT LAST'#10 +
    'Print numbers from FIRST to LAST, in steps of INCREMENT.'#10 +
    #10 +
    '  -s, --separator=STRING   use STRING to separate numbers (default: \n)'#10 +
    '  -w, --equal-width        equalize width by padding with leading zeroes'#10;

  OptionSeparator = 1;
  OptionEqualWidth = 2;

function ParseNumber(Text: PChar): Int64;
begin
  if not ParseInteger(Text, Result) then
    FailWithUsageHint('invalid argument: ''%s''', [ArgumentText(Text)]);
end;

{ Value padded with zeros (after any sign) to Width characters. }
function ZeroPadded(Value: Int64; Width: Integer): string;
var
  Digits: string;
  Sign: string;
begin
  Digits := IntToStr(Value);
  Sign := '';
  if Value < 0 then
  begin
    Sign := '-';
    Delete(Digits, 1, 1);
  end;
  Result := Sign + StringOfChar('0', Width - Length(Sign) - Length(Digits)) + Digits;
end;

var
  Parser: TOptionParser;
  Code: Integer;
  Value: PChar;
  Separator: string;
  EqualWidth: Boolean;
  First: Int64;
  Increment: Int64;
  Last: Int64;
  Current: Int64;
  Width: Integer;
  IsFirstNumber: Boolean;
  Output: string;
begin
  Separator := #10;
  EqualWidth := False;
  BeginOptions(Parser, [
    OptionDefinition('s', 'separator', True, OptionSeparator),
    OptionDefinition('w', 'equal-width', False, OptionEqualWidth)], Usage);
  { "seq -5 5" counts from minus five. }
  Parser.NegativeNumbersAreOperands := True;
  while NextOption(Parser, Code, Value) do
    case Code of
      OptionSeparator: Separator := Value;
      OptionEqualWidth: EqualWidth := True;
    end;

  First := 1;
  Increment := 1;
  case Parser.OperandCount of
    1: Last := ParseNumber(Parser.Operands[0]);
    2:
      begin
        First := ParseNumber(Parser.Operands[0]);
        Last := ParseNumber(Parser.Operands[1]);
      end;
    3:
      begin
        First := ParseNumber(Parser.Operands[0]);
        Increment := ParseNumber(Parser.Operands[1]);
        Last := ParseNumber(Parser.Operands[2]);
      end;
  else
    if Parser.OperandCount = 0 then
      FailWithUsageHint('missing operand', [])
    else
      FailWithUsageHint('extra operand ''%s''', [ArgumentText(Parser.Operands[3])]);
  end;
  if Increment = 0 then
    FailWithUsageHint('invalid Zero increment value: ''%s''', [ArgumentText(Parser.Operands[1])]);

  { With -w every number is padded with zeros to the wider end. }
  Width := 0;
  if EqualWidth then
  begin
    Width := Length(IntToStr(First));
    if Length(IntToStr(Last)) > Width then
      Width := Length(IntToStr(Last));
  end;

  IsFirstNumber := True;
  Current := First;
  while ((Increment > 0) and (Current <= Last)) or ((Increment < 0) and (Current >= Last)) do
  begin
    Output := ZeroPadded(Current, Width);
    if not IsFirstNumber then
      Output := Separator + Output;
    WriteText(StandardOutput, PChar(Output));
    IsFirstNumber := False;
    Current := Current + Increment;
  end;
  if not IsFirstNumber then
    WriteCharacter(StandardOutput, #10);
end.
