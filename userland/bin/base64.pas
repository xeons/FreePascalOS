{
  base64 - encode or decode data as base64 (RFC 4648)

  base64 [-di] [-w COLS] [FILE]

  See Util.BaseEncoding for the encodings and options.
}
program base64;

{$mode objfpc}

uses
  Util.BaseEncoding;

begin
  RunBaseEncodingTool(EncodingBase64, False);
end.
