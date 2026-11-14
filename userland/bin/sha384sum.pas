{
  sha384sum - compute and check SHA-384 message digests

  sha384sum [-bt] [--tag] [-z] [FILE]...
  sha384sum -c [--quiet] [--status] [--strict] [-w] [FILE]...

  See Util.DigestTool for the options.
}
program sha384sum;

{$mode objfpc}

uses
  Crypto.Digests,
  Util.DigestTool;

begin
  RunDigestTool(DigestSha384);
end.
