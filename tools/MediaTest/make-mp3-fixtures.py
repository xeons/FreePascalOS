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

"""MP3 fixtures for libmedia's Layer III decoder and .mp3 reader.

The host's lame encodes synthetic signals (tones and chirps, and a
castanet-like train of noise bursts that forces short blocks) at constant,
variable and average bit rates, in mono, stereo, joint and forced mid/side
stereo, at the MPEG-1, MPEG-2 and MPEG-2.5 rates, with and without CRCs,
the LAME tag, the bit reservoir and ID3 tags, and in free format. The
references are ffmpeg's mp3float decoding as 32-bit floats; ffmpeg reads
the LAME tag the same way libmedia does (encoder delay + 529 samples
dropped at the start, padding - 529 at the end), so the two line up
sample for sample. One stream is also copied into a WAV file (format
0x55), whose packets cut frames in pieces.

FIXTURES/mp3/manifest.txt, a line each:
  decode FILE REFERENCE RATE CHANNELS   decode, compare with the reference
  pieces FILE REFERENCE RATE CHANNELS   feed the raw file to the decoder in
                                         uneven pieces, compare
  decode16 FILE REFERENCE RATE CHANNELS SKIP
                                         compare with 16-bit samples from lame's
                                         own decoder (for free format, which
                                         ffmpeg does not read), which drops the
                                         first SKIP (529) samples
  seek FILE                              seek into the middle and decode
"""

import math
import os
import random
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from fixturetools import (section_directory, have_tool, ffmpeg_has, run, ffmpeg, write_manifest,  # noqa: E402
                          test_signal, write_wav)


def castanets(rate, channels, seconds, seed=7):
    """Short decaying noise bursts every 120 ms over a low tone: transients
    that make the encoder switch to short blocks."""
    generator = random.Random(seed)
    frames = int(rate * seconds)
    period = int(rate * 0.12)
    samples = []
    for index in range(frames):
        phase = index % period
        envelope = math.exp(-phase / (rate * 0.004))
        tone = 0.1 * math.sin(2 * math.pi * 110 * index / rate)
        for channel in range(channels):
            samples.append(tone + 0.7 * envelope * generator.uniform(-1, 1))
    return samples


def main():
    directory = section_directory("mp3")
    if not have_tool("lame") or not ffmpeg_has("decoders", "mp3float"):
        write_manifest(directory, [], skipped="lame or ffmpeg's mp3float decoder is missing")
        return

    signals = {}

    def source(name, rate, channels, kind="tone", seconds=2.0):
        key = (name, rate, channels)
        if key not in signals:
            path = os.path.join(directory, "source-%s-%d-%d.wav" % (name, rate, channels))
            if kind == "tone":
                samples = test_signal(rate, channels, seconds)
            else:
                samples = castanets(rate, channels, seconds)
            write_wav(path, rate, channels, samples)
            signals[key] = path
        return signals[key]

    lines = []

    def reference(name):
        path = os.path.join(directory, name + ".f32")
        ffmpeg(["-c:a", "mp3float", "-i", os.path.join(directory, name), "-f", "f32le", path])
        return name + ".f32"

    def encode(name, rate, channels, options, kind="tone", piecewise=False, seek=False, lame_reference=False):
        wav = source(kind, rate, channels, kind)
        output = os.path.join(directory, name)
        run(["lame", "--quiet", "--resample", "%g" % (rate / 1000.0)] + options + [wav, output])
        if lame_reference:
            ref = name + ".s16"
            run(["lame", "--quiet", "--decode", "-t", output, os.path.join(directory, ref)])
            lines.append("decode16 %s %s %d %d 529" % (name, ref, rate, channels))
            return
        ref = reference(name)
        lines.append("decode %s %s %d %d" % (name, ref, rate, channels))
        if piecewise:
            lines.append("pieces %s %s %d %d" % (name, ref, rate, channels))
        if seek:
            lines.append("seek %s" % name)

    # MPEG-1 at 44.1, 48 and 32 kHz, the bit rate range and the stereo modes.
    encode("cbr32-mono-32k.mp3", 32000, 1, ["-b", "32", "-m", "m"])
    encode("cbr128-joint-44k.mp3", 44100, 2, ["-b", "128", "-m", "j"], seek=True)
    encode("cbr320-stereo-44k.mp3", 44100, 2, ["-b", "320", "-m", "s"])
    encode("cbr192-forced-ms-48k.mp3", 48000, 2, ["-b", "192", "-m", "f"])
    encode("cbr96-mono-44k.mp3", 44100, 1, ["-b", "96", "-m", "m"])
    encode("crc-128-44k.mp3", 44100, 2, ["-b", "128", "-p"])
    encode("noreservoir-160-44k.mp3", 44100, 2, ["-b", "160", "--nores"])
    # Variable and average bit rates (Xing table, LAME tag).
    encode("vbr-v0-44k.mp3", 44100, 2, ["-V", "0"], seek=True)
    encode("vbr-v5-44k.mp3", 44100, 2, ["-V", "5"])
    encode("vbr-v9-44k.mp3", 44100, 2, ["-V", "9"])
    encode("abr96-44k.mp3", 44100, 2, ["--abr", "96"])
    # Short blocks.
    encode("castanets-128-44k.mp3", 44100, 2, ["-b", "128"], kind="castanets")
    encode("castanets-vbr-48k.mp3", 48000, 1, ["-V", "2", "-m", "m"], kind="castanets")
    # MPEG-2 (16, 22.05, 24 kHz) and MPEG-2.5 (8, 11.025, 12 kHz).
    encode("mpeg2-64-22k.mp3", 22050, 2, ["-b", "64"])
    encode("mpeg2-vbr-24k.mp3", 24000, 2, ["-V", "4"])
    encode("mpeg2-32-16k-mono.mp3", 16000, 1, ["-b", "32", "-m", "m"])
    encode("mpeg2-castanets-22k.mp3", 22050, 2, ["-b", "80"], kind="castanets")
    encode("mpeg25-16-8k-mono.mp3", 8000, 1, ["-b", "16", "-m", "m"])
    encode("mpeg25-32-11k.mp3", 11025, 2, ["-b", "32"])
    encode("mpeg25-castanets-12k.mp3", 12000, 2, ["-b", "40"], kind="castanets")
    # Without the LAME tag (no delay information), with ID3 tags, free format.
    encode("notag-128-44k.mp3", 44100, 2, ["-b", "128", "-t"], piecewise=True)
    encode("id3-112-44k.mp3", 44100, 2, ["-b", "112", "--add-id3v2", "--pad-id3v2-size", "3000",
                                         "--tt", "Fixture", "--ta", "FreePascalOS"])
    encode("id3v1-64-44k.mp3", 44100, 1, ["-b", "64", "-m", "m", "--id3v1-only", "--tt", "Fixture"])
    encode("freeformat-400-44k.mp3", 44100, 2, ["-b", "400", "--freeformat", "-t"],
           lame_reference=True)

    # MP3 in WAV: the frames copied without the information frame.
    wav_name = "mp3-in-wav.wav"
    ffmpeg(["-i", os.path.join(directory, "notag-128-44k.mp3"), "-c:a", "copy", "-f", "wav",
            os.path.join(directory, wav_name)])
    lines.append("decode %s %s %d %d" % (wav_name, reference(wav_name), 44100, 2))

    for path in signals.values():
        os.remove(path)
    write_manifest(directory, lines)


main()
