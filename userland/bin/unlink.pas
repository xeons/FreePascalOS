{
  unlink - remove a name (a file, never a directory)

  unlink FILE
}
program unlink;

{$mode objfpc}

uses
  Abi.SystemCalls,
  Sys.Files,
  Sys.Format,
  Util.Messages,
  Util.Options;

const
  Usage: PChar = 'Usage: unlink FILE'#10 +
    'Call the unlink function to remove the specified FILE.'#10;

var
  Parser: TOptionParser;
  Information: TFileInformation;
  Error: LongInt;
begin
  ParseOperandsOnly(Parser, Usage);
  if Parser.OperandCount < 1 then
    FailWithUsageHint('missing operand', []);
  if Parser.OperandCount > 1 then
    FailWithUsageHint('extra operand ''%s''', [ArgumentText(Parser.Operands[1])]);
  Error := GetLinkInformation(Parser.Operands[0], Information);
  if (Error = ErrorNone) and (Information.Kind = KindDirectory) then
    Error := ErrorIsDirectory;
  if Error = ErrorNone then
    Error := RemovePath(Parser.Operands[0]);
  if Error <> ErrorNone then
    FailWithError(1, Error, 'cannot unlink ''%s''', [ArgumentText(Parser.Operands[0])]);
end.
