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

"""The TIFF fixtures of ImageTest.

    make-tiff-fixtures.py OUTPUT_DIRECTORY

Files Pillow (with libtiff) writes, with Pillow's decoding as their
reference (name.rgba, see fixturecommon.py):

  tiff-none, tiff-packbits, tiff-lzw, tiff-deflate   RGB, each compression
  tiff-pillow-rgba, -grey, -palette, -bilevel        other modes
  tiff-jpeg-rgb                                      JPEG, RGB (no transform)
  tiff-jpeg-ycbcr                                    JPEG, YCbCr 1 x 1
  tiff-pages (-0, -1, -2)                            three pages, sizes differ
  tiff-metadata (+ .icc)                             description, software,
                                                     date, resolution in cm,
                                                     orientation, ICC profile
  tiff-g4, -g3, -g3-2d, -g3-fill, -ccitt-rle,         fax compression, also in
  -g4-strips, -g4-fill-order, -g3-2d-fill-order,      strips, fill order 2, and
  -g3-2d-fax-width                                   1728 pixels wide
  tiff-float-predictor-deflate, -lzw                 32-bit float grey,
                                                     predictor 3 (the truth is
                                                     worked out here)

Files put together byte by byte here, for what Pillow does not write:
big-endian files, BigTIFF, tiles, separate planes, fax data seen
white is zero, floating point samples of 16 and 32 bits with and
without the floating point predictor (and one of high dynamic range,
scaled down by its brightest sample, with a NaN and an infinity), old-
style JPEG (a whole stream at JPEGInterchangeFormat, or a stream a
strip), the horizontal
predictor on 8 and 16 bits, 1-, 2-, 4- and 16-bit samples, white is
zero, palettes of 4 bits, associated and unassociated alpha, CMYK,
YCbCr subsampled 2 x 2 and 2 x 1, JPEG with JPEGTables in strips and in
tiles, old-style LZW and fill order 2. Their references are worked out
here from the samples written, by the rules libimage follows:

  - N-bit samples become 8 bits by rounding (v x 255 / (2^N - 1)): Pillow
    takes the high byte of 16-bit RGB and clips 16-bit grey, which is
    not what a careful decoder does, so 16-bit files are not compared
    with Pillow at all;
  - associated alpha is divided out as Pillow does (colour x 255 div
    alpha, at most 255; nothing where alpha is 0 or 255);
  - CMYK is (255 - ink) x (255 - black) / 255, rounded, as for JPEG;
  - YCbCr is libtiff's conversion (16-bit fixed point);
  - JPEG strips and tiles are Pillow's decoding of each one on its own.

Where Pillow reads one of these files the same way, that is checked
here too (a difference is printed as a warning, not an error), so the
files are known to be right. Malformed files (bad-tiff-*) are made from
good ones.
"""

import io
import os
import random
import struct
import sys
import zlib

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from PIL import Image  # noqa: E402

import fixturecommon  # noqa: E402

OUTPUT = sys.argv[1] if len(sys.argv) > 1 else "build/tools/image-fixtures"
WARNINGS = []

SHORT = 3
LONG = 4
RATIONAL = 5
ASCII = 2
UNDEFINED = 7
LONG8 = 16

TYPE_FORMATS = {1: "B", ASCII: "B", SHORT: "H", LONG: "I", RATIONAL: "II", UNDEFINED: "B", LONG8: "Q"}
TYPE_SIZES = {1: 1, ASCII: 1, SHORT: 2, LONG: 4, RATIONAL: 8, UNDEFINED: 1, LONG8: 8}


def path(name):
    return fixturecommon.output_path(OUTPUT, name)


def write(name, data):
    with open(path(name), "wb") as output:
        output.write(data)


def reference_name(name):
    return os.path.splitext(name)[0] + ".rgba"


def save_truth(name, width, height, pixels):
    fixturecommon.write_reference_pixels(path(reference_name(name)), width, height, pixels)


def compare_with_pillow(name, width, height, pixels, tolerance=0):
    """Warns when Pillow reads the fixture differently from its truth."""
    try:
        with Image.open(path(name)) as image:
            image.load()
            decoded = fixturecommon.rgba_pixels(image)
            size = image.size
    except Exception as error:  # Pillow does not read every variant
        WARNINGS.append(f"{name}: Pillow cannot read it ({error})")
        return
    if size != (width, height):
        WARNINGS.append(f"{name}: Pillow reads it as {size}")
        return
    worst = 0
    for got, wanted in zip(decoded, pixels):
        for a, b in zip(got, wanted):
            worst = max(worst, abs(a - b))
    if worst > tolerance:
        WARNINGS.append(f"{name}: Pillow reads it differently (by up to {worst})")


# --- Writing TIFF structure ------------------------------------------------

class Page:
    """A directory: its entries ({tag: (type, values)}) and its chunks
    (strips or tiles, already compressed)."""

    def __init__(self, entries, chunks, tiled=False):
        self.entries = dict(entries)
        self.chunks = chunks
        self.tiled = tiled


def value_bytes(endian, field_type, values):
    if field_type in (ASCII, UNDEFINED, 1) and isinstance(values, (bytes, bytearray)):
        return bytes(values)
    if field_type == RATIONAL:
        return b"".join(struct.pack(endian + "II", numerator, denominator) for numerator, denominator in values)
    return b"".join(struct.pack(endian + TYPE_FORMATS[field_type], value) for value in values)


