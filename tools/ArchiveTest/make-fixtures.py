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

"""Writes the fixtures of ArchiveTest (at build time): zip files made by
Python's zipfile (stored, deflated, folders, a Unicode name, an empty
file, a symbolic link, data larger than 64 KiB, ZIP64 records, data
descriptors, more than 65535 members), some patched by hand (a CP437
name, an encrypted flag, a wrong CRC), tar files made by tarfile
(ustar, GNU long names, pax, gzip-compressed) and an old v7 one made
here, with a manifest of what reading each must give.

    make-fixtures.py <directory>

Manifest lines, fields separated by tabs:
    format    ARCHIVE  zip|tar|targz|tarzst|tarxz|unknown
    count     ARCHIVE  NUMBER-OF-MEMBERS
    entry     ARCHIVE  NAME  KIND(f|d|l)  SIZE  CRC32(hex)  MTIME  MODE(octal, 0 for none)  LINK-TARGET
    encrypted ARCHIVE  NAME
    badcrc    ARCHIVE  NAME
    unsafe    ARCHIVE  NUMBER-OF-UNSAFE-NAMES
A link's SIZE and CRC32 are those of its target text.
"""

import calendar
import gzip
import io
import lzma
import os
import random
import struct
import sys
import tarfile
import zipfile
import zlib
from compression import zstd

MANIFEST = []


def crc_hex(data):
    return '%08x' % (zlib.crc32(data) & 0xFFFFFFFF)


def note(*fields):
    MANIFEST.append('\t'.join(str(field) for field in fields))


def note_entry(archive, name, kind, data, mtime, mode, target=''):
    note('entry', archive, name, kind, len(data), crc_hex(data), mtime, '%o' % mode, target)


def mixed_data(size, seed):
    """Half text, half random bytes: deflate shrinks it, but not to nothing."""
    generator = random.Random(seed)
    pieces = []
    total = 0
    while total < size:
        if generator.random() < 0.5:
            piece = (b'line %d of the archive test, ' % generator.randrange(1000)) * 4
        else:
            piece = bytes(generator.randrange(256) for _ in range(200))
        pieces.append(piece)
        total += len(piece)
    return b''.join(pieces)[:size]


def zip_info(name, date_time, mode, compress):
    info = zipfile.ZipInfo(name, date_time)
    info.create_system = 3
    info.external_attr = mode << 16
    if name.endswith('/'):
        info.external_attr |= 0x10
    info.compress_type = compress
    return info


def write_zip_members(directory, archive, compress):
    """The common members, written with compress; returns the file name."""
    date_time = (2024, 5, 17, 13, 45, 30)
    mtime = calendar.timegm(date_time + (0, 0, 0))
    members = [
        ('docs/', b'', 0o40755, 'd'),
        ('docs/readme.txt', b'Hello from the archive test.\n' * 20, 0o100644, 'f'),
        ('docs/empty.txt', b'', 0o100644, 'f'),
        ('docs/café 日本.txt', 'Unicode content ✓\n'.encode('utf-8'), 0o100644, 'f'),
        ('bin/run.sh', b'#!/bin/sh\necho run\n', 0o100755, 'f'),
        ('data/big.bin', mixed_data(200000, 7), 0o100600, 'f'),
        ('data/random.bin', random.Random(11).randbytes(70000), 0o100644, 'f'),
    ]
    path = os.path.join(directory, archive)
    with zipfile.ZipFile(path, 'w') as zip_file:
        for name, data, mode, kind in members:
            zip_file.writestr(zip_info(name, date_time, mode, compress), data)
            note_entry(archive, name, kind, data, mtime, mode)
        # A symbolic link: its data is the target.
        target = b'../docs/readme.txt'
        zip_file.writestr(zip_info('links/readme', date_time, 0o120777, zipfile.ZIP_STORED), target)
        note_entry(archive, 'links/readme', 'l', target, mtime, 0o120777, target.decode())
        # The extended timestamp field wins over the DOS time (odd seconds).
        exact_time = 1700000001
        info = zip_info('stamped.txt', (2023, 11, 14, 22, 13, 20), 0o100644, compress)
        info.extra = struct.pack('<HHBl', 0x5455, 5, 1, exact_time)
        zip_file.writestr(info, b'stamped')
        note_entry(archive, 'stamped.txt', 'f', b'stamped', exact_time, 0o100644)
    note('count', archive, len(members) + 2)
    note('format', archive, 'zip')
    return path


