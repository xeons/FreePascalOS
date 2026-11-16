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

"""The PNG and APNG fixtures of ImageTest.

    make-png-fixtures.py OUTPUT_DIRECTORY

PNG files are put together chunk by chunk here (with Python's zlib), in
the manner of PngSuite: every colour type at every depth, plain and
interlaced, every filter, tRNS of each kind, tiny interlaced pictures
whose passes are partly empty, image data cut into one-byte and empty
chunks, every ancillary chunk the decoder reads, and broken files of
every kind. The reference (name.rgba, see fixturecommon.py) is worked
out here from the samples the file was made of: depths under 8
multiplied out, 16-bit samples rounded to the nearest 8-bit value
((V x 255 + 32767) // 65535, where Pillow takes the high byte), the
tRNS colour fully transparent. Where Pillow reads a file the same way
(no 16-bit samples, no tRNS key) its decoding must equal the
reference, or the script stops.

APNGs are made the same way, with every dispose and blend op, frames
at offsets, delays as fractions and a default image that is or is not
the first frame. Each frame as seen is worked out by a small compositor
here (name-frameN.rgba) and must equal Pillow's for frames whose pixels
are opaque or fully transparent; one APNG blends translucent pixels,
which Pillow pastes rather than composites, so it has only this
script's reference.

Files Pillow writes (RGB, palette, grey, grey and alpha, bilevel) are
included with Pillow's decoding as their reference.
"""

import os
import random
import struct
import sys
import zlib

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from PIL import Image  # noqa: E402

import fixturecommon  # noqa: E402

OUTPUT = sys.argv[1] if len(sys.argv) > 1 else "build/tools/image-fixtures"
WARNINGS = []

GREY, RGB, PALETTE, GREY_ALPHA, RGB_ALPHA = 0, 2, 3, 4, 6
CHANNELS = {GREY: 1, RGB: 3, PALETTE: 1, GREY_ALPHA: 2, RGB_ALPHA: 4}
ADAM7 = ((0, 0, 8, 8), (4, 0, 8, 8), (0, 4, 4, 8), (2, 0, 4, 4), (0, 2, 2, 4), (1, 0, 2, 2), (0, 1, 1, 2))
SIGNATURE = b"\x89PNG\r\n\x1a\n"


def path(name):
    return fixturecommon.output_path(OUTPUT, name)


def write(name, data):
    with open(path(name), "wb") as output:
        output.write(data)


def reference_name(name):
    return os.path.splitext(name)[0] + ".rgba"


# --- Putting files together -------------------------------------------------

def chunk(kind, data):
    return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)


def header(width, height, depth, color_type, interlaced=False):
    return chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, depth, color_type, 0, 0, 1 if interlaced else 0))


