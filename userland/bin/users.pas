{
  users - print the user names of users currently logged in

  The only session is on the console, of the real user of the process.
}
program users;

{$mode objfpc}

uses
  Sys.Streams,
  Util.Accounts,
  Util.Options;

const
  Usage: PChar = 'Usage: users'#10 +
    'Output who is currently logged in.'#10;

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
