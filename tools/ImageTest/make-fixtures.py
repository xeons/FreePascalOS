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

"""The BMP, DIB, ICO, CUR and GIF fixtures of ImageTest.

    make-fixtures.py OUTPUT_DIRECTORY

Most files are put together byte by byte here, so every variant the
decoders must read is there (each BMP depth and header, RLE with moves,
bit fields, icons with masks, GIF frames with every disposal), and the
pixels they stand for are known exactly: those are the references
(name.rgba, see fixturecommon.py). Where Pillow reads a file the same
way, its decoding is compared with the reference here too, to make sure
the fixture itself is right; files Pillow writes are included with
Pillow's decoding as their reference.

Malformed and truncated files are made from good ones.
"""

import io
import os
import random
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from PIL import Image  # noqa: E402

from fixturecommon import write_reference, write_reference_pixels, test_picture, rgba_pixels  # noqa: E402

OUTPUT = sys.argv[1] if len(sys.argv) > 1 else "build/tools/image-fixtures"
WARNINGS = []


def path(name):
    os.makedirs(OUTPUT, exist_ok=True)
    return os.path.join(OUTPUT, name)


def write(name, data):
    with open(path(name), "wb") as output:
        output.write(data)


def reference_name(name):
    return os.path.splitext(name)[0] + ".rgba"


def save_truth(name, width, height, pixels):
    write_reference_pixels(path(reference_name(name)), width, height, pixels)


def compare_with_pillow(name, width, height, pixels):
    """Warns when Pillow reads the fixture differently from its truth."""
    try:
        image = Image.open(path(name)).convert("RGBA")
    except Exception as error:  # Pillow does not read every variant
        WARNINGS.append(f"{name}: Pillow cannot read it ({error})")
        return
    if image.size != (width, height) or rgba_pixels(image) != list(pixels):
        WARNINGS.append(f"{name}: Pillow reads it differently")


# --- BMP -------------------------------------------------------------------

def palette_colors(count, seed):
    generator = random.Random(seed)
    return [(generator.randrange(256), generator.randrange(256), generator.randrange(256)) for _ in range(count)]


