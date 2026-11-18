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

"""The Raspberry Pi bootloader EEPROM image format: replacing its
configuration file (bootconf.txt), and the .sig file recovery.bin checks.

The image (512 KiB or 2 MiB) is a chain of sections, each an 8-byte
header - a big-endian magic number and the length of what follows - then
the data, the next section starting at the next multiple of 8. Magic
numbers match 0x55aaf00f under the mask 0xfffff00f; 0x55aaf11f is a file
(after the header a 12-byte name padded with zeros and a 4-byte word,
zero in the files changed here, then the contents; the length counts
all three), 0x55aafeef padding. All zeros or
all ones end the chain. The last 4 KiB belong to the bootloader.

Newer (A/B) images keep a read-only part (the first 64 KiB) and a first
partition of 988 KiB after it; bootconf.txt is the one in that
partition. A file can grow up to the next section that is not padding,
and in any case no further than one 4 KiB erase sector (4076 bytes of
contents). Space freed is set to the erase value 0xff, with a padding
section over it where it has room for one (not after the last section).

The .sig file is the image's SHA-256 in hex, then "ts: SECONDS" and
"target-soc: 2712", one per line.
"""

import hashlib
import struct
import time

VALID_IMAGE_SIZES = (512 * 1024, 2 * 1024 * 1024)
SECTION_MAGIC = 0x55AAF00F
SECTION_MAGIC_MASK = 0xFFFFF00F
FILE_MAGIC = 0x55AAF11F
PADDING_MAGIC = 0x55AAFEEF
FILE_NAME_LENGTH = 12
FILE_CONTENTS_OFFSET = 8 + FILE_NAME_LENGTH + 4
FILE_LENGTH_OVERHEAD = FILE_NAME_LENGTH + 4
ERASE_SECTOR_SIZE = 4096
MAX_FILE_SIZE = ERASE_SECTOR_SIZE - FILE_CONTENTS_OFFSET
READ_ONLY_SIZE = 64 * 1024
PARTITION_SIZE = 988 * 1024
CONFIG_FILE_NAME = "bootconf.txt"


class EepromImageError(Exception):
    pass


class Section:
    def __init__(self, magic, offset, length, name):
        self.magic = magic
        self.offset = offset
        self.length = length
        self.name = name


class EepromImage:
    def __init__(self, data):
        if len(data) not in VALID_IMAGE_SIZES:
            raise EepromImageError(f"an EEPROM image is 512 KiB or 2 MiB, not {len(data)} bytes")
        self.data = bytearray(data)
        self.sections = self.parse()

    def parse(self):
        sections = []
        offset = 0
        while offset + 8 <= len(self.data):
            magic, length = struct.unpack_from(">LL", self.data, offset)
            if magic in (0, 0xFFFFFFFF):
                break
            if magic & SECTION_MAGIC_MASK != SECTION_MAGIC:
                raise EepromImageError(f"not a bootloader EEPROM image (magic {magic:08x} at {offset})")
            name = ""
            if magic == FILE_MAGIC:
                raw_name = bytes(self.data[offset + 8:offset + 8 + FILE_NAME_LENGTH])
                name = raw_name.rstrip(b"\0").decode("ascii", errors="replace")
            sections.append(Section(magic, offset, length, name))
            offset = (offset + 8 + length + 7) & ~7
        return sections

    def find_file(self, name):
        """The index of the file section, the one in the first partition if
        the image has one, else the first of that name."""
        candidates = [index for index, section in enumerate(self.sections)
                      if section.magic == FILE_MAGIC and section.name == name]
        if not candidates:
            raise EepromImageError(f"the image has no {name}")
        for index in candidates:
            if READ_ONLY_SIZE <= self.sections[index].offset < READ_ONLY_SIZE + PARTITION_SIZE:
                return index
        return candidates[0]

    def read_file(self, name):
        section = self.sections[self.find_file(name)]
        start = section.offset + FILE_CONTENTS_OFFSET
        return bytes(self.data[start:start + section.length - FILE_LENGTH_OVERHEAD])

    def space_end(self, index):
        """Where the file at index must end: the next section that is not
        padding, the end of its partition, or the bootloader's last 4 KiB."""
        section = self.sections[index]
        end = len(self.data) - ERASE_SECTOR_SIZE
        if READ_ONLY_SIZE <= section.offset < READ_ONLY_SIZE + PARTITION_SIZE:
            end = min(end, READ_ONLY_SIZE + PARTITION_SIZE)
        for following in self.sections[index + 1:]:
            if following.magic != PADDING_MAGIC:
                end = min(end, following.offset)
                break
        return end

    def replace_file(self, name, contents):
        if len(contents) > MAX_FILE_SIZE:
            raise EepromImageError(f"{name} is {len(contents)} bytes, at most {MAX_FILE_SIZE} fit")
        index = self.find_file(name)
        section = self.sections[index]
        is_last = index == len(self.sections) - 1
        end = self.space_end(index)
        contents_start = section.offset + FILE_CONTENTS_OFFSET
        if contents_start + len(contents) > end:
            raise EepromImageError(f"{name} does not fit: {end - contents_start} bytes of room")
        struct.pack_into(">L", self.data, section.offset + 4, len(contents) + FILE_LENGTH_OVERHEAD)
        self.data[contents_start:contents_start + len(contents)] = contents
        free = contents_start + len(contents)
        while free % 8:
            self.data[free] = 0xFF
            free += 1
        padding = end - free
        if padding >= 8 and not is_last:
            struct.pack_into(">LL", self.data, free, PADDING_MAGIC, padding - 8)
            free += 8
        self.data[free:end] = b"\xff" * (end - free)
        self.sections = self.parse()


def signature_text(image_bytes, timestamp=None, target_soc="2712"):
    """The .sig file recovery.bin and self-update check the image with."""
    seconds = int(time.time()) if timestamp is None else int(timestamp)
    lines = [hashlib.sha256(image_bytes).hexdigest(), f"ts: {seconds}"]
    if target_soc:
        lines.append(f"target-soc: {target_soc}")
    return "\n".join(lines) + "\n"