def value_count(field_type, values):
    return len(values)


def build_tiff(pages, big_endian=False, bigtiff=False):
    endian = ">" if big_endian else "<"
    offset_format = "Q" if bigtiff else "I"
    inline_size = 8 if bigtiff else 4
    out = bytearray(b"MM" if big_endian else b"II")
    if bigtiff:
        out += struct.pack(endian + "HHH", 43, 8, 0)
    else:
        out += struct.pack(endian + "H", 42)
    link = len(out)
    out += struct.pack(endian + offset_format, 0)
    for page in pages:
        offsets = []
        for chunk in page.chunks:
            if len(out) % 2:
                out += b"\0"
            offsets.append(len(out))
            out += chunk
        entries = dict(page.entries)
        if page.tiled:
            entries[324] = (LONG, offsets)
            entries[325] = (LONG, [len(chunk) for chunk in page.chunks])
        else:
            entries[273] = (LONG, offsets)
            entries[279] = (LONG, [len(chunk) for chunk in page.chunks])
        encoded = {}
        for tag, (field_type, values) in entries.items():
            data = value_bytes(endian, field_type, values)
            count = len(data) // TYPE_SIZES[field_type]
            if len(data) > inline_size:
                if len(out) % 2:
                    out += b"\0"
                position = len(out)
                out += data
                field = struct.pack(endian + offset_format, position)
            else:
                field = data + b"\0" * (inline_size - len(data))
            encoded[tag] = (field_type, count, field)
        if len(out) % 2:
            out += b"\0"
        struct.pack_into(endian + offset_format, out, link, len(out))
        out += struct.pack(endian + ("Q" if bigtiff else "H"), len(encoded))
        for tag in sorted(encoded):
            field_type, count, field = encoded[tag]
            out += struct.pack(endian + "HH", tag, field_type)
            out += struct.pack(endian + offset_format, count)
            out += field
        link = len(out)
        out += struct.pack(endian + offset_format, 0)
    return bytes(out)


# --- Compression -----------------------------------------------------------

def packbits(data):
    out = bytearray()
    index = 0
    while index < len(data):
        run = 1
        while index + run < len(data) and run < 128 and data[index + run] == data[index]:
            run += 1
        if run >= 2:
            out.append((257 - run) & 0xFF)
            out.append(data[index])
            index += run
            continue
        start = index
        while index < len(data) and index - start < 128:
            if index + 1 < len(data) and data[index + 1] == data[index]:
                break
            index += 1
        if index == start:
            index += 1
        out.append(index - start - 1)
        out += data[start:index]
    return bytes(out)


class BitWriter:
    def __init__(self, lowest_first):
        self.lowest_first = lowest_first
        self.buffer = 0
        self.count = 0
        self.out = bytearray()

    def put(self, code, width):
        if self.lowest_first:
            self.buffer |= code << self.count
            self.count += width
            while self.count >= 8:
                self.out.append(self.buffer & 0xFF)
                self.buffer >>= 8
                self.count -= 8
        else:
            self.buffer = (self.buffer << width) | code
            self.count += width
            while self.count >= 8:
                self.out.append((self.buffer >> (self.count - 8)) & 0xFF)
                self.count -= 8
            self.buffer &= (1 << self.count) - 1

    def finish(self):
        if self.count:
            if self.lowest_first:
                self.out.append(self.buffer & 0xFF)
            else:
                self.out.append((self.buffer << (8 - self.count)) & 0xFF)
        return bytes(self.out)


def lzw(data, old_style=False):
    """TIFF LZW; old style packs codes from the lowest bit and grows the
    width one code later (the decoder is one code behind the encoder)."""
    writer = BitWriter(old_style)
    late = 1 if old_style else 0
    state = {"width": 9, "next": 258, "table": {}}

    def put(code):
        writer.put(code, state["width"])

    def count_entry():
        state["next"] += 1
        if state["next"] == 4094:
            put(256)
            state["table"] = {}
            state["next"] = 258
            state["width"] = 9
        elif state["next"] >= (1 << state["width"]) + late:
            state["width"] += 1

    put(256)
    if data:
        prefix = data[0]
        for value in data[1:]:
            key = (prefix, value)
            if key in state["table"]:
                prefix = state["table"][key]
                continue
            put(prefix)
            state["table"][key] = state["next"]
            count_entry()
            prefix = value
        put(prefix)
        count_entry()
    put(257)
    return writer.finish()


def compress(data, method):
    if method == "none":
        return bytes(data)
    if method == "packbits":
        return packbits(data)
    if method == "lzw":
        return lzw(data)
    if method == "lzw-old":
        return lzw(data, old_style=True)
    if method == "deflate":
        return zlib.compress(bytes(data), 6)
    raise ValueError(method)


COMPRESSION_NUMBERS = {"none": 1, "packbits": 32773, "lzw": 5, "lzw-old": 5, "deflate": 8}


# --- Samples ---------------------------------------------------------------

def pack_row(values, bits, big_endian):
    """One line of sample values packed as TIFF stores them."""
    if bits == 8:
        return bytes(values)
    if bits == 16:
        return b"".join(struct.pack(">H" if big_endian else "<H", value) for value in values)
    out = bytearray()
    accumulator = 0
    filled = 0
    for value in values:
        accumulator = (accumulator << bits) | value
        filled += bits
        while filled >= 8:
            out.append((accumulator >> (filled - 8)) & 0xFF)
            filled -= 8
    if filled:
        out.append((accumulator << (8 - filled)) & 0xFF)
    return bytes(out)


