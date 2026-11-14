{
  sha256sum - compute and check SHA-256 message digests

  sha256sum [-bt] [--tag] [-z] [FILE]...
  sha256sum -c [--quiet] [--status] [--strict] [-w] [FILE]...

  See Util.DigestTool for the options.
}
program sha256sum;

{$mode objfpc}

uses
  Crypto.Digests,
  Util.DigestTool;

begin
  RunDigestTool(DigestSha256);
end.
