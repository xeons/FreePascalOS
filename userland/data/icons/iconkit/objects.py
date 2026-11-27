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

"""Objects several icons share: a monitor, a computer's tower, a
drive's slab, a loudspeaker, a star."""

import math

from .pen import Projection, lighter, darker, outline_of, mix
from .shapes import (box, plane_shape, plane_stroke, poly_path, rect_path, circle_path, sphere, sphere_gloss,
                     SILVER, SILVER_TOP, SILVER_SIDE, SILVER_OUTLINE, BLUE, BLUE_LIGHT, BLUE_DEEP, NAVY, TEAL, INK,
                     GREEN, CHARCOAL, GOLD, GOLD_LIGHT, GOLD_DEEP, GOLD_OUTLINE)

BEZEL = '#4f78b8'
SCREEN_TOP = '#8ff0ff'
SCREEN_BOTTOM = '#1a6fc0'


def screen_paint(pen, top, bottom):
    return pen.linear(0, top, 0, bottom, [(0, SCREEN_TOP), (0.5, '#33a6e0'), (1, SCREEN_BOTTOM)])


def monitor(pen, x, y, width, height, depth=4.0, stand=True, content=None, bezel=BEZEL):
    """A monitor whose front's bottom left is at (x, y); content(pen, w, h)
    draws on the screen in face coordinates (u right, v down from the
    screen's top left)."""
    if stand:
        neck = Projection(x + width * 0.5 - 3.0, y + 5.0)
        box(pen, neck, 6.0, 3.0, 6.0, SILVER, SILVER_OUTLINE, gloss=False)
        base = Projection(x + width * 0.5 - 8.0, y + 7.5)
        box(pen, base, 16.0, 7.0, 2.0, SILVER, SILVER_OUTLINE, gloss=False)
    projection = Projection(x, y)
    box(pen, projection, width, depth, height, bezel, outline_of(bezel), top=lighter(bezel, 0.5),
        side=darker(bezel, 0.3))
    margin = 2.2 if not pen.small else 2.6
    face = projection.front_matrix(0)
    sw = width - 2 * margin
    sh = height - 2 * margin
    screen = rect_path(margin, -height + margin, sw, sh, 0.8)
    plane_shape(pen, face, screen, screen_paint(pen, -height + margin, -margin), INK, pen.thin)
    ctx = pen.ctx
    if content is not None:
        ctx.save()
        ctx.transform(face)
        ctx.new_path()
        pen.rounded(margin, -height + margin, sw, sh, 0.8)
        ctx.clip()
        ctx.translate(margin, -height + margin)
        content(pen, sw, sh)
        ctx.restore()
    # The glass's sheen: a diagonal band of light.
    if not pen.tiny:
        ctx.save()
        ctx.transform(face)
        ctx.new_path()
        pen.rounded(margin, -height + margin, sw, sh, 0.8)
        ctx.clip()
        ctx.new_path()
        pen.polygon([(margin, -height + margin), (margin + sw * 0.75, -height + margin),
                     (margin + sw * 0.3, -margin - sh * 0.35), (margin, -margin - sh * 0.25)])
        ctx.set_source_rgba(1, 1, 1, 0.28)
        ctx.fill()
        ctx.restore()
    return projection


def tower(pen, x, y, width, height, depth=10.0, colour=SILVER):
    projection = Projection(x, y)
    box(pen, projection, width, depth, height, colour, SILVER_OUTLINE, top=SILVER_TOP, side=SILVER_SIDE)
    face = projection.front_matrix(0)
    # Two drive bays and a power light.
    for index in range(2 if not pen.small else 1):
        top = -height + 3.0 + index * 4.0
        plane_shape(pen, face, rect_path(1.6, top, width - 3.2, 2.6, 0.4), '#bfc5cf', SILVER_OUTLINE, pen.thin)
    plane_shape(pen, face, circle_path(width / 2, -4.0, 1.1 if not pen.small else 1.5), '#45d64a', None)
    return projection


def slab(pen, x, y, width, depth, height, colour=SILVER, outline=SILVER_OUTLINE):
    projection = Projection(x, y)
    box(pen, projection, width, depth, height, colour, outline, top=SILVER_TOP if colour == SILVER else None,
        side=SILVER_SIDE if colour == SILVER else None)
    return projection


def drive_light(pen, projection, u, v, colour='#45e04a'):
    face = projection.front_matrix(0)
    plane_shape(pen, face, circle_path(u, v, 1.3 if not pen.small else 1.8), colour, '#14501a', pen.thin * 0.8)


def loudspeaker(pen, x, y, size, colour='#5b6577'):
    """A loudspeaker facing right, its box's left middle at (x, y)."""
    s = size
    points = [(x, y - s * 0.22), (x + s * 0.3, y - s * 0.22), (x + s * 0.68, y - s * 0.55),
              (x + s * 0.68, y + s * 0.55), (x + s * 0.3, y + s * 0.22), (x, y + s * 0.22)]
    pen.shape(poly_path(points), pen.vertical(lighter(colour, 0.45), darker(colour, 0.25), y - s * 0.55,
                                               y + s * 0.55), INK)
    if not pen.tiny:
        pen.gloss(poly_path(points), y - s * 0.55, y, 0.4)


def sound_waves(pen, x, y, size, count=2, colour=BLUE):
    ctx = pen.ctx
    width = size * 0.11 if not pen.small else size * 0.14
    for index in range(count):
        radius = size * (0.28 + index * 0.24)
        ctx.new_path()
        ctx.arc(x, y, radius, math.radians(-50), math.radians(50))
        pen.stroke(INK, width + pen.line * 1.6)
        ctx.new_path()
        ctx.arc(x, y, radius, math.radians(-50), math.radians(50))
        pen.stroke(colour, width)


def star_points(x, y, outer, inner, points=5, rotation=-90.0):
    result = []
    for index in range(points * 2):
        radius = outer if index % 2 == 0 else inner
        a = math.radians(rotation + index * 180.0 / points)
        result.append((x + radius * math.cos(a), y + radius * math.sin(a)))
    return result


def star(pen, x, y, outer, colour=GOLD):
    points = star_points(x, y, outer, outer * 0.48)
    # Its depth: the same star a little lower and darker.
    pen.shape(poly_path([(px + 1.2, py + 2.0) for px, py in points]), darker(colour, 0.4), GOLD_OUTLINE)
    pen.shape(poly_path(points), pen.radial(x - outer * 0.3, y - outer * 0.4, outer * 1.4,
                                            [(0, GOLD_LIGHT), (0.6, colour), (1, GOLD_DEEP)]), GOLD_OUTLINE)
    if not pen.tiny:
        pen.gloss(poly_path(points), y - outer, y + outer * 0.1, 0.55)
