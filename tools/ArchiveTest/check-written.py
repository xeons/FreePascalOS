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

"""Checks the zip files ArchiveTest wrote with Python's zipfile: every
member's CRC (testzip), names in order, data, modes, folder flags, the
DOS time and the extended timestamp field, member counts and the ZIP64
end records where they were forced or needed.

    check-written.py <sample directory>

written-manifest.txt there has the lines ArchiveTest wrote:
    entry ARCHIVE NAME KIND SIZE CRC32 MTIME MODE(octal)
    count ARCHIVE NUMBER
    zip64 ARCHIVE
Prints what fails and exits with 1 if anything did.
"""

import os
import struct
import sys
import time
import zipfile
import zlib

FAILURES = []


def fail(message):
    FAILURES.append(message)
    print('FAIL ' + message)


def extended_time(extra):
    position = 0
    while position + 4 <= len(extra):
        field_id, size = struct.unpack_from('<HH', extra, position)
        if field_id == 0x5455 and size >= 5 and extra[position + 4] & 1:
            return struct.unpack_from('<l', extra, position + 5)[0]
        position += 4 + size
    return None


def check_entry(zip_file, archive, fields):
    name, kind, size, crc, mtime, mode = fields
    try:
        info = zip_file.getinfo(name)
    except KeyError:
        fail('%s: %s is missing' % (archive, name))
        return
    if (kind == 'd') != info.is_dir():
        fail('%s %s: folder or not' % (archive, name))
    if info.file_size != int(size):
        fail('%s %s: size %d, not %s' % (archive, name, info.file_size, size))
    data = zip_file.read(name)
    if '%08x' % (zlib.crc32(data) & 0xFFFFFFFF) != crc or len(data) != int(size):
        fail('%s %s: data differs' % (archive, name))
    if info.create_system != 3:
        fail('%s %s: not made by Unix (%d)' % (archive, name, info.create_system))
    if (info.external_attr >> 16) != int(mode, 8):
        fail('%s %s: mode %o, not %s' % (archive, name, info.external_attr >> 16, mode))
    if kind == 'd' and not info.external_attr & 0x10:
        fail('%s %s: no DOS folder attribute' % (archive, name))
    if not name.isascii() and not info.flag_bits & 0x800:
        fail('%s %s: no UTF-8 flag' % (archive, name))
    seconds = int(mtime)
    if extended_time(info.extra) != seconds:
        fail('%s %s: extended timestamp %s, not %d' % (archive, name, extended_time(info.extra), seconds))
    expected = time.gmtime(max(seconds, 315532800))[:6]
    expected = expected[:5] + (expected[5] // 2 * 2,)
    if info.date_time != expected:
        fail('%s %s: DOS time %s, not %s' % (archive, name, info.date_time, expected))


def main():
    directory = sys.argv[1]
    archives = {}
    with open(os.path.join(directory, 'written-manifest.txt'), encoding='utf-8') as manifest:
        for line in manifest:
            fields = line.rstrip('\n').split('\t')
            if fields[0]:
                archives.setdefault(fields[1], []).append(fields)
    checked = 0
    for archive, lines in archives.items():
        path = os.path.join(directory, archive)
        with zipfile.ZipFile(path) as zip_file:
            bad = zip_file.testzip()
            if bad is not None:
                fail('%s: testzip says %s is damaged' % (archive, bad))
            names = [fields[2] for fields in lines if fields[0] == 'entry']
            if names and zip_file.namelist() != names:
                fail('%s: names %s, not %s' % (archive, zip_file.namelist(), names))
            for fields in lines:
                if fields[0] == 'entry':
                    check_entry(zip_file, archive, fields[2:8])
                    checked += 1
                elif fields[0] == 'count' and len(zip_file.infolist()) != int(fields[2]):
                    fail('%s: %d members, not %s' % (archive, len(zip_file.infolist()), fields[2]))
        with open(path, 'rb') as file:
            data = file.read()
        # No comment is written: the locator is right before the 22-byte end record.
        has_zip64 = data[-42:-38] == b'PK\x06\x07'
        wants_zip64 = any(fields[0] == 'zip64' for fields in lines)
        if has_zip64 != wants_zip64:
            fail('%s: ZIP64 end records %s' % (archive, 'present' if has_zip64 else 'missing'))
    if FAILURES:
        sys.exit(1)
    print('%d archives, %d members as written' % (len(archives), checked))


if __name__ == '__main__':
    main()
