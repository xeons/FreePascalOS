{
  md5sum - compute and check MD5 (128-bit) message digests

  md5sum [-bt] [--tag] [-z] [FILE]...
  md5sum -c [--quiet] [--status] [--strict] [-w] [FILE]...

  See Util.DigestTool for the options.
}
program md5sum;

{$mode objfpc}

uses
  Crypto.Digests,
  Util.DigestTool;

begin
  RunDigestTool(DigestMd5);
end.
