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

"""Overlays: marks drawn over another icon, the same size as it and
clear except in a corner: shortcut (a curved arrow on a white tile, at
the bottom left), locked (a padlock), synced (a green tick), updating
(chasing arrows) and attention (a red exclamation), at the bottom
right. Each overlay's mark grows a little at the small sizes so it
stays readable."""

from .catalog import icon, group
from .shapes import (badge, padlock, rect_path, glyph_check, glyph_arrows_round, glyph_exclamation, glyph_shortcut,
                     BLUE, BLUE_DEEP, GREEN, RED, ORANGE, INK, GOLD)

group('Overlays')


def corner_radius(pen):
    return 9.0 if not pen.small else 11.5


@icon('overlay-shortcut', 'Shortcut')
def draw_shortcut(pen):
    size = 20.0 if not pen.small else 24.0
    pen.shape(rect_path(1.5, 46.5 - size, size, size, 2.5), pen.vertical('#ffffff', '#dfe6f2', 46.5 - size, 46.5),
              INK)
    glyph_shortcut(pen, 1.5 + size / 2, 46.5 - size / 2, size * 0.5, BLUE_DEEP)


@icon('overlay-locked', 'Locked')
def draw_locked(pen):
    size = 16.0 if not pen.small else 20.0
    padlock(pen, 46.0 - size - 1.0, 46.0 - size * 1.1, size, GOLD)


def corner_badge(pen, colour, glyph):
    radius = corner_radius(pen)
    badge(pen, 47.0 - radius - 1.0, 47.0 - radius - 1.0, radius, colour, glyph)


@icon('overlay-synced', 'Synced')
def draw_synced(pen):
    corner_badge(pen, GREEN, glyph_check)


@icon('overlay-updating', 'Updating')
def draw_updating(pen):
    corner_badge(pen, '#2fa84a', glyph_arrows_round)


@icon('overlay-attention', 'Attention')
def draw_attention(pen):
    corner_badge(pen, RED, glyph_exclamation)
