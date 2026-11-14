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
{$pointermath on}

uses
  Abi.SystemCalls,
  Runtime.Text,
  Crypto.Random,
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
  Usage: PChar = 'Usage: shuf [OPTION]... [FILE]'#10 +
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

var
  Parser: TOptionParser;
  Code: Integer;
  Value: PChar;
  EchoMode: Boolean;
  RangeText: PChar;
  Limit: Int64;
  OutputPath: PChar;
  Repeated: Boolean;
  LineEnd: Char;
  Lines: TLineList;
  Stream: PInputStream;
  Output: POutputStream;
  OutputHandle: Int64;
  Low, High: Int64;
  Dash: PtrInt;
  Number: Int64;
  Index: Integer;
  Chosen: Integer;
  Swap: PChar;
  Written: Int64;
  NumberText: TNumberText;
  Bound: array[0..31] of Char;
begin
  EchoMode := False;
  RangeText := nil;
  Limit := -1;
  OutputPath := nil;
  Repeated := False;
  LineEnd := #10;
  BeginOptions(Parser, [
    OptionDefinition('e', 'echo', False, OptionEcho),
    OptionDefinition('i', 'input-range', True, OptionRange),
    OptionDefinition('n', 'head-count', True, OptionCount),
    OptionDefinition('o', 'output', True, OptionOutput),
    OptionDefinition('r', 'repeat', False, OptionRepeat),
    OptionDefinition('z', 'zero-terminated', False, OptionZero)], Usage);
  while NextOption(Parser, Code, Value) do
    case Code of
      OptionEcho: EchoMode := True;
      OptionRange: RangeText := Value;
      OptionCount:
        if not ParseInteger(Value, Limit) or (Limit < 0) then
          Fail(1, 'invalid line count: ''%s''', [ArgumentText(Value)]);
      OptionOutput: OutputPath := Value;
      OptionRepeat: Repeated := True;
      OptionZero: LineEnd := #0;
    end;

  BeginLineList(Lines);
  if RangeText <> nil then
  begin
    Dash := FindCharacter(RangeText, '-');
    if (Dash <= 0) or (Dash >= SizeOf(Bound)) then
      Fail(1, 'invalid input range: ''%s''', [ArgumentText(RangeText)]);
    CopyText(@Bound[0], RangeText, PtrUInt(Dash) + 1);
    if not ParseInteger(@Bound[0], Low) or not ParseInteger(RangeText + Dash + 1, High) or (High < Low) then
      Fail(1, 'invalid input range: ''%s''', [ArgumentText(RangeText)]);
    for Number := Low to High do
      AddLine(Lines, DuplicateText(FormatSignedDecimal(Number, NumberText)));
  end
  else if EchoMode then
  begin
    for Index := 0 to Parser.OperandCount - 1 do
      AddLine(Lines, DuplicateText(Parser.Operands[Index]));
  end
  else
  begin
    if Parser.OperandCount > 1 then
      FailWithUsageHint('extra operand ''%s''', [ArgumentText(Parser.Operands[1])]);
    if Parser.OperandCount = 1 then
      Stream := OpenInput(Parser.Operands[0])
    else
      Stream := StandardInput;
    if Stream = nil then
      Halt(1);
    ReadAllLines(Stream, Lines);
    CloseInput(Stream);
  end;

  Output := StandardOutput;
  OutputHandle := -1;
  if OutputPath <> nil then
  begin
    OutputHandle := OpenFile(OutputPath, OpenWrite or OpenCreate or OpenTruncate);
    if OutputHandle < 0 then
      FailWithError(1, ErrorCodeOf(OutputHandle), '%s', [ArgumentText(OutputPath)]);
    Output := CreateOutputStream(OutputHandle);
  end;

  Written := 0;
  if Repeated then
  begin
    if Lines.Count = 0 then
    begin
      if Limit <> 0 then
        Fail(1, 'no lines to repeat', []);
    end
    else
      while ((Limit < 0) or (Written < Limit)) and not Output^.HadError do
      begin
        WriteText(Output, Lines.Items[RandomBelow(QWord(Lines.Count))]);
        WriteCharacter(Output, LineEnd);
        Inc(Written);
      end;
  end
  else
  begin
    { Fisher-Yates, stopping once Limit lines are placed. }
    Index := 0;
    while (Index < Lines.Count) and ((Limit < 0) or (Index < Limit)) do
    begin
      Chosen := Index + Integer(RandomBelow(QWord(Lines.Count - Index)));
      Swap := Lines.Items[Index];
      Lines.Items[Index] := Lines.Items[Chosen];
      Lines.Items[Chosen] := Swap;
      WriteText(Output, Lines.Items[Index]);
      WriteCharacter(Output, LineEnd);
      Inc(Index);
    end;
  end;
  if OutputHandle >= 0 then
  begin
    DestroyOutputStream(Output);
    CloseFile(OutputHandle);
  end;
end.
