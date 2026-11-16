#!/usr/bin/env python3
# FreePascalOS
# Copyright (C) 2026 Brandon Scott
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <https://www.gnu.org/licenses/>.

"""Writes CompressionTest.Vectors.inc (at build time): deflate, zlib and
gzip data made by Python's zlib and gzip (that is, by zlib itself) from
test data that CompressionTest makes again with the same generators,
and hand-made broken streams with the error each must give.

    python3 tools/CompressionTest/make-vectors.py > build/tools/CompressionTest.Vectors.inc
"""

import struct
import sys
import zlib

WORDS = [b"the", b"quick", b"brown", b"fox", b"jumps", b"over", b"lazy", b"dog", b"pascal",
         b"kernel", b"window", b"deflate", b"huffman", b"block", b"stream", b"of", b"and", b"a",
         b"compression", b"image", b"pixel", b"free", b"system", b"user"]


class Generator:
    """The same linear congruential generator as CompressionTest.Data."""

    def __init__(self, seed):
        self.state = seed & 0x7FFFFFFF

    def next(self):
        self.state = (self.state * 1103515245 + 12345) & 0x7FFFFFFF
        return self.state >> 16


def make_text(size, seed):
    generator = Generator(seed)
    data = bytearray()
    while len(data) < size:
        data += WORDS[generator.next() % len(WORDS)]
        data += b"\n" if generator.next() % 8 == 0 else b" "
    return bytes(data[:size])


def make_random(size, seed):
    generator = Generator(seed)
    return bytes(generator.next() & 0xFF for _ in range(size))


def make_runs(size, seed):
    generator = Generator(seed)
    data = bytearray()
    while len(data) < size:
        value = generator.next() & 0xFF
        data += bytes([value]) * (1 + generator.next() % 300)
    return bytes(data[:size])


def make_blocks(size, seed):
    """A 4096 byte random block, again and again, one byte changed each time."""
    block = bytearray(make_random(4096, seed))
    data = bytearray()
    repetition = 0
    while len(data) < size:
        block[(repetition * 517) % 4096] = repetition & 0xFF
        data += block
        repetition += 1
    return bytes(data[:size])


def make_far(size, seed):
    """32768 bytes of text, then the same again: matches exactly a window back."""
    chunk = make_text(32768, seed)
    data = bytearray()
    while len(data) < size:
        data += chunk
    return bytes(data[:size])


GENERATORS = {
    "DataText": make_text,
    "DataRandom": make_random,
    "DataRuns": make_runs,
    "DataBlocks": make_blocks,
    "DataFar": make_far,
}


def compress(data, level=6, wbits=15, strategy=zlib.Z_DEFAULT_STRATEGY, memlevel=8):
    compressor = zlib.compressobj(level, zlib.DEFLATED, wbits, memlevel, strategy)
    return compressor.compress(data) + compressor.flush()


def gzip_member(data, level=6, header_fields=None):
    """A gzip member written by hand, so that every header field can be set."""
    fields = header_fields or {}
    flags = 0
    extra = b""
    if "extra" in fields:
        flags |= 0x04
        extra = struct.pack("<H", len(fields["extra"])) + fields["extra"]
    name = b""
    if "name" in fields:
        flags |= 0x08
        name = fields["name"] + b"\0"
    comment = b""
    if "comment" in fields:
        flags |= 0x10
        comment = fields["comment"] + b"\0"
    if fields.get("header_crc"):
        flags |= 0x02
    header = bytes([0x1F, 0x8B, 8, flags]) + struct.pack("<I", fields.get("mtime", 0)) + bytes([0, 3])
    header += extra + name + comment
    if fields.get("header_crc"):
        header += struct.pack("<H", zlib.crc32(header) & 0xFFFF)
    body = compress(data, level, -15)
    trailer = struct.pack("<II", zlib.crc32(data), len(data) & 0xFFFFFFFF)
    return header + body + trailer