def difference_row(values, samples_per_pixel, bits):
    modulus = 1 << bits
    result = list(values)
    for index in range(len(values) - 1, samples_per_pixel - 1, -1):
        result[index] = (values[index] - values[index - samples_per_pixel]) % modulus
    return result


def make_chunks(planes, samples_per_pixel, width, height, bits, big_endian, layout, method, predictor=False):
    """Compressed chunks of one or more planes. planes is a list of
    planes, each a list of lines of values (width x the plane's samples
    a pixel); layout is ("strips", rows) or ("tiles", width, height)."""
    chunks = []
    plane_samples = samples_per_pixel if len(planes) == 1 else 1
    for plane in planes:
        if layout[0] == "strips":
            rows_per_strip = layout[1]
            for top in range(0, height, rows_per_strip):
                data = bytearray()
                for row in plane[top:top + rows_per_strip]:
                    if predictor:
                        row = difference_row(row, plane_samples, bits)
                    data += pack_row(row, bits, big_endian)
                chunks.append(compress(data, method))
        else:
            tile_width, tile_height = layout[1], layout[2]
            for top in range(0, height, tile_height):
                for left in range(0, width, tile_width):
                    data = bytearray()
                    for y in range(top, top + tile_height):
                        source = plane[min(y, height - 1)]
                        row = []
                        for x in range(left, left + tile_width):
                            column = min(x, width - 1)
                            row += source[column * plane_samples:(column + 1) * plane_samples]
                        if predictor:
                            row = difference_row(row, plane_samples, bits)
                        data += pack_row(row, bits, big_endian)
                    chunks.append(compress(data, method))
    return chunks


def base_entries(width, height, bits, samples_per_pixel, photometric, method, rows=None, extra=None,
                 planar=1, predictor=False, tiles=None):
    entries = {
        256: (LONG, [width]),
        257: (LONG, [height]),
        258: (SHORT, [bits] * samples_per_pixel),
        259: (SHORT, [COMPRESSION_NUMBERS[method]]),
        262: (SHORT, [photometric]),
        277: (SHORT, [samples_per_pixel]),
        284: (SHORT, [planar]),
    }
    if rows is not None:
        entries[278] = (LONG, [rows])
    if tiles is not None:
        entries[322] = (SHORT, [tiles[0]])
        entries[323] = (SHORT, [tiles[1]])
    if extra is not None:
        entries[338] = (SHORT, extra)
    if predictor:
        entries[317] = (SHORT, [2])
    return entries


