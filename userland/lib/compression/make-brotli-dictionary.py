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

"""Writes Compression.BrotliDictionaryData.inc: brotli's static
dictionary (RFC 7932 appendix A, 122,784 bytes) as a Pascal constant.

    make-brotli-dictionary.py [--library PATH] OUTPUT
    make-brotli-dictionary.py --check INCLUDE

The bytes come from the host's brotli library (libbrotlicommon), which
holds the dictionary and hands it out through BrotliGetDictionary(); they
are checked against the size and CRC-32 (0x5136cb04) the RFC gives
before anything is written. The include is checked in, written once
with this script, so building the system needs no brotli on the build
machine; --check reads an include back and checks it the same way.
"""

import argparse
import ctypes
import ctypes.util
import re
import sys
import zlib

DICTIONARY_SIZE = 122784
DICTIONARY_CRC32 = 0x5136CB04
BYTES_PER_LINE = 30

# The words of each length (RFC 7932 section 8, NDBITS): the dictionary
# is these runs of words, length 4 first.
WORD_BITS_BY_LENGTH = [0, 0, 0, 0, 10, 10, 11, 11, 10, 10, 10, 10, 10, 9, 9, 8, 7, 7, 8, 7, 7, 6, 6, 5, 5]


class BrotliDictionary(ctypes.Structure):
    """struct BrotliDictionary of brotli/common/dictionary.h."""
    _fields_ = [
        ("size_bits_by_length", ctypes.c_uint8 * 32),
        ("offsets_by_length", ctypes.c_uint32 * 32),
        ("data_size", ctypes.c_size_t),
        ("data", ctypes.POINTER(ctypes.c_uint8)),
    ]


def library_candidates(explicit):
    if explicit:
        return [explicit]
    names = []
    found = ctypes.util.find_library("brotlicommon")
    if found:
        names.append(found)
    names += ["libbrotlicommon.so.1", "libbrotlicommon.so", "libbrotlicommon.dylib"]
    return names


def dictionary_from_library(explicit):
    errors = []
    for name in library_candidates(explicit):
        try:
            library = ctypes.CDLL(name)
        except OSError as error:
            errors.append(str(error))
            continue
        library.BrotliGetDictionary.restype = ctypes.POINTER(BrotliDictionary)
        library.BrotliGetDictionary.argtypes = []
        dictionary = library.BrotliGetDictionary().contents
        bits = list(dictionary.size_bits_by_length)[:len(WORD_BITS_BY_LENGTH)]
        if bits != WORD_BITS_BY_LENGTH:
            sys.exit("make-brotli-dictionary.py: %s: the word counts are not RFC 7932's" % name)
        if dictionary.data_size != DICTIONARY_SIZE or not dictionary.data:
            sys.exit("make-brotli-dictionary.py: %s: the dictionary is %d bytes, not %d"
                     % (name, dictionary.data_size, DICTIONARY_SIZE))
        return ctypes.string_at(dictionary.data, dictionary.data_size)
    sys.exit("make-brotli-dictionary.py: no brotli library on this machine (%s)" % "; ".join(errors))


def check(data, source):
    if len(data) != DICTIONARY_SIZE:
        sys.exit("make-brotli-dictionary.py: %s: %d bytes, not %d" % (source, len(data), DICTIONARY_SIZE))
    crc = zlib.crc32(data) & 0xFFFFFFFF
    if crc != DICTIONARY_CRC32:
        sys.exit("make-brotli-dictionary.py: %s: CRC-32 %08x, not %08x" % (source, crc, DICTIONARY_CRC32))


def write_include(data, path):
    lines = [
        "{",
        "  Brotli's static dictionary (RFC 7932 appendix A): %d bytes, CRC-32" % DICTIONARY_SIZE,
        "  %08X. Written by make-brotli-dictionary.py from the host's brotli" % DICTIONARY_CRC32,
        "  library and checked against the RFC; do not edit.",
        "}",
        "const",
        "  BrotliDictionarySize = %d;" % DICTIONARY_SIZE,
        "  BrotliDictionaryData: array[0..BrotliDictionarySize - 1] of Byte = (",
    ]
    for start in range(0, len(data), BYTES_PER_LINE):
        piece = data[start:start + BYTES_PER_LINE]
        text = ",".join("$%02X" % value for value in piece)
        if start + BYTES_PER_LINE < len(data):
            text += ","
        lines.append("    " + text)
    lines.append("  );")
    with open(path, "w", encoding="ascii", newline="\n") as output:
        output.write("\n".join(lines) + "\n")


def read_include(path):
    with open(path, encoding="ascii") as source:
        text = source.read()
    body = text.split("of Byte = (", 1)[1].rsplit(");", 1)[0]
    return bytes(int(value, 16) for value in re.findall(r"\$([0-9A-Fa-f]{2})", body))


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--library", help="the brotli library to take the dictionary from")
    parser.add_argument("--check", action="store_true", help="check an existing include instead")
    parser.add_argument("path")
    arguments = parser.parse_args()
    if arguments.check:
        check(read_include(arguments.path), arguments.path)
        print("%s: %d bytes, CRC-32 %08x" % (arguments.path, DICTIONARY_SIZE, DICTIONARY_CRC32))
        return
    data = dictionary_from_library(arguments.library)
    check(data, "the library's dictionary")
    write_include(data, arguments.path)


if __name__ == "__main__":
    main()
