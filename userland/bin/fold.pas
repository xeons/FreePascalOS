{
  fold - wrap each input line to fit in specified width

  fold [-bs] [-w WIDTH] [FILE]...
}
program fold;

{$mode objfpc}
{$pointermath on}

uses
  Sys.Format,
  Sys.Memory,
  Sys.Streams,
  Sys.Text,
  Util.Input,
  Util.Messages,
  Util.Options;

const
  Usage: PChar = 'Usage: fold [OPTION]... [FILE]...'#10 +
    'Wrap input lines in each FILE, writing to standard output.'#10 +
    #10 +
    '  -b, --bytes         count bytes rather than columns'#10 +
    '  -s, --spaces        break at spaces'#10 +
    '  -w, --width=WIDTH   use WIDTH columns instead of 80'#10;

  OptionBytes = 1;
  OptionSpaces = 2;
  OptionWidth = 3;

var
  BreakAtSpaces: Boolean;
  Width: Int64;

procedure FoldLine(Line: PChar);
var
  Start: PtrInt;
  Length: PtrInt;
  BreakAt: PtrInt;
  Index: PtrInt;
begin
  Start := 0;
  Length := 0;
  while Line[Length] <> #0 do
    Inc(Length);
  while Length - Start > Width do
  begin
    BreakAt := Start + Width;
    if BreakAtSpaces then
    begin
      Index := BreakAt - 1;
      while (Index > Start) and (Line[Index] <> ' ') do
        Dec(Index);
      if Index > Start then
        BreakAt := Index + 1;
    end;
    WriteBytes(StandardOutput, Line + Start, QWord(BreakAt - Start));
    WriteCharacter(StandardOutput, #10);
    Start := BreakAt;
  end;
  WriteLine(StandardOutput, Line + Start);
end;

var
  Parser: TOptionParser;
  Code: Integer;
  Value: PChar;
  Index: Integer;
  Stream: PInputStream;
  Line: PChar;
  HadLineEnd: Boolean;
  ExitStatus: LongInt;
begin
  BreakAtSpaces := False;
  Width := 80;
  BeginOptions(Parser, [
    OptionDefinition('b', 'bytes', False, OptionBytes),
    OptionDefinition('s', 'spaces', False, OptionSpaces),
    OptionDefinition('w', 'width', True, OptionWidth)], Usage);
  while NextOption(Parser, Code, Value) do
    case Code of
      OptionSpaces: BreakAtSpaces := True;
      OptionWidth:
        if not ParseInteger(Value, Width) or (Width < 1) then
          Fail(1, 'invalid number of columns: ''%s''', [ArgumentText(Value)]);
    end;
  if Parser.OperandCount = 0 then
  begin
    Parser.Operands[0] := '-';
    Parser.OperandCount := 1;
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
    while ReadLine(Stream, Line, HadLineEnd) do
    begin
      FoldLine(Line);
      FreeMemory(Line);
    end;
    CloseInput(Stream);
  end;
  Halt(ExitStatus);
end.