def scale(value, bits):
    maximum = (1 << bits) - 1
    return (value * 255 + maximum // 2) // maximum


def picture_samples(width, height, seed, alpha=False):
    image = fixturecommon.test_picture(width, height, seed=seed, alpha=alpha)
    return fixturecommon.rgba_pixels(image)


def lines(values, width, samples_per_pixel):
    stride = width * samples_per_pixel
    return [values[index:index + stride] for index in range(0, len(values), stride)]


# --- Files Pillow writes ---------------------------------------------------

def pillow_fixture(name, image, **options):
    image.save(path(name), "TIFF", **options)
    with Image.open(path(name)) as decoded:
        decoded.load()
        fixturecommon.write_reference(path(reference_name(name)), decoded)


def make_pillow_files():
    picture = fixturecommon.test_picture(53, 41, seed=31)
    for name, method in (("tiff-none.tif", "raw"), ("tiff-packbits.tif", "packbits"),
                         ("tiff-lzw.tif", "tiff_lzw"), ("tiff-deflate.tif", "tiff_adobe_deflate")):
        pillow_fixture(name, picture, compression=method)
    pillow_fixture("tiff-pillow-rgba.tif", fixturecommon.test_picture(45, 33, seed=32, alpha=True),
                   compression="tiff_lzw")
    pillow_fixture("tiff-pillow-grey.tif", picture.convert("L"), compression="tiff_lzw")
    pillow_fixture("tiff-pillow-palette.tif", picture.convert("P", palette=Image.Palette.ADAPTIVE, colors=200),
                   compression="tiff_lzw")
    pillow_fixture("tiff-pillow-bilevel.tif", picture.convert("1"), compression="packbits")
    pillow_fixture("tiff-jpeg-rgb.tif", fixturecommon.smooth_picture(64, 48), compression="jpeg")
    pillow_fixture("tiff-jpeg-ycbcr.tif", fixturecommon.smooth_picture(61, 47).convert("YCbCr"),
                   compression="jpeg")

    pages = [fixturecommon.test_picture(30, 20, seed=33), fixturecommon.test_picture(17, 25, seed=34, alpha=True),
             fixturecommon.test_picture(40, 8, seed=35).convert("L")]
    pages[0].save(path("tiff-pages.tif"), "TIFF", save_all=True, append_images=pages[1:], compression="tiff_lzw")
    with Image.open(path("tiff-pages.tif")) as decoded:
        for index in range(len(pages)):
            decoded.seek(index)
            decoded.load()
            fixturecommon.write_reference(path(f"tiff-pages-{index}.rgba"), decoded)

    profile = bytes((index * 29 + 7) % 256 for index in range(3000))
    with open(path("tiff-metadata.icc"), "wb") as output:
        output.write(profile)
    info = {270: "A test picture", 305: "make-tiff-fixtures", 306: "2026:11:16 12:00:00", 274: 6,
            282: 100, 283: 50, 296: 3}
    pillow_fixture("tiff-metadata.tif", fixturecommon.test_picture(20, 12, seed=36), compression="tiff_lzw",
                   tiffinfo=info, icc_profile=profile)


# --- Files put together here -----------------------------------------------

def rgb_file(name, width, height, seed, method, big_endian=False, layout=("strips", 7), predictor=False,
             bigtiff=False, fill_order=None, compare=True):
    pixels = picture_samples(width, height, seed)
    values = [channel for pixel in pixels for channel in pixel[:3]]
    chunks = make_chunks([lines(values, width, 3)], 3, width, height, 8, big_endian, layout, method, predictor)
    if fill_order == 2:
        table = bytes(int(f"{index:08b}"[::-1], 2) for index in range(256))
        chunks = [chunk.translate(table) for chunk in chunks]
    if layout[0] == "strips":
        entries = base_entries(width, height, 8, 3, 2, method, rows=layout[1], predictor=predictor)
    else:
        entries = base_entries(width, height, 8, 3, 2, method, tiles=layout[1:], predictor=predictor)
    if fill_order is not None:
        entries[266] = (SHORT, [fill_order])
    write(name, build_tiff([Page(entries, chunks, layout[0] == "tiles")], big_endian, bigtiff))
    truth = [(red, green, blue, 255) for red, green, blue, _ in pixels]
    save_truth(name, width, height, truth)
    if compare:
        compare_with_pillow(name, width, height, truth)


def sixteen_bit_files():
    width, height = 23, 17
    generator = random.Random(41)
    values = [generator.randrange(65536) for _ in range(width * height * 3)]
    values[:6] = [0, 65535, 32767, 32768, 128, 65407]
    chunks = make_chunks([lines(values, width, 3)], 3, width, height, 16, True, ("strips", 5), "none")
    entries = base_entries(width, height, 16, 3, 2, "none", rows=5)
    write("tiff-be-rgb16.tif", build_tiff([Page(entries, chunks)], big_endian=True))
    truth = []
    for index in range(width * height):
        red, green, blue = (scale(value, 16) for value in values[3 * index:3 * index + 3])
        truth.append((red, green, blue, 255))
    save_truth("tiff-be-rgb16.tif", width, height, truth)

    grey = [generator.randrange(65536) if (index % 7) else (index * 977) % 65536 for index in range(width * height)]
    chunks = make_chunks([lines(grey, width, 1)], 1, width, height, 16, False, ("strips", 4), "deflate",
                         predictor=True)
    entries = base_entries(width, height, 16, 1, 1, "deflate", rows=4, predictor=True)
    write("tiff-grey16-predictor.tif", build_tiff([Page(entries, chunks)]))
    save_truth("tiff-grey16-predictor.tif", width, height,
               [(scale(value, 16),) * 3 + (255,) for value in grey])


def low_bit_files():
    width, height = 29, 13
    for bits, photometric, name, method in ((1, 0, "tiff-bilevel-white.tif", "packbits"),
                                            (2, 1, "tiff-grey2.tif", "none"),
                                            (4, 1, "tiff-grey4.tif", "lzw"),
                                            (4, 0, "tiff-grey4-white-be.tif", "deflate")):
        maximum = (1 << bits) - 1
        values = [(x * 3 + y * 5 + (x * y) % 7) % (maximum + 1) for y in range(height) for x in range(width)]
        big_endian = name.endswith("-be.tif")
        chunks = make_chunks([lines(values, width, 1)], 1, width, height, bits, big_endian, ("strips", 4), method)
        entries = base_entries(width, height, bits, 1, photometric, method, rows=4)
        write(name, build_tiff([Page(entries, chunks)], big_endian))
        truth = []
        for value in values:
            grey = scale(value, bits)
            if photometric == 0:
                grey = 255 - grey
            truth.append((grey, grey, grey, 255))
        save_truth(name, width, height, truth)
        compare_with_pillow(name, width, height, truth)


def palette_file():
    width, height = 27, 19
    colors = [((index * 70) % 256, (index * 150 + 30) % 256, (index * 33 + 200) % 256) for index in range(16)]
    color_map = [red * 257 for red, _, _ in colors] + [green * 257 for _, green, _ in colors] + \
        [blue * 257 for _, _, blue in colors]
    values = [(x + 2 * y + (x * y) % 3) % 16 for y in range(height) for x in range(width)]
    chunks = make_chunks([lines(values, width, 1)], 1, width, height, 4, True, ("strips", 6), "lzw")
    entries = base_entries(width, height, 4, 1, 3, "lzw", rows=6)
    entries[320] = (SHORT, color_map)
    write("tiff-palette4-be.tif", build_tiff([Page(entries, chunks)], big_endian=True))
    truth = [colors[value] + (255,) for value in values]
    save_truth("tiff-palette4-be.tif", width, height, truth)
    compare_with_pillow("tiff-palette4-be.tif", width, height, truth)


def alpha_files():
    width, height = 31, 21
    pixels = picture_samples(width, height, 51, alpha=True)
    # Unassociated alpha in separate planes, LZW, big-endian.
    planes = [lines([pixel[channel] for pixel in pixels], width, 1) for channel in range(4)]
    chunks = make_chunks(planes, 4, width, height, 8, True, ("strips", 8), "lzw", predictor=True)
    entries = base_entries(width, height, 8, 4, 2, "lzw", rows=8, extra=[2], planar=2, predictor=True)
    write("tiff-planar-rgba-be.tif", build_tiff([Page(entries, chunks)], big_endian=True))
    save_truth("tiff-planar-rgba-be.tif", width, height, pixels)
    compare_with_pillow("tiff-planar-rgba-be.tif", width, height, pixels)

    # Associated (premultiplied) alpha, chunky.
    stored = []
    truth = []
    for red, green, blue, alpha in pixels:
        premultiplied = [(channel * alpha + 127) // 255 for channel in (red, green, blue)]
        stored += premultiplied + [alpha]
        if alpha in (0, 255):
            truth.append(tuple(premultiplied) + (alpha,))
        else:
            truth.append(tuple(min(255, (255 * channel) // alpha) for channel in premultiplied) + (alpha,))
    chunks = make_chunks([lines(stored, width, 4)], 4, width, height, 8, False, ("strips", 5), "deflate")
    entries = base_entries(width, height, 8, 4, 2, "deflate", rows=5, extra=[1])
    write("tiff-associated.tif", build_tiff([Page(entries, chunks)]))
    save_truth("tiff-associated.tif", width, height, truth)
    compare_with_pillow("tiff-associated.tif", width, height, truth)

    # Grey with unassociated alpha.
    grey = [((x * 9 + y * 4) % 256, (x * 31 + y * 17) % 256) for y in range(height) for x in range(width)]
    values = [sample for pair in grey for sample in pair]
    chunks = make_chunks([lines(values, width, 2)], 2, width, height, 8, False, ("strips", 21), "packbits")
    entries = base_entries(width, height, 8, 2, 1, "packbits", rows=21, extra=[2])
    write("tiff-grey-alpha.tif", build_tiff([Page(entries, chunks)]))
    truth = [(value, value, value, alpha) for value, alpha in grey]
    save_truth("tiff-grey-alpha.tif", width, height, truth)
    compare_with_pillow("tiff-grey-alpha.tif", width, height, truth)


def cmyk_file():
    width, height = 26, 18
    values = []
    truth = []
    for y in range(height):
        for x in range(width):
            inks = ((x * 9) % 256, (y * 14) % 256, ((x + y) * 5) % 256, ((x * y) * 3) % 200)
            values += inks
            cyan, magenta, yellow, black = inks
            truth.append(tuple(((255 - ink) * (255 - black) + 127) // 255 for ink in (cyan, magenta, yellow)) +
                         (255,))
    chunks = make_chunks([lines(values, width, 4)], 4, width, height, 8, False, ("strips", 6), "lzw")
    entries = base_entries(width, height, 8, 4, 5, "lzw", rows=6)
    entries[332] = (SHORT, [1])
    write("tiff-cmyk.tif", build_tiff([Page(entries, chunks)]))
    save_truth("tiff-cmyk.tif", width, height, truth)


def float32(value):
    return struct.unpack("f", struct.pack("f", value))[0]


def libtiff_ycbcr_tables():
    """libtiff's tables for the default coefficients and reference."""
    luma_red, luma_green, luma_blue = float32(0.299), float32(0.587), float32(0.114)

    def fix(value):
        return int(float32(value) * 65536 + 0.5)

    f1 = float32(2 - 2 * luma_red)
    f2 = float32(float32(luma_red * f1) / luma_green)
    f3 = float32(2 - 2 * luma_blue)
    f4 = float32(float32(luma_blue * f3) / luma_green)
    return fix(f1), -fix(f2), fix(f3), -fix(f4)


def ycbcr_to_rgb(luma, cb, cr, tables):
    d1, d2, d3, d4 = tables
    cb -= 128
    cr -= 128

    def clamp(value):
        return max(0, min(255, value))

    red = clamp(luma + ((d1 * cr + 32768) >> 16))
    green = clamp(luma + ((d4 * cb + 32768 + d2 * cr) >> 16))
    blue = clamp(luma + ((d3 * cb + 32768) >> 16))
    return (red, green, blue, 255)


def ycbcr_file(name, width, height, horizontal, vertical, method, compare=True):
    tables = libtiff_ycbcr_tables()

    def luma(x, y):
        return (x * 7 + y * 11 + (x * y) % 13) % 256

    def chroma(block_x, block_y):
        return ((block_x * 37 + 60) % 256, (block_y * 53 + block_x * 5 + 90) % 256)

    blocks_across = (width + horizontal - 1) // horizontal
    blocks_down = (height + vertical - 1) // vertical
    rows_per_strip = 2 * vertical
    chunks = []
    for strip_top in range(0, blocks_down, rows_per_strip // vertical):
        data = bytearray()
        for block_y in range(strip_top, min(blocks_down, strip_top + rows_per_strip // vertical)):
            for block_x in range(blocks_across):
                for dy in range(vertical):
                    for dx in range(horizontal):
                        data.append(luma(min(width - 1, block_x * horizontal + dx),
                                         min(height - 1, block_y * vertical + dy)))
                data += bytes(chroma(block_x, block_y))
        chunks.append(compress(data, method))
    entries = base_entries(width, height, 8, 3, 6, method, rows=rows_per_strip)
    entries[530] = (SHORT, [horizontal, vertical])
    write(name, build_tiff([Page(entries, chunks)]))
    truth = []
    for y in range(height):
        for x in range(width):
            cb, cr = chroma(x // horizontal, y // vertical)
            truth.append(ycbcr_to_rgb(luma(x, y), cb, cr, tables))
    save_truth(name, width, height, truth)
    if compare:
        compare_with_pillow(name, width, height, truth)


def split_jpeg(data):
    """A JPEG stream's tables (DQT, DHT) and the rest without APPn."""
    tables = bytearray()
    rest = bytearray(b"\xff\xd8")
    position = 2
    while position < len(data):
        marker = data[position + 1]
        if marker == 0xDA:
            rest += data[position:]
            break
        length = struct.unpack(">H", data[position + 2:position + 4])[0]
        segment = data[position:position + 2 + length]
        if marker in (0xDB, 0xC4):
            tables += segment
        elif not 0xE0 <= marker <= 0xEF:
            rest += segment
        position += 2 + length
    return bytes(tables), bytes(rest)


def jpeg_tiff(name, width, height, layout):
    """JPEG chunks with their tables in JPEGTables, YCbCr 4:2:0."""
    source = Image.blend(fixturecommon.smooth_picture(width, height),
                         fixturecommon.test_picture(width, height, seed=61), 0.3)
    canvas = Image.new("RGBA", (width, height))
    chunks = []
    tables = None
    if layout[0] == "strips":
        boxes = [(0, top, width, min(height, top + layout[1])) for top in range(0, height, layout[1])]
    else:
        boxes = [(left, top, left + layout[1], top + layout[2])
                 for top in range(0, height, layout[2]) for left in range(0, width, layout[1])]
    for box in boxes:
        piece = Image.new("RGB", (box[2] - box[0], box[3] - box[1]))
        piece.paste(source.crop((box[0], box[1], min(width, box[2]), min(height, box[3]))))
        stream = io.BytesIO()
        piece.save(stream, "JPEG", quality=90, subsampling=2)
        piece_tables, rest = split_jpeg(stream.getvalue())
        if tables is None:
            tables = piece_tables
        assert tables == piece_tables
        chunks.append(rest)
        with Image.open(io.BytesIO(stream.getvalue())) as decoded:
            decoded.load()
            canvas.paste(decoded.convert("RGBA"), (box[0], box[1]))
    if layout[0] == "strips":
        entries = base_entries(width, height, 8, 3, 6, "none", rows=layout[1])
    else:
        entries = base_entries(width, height, 8, 3, 6, "none", tiles=layout[1:])
    entries[259] = (SHORT, [7])
    entries[530] = (SHORT, [2, 2])
    entries[347] = (UNDEFINED, b"\xff\xd8" + tables + b"\xff\xd9")
    write(name, build_tiff([Page(entries, chunks, layout[0] == "tiles")]))
    fixturecommon.write_reference(path(reference_name(name)), canvas)


def malformed_files():
    with open(path("tiff-lzw.tif"), "rb") as source:
        good = source.read()
    write("bad-tiff-truncated.tif", good[:len(good) // 2])
    write("bad-tiff-header-only.tif", good[:8])

    width, height = 12, 8
    values = [index % 256 for index in range(width * height * 3)]

    def single(entries_changes, chunk=None):
        chunks = make_chunks([lines(values, width, 3)], 3, width, height, 8, False, ("strips", 8), "none")
        entries = base_entries(width, height, 8, 3, 2, "none", rows=8)
        entries.update(entries_changes)
        return build_tiff([Page(entries, chunks if chunk is None else chunk)])

    write("bad-tiff-huge.tif", single({256: (LONG, [100000]), 257: (LONG, [100000])}))
    write("bad-tiff-compression.tif", single({259: (SHORT, [34676])}))
    write("bad-tiff-ccitt.tif", single({259: (SHORT, [4])}))
    write("bad-tiff-photometric.tif", single({262: (SHORT, [8])}))
    data = bytearray(single({}))
    # The strip offset pointed past the end of the file.
    directory = struct.unpack_from("<I", data, 4)[0]
    count = struct.unpack_from("<H", data, directory)[0]
    for index in range(count):
        entry = directory + 2 + 12 * index
        if struct.unpack_from("<H", data, entry)[0] == 273:
            struct.pack_into("<I", data, entry + 8, len(data) + 100)
    write("bad-tiff-strip-offset.tif", bytes(data))
    # The directory's link points back at itself: one page, read once.
    data = bytearray(single({}))
    directory = struct.unpack_from("<I", data, 4)[0]
    count = struct.unpack_from("<H", data, directory)[0]
    struct.pack_into("<I", data, directory + 2 + 12 * count, directory)
    write("tiff-loop.tif", bytes(data))
    save_truth("tiff-loop.tif", width, height,
               [tuple(values[3 * index:3 * index + 3]) + (255,) for index in range(width * height)])


# --- Fax compression, floating point samples, old-style JPEG -----------------

def entry_value(data, tag):
    """Where a little-endian TIFF's first directory has tag, and its
    first value."""
    directory = struct.unpack_from("<I", data, 4)[0]
    count = struct.unpack_from("<H", data, directory)[0]
    for index in range(count):
        entry = directory + 2 + 12 * index
        if struct.unpack_from("<H", data, entry)[0] == tag:
            field_type = struct.unpack_from("<H", data, entry + 2)[0]
            return entry, struct.unpack_from("<H" if field_type == SHORT else "<I", data, entry + 8)[0]
    raise KeyError(tag)


def strip_data(name):
    """The strips of a Pillow-written TIFF, joined, and its tags."""
    with Image.open(path(name)) as image:
        tags = dict(image.tag_v2)
    with open(path(name), "rb") as source:
        data = source.read()
    return b"".join(data[offset:offset + count] for offset, count in zip(tags[273], tags[279])), tags


def fax_files():
    picture = fixturecommon.test_picture(123, 45, seed=81).convert("1")
    for name, options in (("tiff-g4.tif", dict(compression="group4")),
                          ("tiff-g3.tif", dict(compression="group3")),
                          ("tiff-g3-2d.tif", dict(compression="group3", tiffinfo={292: 1})),
                          ("tiff-g3-fill.tif", dict(compression="group3", tiffinfo={292: 5})),
                          ("tiff-ccitt-rle.tif", dict(compression="tiff_ccitt")),
                          ("tiff-g4-strips.tif", dict(compression="group4", tiffinfo={278: 8})),
                          ("tiff-g4-fill-order.tif", dict(compression="group4", tiffinfo={266: 2})),
                          ("tiff-g3-2d-fill-order.tif", dict(compression="group3", tiffinfo={266: 2, 292: 1}))):
        pillow_fixture(name, picture, **options)
    fax = Image.new("1", (1728, 30), 1)
    pixels = fax.load()
    generator = random.Random(82)
    for y in range(30):
        for x in range(1728):
            if (x // 40 + y // 6) % 3 == 0 or generator.random() < 0.02:
                pixels[x, y] = 0
    pillow_fixture("tiff-g3-2d-fax-width.tif", fax, compression="group3", tiffinfo={292: 1})
    # The Group 4 data again, white is zero: the same bits, seen inverted.
    data, tags = strip_data("tiff-g4.tif")
    assert len(tags[273]) == 1, "the Group 4 fixture is one strip"
    entries = {256: (LONG, [123]), 257: (LONG, [45]), 258: (SHORT, [1]), 259: (SHORT, [4]), 262: (SHORT, [0]),
               277: (SHORT, [1]), 278: (LONG, [45]), 293: (LONG, [0])}
    write("tiff-g4-white-is-zero.tif", build_tiff([Page(entries, [data])]))
    with Image.open(path("tiff-g4.tif")) as decoded:
        inverted = Image.eval(decoded.convert("L"), lambda value: 255 - value)
    fixturecommon.write_reference(path(reference_name("tiff-g4-white-is-zero.tif")), inverted)


def float_bytes(value, bits, big_endian):
    return struct.pack((">" if big_endian else "<") + ("e" if bits == 16 else "f"), value)


def float_predictor(row_bytes, samples_per_pixel, bits):
    """The floating point predictor on one line (bytes of big-endian
    samples): the bytes regrouped, most significant first, then
    differences one pixel apart."""
    size = bits // 8
    count = len(row_bytes) // size
    grouped = bytearray(len(row_bytes))
    for sample in range(count):
        for byte in range(size):
            grouped[byte * count + sample] = row_bytes[sample * size + byte]
    for index in range(len(grouped) - 1, samples_per_pixel - 1, -1):
        grouped[index] = (grouped[index] - grouped[index - samples_per_pixel]) & 0xFF
    return bytes(grouped)


def float_value_for(level, scale=1.0):
    """A sample that tone maps to level (0 to 255), well away from a
    rounding boundary; below 0 and above 255 give values clamped to 0
    and 1."""
    if level < 0:
        return -0.25 * scale
    if level >= 255:
        return 1.0 * scale
    return (level + 0.3) / 255 * scale


def float_file(name, width, height, samples_per_pixel, bits, big_endian, method, predictor, scale=1.0,
               specials=False):
    generator = random.Random(len(name))
    levels = []
    values = []
    for y in range(height):
        for x in range(width):
            for sample in range(samples_per_pixel):
                if (x + y) % 7:
                    level = (x * 9 + y * 5 + sample * 80) % 270 - 5
                else:
                    level = generator.randrange(256)
                value = float_value_for(level, scale)
                if specials and (x, y, sample) == (1, 1, 0):
                    value = float("nan")
                    level = 0
                elif specials and (x, y, sample) == (2, 1, 0):
                    value = float("inf")
                    level = 255
                levels.append(max(0, min(255, level)))
                values.append(value)
    rows = []
    stride = width * samples_per_pixel
    for y in range(height):
        row_values = values[y * stride:(y + 1) * stride]
        if predictor:
            row = float_predictor(b"".join(float_bytes(v, bits, True) for v in row_values), samples_per_pixel, bits)
        else:
            row = b"".join(float_bytes(v, bits, big_endian) for v in row_values)
        rows.append(row)
    chunk = compress(b"".join(rows), method)
    photometric = 2 if samples_per_pixel >= 3 else 1
    entries = base_entries(width, height, bits, samples_per_pixel, photometric, method, rows=height)
    entries[339] = (SHORT, [3] * samples_per_pixel)
    if predictor:
        entries[317] = (SHORT, [3])
    write(name, build_tiff([Page(entries, [chunk])], big_endian=big_endian))
    truth = []
    for index in range(width * height):
        pixel = levels[index * samples_per_pixel:(index + 1) * samples_per_pixel]
        if samples_per_pixel >= 3:
            truth.append((pixel[0], pixel[1], pixel[2], 255))
        else:
            truth.append((pixel[0], pixel[0], pixel[0], 255))
    save_truth(name, width, height, truth)


def pillow_float_files():
    """32-bit float grey through libtiff, with the floating point predictor."""
    width, height = 47, 21
    image = Image.new("F", (width, height))
    truth = []
    for y in range(height):
        for x in range(width):
            level = (x * 11 + y * 7) % 262 - 3
            image.putpixel((x, y), float_value_for(level))
            level = max(0, min(255, level))
            truth.append((level, level, level, 255))
    for name, method in (("tiff-float-predictor-deflate.tif", "tiff_adobe_deflate"),
                         ("tiff-float-predictor-lzw.tif", "tiff_lzw")):
        image.save(path(name), "TIFF", compression=method, tiffinfo={317: 3})
        save_truth(name, width, height, truth)


def old_jpeg_files():
    width, height = 40, 40
    source = fixturecommon.smooth_picture(width, height)
    stream = io.BytesIO()
    source.save(stream, "JPEG", quality=90, subsampling=2)
    jpeg = stream.getvalue()
    entries = base_entries(width, height, 8, 3, 6, "none", rows=height)
    entries[259] = (SHORT, [6])
    entries[513] = (LONG, [0])
    entries[514] = (LONG, [len(jpeg)])
    data = bytearray(build_tiff([Page(entries, [jpeg])]))
    _, strip_offset = entry_value(data, 273)
    entry, _ = entry_value(data, 513)
    struct.pack_into("<I", data, entry + 8, strip_offset)
    write("tiff-old-jpeg.tif", bytes(data))
    with Image.open(io.BytesIO(jpeg)) as decoded:
        fixturecommon.write_reference(path(reference_name("tiff-old-jpeg.tif")), decoded)

    canvas = Image.new("RGBA", (width, height))
    chunks = []
    for top in range(0, height, 16):
        piece = source.crop((0, top, width, min(height, top + 16)))
        stream = io.BytesIO()
        piece.save(stream, "JPEG", quality=90, subsampling=2)
        chunks.append(stream.getvalue())
        with Image.open(io.BytesIO(stream.getvalue())) as decoded:
            canvas.paste(decoded.convert("RGBA"), (0, top))
    entries = base_entries(width, height, 8, 3, 6, "none", rows=16)
    entries[259] = (SHORT, [6])
    write("tiff-old-jpeg-strips.tif", build_tiff([Page(entries, chunks)]))
    fixturecommon.write_reference(path(reference_name("tiff-old-jpeg-strips.tif")), canvas)

    entries = base_entries(width, height, 8, 3, 6, "none", rows=height)
    entries[259] = (SHORT, [6])
    write("bad-tiff-old-jpeg.tif", build_tiff([Page(entries, [bytes(range(7, 250)) * 4])]))


def main():
    make_pillow_files()
    rgb_file("tiff-be-lzw-predictor.tif", 37, 23, 71, "lzw", big_endian=True, predictor=True)
    rgb_file("tiff-be-packbits.tif", 33, 15, 72, "packbits", big_endian=True)
    rgb_file("tiff-tiles.tif", 50, 37, 73, "deflate", layout=("tiles", 16, 16))
    rgb_file("tiff-tiles-be-lzw.tif", 40, 33, 74, "lzw", big_endian=True, layout=("tiles", 32, 16), predictor=True)
    rgb_file("tiff-old-lzw.tif", 41, 19, 75, "lzw-old")
    rgb_file("tiff-long-lzw.tif", 160, 120, 76, "lzw", layout=("strips", 120))
    rgb_file("tiff-fill-order.tif", 21, 11, 77, "packbits", fill_order=2)
    rgb_file("tiff-bigtiff.tif", 24, 18, 78, "deflate", bigtiff=True)
    # Pillow reads only little-endian BigTIFF (libtiff's tiffinfo reads this one).
    rgb_file("tiff-bigtiff-be.tif", 19, 13, 79, "none", big_endian=True, bigtiff=True, compare=False)
    sixteen_bit_files()
    low_bit_files()
    palette_file()
    alpha_files()
    cmyk_file()
    # Pillow reads uncompressed YCbCr as if it were not subsampled.
    ycbcr_file("tiff-ycbcr22.tif", 37, 29, 2, 2, "none", compare=False)
    ycbcr_file("tiff-ycbcr21-lzw.tif", 30, 20, 2, 1, "lzw")
    jpeg_tiff("tiff-jpeg-strips.tif", 61, 45, ("strips", 16))
    jpeg_tiff("tiff-jpeg-tiles.tif", 50, 40, ("tiles", 32, 32))
    fax_files()
    pillow_float_files()
    float_file("tiff-float-rgb-be-predictor.tif", 29, 17, 3, 32, True, "deflate", True)
    float_file("tiff-float-rgb-le-predictor.tif", 23, 13, 3, 32, False, "lzw", True)
    float_file("tiff-half-grey.tif", 31, 9, 1, 16, False, "none", False)
    float_file("tiff-half-grey-be-predictor.tif", 27, 11, 1, 16, True, "deflate", True)
    float_file("tiff-float-hdr.tif", 25, 10, 1, 32, False, "none", False, scale=4.0, specials=True)
    old_jpeg_files()
    malformed_files()
    for warning in WARNINGS:
        print("warning:", warning)


if __name__ == "__main__":
    main()
