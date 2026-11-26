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

"""Opus fixtures for MediaTest.Opus: FIXTURES/opus/.

Each fixture is a test signal encoded by the host's libopus (through
ffmpeg) with one combination of application (voip: SILK and hybrid;
audio; lowdelay: CELT only), bitrate, frame duration, channels and
in-band FEC, written as
  NAME.packets  the Opus packets, each after its length (32-bit big-endian)
  NAME.head     the OpusHead packet
  NAME.f32      libopus' own decoding (48 kHz, 32-bit float, interleaved,
                pre-skip and end trimming applied by ffmpeg)
and a manifest line "NAME CHANNELS PRESKIP MINIMUM-SNR-DB". The packets
are taken out of the Ogg file here, so the test needs no Ogg reader.
"""

import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import fixturetools  # noqa: E402

# name, channels, application, bitrate, frame duration (ms), extra options, minimum SNR
FIXTURES = [
    ("silk-nb-mono-20", 1, "voip", "8k", "20", [], 60),
    ("silk-mb-mono-20", 1, "voip", "12k", "20", [], 60),
    ("silk-wb-mono-10", 1, "voip", "16k", "10", [], 60),
    ("silk-wb-mono-40", 1, "voip", "16k", "40", [], 60),
    ("silk-wb-mono-60", 1, "voip", "18k", "60", [], 60),
    ("silk-wb-stereo-20", 2, "voip", "24k", "20", [], 60),
    ("silk-fec-mono-20", 1, "voip", "16k", "20", ["-packet_loss", "20", "-fec", "1"], 60),
    ("silk-fec-stereo-60", 2, "voip", "32k", "60", ["-packet_loss", "20", "-fec", "1"], 60),
    ("hybrid-swb-mono-20", 1, "voip", "28k", "20", [], 60),
    ("hybrid-fb-stereo-20", 2, "voip", "48k", "20", [], 60),
    ("hybrid-fb-stereo-10", 2, "audio", "40k", "10", [], 60),
    ("celt-audio-stereo-20", 2, "audio", "128k", "20", [], 60),
    ("celt-audio-mono-20", 1, "audio", "64k", "20", [], 60),
    ("celt-lowdelay-stereo-2.5", 2, "lowdelay", "128k", "2.5", [], 60),
    ("celt-lowdelay-stereo-5", 2, "lowdelay", "96k", "5", [], 60),
    ("celt-lowdelay-mono-10", 1, "lowdelay", "48k", "10", [], 60),
    ("celt-cbr-stereo-20", 2, "audio", "96k", "20", ["-vbr", "off"], 60),
    ("celt-low-rate-stereo-20", 2, "audio", "24k", "20", [], 60),
    ("audio-60-stereo", 2, "audio", "64k", "60", [], 60),
    ("audio-40-mono", 1, "audio", "32k", "40", [], 60),
    ("surround-51", 6, "audio", "256k", "20", ["-mapping_family", "1"], 60),
]


def ogg_packets(data):
    """The packets of an Ogg stream (one logical stream)."""
    packets = []
    current = b""
    position = 0
    while position + 27 <= len(data):
        if data[position:position + 4] != b"OggS":
            raise ValueError("not an Ogg page")
        segment_count = data[position + 26]
        table = data[position + 27:position + 27 + segment_count]
        body = position + 27 + segment_count
        for lacing in table:
            current += data[body:body + lacing]
            body += lacing
            if lacing < 255:
                packets.append(current)
                current = b""
        position = body
    return packets


def make(directory, name, channels, application, bitrate, duration, extra):
    source = os.path.join(directory, name + ".source.wav")
    encoded = os.path.join(directory, name + ".opus")
    reference = os.path.join(directory, name + ".f32")
    rate = 48000
    fixturetools.write_wav(source, rate, channels, fixturetools.test_signal(rate, channels, 1.5, seed=len(name)))
    layout = []
    if channels == 6:
        layout = ["-af", "aformat=channel_layouts=5.1"]
    fixturetools.ffmpeg(["-i", source] + layout + ["-c:a", "libopus", "-application", application, "-b:a", bitrate,
                        "-frame_duration", duration] + extra + ["-f", "ogg", encoded])
    fixturetools.ffmpeg(["-c:a", "libopus", "-i", encoded, "-f", "f32le", "-ar", "48000", reference])
    packets = ogg_packets(open(encoded, "rb").read())
    head, audio = packets[0], packets[2:]
    with open(os.path.join(directory, name + ".head"), "wb") as output:
        output.write(head)
    with open(os.path.join(directory, name + ".packets"), "wb") as output:
        for packet in audio:
            output.write(struct.pack(">I", len(packet)) + packet)
    pre_skip = struct.unpack("<H", head[10:12])[0]
    os.remove(source)
    os.remove(encoded)
    return pre_skip


def main():
    directory = fixturetools.section_directory("opus")
    if not (fixturetools.ffmpeg_has("encoders", "libopus") and fixturetools.ffmpeg_has("decoders", "libopus")):
        fixturetools.write_manifest(directory, [], skipped="ffmpeg with libopus not found")
        return
    lines = []
    for name, channels, application, bitrate, duration, extra, minimum in FIXTURES:
        try:
            pre_skip = make(directory, name, channels, application, bitrate, duration, extra)
        except Exception as error:  # an option the host's ffmpeg lacks: skip that fixture
            print("opus fixture %s skipped: %s" % (name, error), file=sys.stderr)
            continue
        lines.append("%s %d %d %d" % (name, channels, pre_skip, minimum))
    fixturetools.write_manifest(directory, lines)


main()
