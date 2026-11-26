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


"""Prepares the libvpx test vectors (vp80-*.ivf, vp90-*.webm, ... with
their .md5 files, from libvpx's test data) for the video test, if they
are there: the WebM files become IVF (a minimal reader: one video track,
no lacing) and a manifest lists them.

usage: prepare-conformance.py SOURCE_DIRECTORY OUTPUT_DIRECTORY
"""
import os
import shutil
import struct
import sys


def vint(data, pos, keep_marker=False):
    first = data[pos]
    length = 1
    mask = 0x80
    while length <= 8 and not (first & mask):
        mask >>= 1
        length += 1
    value = first if keep_marker else first & (mask - 1)
    for i in range(1, length):
        value = (value << 8) | data[pos + i]
    return value, pos + length


CONTAINERS = {0x18538067, 0x1F43B675, 0xA0, 0x1654AE6B, 0xAE}


def walk(data, start, end, frames):
    pos = start
    while pos < end:
        ident, pos = vint(data, pos, keep_marker=True)
        size, pos = vint(data, pos)
        if size == (1 << (7 * 8)) - 1 or size > end - pos:
            size = end - pos
        if ident in CONTAINERS:
            walk(data, pos, pos + size, frames)
        elif ident in (0xA3, 0xA1):  # SimpleBlock, Block
            track, p = vint(data, pos)
            timecode = struct.unpack('>h', data[p:p + 2])[0]
            flags = data[p + 2]
            if flags & 0x06:
                raise SystemExit('lacing not supported')
            frames.append(data[p + 3:pos + size])
        pos += size


def webm_to_ivf(source, target, fourcc):
    data = open(source, 'rb').read()
    frames = []
    walk(data, 0, len(data), frames)
    out = bytearray(b'DKIF' + struct.pack('<HH4sHHIII', 0, 32, fourcc, 0, 0, 30, 1, len(frames)) + b'\0' * 4)
    for index, frame in enumerate(frames):
        out += struct.pack('<IQ', len(frame), index) + frame
    open(target, 'wb').write(out)


def main():
    source, target = sys.argv[1], sys.argv[2]
    os.makedirs(target, exist_ok=True)
    manifest = []
    if os.path.isdir(source):
        for name in sorted(os.listdir(source)):
            md5 = os.path.join(source, name + '.md5')
            if not os.path.exists(md5) or not name.startswith(('vp8', 'vp9')):
                continue
            base = name.rsplit('.', 1)[0]
            stream = base + '.ivf'
            if name.endswith('.ivf'):
                shutil.copyfile(os.path.join(source, name), os.path.join(target, stream))
            elif name.endswith('.webm'):
                webm_to_ivf(os.path.join(source, name), os.path.join(target, stream),
                            b'VP80' if name.startswith('vp8') else b'VP90')
            else:
                continue
            shutil.copyfile(md5, os.path.join(target, base + '.md5'))
            manifest.append('%s %s' % (stream, base + '.md5'))
    if manifest:
        open(os.path.join(target, 'manifest.txt'), 'w').write('\n'.join(manifest) + '\n')
    print('%d libvpx test vectors' % len(manifest))


main()
