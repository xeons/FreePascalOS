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
{$pointermath on}

uses
  Abi.SystemCalls,
  Runtime.Text,
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

function ComparisonStart(Line: PChar): PChar;
var
  Field: Int64;
  Skipped: Int64;
begin
  Result := Line;
  Field := 0;
  while (Field < SkipFields) and (Result^ <> #0) do
  begin
    while (Result^ <> #0) and IsSpace(Result^) do
      Inc(Result);
    while (Result^ <> #0) and not IsSpace(Result^) do
      Inc(Result);
    Inc(Field);
  end;
  Skipped := 0;
  while (Skipped < SkipCharacters) and (Result^ <> #0) do
  begin
    Inc(Result);
    Inc(Skipped);
  end;
end;

function LinesMatch(First, Second: PChar): Boolean;
var
  Left: PChar;
  Right: PChar;
  Compared: Int64;
  LeftCharacter: Char;
  RightCharacter: Char;
begin
  Left := ComparisonStart(First);
  Right := ComparisonStart(Second);
  Compared := 0;
  while (CheckCharacters < 0) or (Compared < CheckCharacters) do
  begin
    LeftCharacter := Left^;
    RightCharacter := Right^;
    if IgnoreCase then
    begin
      LeftCharacter := ToLowerCase(LeftCharacter);
      RightCharacter := ToLowerCase(RightCharacter);
    end;
    if LeftCharacter <> RightCharacter then
      Exit(False);
    if LeftCharacter = #0 then
      Break;
    Inc(Left);
    Inc(Right);
    Inc(Compared);
  end;
  Result := True;
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
  Previous: PChar;
  Line: PChar;
  HadLineEnd: Boolean;
  RunLength: Int64;

procedure FlushRun;
begin
  if Previous = nil then
    Exit;
  if (OnlyRepeated and (RunLength < 2)) or (OnlyUnique and (RunLength > 1)) then
    Exit;
  if ShowCounts then
    WriteFormatted(Output, '%7d ', [ArgumentNumber(RunLength)]);
  WriteLine(Output, Previous);
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

  Previous := nil;
  RunLength := 0;
  while ReadLine(Input, Line, HadLineEnd) do
  begin
    if (Previous <> nil) and LinesMatch(Previous, Line) then
    begin
      Inc(RunLength);
      FreeMemory(Line);
      Continue;
    end;
    FlushRun;
    FreeMemory(Previous);
    Previous := Line;
    RunLength := 1;
  end;
  FlushRun;
  FreeMemory(Previous);
  CloseInput(Input);
  if OutputHandle >= 0 then
  begin
    DestroyOutputStream(Output);
    CloseFile(OutputHandle);
  end;
end.
