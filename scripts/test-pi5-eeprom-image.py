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

"""Checks pi5_eeprom_image.py on a made-up EEPROM image laid out like a
Pi 5 release (read-only part, A/B partition, bootconf.txt the last file),
so no download is needed: the configuration is replaced, longer and
shorter, read back, the sections around it stay as they were, freed
space is erased, and the .sig line format is right.
"""

import hashlib
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import pi5_eeprom_image as eeprom  # noqa: E402

IMAGE_SIZE = 2 * 1024 * 1024


def section(magic, payload):
    data = struct.pack(">LL", magic, len(payload)) + payload
    while len(data) % 8:
        data += b"\xff"
    return data


def file_section(name, contents):
    payload = name.encode().ljust(eeprom.FILE_NAME_LENGTH, b"\0") + b"\0\0\0\0" + contents
    return section(eeprom.FILE_MAGIC, payload)


def padding_to(data, offset):
    gap = offset - len(data)
    return data + struct.pack(">LL", eeprom.PADDING_MAGIC, gap - 8) + b"\xff" * (gap - 8)


def made_up_image():
    data = section(0x55AAF00F, b"\x11" * 1000)
    data = padding_to(data, eeprom.READ_ONLY_SIZE)
    data += file_section("bootsys", b"\x22" * 3000)
    data = padding_to(data, eeprom.READ_ONLY_SIZE + 8192)
    data += file_section("pubkey.bin", b"\x33" * 264)
    data = padding_to(data, eeprom.READ_ONLY_SIZE + 12288)
    data += file_section("bootconf.txt", b"[all]\nBOOT_ORDER=0xf461\n")
    return bytes(data + b"\xff" * (IMAGE_SIZE - len(data)))


def check(condition, message):
    if not condition:
        sys.exit(f"pi5 EEPROM image test: {message}")


def sections_except_config(image):
    return [(s.magic, s.offset, s.length, s.name) for s in image.sections if s.name != "bootconf.txt"]


def main():
    original = made_up_image()
    image = eeprom.EepromImage(original)
    check(image.read_file("bootconf.txt") == b"[all]\nBOOT_ORDER=0xf461\n", "the configuration reads back")
    others = sections_except_config(image)

    longer = b"[all]\nBOOT_UART=1\nBOOT_ORDER=0xf12\nTFTP_IP=192.168.1.20\nDHCP_TIMEOUT=15000\n"
    image.replace_file("bootconf.txt", longer)
    check(image.read_file("bootconf.txt") == longer, "a longer configuration reads back")
    check(sections_except_config(image) == others, "the other sections stay")
    reparsed = eeprom.EepromImage(bytes(image.data))
    check(reparsed.read_file("bootconf.txt") == longer, "a longer configuration parses again")

    shorter = b"[all]\n"
    image.replace_file("bootconf.txt", shorter)
    check(image.read_file("bootconf.txt") == shorter, "a shorter configuration reads back")
    config_section = image.sections[image.find_file("bootconf.txt")]
    freed_start = config_section.offset + eeprom.FILE_CONTENTS_OFFSET + len(shorter)
    check(all(byte == 0xFF for byte in image.data[freed_start:freed_start + len(longer)]),
          "the space freed is erased")
    check(bytes(image.data[:eeprom.READ_ONLY_SIZE]) == original[:eeprom.READ_ONLY_SIZE],
          "the read-only part stays")

    try:
        image.replace_file("bootconf.txt", b"x" * (eeprom.MAX_FILE_SIZE + 1))
        check(False, "an oversized configuration is refused")
    except eeprom.EepromImageError:
        pass
    try:
        eeprom.EepromImage(b"\0" * 1000)
        check(False, "a file of the wrong size is refused")
    except eeprom.EepromImageError:
        pass

    signature = eeprom.signature_text(bytes(image.data), timestamp=1700000000).splitlines()
    check(signature == [hashlib.sha256(bytes(image.data)).hexdigest(), "ts: 1700000000", "target-soc: 2712"],
          "the .sig lines")
    print("pi5 EEPROM image test: passed")


if __name__ == "__main__":
    main()
