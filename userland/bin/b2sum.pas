{
  b2sum - compute and check BLAKE2b-512 message digests

  b2sum [-bt] [--tag] [-z] [FILE]...
  b2sum -c [--quiet] [--status] [--strict] [-w] [FILE]...

  See Util.DigestTool for the options.
}
program b2sum;

{$mode objfpc}

uses
  Crypto.Digests,
  Util.DigestTool;

begin
  RunDigestTool(DigestBlake2b);
end.
