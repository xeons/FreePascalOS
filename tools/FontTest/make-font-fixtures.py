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
The font test's fixtures and reference data (tools/FontTest).

    make-font-fixtures.py OUTPUT-DIRECTORY FONTS-DIRECTORY

Writes small TrueType fonts put together byte by byte (fixture.ttf:
simple, curved and composite glyphs, a format 4 and a format 12
character map, a kern table; fixture-format4.ttf: the format 4 map
only, long loca offsets; fixture-gpos.ttf: GPOS pair kerning, format 1
and format 2 through an extension lookup), broken copies of them that
must be refused, and references.txt: what FreeType (and HarfBuzz,
through Pillow's Raqm layout) make of these fonts and of DejaVu Sans
and DejaVu Sans Mono from FONTS-DIRECTORY: character map lookups,
advances, kern table pairs, GPOS kerning, line metrics and glyphs
rendered unhinted and anti-aliased at several sizes and subpixel
offsets. One record a line:

    font NAME FILE
    cmap NAME CODEPOINT GLYPH
    advance NAME GLYPH UNITS
    kern NAME LEFT-GLYPH RIGHT-GLYPH UNITS            (the kern table)
    gpos NAME LEFT-CODEPOINT RIGHT-CODEPOINT UNITS    (HarfBuzz, +-1)
    metrics NAME PIXELS ASCENT DESCENT                (Pillow's FreeType)
    glyph NAME GLYPH PIXELS OFFSET64 LEFT TOP WIDTH HEIGHT HEX-COVERAGE
    refuse FILE                                       (must not open)
    badglyph NAME GLYPH                               (opens; glyph refused)
"""

import os
import struct
import sys

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import freetypereference  # noqa: E402

try:
    from PIL import ImageFont, features
except ImportError:
    ImageFont = None
    features = None

UNITS_PER_EM = 1000


# --- Building fonts -------------------------------------------------------

def simple_glyph(contours):
    """glyf data for contours of (x, y, on_curve) points."""
    points = [point for contour in contours for point in contour]
    xs = [point[0] for point in points]
    ys = [point[1] for point in points]
    data = struct.pack('>hhhhh', len(contours), min(xs), min(ys), max(xs), max(ys))
    end = -1
    for contour in contours:
        end += len(contour)
        data += struct.pack('>H', end)
    data += struct.pack('>H', 0)
    flags = b''
    x_data = b''
    y_data = b''
    previous_x = previous_y = 0
    for x, y, on_curve in points:
        flag = 1 if on_curve else 0
        delta_x = x - previous_x
        delta_y = y - previous_y
        if delta_x == 0:
            flag |= 0x10
        elif -255 <= delta_x <= 255:
            flag |= 0x02 | (0x10 if delta_x > 0 else 0)
            x_data += struct.pack('>B', abs(delta_x))
        else:
            x_data += struct.pack('>h', delta_x)
        if delta_y == 0:
            flag |= 0x20
        elif -255 <= delta_y <= 255:
            flag |= 0x04 | (0x20 if delta_y > 0 else 0)
            y_data += struct.pack('>B', abs(delta_y))
        else:
            y_data += struct.pack('>h', delta_y)
        flags += struct.pack('>B', flag)
        previous_x, previous_y = x, y
    return data + flags + x_data + y_data


def composite_glyph(components, box=(0, 0, 1000, 1000)):
    """glyf data for components (glyph, dx, dy, transform), transform
    None, a scale, an (x, y) scale or a 2x2 (xx, yx, xy, yy)."""
    data = struct.pack('>hhhhh', -1, *box)
    for index, (glyph, dx, dy, transform) in enumerate(components):
        flags = 0x0002  # offsets
        arguments = b''
        if -128 <= dx <= 127 and -128 <= dy <= 127:
            arguments = struct.pack('>bb', dx, dy)
        else:
            flags |= 0x0001
            arguments = struct.pack('>hh', dx, dy)
        scale = b''
        if transform is None:
            pass
        elif isinstance(transform, (int, float)):
            flags |= 0x0008
            scale = struct.pack('>h', round(transform * 16384))
        elif len(transform) == 2:
            flags |= 0x0040
            scale = struct.pack('>hh', *(round(value * 16384) for value in transform))
        else:
            flags |= 0x0080
            scale = struct.pack('>hhhh', *(round(value * 16384) for value in transform))
        if index < len(components) - 1:
            flags |= 0x0020
        data += struct.pack('>HH', flags, glyph) + arguments + scale
    return data


def format4_subtable(mapping):
    """A format 4 cmap subtable: the first half of the code points by
    delta, the rest through the glyph array."""
    codes = sorted(code for code in mapping if code <= 0xFFFF)
    segments = []
    for code in codes:
        if segments and segments[-1][1] == code - 1 and segments[-1][2] == (len(segments) % 2 == 1):
            segments[-1][1] = code
        else:
            segments.append([code, code, len(segments) % 2 == 1])
    segments.append([0xFFFF, 0xFFFF, False])
    count = len(segments)
    ends = starts = deltas = offsets = b''
    glyph_array = b''
    glyph_array_words = []
    for index, (first, last, use_array) in enumerate(segments):
        ends += struct.pack('>H', last)
        starts += struct.pack('>H', first)
        if first == 0xFFFF:
            deltas += struct.pack('>H', 1)
            offsets += struct.pack('>H', 0)
        elif use_array:
            deltas += struct.pack('>H', 0)
            # From this offset word to the glyph array entry.
            position = 2 * (count - index) + 2 * len(glyph_array_words)
            offsets += struct.pack('>H', position)
            glyph_array_words.extend(mapping[code] for code in range(first, last + 1))
        else:
            deltas += struct.pack('>H', (mapping[first] - first) & 0xFFFF)
            offsets += struct.pack('>H', 0)
    for word in glyph_array_words:
        glyph_array += struct.pack('>H', word)
    body = struct.pack('>HHHH', 2 * count, 0, 0, 0) + ends + struct.pack('>H', 0) + starts + deltas + offsets + \
        glyph_array
    return struct.pack('>HHH', 4, 6 + len(body), 0) + body


def format12_subtable(mapping):
    groups = []
    for code in sorted(mapping):
        if groups and groups[-1][1] == code - 1 and groups[-1][2] + (code - groups[-1][0]) == mapping[code]:
            groups[-1][1] = code
        else:
            groups.append([code, code, mapping[code]])
    data = b''.join(struct.pack('>III', *group) for group in groups)
    return struct.pack('>HHIII', 12, 0, 16 + len(data), 0, len(groups)) + data


def cmap_table(mapping, with_format12):
    subtables = [(3, 1, format4_subtable(mapping))]
    if with_format12:
        subtables.append((3, 10, format12_subtable(mapping)))
    header = struct.pack('>HH', 0, len(subtables))
    offset = 4 + 8 * len(subtables)
    records = b''
    data = b''
    for platform, encoding, subtable in subtables:
        records += struct.pack('>HHI', platform, encoding, offset + len(data))
        data += subtable
    return header + records + data


def kern_table(pairs):
    pairs = sorted(pairs.items())
    count = len(pairs)
    body = struct.pack('>HHHH', count, 6, 0, 0)
    for (left, right), value in pairs:
        body += struct.pack('>HHh', left, right, value)
    subtable = struct.pack('>HHH', 0, 6 + len(body), 0x0001) + body
    return struct.pack('>HH', 0, 1) + subtable


def coverage_format1(glyphs):
    return struct.pack('>HH', 1, len(glyphs)) + b''.join(struct.pack('>H', glyph) for glyph in glyphs)


def gpos_table(format1_pairs, class_first, class_second, class_value):
    """GPOS with one kern feature: lookup 0 a pair adjustment (format 1)
    for format1_pairs, lookup 1 an extension holding a format 2 subtable
    (first glyphs class_first in class 1, second class_second in class
    1, that pair of classes adjusted by class_value)."""
    value_format = 0x0004
    # Format 1.
    firsts = sorted({left for left, right in format1_pairs})
    pair_sets = []
    for left in firsts:
        records = sorted((right, value) for (l, right), value in format1_pairs.items() if l == left)
        pair_sets.append(struct.pack('>H', len(records)) +
                         b''.join(struct.pack('>Hh', right, value) for right, value in records))
    header_size = 10 + 2 * len(pair_sets)
    coverage = coverage_format1(firsts)
    offsets = []
    position = header_size + len(coverage)
    for pair_set in pair_sets:
        offsets.append(position)
        position += len(pair_set)
    format1 = struct.pack('>HHHHH', 1, header_size, value_format, 0, len(pair_sets)) + \
        b''.join(struct.pack('>H', offset) for offset in offsets) + coverage + b''.join(pair_sets)
    # Format 2: two classes each way.
    class_records = struct.pack('>hh', 0, 0) + struct.pack('>hh', 0, class_value)
    header_size = 16 + len(class_records)
    coverage = coverage_format1(sorted(class_first))

    def class_definition(glyphs):
        glyphs = sorted(glyphs)
        first = glyphs[0]
        classes = [1 if glyph in glyphs else 0 for glyph in range(first, glyphs[-1] + 1)]
        return struct.pack('>HHH', 1, first, len(classes)) + b''.join(struct.pack('>H', value) for value in classes)

    first_classes = class_definition(class_first)
    second_classes = class_definition(class_second)
    coverage_offset = header_size
    first_offset = coverage_offset + len(coverage)
    second_offset = first_offset + len(first_classes)
    format2 = struct.pack('>HHHHHHHH', 2, coverage_offset, value_format, 0, first_offset, second_offset, 2, 2) + \
        class_records + coverage + first_classes + second_classes
    extension = struct.pack('>HHI', 1, 2, 8) + format2
    lookup0 = struct.pack('>HHHH', 2, 0, 1, 8) + format1
    lookup1 = struct.pack('>HHHH', 9, 0, 1, 8) + extension
    lookup_list = struct.pack('>HHH', 2, 6, 6 + len(lookup0)) + lookup0 + lookup1
    feature = struct.pack('>HHHH', 0, 2, 0, 1)
    feature_list = struct.pack('>H4sH', 1, b'kern', 8) + feature
    lang_sys = struct.pack('>HHHH', 0, 0xFFFF, 1, 0)
    script = struct.pack('>HH', 4, 0) + lang_sys
    script_list = struct.pack('>H4sH', 1, b'DFLT', 8) + script
    header_size = 10
    script_offset = header_size
    feature_offset = script_offset + len(script_list)
    lookup_offset = feature_offset + len(feature_list)
    return struct.pack('>IHHH', 0x00010000, script_offset, feature_offset, lookup_offset) + script_list + \
        feature_list + lookup_list


def name_table():
    names = [(1, 'Fixture'), (2, 'Regular'), (4, 'Fixture Regular'), (6, 'Fixture-Regular')]
    strings = b''
    records = b''
    for name_id, text in names:
        encoded = text.encode('utf-16-be')
        records += struct.pack('>HHHHHH', 3, 1, 0x409, name_id, len(encoded), len(strings))
        strings += encoded
    return struct.pack('>HHH', 0, len(names), 6 + len(records)) + records + strings


def build_font(glyphs, advances, mapping, long_loca=False, with_format12=True, kern=None, gpos=None,
               advance_count=None, ascender=800, descender=-200):
    glyph_count = len(glyphs)
    if advance_count is None:
        advance_count = glyph_count
    glyf = b''
    loca_offsets = []
    for data in glyphs:
        loca_offsets.append(len(glyf))
        glyf += data
        if len(glyf) % 2:
            glyf += b'\0'
    loca_offsets.append(len(glyf))
    if long_loca:
        loca = b''.join(struct.pack('>I', offset) for offset in loca_offsets)
    else:
        loca = b''.join(struct.pack('>H', offset // 2) for offset in loca_offsets)
    head = struct.pack('>IIIIHHqqhhhhHHhhh', 0x00010000, 0x00010000, 0, 0x5F0F3CF5, 0x000B, UNITS_PER_EM, 0, 0,
                       -100, -250, 1100, 1000, 0, 8, 2, 1 if long_loca else 0, 0)
    hhea = struct.pack('>IhhhHhhhhhhhhhhhH', 0x00010000, ascender, descender, 0, max(advances), 0, 0, 1000, 1, 0,
                       0, 0, 0, 0, 0, 0, advance_count)
    max_points = 64
    maxp = struct.pack('>IHHHHHHHHHHHHHH', 0x00010000, glyph_count, max_points, 8, max_points, 8, 2, 0, 0, 0, 0,
                       0, 0, 4, 3)
    hmtx = b''
    for index in range(glyph_count):
        if index < advance_count:
            hmtx += struct.pack('>Hh', advances[index], 0)
        else:
            hmtx += struct.pack('>h', 0)
    os2 = struct.pack('>HhHHHhhhhhhhhhhh10sIIII4sHHHhhhHHII', 1, 500, 400, 5, 0, 650, 700, 0, 140, 650, 700, 0,
                      480, 50, 250, 0, b'\0' * 10, 0, 0, 0, 0, b'NONE', 0x40, 0x20, 0xFFFF, ascender, descender,
                      0, 1000, 300, 1, 0)
    post = struct.pack('>IIhhIIIII', 0x00030000, 0, -120, 60, 0, 0, 0, 0, 0)
    tables = {
        b'head': head, b'hhea': hhea, b'maxp': maxp, b'hmtx': hmtx, b'loca': loca, b'glyf': glyf,
        b'cmap': cmap_table(mapping, with_format12), b'OS/2': os2, b'post': post, b'name': name_table(),
    }
    if kern:
        tables[b'kern'] = kern_table(kern)
    if gpos:
        tables[b'GPOS'] = gpos
    tags = sorted(tables)
    count = len(tags)
    search_range = 1
    selector = 0
    while search_range * 2 <= count:
        search_range *= 2
        selector += 1
    directory = struct.pack('>IHHHH', 0x00010000, count, search_range * 16, selector, count * 16 - search_range * 16)
    offset = 12 + 16 * count
    body = b''
    entries = b''
    for index, tag in enumerate(tags):
        data = tables[tag]
        checksum = 0
        padded = data + b'\0' * (-len(data) % 4)
        for word in range(0, len(padded), 4):
            checksum = (checksum + struct.unpack('>I', padded[word:word + 4])[0]) & 0xFFFFFFFF
        entries += struct.pack('>4sIII', tag, checksum, offset + len(body), len(data))
        # Padded to four bytes, all but the last: the file ends where its
        # last table does, so every truncation cuts a table.
        body += data if index == count - 1 else padded
    return directory + entries + body


def fixture_glyphs():
    """Glyphs: 0 the missing box, 1 'A' (straight lines, a hole), 2 'B'
    (quadratic curves, on-curve points implied between off-curve ones),
    3 'C' (composite: A and B side by side, B halved), 4 'D' (composite
    with a 2x2 transform), 5 space (empty), 6 'E' (composite of the
    composite C, moved), 7 a smiley for U+1F600 (only in format 12)."""
    box = simple_glyph([[(50, 0, True), (50, 700, True), (450, 700, True), (450, 0, True)],
                        [(100, 50, True), (400, 50, True), (400, 650, True), (100, 650, True)]])
    letter_a = simple_glyph([[(0, 0, True), (250, 700, True), (500, 0, True), (380, 0, True), (250, 400, True),
                              (120, 0, True)]])
    letter_b = simple_glyph([[(250, 0, False), (500, 0, False), (500, 350, True), (500, 700, False),
                              (250, 700, True), (0, 700, False), (0, 350, True), (0, 0, False)]])
    letter_c = composite_glyph([(1, 0, 0, None), (2, 520, 100, 0.5)])
    letter_d = composite_glyph([(1, 30, -40, (0.75, 0.25, -0.25, 0.75))])
    space = b''
    letter_e = composite_glyph([(3, 300, 200, None)])
    smiley = simple_glyph([[(100, 100, True), (100, 600, True), (600, 600, True), (600, 100, True)]])
    return [box, letter_a, letter_b, letter_c, letter_d, space, letter_e, smiley]


FIXTURE_MAPPING = {0x20: 5, 0x41: 1, 0x42: 2, 0x43: 3, 0x44: 4, 0x45: 6, 0xE9: 3, 0x1F600: 7}
FIXTURE_ADVANCES = [500, 520, 540, 800, 600, 250, 900, 700]


def write_fixtures(output):
    glyphs = fixture_glyphs()
    fixtures = {}
    fixtures['fixture'] = build_font(glyphs, FIXTURE_ADVANCES, FIXTURE_MAPPING,
                                     kern={(1, 2): -50, (2, 1): 30, (3, 4): -120}, advance_count=6)
    fixtures['fixture-format4'] = build_font(glyphs, FIXTURE_ADVANCES, FIXTURE_MAPPING, long_loca=True,
                                             with_format12=False)
    fixtures['fixture-gpos'] = build_font(glyphs, FIXTURE_ADVANCES, FIXTURE_MAPPING,
                                          gpos=gpos_table({(1, 2): -70, (2, 1): 25}, [3, 4], [1], -40))
    for name, data in fixtures.items():
        with open(os.path.join(output, name + '.ttf'), 'wb') as file:
            file.write(data)
    return fixtures


# --- Broken fonts ---------------------------------------------------------

def table_entry(data, tag):
    count = struct.unpack('>H', data[4:6])[0]
    for index in range(count):
        entry = 12 + 16 * index
        if data[entry:entry + 4] == tag:
            offset, length = struct.unpack('>II', data[entry + 8:entry + 16])
            return entry, offset, length
    raise KeyError(tag)


def patched(data, position, packed):
    return data[:position] + packed + data[position + len(packed):]


def broken_fonts(good):
    """(name, data) of fonts that must be refused."""
    fonts = []
    fonts.append(('bad-version', patched(good, 0, b'OTTO')))
    entry, head, _ = table_entry(good, b'head')
    fonts.append(('bad-head-magic', patched(good, head + 12, struct.pack('>I', 0x12345678))))
    fonts.append(('zero-units-per-em', patched(good, head + 18, struct.pack('>H', 0))))
    fonts.append(('bad-loca-format', patched(good, head + 50, struct.pack('>h', 2))))
    entry, _, _ = table_entry(good, b'glyf')
    fonts.append(('table-past-the-end', patched(good, entry + 8, struct.pack('>I', len(good) - 4))))
    entry, _, _ = table_entry(good, b'cmap')
    fonts.append(('no-character-map', patched(good, entry, b'cmaX')))
    entry, _, _ = table_entry(good, b'loca')
    fonts.append(('no-loca', patched(good, entry, b'locX')))
    _, hhea, _ = table_entry(good, b'hhea')
    fonts.append(('no-advances', patched(good, hhea + 34, struct.pack('>H', 0))))
    fonts.append(('more-advances-than-glyphs', patched(good, hhea + 34, struct.pack('>H', 60000))))
    _, maxp, _ = table_entry(good, b'maxp')
    fonts.append(('no-glyphs', patched(good, maxp + 4, struct.pack('>H', 0))))
    fonts.append(('more-glyphs-than-loca', patched(good, maxp + 4, struct.pack('>H', 500))))
    _, loca, _ = table_entry(good, b'loca')
    fonts.append(('loca-out-of-order', patched(good, loca + 4, struct.pack('>H', 0x7FFF))))
    _, cmap, _ = table_entry(good, b'cmap')
    beyond = struct.pack('>I', 0x00FFFFFF)
    fonts.append(('cmap-subtable-past-the-end', patched(patched(good, cmap + 8, beyond), cmap + 16, beyond)))
    fonts.append(('too-many-tables', patched(good, 4, struct.pack('>H', 4000))))
    fonts.append(('empty', b''))
    return fonts


def broken_glyph_fonts(good):
    """(name, data, glyph) of fonts that open but whose glyph must be refused."""
    fonts = []
    _, loca, _ = table_entry(good, b'loca')
    _, glyf, _ = table_entry(good, b'glyf')
    glyph_offset = 2 * struct.unpack('>H', good[loca + 2 * 6:loca + 2 * 6 + 2])[0]
    # Glyph 6 (a composite of 3) made to contain itself.
    position = glyf + glyph_offset + 10 + 2
    fonts.append(('composite-loop', patched(good, position, struct.pack('>H', 6)), 6))
    # Glyph 3's component names a glyph past the font.
    glyph_offset = 2 * struct.unpack('>H', good[loca + 2 * 3:loca + 2 * 3 + 2])[0]
    fonts.append(('component-past-the-font', patched(good, glyf + glyph_offset + 12, struct.pack('>H', 999)), 3))
    # Glyph 1's contour end points past what its data holds.
    glyph_offset = 2 * struct.unpack('>H', good[loca + 2 * 1:loca + 2 * 1 + 2])[0]
    fonts.append(('points-past-the-data', patched(good, glyf + glyph_offset + 10, struct.pack('>H', 3000)), 1))
    return fonts


# --- References -----------------------------------------------------------

class References:
    def __init__(self, path):
        self.file = open(path, 'w')

    def add(self, *fields):
        self.file.write(' '.join(str(field) for field in fields) + '\n')

    def close(self):
        self.file.close()


def add_glyph(references, name, face, glyph, pixels, offset_64):
    left, top, width, height, coverage, _ = face.render(glyph, pixels, offset_64)
    references.add('glyph', name, glyph, pixels, offset_64, left, top, width, height, coverage.hex() or '-')


def add_font_references(references, name, data, code_points, glyph_sizes, pairs):
    face = freetypereference.open_face(data)
    glyph_count = face.glyph_count()
    for code_point in code_points:
        references.add('cmap', name, code_point, face.char_index(code_point))
    for glyph in range(min(glyph_count, 400)):
        references.add('advance', name, glyph, face.advance_units(glyph))
    for left, right in pairs:
        references.add('kern', name, face.char_index(left), face.char_index(right),
                       face.kerning(face.char_index(left), face.char_index(right)))
    for code_point, sizes in glyph_sizes:
        glyph = face.char_index(code_point)
        for pixels in sizes:
            for offset_64 in (0, 16, 32, 48):
                add_glyph(references, name, face, glyph, pixels, offset_64)
    return face


def add_layout_references(references, name, path, pairs, sizes):
    """Kerning through HarfBuzz (Pillow's Raqm layout) and line metrics."""
    if ImageFont is None:
        return
    if features.check('raqm'):
        units = freetypereference.open_face(open(path, 'rb').read()).units_per_em()
        font = ImageFont.truetype(path, units, layout_engine=ImageFont.Layout.RAQM)
        no_ligatures = ['-liga', '-clig', '-dlig']
        for left, right in pairs:
            together = font.getlength(chr(left) + chr(right), features=no_ligatures)
            apart = font.getlength(chr(left), features=no_ligatures) + font.getlength(chr(right), features=no_ligatures)
            references.add('gpos', name, left, right, round(together - apart))
    for pixels in sizes:
        ascent, descent = ImageFont.truetype(path, pixels, layout_engine=ImageFont.Layout.BASIC).getmetrics()
        references.add('metrics', name, pixels, ascent, descent)


SAMPLE_TEXT = 'AaBbGgHhOoQqRrSsWwXxeg@&%019?.,;'
KERNED_PAIRS = [(ord(left), ord(right)) for left, right in
                ('AV', 'AT', 'To', 'Ty', 'LT', 'Yo', 'VA', 'P.', 'F,', 'rv', 'av', 'AB', 'HH', 'oo', 'Wa', 'y.')]


def main():
    if len(sys.argv) != 3:
        sys.exit('usage: make-font-fixtures.py OUTPUT-DIRECTORY FONTS-DIRECTORY')
    output, fonts_directory = sys.argv[1], sys.argv[2]
    os.makedirs(output, exist_ok=True)
    try:
        fixtures = write_fixtures(output)
        references = References(os.path.join(output, 'references.txt'))
        # The fixtures.
        fixture_code_points = [0x20, 0x41, 0x42, 0x43, 0x44, 0x45, 0x46, 0xE9, 0x1F600, 0x1F601, 0xFFFF]
        fixture_glyphs_sizes = [(code_point, [10, 23]) for code_point in (0x41, 0x42, 0x43, 0x44, 0x45, 0x1F600)]
        fixture_pairs = [(0x41, 0x42), (0x42, 0x41), (0x43, 0x44), (0x41, 0x41)]
        for name in ('fixture', 'fixture-format4', 'fixture-gpos'):
            references.add('font', name, name + '.ttf')
            add_font_references(references, name, fixtures[name], fixture_code_points,
                                fixture_glyphs_sizes if name == 'fixture' else [], fixture_pairs)
        add_layout_references(references, 'fixture-gpos', os.path.join(output, 'fixture-gpos.ttf'),
                              fixture_pairs + [(0x44, 0x41), (0x43, 0x41), (0x45, 0x41)], [])
        # Broken fonts.
        for name, data in broken_fonts(fixtures['fixture']):
            with open(os.path.join(output, name + '.ttf'), 'wb') as file:
                file.write(data)
            references.add('refuse', name + '.ttf')
        for name, data, glyph in broken_glyph_fonts(fixtures['fixture']):
            with open(os.path.join(output, name + '.ttf'), 'wb') as file:
                file.write(data)
            references.add('font', name, name + '.ttf')
            references.add('badglyph', name, glyph)
        # DejaVu Sans and DejaVu Sans Mono.
        code_points = list(range(0x20, 0x7F)) + list(range(0xA0, 0x180)) + \
            [0x2013, 0x2014, 0x2018, 0x201C, 0x2026, 0x20AC, 0x2122, 0x2212, 0x3B1, 0x416, 0xFFFD, 0x1F600,
             0x10FFFF, 0x1D400]
        sample_sizes = [(ord(character), [9, 12, 17, 31]) for character in SAMPLE_TEXT] + \
            [(0xE9, [12, 20]), (0x20AC, [12]), (0x1EA0, [14])]
        for name, file_name in (('sans', 'dejavu-sans/DejaVuSans.ttf'), ('sans-bold', 'dejavu-sans/DejaVuSans-Bold.ttf'),
                                ('mono', 'dejavu-sans-mono/DejaVuSansMono.ttf')):
            path = os.path.abspath(os.path.join(fonts_directory, file_name))
            references.add('font', name, path)
            data = open(path, 'rb').read()
            add_font_references(references, name, data, code_points, sample_sizes if name != 'mono' else
                                [(ord('m'), [12]), (ord('0'), [12, 15])], KERNED_PAIRS)
            add_layout_references(references, name, path, KERNED_PAIRS, [9, 10, 11, 12, 13, 15, 16, 18, 20, 24,
                                                                        32, 40])
        references.close()
    except freetypereference.FreeTypeMissing as error:
        sys.exit('make-font-fixtures.py: ' + str(error))


if __name__ == '__main__':
    main()
