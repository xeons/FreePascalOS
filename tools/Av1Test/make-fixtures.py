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

"""Makes the AV1 test streams and their reference frames.

    make-fixtures.py OUTPUT_DIRECTORY

Short synthetic clips (ffmpeg's lavfi sources) are encoded with the
host's AV1 encoders - libaom's aomenc with each coding tool and format
switched on or off, SVT-AV1's SvtAv1EncApp and rav1e through ffmpeg when
they are there - into IVF files, and decoded with libaom's aomdec, the
reference decoder, into raw frames. OUTPUT_DIRECTORY/manifest.txt lists
"name stream.ivf frames.yuv count" for tools/Av1Test. ffmpeg, aomenc
and aomdec are needed; streams of encoders that are missing are left out.
"""

import os
import shutil
import subprocess
import sys

# name: (width, height, frames, pixel format, lavfi source)
SOURCES = {
    'pattern': (176, 144, 10, 'yuv420p', 'testsrc2=size={w}x{h}:rate=30'),
    'pattern10': (176, 144, 8, 'yuv420p10le', 'testsrc2=size={w}x{h}:rate=30'),
    'pattern12': (128, 96, 4, 'yuv420p12le', 'testsrc2=size={w}x{h}:rate=30'),
    'pattern444': (128, 96, 6, 'yuv444p', 'testsrc2=size={w}x{h}:rate=30'),
    'pattern444-10': (128, 96, 4, 'yuv444p10le', 'testsrc2=size={w}x{h}:rate=30'),
    'pattern422': (128, 96, 4, 'yuv422p10le', 'testsrc2=size={w}x{h}:rate=30'),
    'odd': (202, 118, 8, 'yuv420p', 'mandelbrot=size={w}x{h}:rate=30'),
    'rotate': (192, 128, 8, 'yuv420p',
               'testsrc2=size=384x256:rate=30,rotate=a=0.04*t*30:ow=384:oh=256,scale={w}:{h}'),
    'zoom': (160, 120, 8, 'yuv420p', 'mandelbrot=size={w}x{h}:rate=30:start_scale=0.3:end_scale=0.02'),
    'screen': (128, 96, 4, 'yuv420p', 'testsrc=size={w}x{h}:rate=30'),
    'repeated': (256, 192, 2, 'yuv420p', 'testsrc=size=64x48:rate=30,scale=128x96:flags=neighbor,tile=2x2'),
    'zoom-long': (160, 120, 12, 'yuv420p', 'mandelbrot=size={w}x{h}:rate=30:start_scale=0.3:end_scale=0.02'),
    'large': (352, 288, 3, 'yuv420p', 'testsrc2=size={w}x{h}:rate=30'),
    'wide': (512, 160, 3, 'yuv420p', 'mandelbrot=size={w}x{h}:rate=30'),
}

AOM_COMMON = ['--cpu-used=6', '--threads=1']

# Streams also put into WebM and MP4 files (by ffmpeg, without
# re-encoding), and encoded as OBU files, for libmedia's demuxers.
CONTAINERS = {
    'inter-good': ['webm', 'mp4'],
    'high-bitdepth-10': ['webm', 'mp4'],
    'svt-av1': ['webm', 'mp4'],
    'film-grain': ['mkv'],
}
OBU_STREAMS = ['inter-good']

