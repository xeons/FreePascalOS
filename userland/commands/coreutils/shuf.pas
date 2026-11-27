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
  shuf - generate random permutations

  shuf [-r] [-n COUNT] [-o FILE] [FILE]
  shuf -e [OPTION]... [ARG]...
  shuf -i LO-HI [OPTION]...

  Prints the lines (or arguments, or numbers) in random order; -n stops
  after COUNT, -r picks with repetition (forever unless -n is given).
}
program shuf;

{$mode objfpc}
{$H+}

uses
  SysUtils,
  Classes,
  Abi.SystemCalls,
  Crypto.Random,
  Sys.Errors,
  Sys.Files,
  Sys.Streams,
  Util.CommandLine,
  Util.Input,
  Util.Messages,
  Util.Numbers;

const
  Usage = 'Usage: shuf [OPTION]... [FILE]'#10 +
    '  or:  shuf -e [OPTION]... [ARG]...'#10 +
    '  or:  shuf -i LO-HI [OPTION]...'#10 +
    'Write a random permutation of the input lines to standard output.'#10#10 +
    '  -e, --echo                treat each ARG as an input line'#10 +
    '  -i, --input-range=LO-HI   treat each number LO through HI as an input line'#10 +
    '  -n, --head-count=COUNT    output at most COUNT lines'#10 +
    '  -o, --output=FILE         write result to FILE instead of standard output'#10 +
    '  -r, --repeat              output lines can be repeated'#10 +
    '  -z, --zero-terminated     line delimiter is NUL, not newline'#10;

  OptionEcho = 1;
  OptionRange = 2;
  OptionCount = 3;
  OptionOutput = 4;
  OptionRepeat = 5;
  OptionZero = 6;

  { Longest bound text before the dash of LO-HI. }
  MaximumBoundLength = 31;

var
  CommandLine: TCommandLine;
  EchoMode: Boolean;
  HasRange: Boolean;
  RangeText: string;
  Limit: Int64;
  OutputPath: string;
  Repeated: Boolean;
  LineEnd: Char;

procedure ReadOptions;
var
  Code: Integer;
  Value: string;
begin
  EchoMode := False;
  HasRange := False;
  Limit := -1;
  Repeated := False;
  LineEnd := #10;
  CommandLine := TCommandLine.Create([
    CommandOption('e', 'echo', False, OptionEcho),
    CommandOption('i', 'input-range', True, OptionRange),
    CommandOption('n', 'head-count', True, OptionCount),
    CommandOption('o', 'output', True, OptionOutput),
    CommandOption('r', 'repeat', False, OptionRepeat),
    CommandOption('z', 'zero-terminated', False, OptionZero)], Usage);
  while CommandLine.NextOption(Code, Value) do
    case Code of
      OptionEcho: EchoMode := True;
      OptionRange:
        begin
          RangeText := Value;
          HasRange := True;
        end;
      OptionCount:
        if not ParseDecimal(Value, Limit) or (Limit < 0) then
          Fail(1, Format('invalid line count: ''%s''', [Value]));
      OptionOutput: OutputPath := Value;
      OptionRepeat: Repeated := True;
      OptionZero: LineEnd := #0;
    end;
end;

procedure FailInvalidRange;
begin
  Fail(1, Format('invalid input range: ''%s''', [RangeText]));
end;

{ The numbers LO through HI of RangeText. }
procedure AddRange(Lines: TStrings);
var
  Dash: Integer;
  Low, High: Int64;
  Number: Int64;
begin
  Dash := Pos('-', RangeText);
  if (Dash <= 1) or (Dash - 1 > MaximumBoundLength) then
    FailInvalidRange;
  if not ParseDecimal(Copy(RangeText, 1, Dash - 1), Low) or
     not ParseDecimal(Copy(RangeText, Dash + 1, MaxInt), High) or (High < Low) then
    FailInvalidRange;
  for Number := Low to High do
    Lines.Add(IntToStr(Number));
end;

procedure AddInputLines(Lines: TStrings);
var
  Stream: PInputStream;
begin
  if CommandLine.OperandCount > 1 then
    FailWithUsageHint(Format('extra operand ''%s''', [CommandLine.Operands[1]]));
  if CommandLine.OperandCount = 1 then
    Stream := OpenInput(CommandLine.Operands[0])
  else
    Stream := StandardInput;
  if Stream = nil then
    Halt(1);
  ReadLinesInto(Stream, Lines);
  CloseInput(Stream);
end;

procedure WriteRepeated(Output: POutputStream; Lines: TStrings);
var
  Written: Int64;
begin
  if Lines.Count = 0 then
  begin
    if Limit <> 0 then
      Fail(1, 'no lines to repeat');
    Exit;
  end;
  Written := 0;
  while ((Limit < 0) or (Written < Limit)) and not Output^.HadError do
  begin
    WriteString(Output, Lines[RandomBelow(QWord(Lines.Count))]);
    WriteCharacter(Output, LineEnd);
    Inc(Written);
  end;
end;

{ Fisher-Yates, stopping once Limit lines are placed. }
procedure WriteShuffled(Output: POutputStream; Lines: TStrings);
var
  Index: Integer;
  Chosen: Integer;
begin
  Index := 0;
  while (Index < Lines.Count) and ((Limit < 0) or (Index < Limit)) do
  begin
    Chosen := Index + Integer(RandomBelow(QWord(Lines.Count - Index)));
    Lines.Exchange(Index, Chosen);
    WriteString(Output, Lines[Index]);
    WriteCharacter(Output, LineEnd);
    Inc(Index);
  end;
end;

var
  Lines: TStringList;
  Operand: string;
  Output: POutputStream;
  OutputHandle: Int64;
begin
  ReadOptions;

  Lines := TStringList.Create;
  if HasRange then
    AddRange(Lines)
  else if EchoMode then
  begin
    for Operand in CommandLine.Operands do
      Lines.Add(Operand);
  end
  else
    AddInputLines(Lines);

  Output := StandardOutput;
  OutputHandle := -1;
  if CommandLine.OptionGiven(OptionOutput) then
  begin
    OutputHandle := OpenFile(PChar(OutputPath), OpenWrite or OpenCreate or OpenTruncate);
    if OutputHandle < 0 then
      FailWithError(1, ErrorCodeOf(OutputHandle), OutputPath);
    Output := CreateOutputStream(OutputHandle);
  end;

  if Repeated then
    WriteRepeated(Output, Lines)
  else
    WriteShuffled(Output, Lines);
  if OutputHandle >= 0 then
  begin
    DestroyOutputStream(Output);
    CloseFile(OutputHandle);
  end;
  Lines.Free;
end.
