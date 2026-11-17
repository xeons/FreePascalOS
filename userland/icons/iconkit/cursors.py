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

"""The pointer's shapes, drawn in several sizes for the display server
(/lib/pointers/NAME.cur): the arrow, the text beam, the hand, busy (an
hourglass), the four resize arrows, move, not allowed and the
crosshair. White shapes with a black outline and a soft shadow, the
hourglass golden, the not-allowed sign red, as the icons are.

Each is designed on a 32 unit grid with its hotspot there; the 32
pixel picture is the one for 100 %, the others for larger scales (the
server picks the nearest, and scales it when none fits). Outlines go
through half units, so they fall on whole pixels at 32 and 64.
"""

import math

import cairo

from .pen import rgb

SIZES = (24, 32, 40, 48, 64, 96)
GRID = 32.0
ORDER = []
POINTERS = {}

WHITE = (1.0, 1.0, 1.0)
BLACK = (0.0, 0.0, 0.0)


def pointer(name, hotspot_x, hotspot_y):
    def register(draw):
        POINTERS[name] = (draw, hotspot_x, hotspot_y)
        ORDER.append(name)
        return draw
    return register


class PointerPen:
    def __init__(self, context, size):
        self.ctx = context
        self.size = size
        self.unit = size / GRID
        context.scale(self.unit, self.unit)
        context.set_line_join(cairo.LINE_JOIN_MITER)
        context.set_miter_limit(4.0)

    @property
    def line(self):
        """One pixel at 32, two at 64: the outline."""
        return max(1.0, self.size / GRID) / self.unit

    def polygon(self, points):
        self.ctx.new_path()
        self.ctx.move_to(*points[0])
        for point in points[1:]:
            self.ctx.line_to(*point)
        self.ctx.close_path()

    def outlined(self, fill=WHITE, outline=BLACK, shadow=True):
        """Fills and outlines the current path, with a soft shadow below
        and to the right of it first."""
        ctx = self.ctx
        path = ctx.copy_path()
        if shadow:
            ctx.save()
            ctx.translate(1.0, 1.4)
            for spread, alpha in ((2.2, 0.08), (1.4, 0.12), (0.6, 0.16)):
                ctx.new_path()
                ctx.append_path(path)
                ctx.set_source_rgba(0, 0, 0, alpha)
                ctx.set_line_width(spread)
                ctx.stroke_preserve()
                ctx.fill()
            ctx.restore()
        ctx.new_path()
        ctx.append_path(path)
        if isinstance(fill, cairo.Pattern):
            ctx.set_source(fill)
        else:
            ctx.set_source_rgb(*rgb(fill))
        ctx.fill_preserve()
        ctx.set_source_rgb(*rgb(outline))
        ctx.set_line_width(self.line)
        ctx.stroke()


def render(name, size):
    draw, hotspot_x, hotspot_y = POINTERS[name]
    surface = cairo.ImageSurface(cairo.FORMAT_ARGB32, size, size)
    context = cairo.Context(surface)
    draw(PointerPen(context, size))
    surface.flush()
    hotspot = (min(size - 1, int(hotspot_x * size / GRID)), min(size - 1, int(hotspot_y * size / GRID)))
    return surface, hotspot


def render_all(name):
    surfaces = []
    hotspots = []
    for size in SIZES:
        surface, hotspot = render(name, size)
        surfaces.append(surface)
        hotspots.append(hotspot)
    return surfaces, hotspots


ARROW = [(1.5, 1.5), (1.5, 19.5), (5.6, 15.6), (8.6, 22.5), (11.6, 21.2), (8.7, 14.5), (14.2, 14.5)]


@pointer('arrow', 1, 1)
def draw_arrow(pen):
    pen.polygon(ARROW)
    pen.outlined()