# name: (source, encoder, arguments)
CASES = [
    ('intra-nofilter', 'pattern', 'aom',
     ['--limit=2', '--kf-max-dist=0', '--enable-cdef=0', '--enable-restoration=0', '--loopfilter-control=0']),
    ('intra-filters', 'pattern', 'aom', ['--limit=3', '--kf-max-dist=0']),
    ('allintra', 'odd', 'aom', ['--limit=2', '--usage=2']),
    ('inter-good', 'pattern', 'aom', ['--limit=10']),
    ('inter-odd-size', 'odd', 'aom', ['--limit=8', '--cpu-used=3']),
    ('inter-slow-tools', 'zoom', 'aom', ['--limit=8', '--cpu-used=1']),
    ('global-warped', 'rotate', 'aom',
     ['--limit=8', '--cpu-used=2', '--enable-global-motion=1', '--enable-warped-motion=1']),
    ('realtime', 'pattern', 'aom', ['--limit=8', '--usage=1', '--cpu-used=8']),
    ('high-bitdepth-10', 'pattern10', 'aom', ['--limit=8', '--bit-depth=10', '--input-bit-depth=10']),
    ('intra-10', 'pattern10', 'aom', ['--limit=2', '--bit-depth=10', '--input-bit-depth=10', '--kf-max-dist=0']),
    ('profile2-12bit', 'pattern12', 'aom', ['--limit=4', '--profile=2', '--bit-depth=12', '--input-bit-depth=12']),
    ('profile1-444', 'pattern444', 'aom', ['--limit=6', '--profile=1', '--i444']),
    ('profile1-444-10', 'pattern444-10', 'aom',
     ['--limit=4', '--profile=1', '--i444', '--bit-depth=10', '--input-bit-depth=10']),
    ('profile2-422-10', 'pattern422', 'aom',
     ['--limit=4', '--profile=2', '--i422', '--bit-depth=10', '--input-bit-depth=10']),
    ('monochrome', 'pattern', 'aom', ['--limit=4', '--monochrome']),
    ('screen-content', 'screen', 'aom',
     ['--limit=4', '--tune-content=screen', '--enable-palette=1', '--enable-intrabc=1']),
    ('screen-intrabc', 'repeated', 'aom', ['--limit=2', '--kf-max-dist=0', '--tune-content=screen', '--cpu-used=1']),
    ('svt-screen-intrabc', 'repeated', 'svt', ['--scm', '1', '--preset', '2']),
    ('slowest-tools', 'zoom-long', 'aom', ['--limit=12', '--cpu-used=0']),
    ('forward-key-frames', 'zoom-long', 'aom', ['--limit=12', '--enable-fwd-kf=1', '--fwd-kf-dist=4', '--kf-max-dist=6']),
    ('film-grain', 'pattern', 'aom', ['--limit=4', '--film-grain-test=1']),
    ('film-grain-10', 'pattern10', 'aom',
     ['--limit=3', '--bit-depth=10', '--input-bit-depth=10', '--film-grain-test=10']),
    ('film-grain-444', 'pattern444', 'aom', ['--limit=2', '--profile=1', '--i444', '--film-grain-test=6']),
    ('superres', 'pattern', 'aom',
     ['--limit=5', '--superres-mode=1', '--superres-denominator=12', '--superres-kf-denominator=10']),
    ('superres-random', 'odd', 'aom', ['--limit=5', '--superres-mode=2']),
    ('tiles', 'large', 'aom', ['--limit=3', '--tile-columns=1', '--tile-rows=1']),
    ('uniform-tiles', 'wide', 'aom', ['--limit=3', '--tile-columns=2']),
    ('superblock-128', 'large', 'aom', ['--limit=3', '--sb-size=128']),
    ('lossless', 'pattern', 'aom', ['--limit=3', '--lossless=1']),
    ('quantizer-matrices', 'pattern', 'aom', ['--limit=3', '--enable-qm=1', '--qm-min=0', '--qm-max=8']),
    ('delta-q-lf', 'odd', 'aom', ['--limit=6', '--deltaq-mode=1', '--delta-lf-mode=1', '--aq-mode=1']),
    ('segmentation', 'pattern', 'aom', ['--limit=6', '--aq-mode=2']),
    ('error-resilient', 'pattern', 'aom', ['--limit=7', '--error-resilient=1', '--sframe-dist=3']),
    ('reduced-tx-set', 'pattern', 'aom', ['--limit=4', '--reduced-tx-type-set=1']),
    ('no-dual-filter', 'pattern', 'aom', ['--limit=5', '--enable-dual-filter=0', '--enable-order-hint=0']),
    ('frame-size-change', 'pattern', 'aom', ['--limit=6', '--resize-mode=3']),
    ('svt-av1', 'pattern', 'svt', ['--preset', '8']),
    ('svt-av1-10', 'pattern10', 'svt', ['--preset', '8', '--input-depth', '10']),
    ('svt-av1-film-grain', 'odd', 'svt', ['--preset', '10', '--film-grain', '8']),
    ('rav1e', 'pattern', 'rav1e', []),
]