class BitWriter:
    """Bits first bit first, as deflate sends them."""

    def __init__(self):
        self.bits = []

    def write(self, value, count):
        for bit in range(count):
            self.bits.append((value >> bit) & 1)

    def write_code(self, code, length):
        """A Huffman code: its most significant bit first."""
        for bit in range(length - 1, -1, -1):
            self.bits.append((code >> bit) & 1)

    def data(self, padding=b""):
        while len(self.bits) % 8:
            self.bits.append(0)
        result = bytearray()
        for index in range(0, len(self.bits), 8):
            value = 0
            for bit in range(8):
                value |= self.bits[index + bit] << bit
            result.append(value)
        return bytes(result) + padding


CODE_LENGTH_ORDER = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]


def canonical_codes(lengths):
    codes = {}
    code = 0
    for length in range(1, 16):
        for symbol, symbol_length in enumerate(lengths):
            if symbol_length == length:
                codes[symbol] = code
                code += 1
        code <<= 1
    return codes


def dynamic_header(writer, literal_count, distance_count, code_length_lengths):
    writer.write(1, 1)
    writer.write(2, 2)
    writer.write(literal_count - 257, 5)
    writer.write(distance_count - 1, 5)
    writer.write(len(CODE_LENGTH_ORDER) - 4, 4)
    for symbol in CODE_LENGTH_ORDER:
        writer.write(code_length_lengths[symbol], 3)
    return canonical_codes(code_length_lengths)


