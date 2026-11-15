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

"""
Renders a TrueType font into coverage fonts (.cvf), the anti-aliased
bitmap fonts libfont reads (Font.Coverage), one file per pixel size.

The system has no font rasterizer yet, so a proportional font is drawn
here, on the host, with FreeType (through Pillow), at every pixel size
the interface may want, and the system only blends the finished
coverage bitmaps.

    render-font.py --font FILE.ttf [--bold] --sizes 9-40
                   --name PREFIX --output DIRECTORY

writes DIRECTORY/PREFIX-<size>.cvf for every size. The size is the em
in pixels (what a point size at a DPI comes to); the line is taller.

A coverage font, all numbers little-endian:

    header (40 bytes)
       0  magic "CVF1"
       4  u16 header size (40)
       6  u16 flags: bit 0 bold
       8  u16 pixel size (the em)
      10  u16 line height (ascent + descent)
      12  i16 ascent: from the top of the line to the baseline
      14  i16 underline top, from the top of the line
      16  u16 underline thickness
      18  u16 glyph count
      20  u32 kerning pair count
      24  u32 offset of the glyph table
      28  u32 offset of the kerning table
      32  u32 offset of the coverage data
      36  u32 size of the coverage data
    glyph table: glyph count entries of 20 bytes, by code point,
    strictly increasing
       0  u32 code point
       4  u32 offset of its bitmap within the coverage data
       8  i16 advance: how far the pen moves after it
      10  i16 left bearing: from the pen to the bitmap's left column
      12  i16 top: from the top of the line to the bitmap's top row
      14  u16 width, 16 u16 height of the bitmap
      18  u16 reserved (0)
    kerning table: pair count entries of 12 bytes, by left then right
    code point, strictly increasing
       0  u32 left code point, 4 u32 right code point
       8  i16 adjustment: added to the pen after the left character
      10  u16 reserved (0)
    coverage data: each bitmap width * height bytes, row by row from
    the top, 0 nothing to 255 fully covered.

Kerning comes from the font's own tables (GPOS through Raqm): a pair's
adjustment is how much shorter the pair is than its two characters
laid out apart, measured once in font units and scaled to each size.
"""

import argparse
import os
import struct
import sys

try:
    from PIL import Image, ImageDraw, ImageFont, features
except ImportError:
    sys.exit('render-font.py: Python\'s Pillow (PIL) is needed to render the system\'s proportional font')

MAGIC = b'CVF1'
HEADER_SIZE = 40
GLYPH_ENTRY_SIZE = 20
KERNING_ENTRY_SIZE = 12
FLAG_BOLD = 1
# Measuring kerning at a size this large gives it in font units for
# fonts with 2048 units to the em (DejaVu's), and precise enough for any.
KERNING_MEASURING_SIZE = 2048
REPLACEMENT_CHARACTER = 0xFFFD

# The characters rendered: what the text console's Terminus has for
# western text (ASCII, Latin-1, Latin Extended-A), the typographic
# punctuation, the euro and trade mark signs, the minus sign and the
# replacement character drawn for anything missing. The font must have
# them all (a character it lacks would come out as its empty box).
CHARACTER_RANGES = [
    (0x0020, 0x007E),
    (0x00A0, 0x017F),
    (0x0192, 0x0192),
    (0x02C6, 0x02C7),
    (0x02D8, 0x02DD),
    (0x2013, 0x2014),
    (0x2018, 0x201A),
    (0x201C, 0x201E),
    (0x2020, 0x2022),
    (0x2026, 0x2026),
    (0x2030, 0x2030),
    (0x2039, 0x203A),
    (0x20AC, 0x20AC),
    (0x2122, 0x2122),
    (0x2212, 0x2212),
    (REPLACEMENT_CHARACTER, REPLACEMENT_CHARACTER),
]


def wanted_code_points():
    code_points = []
    for first, last in CHARACTER_RANGES:
        code_points.extend(range(first, last + 1))
    return code_points


def render_glyph(font, code_point, ascent):
    """The glyph's advance, left bearing, top, width, height and coverage."""
    character = chr(code_point)
    advance = int(round(font.getlength(character)))
    size = font.size
    # Drawn with its baseline origin well inside a canvas, then cut down
    # to the pixels it covers.
    canvas_size = 4 * size + 16
    origin_x = size + 8
    origin_y = 2 * size + 8
    canvas = Image.new('L', (canvas_size, canvas_size), 0)
    ImageDraw.Draw(canvas).text((origin_x, origin_y), character, font=font, fill=255, anchor='ls')
    box = canvas.getbbox()
    if box is None:
        return advance, 0, 0, 0, 0, b''
    left, top, right, bottom = box
    coverage = canvas.crop(box).tobytes()
    return advance, left - origin_x, ascent + (top - origin_y), right - left, bottom - top, coverage


