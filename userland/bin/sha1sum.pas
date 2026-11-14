{
  sha1sum - compute and check SHA-1 (160-bit) message digests

  sha1sum [-bt] [--tag] [-z] [FILE]...
  sha1sum -c [--quiet] [--status] [--strict] [-w] [FILE]...

  See Util.DigestTool for the options.
}
program sha1sum;

{$mode objfpc}

uses
  Crypto.Digests,
  Util.DigestTool;

begin
  RunDigestTool(DigestSha1);
end.
