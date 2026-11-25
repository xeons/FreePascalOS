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

"""Draws the system's icons and pointers (the set is the project's own
work, drawn here with vector shapes: there are no source pictures).

    make-icons.py ICON_DIRECTORY [POINTER_DIRECTORY]
        every icon as ICON_DIRECTORY/NAME.ico (16, 20, 24, 32, 40, 48,
        64 and 96 pixels) and an index.txt listing them; the pointers as
        POINTER_DIRECTORY/NAME.cur in several sizes
    make-icons.py --sheet FILE.png [SIZE...]
        a contact sheet of every icon at the sizes, to look at
"""

import os
import sys

import cairo

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from iconkit import catalog, icofile, cursors  # noqa: E402
from iconkit import places, folders, filetypes, programs, actions, status, devices, overlays  # noqa: E402,F401
from iconkit import browsing  # noqa: E402,F401


def write_icons(directory):
    os.makedirs(directory, exist_ok=True)
    for name in catalog.ORDER:
        surfaces = [catalog.render(name, size) for size in catalog.SIZES]
        with open(os.path.join(directory, name + '.ico'), 'wb') as output:
            output.write(icofile.icon_file(surfaces))
    with open(os.path.join(directory, 'index.txt'), 'w') as index:
        index.write('# The icons here, one name a line (NAME.ico), and their sizes.\n')
        index.write('sizes ' + ' '.join(str(size) for size in catalog.SIZES) + '\n')
        for name in catalog.ORDER:
            index.write(name + '\n')


def write_pointers(directory):
    os.makedirs(directory, exist_ok=True)
    for name in cursors.ORDER:
        surfaces, hotspots = cursors.render_all(name)
        with open(os.path.join(directory, name + '.cur'), 'wb') as output:
            output.write(icofile.icon_file(surfaces, hotspots))


def write_sheet(file_name, sizes):
    names = list(catalog.ORDER)
    columns = 8
    cell_width = sum(sizes) + 8 * len(sizes) + 8
    cell_height = max(sizes) + 12
    rows = (len(names) + columns - 1) // columns
    pointer_row = max(cursors.SIZES) + 16
    sheet = cairo.ImageSurface(cairo.FORMAT_ARGB32, columns * cell_width, rows * cell_height + pointer_row)
    context = cairo.Context(sheet)
    context.set_source_rgb(0.86, 0.86, 0.93)
    context.paint()
    for index, name in enumerate(names):
        x = (index % columns) * cell_width + 6
        y = (index // columns) * cell_height + 6
        for size in sizes:
            context.set_source_surface(catalog.render(name, size), x, y + max(sizes) - size)
            context.paint()
            x += size + 8
    x = 6
    y = rows * cell_height + 6
    for name in cursors.ORDER:
        surfaces, hotspots = cursors.render_all(name)
        for surface in surfaces:
            context.set_source_surface(surface, x, y)
            context.paint()
            x += surface.get_width() + 4
        x += 12
    sheet.write_to_png(file_name)


def main(arguments):
    if len(arguments) >= 2 and arguments[0] == '--sheet':
        sizes = [int(each) for each in arguments[2:]] or [16, 24, 32, 48, 96]
        write_sheet(arguments[1], sizes)
        return 0
    if len(arguments) not in (1, 2):
        print(__doc__)
        return 2
    write_icons(arguments[0])
    if len(arguments) == 2:
        write_pointers(arguments[1])
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
