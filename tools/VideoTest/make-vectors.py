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

"""Makes the VP8 and VP9 test streams of the video test.

usage: make-vectors.py OUTPUT_DIRECTORY

Sources come from ffmpeg's test patterns; the host's vpxenc encodes
them with settings that between them use every part of the formats
(the VP8 versions, token partitions, alternate references, error
resilience, segmentation; VP9 tiles, superframes, lossless frames,
segmentation, frame parallel mode, every profile, bit depth and
subsampling, and scaled references through scaling-encoder.c when a C
compiler and libvpx's headers are there). vpxdec's per frame MD5s are
the expected results. The manifest lists 'stream md5file' per line.
"""
import os
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))


def run(arguments, **options):
    subprocess.run(arguments, check=True, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                   stderr=subprocess.DEVNULL, **options)


def make_source(directory, name, pattern, width, height, frames, pixel_format):
    path = os.path.join(directory, name + '.yuv')
    if not os.path.exists(path):
        run(['ffmpeg', '-v', 'error', '-y', '-f', 'lavfi', '-i',
             '%s=size=%dx%d:rate=30' % (pattern, width, height), '-frames:v', str(frames),
             '-pix_fmt', pixel_format, '-f', 'rawvideo', path])
    return path


def reference_md5(directory, stream):
    """vpxdec's MD5 of every frame, as 'md5  name' lines."""
    result = subprocess.run(['vpxdec', '--md5', '--rawvideo', '-o',
                             os.path.join(directory, 'frame-%wx%h-%4.yuv'), stream],
                            check=True, capture_output=True, text=True)
    return result.stdout