class Unseekable:
    """A file zipfile cannot seek in, so that it writes data descriptors."""

    def __init__(self, file):
        self.file = file

    def write(self, data):
        return self.file.write(data)

    def flush(self):
        self.file.flush()


def write_descriptor_zip(directory):
    archive = 'zip-descriptor.zip'
    date_time = (2022, 1, 2, 3, 4, 6)
    mtime = calendar.timegm(date_time + (0, 0, 0))
    with open(os.path.join(directory, archive), 'wb') as file:
        with zipfile.ZipFile(Unseekable(file), 'w', zipfile.ZIP_DEFLATED) as zip_file:
            for index in range(3):
                data = mixed_data(30000 + index * 1000, 20 + index)
                name = 'part%d.bin' % index
                info = zip_info(name, date_time, 0o100644, zipfile.ZIP_DEFLATED)
                with zip_file.open(info, 'w') as member:
                    member.write(data)
                note_entry(archive, name, 'f', data, mtime, 0o100644)
    note('count', archive, 3)
    note('format', archive, 'zip')


def write_zip64(directory):
    archive = 'zip-zip64.zip'
    date_time = (2021, 6, 7, 8, 9, 10)
    mtime = calendar.timegm(date_time + (0, 0, 0))
    with zipfile.ZipFile(os.path.join(directory, archive), 'w', zipfile.ZIP_DEFLATED) as zip_file:
        for index in range(4):
            data = mixed_data(5000 * (index + 1), 40 + index)
            name = 'forced%d.bin' % index
            info = zip_info(name, date_time, 0o100644, zipfile.ZIP_DEFLATED)
            with zip_file.open(info, 'w', force_zip64=True) as member:
                member.write(data)
            note_entry(archive, name, 'f', data, mtime, 0o100644)
    note('count', archive, 4)
    note('format', archive, 'zip')

    # More than 65535 members: the end record needs ZIP64.
    archive = 'zip-many.zip'
    count = 65540
    with zipfile.ZipFile(os.path.join(directory, archive), 'w', zipfile.ZIP_STORED) as zip_file:
        for index in range(count):
            name = 'many/%05d.txt' % index
            data = b'%d' % index
            zip_file.writestr(zip_info(name, date_time, 0o100644, zipfile.ZIP_STORED), data)
            if index in (0, 1, 65534, 65535, count - 1):
                note_entry(archive, name, 'f', data, mtime, 0o100644)
    note('count', archive, count)
    note('format', archive, 'zip')


def patch_flag(data, name_bytes, set_bits=0, clear_bits=0):
    """Changes the flags of the local and central headers of name_bytes."""
    data = bytearray(data)
    for signature, flag_offset, name_offset in ((b'PK\x03\x04', 6, 30), (b'PK\x01\x02', 8, 46)):
        position = data.find(signature)
        while position >= 0:
            if data[position + name_offset:position + name_offset + len(name_bytes)] == name_bytes:
                flags = struct.unpack_from('<H', data, position + flag_offset)[0]
                flags = (flags | set_bits) & ~clear_bits
                struct.pack_into('<H', data, position + flag_offset, flags)
            position = data.find(signature, position + 4)
    return bytes(data)


