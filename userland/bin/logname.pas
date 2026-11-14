{
  logname - print user's login name

  The console session belongs to the real user of the process.
}
program logname;

{$mode objfpc}

uses
  Sys.Streams,
  Util.Accounts,
  Util.Options;

const
  Usage: PChar = 'Usage: logname'#10 +
    'Print the user''s login name.'#10;

var
  Parser: TOptionParser;
  Name: PChar;
begin
  ParseOperandsOnly(Parser, Usage);
  Name := UserNameOf(CurrentRealUserId);
  if Name = nil then
    Name := 'root';
  PrintLine(Name);
end.
