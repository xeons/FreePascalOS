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

"""Writes the brotli and Zstandard fixtures of CompressionTest (at build
time): deterministic data compressed by the host's brotli and zstd
programs and Python's compression.zstd, small streams made by hand (each
checked with the host's decoder), and broken copies, with a manifest
saying what decoding each must give.

    make-fixtures.py <directory>

Each manifest line is "NAME FORMAT EXPECTED [ORIGINAL]": the compressed
file NAME, the format (br or zstd), the outcome and, for ok, the file
the output must equal. Outcomes: ok; truncated (the input ends inside
the data); trailing (the data ends before the input does); fail (any
failure, truncated included); any (anything but a crash or a hang:
brotli has no check to notice changed data); or the error a failure
must name (checksum, dictionary, window, frameheader, padding, size).

A format whose program is missing on the host is left out with a
warning.
"""

import os
import random
import shutil
import struct
import subprocess
import sys

try:
    from compression import zstd as python_zstd
except ImportError:
    python_zstd = None

WORDS = (b"the of and to in is that for it as was with be by on not he this are or his from at which but have "
         b"an they you were her she there been one all we their has would when if so no time out up more what "
         b"about who into than them can only other new some could these two may first then do any like my now "
         b"over such our man me even most made after also did many before must through back years where much "
         b"your way well down should because each just those people how too little state good very make world "
         b"still own see men work long get here between both life being under never day same another know while "
         b"last might us great old year off come since against go came right used take three").split()


def text(size, seed):
    """English-looking words and punctuation, with some markup."""
    generator = random.Random(seed)
    pieces = []
    length = 0
    while length < size:
        sentence = b" ".join(generator.choice(WORDS) for _ in range(generator.randrange(4, 18)))
        sentence = sentence[:1].upper() + sentence[1:] + generator.choice([b". ", b", ", b"; ", b".\n", b"! "])
        if generator.random() < 0.05:
            sentence = b'<a href="http://www.example.com/' + generator.choice(WORDS) + b'">' + sentence + b"</a>\n"
        pieces.append(sentence)
        length += len(sentence)
    return b"".join(pieces)[:size]


def multilingual(size, seed):
    """UTF-8 text in several scripts (for the UTF-8 context mode)."""
    generator = random.Random(seed)
    words = ["привет", "мир", "данные", "сжатие", "κόσμος", "δεδομένα", "日本語", "圧縮", "データ",
             "नमस्ते", "दुनिया", "hello", "world", "naïve", "café", "Straße"]
    out = []
    length = 0
    while length < size:
        word = generator.choice(words).encode("utf-8") + b" "
        out.append(word)
        length += len(word)
    return b"".join(out)[:size]


def binary(size, seed):
    """Records of little-endian numbers that change slowly (for the
    signed and MSB6 context modes)."""
    generator = random.Random(seed)
    out = bytearray()
    value = 0
    while len(out) < size:
        value += generator.randrange(-300, 300)
        out += struct.pack("<iHh", value, generator.randrange(16), generator.randrange(-50, 50))
    return bytes(out[:size])


def noise(size, seed):
    return random.Random(seed).randbytes(size)


