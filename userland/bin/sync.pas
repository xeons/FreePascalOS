{
  sync - write cached data to permanent storage
}
program sync;

{$mode objfpc}

uses
  Sys.Files,
  Util.Messages,
  Util.Options;

const
  Usage: PChar = 'Usage: sync'#10 +
    'Synchronize cached writes to persistent storage.'#10;

var
  Parser: TOptionParser;
  Error: LongInt;
begin
  ParseOperandsOnly(Parser, Usage);
  Error := SyncFileSystems;
  if Error <> 0 then
    FailWithError(1, Error, 'error syncing', []);
end.
