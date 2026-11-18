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

"""Writes the fixtures of DecompressionTest (at build time): data
compressed by Python's lzma (liblzma) and gzip (zlib), and broken copies
of it, with a manifest saying what decoding each must give.

    make-fixtures.py <directory>

Each manifest line is "NAME KIND EXPECTED [ORIGINAL]": the compressed
file NAME, the format the magic must be detected as (xz, gzip, zstd or
none), the outcome (ok, or a TDecodeResult name such as truncated, or
fail for any failure) and, for ok, the file the output must equal.
"""

import gzip
import lzma
import os
import random
import struct
import sys
import zlib


def disk_like(size, seed):
    """Mostly zeros with scattered text and random sectors, as a
    file system image is."""
    generator = random.Random(seed)
    data = bytearray(size)
    words = b"kernel ramdisk volume system image pascal block inode extent journal ".split()
    position = 0
    while position < size:
        position += generator.randrange(4096, 65536)
        length = generator.randrange(64, 4096)
        if generator.random() < 0.3:
            piece = bytes(generator.randrange(256) for _ in range(length))
        else:
            piece = b" ".join(generator.choice(words) for _ in range(length // 6))
        data[position:position + len(piece)] = piece[:max(0, size - position)]
    return bytes(data[:size])


def xz(data, check=lzma.CHECK_CRC64, preset=6):
    return lzma.compress(data, format=lzma.FORMAT_XZ, check=check, preset=preset)


def raw_lzma2(data, preset=6):
    return lzma.compress(data, format=lzma.FORMAT_RAW, filters=[{"id": lzma.FILTER_LZMA2, "preset": preset}])


def variable_integer(value):
    out = bytearray()
    while value >= 0x80:
        out.append((value & 0x7F) | 0x80)
        value >>= 7
    out.append(value)
    return bytes(out)


def pad4(data):
    return data + bytes(-len(data) % 4)


def xz_with_blocks(pieces, sizes_in_headers=True):
    """An xz stream of one block per piece, CRC-32 checked, with the
    sizes in the block headers (as multithreaded xz writes them)."""
    check_id = 1
    flags = bytes([0, check_id])
    stream = bytearray(b"\xfd7zXZ\x00" + flags + struct.pack("<I", zlib.crc32(flags)))
    records = []
    for piece in pieces:
        packed = raw_lzma2(piece)
        header_flags = 0x00
        fields = b""
        if sizes_in_headers:
            header_flags |= 0x40 | 0x80
            fields = variable_integer(len(packed)) + variable_integer(len(piece))
        # LZMA2 filter: id 0x21, one property byte (dictionary size 8 MiB: 22).
        body = bytes([header_flags]) + fields + b"\x21\x01\x16"
        size = len(body) + 1 + 4
        size += -size % 4
        header = bytes([size // 4 - 1]) + body
        header += bytes(size - 4 - len(header))
        header += struct.pack("<I", zlib.crc32(header))
        block = header + packed
        unpadded = len(block) + 4
        block = pad4(block) + struct.pack("<I", zlib.crc32(piece))
        stream += block
        records.append((unpadded, len(piece)))
    index = bytearray(b"\x00" + variable_integer(len(records)))
    for unpadded, uncompressed in records:
        index += variable_integer(unpadded) + variable_integer(uncompressed)
    index = pad4(bytes(index))
    index += struct.pack("<I", zlib.crc32(index))
    stream += index
    backward = struct.pack("<I", len(index) // 4 - 1)
    stream += struct.pack("<I", zlib.crc32(backward + flags)) + backward + flags + b"YZ"
    return bytes(stream)


def gzip_with_header_fields(data):
    """A gzip member with FEXTRA, FNAME, FCOMMENT and FHCRC."""
    header = bytearray(b"\x1f\x8b\x08" + bytes([0x02 | 0x04 | 0x08 | 0x10]) + struct.pack("<I", 0) + b"\x00\x03")
    extra = b"AB\x02\x00hi"
    header += struct.pack("<H", len(extra)) + extra
    header += b"system.img\x00" + b"a comment\x00"
    header += struct.pack("<H", zlib.crc32(header) & 0xFFFF)
    compressor = zlib.compressobj(9, zlib.DEFLATED, -15)
    body = compressor.compress(data) + compressor.flush()
    return bytes(header) + body + struct.pack("<II", zlib.crc32(data), len(data) & 0xFFFFFFFF)


def stored_deflate_gzip(data):
    compressor = zlib.compressobj(0, zlib.DEFLATED, -15)
    body = compressor.compress(data) + compressor.flush()
    return b"\x1f\x8b\x08\x00\x00\x00\x00\x00\x00\x03" + body + struct.pack("<II", zlib.crc32(data), len(data))


def flip(data, position):
    changed = bytearray(data)
    changed[position] ^= 0x55
    return bytes(changed)


def flip_last_check(stream, check_size):
    """Damages the check of an xz stream's last block."""
    index_size = (struct.unpack("<I", stream[-8:-4])[0] + 1) * 4
    return flip(stream, len(stream) - 12 - index_size - check_size)


def main():
    directory = sys.argv[1]
    os.makedirs(directory, exist_ok=True)
    lines = []

    def write(name, content):
        with open(os.path.join(directory, name), "wb") as output:
            output.write(content)

    def case(name, kind, expected, compressed, original=None):
        write(name, compressed)
        if original is None:
            lines.append(f"{name} {kind} {expected}")
        else:
            lines.append(f"{name} {kind} {expected} {original}")

    generator = random.Random(1)
    random_data = bytes(generator.randrange(256) for _ in range(300 * 1024))
    disk = disk_like(8 * 1024 * 1024, 2)
    text = (b"FreePascalOS RAM disk image test. " * 20000)[:500000]
    small = b"a"
    write("random.raw", random_data)
    write("disk.raw", disk)
    write("text.raw", text)
    write("small.raw", small)
    write("empty.raw", b"")

    # Good streams: random (stored LZMA2 chunks, stored deflate blocks),
    # highly compressible, text, tiny and empty data; every xz check.
    case("random.xz", "xz", "ok", xz(random_data), "random.raw")
    case("random.gz", "gzip", "ok", gzip.compress(random_data, 6, mtime=0), "random.raw")
    case("disk.xz", "xz", "ok", xz(disk, lzma.CHECK_CRC32), "disk.raw")
    case("disk-9e.xz", "xz", "ok", xz(disk, lzma.CHECK_CRC32, 9 | lzma.PRESET_EXTREME), "disk.raw")
    case("disk.gz", "gzip", "ok", gzip.compress(disk, 9, mtime=0), "disk.raw")
    case("disk-fast.gz", "gzip", "ok", gzip.compress(disk, 1, mtime=0), "disk.raw")
    case("text-nocheck.xz", "xz", "ok", xz(text, lzma.CHECK_NONE, 1), "text.raw")
    case("text-stored.gz", "gzip", "ok", stored_deflate_gzip(text), "text.raw")
    case("text-fields.gz", "gzip", "ok", gzip_with_header_fields(text), "text.raw")
    case("small.xz", "xz", "ok", xz(small), "small.raw")
    case("small.gz", "gzip", "ok", gzip.compress(small, mtime=0), "small.raw")
    case("empty.xz", "xz", "ok", xz(b""), "empty.raw")
    # Several blocks, with and without their sizes in the block headers.
    pieces = [disk[:3000000], disk[3000000:3000001], disk[3000001:]]
    case("disk-blocks.xz", "xz", "ok", xz_with_blocks(pieces), "disk.raw")
    case("disk-blocks-bare.xz", "xz", "ok", xz_with_blocks(pieces, sizes_in_headers=False), "disk.raw")
    # Stream padding (a boot loader rounding the file up).
    case("padded.xz", "xz", "ok", xz(text) + bytes(4), "text.raw")
    case("padded-odd.xz", "xz", "ok", xz(text) + bytes(3), "text.raw")

    # Truncated streams.
    whole_xz = xz(disk, lzma.CHECK_CRC32)
    whole_gz = gzip.compress(disk, 9, mtime=0)
    case("truncated-half.xz", "xz", "truncated", whole_xz[:len(whole_xz) // 2])
    case("truncated-footer.xz", "xz", "fail", whole_xz[:-5])
    case("truncated-header.xz", "xz", "truncated", whole_xz[:8])
    case("truncated-half.gz", "gzip", "fail", whole_gz[:len(whole_gz) // 2])
    # The member cut short but its last 8 bytes put back as a trailer,
    # so the size is right and the deflate data ends early.
    case("truncated-body.gz", "gzip", "truncated", whole_gz[:len(whole_gz) // 2] + whole_gz[-8:])

    # Checksums that do not match: the last block's check (just before
    # the index), the stream header's CRC-32, the gzip trailer's.
    case("bad-check.xz", "xz", "checksummismatch", flip_last_check(xz_with_blocks([text]), 4))
    case("bad-check64.xz", "xz", "checksummismatch", flip_last_check(xz(text), 8))
    case("bad-header.xz", "xz", "checksummismatch", flip(whole_xz, 7))
    case("bad-crc.gz", "gzip", "checksummismatch", flip(whole_gz, len(whole_gz) - 8))
    case("bad-size.gz", "gzip", "fail", flip(whole_gz, len(whole_gz) - 3))
    case("bad-hcrc.gz", "gzip", "checksummismatch", flip(gzip_with_header_fields(text), 31))
    # Damaged compressed data: any failure, never a crash.
    case("damaged.xz", "xz", "fail", flip(whole_xz, len(whole_xz) // 3))
    case("damaged.gz", "gzip", "fail", flip(whole_gz, len(whole_gz) // 3))
    case("junk-after.gz", "gzip", "fail", gzip.compress(text, mtime=0) + b"junk")

    # Unsupported and unknown formats.
    case("frame.zst", "zstd", "unsupported", b"\x28\xb5\x2f\xfd" + bytes(60))
    case("bcj.xz", "xz", "unsupported",
         lzma.compress(text, format=lzma.FORMAT_XZ, filters=[{"id": lzma.FILTER_X86},
                                                             {"id": lzma.FILTER_LZMA2, "preset": 1}]))
    case("sha256.xz", "xz", "unsupported", xz(text, lzma.CHECK_SHA256, 1))
    case("plain.img", "none", "ok", disk[:65536], None)

    with open(os.path.join(directory, "manifest.txt"), "w") as manifest:
        manifest.write("\n".join(lines) + "\n")


if __name__ == "__main__":
    main()
