{
  whoami - print effective user name
}
program whoami;

{$mode objfpc}

uses
  Sys.Format,
  Sys.Streams,
  Util.Accounts,
  Util.Messages,
  Util.Options;

const
  Usage: PChar = 'Usage: whoami'#10 +
    'Print the user name associated with the current effective user ID.'#10;

var
  Parser: TOptionParser;
  Name: PChar;
begin
  ParseOperandsOnly(Parser, Usage);
  if Parser.OperandCount > 0 then
    FailWithUsageHint('extra operand', []);
  Name := UserNameOf(CurrentUserId);
  if Name = nil then
    Fail(1, 'cannot find name for user ID %u', [ArgumentUnsigned(CurrentUserId)]);
  PrintLine(Name);
end.
