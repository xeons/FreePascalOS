{
  comm - compare two sorted files line by line

  comm [-123] [--output-delimiter=STR] FILE1 FILE2

  Prints three columns: lines only in FILE1, lines only in FILE2, and
  lines in both; -1, -2 and -3 suppress them.
}
program comm;

{$mode objfpc}
{$pointermath on}

uses
  Runtime.Text,
  Sys.Format,
  Sys.Memory,
  Sys.Streams,
  Sys.Text,
  Util.Input,
  Util.Messages,
  Util.Options;

const
  Usage: PChar = 'Usage: comm [OPTION]... FILE1 FILE2'#10 +
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
  Delimiter: PChar;
  Counts: array[1..3] of Int64;

procedure PrintInColumn(Column: Integer; Line: PChar);
var
  Index: Integer;
begin
  Inc(Counts[Column]);
  if not Show[Column] then
    Exit;
  for Index := 1 to Column - 1 do
    if Show[Index] then
      WriteText(StandardOutput, Delimiter);
  WriteLine(StandardOutput, Line);
end;

var
  Parser: TOptionParser;
  Code: Integer;
  Value: PChar;
  ShowTotal: Boolean;
  First: PInputStream;
  Second: PInputStream;
  LineOne: PChar;
  LineTwo: PChar;
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
  BeginOptions(Parser, [
    OptionDefinition('1', nil, False, OptionHideFirst),
    OptionDefinition('2', nil, False, OptionHideSecond),
    OptionDefinition('3', nil, False, OptionHideCommon),
    OptionDefinition(#0, 'output-delimiter', True, OptionDelimiter),
    OptionDefinition(#0, 'total', False, OptionTotal)], Usage);
  while NextOption(Parser, Code, Value) do
    case Code of
      OptionHideFirst: Show[1] := False;
      OptionHideSecond: Show[2] := False;
      OptionHideCommon: Show[3] := False;
      OptionDelimiter: Delimiter := Value;
      OptionTotal: ShowTotal := True;
    end;
  if Parser.OperandCount < 2 then
    FailWithUsageHint('missing operand', []);
  if Parser.OperandCount > 2 then
    FailWithUsageHint('extra operand ''%s''', [ArgumentText(Parser.Operands[2])]);
  First := OpenInput(Parser.Operands[0]);
  Second := OpenInput(Parser.Operands[1]);
  if (First = nil) or (Second = nil) then
    Halt(1);

  HasOne := ReadLine(First, LineOne, HadLineEnd);
  HasTwo := ReadLine(Second, LineTwo, HadLineEnd);
  while HasOne or HasTwo do
  begin
    if HasOne and HasTwo then
      Order := CompareText(LineOne, LineTwo)
    else if HasOne then
      Order := -1
    else
      Order := 1;
    if Order < 0 then
    begin
      PrintInColumn(1, LineOne);
      FreeMemory(LineOne);
      HasOne := ReadLine(First, LineOne, HadLineEnd);
    end
    else if Order > 0 then
    begin
      PrintInColumn(2, LineTwo);
      FreeMemory(LineTwo);
      HasTwo := ReadLine(Second, LineTwo, HadLineEnd);
    end
    else
    begin
      PrintInColumn(3, LineOne);
      FreeMemory(LineOne);
      FreeMemory(LineTwo);
      HasOne := ReadLine(First, LineOne, HadLineEnd);
      HasTwo := ReadLine(Second, LineTwo, HadLineEnd);
    end;
  end;
  if ShowTotal then
    WriteFormatted(StandardOutput, '%d%s%d%s%d%stotal'#10, [ArgumentNumber(Counts[1]), ArgumentText(Delimiter),
      ArgumentNumber(Counts[2]), ArgumentText(Delimiter), ArgumentNumber(Counts[3]), ArgumentText(Delimiter)]);
  CloseInput(First);
  CloseInput(Second);
end.
