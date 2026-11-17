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

"""The catalogue of icons: every icon's name (its file is NAME.ico in
/usr/share/icons) and the function that draws it on a Pen.

    @icon('folder', 'Folder')
    def folder(pen): ...

registers one; an icon may have other names that draw the same (an
alias list), and belongs to a group (for the contact sheet only).
"""

import cairo

from .pen import Pen

SIZES = (16, 20, 24, 32, 40, 48, 64, 96)

ICONS = {}
ORDER = []
GROUPS = {}


class IconDefinition:
    def __init__(self, name, title, group, draw):
        self.name = name
        self.title = title
        self.group = group
        self.draw = draw


_current_group = ['Other']


def group(name):
    """The group icons registered from here on are in."""
    _current_group[0] = name


def icon(name, title=None, aliases=()):
    def register(draw):
        for each in (name,) + tuple(aliases):
            if each in ICONS:
                raise ValueError('icon %s defined twice' % each)
            definition = IconDefinition(each, title or each, _current_group[0], draw)
            ICONS[each] = definition
            ORDER.append(each)
            GROUPS.setdefault(_current_group[0], []).append(each)
        return draw
    return register


def render(name, size):
    """Icon name drawn at size x size pixels: an ARGB32 surface."""
    surface = cairo.ImageSurface(cairo.FORMAT_ARGB32, size, size)
    context = cairo.Context(surface)
    pen = Pen(context, size)
    ICONS[name].draw(pen)
    surface.flush()
    return surface
