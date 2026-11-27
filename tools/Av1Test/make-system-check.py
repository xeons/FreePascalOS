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

"""Writes the streams av1check (userland/tests/av1check/av1check.pas) decodes on the system.

    make-system-check.py OUTPUT_INCLUDE

A few small AV1 streams (8-bit inter frames with every loop filter,
10-bit with film grain, 4:4:4 screen content with palettes and intra
block copy, superres with tiles) are encoded with aomenc and decoded with
aomdec, the reference decoder; the include holds the IVF files' bytes and
the 64-bit FNV-1a hash of each frame aomdec shows (its planes as aomdec
writes them raw). The include is checked in (about 30 KB of streams), so
building the system needs no AV1 tools; run this again only to change the
streams.
"""

import hashlib
import os
import subprocess
import sys
import tempfile

STREAMS = [
    # name, size, frames, pixel format, lavfi source, aomenc arguments
    ('inter', '96x64', 6, 'yuv420p', 'testsrc2=size={size}:rate=30', ['--cpu-used=4']),
    ('grain10', '64x48', 3, 'yuv420p10le', 'testsrc2=size={size}:rate=30',
     ['--cpu-used=6', '--bit-depth=10', '--input-bit-depth=10', '--film-grain-test=2']),
    ('screen444', '64x48', 2, 'yuv444p', 'testsrc=size=32x24:rate=30,scale=64x48:flags=neighbor',
     ['--cpu-used=2', '--profile=1', '--i444', '--kf-max-dist=0', '--tune-content=screen']),
    ('superres', '160x96', 3, 'yuv420p', 'mandelbrot=size={size}:rate=30',
     ['--cpu-used=6', '--superres-mode=1', '--superres-denominator=11', '--tile-columns=1']),
]


def fnv1a64(data):
    value = 0xcbf29ce484222325
    for byte in data:
        value ^= byte
        value = (value * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF
    return value


def frame_sizes(width, height, pixel_format):
    sample = 2 if '10' in pixel_format or '12' in pixel_format else 1
    luma = width * height * sample
    if pixel_format.startswith('yuv444'):
        chroma = luma
    else:
        chroma = ((width + 1) // 2) * ((height + 1) // 2) * sample
    return luma + 2 * chroma


def make_stream(directory, name, size, frames, pixel_format, source, arguments):
    width, height = (int(v) for v in size.split('x'))
    raw = os.path.join(directory, name + '.y4m')
    stream = os.path.join(directory, name + '.ivf')
    decoded = os.path.join(directory, name + '.yuv')
    subprocess.run(['ffmpeg', '-nostdin', '-loglevel', 'error', '-y', '-f', 'lavfi', '-i', source.format(size=size),
                    '-frames:v', str(frames), '-pix_fmt', pixel_format, '-strict', '-1', raw], check=True)
    subprocess.run(['aomenc', '--threads=1', '--limit=%d' % frames] + arguments + ['--ivf', '-o', stream, raw],
                   check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    subprocess.run(['aomdec', '--rawvideo', '-o', decoded, stream], check=True)
    data = open(decoded, 'rb').read()
    per_frame = frame_sizes(width, height, pixel_format)
    if len(data) % per_frame:
        raise SystemExit('%s: decoded size %d is not a whole number of frames' % (name, len(data)))
    hashes = [fnv1a64(data[i:i + per_frame]) for i in range(0, len(data), per_frame)]
    return open(stream, 'rb').read(), hashes


def pascal_bytes(data):
    lines = []
    for offset in range(0, len(data), 24):
        lines.append(', '.join('$%02x' % b for b in data[offset:offset + 24]))
    return '(\n    ' + ',\n    '.join(lines) + ')'


def main():
    if len(sys.argv) != 2:
        raise SystemExit(__doc__)
    output = []
    output.append('{ Written by tools/Av1Test/make-system-check.py with aomenc and aomdec; do not edit. }\n')
    names = []
    with tempfile.TemporaryDirectory() as directory:
        for name, size, frames, pixel_format, source, arguments in STREAMS:
            data, hashes = make_stream(directory, name, size, frames, pixel_format, source, arguments)
            identifier = name.capitalize()
            names.append((identifier, name, len(hashes)))
            output.append('const\n  Stream%s: array[0..%d] of Byte = %s;\n' % (identifier, len(data) - 1,
                                                                             pascal_bytes(data)))
            output.append('  Hashes%s: array[0..%d] of QWord = (\n    %s);\n\n' % (
                identifier, len(hashes) - 1, ',\n    '.join('QWord($%016x)' % h for h in hashes)))
        # The first stream in a WebM file too, for libmedia and mediaplay.
        webm = os.path.join(directory, 'sample.webm')
        subprocess.run(['ffmpeg', '-nostdin', '-loglevel', 'error', '-y', '-i', os.path.join(directory, 'inter.ivf'),
                        '-c:v', 'copy', webm], check=True)
        webm_data = open(webm, 'rb').read()
        raw = open(os.path.join(directory, 'inter.yuv'), 'rb').read()
        per_frame = frame_sizes(96, 64, 'yuv420p')
        md5s = [hashlib.md5(raw[i:i + per_frame]).hexdigest() for i in range(0, len(raw), per_frame)]
        output.append('const\n  SampleWebm: array[0..%d] of Byte = %s;\n' % (len(webm_data) - 1, pascal_bytes(webm_data)))
        output.append('  { MD5 of each frame of SampleWebm (for mediaplay -k): %s }\n\n' % ' '.join(md5s))
    output.append('const\n  StreamCount = %d;\n' % len(names))
    output.append('  Streams: array[0..StreamCount - 1] of TCheckStream = (\n    %s);\n' % ',\n    '.join(
        "(Name: '%s'; Data: @Stream%s; Size: SizeOf(Stream%s); Hashes: @Hashes%s; FrameCount: %d)" %
        (name, identifier, identifier, identifier, count) for identifier, name, count in names))
    with open(sys.argv[1], 'w') as include:
        include.write(''.join(output))


if __name__ == '__main__':
    main()
