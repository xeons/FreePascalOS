{
  sha224sum - compute and check SHA-224 message digests

  sha224sum [-bt] [--tag] [-z] [FILE]...
  sha224sum -c [--quiet] [--status] [--strict] [-w] [FILE]...

  See Util.DigestTool for the options.
}
program sha224sum;

{$mode objfpc}

uses
  Crypto.Digests,
  Util.DigestTool;

begin
  RunDigestTool(DigestSha224);
end.
