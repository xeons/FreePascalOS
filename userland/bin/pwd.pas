{
  pwd - print name of current/working directory
}
program pwd;

{$mode objfpc}

uses
  Sys.Files,
  Sys.Format,
  Sys.Streams,
  Util.Messages,
  Util.Options;

const
  Usage: PChar = 'Usage: pwd'#10 +
    'Print the full name of the current working directory.'#10;

var
  Parser: TOptionParser;
  Directory: array[0..PathCapacity - 1] of Char;
  Error: LongInt;
begin
  ParseOperandsOnly(Parser, Usage);
  Error := GetCurrentDirectory(@Directory[0], PathCapacity);
  if Error <> 0 then
    FailWithError(1, Error, 'cannot get the current directory', []);
  PrintLine(@Directory[0]);
end.
