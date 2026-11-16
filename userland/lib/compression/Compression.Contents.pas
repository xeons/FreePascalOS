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
  The contents of libcompression.so: deflate compression and
  decompression with the zlib and gzip wrappers and their checksums.
  Compiling this unit compiles all of them.
}
unit Compression.Contents;

{$mode objfpc}

interface

uses
  Compression.Errors,
  Compression.Formats,
  Compression.Checksums,
  Compression.DeflateFormat,
  Compression.HuffmanDecoding,
  Compression.InflateEngine,
  Compression.ZlibFormat,
  Compression.GzipFormat,
  Compression.Inflater,
  Compression.HuffmanEncoding,
  Compression.BitWriter,
  Compression.DeflateBlocks,
  Compression.MatchFinder,
  Compression.DeflateEngine,
  Compression.Deflater,
  Compression.Streams,
  Compression.Buffers;

implementation

end.