def index_pattern(width, height, count):
    return [[(x * 3 + y * 5 + (x * y) // 7) % count for x in range(width)] for y in range(height)]


def info_header(size, width, height, bits, compression=0, colors_used=0, masks=None, color_space=0,
                profile_offset=0, profile_size=0, image_size=0):
    if size == 12:
        return struct.pack("<IHHHH", 12, width, height & 0xFFFF, 1, bits)
    header = struct.pack("<IiiHHIIiiII", size, width, height, 1, bits, compression, image_size, 2835, 2835,
                         colors_used, 0)
    if size >= 52:
        red, green, blue, alpha = (list(masks) + [0, 0, 0, 0])[:4] if masks else (0, 0, 0, 0)
        header += struct.pack("<III", red, green, blue)
        if size >= 56:
            header += struct.pack("<I", alpha)
    if size >= 108:
        header += struct.pack("<I", color_space) + bytes(36) + bytes(12)
    if size >= 124:
        header += struct.pack("<IIII", 4, profile_offset, profile_size, 0)
    assert len(header) == size, (size, len(header))
    return header


def palette_bytes(colors, entry_size=4):
    data = b""
    for red, green, blue in colors:
        data += bytes((blue, green, red)) + (b"\0" if entry_size == 4 else b"")
    return data


def row_stride(width, bits):
    return ((width * bits + 31) // 32) * 4


def pack_indexed_rows(rows, bits, top_down=False):
    height = len(rows)
    width = len(rows[0])
    data = b""
    order = range(height) if top_down else range(height - 1, -1, -1)
    for y in order:
        line = bytearray(row_stride(width, bits))
        for x, value in enumerate(rows[y]):
            if bits == 8:
                line[x] = value
            elif bits == 4:
                line[x // 2] |= value << (4 if x % 2 == 0 else 0)
            elif bits == 1:
                line[x // 8] |= value << (7 - x % 8)
        data += bytes(line)
    return data


def mask_field(mask):
    if mask == 0:
        return 0, 0
    shift = 0
    while not (mask >> shift) & 1:
        shift += 1
    bits = 0
    while (mask >> (shift + bits)) & 1:
        bits += 1
    return shift, bits


def to_field(value, mask):
    shift, bits = mask_field(mask)
    if bits == 0:
        return 0
    maximum = (1 << bits) - 1
    return (round(value * maximum / 255) & maximum) << shift


def from_field(pixel, mask, default):
    shift, bits = mask_field(mask)
    if bits == 0:
        return default
    maximum = (1 << bits) - 1
    value = (pixel >> shift) & maximum
    if bits == 8:
        return value
    return (value * 255 + maximum // 2) // maximum


def pack_masked(picture, bits, masks, top_down=False):
    """Packs RGBA tuples with masks; returns the bytes and the pixels a
    decoder must see."""
    width, height = picture.size
    source = picture.load()
    red_mask, green_mask, blue_mask, alpha_mask = masks
    data = b""
    truth = [[None] * width for _ in range(height)]
    order = range(height) if top_down else range(height - 1, -1, -1)
    for y in order:
        line = bytearray(row_stride(width, bits))
        for x in range(width):
            red, green, blue, alpha = source[x, y]
            pixel = (to_field(red, red_mask) | to_field(green, green_mask) | to_field(blue, blue_mask) |
                     to_field(alpha, alpha_mask))
            struct.pack_into("<H" if bits == 16 else "<I", line, x * bits // 8, pixel)
            truth[y][x] = (from_field(pixel, red_mask, 0), from_field(pixel, green_mask, 0),
                           from_field(pixel, blue_mask, 0), from_field(pixel, alpha_mask, 255))
        data += bytes(line)
    return data, [pixel for row in truth for pixel in row]


def pack_true_color(picture, bits, top_down=False, alpha_byte=None):
    width, height = picture.size
    source = picture.convert("RGBA").load()
    data = b""
    order = range(height) if top_down else range(height - 1, -1, -1)
    for y in order:
        line = bytearray(row_stride(width, bits))
        for x in range(width):
            red, green, blue, alpha = source[x, y]
            if bits == 24:
                line[3 * x:3 * x + 3] = bytes((blue, green, red))
            else:
                line[4 * x:4 * x + 4] = bytes((blue, green, red, alpha if alpha_byte is None else alpha_byte))
        data += bytes(line)
    return data


def bmp_file(header, extra, pixels):
    offset = 14 + len(header) + len(extra)
    return b"BM" + struct.pack("<IHHI", offset + len(pixels), 0, 0, offset) + header + extra + pixels


def indexed_truth(rows, colors):
    return [colors[value] + (255,) for row in rows for value in row]


def make_indexed_bmp(name, width, height, bits, top_down=False, header_size=40, compare=True):
    count = 1 << bits
    colors = palette_colors(count, bits * 11 + width)
    rows = index_pattern(width, height, count)
    entry_size = 3 if header_size == 12 else 4
    header = info_header(header_size, width, -height if top_down else height, bits)
    data = bmp_file(header, palette_bytes(colors, entry_size), pack_indexed_rows(rows, bits, top_down))
    write(name, data)
    truth = indexed_truth(rows, colors)
    save_truth(name, width, height, truth)
    if compare:
        compare_with_pillow(name, width, height, truth)
    return data


def make_masked_bmp(name, width, height, bits, masks, header_size, compression, top_down=False,
                    alpha_picture=True, compare=True):
    picture = test_picture(width, height, seed=bits + header_size, alpha=alpha_picture).convert("RGBA")
    pixels, truth = pack_masked(picture, bits, masks, top_down)
    header = info_header(header_size, width, -height if top_down else height, bits, compression,
                         masks=masks if header_size >= 52 else None, color_space=0x73524742)
    extra = b""
    if header_size == 40 and compression in (3, 6):
        extra = struct.pack("<III", *masks[:3]) + (struct.pack("<I", masks[3]) if compression == 6 else b"")
    write(name, bmp_file(header, extra, pixels))
    save_truth(name, width, height, truth)
    if compare:
        compare_with_pillow(name, width, height, truth)


def rle_encode_row(values, four_bits):
    """One line of RLE8 or RLE4: runs of equal values, absolute runs of
    three and more different ones."""
    data = bytearray()
    index = 0
    width = len(values)
    while index < width:
        run = 1
        while index + run < width and run < 255 and values[index + run] == values[index]:
            run += 1
        if run >= 2:
            value = values[index]
            data += bytes((run, (value << 4) | value if four_bits else value))
            index += run
            continue
        literal = 1
        while (index + literal < width and literal < 255 and
               not (index + literal + 1 < width and values[index + literal] == values[index + literal + 1])):
            literal += 1
        chunk = values[index:index + literal]
        if literal >= 3:
            data += bytes((0, literal))
            if four_bits:
                packed = bytearray((literal + 1) // 2)
                for position, value in enumerate(chunk):
                    packed[position // 2] |= value << (4 if position % 2 == 0 else 0)
            else:
                packed = bytearray(chunk)
            if len(packed) % 2:
                packed += b"\0"
            data += packed
        else:
            for value in chunk:
                data += bytes((1, value << 4 if four_bits else value))
        index += literal
    return bytes(data)


def make_rle_bmp(name, width, height, four_bits):
    bits = 4 if four_bits else 8
    count = 16 if four_bits else 256
    colors = palette_colors(count, 70 + bits)
    rows = [[((x // 5) * 3 + y) % count if x % 9 else (x * 7 + y * 3) % count for x in range(width)]
            for y in range(height)]
    stream = b""
    for y in range(height - 1, -1, -1):
        stream += rle_encode_row(rows[y], four_bits) + b"\0\0"
    stream += b"\0\1"
    header = info_header(40, width, height, bits, 2 if four_bits else 1, image_size=len(stream))
    write(name, bmp_file(header, palette_bytes(colors), stream))
    truth = indexed_truth(rows, colors)
    save_truth(name, width, height, truth)
    compare_with_pillow(name, width, height, truth)


def make_rle_moves_bmp(name):
    """RLE8 with a move, a line ended early and the picture ended early:
    the pixels it skips are transparent."""
    width, height = 16, 8
    colors = palette_colors(256, 99)
    truth = [[(0, 0, 0, 0)] * width for _ in range(height)]

    def put(x, row, value):
        y = height - 1 - row
        truth[y][x] = colors[value] + (255,)

    stream = bytearray()
    # Line 0 (the bottom): 16 pixels of 5.
    stream += bytes((16, 5, 0, 0))
    for x in range(16):
        put(x, 0, 5)
    # Line 1: 4 pixels of 7, a move 6 right and 1 down, 3 of 9, end of line.
    stream += bytes((4, 7, 0, 2, 6, 1, 3, 9, 0, 0))
    for x in range(4):
        put(x, 1, 7)
    for x in range(10, 13):
        put(x, 2, 9)
    # Line 3: an absolute run of 5 and the end of the picture.
    stream += bytes((0, 5, 1, 2, 3, 4, 200, 0, 0, 1))
    for x, value in enumerate((1, 2, 3, 4, 200)):
        put(x, 3, value)
    header = info_header(40, width, height, 8, 1, image_size=len(stream))
    write(name, bmp_file(header, palette_bytes(colors), bytes(stream)))
    save_truth(name, width, height, [pixel for row in truth for pixel in row])


def make_bmps():
    make_indexed_bmp("bmp1.bmp", 37, 13, 1)
    make_indexed_bmp("bmp4.bmp", 21, 11, 4)
    make_indexed_bmp("bmp8.bmp", 30, 17, 8)
    make_indexed_bmp("bmp8-topdown.bmp", 19, 9, 8, top_down=True)
    make_indexed_bmp("bmp8-core.bmp", 23, 7, 8, header_size=12)
    make_indexed_bmp("bmp4-core.bmp", 13, 5, 4, header_size=12)

    picture = test_picture(31, 15, seed=3)
    pixels = pack_true_color(picture, 24)
    write("bmp24.bmp", bmp_file(info_header(40, 31, 15, 24), b"", pixels))
    truth = rgba_pixels(picture)
    save_truth("bmp24.bmp", 31, 15, truth)
    compare_with_pillow("bmp24.bmp", 31, 15, truth)

    pixels = pack_true_color(picture, 24, top_down=True)
    write("bmp24-topdown.bmp", bmp_file(info_header(40, 31, -15, 24), b"", pixels))
    save_truth("bmp24-topdown.bmp", 31, 15, truth)

    # 32 bits without masks, the fourth byte zero: opaque.
    pixels = pack_true_color(picture, 32, alpha_byte=0)
    write("bmp32-reserved.bmp", bmp_file(info_header(40, 31, 15, 32), b"", pixels))
    save_truth("bmp32-reserved.bmp", 31, 15, truth)
    compare_with_pillow("bmp32-reserved.bmp", 31, 15, truth)

    # 32 bits without masks, the fourth byte used: alpha.
    translucent = test_picture(29, 14, seed=4, alpha=True)
    pixels = pack_true_color(translucent, 32)
    write("bmp32-alpha.bmp", bmp_file(info_header(40, 29, 14, 32), b"", pixels))
    save_truth("bmp32-alpha.bmp", 29, 14, rgba_pixels(translucent))

    # Pillow widens 5 and 6-bit values by truncating, the decoder by
    # rounding (as bit replication does): not compared.
    make_masked_bmp("bmp16-555.bmp", 27, 12, 16, (0x7C00, 0x03E0, 0x001F, 0), 40, 0, alpha_picture=False,
                    compare=False)
    make_masked_bmp("bmp16-565.bmp", 27, 12, 16, (0xF800, 0x07E0, 0x001F, 0), 40, 3, alpha_picture=False,
                    compare=False)
    make_masked_bmp("bmp16-4444-v3.bmp", 26, 10, 16, (0x0F00, 0x00F0, 0x000F, 0xF000), 56, 3, compare=False)
    make_masked_bmp("bmp32-v5.bmp", 25, 13, 32, (0x00FF0000, 0x0000FF00, 0x000000FF, 0xFF000000), 124, 3)
    make_masked_bmp("bmp32-v4-rgba.bmp", 25, 13, 32, (0x000000FF, 0x0000FF00, 0x00FF0000, 0xFF000000), 108, 3,
                    top_down=True, compare=False)
    make_masked_bmp("bmp32-alphabitfields.bmp", 22, 9, 32, (0x00FF0000, 0x0000FF00, 0x000000FF, 0xFF000000), 40, 6,
                    compare=False)
    make_masked_bmp("bmp32-101010.bmp", 22, 9, 32, (0x3FF00000, 0x000FFC00, 0x000003FF, 0), 40, 3,
                    alpha_picture=False, compare=False)

    make_rle_bmp("bmp-rle8.bmp", 41, 12, False)
    make_rle_bmp("bmp-rle4.bmp", 39, 11, True)
    make_rle_moves_bmp("bmp-rle8-moves.bmp")

    # A V5 header with an embedded profile after the pixels.
    width, height = 8, 4
    picture = test_picture(width, height, seed=8, alpha=True)
    pixels, truth = pack_masked(picture, 32, (0x00FF0000, 0x0000FF00, 0x000000FF, 0xFF000000))
    profile = b"FAKE-ICC-PROFILE-" + bytes(range(40))
    profile_offset = 124 + len(pixels)
    header = info_header(124, width, height, 32, 3, masks=(0x00FF0000, 0x0000FF00, 0x000000FF, 0xFF000000),
                         color_space=0x4D424544, profile_offset=profile_offset, profile_size=len(profile))
    write("bmp32-profile.bmp", bmp_file(header, b"", pixels) + profile)
    save_truth("bmp32-profile.bmp", width, height, truth)
    write("bmp32-profile.icc", profile)

    # Pillow's own BMPs.
    for name, mode in (("pillow-rgb.bmp", "RGB"), ("pillow-p.bmp", "P"), ("pillow-1.bmp", "1"),
                       ("pillow-l.bmp", "L")):
        picture = test_picture(33, 21, seed=len(name)).convert(mode)
        picture.save(path(name))
        write_reference(path(reference_name(name)), Image.open(path(name)))

    # DIBs: a BMP without its file header.
    picture = test_picture(17, 9, seed=17)
    write("dib24.dib", info_header(40, 17, 9, 24) + pack_true_color(picture, 24))
    save_truth("dib24.dib", 17, 9, rgba_pixels(picture))
    picture = test_picture(15, 6, seed=18, alpha=True)
    pixels, truth = pack_masked(picture, 32, (0x00FF0000, 0x0000FF00, 0x000000FF, 0))
    write("dib32-bitfields.dib", info_header(40, 15, 6, 32, 3) + struct.pack("<III", 0xFF0000, 0xFF00, 0xFF) + pixels)
    save_truth("dib32-bitfields.dib", 15, 6, truth)
    colors = palette_colors(16, 5)
    rows = index_pattern(11, 7, 16)
    write("dib4.dib", info_header(40, 11, 7, 4) + palette_bytes(colors) + pack_indexed_rows(rows, 4))
    save_truth("dib4.dib", 11, 7, indexed_truth(rows, colors))

    # Malformed.
    good = open(path("bmp24.bmp"), "rb").read()
    write("bad-bmp-truncated.bmp", good[:len(good) // 2])
    write("bad-bmp-header-only.bmp", good[:20])
    bad = bytearray(good)
    struct.pack_into("<I", bad, 14, 77)
    write("bad-bmp-header-size.bmp", bytes(bad))
    bad = bytearray(good)
    struct.pack_into("<i", bad, 18, 100000)
    write("bad-bmp-huge.bmp", bytes(bad))
    bad = bytearray(good)
    struct.pack_into("<H", bad, 28, 7)
    write("bad-bmp-depth.bmp", bytes(bad))
    bad = bytearray(open(path("bmp8.bmp"), "rb").read())
    struct.pack_into("<I", bad, 46, 1000)
    write("bad-bmp-palette.bmp", bytes(bad))
    bad = bytearray(open(path("bmp-rle8.bmp"), "rb").read())
    generator = random.Random(5)
    for index in range(1078, len(bad)):
        bad[index] = generator.randrange(256)
    write("bad-bmp-rle-garbage.bmp", bytes(bad))
    bad = bytearray(good)
    struct.pack_into("<I", bad, 10, 0x7FFFFFF0)
    write("bad-bmp-offset.bmp", bytes(bad))


# --- ICO and CUR -----------------------------------------------------------

def circle_mask(size):
    """1 (transparent) outside a circle."""
    centre = (size - 1) / 2
    return [[1 if (x - centre) ** 2 + (y - centre) ** 2 > (size / 2) ** 2 else 0 for x in range(size)]
            for y in range(size)]


def pack_mask(mask):
    return pack_indexed_rows(mask, 1)


def icon_dib_indexed(size, bits, seed):
    count = 1 << bits
    colors = palette_colors(count, seed)
    rows = index_pattern(size, size, count)
    mask = circle_mask(size)
    data = info_header(40, size, size * 2, bits) + palette_bytes(colors) + pack_indexed_rows(rows, bits) + \
        pack_mask(mask)
    truth = [(0, 0, 0, 0) if mask[y][x] else colors[rows[y][x]] + (255,) for y in range(size) for x in range(size)]
    return data, truth


def icon_dib_alpha(size, seed):
    picture = test_picture(size, size, seed=seed, alpha=True)
    pixels = pack_true_color(picture, 32)
    mask = [[0] * size for _ in range(size)]
    data = info_header(40, size, size * 2, 32) + pixels + pack_mask(mask)
    return data, rgba_pixels(picture)


def icon_file(entries, cursor=False):
    """entries: (width, height, bits, data, hotspot)."""
    header = struct.pack("<HHH", 0, 2 if cursor else 1, len(entries))
    offset = 6 + 16 * len(entries)
    directory = b""
    body = b""
    for width, height, bits, data, hotspot in entries:
        first, second = hotspot if cursor else (1, bits)
        directory += struct.pack("<BBBBHHII", width % 256, height % 256, 0, 0, first, second, len(data),
                                 offset + len(body))
        body += data
    return header + directory + body


def make_icons():
    entry16, truth16 = icon_dib_indexed(16, 4, 21)
    entry24, truth24 = icon_dib_indexed(24, 1, 22)
    entry32, truth32 = icon_dib_indexed(32, 8, 23)
    entry48, truth48 = icon_dib_alpha(48, 24)
    write("icon-multi.ico", icon_file([(16, 16, 4, entry16, None), (32, 32, 8, entry32, None),
                                       (48, 48, 32, entry48, None), (24, 24, 1, entry24, None)]))
    for size, truth in ((16, truth16), (24, truth24), (32, truth32), (48, truth48)):
        save_truth(f"icon-multi-{size}.ico", size, size, truth)
    compare_with_pillow("icon-multi.ico", 48, 48, truth48)

    # A PNG entry beside a DIB one.
    png = io.BytesIO()
    test_picture(64, 64, seed=25, alpha=True).save(png, "PNG")
    write("icon-png-mixed.ico", icon_file([(16, 16, 4, entry16, None), (64, 64, 32, png.getvalue(), None)]))
    # Only PNG entries, as Pillow writes icons.
    test_picture(32, 32, seed=26, alpha=True).save(path("icon-png-only.ico"), sizes=[(32, 32)])
    # Pillow's BMP entries.
    picture = test_picture(32, 32, seed=27, alpha=True)
    picture.save(path("pillow-bmp.ico"), sizes=[(16, 16), (32, 32)], bitmap_format="bmp")
    write_reference(path("pillow-bmp.rgba"), Image.open(path("pillow-bmp.ico")))

    # A cursor: two sizes with their hotspots.
    cursor32, cursor_truth32 = icon_dib_indexed(32, 1, 31)
    cursor48, cursor_truth48 = icon_dib_alpha(48, 32)
    write("pointer.cur", icon_file([(32, 32, 1, cursor32, (5, 7)), (48, 48, 32, cursor48, (8, 10))], cursor=True))
    save_truth("pointer-32.cur", 32, 32, cursor_truth32)
    save_truth("pointer-48.cur", 48, 48, cursor_truth48)

    good = open(path("icon-multi.ico"), "rb").read()
    bad = bytearray(good)
    struct.pack_into("<I", bad, 6 + 12, len(good) + 100)
    write("bad-ico-offset.ico", bytes(bad))
    bad = bytearray(good)
    struct.pack_into("<H", bad, 4, 60000)
    write("bad-ico-count.ico", bytes(bad))
    write("bad-ico-truncated.ico", good[:len(good) - 300])
    bad = bytearray(good)
    first_offset = struct.unpack_from("<I", good, 6 + 12)[0]
    struct.pack_into("<i", bad, first_offset + 8, 0)
    write("bad-ico-height.ico", bytes(bad))


# --- GIF -------------------------------------------------------------------

def lzw_encode(indices, minimum_code_size):
    clear = 1 << minimum_code_size
    end = clear + 1
    output = bytearray()
    state = {"buffer": 0, "count": 0}

    def emit(code, bits):
        state["buffer"] |= code << state["count"]
        state["count"] += bits
        while state["count"] >= 8:
            output.append(state["buffer"] & 0xFF)
            state["buffer"] >>= 8
            state["count"] -= 8

    def fresh_table():
        return {(value,): value for value in range(clear)}, end + 1, minimum_code_size + 1

    table, next_code, bits = fresh_table()
    emit(clear, bits)
    if indices:
        current = (indices[0],)
        for value in indices[1:]:
            extended = current + (value,)
            if extended in table:
                current = extended
                continue
            emit(table[current], bits)
            table[extended] = next_code
            next_code += 1
            if next_code > (1 << bits) and bits < 12:
                bits += 1
            if next_code >= 4096:
                emit(clear, bits)
                table, next_code, bits = fresh_table()
            current = (value,)
        emit(table[current], bits)
        if next_code >= (1 << bits) and bits < 12:
            bits += 1
    emit(end, bits)
    if state["count"]:
        output.append(state["buffer"] & 0xFF)
    return bytes(output)


def sub_blocks(data):
    out = bytearray()
    for start in range(0, len(data), 255):
        chunk = data[start:start + 255]
        out += bytes((len(chunk),)) + chunk
    return bytes(out) + b"\0"


def palette_size_bits(colors):
    bits = 1
    while (1 << bits) < len(colors):
        bits += 1
    return bits


def color_table(colors):
    bits = palette_size_bits(colors)
    padded = list(colors) + [(0, 0, 0)] * ((1 << bits) - len(colors))
    return b"".join(bytes(color) for color in padded), bits


def interlace_order(height):
    return (list(range(0, height, 8)) + list(range(4, height, 8)) + list(range(2, height, 4)) +
            list(range(1, height, 2)))


def gif_file(width, height, global_colors, frames, loop=None, comment=None, version=b"89a", background=0):
    data = bytearray(b"GIF" + version + struct.pack("<HH", width, height))
    if global_colors:
        table, bits = color_table(global_colors)
        data += bytes((0x80 | ((bits - 1) << 4) | (bits - 1), background, 0)) + table
    else:
        data += bytes((0, 0, 0))
    if loop is not None:
        data += b"\x21\xFF\x0BNETSCAPE2.0\x03\x01" + struct.pack("<H", loop) + b"\0"
    if comment:
        data += b"\x21\xFE" + sub_blocks(comment)
    for frame in frames:
        if version == b"89a":
            flags = (frame.get("disposal", 0) << 2) | (1 if frame.get("transparent") is not None else 0)
            data += b"\x21\xF9\x04" + bytes((flags,)) + struct.pack("<H", frame.get("delay", 0)) + \
                bytes((frame.get("transparent") or 0, 0))
        local = frame.get("local")
        flags = 0x40 if frame.get("interlaced") else 0
        table = b""
        if local:
            table, bits = color_table(local)
            flags |= 0x80 | (bits - 1)
        data += b"\x2C" + struct.pack("<HHHH", frame["left"], frame["top"], frame["width"], frame["height"]) + \
            bytes((flags,)) + table
        rows = frame["rows"]
        order = interlace_order(frame["height"]) if frame.get("interlaced") else range(frame["height"])
        indices = [value for y in order for value in rows[y]]
        palette = local or global_colors
        minimum = max(2, palette_size_bits(palette))
        data += bytes((minimum,)) + sub_blocks(lzw_encode(indices, minimum))
    data += b"\x3B"
    return bytes(data)


def composite(width, height, global_colors, frames):
    """The canvases a player shows: transparent at first; disposal 2
    clears the frame's area, 3 puts back what was before it."""
    canvas = [[(0, 0, 0, 0)] * width for _ in range(height)]
    results = []
    previous = None
    saved = None
    for frame in frames:
        if previous is not None:
            if previous.get("disposal") == 2:
                for y in range(previous["top"], min(height, previous["top"] + previous["height"])):
                    for x in range(previous["left"], min(width, previous["left"] + previous["width"])):
                        canvas[y][x] = (0, 0, 0, 0)
            elif previous.get("disposal") == 3 and saved is not None:
                canvas = [row[:] for row in saved]
        if frame.get("disposal") == 3:
            saved = [row[:] for row in canvas]
        palette = frame.get("local") or global_colors
        for row_index, row in enumerate(frame["rows"]):
            y = frame["top"] + row_index
            if y >= height:
                continue
            for column, value in enumerate(row):
                x = frame["left"] + column
                if x >= width or value == frame.get("transparent"):
                    continue
                canvas[y][x] = palette[value] + (255,)
        results.append([pixel for row in canvas for pixel in row])
        previous = frame
    return results


def frame_rows(width, height, count, seed, transparent=None):
    generator = random.Random(seed)
    rows = []
    for y in range(height):
        row = []
        for x in range(width):
            value = (x // 2 + y + seed) % count
            if transparent is not None and generator.random() < 0.25:
                value = transparent
            row.append(value)
        rows.append(row)
    return rows


def make_gifs():
    global_colors = palette_colors(16, 41)
    local_colors = palette_colors(4, 42)
    width, height = 40, 30
    frames = [
        dict(left=0, top=0, width=40, height=30, rows=frame_rows(40, 30, 16, 1), disposal=1, delay=10),
        dict(left=5, top=4, width=10, height=8, rows=frame_rows(10, 8, 16, 2, transparent=3), transparent=3,
             disposal=2, delay=20),
        dict(left=20, top=10, width=12, height=10, rows=frame_rows(12, 10, 4, 3), local=local_colors, disposal=3,
             delay=5),
        dict(left=2, top=13, width=8, height=11, rows=frame_rows(8, 11, 16, 4, transparent=0), transparent=0,
             interlaced=True, disposal=0, delay=0),
        dict(left=36, top=26, width=6, height=6, rows=frame_rows(6, 6, 16, 5), disposal=1, delay=7),
    ]
    data = gif_file(width, height, global_colors, frames, loop=3, comment=b"FreePascalOS test animation")
    write("anim.gif", data)
    for index, canvas in enumerate(composite(width, height, global_colors, frames)):
        save_truth(f"anim-{index}.gif", width, height, canvas)
    first = composite(width, height, global_colors, frames)[0]
    compare_with_pillow("anim.gif", width, height, first)
    # Cut short in the fourth frame's data.
    cut = data.rfind(b"\x2C\x02\x00\x0D\x00") + 30
    write("anim-truncated.gif", data[:cut])

    # A still picture of 256 colours, large enough for the table to fill
    # and start again, interlaced.
    colors = palette_colors(256, 43)
    generator = random.Random(44)
    noise = [[generator.randrange(256) for _ in range(120)] for _ in range(100)]
    frame = dict(left=0, top=0, width=120, height=100, rows=noise, interlaced=True)
    write("noise.gif", gif_file(120, 100, colors, [frame]))
    truth = composite(120, 100, colors, [frame])[0]
    save_truth("noise.gif", 120, 100, truth)
    compare_with_pillow("noise.gif", 120, 100, truth)

    # Two colours (the smallest code size), GIF87a, no loop count.
    colors = [(255, 255, 255), (10, 20, 30)]
    rows = [[(x // 3 + y // 2) % 2 for x in range(25)] for y in range(14)]
    frame = dict(left=0, top=0, width=25, height=14, rows=rows)
    write("bilevel.gif", gif_file(25, 14, colors, [frame], version=b"87a"))
    save_truth("bilevel.gif", 25, 14, composite(25, 14, colors, [frame])[0])

    # Only a local colour table, offset into a screen of 0 x 0.
    rows = frame_rows(9, 7, 4, 6)
    frame = dict(left=3, top=2, width=9, height=7, rows=rows, local=local_colors)
    write("local-only.gif", gif_file(0, 0, None, [frame]))
    save_truth("local-only.gif", 12, 9, composite(12, 9, None, [frame])[0])

    # Pillow's own GIF.
    picture = test_picture(35, 22, seed=45).convert("P", palette=Image.Palette.ADAPTIVE, colors=64)
    picture.save(path("pillow.gif"))
    write_reference(path("pillow.rgba"), Image.open(path("pillow.gif")))

    good = data
    write("bad-gif-signature.gif", b"GIF88a" + good[6:])
    write("bad-gif-header-only.gif", good[:10])
    garbage = bytearray(good)
    generator = random.Random(46)
    start = good.find(b"\x2C")
    for index in range(start + 12, min(len(garbage) - 1, start + 400)):
        garbage[index] = generator.randrange(256)
    write("bad-gif-garbage.gif", bytes(garbage))
    bad = bytearray(gif_file(8, 8, palette_colors(4, 47), [dict(left=0, top=0, width=8, height=8,
                                                               rows=frame_rows(8, 8, 4, 7))]))
    lzw_start = bad.find(b"\x2C") + 10
    bad[lzw_start] = 12
    write("bad-gif-code-size.gif", bytes(bad))
    write("bad-gif-no-frames.gif", good[:good.find(b"\x21\xF9")] + b"\x3B")


def main():
    make_bmps()
    make_icons()
    make_gifs()
    for warning in WARNINGS:
        print("make-fixtures:", warning)


if __name__ == "__main__":
    main()
