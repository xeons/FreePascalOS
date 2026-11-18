{
  FreePascalOS
  Copyright (C) 2026 Brandon Scott

  This program is free software: you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation, either version 3 of the License, or
  (at your option) any later version.

  This program is distributed in the hope that it will be useful,
  but WITHOUT ANY WARRANTY; without even the implied warranty of
  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
  GNU General Public License for more details.

  You should have received a copy of the GNU General Public License
  along with this program.  If not, see <https://www.gnu.org/licenses/>.
}

{
  What the whole-buffer decoders (Compression.MemoryImages and the
  units under it: xz, LZMA2, LZMA, gzip, deflate) report.

  Freestanding: the kernel compiles it, so the texts are PChar.
}
unit Compression.DecodeResults;

{$mode objfpc}

interface

type
  TDecodeResult = (
    DecodeSucceeded,
    { The input ends before the compressed data does. }
    DecodeTruncated,
    { A header is not the format's (magic, flags, reserved bits). }
    DecodeInvalidHeader,
    { The compressed data breaks the format's rules. }
    DecodeCorrupt,
    { The check of the decompressed data (CRC-32, CRC-64) or of a
      header does not match. }
    DecodeChecksumMismatch,
    { The decompressed size is not what the container says. }
    DecodeSizeMismatch,
    { A valid feature this decoder does not have (zstd, an xz filter
      other than LZMA2, an SHA-256 check). }
    DecodeUnsupported,
    { The output buffer is too small for the data. }
    DecodeOutputTooSmall,
    { Something other than padding follows the compressed data. }
    DecodeTrailingData
  );

function DecodeResultText(Outcome: TDecodeResult): PChar;

implementation

function DecodeResultText(Outcome: TDecodeResult): PChar;
begin
  case Outcome of
    DecodeSucceeded: Result := 'success';
    DecodeTruncated: Result := 'the compressed data is cut short';
    DecodeInvalidHeader: Result := 'invalid header';
    DecodeCorrupt: Result := 'the compressed data is corrupt';
    DecodeChecksumMismatch: Result := 'checksum mismatch';
    DecodeSizeMismatch: Result := 'the decompressed size does not match';
    DecodeUnsupported: Result := 'unsupported format feature';
    DecodeOutputTooSmall: Result := 'the output buffer is too small';
    DecodeTrailingData: Result := 'data after the end of the compressed stream';
  else
    Result := 'unknown error';
  end;
end;

end.
