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

"""The pen every icon is drawn with: a cairo context scaled so that the
icon is designed on a grid of 48 x 48 units whatever its pixel size,
with the outline width, the level of detail and the colour helpers.

Icons are seen in the set's three-quarter view (see Projection): the
front of an object faces the viewer and rises a little to the right,
its depth goes back up and to the right, so the top and the right side
show too. Light comes from the top left: tops are lightest, fronts in
between, right sides darkest, and every shape has a dark outline.
"""

import math

import cairo

GRID = 48.0


def rgb(colour):
    """'#rrggbb' or (r, g, b) in 0..1 as a tuple of floats."""
    if isinstance(colour, tuple):
        return colour
    colour = colour.lstrip('#')
    return tuple(int(colour[i:i + 2], 16) / 255.0 for i in (0, 2, 4))


def mix(first, second, amount):
    """first moved amount (0..1) of the way to second."""
    a = rgb(first)
    b = rgb(second)
    return tuple(a[i] + (b[i] - a[i]) * amount for i in range(3))


def lighter(colour, amount=0.35):
    return mix(colour, (1.0, 1.0, 1.0), amount)


def darker(colour, amount=0.35):
    return mix(colour, (0.0, 0.0, 0.0), amount)


def outline_of(colour):
    """The outline drawn round a shape of this colour: much darker and
    a little cooler, so outlines read as one family."""
    return mix(darker(colour, 0.68), (0.06, 0.07, 0.12), 0.35)


class Projection:
    """The three-quarter view: a point (x along the front, y into the
    depth, z up) from an origin at the front bottom left."""

    RISE = 0.22        # the front's rise to the right, per unit across
    DEPTH_X = 0.55     # the depth's run to the right, per unit back
    DEPTH_Y = 0.45     # and up

    def __init__(self, x, y):
        self.x = x
        self.y = y

    def point(self, x, y=0.0, z=0.0):
        return (self.x + x + y * self.DEPTH_X, self.y - x * self.RISE - y * self.DEPTH_Y - z)

    def front_matrix(self, y=0.0):
        """Cairo matrix taking front face coordinates (u right, v down
        from the face's top... v as screen y relative to the origin)
        onto the front plane at depth y."""
        ox, oy = self.point(0, y, 0)
        return cairo.Matrix(1.0, -self.RISE, 0.0, 1.0, ox, oy)

    def top_matrix(self, z):
        """Face coordinates (u across, w into the depth) on the plane z."""
        ox, oy = self.point(0, 0, z)
        return cairo.Matrix(1.0, -self.RISE, self.DEPTH_X, -self.DEPTH_Y, ox, oy)

    def side_matrix(self, x):
        """Face coordinates (w into the depth, v down) on the plane x."""
        ox, oy = self.point(x, 0, 0)
        return cairo.Matrix(self.DEPTH_X, -self.DEPTH_Y, 0.0, 1.0, ox, oy)


