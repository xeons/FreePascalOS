{
  base32 - encode or decode data as base32 (RFC 4648)

  base32 [-di] [-w COLS] [FILE]

  See Util.BaseEncoding for the encodings and options.
}
program base32;

{$mode objfpc}

uses
  Util.BaseEncoding;

begin
  RunBaseEncodingTool(EncodingBase32, False);
end.
