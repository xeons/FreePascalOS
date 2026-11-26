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

"""What the media fixture scripts share.

Each make-<section>-fixtures.py writes into FIXTURES/<section>/ the files
it makes and a manifest.txt that says, a line each, what the test should
check. A script whose tool is missing on the host writes a manifest with
only a "# skipped: ..." comment, so the test checks nothing there.

The test signals are synthetic (tones, chirps, noise), made here with
Python's own math and random modules: the same every build.
"""

import math
import os
import random
import shutil
import struct
import subprocess
import sys


def section_directory(section):
    """FIXTURES/<section>, made empty."""
    root = sys.argv[1]
    directory = os.path.join(root, section)
    if os.path.isdir(directory):
        shutil.rmtree(directory)
    os.makedirs(directory)
    return directory


def have_tool(name):
    return shutil.which(name) is not None


def ffmpeg_has(kind, name):
    """Whether the host's ffmpeg has an encoder, decoder or muxer called name
    (kind: "encoders", "decoders" or "muxers")."""
    if not have_tool("ffmpeg"):
        return False
    listing = subprocess.run(["ffmpeg", "-hide_banner", "-" + kind], capture_output=True, text=True).stdout
    for line in listing.splitlines():
        fields = line.split()
        if len(fields) >= 2 and fields[1] == name:
            return True
    return False


def run(arguments):
    subprocess.run(arguments, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def ffmpeg(arguments):
    run(["ffmpeg", "-nostdin", "-hide_banner", "-loglevel", "error", "-y"] + arguments)


def write_manifest(directory, lines, skipped=None):
    with open(os.path.join(directory, "manifest.txt"), "w") as manifest:
        if skipped is not None:
            manifest.write("# skipped: %s\n" % skipped)
        for line in lines:
            manifest.write(line + "\n")


def test_signal(rate, channels, seconds, seed=1):
    """Interleaved floats: a chirp and a tone per channel with a little
    noise, about -6 dBFS."""
    generator = random.Random(seed)
    frames = int(rate * seconds)
    samples = []
    for index in range(frames):
        time = index / rate
        for channel in range(channels):
            base = 220.0 * (channel + 1)
            chirp = math.sin(2 * math.pi * (base * time + 400.0 * time * time))
            tone = math.sin(2 * math.pi * (base * 1.5) * time + channel)
            noise = generator.uniform(-1, 1)
            samples.append(0.3 * chirp + 0.15 * tone + 0.02 * noise)
    return samples


def write_wav(path, rate, channels, samples, bits=16, float_samples=False, extensible=False):
    """A WAV file of interleaved floats (-1..1) as bits-wide PCM or floats."""
    data = bytearray()
    for value in samples:
        value = max(-1.0, min(1.0, value))
        if float_samples:
            data += struct.pack("<f" if bits == 32 else "<d", value)
        elif bits == 8:
            data += struct.pack("<B", max(0, min(255, int(round(value * 128)) + 128)))
        elif bits == 16:
            data += struct.pack("<h", max(-32768, min(32767, int(round(value * 32768)))))
        elif bits == 24:
            integer = max(-8388608, min(8388607, int(round(value * 8388608))))
            data += struct.pack("<i", integer)[:3]
        else:
            data += struct.pack("<i", max(-2147483648, min(2147483647, int(round(value * 2147483648)))))
    block_align = channels * bits // 8
    tag = 3 if float_samples else 1
    if extensible:
        guid_tail = bytes([0x00, 0x00, 0x00, 0x00, 0x10, 0x00, 0x80, 0x00, 0x00, 0xAA, 0x00, 0x38, 0x9B, 0x71])
        fmt = struct.pack("<HHIIHHHHI", 0xFFFE, channels, rate, rate * block_align, block_align, bits, 22, bits,
                          (1 << channels) - 1) + struct.pack("<H", tag) + guid_tail
    else:
        fmt = struct.pack("<HHIIHH", tag, channels, rate, rate * block_align, block_align, bits)
    body = b"WAVE" + b"fmt " + struct.pack("<I", len(fmt)) + fmt
    body += b"LIST" + struct.pack("<I", 4) + b"INFO"
    body += b"data" + struct.pack("<I", len(data)) + bytes(data)
    if len(data) % 2:
        body += b"\0"
    with open(path, "wb") as output:
        output.write(b"RIFF" + struct.pack("<I", len(body)) + body)


def write_raw_float(path, samples):
    with open(path, "wb") as output:
        output.write(struct.pack("<%df" % len(samples), *samples))
