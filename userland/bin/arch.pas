{
  arch - print machine hardware name (same as uname -m)
}
program arch;

{$mode objfpc}

uses
  Sys.Information,
  Sys.Streams,
  Util.Options;

const
  Usage: PChar = 'Usage: arch'#10 +
    'Print machine architecture.'#10;

var
  Parser: TOptionParser;
  Information: TSystemInformation;
begin
  ParseOperandsOnly(Parser, Usage);
  GetSystemInformation(Information);
  PrintLine(@Information.Machine[0]);
end.