class Pen:
    def __init__(self, context, size):
        self.ctx = context
        self.size = size
        self.unit = size / GRID
        # Detail: the small sizes (16, 20, 24) are simplified.
        self.small = size <= 24
        self.tiny = size <= 16
        self.large = size >= 64
        context.scale(self.unit, self.unit)
        context.set_line_join(cairo.LINE_JOIN_ROUND)
        context.set_line_cap(cairo.LINE_CAP_ROUND)

    # --- widths in pixels turned into design units -------------------------

    def px(self, pixels):
        return pixels / self.unit

    @property
    def line(self):
        """The outline's width: one pixel up to 32, then growing."""
        if self.size <= 32:
            return self.px(1.0)
        return self.px(self.size / 32.0)

    @property
    def thin(self):
        return self.line * 0.6

    # --- paths ---------------------------------------------------------------

    def polygon(self, points):
        ctx = self.ctx
        ctx.move_to(*points[0])
        for point in points[1:]:
            ctx.line_to(*point)
        ctx.close_path()

    def rounded(self, x, y, width, height, radius):
        ctx = self.ctx
        radius = max(0.0, min(radius, width / 2.0, height / 2.0))
        if radius == 0:
            ctx.rectangle(x, y, width, height)
            return
        ctx.new_sub_path()
        ctx.arc(x + width - radius, y + radius, radius, -math.pi / 2, 0)
        ctx.arc(x + width - radius, y + height - radius, radius, 0, math.pi / 2)
        ctx.arc(x + radius, y + height - radius, radius, math.pi / 2, math.pi)
        ctx.arc(x + radius, y + radius, radius, math.pi, 3 * math.pi / 2)
        ctx.close_path()

    def circle(self, x, y, radius):
        self.ctx.new_sub_path()
        self.ctx.arc(x, y, radius, 0, 2 * math.pi)

    def ellipse(self, x, y, rx, ry):
        ctx = self.ctx
        ctx.save()
        ctx.translate(x, y)
        ctx.scale(rx, ry)
        ctx.new_sub_path()
        ctx.arc(0, 0, 1, 0, 2 * math.pi)
        ctx.restore()

    # --- paint -----------------------------------------------------------------

    def source(self, paint):
        if isinstance(paint, cairo.Pattern):
            self.ctx.set_source(paint)
        else:
            colour = rgb(paint)
            self.ctx.set_source_rgb(*colour)

    def linear(self, x0, y0, x1, y1, stops):
        pattern = cairo.LinearGradient(x0, y0, x1, y1)
        for offset, colour in stops:
            if len(colour) == 2 and not isinstance(colour, str):
                c, alpha = colour
                pattern.add_color_stop_rgba(offset, *rgb(c), alpha)
            else:
                pattern.add_color_stop_rgb(offset, *rgb(colour))
        return pattern

    def radial(self, cx, cy, radius, stops, fx=None, fy=None):
        fx = cx if fx is None else fx
        fy = cy if fy is None else fy
        pattern = cairo.RadialGradient(fx, fy, 0, cx, cy, radius)
        for offset, colour in stops:
            if len(colour) == 2 and not isinstance(colour, str):
                c, alpha = colour
                pattern.add_color_stop_rgba(offset, *rgb(c), alpha)
            else:
                pattern.add_color_stop_rgb(offset, *rgb(colour))
        return pattern

    def vertical(self, top, bottom, y0, y1):
        return self.linear(0, y0, 0, y1, [(0, top), (1, bottom)])

    def fill(self, paint, outline=None, width=None):
        """Fills the current path, then outlines it (outline None: none)."""
        self.source(paint)
        if outline is None:
            self.ctx.fill()
            return
        self.ctx.fill_preserve()
        self.stroke(outline, width)

    def stroke(self, colour, width=None):
        self.ctx.set_line_width(self.line if width is None else width)
        if isinstance(colour, cairo.Pattern):
            self.ctx.set_source(colour)
        elif len(colour) == 2 and not isinstance(colour, str):
            c, alpha = colour
            self.ctx.set_source_rgba(*rgb(c), alpha)
        else:
            self.ctx.set_source_rgb(*rgb(colour))
        self.ctx.stroke()

    def shape(self, path, paint, outline=None, width=None):
        """path(pen) builds a path; it is filled and outlined."""
        self.ctx.new_path()
        path(self)
        self.fill(paint, outline, width)

    def gloss(self, path, top, bottom, strength=0.55):
        """A white sheen from top to bottom over the shape path makes,
        fading out: the glossy highlight of the set's objects."""
        if self.tiny:
            strength *= 0.6
        ctx = self.ctx
        ctx.save()
        ctx.new_path()
        path(self)
        ctx.clip()
        pattern = cairo.LinearGradient(0, top, 0, bottom)
        pattern.add_color_stop_rgba(0, 1, 1, 1, strength)
        pattern.add_color_stop_rgba(1, 1, 1, 1, 0)
        ctx.set_source(pattern)
        ctx.paint()
        ctx.restore()

    def highlight_line(self, points, alpha=0.7, width=None):
        """A thin light line just inside an edge: the bevel's catch light."""
        ctx = self.ctx
        ctx.new_path()
        ctx.move_to(*points[0])
        for point in points[1:]:
            ctx.line_to(*point)
        self.stroke(((1, 1, 1), alpha), self.thin if width is None else width)

    def save(self):
        self.ctx.save()

    def restore(self):
        self.ctx.restore()

    def transform(self, matrix):
        self.ctx.transform(matrix)

    def translate(self, x, y):
        self.ctx.translate(x, y)

    def scale(self, x, y=None):
        self.ctx.scale(x, x if y is None else y)