@pointer('text-beam', 8, 12)
def draw_text_beam(pen):
    ctx = pen.ctx
    ctx.new_path()
    # An I with serifs, as one outlined shape.
    pen.polygon([(4.5, 1.5), (7.0, 1.5), (8.0, 2.6), (9.0, 1.5), (11.5, 1.5), (11.5, 3.5), (9.0, 3.5), (9.0, 20.5),
                 (11.5, 20.5), (11.5, 22.5), (9.0, 22.5), (8.0, 21.4), (7.0, 22.5), (4.5, 22.5), (4.5, 20.5),
                 (7.0, 20.5), (7.0, 3.5), (4.5, 3.5)])
    pen.outlined()


@pointer('hand', 7, 1)
def draw_hand(pen):
    ctx = pen.ctx
    ctx.new_path()
    # The pointing finger, three folded fingers and the palm, as one shape.
    ctx.move_to(5.5, 3.5)
    ctx.curve_to(5.5, 1.0, 9.5, 1.0, 9.5, 3.5)
    ctx.line_to(9.5, 10.5)
    ctx.curve_to(9.5, 8.6, 13.0, 8.6, 13.0, 10.8)
    ctx.curve_to(13.0, 9.0, 16.5, 9.0, 16.5, 11.6)
    ctx.curve_to(16.5, 10.0, 20.0, 10.0, 20.0, 12.6)
    ctx.line_to(20.0, 18.5)
    ctx.curve_to(20.0, 22.0, 18.5, 23.5, 17.5, 25.5)
    ctx.line_to(8.5, 25.5)
    ctx.curve_to(6.5, 23.0, 4.0, 20.0, 2.2, 16.5)
    ctx.curve_to(1.2, 14.6, 3.6, 13.0, 5.5, 15.5)
    ctx.close_path()
    pen.outlined()
    ctx.new_path()
    for x in (13.0, 16.5):
        ctx.move_to(x, 11.5)
        ctx.line_to(x, 15.0)
    ctx.set_source_rgb(0, 0, 0)
    ctx.set_line_width(pen.line * 0.8)
    ctx.stroke()


@pointer('busy', 9, 12)
def draw_busy(pen):
    ctx = pen.ctx
    # The hourglass: golden caps, the glass, the sand running down.
    pen.polygon([(4.5, 4.5), (15.5, 4.5), (15.5, 7.0), (11.0, 12.0), (15.5, 17.0), (15.5, 19.5), (4.5, 19.5),
                 (4.5, 17.0), (9.0, 12.0), (4.5, 7.0)])
    glass = cairo.LinearGradient(4, 0, 16, 0)
    glass.add_color_stop_rgb(0, 0.85, 0.92, 1.0)
    glass.add_color_stop_rgb(0.4, 1, 1, 1)
    glass.add_color_stop_rgb(1, 0.7, 0.8, 0.92)
    pen.outlined(glass)
    sand = (0.93, 0.70, 0.20)
    ctx.new_path()
    pen.polygon([(6.5, 7.5), (13.5, 7.5), (10.0, 11.5)])
    ctx.set_source_rgb(*sand)
    ctx.fill()
    ctx.new_path()
    pen.polygon([(6.0, 18.5), (14.0, 18.5), (10.0, 15.0)])
    ctx.set_source_rgb(*sand)
    ctx.fill()
    for y in (1.5, 19.5):
        ctx.new_path()
        pen.polygon([(2.5, y), (17.5, y), (17.5, y + 3.0), (2.5, y + 3.0)])
        cap = cairo.LinearGradient(0, y, 0, y + 3)
        cap.add_color_stop_rgb(0, 1.0, 0.88, 0.45)
        cap.add_color_stop_rgb(1, 0.8, 0.52, 0.08)
        pen.outlined(cap, (0.3, 0.18, 0.0))


