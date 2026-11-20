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

"""libhttp's HPACK against libnghttp2 (through ctypes):

    check-hpack-with-nghttp2.py OURS THEIRS

decodes the blocks HttpTest's encoder wrote to OURS (and its Huffman
coding of every byte) with nghttp2's inflater, and writes blocks of
nghttp2's deflater for the same header lists to THEIRS for HttpTest to
decode. Exits with 2 (skipped) when the host has no libnghttp2."""

import ctypes
import ctypes.util
import sys


class NameValue(ctypes.Structure):
    _fields_ = [("name", ctypes.POINTER(ctypes.c_uint8)), ("value", ctypes.POINTER(ctypes.c_uint8)),
                ("namelen", ctypes.c_size_t), ("valuelen", ctypes.c_size_t), ("flags", ctypes.c_uint8)]


INFLATE_FINAL = 0x01
INFLATE_EMIT = 0x02


def header_list(index):
    """HttpTest.HpackExchange's HeaderList."""
    fields = [(b":method", b"GET"), (b":scheme", b"https"), (b":authority", b"www.example.com"),
              (b":path", b"/page/%d?q=" % index + b"z" * (index * 7)), (b"user-agent", b"FreePascalOS-libhttp/1.0"),
              (b"accept-encoding", b"gzip, deflate"), (b"cookie", b"a=b"), (b"cookie", b"session=" + b"s" * 40)]
    if index == 3:
        for number in range(1, 61):
            fields.append((b"x-filler-%d" % number, bytes([ord("a") + number % 26]) * 90))
    fields.append((b"x-binary", b"\x01\x7f\xc8\xffend"))
    return fields


def load_library():
    name = ctypes.util.find_library("nghttp2")
    if not name:
        return None
    library = ctypes.CDLL(name)
    library.nghttp2_hd_inflate_hd2.restype = ctypes.c_ssize_t
    library.nghttp2_hd_inflate_hd2.argtypes = [ctypes.c_void_p, ctypes.POINTER(NameValue), ctypes.POINTER(ctypes.c_int),
                                              ctypes.c_char_p, ctypes.c_size_t, ctypes.c_int]
    library.nghttp2_hd_deflate_hd.restype = ctypes.c_ssize_t
    library.nghttp2_hd_deflate_hd.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_size_t,
                                             ctypes.POINTER(NameValue), ctypes.c_size_t]
    library.nghttp2_hd_deflate_bound.restype = ctypes.c_size_t
    library.nghttp2_hd_deflate_bound.argtypes = [ctypes.c_void_p, ctypes.POINTER(NameValue), ctypes.c_size_t]
    return library


def inflate(library, inflater, block):
    fields = []
    data = ctypes.create_string_buffer(block, len(block))
    position = 0
    while True:
        value = NameValue()
        flags = ctypes.c_int(0)
        used = library.nghttp2_hd_inflate_hd2(inflater, ctypes.byref(value), ctypes.byref(flags),
                                              ctypes.cast(ctypes.byref(data, position), ctypes.c_char_p),
                                              len(block) - position, 1)
        if used < 0:
            raise ValueError("nghttp2 refused the block (%d)" % used)
        position += used
        if flags.value & INFLATE_EMIT:
            fields.append((ctypes.string_at(value.name, value.namelen), ctypes.string_at(value.value, value.valuelen)))
        if flags.value & INFLATE_FINAL:
            library.nghttp2_hd_inflate_end_headers(inflater)
            return fields
        if used == 0 and not flags.value & INFLATE_EMIT:
            raise ValueError("nghttp2 did not finish the block")


def deflate(library, deflater, fields):
    keep = []
    array = (NameValue * len(fields))()
    for index, (name, value) in enumerate(fields):
        name_buffer = (ctypes.c_uint8 * len(name)).from_buffer_copy(name)
        value_buffer = (ctypes.c_uint8 * max(len(value), 1)).from_buffer_copy(value or b"\0")
        keep += [name_buffer, value_buffer]
        array[index] = NameValue(ctypes.cast(name_buffer, ctypes.POINTER(ctypes.c_uint8)),
                                 ctypes.cast(value_buffer, ctypes.POINTER(ctypes.c_uint8)), len(name), len(value), 0)
    bound = library.nghttp2_hd_deflate_bound(deflater, array, len(fields))
    output = ctypes.create_string_buffer(bound)
    length = library.nghttp2_hd_deflate_hd(deflater, output, bound, array, len(fields))
    if length < 0:
        raise ValueError("nghttp2 could not encode (%d)" % length)
    return output.raw[:length]


def check_ours(library, path):
    inflater = ctypes.c_void_p()
    library.nghttp2_hd_inflate_new(ctypes.byref(inflater))
    failures = 0
    checked = 0
    block = b""
    expected = []
    for line in open(path):
        parts = line.split()
        if not parts:
            continue
        if parts[0] == "BLOCK":
            block, expected = bytes.fromhex(parts[1]), []
        elif parts[0] == "FIELD":
            expected.append(tuple(b"" if part == "-" else bytes.fromhex(part) for part in parts[1:3]))
        elif parts[0] == "END":
            checked += 1
            if inflate(library, inflater, block) != expected:
                print("FAIL nghttp2 decodes libhttp's block %d differently" % checked)
                failures += 1
        elif parts[0] == "HUFFMAN":
            coded = bytes.fromhex(parts[1])
            single = ctypes.c_void_p()
            library.nghttp2_hd_inflate_new(ctypes.byref(single))
            length = len(coded)
            prefix = bytes([0x80 | 0x7F]) + bytes([((length - 127) & 0x7F) | 0x80, (length - 127) >> 7])
            fields = inflate(library, single, b"\x00\x01x" + prefix + coded)
            if fields != [(b"x", bytes(range(256)))]:
                print("FAIL nghttp2 decodes libhttp's Huffman coding of every byte differently")
                failures += 1
            else:
                print("ok every byte Huffman coded as nghttp2 decodes it")
    print("ok nghttp2 decoded %d of libhttp's blocks" % (checked - failures))
    return failures


def write_theirs(library, path, count):
    deflater = ctypes.c_void_p()
    library.nghttp2_hd_deflate_new(ctypes.byref(deflater), 4096)
    with open(path, "w") as output:
        for index in range(count):
            fields = header_list(index)
            output.write("BLOCK %s\n" % deflate(library, deflater, fields).hex())
            for name, value in fields:
                output.write("FIELD %s %s\n" % (name.hex() or "-", value.hex() or "-"))
            output.write("END\n")


def main():
    library = load_library()
    if library is None:
        print("skipped: no libnghttp2 on this host")
        sys.exit(2)
    failures = check_ours(library, sys.argv[1])
    write_theirs(library, sys.argv[2], 6)
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
