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

"""FLAC fixtures: WAV files of synthetic sound encoded by the host's flac
in many settings. FLAC is lossless, so the WAV is the reference: the test
decodes both and wants the same samples, and the STREAMINFO MD5 of them.

manifest.txt lines: FLAC-FILE WAV-FILE SEEKS
  SEEKS is "seek" when the test should also seek in the file.
Also written: the plain WAV fixtures for the WAV reader's own checks
(wav-*.wav, with the floats they were made from in wav-*.wav.f32),
listed as "wav WAV-FILE BITS FLOAT CHANNELS RATE FRAMES".
"""

import math
import os
import random
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from fixturetools import section_directory, have_tool, write_manifest, test_signal, write_wav, write_raw_float  # noqa: E402


def silence_and_noise(rate, seconds):
    """Silence (constant subframes), then white noise (verbatim and escaped
    residuals), then a tone, mono."""
    generator = random.Random(7)
    frames = int(rate * seconds)
    samples = []
    for index in range(frames):
        part = index * 3 // frames
        if part == 0:
            samples.append(0.0)
        elif part == 1:
            samples.append(generator.uniform(-0.9, 0.9))
        else:
            samples.append(0.5 * math.sin(2 * math.pi * 1000 * index / rate))
    return samples


def wasted_bits(samples):
    """Samples whose 16-bit values are multiples of 8 (three wasted bits)."""
    return [round(value * 4096) / 4096 for value in samples]


def main():
    directory = section_directory("flac")
    lines = []
    wav_lines = []

    # The WAV reader's own fixtures: every sample kind it reads.
    for bits, float_samples, extensible, channels, rate in [(8, False, False, 1, 8000), (16, False, False, 2, 44100),
                                                            (24, False, True, 2, 48000), (32, False, False, 1, 32000),
                                                            (32, True, False, 2, 48000), (64, True, False, 1, 22050),
                                                            (16, False, True, 6, 48000)]:
        name = "wav-%d%s-%dch-%d%s.wav" % (bits, "f" if float_samples else "", channels, rate,
                                           "-ext" if extensible else "")
        samples = test_signal(rate, channels, 0.25, seed=bits)
        write_wav(os.path.join(directory, name), rate, channels, samples, bits, float_samples, extensible)
        write_raw_float(os.path.join(directory, name + ".f32"), samples)
        wav_lines.append("wav %s %d %d %d %d %d" % (name, bits, 1 if float_samples else 0, channels, rate,
                                                      len(samples) // channels))

    if not have_tool("flac"):
        write_manifest(directory, wav_lines, skipped="no flac on the host")
        return

    cases = [
        ("s16-stereo-44100", 44100, 2, 16, 2.0, [], "seek"),
        ("s16-mono-8000-level0", 8000, 1, 16, 1.0, ["-0"], ""),
        ("s24-stereo-96000-level8", 96000, 2, 24, 1.0, ["-8"], "seek"),
        ("s8-mono-22050", 22050, 1, 8, 1.0, ["-3"], ""),
        ("s32-stereo-48000", 48000, 2, 32, 0.5, [], ""),
        ("s16-6ch-48000", 48000, 6, 16, 0.5, [], ""),
        ("s24-8ch-48000", 48000, 8, 24, 0.5, [], ""),
        ("s16-lpc32-block16384", 44100, 2, 16, 1.5, ["--lax", "-l", "32", "-b", "16384", "-e", "-p"], ""),
        ("s16-block192", 44100, 2, 16, 0.5, ["-b", "192"], ""),
        ("s16-block65535", 44100, 1, 16, 3.0, ["--lax", "-b", "65535"], ""),
        ("s16-rate11127", 11127, 1, 16, 1.0, [], ""),
        ("s24-stereo-44100-level5", 44100, 2, 24, 0.5, ["-5"], ""),
        ("s16-no-seektable", 44100, 2, 16, 2.0, ["--no-seektable"], "seek"),
    ]
    for name, rate, channels, bits, seconds, options, seeks in cases:
        samples = test_signal(rate, channels, seconds, seed=len(name))
        wav = name + ".wav"
        write_wav(os.path.join(directory, wav), rate, channels, samples, bits, extensible=channels > 2 or bits > 16)
        flac_file = name + ".flac"
        subprocess.run(["flac", "-s", "-f"] + options + ["-o", os.path.join(directory, flac_file),
                                                         os.path.join(directory, wav)], check=True,
                       stderr=subprocess.DEVNULL)
        lines.append("%s %s %s" % (flac_file, wav, seeks or "-"))

    # Constant, verbatim and escaped subframes; wasted bits.
    special = [("s16-silence-noise", silence_and_noise(44100, 1.5)),
               ("s16-wasted-bits", wasted_bits(test_signal(44100, 1, 1.0, seed=3)))]
    for name, samples in special:
        wav = name + ".wav"
        write_wav(os.path.join(directory, wav), 44100, 1, samples, 16)
        flac_file = name + ".flac"
        subprocess.run(["flac", "-s", "-f", "-o", os.path.join(directory, flac_file), os.path.join(directory, wav)],
                       check=True, stderr=subprocess.DEVNULL)
        lines.append("%s %s -" % (flac_file, wav))

    # An ID3v2 tag in front of the stream.
    with open(os.path.join(directory, "s16-stereo-44100.flac"), "rb") as source:
        stream = source.read()
    tag_body = b"TIT2" + (6).to_bytes(4, "big") + b"\0\0" + b"\x03Title"
    tag = b"ID3\x04\x00\x00" + bytes([0, 0, 0, len(tag_body)]) + tag_body
    with open(os.path.join(directory, "s16-id3.flac"), "wb") as output:
        output.write(tag + stream)
    lines.append("s16-id3.flac s16-stereo-44100.wav -")

    write_manifest(directory, lines + wav_lines)


main()