def double_arrow(pen, angle):
    """A resize arrow through the grid's middle at angle degrees."""
    length = 10.5
    shaft = 1.6
    head = 4.6
    head_length = 4.5
    points = [(-length, 0), (-length + head_length, -head), (-length + head_length, -shaft),
              (length - head_length, -shaft), (length - head_length, -head), (length, 0),
              (length - head_length, head), (length - head_length, shaft), (-length + head_length, shaft),
              (-length + head_length, head)]
    a = math.radians(angle)
    placed = [(12.0 + x * math.cos(a) - y * math.sin(a), 12.0 + x * math.sin(a) + y * math.cos(a)) for x, y in points]
    pen.polygon(placed)
    pen.outlined()


@pointer('resize-horizontal', 12, 12)
def draw_resize_horizontal(pen):
    double_arrow(pen, 0)


@pointer('resize-vertical', 12, 12)
def draw_resize_vertical(pen):
    double_arrow(pen, 90)


@pointer('resize-diagonal-down', 12, 12)
def draw_resize_diagonal_down(pen):
    double_arrow(pen, 45)


@pointer('resize-diagonal-up', 12, 12)
def draw_resize_diagonal_up(pen):
    double_arrow(pen, -45)


@pointer('move', 12, 12)
def draw_move(pen):
    length = 11.0
    shaft = 1.6
    head = 4.2
    head_length = 4.2
    points = []
    for quarter in range(4):
        a = math.radians(quarter * 90)
        arm = [(shaft, shaft), (length - head_length, shaft), (length - head_length, head), (length, 0),
               (length - head_length, -head), (length - head_length, -shaft)]
        for x, y in arm:
            points.append((12.0 + x * math.cos(a) - y * math.sin(a), 12.0 + x * math.sin(a) + y * math.cos(a)))
    # Each arm runs from its lower corner round its tip to its upper
    # one; taken right, up, left, down the outline goes round once.
    ordered = []
    for quarter in (0, 3, 2, 1):
        ordered.extend(points[quarter * 6:quarter * 6 + 6])
    pen.polygon(ordered)
    pen.outlined()


@pointer('not-allowed', 12, 12)
def draw_not_allowed(pen):
    ctx = pen.ctx
    ctx.new_path()
    ctx.arc(12.0, 12.0, 9.5, 0, 2 * math.pi)
    ctx.new_sub_path()
    ctx.arc_negative(12.0, 12.0, 6.5, 2 * math.pi, 0)
    ctx.set_fill_rule(cairo.FILL_RULE_EVEN_ODD)
    red = cairo.LinearGradient(0, 2, 0, 22)
    red.add_color_stop_rgb(0, 1.0, 0.45, 0.38)
    red.add_color_stop_rgb(1, 0.72, 0.08, 0.05)
    pen.outlined(red, (0.25, 0.0, 0.0))
    ctx.set_fill_rule(cairo.FILL_RULE_WINDING)
    a = math.radians(45)
    dx, dy = math.cos(a), math.sin(a)
    half = 1.6
    pen.polygon([(12.0 - 7.0 * dx - half * dy, 12.0 - 7.0 * dy + half * dx),
                 (12.0 + 7.0 * dx - half * dy, 12.0 + 7.0 * dy + half * dx),
                 (12.0 + 7.0 * dx + half * dy, 12.0 + 7.0 * dy - half * dx),
                 (12.0 - 7.0 * dx + half * dy, 12.0 - 7.0 * dy - half * dx)])
    pen.outlined(red, (0.25, 0.0, 0.0), shadow=False)


@pointer('crosshair', 12, 12)
def draw_crosshair(pen):
    half = 0.9
    gap = 2.5
    reach = 10.5
    for x0, y0, x1, y1 in ((12 - reach, 12 - half, 12 - gap, 12 + half), (12 + gap, 12 - half, 12 + reach, 12 + half),
                           (12 - half, 12 - reach, 12 + half, 12 - gap), (12 - half, 12 + gap, 12 + half, 12 + reach)):
        pen.polygon([(x0, y0), (x1, y0), (x1, y1), (x0, y1)])
        pen.outlined()
