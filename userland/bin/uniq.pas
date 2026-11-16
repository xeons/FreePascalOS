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
  Sys.Streams,
  Sys.Text,
  Util.CommandLine,
  Util.Input,
  Util.Messages,
  Util.Numbers,
  Util.Output;

const
  Usage = 'Usage: uniq [OPTION]... [INPUT [OUTPUT]]'#10 +
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

procedure ParseCount(const Text: string; out Value: Int64);
begin
  if not ParseDecimal(Text, Value) or (Value < 0) then
    Fail(1, Format('invalid number: ''%s''', [Text]));
end;

var
  CommandLine: TCommandLine;
  Code: Integer;
  Value: string;
  Input: PInputStream;
  Output: POutputStream;
  OutputHandle: Int64;
  Previous: string;
  HasPrevious: Boolean;
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
    WriteString(Output, Format('%7d ', [RunLength]));
  WriteStringLine(Output, Previous);
end;

begin
  CheckCharacters := -1;
  CommandLine := TCommandLine.Create([
    CommandOption('c', 'count', False, OptionCount),
    CommandOption('d', 'repeated', False, OptionRepeated),
    CommandOption('f', 'skip-fields', True, OptionSkipFields),
    CommandOption('i', 'ignore-case', False, OptionIgnoreCase),
    CommandOption('s', 'skip-chars', True, OptionSkipCharacters),
    CommandOption('u', 'unique', False, OptionUnique),
    CommandOption('w', 'check-chars', True, OptionCheckCharacters)], Usage);
  while CommandLine.NextOption(Code, Value) do
    case Code of
      OptionCount: ShowCounts := True;
      OptionRepeated: OnlyRepeated := True;
      OptionSkipFields: ParseCount(Value, SkipFields);
      OptionIgnoreCase: IgnoreCase := True;
      OptionSkipCharacters: ParseCount(Value, SkipCharacters);
      OptionUnique: OnlyUnique := True;
      OptionCheckCharacters: ParseCount(Value, CheckCharacters);
    end;
  if CommandLine.OperandCount > 2 then
    FailWithUsageHint(Format('extra operand ''%s''', [CommandLine.Operands[2]]));

  if CommandLine.OperandCount >= 1 then
    Input := OpenInput(CommandLine.Operands[0])
  else
    Input := StandardInput;
  if Input = nil then
    Halt(1);
  Output := StandardOutput;
  OutputHandle := -1;
  if CommandLine.OperandCount = 2 then
  begin
    OutputHandle := OpenFile(PChar(CommandLine.Operands[1]), OpenWrite or OpenCreate or OpenTruncate);
    if OutputHandle < 0 then
      FailWithError(1, ErrorCodeOf(OutputHandle), CommandLine.Operands[1]);
    Output := CreateOutputStream(OutputHandle);
  end;

  Previous := '';
  HasPrevious := False;
  RunLength := 0;
  while ReadTextLine(Input, Line, HadLineEnd) do
  begin
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