def broken_streams():
    """(name, format, expected error, data)"""
    cases = []

    cases.append(("block type 3", "FormatRaw", "CompressionErrorInvalidBlockType", bytes([0x07, 0, 0, 0])))
    cases.append(("stored length", "FormatRaw", "CompressionErrorStoredLengthMismatch",
                  bytes([0x01, 0x05, 0x00, 0x00, 0x00]) + b"hello"))

    # Fixed block: a length before any output.
    writer = BitWriter()
    writer.write(1, 1)
    writer.write(1, 2)
    writer.write_code(0b0000001, 7)   # 257: length 3
    writer.write_code(0, 5)           # distance 1
    writer.write_code(0, 7)           # end of block
    cases.append(("distance before output", "FormatRaw", "CompressionErrorDistanceTooFar", writer.data(b"\0" * 8)))

    # Fixed block: a literal, then a match two back.
    writer = BitWriter()
    writer.write(1, 1)
    writer.write(1, 2)
    writer.write_code(0x30 + ord("a"), 8)
    writer.write_code(0b0000001, 7)
    writer.write_code(1, 5)           # distance 2
    writer.write_code(0, 7)
    cases.append(("distance too far", "FormatRaw", "CompressionErrorDistanceTooFar", writer.data(b"\0" * 8)))

    writer = BitWriter()
    writer.write(1, 1)
    writer.write(1, 2)
    writer.write_code(0b11000000 + 6, 8)   # 286
    cases.append(("literal/length 286", "FormatRaw", "CompressionErrorInvalidSymbol", writer.data(b"\0" * 8)))

    writer = BitWriter()
    writer.write(1, 1)
    writer.write(1, 2)
    writer.write_code(0x30 + ord("a"), 8)
    writer.write_code(0b0000001, 7)
    writer.write_code(30, 5)          # distance code 30
    cases.append(("distance code 30", "FormatRaw", "CompressionErrorInvalidSymbol", writer.data(b"\0" * 8)))

    writer = BitWriter()
    writer.write(1, 1)
    writer.write(2, 2)
    writer.write(30, 5)
    writer.write(0, 5)
    writer.write(0, 4)
    cases.append(("287 length codes", "FormatRaw", "CompressionErrorTooManyCodes", writer.data(b"\0" * 8)))

    writer = BitWriter()
    writer.write(1, 1)
    writer.write(2, 2)
    writer.write(0, 5)
    writer.write(30, 5)
    writer.write(0, 4)
    cases.append(("31 distance codes", "FormatRaw", "CompressionErrorTooManyCodes", writer.data(b"\0" * 8)))

    writer = BitWriter()
    dynamic_header(writer, 257, 1, [1] * 19)
    cases.append(("over-subscribed code length code", "FormatRaw", "CompressionErrorInvalidCodeLengths",
                  writer.data(b"\0" * 8)))

    lengths = [0] * 19
    lengths[0] = 1
    lengths[1] = 2
    cases_writer = BitWriter()
    dynamic_header(cases_writer, 257, 1, lengths)
    cases.append(("incomplete code length code", "FormatRaw", "CompressionErrorInvalidCodeLengths",
                  cases_writer.data(b"\0" * 8)))

    lengths = [0] * 19
    lengths[0] = 1
    lengths[16] = 1
    writer = BitWriter()
    codes = dynamic_header(writer, 257, 1, lengths)
    writer.write_code(codes[16], 1)
    writer.write(0, 2)
    cases.append(("repeat with nothing before", "FormatRaw", "CompressionErrorInvalidRepeat", writer.data(b"\0" * 8)))

    lengths = [0] * 19
    lengths[1] = 1
    lengths[18] = 1
    writer = BitWriter()
    codes = dynamic_header(writer, 257, 1, lengths)
    writer.write_code(codes[18], 1)
    writer.write(138 - 11, 7)
    writer.write_code(codes[18], 1)
    writer.write(138 - 11, 7)        # 276 zeros where 258 lengths fit
    cases.append(("repeat past the end", "FormatRaw", "CompressionErrorInvalidRepeat", writer.data(b"\0" * 8)))

    lengths = [0] * 19
    lengths[0] = 1
    lengths[18] = 1
    writer = BitWriter()
    codes = dynamic_header(writer, 257, 1, lengths)
    writer.write_code(codes[18], 1)
    writer.write(138 - 11, 7)
    writer.write_code(codes[18], 1)
    writer.write(120 - 11, 7)
    cases.append(("no end of block code", "FormatRaw", "CompressionErrorMissingEndOfBlock", writer.data(b"\0" * 8)))

    lengths = [0] * 19
    for symbol in (0, 1, 2, 18):
        lengths[symbol] = 2
    writer = BitWriter()
    codes = dynamic_header(writer, 257, 1, lengths)
    writer.write_code(codes[2], 2)        # literal 0: two bits
    writer.write_code(codes[18], 2)
    writer.write(138 - 11, 7)
    writer.write_code(codes[18], 2)
    writer.write(117 - 11, 7)
    writer.write_code(codes[2], 2)        # end of block: two bits
    writer.write_code(codes[1], 2)        # one distance code of one bit
    cases.append(("incomplete literal/length code", "FormatRaw", "CompressionErrorInvalidCodeLengths",
                  writer.data(b"\0" * 8)))

    text = make_text(2000, 7)
    good_zlib = compress(text, 6)
    cases.append(("cut off zlib", "FormatZlib", "CompressionErrorTruncated", good_zlib[:-1]))
    cases.append(("cut off zlib body", "FormatZlib", "CompressionErrorTruncated", good_zlib[:len(good_zlib) // 2]))
    cases.append(("zlib header only", "FormatZlib", "CompressionErrorTruncated", good_zlib[:2]))
    cases.append(("empty zlib", "FormatZlib", "CompressionErrorTruncated", b""))
    damaged = bytearray(good_zlib)
    damaged[-1] ^= 1
    cases.append(("zlib Adler-32", "FormatZlib", "CompressionErrorAdlerMismatch", bytes(damaged)))
    cases.append(("zlib header check", "FormatZlib", "CompressionErrorInvalidZlibHeader", bytes([0x78, 0x9D]) +
                  good_zlib[2:]))
    method_byte = 0x77
    flags_byte = (31 - (method_byte * 256) % 31) % 31
    cases.append(("zlib method 7", "FormatZlib", "CompressionErrorUnsupportedMethod",
                  bytes([method_byte, flags_byte]) + good_zlib[2:]))
    cases.append(("zlib window 2^16", "FormatZlib", "CompressionErrorInvalidZlibHeader",
                  bytes([0x88, (31 - (0x88 * 256) % 31) % 31]) + good_zlib[2:]))
    cases.append(("zlib preset dictionary", "FormatZlib", "CompressionErrorPresetDictionary",
                  bytes([0x78, 0xBB]) + good_zlib[2:]))
    cases.append(("zlib trailing data", "FormatZlib", "CompressionErrorTrailingData", good_zlib + b"x"))

    good_gzip = gzip_member(text)
    cases.append(("gzip magic", "FormatGzip", "CompressionErrorInvalidGzipHeader", b"\x1f\x8c" + good_gzip[2:]))
    cases.append(("gzip method", "FormatGzip", "CompressionErrorUnsupportedMethod",
                  good_gzip[:2] + b"\x07" + good_gzip[3:]))
    cases.append(("gzip reserved flag", "FormatGzip", "CompressionErrorInvalidGzipHeader",
                  good_gzip[:3] + b"\x20" + good_gzip[4:]))
    damaged = bytearray(good_gzip)
    damaged[-8] ^= 0x10
    cases.append(("gzip CRC-32", "FormatGzip", "CompressionErrorCrcMismatch", bytes(damaged)))
    damaged = bytearray(good_gzip)
    damaged[-4] ^= 0x01
    cases.append(("gzip length", "FormatGzip", "CompressionErrorLengthMismatch", bytes(damaged)))
    with_crc = bytearray(gzip_member(text, 6, {"name": b"a.txt", "header_crc": True}))
    with_crc[10] ^= 0x01
    cases.append(("gzip header CRC", "FormatGzip", "CompressionErrorHeaderCrcMismatch", bytes(with_crc)))
    cases.append(("gzip trailing data", "FormatGzip", "CompressionErrorTrailingData", good_gzip + b"garbage"))
    cases.append(("cut off gzip trailer", "FormatGzip", "CompressionErrorTruncated", good_gzip[:-3]))
    cases.append(("cut off gzip name", "FormatGzip", "CompressionErrorTruncated",
                  gzip_member(text, 6, {"name": b"name.txt"})[:14]))
    cases.append(("gzip in a zlib reader", "FormatZlib", "CompressionErrorInvalidZlibHeader", good_gzip))
    return cases


def pascal_hex(data):
    if not data:
        return "''"
    text = data.hex()
    lines = [text[i:i + 96] for i in range(0, len(text), 96)]
    return " +\n      ".join("'" + line + "'" for line in lines)


def main():
    good = []

    def add(name, format_name, kind, size, seed, data_bytes, compressed):
        good.append((name, format_name, kind, size, seed, zlib.crc32(data_bytes), zlib.adler32(data_bytes), compressed))

    for kind, size, seed in [("DataText", 20000, 1), ("DataRandom", 5000, 2), ("DataRuns", 100000, 3),
                             ("DataBlocks", 200000, 4)]:
        data = GENERATORS[kind](size, seed)
        levels = (0, 1, 6, 9) if kind == "DataRandom" else (1, 6, 9)
        for level in levels:
            add("%s zlib level %d" % (kind, level), "FormatZlib", kind, size, seed, data, compress(data, level))
    far = make_far(32768 + 258, 5)
    compressor = zlib.compressobj(6, zlib.DEFLATED, -15)
    first_window = compressor.compress(far[:32768]) + compressor.flush(zlib.Z_SYNC_FLUSH)
    writer = BitWriter()
    writer.write(1, 1)
    writer.write(1, 2)
    writer.write_code(0b11000000 + 5, 8)   # 285: length 258
    writer.write_code(29, 5)               # distance code 29
    writer.write(32768 - 24577, 13)
    writer.write_code(0, 7)
    add("distance 32768", "FormatRaw", "DataFar", 32768 + 258, 5, far, first_window + writer.data())
    text = make_text(30000, 6)
    add("raw deflate", "FormatRaw", "DataText", 30000, 6, text, compress(text, 6, -15))
    add("fixed Huffman only", "FormatRaw", "DataText", 30000, 6, text, compress(text, 6, -15, zlib.Z_FIXED))
    add("Huffman only", "FormatZlib", "DataText", 30000, 6, text, compress(text, 6, 15, zlib.Z_HUFFMAN_ONLY))
    runs = make_runs(50000, 8)
    add("run length", "FormatZlib", "DataRuns", 50000, 8, runs, compress(runs, 6, 15, zlib.Z_RLE))
    add("small window", "FormatZlib", "DataText", 30000, 6, text, compress(text, 9, 9))
    add("small blocks", "FormatZlib", "DataText", 30000, 6, text, compress(text, 6, 15, zlib.Z_DEFAULT_STRATEGY, 1))
    add("gzip", "FormatGzip", "DataText", 30000, 6, text, gzip_member(text))
    add("gzip read as automatic", "FormatAutomatic", "DataText", 30000, 6, text, gzip_member(text, 9))
    add("zlib read as automatic", "FormatAutomatic", "DataText", 30000, 6, text, compress(text, 1))
    add("gzip two members", "FormatGzip", "DataText", 30000, 6, text,
        gzip_member(text[:12345], 6) + gzip_member(text[12345:], 1))
    add("gzip three members, one empty", "FormatGzip", "DataText", 30000, 6, text,
        gzip_member(text[:100]) + gzip_member(b"") + gzip_member(text[100:]))
    add("empty zlib", "FormatZlib", "DataText", 0, 1, b"", compress(b""))
    add("empty raw", "FormatRaw", "DataText", 0, 1, b"", compress(b"", 6, -15))
    add("empty gzip", "FormatGzip", "DataText", 0, 1, b"", gzip_member(b""))

    fields = {"name": b"hello.txt", "comment": b"a comment", "extra": b"AB\x04\x00\xde\xad\xbe\xef",
              "mtime": 1700000000, "header_crc": True}
    header_vector = gzip_member(text[:1000], 6, fields)

    print("{ Made by tools/CompressionTest/make-vectors.py. }")
    print("const")
    print("  GoodVectors: array[0..%d] of TGoodVector = (" % (len(good) - 1))
    for index, (name, format_name, kind, size, seed, crc, adler, compressed) in enumerate(good):
        print("    (Name: '%s'; Format: %s; Kind: %s; Size: %d; Seed: %d; Crc: $%08x; Adler: $%08x;" %
              (name, format_name, kind, size, seed, crc, adler))
        print("     Compressed:")
        print("      %s)%s" % (pascal_hex(compressed), "," if index < len(good) - 1 else ""))
    print("  );")
    broken = broken_streams()
    print("  BrokenVectors: array[0..%d] of TBrokenVector = (" % (len(broken) - 1))
    for index, (name, format_name, error, data) in enumerate(broken):
        print("    (Name: '%s'; Format: %s; Expected: %s;" % (name, format_name, error))
        print("     Compressed:")
        print("      %s)%s" % (pascal_hex(data), "," if index < len(broken) - 1 else ""))
    print("  );")
    print("  GzipHeaderVector: PChar =")
    print("      %s;" % pascal_hex(header_vector))
    print("  GzipHeaderVectorSize = 1000;")
    print("  GzipHeaderVectorSeed = 6;")
    print("  { Of a million bytes of $FF. }")
    print("  FilledAdler: LongWord = $%08x;" % zlib.adler32(b"\xff" * 1000000))
    print("  FilledCrc: LongWord = $%08x;" % zlib.crc32(b"\xff" * 1000000))


if __name__ == "__main__":
    sys.exit(main())
