{
  basenc - encode or decode data as one of several encodings

  basenc [-di] [-w COLS] [FILE]

  See Util.BaseEncoding for the encodings and options.
}
program basenc;

{$mode objfpc}

uses
  Util.BaseEncoding;

begin
  RunBaseEncodingTool(EncodingBase64, True);
end.