def pack_row(samples, depth):
    """A line's samples (a flat list) as bytes."""
    if depth == 16:
        return b"".join(struct.pack(">H", value) for value in samples)
    if depth == 8:
        return bytes(samples)
    output = bytearray((len(samples) * depth + 7) // 8)
    for index, value in enumerate(samples):
        position = index * depth
        output[position // 8] |= value << (8 - depth - position % 8)
    return bytes(output)


def paeth(left, above, upper_left):
    estimate = left + above - upper_left
    distance_left = abs(estimate - left)
    distance_above = abs(estimate - above)
    distance_upper_left = abs(estimate - upper_left)
    if distance_left <= distance_above and distance_left <= distance_upper_left:
        return left
    if distance_above <= distance_upper_left:
        return above
    return upper_left


def filter_row(kind, row, previous, stride):
    output = bytearray(len(row))
    for index in range(len(row)):
        left = row[index - stride] if index >= stride else 0
        above = previous[index]
        upper_left = previous[index - stride] if index >= stride else 0
        prediction = (0, left, above, (left + above) // 2, paeth(left, above, upper_left))[kind]
        output[index] = (row[index] - prediction) & 0xFF
    return bytes([kind]) + bytes(output)


def filtered_data(rows, depth, channels, filters):
    """Lines (each packed bytes) filtered; filters(line_number) names each line's filter."""
    stride = max(1, depth * channels // 8)
    output = bytearray()
    previous = bytes(len(rows[0])) if rows else b""
    for number, row in enumerate(rows):
        output += filter_row(filters(number), row, previous, stride)
        previous = row
    return bytes(output)


def image_data(pixels, width, height, depth, color_type, interlaced, filters):
    """pixels[y][x] is a tuple of samples; the raw (uncompressed) image data."""
    channels = CHANNELS[color_type]
    if not interlaced:
        rows = [pack_row([sample for pixel in pixels[y] for sample in pixel], depth) for y in range(height)]
        return filtered_data(rows, depth, channels, filters)
    output = bytearray()
    for first_x, first_y, step_x, step_y in ADAM7:
        columns = range(first_x, width, step_x)
        lines = range(first_y, height, step_y)
        if not columns or not lines:
            continue
        rows = [pack_row([sample for x in columns for sample in pixels[y][x]], depth) for y in lines]
        output += filtered_data(rows, depth, channels, filters)
    return bytes(output)


def cycle_filters(number):
    return number % 5


def png_file(width, height, depth, color_type, pixels, interlaced=False, filters=cycle_filters, palette=None,
             transparency=None, before=b"", after=b"", idat_size=None, level=9, data_override=None):
    raw = image_data(pixels, width, height, depth, color_type, interlaced, filters)
    compressed = data_override if data_override is not None else zlib.compress(raw, level)
    data = SIGNATURE + header(width, height, depth, color_type, interlaced) + before
    if palette is not None:
        data += chunk(b"PLTE", b"".join(bytes(color) for color in palette))
    if transparency is not None:
        data += chunk(b"tRNS", transparency)
    if idat_size is None:
        data += chunk(b"IDAT", compressed)
    else:
        for start in range(0, len(compressed), idat_size):
            data += chunk(b"IDAT", compressed[start:start + idat_size])
    return data + after + chunk(b"IEND", b"")


# --- Samples and what they look like -----------------------------------------

def sample_pixels(width, height, depth, color_type, seed):
    """Samples covering the whole range of the depth: gradients, edges and noise."""
    generator = random.Random(seed)
    maximum = (1 << depth) - 1
    channels = CHANNELS[color_type]
    pixels = []
    for y in range(height):
        line = []
        for x in range(width):
            pixel = []
            for channel in range(channels):
                if (x + y + channel) % 7 == 0:
                    value = generator.randint(0, maximum)
                else:
                    value = ((x * (channel + 1) + y * 3) * maximum) // max(1, width + 3 * height)
                pixel.append(min(maximum, value))
            line.append(tuple(pixel))
        pixels.append(line)
    return pixels


def to_8(value, depth):
    if depth == 16:
        return (value * 255 + 32767) // 65535
    if depth == 8:
        return value
    return value * (255 // ((1 << depth) - 1))


def truth(pixels, depth, color_type, palette=None, transparency=None):
    """The pixels as (red, green, blue, alpha) tuples, line after line."""
    key = None
    alphas = []
    if transparency is not None:
        if color_type == GREY:
            key = (struct.unpack(">H", transparency[:2])[0],)
        elif color_type == RGB:
            key = struct.unpack(">HHH", transparency[:6])
        elif color_type == PALETTE:
            alphas = list(transparency)
    result = []
    for line in pixels:
        for pixel in line:
            if color_type == PALETTE:
                red, green, blue = palette[pixel[0]]
                alpha = alphas[pixel[0]] if pixel[0] < len(alphas) else 255
                result.append((red, green, blue, alpha))
                continue
            values = [to_8(sample, depth) for sample in pixel]
            if color_type == GREY:
                alpha = 0 if key is not None and tuple(pixel) == key else 255
                result.append((values[0], values[0], values[0], alpha))
            elif color_type == RGB:
                alpha = 0 if key is not None and tuple(pixel) == key else 255
                result.append((values[0], values[1], values[2], alpha))
            elif color_type == GREY_ALPHA:
                result.append((values[0], values[0], values[0], values[1]))
            else:
                result.append(tuple(values))
    return result


def make_palette(count, seed):
    generator = random.Random(seed)
    return [(generator.randrange(256), generator.randrange(256), generator.randrange(256)) for _ in range(count)]


def pillow_rgba(name):
    with Image.open(path(name)) as image:
        image.load()
        return fixturecommon.rgba_pixels(image), image.size


def save_png(name, width, height, data, expected, compare_with_pillow):
    write(name, data)
    fixturecommon.write_reference_pixels(path(reference_name(name)), width, height, expected)
    if not compare_with_pillow:
        return
    pixels, size = pillow_rgba(name)
    if size != (width, height) or pixels != list(expected):
        raise SystemExit(f"{name}: Pillow reads it differently from its reference")


def check_with_pillow_softly(name, width, height, expected):
    try:
        pixels, size = pillow_rgba(name)
    except Exception as error:
        WARNINGS.append(f"{name}: Pillow cannot read it ({error})")
        return
    if size != (width, height) or pixels != list(expected):
        WARNINGS.append(f"{name}: Pillow reads it differently (expected where Pillow reduces samples its own way)")


# --- Every colour type and depth --------------------------------------------

COMBINATIONS = ((GREY, (1, 2, 4, 8, 16)), (RGB, (8, 16)), (PALETTE, (1, 2, 4, 8)), (GREY_ALPHA, (8, 16)),
                (RGB_ALPHA, (8, 16)))


def make_matrix():
    width, height = 37, 23
    for color_type, depths in COMBINATIONS:
        for depth in depths:
            for interlaced in (False, True):
                name = f"png-c{color_type}-d{depth}{'-i' if interlaced else ''}.png"
                palette = None
                if color_type == PALETTE:
                    palette = make_palette(1 << depth, depth)
                pixels = sample_pixels(width, height, depth, color_type, color_type * 100 + depth)
                data = png_file(width, height, depth, color_type, pixels, interlaced, palette=palette)
                expected = truth(pixels, depth, color_type, palette)
                save_png(name, width, height, data, expected, depth != 16)


def make_transparency():
    width, height = 19, 13
    cases = (
        ("png-trns-grey1.png", GREY, 1, struct.pack(">H", 1)),
        ("png-trns-grey4.png", GREY, 4, struct.pack(">H", 7)),
        ("png-trns-grey8.png", GREY, 8, None),
        ("png-trns-grey16.png", GREY, 16, None),
        ("png-trns-rgb8.png", RGB, 8, None),
        ("png-trns-rgb16.png", RGB, 16, None),
        ("png-trns-palette4.png", PALETTE, 4, bytes((0, 64, 128, 255, 10))),
        ("png-trns-palette8.png", PALETTE, 8, bytes(range(0, 250, 3))),
    )
    for name, color_type, depth, transparency in cases:
        pixels = sample_pixels(width, height, depth, color_type, len(name))
        if transparency is None:
            # The key is a colour the picture has, so some pixels go.
            key = pixels[3][5]
            transparency = struct.pack(">" + "H" * len(key), *key)
        palette = make_palette(1 << depth, depth + 7) if color_type == PALETTE else None
        data = png_file(width, height, depth, color_type, pixels, interlaced=(depth == 8), palette=palette,
                        transparency=transparency)
        expected = truth(pixels, depth, color_type, palette, transparency)
        save_png(name, width, height, data, expected, False)
        if depth != 16:
            check_with_pillow_softly(name, width, height, expected)


def make_sizes():
    """Tiny interlaced pictures: some passes have no columns or no lines."""
    for width, height in ((1, 1), (2, 2), (3, 3), (4, 4), (5, 5), (7, 1), (1, 9), (8, 8), (9, 9), (33, 2)):
        for color_type, depth in ((RGB_ALPHA, 8), (PALETTE, 1), (GREY, 2)):
            name = f"png-size-{width}x{height}-c{color_type}.png"
            palette = make_palette(1 << depth, 3) if color_type == PALETTE else None
            pixels = sample_pixels(width, height, depth, color_type, width * 31 + height)
            data = png_file(width, height, depth, color_type, pixels, interlaced=True, palette=palette)
            save_png(name, width, height, data, truth(pixels, depth, color_type, palette), True)


def make_filters_and_chunking():
    width, height = 41, 17
    pixels = sample_pixels(width, height, 8, RGB, 77)
    expected = truth(pixels, 8, RGB)
    for kind in range(5):
        data = png_file(width, height, 8, RGB, pixels, filters=lambda number, kind=kind: kind)
        save_png(f"png-filter-{kind}.png", width, height, data, expected, True)
    save_png("png-idat-bytes.png", width, height, png_file(width, height, 8, RGB, pixels, idat_size=1), expected, True)
    raw = image_data(pixels, width, height, 8, RGB, False, cycle_filters)
    compressed = zlib.compress(raw, 9)
    data = SIGNATURE + header(width, height, 8, RGB) + chunk(b"IDAT", b"")
    for start in range(0, len(compressed), 100):
        data += chunk(b"IDAT", compressed[start:start + 100]) + chunk(b"IDAT", b"")
    save_png("png-idat-empty.png", width, height, data + chunk(b"IEND", b""), expected, True)
    save_png("png-stored.png", width, height, png_file(width, height, 8, RGB, pixels, level=0), expected, True)
    # No IEND: the picture is whole, so it is read.
    whole = png_file(width, height, 8, RGB, pixels)
    save_png("png-no-end.png", width, height, whole[:-12], expected, False)
    # A palette in an RGB picture is a suggestion only.
    data = png_file(width, height, 8, RGB, pixels, palette=make_palette(16, 5))
    save_png("png-rgb-palette.png", width, height, data, expected, True)
    # A palette shorter than the depth allows.
    palette = make_palette(5, 9)
    indices = [[(x + y) % 5 for x in range(width)] for y in range(height)]
    pixels = [[(value,) for value in line] for line in indices]
    data = png_file(width, height, 4, PALETTE, pixels, palette=palette)
    save_png("png-short-palette.png", width, height, data, truth(pixels, 4, PALETTE, palette), True)
    # An unknown ancillary chunk is passed over.
    pixels = sample_pixels(width, height, 8, GREY_ALPHA, 5)
    data = png_file(width, height, 8, GREY_ALPHA, pixels, before=chunk(b"prIv", b"private"), after=chunk(b"zzZz", b""))
    save_png("png-unknown-ancillary.png", width, height, data, truth(pixels, 8, GREY_ALPHA), True)


def text_chunk(keyword, text):
    return chunk(b"tEXt", keyword.encode("latin-1") + b"\0" + text.encode("latin-1"))


def make_metadata():
    width, height = 16, 12
    pixels = sample_pixels(width, height, 8, RGB, 12)
    profile = bytes((index * 13 + index // 7) % 256 for index in range(3000))
    exif = b"MM\0*" + struct.pack(">IHHHIHHI", 8, 1, 0x0112, 3, 1, 6, 0, 0)
    before = (chunk(b"gAMA", struct.pack(">I", 45455)) +
              chunk(b"cHRM", struct.pack(">8I", 31270, 32900, 64000, 33000, 30000, 60000, 15000, 6000)) +
              chunk(b"iCCP", b"test profile\0\0" + zlib.compress(profile)) +
              chunk(b"pHYs", struct.pack(">IIB", 11811, 5906, 1)) +
              chunk(b"tIME", struct.pack(">HBBBBB", 2026, 11, 16, 12, 30, 5)) +
              chunk(b"eXIf", exif) +
              text_chunk("Title", "A test picture") +
              text_chunk("Author", "Grün") +
              chunk(b"zTXt", b"Description\0\0" + zlib.compress(b"Compressed text " * 20)) +
              chunk(b"iTXt", b"Comment\0\0\0en\0Kommentar\0" + "日本語".encode("utf-8")) +
              chunk(b"iTXt", b"Software\0\1\0\0\0" + zlib.compress("café writer".encode("utf-8"))))
    after = text_chunk("Disclaimer", "after the image data")
    data = png_file(width, height, 8, RGB, pixels, before=before, after=after)
    save_png("png-metadata.png", width, height, data, truth(pixels, 8, RGB), True)
    with open(path("png-metadata.icc"), "wb") as output:
        output.write(profile)
    srgb = png_file(width, height, 8, RGB, pixels, before=chunk(b"sRGB", b"\1"))
    save_png("png-srgb.png", width, height, srgb, truth(pixels, 8, RGB), True)


def make_pillow_files():
    picture = fixturecommon.test_picture(160, 120, seed=40)
    picture.save(path("png-pillow-rgb.png"), optimize=True)
    picture.quantize(colors=200).save(path("png-pillow-palette.png"))
    picture.convert("L").save(path("png-pillow-grey.png"))
    fixturecommon.test_picture(64, 48, seed=41, alpha=True).convert("LA").save(path("png-pillow-grey-alpha.png"))
    picture.convert("1").save(path("png-pillow-bilevel.png"))
    fixturecommon.test_picture(90, 70, seed=42, alpha=True).save(path("png-pillow-rgba.png"), compress_level=1)
    for name in ("png-pillow-rgb", "png-pillow-palette", "png-pillow-grey", "png-pillow-grey-alpha", "png-pillow-bilevel", "png-pillow-rgba"):
        with Image.open(path(name + ".png")) as image:
            fixturecommon.write_reference(path(name + ".rgba"), image)
    # A large picture, for the time it takes.
    fixturecommon.smooth_picture(1600, 1200).save(path("png-pillow-large.png"))
    with Image.open(path("png-pillow-large.png")) as image:
        fixturecommon.write_reference(path("png-pillow-large.rgba"), image)


# --- Broken files ------------------------------------------------------------

def make_broken():
    width, height = 20, 10
    pixels = sample_pixels(width, height, 8, RGB, 3)
    good = png_file(width, height, 8, RGB, pixels)
    raw = image_data(pixels, width, height, 8, RGB, False, cycle_filters)
    write("bad-png-signature.png", b"\x89PNG\r\n\x1a\x0b" + good[8:])
    bad = bytearray(good)
    bad[29] ^= 1  # the IHDR CRC
    write("bad-png-header-crc.png", bytes(bad))
    bad = bytearray(good)
    bad[len(good) - 12 - 5] ^= 0x40  # inside the IDAT data: its CRC no longer matches
    write("bad-png-data-crc.png", bytes(bad))
    write("bad-png-color-type.png", SIGNATURE + header(width, height, 8, 1) + good[33:])
    write("bad-png-depth.png", SIGNATURE + header(width, height, 4, RGB) + good[33:])
    write("bad-png-interlace.png", SIGNATURE + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 2)) +
          good[33:])
    write("bad-png-compression.png", SIGNATURE + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 1, 0, 0)) +
          good[33:])
    write("bad-png-zero-width.png", SIGNATURE + header(0, height, 8, RGB) + good[33:])
    write("bad-png-huge.png", SIGNATURE + header(70000, 70000, 8, RGB) + good[33:])
    write("bad-png-no-palette.png", png_file(width, height, 8, PALETTE, [[(1,)] * width] * height))
    write("bad-png-no-data.png", SIGNATURE + header(width, height, 8, RGB) + chunk(b"IEND", b""))
    bad_raw = bytearray(raw)
    bad_raw[(3 * width + 1) * 4] = 5
    write("bad-png-filter-type.png", png_file(width, height, 8, RGB, pixels, data_override=zlib.compress(bytes(bad_raw))))
    compressed = bytearray(zlib.compress(raw))
    compressed[-1] ^= 0xFF
    write("bad-png-adler.png", png_file(width, height, 8, RGB, pixels, data_override=bytes(compressed)))
    write("bad-png-short-data.png", png_file(width, height, 8, RGB, pixels,
                                             data_override=zlib.compress(raw[:len(raw) // 2])))
    write("bad-png-garbage-data.png", png_file(width, height, 8, RGB, pixels,
                                               data_override=b"\x78\x9c" + bytes(range(7, 250, 3))))
    write("bad-png-truncated.png", good[:len(good) - 40])
    write("bad-png-critical.png", png_file(width, height, 8, RGB, pixels, before=chunk(b"CRIt", b"x")))
    write("bad-png-chunk-name.png", png_file(width, height, 8, RGB, pixels, before=chunk(b"a1b2", b"x")))


# --- APNG --------------------------------------------------------------------

class Frame:
    def __init__(self, width, height, left, top, pixels, numerator, denominator, dispose, blend):
        self.width, self.height, self.left, self.top = width, height, left, top
        self.pixels = pixels  # [y][x] (r, g, b, a)
        self.numerator, self.denominator = numerator, denominator
        self.dispose, self.blend = dispose, blend


def frame_control(sequence, frame):
    return chunk(b"fcTL", struct.pack(">IIIIIHHBB", sequence, frame.width, frame.height, frame.left, frame.top,
                                      frame.numerator, frame.denominator, frame.dispose, frame.blend))


def apng_file(width, height, default_pixels, frames, plays, default_is_frame, color_type=RGB_ALPHA, palette=None,
              transparency=None, encode=None):
    """frames[i].pixels are tuples in the file's samples (encode turns RGBA into them if given)."""
    def samples(pixels):
        return [[encode(pixel) for pixel in line] for line in pixels] if encode else pixels

    data = SIGNATURE + header(width, height, 8, color_type) + chunk(b"acTL", struct.pack(">II", len(frames), plays))
    if palette is not None:
        data += chunk(b"PLTE", b"".join(bytes(color) for color in palette))
    if transparency is not None:
        data += chunk(b"tRNS", transparency)
    sequence = 0
    remaining = frames
    if default_is_frame:
        data += frame_control(sequence, frames[0])
        sequence += 1
        remaining = frames[1:]
    raw = image_data(samples(default_pixels), width, height, 8, color_type, False, cycle_filters)
    data += chunk(b"IDAT", zlib.compress(raw))
    for frame in remaining:
        data += frame_control(sequence, frame)
        sequence += 1
        raw = image_data(samples(frame.pixels), frame.width, frame.height, 8, color_type, False, cycle_filters)
        compressed = zlib.compress(raw)
        # Two fdAT chunks a frame, to have more than one.
        half = len(compressed) // 2
        for piece in (compressed[:half], compressed[half:]):
            data += chunk(b"fdAT", struct.pack(">I", sequence) + piece)
            sequence += 1
    return data + chunk(b"IEND", b"")


def blend_over(destination, source):
    """libdrawing's BlendColors: straight alpha, rounded."""
    source_alpha = source[3]
    if source_alpha == 255:
        return source
    if source_alpha == 0:
        return destination
    destination_alpha = destination[3]
    output_alpha = source_alpha + (destination_alpha * (255 - source_alpha) + 127) // 255
    if output_alpha == 0:
        return (0, 0, 0, 0)
    channels = []
    for channel in range(3):
        weighted = source[channel] * source_alpha * 255 + destination[channel] * destination_alpha * (255 - source_alpha)
        channels.append((weighted + output_alpha * 255 // 2) // (output_alpha * 255))
    return (channels[0], channels[1], channels[2], output_alpha)


def composite(width, height, frames):
    """Every frame as seen, by APNG's rules."""
    canvas = [[(0, 0, 0, 0)] * width for _ in range(height)]
    seen = []
    for index, frame in enumerate(frames):
        dispose = frame.dispose
        if index == 0 and dispose == 2:
            dispose = 1
        saved = [line[:] for line in canvas] if dispose == 2 else None
        for y in range(frame.height):
            for x in range(frame.width):
                pixel = frame.pixels[y][x]
                target_y, target_x = frame.top + y, frame.left + x
                if frame.blend == 0:
                    canvas[target_y][target_x] = pixel
                else:
                    canvas[target_y][target_x] = blend_over(canvas[target_y][target_x], pixel)
        seen.append([pixel for line in canvas for pixel in line])
        if dispose == 1:
            for y in range(frame.height):
                for x in range(frame.width):
                    canvas[frame.top + y][frame.left + x] = (0, 0, 0, 0)
        elif dispose == 2:
            canvas = saved
    return seen


def solid_frame(width, height, left, top, color, hole=False, seed=0, translucent=False):
    generator = random.Random(seed)
    pixels = []
    for y in range(height):
        line = []
        for x in range(width):
            red, green, blue = color
            red = (red + x * 9 + generator.randrange(8)) % 256
            green = (green + y * 11) % 256
            if translucent:
                alpha = (x * 40 + y * 25) % 256
            elif hole and (x + y) % 3 == 0:
                alpha = 0
            else:
                alpha = 255
            line.append((red, green, blue, alpha) if alpha else (0, 0, 0, 0))
        pixels.append(line)
    return pixels


def write_animation(name, width, height, default_pixels, frames, plays, default_is_frame, pillow_check,
                    **options):
    """pillow_check: "exact" (Pillow must composite every frame the same), "soft" (a warning if not) or None."""
    write(name, apng_file(width, height, default_pixels, frames, plays, default_is_frame, **options))
    base = os.path.splitext(name)[0]
    fixturecommon.write_reference_pixels(path(base + "-default.rgba"), width, height,
                                         [pixel for line in default_pixels for pixel in line])
    seen = composite(width, height, frames)
    for index, pixels in enumerate(seen):
        fixturecommon.write_reference_pixels(path(f"{base}-frame{index}.rgba"), width, height, pixels)
    if pillow_check is None:
        return
    problem = None
    with Image.open(path(name)) as image:
        offset = 0 if default_is_frame else 1
        if image.n_frames != len(frames) + offset:
            problem = f"{name}: Pillow sees {image.n_frames} frames"
        else:
            for index, pixels in enumerate(seen):
                image.seek(index + offset)
                if fixturecommon.rgba_pixels(image) != pixels:
                    problem = f"{name}: Pillow composites frame {index} differently"
                    break
    if problem is None:
        return
    if pillow_check == "exact":
        raise SystemExit(problem)
    WARNINGS.append(problem)


def make_animations():
    width, height = 40, 30
    first = solid_frame(width, height, 0, 0, (200, 30, 30), seed=1)
    frames = [
        # The first frame's "previous" is a cleared canvas.
        Frame(width, height, 0, 0, first, 1, 10, 2, 0),
        Frame(12, 10, 5, 4, solid_frame(12, 10, 5, 4, (20, 200, 40), hole=True, seed=2), 20, 100, 0, 1),
        Frame(15, 12, 20, 10, solid_frame(15, 12, 20, 10, (30, 30, 220), seed=3), 1, 0, 1, 0),
        Frame(20, 15, 10, 8, solid_frame(20, 15, 10, 8, (250, 250, 0), hole=True, seed=4), 3, 7, 2, 1),
        Frame(10, 10, 25, 2, solid_frame(10, 10, 25, 2, (0, 250, 250), seed=5), 0, 0, 2, 0),
        Frame(40, 30, 0, 0, solid_frame(40, 30, 0, 0, (90, 90, 90), hole=True, seed=6), 500, 1000, 0, 1),
    ]
    write_animation("apng-default-frame.png", width, height, first, frames, 3, True, "exact")
    default = solid_frame(width, height, 0, 0, (10, 10, 10), seed=9)
    separate = [
        # Pillow takes the default image for what was before the first
        # frame where the specification has a transparent canvas, so this
        # one covers it all and is left as it is.
        Frame(40, 30, 0, 0, solid_frame(40, 30, 0, 0, (100, 0, 0), hole=True, seed=10), 1, 1, 0, 0),
        Frame(10, 10, 0, 0, solid_frame(10, 10, 0, 0, (0, 100, 0), seed=11), 2, 1, 1, 1),
        Frame(40, 30, 0, 0, solid_frame(40, 30, 0, 0, (0, 0, 100), hole=True, seed=12), 65535, 1000, 0, 0),
    ]
    write_animation("apng-default-separate.png", width, height, default, separate, 0, False, "exact")
    # Palette frames with tRNS; entry 3 is fully transparent.
    palette = [(255, 0, 0), (0, 255, 0), (0, 0, 255), (0, 0, 0), (255, 255, 255)]
    alphas = bytes((255, 128, 255, 0))
    colors = [palette[index] + ((alphas[index] if index < len(alphas) else 255),) for index in range(len(palette))]
    lookup = {color: index for index, color in enumerate(colors)}

    def palette_frame(frame_width, frame_height, shift):
        return [[colors[(x + y + shift) % len(colors)] for x in range(frame_width)] for y in range(frame_height)]

    first = palette_frame(16, 16, 0)
    palette_frames = [Frame(16, 16, 0, 0, first, 1, 25, 1, 0),
                      Frame(8, 8, 4, 4, palette_frame(8, 8, 2), 1, 25, 0, 0),
                      Frame(6, 10, 10, 6, palette_frame(6, 10, 4), 1, 25, 2, 1)]
    write_animation("apng-palette.png", 16, 16, first, palette_frames, 1, True, "soft", color_type=PALETTE,
                    palette=palette, transparency=alphas, encode=lambda pixel: (lookup[pixel],))
    # Translucent pixels blended over others: only this script's compositor is the reference.
    first = solid_frame(24, 20, 0, 0, (200, 100, 50), translucent=True, seed=20)
    translucent = [Frame(24, 20, 0, 0, first, 1, 10, 0, 1),
                   Frame(16, 12, 4, 4, solid_frame(16, 12, 4, 4, (10, 120, 240), translucent=True, seed=21), 1, 10,
                         0, 1)]
    write_animation("apng-translucent.png", 24, 20, first, translucent, 0, True, None)
    # The second frame's data is cut off: the first frame is kept.
    data = apng_file(width, height, frames[0].pixels, frames, 3, True)
    second_fdat = data.find(b"fdAT", data.find(b"fdAT") + 1)
    write("apng-truncated.png", data[:second_fdat + 20])


def main():
    make_matrix()
    make_transparency()
    make_sizes()
    make_filters_and_chunking()
    make_metadata()
    make_pillow_files()
    make_broken()
    make_animations()
    for warning in WARNINGS:
        print("warning:", warning)


if __name__ == "__main__":
    main()
