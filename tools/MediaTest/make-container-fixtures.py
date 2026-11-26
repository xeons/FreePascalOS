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

"""Fixtures for libmedia's container readers (Ogg, Matroska/WebM, MP4).

make-container-fixtures.py FIXTURES

Writes FIXTURES/containers/: files the host's ffmpeg muxes from the same
synthetic signal (and small synthetic videos, with the video encoders the
host has), and for each NAME:

  NAME.streams   a line per stream: index codec rate channels timebase
                 width height extradata-md5 (or "-")
  NAME.packets   a line per packet: stream pts duration size key md5,
                 as ffprobe reports them ("-" for an unknown time)

plus files this script writes byte by byte (Matroska with every kind of
lacing, header stripping and unknown sizes; a chained Ogg stream), whose
packets it knows itself. manifest.txt names each file:

  file NAME FORMAT DURATION-TOLERANCE
  mse NAME INIT-BYTES      (a fragmented MP4 fed as an init segment, then
                            the rest appended)
"""

import hashlib
import os
import random
import struct
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from fixturetools import (section_directory, have_tool, ffmpeg_has, ffmpeg, write_manifest,  # noqa: E402
                          test_signal, write_wav)


def probe_streams(path):
    output = subprocess.run(
        ["ffprobe", "-v", "error", "-show_entries",
         "stream=index,codec_name,sample_rate,channels,time_base,width,height,extradata_hash",
         "-show_data_hash", "MD5", "-of", "compact=p=0", path],
        capture_output=True, text=True, check=True).stdout
    lines = []
    for line in output.splitlines():
        fields = dict(item.split("=", 1) for item in line.split("|") if "=" in item)
        extradata = fields.get("extradata_hash", "")
        extradata = extradata.split(":", 1)[1] if ":" in extradata else "-"
        lines.append(" ".join([
            fields.get("index", "0"), fields.get("codec_name", "-"),
            value_or_zero(fields.get("sample_rate")), value_or_zero(fields.get("channels")),
            fields.get("time_base", "0/0"),
            value_or_zero(fields.get("width")), value_or_zero(fields.get("height")), extradata]))
    return lines


def value_or_zero(value):
    if value is None or value in ("", "N/A"):
        return "0"
    return value


def probe_packets(path):
    output = subprocess.run(
        ["ffprobe", "-v", "error", "-show_entries", "packet=stream_index,pts,duration,size,flags,data_hash",
         "-show_data_hash", "MD5", "-of", "compact=p=0", path],
        capture_output=True, text=True, check=True).stdout
    lines = []
    for line in output.splitlines():
        fields = dict(item.split("=", 1) for item in line.split("|") if "=" in item)
        if "stream_index" not in fields:
            continue
        pts = fields.get("pts", "N/A")
        duration = fields.get("duration", "N/A")
        lines.append(" ".join([
            fields["stream_index"], "-" if pts == "N/A" else pts, "-" if duration == "N/A" else duration,
            fields["size"], "1" if "K" in fields.get("flags", "") else "0",
            fields["data_hash"].split(":", 1)[1]]))
    return lines


def describe(directory, name):
    path = os.path.join(directory, name)
    with open(path + ".streams", "w") as streams:
        streams.write("\n".join(probe_streams(path)) + "\n")
    with open(path + ".packets", "w") as packets:
        packets.write("\n".join(probe_packets(path)) + "\n")


# --- Matroska written here: every lacing, header stripping, unknown sizes.

def ebml_id(value):
    for length in (1, 2, 3, 4):
        if value < (1 << (8 * length)):
            return value.to_bytes(length, "big")
    raise ValueError(value)


def ebml_size(size, width=None):
    if size is None:
        return bytes([0x01, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF])
    for length in range(1, 9):
        if width is not None and length != width:
            continue
        if size < (1 << (7 * length)) - 1:
            return ((1 << (7 * length)) | size).to_bytes(length, "big")
    raise ValueError(size)


def element(identifier, payload, unknown=False):
    return ebml_id(identifier) + ebml_size(None if unknown else len(payload)) + payload