def run(command, **options):
    subprocess.run(command, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, **options)


def make_source(directory, name):
    width, height, frames, pixel_format, source = SOURCES[name]
    path = os.path.join(directory, 'source-%s.y4m' % name)
    if not os.path.exists(path):
        run(['ffmpeg', '-nostdin', '-y', '-f', 'lavfi', '-i', source.format(w=width, h=height),
             '-frames:v', str(frames), '-pix_fmt', pixel_format, '-strict', '-1', path])
    return path, frames


def encode(directory, name, source_name, encoder, arguments):
    source, frames = make_source(directory, source_name)
    stream = os.path.join(directory, name + '.ivf')
    if encoder == 'aom':
        run(['aomenc'] + AOM_COMMON + arguments + ['--ivf', '-o', stream, source])
    elif encoder == 'svt':
        if not shutil.which('SvtAv1EncApp'):
            return None
        run(['SvtAv1EncApp', '-i', source, '-b', stream, '-n', str(frames)] + arguments)
    elif encoder == 'rav1e':
        run(['ffmpeg', '-nostdin', '-y', '-i', source, '-c:v', 'librav1e', '-speed', '10', '-f', 'ivf', stream])
    return stream


def main():
    if len(sys.argv) != 2:
        raise SystemExit(__doc__)
    directory = sys.argv[1]
    os.makedirs(directory, exist_ok=True)
    for tool in ('ffmpeg', 'aomenc', 'aomdec'):
        if not shutil.which(tool):
            raise SystemExit('%s is needed for the AV1 test streams' % tool)
    lines = []
    for name, source_name, encoder, arguments in CASES:
        try:
            stream = encode(directory, name, source_name, encoder, arguments)
        except subprocess.CalledProcessError:
            print('skipped %s: the encoder failed' % name)
            continue
        if stream is None:
            print('skipped %s: no encoder' % name)
            continue
        reference = os.path.join(directory, name + '.yuv')
        run(['aomdec', '--rawvideo', '-o', reference, stream])
        # aomdec writes one file of all the frames; count them by decoding to per-frame files.
        pattern = os.path.join(directory, name + '-%4.count')
        run(['aomdec', '--rawvideo', '-o', pattern, stream])
        count = len([f for f in os.listdir(directory) if f.startswith(name + '-') and f.endswith('.count')])
        for f in os.listdir(directory):
            if f.startswith(name + '-') and f.endswith('.count'):
                os.remove(os.path.join(directory, f))
        lines.append('%s %s %s %d' % (name, os.path.basename(stream), os.path.basename(reference), count))
        # The same stream in containers, read through libmedia.
        for container in CONTAINERS.get(name, []):
            boxed = os.path.join(directory, '%s.%s' % (name, container))
            run(['ffmpeg', '-nostdin', '-y', '-i', stream, '-c:v', 'copy', boxed])
            lines.append('%s-%s %s %s %d' % (name, container, os.path.basename(boxed),
                                             os.path.basename(reference), count))
        if name in OBU_STREAMS:
            obu = os.path.join(directory, name + '.obu')
            run(['aomenc'] + AOM_COMMON + arguments + ['--obu', '-o', obu, make_source(directory, source_name)[0]])
            run(['aomdec', '--rawvideo', '-o', reference + '.obu.yuv', obu])
            lines.append('%s-obu %s %s %d' % (name, os.path.basename(obu), os.path.basename(reference) + '.obu.yuv',
                                              count))
    with open(os.path.join(directory, 'manifest.txt'), 'w') as manifest:
        manifest.write('\n'.join(lines) + '\n')
    for f in os.listdir(directory):
        if f.startswith('source-'):
            os.remove(os.path.join(directory, f))


if __name__ == '__main__':
    main()
