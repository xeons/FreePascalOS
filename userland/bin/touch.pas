{
  touch - create files

  touch [-c] FILE...

  Creates each FILE that does not exist. The system has no call for
  changing file times yet, so existing files are left as they are.
}
program touch;

{$mode objfpc}
{$pointermath on}

uses
  Abi.SystemCalls,
  Sys.Errors,
  Sys.Files,
  Sys.Format,
  Util.Messages,
  Util.Options;

const
  Usage: PChar = 'Usage: touch [OPTION]... FILE...'#10 +
    'Create each FILE that does not exist as an empty file.'#10 +
    #10 +
    '  -a, -m              accepted for compatibility'#10 +
    '  -c, --no-create     do not create any files'#10;

  OptionNoCreate = 1;
  OptionIgnored = 2;

var
  Parser: TOptionParser;
  Code: Integer;
  Value: PChar;
  NoCreate: Boolean;
  Index: Integer;
  Handle: Int64;
  ExitStatus: LongInt;
begin
  NoCreate := False;
  BeginOptions(Parser, [
    OptionDefinition('a', nil, False, OptionIgnored),
    OptionDefinition('m', nil, False, OptionIgnored),
    OptionDefinition('c', 'no-create', False, OptionNoCreate)], Usage);
  while NextOption(Parser, Code, Value) do
    if Code = OptionNoCreate then
      NoCreate := True;
  if Parser.OperandCount = 0 then
    FailWithUsageHint('missing file operand', []);

  ExitStatus := 0;
  for Index := 0 to Parser.OperandCount - 1 do
  begin
    if PathExists(Parser.Operands[Index]) or NoCreate then
      Continue;
    Handle := OpenFile(Parser.Operands[Index], OpenWrite or OpenCreate);
    if Handle < 0 then
    begin
      ReportError(ErrorCodeOf(Handle), 'cannot touch ''%s''', [ArgumentText(Parser.Operands[Index])]);
      ExitStatus := 1;
    end
    else
      CloseFile(Handle);
  end;
  Halt(ExitStatus);
end.
