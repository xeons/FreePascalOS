{
  head - output the first part of files

  head [-n [-]NUM | -c [-]NUM] [-qv] [FILE]...

  Prints the first 10 lines of each FILE. With a leading '-' on NUM,
  prints everything except the last NUM lines (or bytes). An old style
  "-NUM" means "-n NUM".
}
program head;

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
  Util.Options,
  Util.Sizes;

const
  Usage: PChar = 'Usage: head [OPTION]... [FILE]...'#10 +
    'Print the first 10 lines of each FILE to standard output.'#10 +
    'With more than one FILE, precede each with a header giving the file name.'#10 +
    #10 +
    '  -c, --bytes=[-]NUM       print the first NUM bytes of each file;'#10 +
    '                             with the leading ''-'', print all but the last'#10 +
    '                             NUM bytes of each file'#10 +
    '  -n, --lines=[-]NUM       print the first NUM lines instead of the first 10;'#10 +
    '                             with the leading ''-'', print all but the last'#10 +
    '                             NUM lines of each file'#10 +
    '  -q, --quiet, --silent    never print headers giving file names'#10 +
    '  -v, --verbose            always print headers giving file names'#10;

  OptionBytes = 1;
  OptionLines = 2;
  OptionQuiet = 3;
  OptionVerbose = 4;

var
  CountBytes: Boolean;
  AllButLast: Boolean;
  Amount: QWord;

procedure ParseAmount(Text: PChar);
begin
  AllButLast := Text[0] = '-';
  if AllButLast then
    Inc(Text);
  if not ParseSize(Text, Amount) then
  begin
    if CountBytes then
      Fail(1, 'invalid number of bytes: ''%s''', [ArgumentText(Text)])
    else
      Fail(1, 'invalid number of lines: ''%s''', [ArgumentText(Text)]);
  end;
end;

procedure HeadLines(Stream: PInputStream);
var
  Character: Char;
  LinesSeen: QWord;
begin
  LinesSeen := 0;
  while (LinesSeen < Amount) and ReadCharacter(Stream, Character) do
  begin
    WriteCharacter(StandardOutput, Character);
    if Character = #10 then
      Inc(LinesSeen);
  end;
end;

procedure HeadBytes(Stream: PInputStream);
var
  Buffer: array[0..4095] of Char;
  Remaining: QWord;
  Wanted: QWord;
  Count: QWord;
begin
  Remaining := Amount;
  while Remaining > 0 do
  begin
    Wanted := SizeOf(Buffer);
    if Wanted > Remaining then
      Wanted := Remaining;
    Count := ReadBytes(Stream, @Buffer[0], Wanted);
    if Count = 0 then
      Break;
    WriteBytes(StandardOutput, @Buffer[0], Count);
    Remaining := Remaining - Count;
  end;
end;

{ All but the last Amount lines: collect everything, then print. }
procedure HeadAllButLastLines(Stream: PInputStream);
var
  List: TLineList;
  Index: Integer;
  Keep: Int64;
begin
  BeginLineList(List);
  ReadAllLines(Stream, List);
  Keep := Int64(List.Count) - Int64(Amount);
  for Index := 0 to Integer(Keep) - 1 do
    WriteLine(StandardOutput, List.Items[Index]);
  FreeLineList(List);
end;

procedure HeadAllButLastBytes(Stream: PInputStream);
var
  Builder: TTextBuilder;
  Buffer: array[0..4095] of Char;
  Count: QWord;
begin
  BeginText(Builder);
  repeat
    Count := ReadBytes(Stream, @Buffer[0], SizeOf(Buffer));
    AppendBytes(Builder, @Buffer[0], Count);
  until Count = 0;
  if Builder.Length > Amount then
    WriteBytes(StandardOutput, Builder.Text, Builder.Length - Amount);
  DiscardText(Builder);
end;

var
  Parser: TOptionParser;
  Code: Integer;
  Value: PChar;
  Index: Integer;
  Stream: PInputStream;
  ExitStatus: LongInt;
  ShowHeaders: Integer; { -1 never, 0 automatic, 1 always }
  OldStyle: PChar;
begin
  CountBytes := False;
  AllButLast := False;
  Amount := 10;
  ShowHeaders := 0;

  { "head -5 file" is the old way of writing "head -n 5 file". }
  OldStyle := nil;
  if (ArgumentCount > 1) and (ArgumentValues[1][0] = '-') and IsDigit(ArgumentValues[1][1]) then
  begin
    OldStyle := ArgumentValues[1] + 1;
    ArgumentValues[1] := '--';
    if not ParseSize(OldStyle, Amount) then
      Fail(1, 'invalid number of lines: ''%s''', [ArgumentText(OldStyle)]);
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
    if CountBytes and AllButLast then
      HeadAllButLastBytes(Stream)
    else if CountBytes then
      HeadBytes(Stream)
    else if AllButLast then
      HeadAllButLastLines(Stream)
    else
      HeadLines(Stream);
    CloseInput(Stream);
  end;
  Halt(ExitStatus);
end.
