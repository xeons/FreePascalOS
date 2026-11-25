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

"""Malformed AML for AmlTest --malformed: small SSDTs, each built to reach
one of the ways firmware tables could make the interpreter write outside
its buffers, recurse without end or loop for ever.  Each defines a method
\\Txxx; the interpreter must load and run them all without crashing or
writing outside its blocks, and every method must fail (the interpreter
gives up on it, or the object it reaches was never made).

    make-malformed.py OUTPUT_FOLDER
"""

import os
import struct
import sys


# --- A tiny AML assembler ---------------------------------------------------

def package_length(content_length):
    """The PkgLength encoding of a package whose content (after the
    length) is CONTENT_LENGTH bytes."""
    if content_length + 1 < 0x40:
        return bytes([content_length + 1])
    for count in (1, 2, 3):
        total = content_length + 1 + count
        if total < (1 << (4 + 8 * count)):
            lead = (count << 6) | (total & 0x0F)
            rest = [(total >> (4 + 8 * index)) & 0xFF for index in range(count)]
            return bytes([lead] + rest)
    raise ValueError("package too long")


def package(opcode, *parts):
    content = b"".join(parts)
    return opcode + package_length(len(content)) + content


def name(text):
    text = text.lstrip("\\")
    segments = text.split(".")
    encoded = b""
    for segment in segments:
        encoded += segment.ljust(4, "_").encode()
    prefix = b"\\"
    if len(segments) == 2:
        return prefix + b"\x2E" + encoded
    if len(segments) > 2:
        return prefix + b"\x2F" + bytes([len(segments)]) + encoded
    return prefix + encoded


def integer(value):
    if value == 0:
        return b"\x00"
    if value == 1:
        return b"\x01"
    if value < 0x100:
        return b"\x0A" + bytes([value])
    if value < 0x10000:
        return b"\x0B" + struct.pack("<H", value)
    if value < 0x100000000:
        return b"\x0C" + struct.pack("<I", value)
    return b"\x0E" + struct.pack("<Q", value)


def string(text):
    return b"\x0D" + text.encode() + b"\x00"


def method(path, argument_count, *body):
    return package(b"\x14", name(path), bytes([argument_count]), *body)


def define_name(path, value):
    return b"\x08" + name(path) + value


def buffer(size, contents=b""):
    return package(b"\x11", integer(size), contents)


def aml_package(*elements):
    return package(b"\x12", bytes([len(elements)]), *elements)


NULL_TARGET = b"\x00"
ARG0 = b"\x68"
LOCAL0 = b"\x60"


def store(value, target):
    return b"\x70" + value + target


def ref_of(target):
    return b"\x71" + target


def index(source, position):
    return b"\x88" + source + position + NULL_TARGET


def add(left, right):
    return b"\x72" + left + right + NULL_TARGET


def subtract(left, right):
    return b"\x74" + left + right + NULL_TARGET


def concatenate(left, right):
    return b"\x73" + left + right + NULL_TARGET


def return_value(value):
    return b"\xA4" + value


def while_loop(predicate, *body):
    return package(b"\xA2", predicate, *body)


def if_then(predicate, *body):
    return package(b"\xA0", predicate, *body)


def operation_region(path, space, offset, length):
    return b"\x5B\x80" + name(path) + bytes([space]) + integer(offset) + integer(length)


def named_field(segment, bits):
    return segment.encode() + encode_length(bits)


def encode_length(value):
    """A field unit's length: the PkgLength encoding of the number itself."""
    if value < 0x40:
        return bytes([value])
    for count in (1, 2, 3):
        if value < (1 << (4 + 8 * count)):
            lead = (count << 6) | (value & 0x0F)
            rest = [(value >> (4 + 8 * index)) & 0xFF for index in range(count)]
            return bytes([lead] + rest)
    raise ValueError("field too long")


def reserved_field(bits):
    return b"\x00" + encode_length(bits)


def field(region, flags, *units):
    return package(b"\x5B\x81", name(region), bytes([flags]), *units)


def index_field(index_name, data_name, flags, *units):
    return package(b"\x5B\x86", name(index_name), name(data_name), bytes([flags]), *units)