def measure_kerning(font_path, code_points):
    """Every pair's adjustment in units of the measuring size, nonzero ones only."""
    if not features.check('raqm'):
        print('render-font.py: Pillow has no Raqm layout here: the font is rendered without kerning',
              file=sys.stderr)
        return {}
    font = ImageFont.truetype(font_path, KERNING_MEASURING_SIZE, layout_engine=ImageFont.Layout.RAQM)
    no_ligatures = ['-liga', '-clig', '-dlig']
    lengths = {code_point: font.getlength(chr(code_point), features=no_ligatures) for code_point in code_points}
    # Only letters, digits and punctuation are kerned in practice; the
    # rest would only make measuring slower.
    kerned = [code_point for code_point in code_points if chr(code_point).isprintable() and code_point != 0x20]
    pairs = {}
    for left in kerned:
        for right in kerned:
            together = font.getlength(chr(left) + chr(right), features=no_ligatures)
            adjustment = together - lengths[left] - lengths[right]
            if abs(adjustment) >= 1:
                pairs[(left, right)] = adjustment
    return pairs


def build_face(font_path, size, bold, code_points, kerning_units):
    font = ImageFont.truetype(font_path, size, layout_engine=ImageFont.Layout.BASIC)
    ascent, descent = font.getmetrics()
    line_height = ascent + descent
    # Just under the baseline, about a fourteenth of the em thick, as
    # the font's own underscore is.
    thickness = max(1, int(round(size / 14)))
    underline_top = ascent + max(1, int(round(size / 12)))
    if underline_top + thickness > line_height:
        underline_top = line_height - thickness

    glyph_table = bytearray()
    coverage_data = bytearray()
    for code_point in code_points:
        advance, left_bearing, top, width, height, coverage = render_glyph(font, code_point, ascent)
        glyph_table += struct.pack('<IIhhhHHH', code_point, len(coverage_data), advance, left_bearing, top,
                                   width, height, 0)
        coverage_data += coverage

    kerning_table = bytearray()
    kerning_count = 0
    for (left, right) in sorted(kerning_units):
        adjustment = int(round(kerning_units[(left, right)] * size / KERNING_MEASURING_SIZE))
        if adjustment == 0:
            continue
        kerning_table += struct.pack('<IIhH', left, right, adjustment, 0)
        kerning_count += 1

    glyph_table_offset = HEADER_SIZE
    kerning_table_offset = glyph_table_offset + len(glyph_table)
    coverage_offset = kerning_table_offset + len(kerning_table)
    flags = FLAG_BOLD if bold else 0
    header = MAGIC + struct.pack('<HHHHhhHHIIIII', HEADER_SIZE, flags, size, line_height, ascent, underline_top,
                                 thickness, len(code_points), kerning_count, glyph_table_offset,
                                 kerning_table_offset, coverage_offset, len(coverage_data))
    assert len(header) == HEADER_SIZE
    return bytes(header + glyph_table + kerning_table + coverage_data)


def parse_sizes(text):
    first, _, last = text.partition('-')
    first = int(first)
    last = int(last) if last else first
    if first < 1 or last < first or last > 255:
        raise argparse.ArgumentTypeError('sizes are FIRST-LAST, from 1 to 255')
    return list(range(first, last + 1))


def main():
    parser = argparse.ArgumentParser(description='Renders a TrueType font into coverage fonts (.cvf).')
    parser.add_argument('--font', required=True, help='the TrueType font')
    parser.add_argument('--bold', action='store_true', help='mark the faces bold')
    parser.add_argument('--sizes', required=True, type=parse_sizes, help='pixel sizes, FIRST-LAST')
    parser.add_argument('--name', required=True, help='file names start with this')
    parser.add_argument('--output', required=True, help='the directory to write into')
    arguments = parser.parse_args()
    if not os.path.isfile(arguments.font):
        sys.exit('render-font.py: ' + arguments.font + ' is not there (set the font\'s path)')
    os.makedirs(arguments.output, exist_ok=True)
    code_points = wanted_code_points()
    kerning_units = measure_kerning(arguments.font, code_points)
    for size in arguments.sizes:
        face = build_face(arguments.font, size, arguments.bold, code_points, kerning_units)
        path = os.path.join(arguments.output, '%s-%d.cvf' % (arguments.name, size))
        with open(path, 'wb') as output:
            output.write(face)


if __name__ == '__main__':
    main()
