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
  decompression with the zlib and gzip wrappers and their checksums,
  the brotli and Zstandard decoders, and the whole-buffer xz decoder.
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
  Compression.Buffers,
  Compression.StreamingDecoders,
  Compression.InflatingDecoders,
  Compression.OutputWindows,
  Compression.XxHash64,
  Compression.BrotliTables,
  Compression.BrotliDictionary,
  Compression.BrotliTransforms,
  Compression.BrotliBitReader,
  Compression.BrotliPrefixCodes,
  Compression.BrotliContextMaps,
  Compression.BrotliMetaBlocks,
  Compression.BrotliDecoder,
  Compression.BrotliStored,
  Compression.ZstdBitReaders,
  Compression.FiniteStateEntropy,
  Compression.ZstdHuffman,
  Compression.ZstdLiterals,
  Compression.ZstdSequences,
  Compression.ZstdFrames,
  Compression.ZstdDecoder,
  Compression.DecodeResults,
  Compression.CyclicRedundancy,
  Compression.RangeDecoder,
  Compression.LzmaDecoder,
  Compression.Lzma2Decoder,
  Compression.XzDecoder;

implementation

end.
