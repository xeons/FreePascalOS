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

"""Writing ICO and CUR files from cairo surfaces.

Entries up to 48 pixels are 32-bit DIBs (BGRA, bottom-up, with the
1-bit mask after them, as icons always had); larger ones are whole PNG
files, which is what icons of that size usually hold. Both keep the
full alpha channel. A cursor's entries carry their hotspot where an
icon's have planes and bits per pixel.
"""

import io
import struct

LARGEST_DIB_ENTRY = 48


def unpremultiplied_bgra(surface):
    """The pixels of an ARGB32 surface, top row first, as straight
    (not premultiplied) BGRA bytes."""
    surface.flush()
    width = surface.get_width()
    height = surface.get_height()
    stride = surface.get_stride()
    data = bytes(surface.get_data())
    rows = []
    for y in range(height):
        row = bytearray(width * 4)
        for x in range(width):
            offset = y * stride + x * 4
            # Little-endian ARGB32: B, G, R, A in memory, premultiplied.
            blue, green, red, alpha = data[offset:offset + 4]
            if 0 < alpha < 255:
                blue = min(255, (blue * 255 + alpha // 2) // alpha)
                green = min(255, (green * 255 + alpha // 2) // alpha)
                red = min(255, (red * 255 + alpha // 2) // alpha)
            row[x * 4:x * 4 + 4] = bytes((blue, green, red, alpha))
        rows.append(bytes(row))
    return rows


def dib_entry(surface):
    width = surface.get_width()
    height = surface.get_height()
    rows = unpremultiplied_bgra(surface)
    header = struct.pack('<IiiHHIIiiII', 40, width, height * 2, 1, 32, 0, 0, 0, 0, 0, 0)
    colours = b''.join(reversed(rows))
    # The mask: a bit set where the picture is wholly clear, rows padded
    # to four bytes, bottom row first like the colours.
    mask_stride = ((width + 31) // 32) * 4
    mask = bytearray()
    for row in reversed(rows):
        line = bytearray(mask_stride)
        for x in range(width):
            if row[x * 4 + 3] == 0:
                line[x // 8] |= 0x80 >> (x % 8)
        mask += line
    return header + colours + bytes(mask)


def png_entry(surface):
    buffer = io.BytesIO()
    surface.write_to_png(buffer)
    return buffer.getvalue()


def icon_file(surfaces, hotspots=None):
    """An ICO file of the surfaces (smallest first is customary), or a
    CUR file when hotspots (one (x, y) per surface) are given."""
    is_cursor = hotspots is not None
    entries = []
    for surface in surfaces:
        if surface.get_width() <= LARGEST_DIB_ENTRY:
            entries.append(dib_entry(surface))
        else:
            entries.append(png_entry(surface))
    header = struct.pack('<HHH', 0, 2 if is_cursor else 1, len(surfaces))
    directory = b''
    offset = 6 + 16 * len(surfaces)
    for index, surface in enumerate(surfaces):
        width = surface.get_width()
        height = surface.get_height()
        if is_cursor:
            first, second = hotspots[index]
        else:
            first, second = 1, 32
        directory += struct.pack('<BBBBHHII', width % 256, height % 256, 0, 0, first, second,
                                 len(entries[index]), offset)
        offset += len(entries[index])
    return header + directory + b''.join(entries)