def main():
    directory = sys.argv[1]
    for tool in ('ffmpeg', 'vpxenc', 'vpxdec'):
        if shutil.which(tool) is None:
            raise SystemExit('%s is needed for the video test streams (ffmpeg, libvpx)' % tool)
    os.makedirs(directory, exist_ok=True)
    sources = os.path.join(directory, 'sources')
    os.makedirs(sources, exist_ok=True)

    s176 = make_source(sources, 'testsrc176', 'testsrc2', 176, 144, 30, 'yuv420p')
    m176 = make_source(sources, 'mandelbrot176', 'mandelbrot', 176, 144, 24, 'yuv420p')
    odd = make_source(sources, 'odd99', 'testsrc2', 99, 67, 20, 'yuv420p')
    wide = make_source(sources, 'wide640', 'testsrc2', 640, 360, 8, 'yuv420p')
    s444 = make_source(sources, 'testsrc444', 'testsrc2', 176, 144, 10, 'yuv444p')
    s422 = make_source(sources, 'testsrc422', 'testsrc2', 176, 144, 10, 'yuv422p')
    s440 = make_source(sources, 'testsrc440', 'testsrc2', 176, 144, 10, 'yuv440p')
    s10 = make_source(sources, 'testsrc420p10', 'testsrc2', 176, 144, 10, 'yuv420p10le')
    s12 = make_source(sources, 'testsrc420p12', 'mandelbrot', 176, 144, 10, 'yuv420p12le')
    s444p10 = make_source(sources, 'testsrc444p10', 'testsrc2', 176, 144, 8, 'yuv444p10le')
    s422p12 = make_source(sources, 'testsrc422p12', 'mandelbrot', 176, 144, 8, 'yuv422p12le')

    good = ['--good', '--cpu-used=4', '--passes=1']
    streams = [
        # VP8
        ('vp8-default', 'vp8', s176, 176, 144, good + ['--kf-max-dist=12']),
        ('vp8-profile1', 'vp8', m176, 176, 144, good + ['--profile=1']),
        ('vp8-profile2', 'vp8', odd, 99, 67, good + ['--profile=2']),
        ('vp8-profile3', 'vp8', s176, 176, 144, good + ['--profile=3']),
        ('vp8-partitions', 'vp8', wide, 640, 360, good + ['--token-parts=3']),
        ('vp8-altref', 'vp8', s176, 176, 144, good + ['--auto-alt-ref=1', '--lag-in-frames=12']),
        ('vp8-error-resilient', 'vp8', m176, 176, 144, good + ['--error-resilient=1', '--token-parts=2']),
        ('vp8-high-quality', 'vp8', m176, 176, 144, good + ['--end-usage=q', '--cq-level=0', '--min-q=0',
                                                          '--max-q=8']),
        ('vp8-realtime', 'vp8', s176, 176, 144, ['--rt', '--cpu-used=8', '--lag-in-frames=0', '--end-usage=cbr',
                                                  '--target-bitrate=60', '--static-thresh=200',
                                                  '--noise-sensitivity=2']),
        ('vp8-sharpness', 'vp8', odd, 99, 67, good + ['--sharpness=5', '--kf-max-dist=7']),
        # VP9
        ('vp9-default', 'vp9', s176, 176, 144, good + ['--kf-max-dist=10']),
        ('vp9-superframes', 'vp9', odd, 99, 67, good + ['--auto-alt-ref=1', '--lag-in-frames=16']),
        ('vp9-tiles', 'vp9', wide, 640, 360, good + ['--tile-columns=1', '--tile-rows=1']),
        ('vp9-lossless', 'vp9', m176, 176, 144, good + ['--lossless=1']),
        ('vp9-aq-variance', 'vp9', s176, 176, 144, good + ['--aq-mode=1']),
        ('vp9-aq-cyclic', 'vp9', m176, 176, 144, ['--rt', '--cpu-used=7', '--lag-in-frames=0', '--end-usage=cbr',
                                                  '--target-bitrate=80', '--aq-mode=3']),
        ('vp9-frame-parallel', 'vp9', s176, 176, 144, good + ['--frame-parallel=1']),
        ('vp9-error-resilient', 'vp9', m176, 176, 144, good + ['--error-resilient=1']),
        ('vp9-no-loop-filter', 'vp9', s176, 176, 144, good + ['--disable-loopfilter=2']),
        ('vp9-slow-sharp', 'vp9', odd, 99, 67, ['--good', '--cpu-used=0', '--sharpness=7',
                                                '--auto-alt-ref=1', '--lag-in-frames=8']),
        ('vp9-profile1-444', 'vp9', s444, 176, 144, good + ['--profile=1', '--i444']),
        ('vp9-profile1-422', 'vp9', s422, 176, 144, good + ['--profile=1', '--i422']),
        ('vp9-profile1-440', 'vp9', s440, 176, 144, good + ['--profile=1', '--i440']),
        ('vp9-profile2-10bit', 'vp9', s10, 176, 144, good + ['--profile=2', '--bit-depth=10',
                                                             '--input-bit-depth=10']),
        ('vp9-profile2-12bit', 'vp9', s12, 176, 144, good + ['--profile=2', '--bit-depth=12',
                                                             '--input-bit-depth=12']),
        ('vp9-profile3-10bit-444', 'vp9', s444p10, 176, 144, good + ['--profile=3', '--bit-depth=10',
                                                                     '--input-bit-depth=10', '--i444']),
        ('vp9-profile3-12bit-422', 'vp9', s422p12, 176, 144, good + ['--profile=3', '--bit-depth=12',
                                                                     '--input-bit-depth=12', '--i422']),
    ]
    manifest = []
    for name, codec, source, width, height, options in streams:
        stream = os.path.join(directory, name + '.ivf')
        run(['vpxenc', '--codec=' + codec, '-w', str(width), '-h', str(height), '--ivf', '-o', stream]
            + options + [source])
        open(os.path.join(directory, name + '.md5'), 'w').write(reference_md5(directory, stream))
        manifest.append('%s %s' % (name + '.ivf', name + '.md5'))

    # Scaled references: needs a C compiler and libvpx's headers.
    compiler = shutil.which('cc') or shutil.which('gcc')
    encoder = os.path.join(directory, 'scaling-encoder')
    if compiler is not None:
        try:
            run([compiler, '-O1', '-o', encoder, os.path.join(HERE, 'scaling-encoder.c'), '-lvpx'])
            scaled_source = make_source(sources, 'mandelbrot320', 'mandelbrot', 320, 240, 40, 'yuv420p')
            stream = os.path.join(directory, 'vp9-scaled-references.ivf')
            run([encoder, scaled_source, '320', '240', '40', stream])
            open(os.path.join(directory, 'vp9-scaled-references.md5'), 'w').write(reference_md5(directory, stream))
            manifest.append('vp9-scaled-references.ivf vp9-scaled-references.md5')
        except subprocess.CalledProcessError:
            print('scaled reference stream left out (no libvpx headers?)')
    open(os.path.join(directory, 'manifest.txt'), 'w').write('\n'.join(manifest) + '\n')

    # The same streams in WebM and MP4 files, for libmedia's demuxers.
    containers = []
    for name, extension in (('vp9-default', 'webm'), ('vp9-superframes', 'webm'), ('vp9-profile2-10bit', 'webm'),
                            ('vp8-altref', 'webm'), ('vp9-tiles', 'mp4'), ('vp9-profile1-444', 'mp4')):
        target = os.path.join(directory, '%s.%s' % (name, extension))
        run(['ffmpeg', '-v', 'error', '-y', '-i', os.path.join(directory, name + '.ivf'), '-c:v', 'copy', target])
        containers.append('%s.%s %s.md5' % (name, extension, name))
    open(os.path.join(directory, 'containers.txt'), 'w').write('\n'.join(containers) + '\n')


main()
