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
  comm - compare two sorted files line by line

  comm [-123] [--output-delimiter=STR] FILE1 FILE2

  Prints three columns: lines only in FILE1, lines only in FILE2, and
  lines in both; -1, -2 and -3 suppress them.
}
program comm;

{$mode objfpc}{$H+}

uses
  SysUtils,
  Sys.Streams,
  Util.CommandLine,
  Util.Input,
  Util.Messages,
  Util.Output;

const
  Usage = 'Usage: comm [OPTION]... FILE1 FILE2'#10 +
    'Compare sorted files FILE1 and FILE2 line by line.'#10#10 +
    'With no options, produce three-column output.  Column one contains'#10 +
    'lines unique to FILE1, column two contains lines unique to FILE2,'#10 +
    'and column three contains lines common to both files.'#10#10 +
    '  -1              suppress column 1 (lines unique to FILE1)'#10 +
    '  -2              suppress column 2 (lines unique to FILE2)'#10 +
    '  -3              suppress column 3 (lines that appear in both files)'#10 +
    '      --output-delimiter=STR  separate columns with STR'#10 +
    '      --total     output a summary'#10;

  OptionHideFirst = 1;
  OptionHideSecond = 2;
  OptionHideCommon = 3;
  OptionDelimiter = 4;
  OptionTotal = 5;

var
  Show: array[1..3] of Boolean;
  Delimiter: string;
  Counts: array[1..3] of Int64;

procedure PrintInColumn(Column: Integer; const Line: string);
var
  Index: Integer;
begin
  Inc(Counts[Column]);
  if not Show[Column] then
    Exit;
  for Index := 1 to Column - 1 do
    if Show[Index] then
      PrintString(Delimiter);
  PrintStringLine(Line);
end;

var
  CommandLine: TCommandLine;
  Code: Integer;
  Value: string;
  ShowTotal: Boolean;
  First: PInputStream;
  Second: PInputStream;
  LineOne: string;
  LineTwo: string;
  HasOne: Boolean;
  HasTwo: Boolean;
  HadLineEnd: Boolean;
  Order: Integer;
begin
  Show[1] := True;
  Show[2] := True;
  Show[3] := True;
  Delimiter := #9;
  ShowTotal := False;
  CommandLine := TCommandLine.Create([
    CommandOption('1', '', False, OptionHideFirst),
    CommandOption('2', '', False, OptionHideSecond),
    CommandOption('3', '', False, OptionHideCommon),
    CommandOption(#0, 'output-delimiter', True, OptionDelimiter),
    CommandOption(#0, 'total', False, OptionTotal)], Usage);
  while CommandLine.NextOption(Code, Value) do
    case Code of
      OptionHideFirst: Show[1] := False;
      OptionHideSecond: Show[2] := False;
      OptionHideCommon: Show[3] := False;
      OptionDelimiter: Delimiter := Value;
      OptionTotal: ShowTotal := True;
    end;
  if CommandLine.OperandCount < 2 then
    FailWithUsageHint('missing operand');
  if CommandLine.OperandCount > 2 then
    FailWithUsageHint(Format('extra operand ''%s''', [CommandLine.Operands[2]]));
  First := OpenInput(CommandLine.Operands[0]);
  Second := OpenInput(CommandLine.Operands[1]);
  if (First = nil) or (Second = nil) then
    Halt(1);

  HasOne := ReadTextLine(First, LineOne, HadLineEnd);
  HasTwo := ReadTextLine(Second, LineTwo, HadLineEnd);
  while HasOne or HasTwo do
  begin
    if HasOne and HasTwo then
      Order := CompareStr(LineOne, LineTwo)
    else if HasOne then
      Order := -1
    else
      Order := 1;
    if Order < 0 then
    begin
      PrintInColumn(1, LineOne);
      HasOne := ReadTextLine(First, LineOne, HadLineEnd);
    end
    else if Order > 0 then
    begin
      PrintInColumn(2, LineTwo);
      HasTwo := ReadTextLine(Second, LineTwo, HadLineEnd);
    end
    else
    begin
      PrintInColumn(3, LineOne);
      HasOne := ReadTextLine(First, LineOne, HadLineEnd);
      HasTwo := ReadTextLine(Second, LineTwo, HadLineEnd);
    end;
  end;
  if ShowTotal then
    PrintString(Format('%d%s%d%s%d%stotal'#10, [Counts[1], Delimiter, Counts[2], Delimiter, Counts[3],
      Delimiter]));
  CloseInput(First);
  CloseInput(Second);
  CommandLine.Free;
end.