def write_patched_zips(directory):
    date_time = (2020, 2, 29, 12, 0, 0)
    mtime = calendar.timegm(date_time + (0, 0, 0))

    # CP437: "é" is written as UTF-8 (2 bytes), then replaced by the
    # CP437 bytes 82 81 ("éü") and the UTF-8 flag cleared.
    archive = 'zip-cp437.zip'
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, 'w') as zip_file:
        zip_file.writestr(zip_info('xé.txt', date_time, 0o100644, zipfile.ZIP_STORED), b'cp437')
    data = buffer.getvalue().replace('xé.txt'.encode('utf-8'), b'x\x82\x81.txt')
    data = patch_flag(data, b'x\x82\x81.txt', clear_bits=0x800)
    with open(os.path.join(directory, archive), 'wb') as file:
        file.write(data)
    note_entry(archive, 'xéü.txt', 'f', b'cp437', mtime, 0o100644)
    note('count', archive, 1)

    # The encrypted flag on a member (the data itself is plain).
    archive = 'zip-encrypted.zip'
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, 'w') as zip_file:
        zip_file.writestr(zip_info('secret.txt', date_time, 0o100644, zipfile.ZIP_STORED), b'secret')
        zip_file.writestr(zip_info('plain.txt', date_time, 0o100644, zipfile.ZIP_STORED), b'plain')
    with open(os.path.join(directory, archive), 'wb') as file:
        file.write(patch_flag(buffer.getvalue(), b'secret.txt', set_bits=1))
    note('encrypted', archive, 'secret.txt')
    note_entry(archive, 'plain.txt', 'f', b'plain', mtime, 0o100644)
    note('count', archive, 2)

    # A wrong CRC-32 in the central directory.
    archive = 'zip-badcrc.zip'
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, 'w', zipfile.ZIP_DEFLATED) as zip_file:
        zip_file.writestr(zip_info('damaged.txt', date_time, 0o100644, zipfile.ZIP_DEFLATED), b'damaged ' * 100)
    data = bytearray(buffer.getvalue())
    central = data.find(b'PK\x01\x02')
    data[central + 16] ^= 0xFF
    with open(os.path.join(directory, archive), 'wb') as file:
        file.write(data)
    note('badcrc', archive, 'damaged.txt')

    # Names that must not be extracted.
    archive = 'zip-unsafe.zip'
    with zipfile.ZipFile(os.path.join(directory, archive), 'w') as zip_file:
        for name in ('../evil.txt', '/absolute.txt', 'a/../../up.txt', 'ok.txt'):
            info = zip_info('x', date_time, 0o100644, zipfile.ZIP_STORED)
            info.filename = name
            info.orig_filename = name
            zip_file.writestr(info, b'unsafe ' + name.encode())
    note('unsafe', archive, 3)
    note('count', archive, 4)


def tar_member(tar, name, data=b'', kind=tarfile.REGTYPE, mode=0o644, mtime=1650000000, target=''):
    info = tarfile.TarInfo(name)
    info.type = kind
    info.mode = mode
    info.mtime = mtime
    info.linkname = target
    if kind == tarfile.REGTYPE:
        info.size = len(data)
        tar.addfile(info, io.BytesIO(data))
    else:
        tar.addfile(info)


def write_tar_members(tar, archive, long_names):
    mtime = 1650000000
    big = mixed_data(150000, 3)
    tar_member(tar, 'top/', kind=tarfile.DIRTYPE, mode=0o755)
    note_entry(archive, 'top/', 'd', b'', mtime, 0o40755)
    tar_member(tar, 'top/hello.txt', b'hello tar\n', mode=0o644)
    note_entry(archive, 'top/hello.txt', 'f', b'hello tar\n', mtime, 0o100644)
    tar_member(tar, 'top/empty', b'', mode=0o600)
    note_entry(archive, 'top/empty', 'f', b'', mtime, 0o100600)
    tar_member(tar, 'top/big.bin', big, mode=0o755)
    note_entry(archive, 'top/big.bin', 'f', big, mtime, 0o100755)
    tar_member(tar, 'top/link', kind=tarfile.SYMTYPE, mode=0o777, target='hello.txt')
    note_entry(archive, 'top/link', 'l', b'hello.txt', mtime, 0o120777, 'hello.txt')
    tar_member(tar, 'top/hard', kind=tarfile.LNKTYPE, mode=0o644, target='top/hello.txt')
    note_entry(archive, 'top/hard', 'f', b'hello tar\n', mtime, 0o100644)
    count = 6
    if long_names:
        long_name = 'top/' + 'a-very-long-folder-name/' * 6 + 'and-a-long-file-name.txt'
        tar_member(tar, long_name, b'long name\n')
        note_entry(archive, long_name, 'f', b'long name\n', mtime, 0o100644)
        long_target = '../' * 40 + 'target'
        tar_member(tar, 'top/longlink', kind=tarfile.SYMTYPE, mode=0o777, target=long_target)
        note_entry(archive, 'top/longlink', 'l', long_target.encode(), mtime, 0o120777, long_target)
        count += 2
    return count