def unsigned(identifier, value):
    length = max(1, (value.bit_length() + 7) // 8)
    return element(identifier, value.to_bytes(length, "big"))


def text(identifier, value):
    return element(identifier, value.encode())


def xiph_size(size):
    return b"\xff" * (size // 255) + bytes([size % 255])


def ebml_lace_number(value):
    return ebml_size(value)


def ebml_signed(value):
    for length in range(1, 9):
        bias = (1 << (7 * length - 1)) - 1
        if -bias <= value <= bias:
            return ebml_size(value + bias, length)
    raise ValueError(value)


def make_block(track, timestamp, frames, lacing, keyframe=True):
    flags = 0x80 if keyframe else 0
    header = ebml_size(track) + struct.pack(">h", timestamp)
    if len(frames) == 1 or lacing == "none":
        return header + bytes([flags]) + frames[0]
    if lacing == "xiph":
        flags |= 0x02
        lace = bytes([len(frames) - 1]) + b"".join(xiph_size(len(frame)) for frame in frames[:-1])
    elif lacing == "fixed":
        flags |= 0x04
        lace = bytes([len(frames) - 1])
    else:
        flags |= 0x06
        lace = bytes([len(frames) - 1]) + ebml_lace_number(len(frames[0]))
        for previous, frame in zip(frames, frames[1:-1]):
            lace += ebml_signed(len(frame) - len(previous))
    return header + bytes([flags]) + lace + b"".join(frames)


def write_laced_matroska(directory, name):
    """Track 1: header-stripped (prefix b"HDR!") Xiph and EBML laces;
    track 2: fixed lacing; a BlockGroup with a duration; unknown-size
    segment and clusters. DefaultDuration 10 ms, TimestampScale 1 ms."""
    generator = random.Random(7)
    prefix = b"HDR!"
    tracks = (
        element(0xAE,
                unsigned(0xD7, 1) + unsigned(0x83, 2) + text(0x86, "A_PCM/INT/LIT") + unsigned(0x23E383, 10000000) +
                element(0xE1, element(0xB5, struct.pack(">f", 8000.0)) + unsigned(0x9F, 1) + unsigned(0x6264, 16)) +
                element(0x6D80, element(0x6240, unsigned(0x5032, 1) +
                                        element(0x5034, unsigned(0x4254, 3) + element(0x4255, prefix))))) +
        element(0xAE,
                unsigned(0xD7, 2) + unsigned(0x83, 2) + text(0x86, "A_PCM/INT/BIG") + unsigned(0x23E383, 10000000) +
                text(0x22B59C, "fin") +
                element(0xE1, element(0xB5, struct.pack(">f", 8000.0)) + unsigned(0x9F, 2) + unsigned(0x6264, 16))))
    expected = []
    clusters = b""
    timestamp = 0
    for cluster_index in range(3):
        blocks = b""
        cluster_time = cluster_index * 1000
        for block_index in range(4):
            relative = block_index * 60
            count = 3 + block_index % 3
            # Track 1, alternating Xiph and EBML lacing, stored without the prefix.
            stored = [bytes(generator.randrange(256) for _ in range(generator.randrange(1, 600)))
                      for _ in range(count)]
            lacing = "xiph" if block_index % 2 == 0 else "ebml"
            blocks += element(0xA3, make_block(1, relative, stored, lacing))
            for index, frame in enumerate(stored):
                expected.append((0, cluster_time + relative + 10 * index, 10, prefix + frame))
            # Track 2, fixed lacing (equal sizes): 4 bytes per frame.
            fixed = [bytes(generator.randrange(256) for _ in range(40)) for _ in range(2)]
            blocks += element(0xA3, make_block(2, relative + 5, fixed, "fixed"))
            for index, frame in enumerate(fixed):
                expected.append((1, cluster_time + relative + 5 + 10 * index, 10, frame))
        # A BlockGroup with its own duration.
        lone = bytes(generator.randrange(256) for _ in range(77))
        blocks += element(0xA0, element(0xA1, make_block(2, 300, [lone], "none")) + unsigned(0x9B, 25))
        expected.append((1, cluster_time + 300, 25, lone))
        clusters += element(0x1F43B675, unsigned(0xE7, cluster_time) + blocks, unknown=True)
        timestamp += 1000
    header = element(0x1A45DFA3, unsigned(0x4286, 1) + unsigned(0x42F7, 1) + unsigned(0x42F2, 4) +
                     unsigned(0x42F3, 8) + text(0x4282, "matroska") + unsigned(0x4287, 4) + unsigned(0x4285, 2))
    info = element(0x1549A966, unsigned(0x2AD7B1, 1000000) + text(0x4D80, "fixture") + text(0x5741, "fixture"))
    segment = element(0x18538067, info + element(0x1654AE6B, tracks) + clusters, unknown=True)
    with open(os.path.join(directory, name), "wb") as output:
        output.write(header + segment)
    write_expected(directory, name, ["0 pcm_s16le 8000 1 1/1000 0 0 -", "1 pcm_s16be 8000 2 1/1000 0 0 -"],
                   [(stream, pts, duration, data, True) for stream, pts, duration, data in expected])


def write_expected(directory, name, streams, packets):
    path = os.path.join(directory, name)
    with open(path + ".streams", "w") as output:
        output.write("\n".join(streams) + "\n")
    with open(path + ".packets", "w") as output:
        for stream, pts, duration, data, key in packets:
            output.write("%d %d %d %d %d %s\n" % (stream, pts, duration, len(data), 1 if key else 0,
                                                  hashlib.md5(data).hexdigest()))


def concatenate(directory, name, parts):
    """A chained Ogg stream: the parts one after the other; each link's
    packets follow as a stream of its own."""
    with open(os.path.join(directory, name), "wb") as output:
        for part in parts:
            with open(os.path.join(directory, part), "rb") as source:
                output.write(source.read())
    packets = []
    streams = []
    for stream_index, part in enumerate(parts):
        with open(os.path.join(directory, part + ".streams")) as source:
            fields = source.readline().split()
            fields[0] = str(stream_index)
            streams.append(" ".join(fields))
        with open(os.path.join(directory, part + ".packets")) as source:
            for line in source:
                fields = line.split()
                fields[0] = str(stream_index)
                packets.append(" ".join(fields))
    path = os.path.join(directory, name)
    with open(path + ".streams", "w") as output:
        output.write("\n".join(streams) + "\n")
    with open(path + ".packets", "w") as output:
        output.write("\n".join(packets) + "\n")


def main():
    directory = section_directory("containers")
    manifest = []
    generator_ok = have_tool("ffmpeg") and have_tool("ffprobe")
    write_laced_matroska(directory, "laced.mkv")
    manifest.append("file laced.mkv matroska 0")
    if not generator_ok:
        write_manifest(directory, manifest, skipped="no ffmpeg/ffprobe: only the written fixtures")
        return
    source = os.path.join(directory, "source.wav")
    write_wav(source, 48000, 2, test_signal(48000, 2, 1.5))
    mono = os.path.join(directory, "mono44.wav")
    write_wav(mono, 44100, 1, test_signal(44100, 1, 1.2, seed=3))

    def audio(name, codec_arguments, form, tolerance, input_path=source, extra=()):
        ffmpeg(["-i", input_path] + codec_arguments + list(extra) + [os.path.join(directory, name)])
        describe(directory, name)
        manifest.append("file %s %s %d" % (name, form, tolerance))

    has = {name: ffmpeg_has("encoders", name) for name in
           ("libopus", "libvorbis", "flac", "libmp3lame", "pcm_s16le", "pcm_f32le", "aac",
            "libvpx", "libvpx-vp9", "libaom-av1", "libx264")}
    if has["libopus"]:
        audio("opus.ogg", ["-c:a", "libopus", "-b:a", "64k"], "ogg", 0)
        audio("opus.webm", ["-c:a", "libopus"], "webm", 1)
        audio("opus.mp4", ["-c:a", "libopus"], "mp4", 0)
        audio("opus-fragmented.mp4", ["-c:a", "libopus", "-frag_duration", "200000",
                                      "-movflags", "frag_keyframe+empty_moov+default_base_moof"], "mp4", 0)
        audio("opus-mono.ogg", ["-c:a", "libopus", "-b:a", "24k"], "ogg", 0, input_path=mono)
    if has["libvorbis"]:
        audio("vorbis.ogg", ["-c:a", "libvorbis", "-q:a", "3"], "ogg", 0)
        audio("vorbis-mono.ogg", ["-c:a", "libvorbis", "-q:a", "1"], "ogg", 0, input_path=mono)
        audio("vorbis.webm", ["-c:a", "libvorbis"], "webm", 1)
    if has["flac"]:
        audio("flac.oga", ["-c:a", "flac"], "ogg", 0)
        audio("flac.mkv", ["-c:a", "flac"], "matroska", 1)
        audio("flac.mp4", ["-c:a", "flac", "-strict", "-2"], "mp4", 0)
    if has["libmp3lame"]:
        audio("mp3.mkv", ["-c:a", "libmp3lame"], "matroska", 1, input_path=mono)
        audio("mp3.mp4", ["-c:a", "libmp3lame"], "mp4", 0, input_path=mono)
    if has["pcm_s16le"]:
        audio("pcm.mkv", ["-c:a", "pcm_s16le"], "matroska", 1)
        audio("pcm-be.mkv", ["-c:a", "pcm_s16be"], "matroska", 1)
        audio("pcm.mp4", ["-c:a", "pcm_s16le"], "mp4", 0)
    if has["pcm_f32le"]:
        audio("float.mkv", ["-c:a", "pcm_f32le"], "matroska", 1)
    if has["aac"]:
        audio("aac.mp4", ["-c:a", "aac", "-b:a", "96k"], "mp4", 0)
    # Streamed Matroska (no seeking while writing): unknown sizes, no cues.
    if has["libopus"]:
        with open(os.path.join(directory, "live.webm"), "wb") as output:
            subprocess.run(["ffmpeg", "-nostdin", "-hide_banner", "-loglevel", "error", "-i", source,
                            "-c:a", "libopus", "-f", "webm", "-live", "1", "pipe:1"],
                           stdout=output, check=True)
        describe(directory, "live.webm")
        manifest.append("file live.webm webm 1")
    if has["libopus"] and has["libvorbis"]:
        concatenate(directory, "chained.ogg", ["opus.ogg", "vorbis.ogg"])
        manifest.append("file chained.ogg ogg 0")

    def video(name, arguments, form, tolerance):
        ffmpeg(["-f", "lavfi", "-i", "testsrc2=size=96x64:rate=25:duration=1.2", "-i", source,
                "-shortest", "-g", "10"] + arguments + [os.path.join(directory, name)])
        describe(directory, name)
        manifest.append("file %s %s %d" % (name, form, tolerance))

    if has["libvpx"] and has["libvorbis"]:
        video("vp8.webm", ["-c:v", "libvpx", "-b:v", "200k", "-c:a", "libvorbis"], "webm", 1)
    if has["libvpx-vp9"] and has["libopus"]:
        video("vp9.webm", ["-c:v", "libvpx-vp9", "-b:v", "200k", "-deadline", "realtime", "-c:a", "libopus"],
              "webm", 1)
        video("vp9.mp4", ["-c:v", "libvpx-vp9", "-b:v", "200k", "-deadline", "realtime", "-c:a", "libopus"],
              "mp4", 0)
    if has["libaom-av1"]:
        video("av1.mkv", ["-c:v", "libaom-av1", "-cpu-used", "8", "-b:v", "100k", "-an"], "matroska", 1)
        video("av1.mp4", ["-c:v", "libaom-av1", "-cpu-used", "8", "-b:v", "100k", "-an"], "mp4", 0)
        video("av1-fragmented.mp4", ["-c:v", "libaom-av1", "-cpu-used", "8", "-b:v", "100k", "-c:a", "libopus",
                                     "-movflags", "frag_keyframe+empty_moov+default_base_moof"], "mp4", 0)
    if has["libx264"]:
        # B-frames: composition offsets (ctts) and an edit list.
        video("h264.mp4", ["-c:v", "libx264", "-bf", "2", "-preset", "fast", "-an"], "mp4", 0)
    fragmented = os.path.join(directory, "opus-fragmented.mp4")
    if os.path.exists(fragmented):
        with open(fragmented, "rb") as source_file:
            data = source_file.read()
        # The init segment ends where the first moof starts.
        position = 0
        while position + 8 <= len(data):
            size = int.from_bytes(data[position:position + 4], "big")
            if data[position + 4:position + 8] == b"moof":
                break
            position += size
        manifest.append("mse opus-fragmented.mp4 %d" % position)
    write_manifest(directory, manifest)


main()
