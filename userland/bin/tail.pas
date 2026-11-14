{
  tail - output the last part of files

  tail [-n [+]NUM | -c [+]NUM] [-qv] [FILE]...

  Prints the last 10 lines of each FILE. With a leading '+' on NUM,
  prints starting at line (or byte) NUM instead. An old style "-NUM"
  means "-n NUM".
}
program tail;

{$mode objfpc}
{$pointermath on}

uses
  Sys.Environment,
  Runtime.Text,
  Sys.Format,
  Sys.Memory,
  Sys.Streams,
  Sys.Text,
  Util.Input,
  Util.Messages,
  Util.Options,
  Util.Sizes;

const
  Usage: PChar = 'Usage: tail [OPTION]... [FILE]...'#10 +
    'Print the last 10 lines of each FILE to standard output.'#10 +
    'With more than one FILE, precede each with a header giving the file name.'#10 +
    #10 +
    '  -c, --bytes=[+]NUM       output the last NUM bytes; or use -c +NUM to'#10 +
    '                             output starting with byte NUM of each file'#10 +
    '  -n, --lines=[+]NUM       output the last NUM lines, instead of the last 10;'#10 +
    '                             or use -n +NUM to skip NUM-1 lines at the start'#10 +
    '  -q, --quiet, --silent    never output headers giving file names'#10 +
    '  -v, --verbose            always output headers giving file names'#10;

  OptionBytes = 1;
  OptionLines = 2;
  OptionQuiet = 3;
  OptionVerbose = 4;

var
  CountBytes: Boolean;
  FromStart: Boolean;
  Amount: QWord;

procedure ParseAmount(Text: PChar);
begin
  FromStart := Text[0] = '+';
  if (Text[0] = '+') or (Text[0] = '-') then
    Inc(Text);
  if not ParseSize(Text, Amount) then
  begin
    if CountBytes then
      Fail(1, 'invalid number of bytes: ''%s''', [ArgumentText(Text)])
    else
      Fail(1, 'invalid number of lines: ''%s''', [ArgumentText(Text)]);
  end;
end;

procedure TailLines(Stream: PInputStream);
var
  List: TLineList;
  First: Int64;
  Index: Integer;
begin
  BeginLineList(List);
  ReadAllLines(Stream, List);
  if FromStart then
  begin
    First := Int64(Amount) - 1;
    if First < 0 then
      First := 0;
  end
  else
  begin
    First := Int64(List.Count) - Int64(Amount);
    if First < 0 then
      First := 0;
  end;
  Index := Integer(First);
  while Index < List.Count do
  begin
    WriteText(StandardOutput, List.Items[Index]);
    if (Index < List.Count - 1) or List.LastLineTerminated then
      WriteCharacter(StandardOutput, #10);
    Inc(Index);
  end;
  FreeLineList(List);
end;

procedure TailBytes(Stream: PInputStream);
var
  Builder: TTextBuilder;
  Buffer: array[0..4095] of Char;
  Count: QWord;
  Start: QWord;
begin
  BeginText(Builder);
  repeat
    Count := ReadBytes(Stream, @Buffer[0], SizeOf(Buffer));
    AppendBytes(Builder, @Buffer[0], Count);
  until Count = 0;
  if FromStart then
  begin
    Start := 0;
    if Amount > 0 then
      Start := Amount - 1;
  end
  else if Builder.Length > Amount then
    Start := Builder.Length - Amount
  else
    Start := 0;
  if Start < Builder.Length then
    WriteBytes(StandardOutput, Builder.Text + Start, Builder.Length - Start);
  DiscardText(Builder);
end;

var
  Parser: TOptionParser;
  Code: Integer;
  Value: PChar;
  Index: Integer;
  Stream: PInputStream;
  ExitStatus: LongInt;
  ShowHeaders: Integer;
  OldStyle: PChar;
begin
  CountBytes := False;
  FromStart := False;
  Amount := 10;
  ShowHeaders := 0;

  OldStyle := nil;
  if (ArgumentTotal > 1) and (ArgumentValues[1][0] in ['-', '+']) and IsDigit(ArgumentValues[1][1]) then
  begin
    OldStyle := ArgumentValues[1];
    ArgumentValues[1] := '--';
    ParseAmount(OldStyle);
  end;

  BeginOptions(Parser, [
    OptionDefinition('c', 'bytes', True, OptionBytes),
    OptionDefinition('n', 'lines', True, OptionLines),
    OptionDefinition('q', 'quiet', False, OptionQuiet),
    OptionDefinition(#0, 'silent', False, OptionQuiet),
    OptionDefinition('v', 'verbose', False, OptionVerbose)], Usage);
  while NextOption(Parser, Code, Value) do
    case Code of
      OptionBytes:
        begin
          CountBytes := True;
          ParseAmount(Value);
        end;
      OptionLines:
        begin
          CountBytes := False;
          ParseAmount(Value);
        end;
      OptionQuiet: ShowHeaders := -1;
      OptionVerbose: ShowHeaders := 1;
    end;

  if Parser.OperandCount = 0 then
  begin
    Parser.Operands[0] := '-';
    Parser.OperandCount := 1;
  end;
  if ShowHeaders = 0 then
  begin
    if Parser.OperandCount > 1 then
      ShowHeaders := 1
    else
      ShowHeaders := -1;
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
    if ShowHeaders = 1 then
    begin
      if Index > 0 then
        WriteCharacter(StandardOutput, #10);
      if TextIsEqual(Parser.Operands[Index], '-') then
        WriteLine(StandardOutput, '==> standard input <==')
      else
        WriteFormatted(StandardOutput, '==> %s <=='#10, [ArgumentText(Parser.Operands[Index])]);
    end;
    if CountBytes then
      TailBytes(Stream)
    else
      TailLines(Stream);
    CloseInput(Stream);
  end;
  Halt(ExitStatus);
end.
