{
  hostid - print the numeric identifier for the current host

  Derived from the node name, as eight hexadecimal digits.
}
program hostid;

{$mode objfpc}
{$pointermath on}

uses
  Runtime.Text,
  Crypto.Checksums,
  Sys.Format,
  Sys.Information,
  Sys.Streams,
  Util.Options;

const
  Usage: PChar = 'Usage: hostid'#10 +
    'Print the numeric identifier (in hexadecimal) for the current host.'#10;

var
  Parser: TOptionParser;
  Information: TSystemInformation;
  Identifier: LongWord;
begin
  ParseOperandsOnly(Parser, Usage);
  GetSystemInformation(Information);
  Identifier := Crc32Finish(Crc32Update(Crc32Initial, @Information.NodeName[0],
    TextLength(@Information.NodeName[0])));
  WriteFormatted(StandardOutput, '%08x'#10, [ArgumentUnsigned(Identifier)]);
end.
