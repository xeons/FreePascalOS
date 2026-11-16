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
  uniq - report or omit repeated lines

  uniq [-cdiu] [-f N] [-s N] [-w N] [INPUT [OUTPUT]]

  Only adjacent equal lines are merged, so input is usually sorted first.
}
program uniq;

{$mode objfpc}
{$H+}

uses
  SysUtils,
  Abi.SystemCalls,
  Sys.Errors,
  Sys.Files,
  Sys.Format,
  Sys.Memory,
  Sys.Streams,
  Sys.Text,
  Util.Input,
  Util.Messages,
  Util.Options;

const
  Usage: PChar = 'Usage: uniq [OPTION]... [INPUT [OUTPUT]]'#10 +
    'Filter adjacent matching lines from INPUT (or standard input),'#10 +
    'writing to OUTPUT (or standard output).'#10 +
    #10 +
    '  -c, --count           prefix lines by the number of occurrences'#10 +
    '  -d, --repeated        only print duplicate lines, one for each group'#10 +
    '  -f, --skip-fields=N   avoid comparing the first N fields'#10 +
    '  -i, --ignore-case     ignore differences in case when comparing'#10 +
    '  -s, --skip-chars=N    avoid comparing the first N characters'#10 +
    '  -u, --unique          only print unique lines'#10 +
    '  -w, --check-chars=N   compare no more than N characters in lines'#10;

  OptionCount = 1;
  OptionRepeated = 2;
  OptionSkipFields = 3;
  OptionIgnoreCase = 4;
  OptionSkipCharacters = 5;
  OptionUnique = 6;
  OptionCheckCharacters = 7;

var
  ShowCounts: Boolean;
  OnlyRepeated: Boolean;
  OnlyUnique: Boolean;
  IgnoreCase: Boolean;
  SkipFields: Int64;
  SkipCharacters: Int64;
  CheckCharacters: Int64;  { -1 = all }

{ The index (from 1) of the first character that takes part in comparisons. }
function ComparisonStart(const Line: string): Integer;
var
  Field: Int64;
begin
  Result := 1;
  Field := 0;
  while (Field < SkipFields) and (Result <= Length(Line)) do
  begin
    while (Result <= Length(Line)) and IsSpace(Line[Result]) do
      Inc(Result);
    while (Result <= Length(Line)) and not IsSpace(Line[Result]) do
      Inc(Result);
    Inc(Field);
  end;
  if SkipCharacters > Length(Line) - Result + 1 then
    Result := Length(Line) + 1
  else
    Inc(Result, SkipCharacters);
end;

{ The part of Line that is compared, case folded with -i. }
function ComparedPart(const Line: string): string;
var
  Start: Integer;
begin
  Start := ComparisonStart(Line);
  if CheckCharacters < 0 then
    Result := Copy(Line, Start, MaxInt)
  else if CheckCharacters > MaxInt then
    Result := Copy(Line, Start, MaxInt)
  else
    Result := Copy(Line, Start, CheckCharacters);
  if IgnoreCase then
    Result := LowerCase(Result);
end;

function LinesMatch(const First, Second: string): Boolean;
begin
  Result := ComparedPart(First) = ComparedPart(Second);
end;

procedure ParseCount(Text: PChar; out Value: Int64);
begin
  if not ParseInteger(Text, Value) or (Value < 0) then
    Fail(1, 'invalid number: ''%s''', [ArgumentText(Text)]);
end;

var
  Parser: TOptionParser;
  Code: Integer;
  Value: PChar;
  Input: PInputStream;
  Output: POutputStream;
  OutputHandle: Int64;
  Previous: string;
  HasPrevious: Boolean;
  LineText: PChar;
  Line: string;
  HadLineEnd: Boolean;
  RunLength: Int64;

procedure FlushRun;
begin
  if not HasPrevious then
    Exit;
  if (OnlyRepeated and (RunLength < 2)) or (OnlyUnique and (RunLength > 1)) then
    Exit;
  if ShowCounts then
    WriteFormatted(Output, '%7d ', [ArgumentNumber(RunLength)]);
  WriteLine(Output, PChar(Previous));
end;

begin
  CheckCharacters := -1;
  BeginOptions(Parser, [
    OptionDefinition('c', 'count', False, OptionCount),
    OptionDefinition('d', 'repeated', False, OptionRepeated),
    OptionDefinition('f', 'skip-fields', True, OptionSkipFields),
    OptionDefinition('i', 'ignore-case', False, OptionIgnoreCase),
    OptionDefinition('s', 'skip-chars', True, OptionSkipCharacters),
    OptionDefinition('u', 'unique', False, OptionUnique),
    OptionDefinition('w', 'check-chars', True, OptionCheckCharacters)], Usage);
  while NextOption(Parser, Code, Value) do
    case Code of
      OptionCount: ShowCounts := True;
      OptionRepeated: OnlyRepeated := True;
      OptionSkipFields: ParseCount(Value, SkipFields);
      OptionIgnoreCase: IgnoreCase := True;
      OptionSkipCharacters: ParseCount(Value, SkipCharacters);
      OptionUnique: OnlyUnique := True;
      OptionCheckCharacters: ParseCount(Value, CheckCharacters);
    end;
  if Parser.OperandCount > 2 then
    FailWithUsageHint('extra operand ''%s''', [ArgumentText(Parser.Operands[2])]);

  if Parser.OperandCount >= 1 then
    Input := OpenInput(Parser.Operands[0])
  else
    Input := StandardInput;
  if Input = nil then
    Halt(1);
  Output := StandardOutput;
  OutputHandle := -1;
  if Parser.OperandCount = 2 then
  begin
    OutputHandle := OpenFile(Parser.Operands[1], OpenWrite or OpenCreate or OpenTruncate);
    if OutputHandle < 0 then
      FailWithError(1, ErrorCodeOf(OutputHandle), '%s', [ArgumentText(Parser.Operands[1])]);
    Output := CreateOutputStream(OutputHandle);
  end;

  Previous := '';
  HasPrevious := False;
  RunLength := 0;
  while ReadLine(Input, LineText, HadLineEnd) do
  begin
    Line := LineText;
    FreeMemory(LineText);
    if HasPrevious and LinesMatch(Previous, Line) then
    begin
      Inc(RunLength);
      Continue;
    end;
    FlushRun;
    Previous := Line;
    HasPrevious := True;
    RunLength := 1;
  end;
  FlushRun;
  CloseInput(Input);
  if OutputHandle >= 0 then
  begin
    DestroyOutputStream(Output);
    CloseFile(OutputHandle);
  end;
end.