def repetitive(size):
    pattern = b"FreePascalOS repeats itself. " * 3 + bytes(range(64))
    return (pattern * (size // len(pattern) + 1))[:size]


def run(program, arguments, data):
    result = subprocess.run([program] + arguments, input=data, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            check=True)
    return result.stdout


class BitWriter:
    """Bits lowest first, as brotli packs them."""

    def __init__(self):
        self.bits = []

    def write(self, value, count):
        for index in range(count):
            self.bits.append((value >> index) & 1)

    def pad(self):
        while len(self.bits) % 8:
            self.bits.append(0)

    def data(self):
        self.pad()
        out = bytearray()
        for start in range(0, len(self.bits), 8):
            out.append(sum(bit << index for index, bit in enumerate(self.bits[start:start + 8])))
        return bytes(out)


def simple_code(writer, symbol, alphabet_bits):
    """A simple prefix code of one symbol (takes no bits to send)."""
    writer.write(1, 2)
    writer.write(0, 2)
    writer.write(symbol, alphabet_bits)


def handmade_brotli():
    """Small streams made bit by bit: what each must decode to."""
    streams = {}
    streams["empty"] = (bytes([0x06]), b"")

    # WBITS 16, a metadata block of five bytes, then the last (empty) one.
    writer = BitWriter()
    writer.write(0, 1)
    writer.write(0, 1)
    writer.write(3, 2)
    writer.write(0, 1)
    writer.write(1, 2)
    writer.write(4, 8)
    writer.pad()
    for value in b"notes":
        writer.write(value, 8)
    writer.write(1, 1)
    writer.write(1, 1)
    streams["metadata"] = (writer.data(), b"")

    # An uncompressed meta-block, then the last (empty) one.
    writer = BitWriter()
    writer.write(0, 1)
    writer.write(0, 1)
    writer.write(0, 2)
    writer.write(len(b"stored bytes") - 1, 16)
    writer.write(1, 1)
    writer.pad()
    for value in b"stored bytes":
        writer.write(value, 8)
    writer.write(1, 1)
    writer.write(1, 1)
    streams["uncompressed"] = (writer.data(), b"stored bytes")

    def last_meta_block(length, literal, command, distance, body):
        """The last meta-block: one block type each, one tree each, all
        of them simple codes of one symbol; body writes the commands."""
        writer = BitWriter()
        writer.write(1, 1)              # WBITS 18 (pattern 0011)
        writer.write(1, 3)
        writer.write(1, 1)              # ISLAST
        writer.write(0, 1)              # ISLASTEMPTY
        writer.write(0, 2)              # MNIBBLES 4
        writer.write(length - 1, 16)
        writer.write(0, 1)              # NBLTYPESL 1
        writer.write(0, 1)              # NBLTYPESI 1
        writer.write(0, 1)              # NBLTYPESD 1
        writer.write(0, 2)              # NPOSTFIX
        writer.write(0, 4)              # NDIRECT
        writer.write(0, 2)              # context mode LSB6
        writer.write(0, 1)              # NTREESL 1
        writer.write(0, 1)              # NTREESD 1
        simple_code(writer, literal, 8)
        simple_code(writer, command, 10)
        simple_code(writer, distance, 6)
        body(writer)
        return writer.data()

    # Insert code 5, copy code 0, implicit distance (command 40): five
    # literals, all "a"; the copy is not done (the meta-block is full).
    streams["literals"] = (last_meta_block(5, ord("a"), 40, 0, lambda writer: None), b"aaaaa")
    # Insert 0, copy 4, explicit distance (command 130); distance code 16
    # with one extra bit 0 is distance 1, past the output: word 0 of
    # length 4, untransformed.
    streams["dictionary"] = (last_meta_block(4, 0, 130, 16, lambda writer: writer.write(0, 1)), b"time")
    # Distance code 32 with nine extra bits 4: distance 1025, word 1024 of
    # length 4: word 0 with transform 1 (a space after it).
    streams["transform"] = (last_meta_block(5, 0, 130, 32, lambda writer: writer.write(4, 9)), b"time ")
    return streams


def zstd_skippable(payload, nibble=0):
    return struct.pack("<II", 0x184D2A50 + nibble, len(payload)) + payload


class Manifest:
    def __init__(self, directory):
        self.directory = directory
        self.lines = []

    def original(self, name, data):
        with open(os.path.join(self.directory, name), "wb") as output:
            output.write(data)

    def add(self, name, kind, data, expected, original=None):
        with open(os.path.join(self.directory, name), "wb") as output:
            output.write(data)
        line = "%s %s %s" % (name, kind, expected)
        if original:
            line += " " + original
        self.lines.append(line)

    def write(self):
        with open(os.path.join(self.directory, "manifest.txt"), "w") as output:
            output.write("\n".join(self.lines) + "\n")


def broken_copies(manifest, name, kind, compressed, changed_expected):
    """Cut short in a few places, and with bytes changed."""
    if len(compressed) > 2:
        manifest.add(name + ".cut-half", kind, compressed[:len(compressed) // 2], "truncated")
        manifest.add(name + ".cut-last", kind, compressed[:-1], "truncated")
    if len(compressed) > 16:
        changed = bytearray(compressed)
        generator = random.Random(len(compressed))
        for _ in range(3):
            position = generator.randrange(8, len(changed))
            changed[position] ^= 1 << generator.randrange(8)
        manifest.add(name + ".changed", kind, bytes(changed), changed_expected)


def brotli_fixtures(manifest, inputs):
    if not shutil.which("brotli"):
        print("make-fixtures.py: no brotli program; brotli fixtures left out", file=sys.stderr)
        return
    for name, (stream, expected) in handmade_brotli().items():
        decoded = run("brotli", ["-d", "-c"], stream)
        if decoded != expected:
            sys.exit("make-fixtures.py: brotli decodes the hand-made %s stream to %r" % (name, decoded))
        manifest.original("hand-" + name + ".out", expected)
        manifest.add("hand-" + name + ".br", "br", stream, "ok", "hand-" + name + ".out")
    manifest.add("hand-bad-window.br", "br", bytes([0x11, 0x03]), "window")
    manifest.add("hand-padding.br", "br", bytes([0x06 | 0x80]), "padding")
    manifest.add("hand-trailing.br", "br", bytes([0x06, 0x00]), "trailing")

    settings = [
        ("q0", ["-q", "0"]),
        ("q1", ["-q", "1"]),
        ("q5", ["-q", "5"]),
        ("q9-w10", ["-q", "9", "-w", "10"]),
        ("q11", ["-q", "11"]),
        ("q11-w24", ["-q", "11", "-w", "24"]),
    ]
    for input_name, data in inputs.items():
        for setting_name, arguments in settings:
            if len(data) > 1024 * 1024 and setting_name.startswith("q11"):
                continue
            name = "%s.%s.br" % (input_name, setting_name)
            compressed = run("brotli", arguments + ["-c"], data)
            manifest.add(name, "br", compressed, "ok", input_name)
            if setting_name in ("q5", "q11") and len(data) > 0:
                broken_copies(manifest, name, "br", compressed, "any")
    comment = run("brotli", ["-q", "6", "-c", "-C", "RnJlZVBhc2NhbE9T"], inputs["text"])
    manifest.add("text.comment.br", "br", comment, "ok", "text")


def zstd_fixtures(manifest, inputs):
    if not shutil.which("zstd"):
        print("make-fixtures.py: no zstd program; zstd fixtures left out", file=sys.stderr)
        return
    settings = [
        ("l1", ["-1"]),
        ("l3", ["-3"]),
        ("l9-nocheck", ["-9", "--no-check"]),
        ("l19", ["-19"]),
        ("l22", ["--ultra", "-22"]),
        ("w10", ["-5", "--zstd=wlog=10"]),
        ("long", ["-3", "--long=24"]),
    ]
    for input_name, data in inputs.items():
        for setting_name, arguments in settings:
            if len(data) > 1024 * 1024 and setting_name in ("l19", "l22"):
                continue
            name = "%s.%s.zst" % (input_name, setting_name)
            compressed = run("zstd", ["-q", "-c"] + arguments, data)
            manifest.add(name, "zstd", compressed, "ok", input_name)
            if setting_name == "l3" and len(data) > 0:
                broken_copies(manifest, name, "zstd", compressed, "fail")
        # Streamed (no content size in the header).
        streamed = run("sh", ["-c", "cat | zstd -q -c -3 -"], data)
        manifest.add("%s.stream.zst" % input_name, "zstd", streamed, "ok", input_name)

    text = inputs["text"]
    first = run("zstd", ["-q", "-c", "-3"], text)
    second = run("zstd", ["-q", "-c", "-19", "--no-check"], inputs["binary"])
    manifest.original("text-binary.out", text + inputs["binary"])
    manifest.add("frames.zst", "zstd", first + second, "ok", "text-binary.out")
    manifest.add("skippable.zst", "zstd", zstd_skippable(b"metadata") + first + zstd_skippable(b"", 15) + second,
                 "ok", "text-binary.out")
    manifest.add("only-skippable.zst", "zstd", zstd_skippable(b"x" * 300, 7), "ok", "empty")
    manifest.add("trailing-junk.zst", "zstd", first + b"\x00\x01\x02\x03", "frameheader")

    checked = bytearray(first)
    checked[-1] ^= 0x40
    manifest.add("bad-checksum.zst", "zstd", bytes(checked), "checksum")
    reserved = bytearray(first)
    reserved[4] |= 0x08
    manifest.add("reserved-bit.zst", "zstd", bytes(reserved), "frameheader")
    manifest.add("bad-magic.zst", "zstd", b"\x29" + first[1:], "frameheader")
    # A frame asking for dictionary 7, and one asking for a 2 TiB window.
    manifest.add("dictionary.zst", "zstd", b"\x28\xb5\x2f\xfd\x01\x00\x07" + b"\x01\x00\x00", "dictionary")
    manifest.add("huge-window.zst", "zstd", b"\x28\xb5\x2f\xfd\x00\xf8" + b"\x01\x00\x00", "window")
    # A single segment frame whose stated size (13) is one more than its
    # content: a last raw block of twelve bytes.
    wrong_size = b"\x28\xb5\x2f\xfd\x20\x0d" + struct.pack("<I", 1 | (12 << 3))[:3] + b"twelve bytes"
    manifest.add("wrong-size.zst", "zstd", wrong_size, "size")
    manifest.original("twelve.out", b"twelve bytes")
    manifest.add("right-size.zst", "zstd", wrong_size[:5] + b"\x0c" + wrong_size[6:], "ok", "twelve.out")

    if python_zstd is not None:
        parameter = python_zstd.CompressionParameter
        options = {parameter.compression_level: 7, parameter.checksum_flag: 1, parameter.content_size_flag: 0}
        manifest.add("text.python.zst", "zstd", python_zstd.compress(text, options=options), "ok", "text")
        options = {parameter.compression_level: 1, parameter.checksum_flag: 0, parameter.window_log: 12}
        manifest.add("binary.python.zst", "zstd", python_zstd.compress(inputs["binary"], options=options), "ok",
                     "binary")
        manifest.add("empty.python.zst", "zstd", python_zstd.compress(b""), "ok", "empty")
    else:
        print("make-fixtures.py: no compression.zstd; its fixtures left out", file=sys.stderr)


def main():
    if len(sys.argv) != 2:
        sys.exit("usage: make-fixtures.py <directory>")
    directory = sys.argv[1]
    os.makedirs(directory, exist_ok=True)
    manifest = Manifest(directory)
    inputs = {
        "empty": b"",
        "byte": b"a",
        "text": text(200000, 1),
        "multilingual": multilingual(60000, 2),
        "binary": binary(80000, 3),
        "noise": noise(100000, 4),
        "zeros": bytes(300000),
        "repetitive": repetitive(3 * 1024 * 1024),
    }
    for name, data in inputs.items():
        manifest.original(name, data)
    brotli_fixtures(manifest, inputs)
    zstd_fixtures(manifest, inputs)
    manifest.write()


if __name__ == "__main__":
    main()