def write_tars(directory):
    archive = 'tar-ustar.tar'
    with tarfile.open(os.path.join(directory, archive), 'w', format=tarfile.USTAR_FORMAT) as tar:
        count = write_tar_members(tar, archive, False)
    note('count', archive, count)
    note('format', archive, 'tar')

    archive = 'tar-gnu.tar'
    with tarfile.open(os.path.join(directory, archive), 'w', format=tarfile.GNU_FORMAT) as tar:
        count = write_tar_members(tar, archive, True)
    note('count', archive, count)
    note('format', archive, 'tar')

    for archive in ('tar-pax.tar', 'tar-pax.tar.gz', 'tar-pax.tar.zst', 'tar-pax.tar.xz'):
        buffer = io.BytesIO()
        with tarfile.open(fileobj=buffer, mode='w', format=tarfile.PAX_FORMAT, encoding='utf-8') as tar:
            count = write_tar_members(tar, archive, True)
            unicode_name = 'top/über 日本.txt'
            tar_member(tar, unicode_name, b'pax unicode\n')
            note_entry(archive, unicode_name, 'f', b'pax unicode\n', 1650000000, 0o100644)
            # A fractional time goes into a pax header.
            tar_member(tar, 'top/fraction.txt', b'fraction\n', mtime=1700000000.5)
            note_entry(archive, 'top/fraction.txt', 'f', b'fraction\n', 1700000000, 0o100644)
            count += 2
        data = buffer.getvalue()
        if archive.endswith('.gz'):
            data = gzip.compress(data, mtime=0)
            note('format', archive, 'targz')
        elif archive.endswith('.zst'):
            # Two frames, which must read as one stream.
            half = len(data) // 2
            data = zstd.compress(data[:half], level=9) + zstd.compress(data[half:], level=3)
            note('format', archive, 'tarzst')
        elif archive.endswith('.xz'):
            data = lzma.compress(data, format=lzma.FORMAT_XZ, check=lzma.CHECK_CRC64)
            note('format', archive, 'tarxz')
        else:
            note('format', archive, 'tar')
        with open(os.path.join(directory, archive), 'wb') as file:
            file.write(data)
        note('count', archive, count)


def v7_header(name, size, mode, mtime, kind=b'\0'):
    header = bytearray(512)
    header[0:len(name)] = name
    header[100:108] = b'%07o\0' % mode
    header[108:116] = b'%07o\0' % 0
    header[116:124] = b'%07o\0' % 0
    header[124:136] = b'%011o\0' % size
    header[136:148] = b'%011o\0' % mtime
    header[148:156] = b' ' * 8
    header[156:157] = kind
    checksum = sum(header)
    header[148:156] = b'%06o\0 ' % checksum
    return bytes(header)


def write_v7_tar(directory):
    archive = 'tar-v7.tar'
    mtime = 1600000000
    data = b'old style tar\n'
    blocks = [v7_header(b'old/', 0, 0o755, mtime), v7_header(b'old/file.txt', len(data), 0o644, mtime)]
    blocks.append(data + b'\0' * (512 - len(data)))
    blocks.append(b'\0' * 1024)
    with open(os.path.join(directory, archive), 'wb') as file:
        file.write(b''.join(blocks))
    note_entry(archive, 'old/', 'd', b'', mtime, 0o40755)
    note_entry(archive, 'old/file.txt', 'f', data, mtime, 0o100644)
    note('count', archive, 2)
    note('format', archive, 'tar')


def write_non_archives(directory):
    with open(os.path.join(directory, 'not-archive.bin'), 'wb') as file:
        file.write(random.Random(5).randbytes(3000))
    note('format', 'not-archive.bin', 'unknown')
    with open(os.path.join(directory, 'plain.txt.gz'), 'wb') as file:
        file.write(gzip.compress(b'just some text, not a tar\n' * 50, mtime=0))
    note('format', 'plain.txt.gz', 'unknown')


def main():
    directory = sys.argv[1]
    os.makedirs(directory, exist_ok=True)
    write_zip_members(directory, 'zip-stored.zip', zipfile.ZIP_STORED)
    write_zip_members(directory, 'zip-deflated.zip', zipfile.ZIP_DEFLATED)
    write_descriptor_zip(directory)
    write_zip64(directory)
    write_patched_zips(directory)
    write_tars(directory)
    write_v7_tar(directory)
    write_non_archives(directory)
    with open(os.path.join(directory, 'manifest.txt'), 'w', encoding='utf-8') as file:
        file.write('\n'.join(MANIFEST) + '\n')


if __name__ == '__main__':
    main()
