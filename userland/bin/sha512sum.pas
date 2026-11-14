{
  sha512sum - compute and check SHA-512 message digests

  sha512sum [-bt] [--tag] [-z] [FILE]...
  sha512sum -c [--quiet] [--status] [--strict] [-w] [FILE]...

  See Util.DigestTool for the options.
}
program sha512sum;

{$mode objfpc}

uses
  Crypto.Digests,
  Util.DigestTool;

begin
  RunDigestTool(DigestSha512);
end.
