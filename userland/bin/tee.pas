{
  tee - read from standard input and write to standard output and files

  tee [-a] [FILE]...
}
program tee;

{$mode objfpc}
{$pointermath on}

uses
  Abi.SystemCalls,
  Sys.Errors,
  Sys.Files,
  Sys.Format,
  Sys.Streams,
  Util.Messages,
  Util.Options;

const
  Usage: PChar = 'Usage: tee [OPTION]... [FILE]...'#10 +
    'Copy standard input to each FILE, and also to standard output.'#10 +
    #10 +
    '  -a, --append              append to the given FILEs, do not overwrite'#10 +
    '  -i, --ignore-interrupts   ignore interrupt signals (no effect here)'#10;

  OptionAppend = 1;
  OptionIgnore = 2;
  MaximumFiles = 32;

var
  Parser: TOptionParser;
  Code: Integer;
  Value: PChar;
  Append: Boolean;
  Handles: array[0..MaximumFiles - 1] of Int64;
  Index: Integer;
  Flags: LongWord;
  Buffer: array[0..4095] of Char;
  Count: Int64;
  ExitStatus: LongInt;
  Error: LongInt;
begin
  Append := False;
  BeginOptions(Parser, [
    OptionDefinition('a', 'append', False, OptionAppend),
    OptionDefinition('i', 'ignore-interrupts', False, OptionIgnore)], Usage);
  while NextOption(Parser, Code, Value) do
    if Code = OptionAppend then
      Append := True;
  if Parser.OperandCount > MaximumFiles then
    Fail(1, 'too many files', []);

  if Append then
    Flags := OpenWrite or OpenCreate or OpenAppend
  else
    Flags := OpenWrite or OpenCreate or OpenTruncate;
  ExitStatus := 0;
  for Index := 0 to Parser.OperandCount - 1 do
  begin
    Handles[Index] := OpenFile(Parser.Operands[Index], Flags);
    if Handles[Index] < 0 then
    begin
      ReportError(ErrorCodeOf(Handles[Index]), '%s', [ArgumentText(Parser.Operands[Index])]);
      ExitStatus := 1;
    end;
  end;

  repeat
    Count := ReadFile(StandardInputHandle, @Buffer[0], SizeOf(Buffer));
    if Count <= 0 then
      Break;
    WriteAll(StandardOutputHandle, @Buffer[0], QWord(Count));
    for Index := 0 to Parser.OperandCount - 1 do
    begin
      if Handles[Index] < 0 then
        Continue;
      Error := WriteAll(Handles[Index], @Buffer[0], QWord(Count));
      if Error <> ErrorNone then
      begin
        ReportError(Error, '%s', [ArgumentText(Parser.Operands[Index])]);
        CloseFile(Handles[Index]);
        Handles[Index] := -1;
        ExitStatus := 1;
      end;
    end;
  until False;

  for Index := 0 to Parser.OperandCount - 1 do
    if Handles[Index] >= 0 then
      CloseFile(Handles[Index]);
  Halt(ExitStatus);
end.
