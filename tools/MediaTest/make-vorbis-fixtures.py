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

"""Ogg Vorbis fixtures for MediaTest.Vorbis.

make-vorbis-fixtures.py FIXTURES

Encodes the test signal with the host's ffmpeg (libvorbis) at several
qualities, rates and channel counts, and decodes each file again with
libvorbis (through ffmpeg) into 32-bit floats, the reference. ffmpeg's
libvorbis wrapper leaves the channels in Vorbis' order, so for 3 or more
channels the reference is reordered here to the WAVE order the decoder
gives (Vorbis I specification, section 4.3.9). One file has stretches of
digital silence, so its packets have unused floors.

manifest.txt, a line per file:
    NAME.ogg NAME.f32 RATE CHANNELS QUALITY
"""

import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import fixturetools  # noqa: E402

# (rate, channels, quality, seconds, gated)
CASES = [
    (44100, 2, -1, 1.5, False),
    (44100, 1, 3, 1.5, False),
    (44100, 2, 0, 1.0, True),
    (48000, 2, 6, 1.5, False),
    (96000, 2, 10, 1.0, False),
    (8000, 1, 2, 2.0, False),
    (22050, 2, 4, 1.5, False),
    (48000, 6, 5, 1.0, False),
    (32000, 3, 8, 1.0, False),
]

LAYOUTS = {1: "mono", 2: "stereo", 3: "3.0", 6: "5.1"}

# For each channel count, the Vorbis channel each WAVE-order channel is:
# 3 is L C R, 5 L C R BL BR, 6 L C R BL BR LFE, 7 L C R SL SR BC LFE,
# 8 L C R SL SR BL BR LFE.
WAVE_FROM_VORBIS = {
    3: [0, 2, 1],
    5: [0, 2, 1, 3, 4],
    6: [0, 2, 1, 5, 3, 4],
    7: [0, 2, 1, 6, 5, 3, 4],
    8: [0, 2, 1, 7, 5, 6, 3, 4],
}


def reorder_to_wave(path, channels):
    order = WAVE_FROM_VORBIS.get(channels)
    if order is None:
        return
    with open(path, "rb") as reference:
        raw = reference.read()
    values = struct.unpack("<%df" % (len(raw) // 4), raw)
    reordered = []
    for frame in range(len(values) // channels):
        base = frame * channels
        reordered.extend(values[base + source] for source in order)
    with open(path, "wb") as reference:
        reference.write(struct.pack("<%df" % len(reordered), *reordered))


def gate(samples, rate, channels):
    """Silences alternate quarter seconds."""
    gated = []
    for index, value in enumerate(samples):
        frame = index // channels
        gated.append(value if (frame * 4 // rate) % 2 == 0 else 0.0)
    return gated


def main():
    directory = fixturetools.section_directory("vorbis")
    if not (fixturetools.ffmpeg_has("encoders", "libvorbis") and fixturetools.ffmpeg_has("decoders", "libvorbis")):
        fixturetools.write_manifest(directory, [], skipped="ffmpeg without libvorbis")
        return
    lines = []
    for rate, channels, quality, seconds, gated in CASES:
        name = "q%d-%d-%dch%s" % (quality, rate, channels, "-gated" if gated else "")
        samples = fixturetools.test_signal(rate, channels, seconds, seed=rate + channels)
        if gated:
            samples = gate(samples, rate, channels)
        source = os.path.join(directory, name + ".wav")
        fixturetools.write_wav(source, rate, channels, samples)
        encoded = os.path.join(directory, name + ".ogg")
        fixturetools.ffmpeg(["-i", source, "-af", "aformat=channel_layouts=" + LAYOUTS[channels],
                             "-c:a", "libvorbis", "-q:a", str(quality), encoded])
        reference = os.path.join(directory, name + ".f32")
        fixturetools.ffmpeg(["-c:a", "libvorbis", "-i", encoded, "-f", "f32le", reference])
        reorder_to_wave(reference, channels)
        os.remove(source)
        lines.append("%s.ogg %s.f32 %d %d %d" % (name, name, rate, channels, quality))
    fixturetools.write_manifest(directory, lines)


main()