def create_field(source, bit_index, bit_count, path):
    return b"\x5B\x13" + source + integer(bit_index) + integer(bit_count) + name(path)


def table(*body):
    content = b"".join(body)
    length = 36 + len(content)
    header = b"SSDT" + struct.pack("<I", length) + bytes([2, 0]) + b"FPOS  " + b"MALFORMD" + \
        struct.pack("<I", 1) + b"FPOS" + struct.pack("<I", 1)
    assert len(header) == 36
    return header + content


# --- The cases ----------------------------------------------------------------

def cases():
    yield "buffer-field-huge", table(
        # A field 2^35 + 8 bits long over a 4 byte buffer: its length used
        # to be cut to 32 bits when the field was read.
        define_name("B001", buffer(4, b"\x00\x00\x00\x00")),
        method("T001", 0,
               create_field(name("B001"), 0, 0x800000008, "F001"),
               return_value(name("F001"))))

    yield "buffer-field-past-end", table(
        define_name("B002", buffer(4, b"\x00\x00\x00\x00")),
        method("T002", 0,
               create_field(name("B002"), 24, 64, "F002"),
               store(integer(0xFFFFFFFF), name("F002")),
               return_value(name("F002"))))

    yield "concatenate-package", table(
        # A string joined with something that converts to no string.
        method("T003", 0,
               return_value(concatenate(string("ab"), aml_package(integer(1))))))

    yield "reference-to-itself", table(
        # A name holding a reference to itself, then stored to.
        define_name("N004", integer(0)),
        method("T004", 0,
               store(ref_of(name("N004")), name("N004")),
               store(integer(5), name("N004")),
               return_value(integer(1))))

    yield "package-in-itself", table(
        # A package stored into its own element again and again: copies
        # nested ever deeper.
        define_name("P005", aml_package(integer(0))),
        method("T005", 0,
               while_loop(b"\x01",
                          store(name("P005"), index(name("P005"), b"\x00"))),
               return_value(integer(1))))

    nested = integer(1)
    for _ in range(600):
        nested = add(nested, b"\x01")
    yield "operators-nested-deep", table(
        # 600 operators inside one another.
        method("T006", 0, return_value(nested)))

    yield "method-calls-explode", table(
        # Each call makes two more, 22 deep (within the call depth
        # limit): 2^22 calls.
        method("M007", 1,
               if_then(ARG0,
                       name("M007") + subtract(ARG0, b"\x01"),
                       name("M007") + subtract(ARG0, b"\x01")),
               return_value(integer(1))),
        method("T007", 0, return_value(name("M007") + integer(22))))

    yield "field-past-region", table(
        # A field 8 bytes into a 4 byte region.
        operation_region("R008", 0, 0x1000, 4),
        field("R008", 0x01, reserved_field(64), named_field("F008", 8)),
        method("T008", 0, return_value(name("F008"))))

    yield "index-field-missing-names", table(
        # An index field over names that do not exist.
        index_field("NOP1", "NOP2", 0x01, named_field("F009", 8)),
        method("T009", 0, return_value(name("F009"))))

    chain = [operation_region("R010", 0, 0x2000, 16),
             field("R010", 0x01, named_field("I000", 8), named_field("D000", 8))]
    previous_index, previous_data = "I000", "D000"
    for level in range(1, 200):
        index_name = "I%03d" % level
        data_name = "D%03d" % level
        chain.append(index_field(previous_index, previous_data, 0x01,
                                 named_field(index_name, 8), named_field(data_name, 8)))
        previous_index, previous_data = index_name, data_name
    yield "index-fields-chained", table(
        # 200 index fields, each reached through the one before.
        *chain,
        method("T010", 0, return_value(name(previous_data))))


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    output = sys.argv[1]
    os.makedirs(output, exist_ok=True)
    names = []
    for case_name, data in cases():
        with open(os.path.join(output, case_name + ".aml"), "wb") as file:
            file.write(data)
        names.append(case_name)
    with open(os.path.join(output, "CASES"), "w") as file:
        file.write("\n".join(names) + "\n")


if __name__ == "__main__":
    main()
