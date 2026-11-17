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

"""The set's building blocks, on the 48 unit grid: boxes in the
three-quarter view, faces with things drawn on them, discs and spheres,
block arrows, gears, and the palette they share."""

import math

import cairo

from .pen import Projection, rgb, lighter, darker, mix, outline_of

# --- the palette ---------------------------------------------------------------

GOLD_LIGHT = '#ffe98a'
GOLD = '#f9c936'
GOLD_DEEP = '#e39a14'
GOLD_OUTLINE = '#6e4304'
BLUE_LIGHT = '#8cc2ff'
BLUE = '#2f74d6'
BLUE_DEEP = '#18479e'
NAVY = '#14306e'
TEAL = '#21a3b5'
GREEN_LIGHT = '#9ae46c'
GREEN = '#3aa83a'
GREEN_DEEP = '#1e6e22'
RED_LIGHT = '#ff8a74'
RED = '#da3426'
RED_DEEP = '#8e160e'
ORANGE = '#f28a1e'
PURPLE = '#7a4fd6'
PURPLE_LIGHT = '#b89bff'
SILVER_TOP = '#f2f4f8'
SILVER = '#d3d8e0'
SILVER_SIDE = '#a3abb8'
SILVER_OUTLINE = '#3b414d'
CHARCOAL = '#3a3f4a'
PAPER = '#ffffff'
PAPER_SHADE = '#e3e8f1'
INK = '#1b2030'


# --- shapes on a face --------------------------------------------------------------

def plane_shape(pen, matrix, path, paint, outline=None, width=None):
    """path(pen) built in the face coordinates of matrix, filled with
    paint (a pattern is in face coordinates too) and outlined in plain
    drawing coordinates, so the outline keeps its width."""
    ctx = pen.ctx
    ctx.save()
    ctx.transform(matrix)
    ctx.new_path()
    path(pen)
    pen.source(paint)
    ctx.fill_preserve()
    ctx.restore()
    if outline is not None:
        pen.stroke(outline, width)
    else:
        ctx.new_path()


def plane_stroke(pen, matrix, path, colour, width=None):
    ctx = pen.ctx
    ctx.save()
    ctx.transform(matrix)
    ctx.new_path()
    path(pen)
    ctx.restore()
    pen.stroke(colour, width)


def poly_path(points):
    def path(pen):
        pen.polygon(points)
    return path


def rect_path(x, y, width, height, radius=0.0):
    def path(pen):
        pen.rounded(x, y, width, height, radius)
    return path


def circle_path(x, y, radius):
    def path(pen):
        pen.circle(x, y, radius)
    return path


# --- boxes ---------------------------------------------------------------------------

def box(pen, projection, width, depth, height, colour, outline=None, top=None, side=None, front=None,
        gloss=True):
    """A box from the projection's origin: its front, top and right side.
    The faces are shades of colour unless given."""
    p = projection.point
    outline = outline or outline_of(colour)
    top = top or lighter(colour, 0.45)
    side = side or darker(colour, 0.25)
    front = front or colour
    ctx = pen.ctx
    front_points = [p(0, 0, 0), p(width, 0, 0), p(width, 0, height), p(0, 0, height)]
    top_points = [p(0, 0, height), p(width, 0, height), p(width, depth, height), p(0, depth, height)]
    side_points = [p(width, 0, 0), p(width, depth, 0), p(width, depth, height), p(width, 0, height)]
    y_top = p(0, 0, height)[1]
    y_bottom = p(0, 0, 0)[1]
    ctx.new_path()
    pen.polygon(front_points)
    pen.fill(pen.vertical(lighter(front, 0.18), darker(front, 0.08), y_top - 4, y_bottom))
    if depth > 0:
        ctx.new_path()
        pen.polygon(top_points)
        pen.fill(top)
        ctx.new_path()
        pen.polygon(side_points)
        pen.fill(pen.vertical(side, darker(side, 0.15), y_top, y_bottom))
    if gloss and not pen.tiny:
        pen.gloss(poly_path(front_points), y_top, y_top + (y_bottom - y_top) * 0.6, 0.35)
    # Inner edges thin, the silhouette at full width.
    if depth > 0:
        ctx.new_path()
        ctx.move_to(*p(0, 0, height))
        ctx.line_to(*p(width, 0, height))
        ctx.line_to(*p(width, 0, 0))
        ctx.move_to(*p(width, 0, height))
        ctx.line_to(*p(width, depth, height))
        pen.stroke(outline, pen.thin)
        silhouette = [p(0, 0, 0), p(width, 0, 0), p(width, depth, 0), p(width, depth, height), p(0, depth, height),
                      p(0, 0, height)]
    else:
        silhouette = front_points
    ctx.new_path()
    pen.polygon(silhouette)
    pen.stroke(outline)
    return front_points


def front_face(pen, projection, y=0.0):
    """Cairo matrix of a box's front face at depth y: (u, v) with u to
    the right and v down from the origin (so the face's top is v = -H)."""
    return projection.front_matrix(y)


# --- discs and spheres ---------------------------------------------------------------

def sphere(pen, x, y, radius, colour, outline=None):
    """A shiny ball lit from the top left."""
    outline = outline or outline_of(colour)
    paint = pen.radial(x - radius * 0.35, y - radius * 0.4, radius * 1.45,
                       [(0, lighter(colour, 0.55)), (0.45, colour), (1, darker(colour, 0.45))])
    pen.shape(circle_path(x, y, radius), paint, outline)


def sphere_gloss(pen, x, y, radius, strength=0.75):
    """The white highlight at a ball's top left."""
    ctx = pen.ctx
    ctx.save()
    ctx.new_path()
    pen.ellipse(x - radius * 0.2, y - radius * 0.48, radius * 0.62, radius * 0.38)
    pattern = cairo.LinearGradient(0, y - radius * 0.9, 0, y - radius * 0.05)
    pattern.add_color_stop_rgba(0, 1, 1, 1, strength)
    pattern.add_color_stop_rgba(1, 1, 1, 1, 0)
    ctx.set_source(pattern)
    ctx.fill()
    ctx.restore()


def badge(pen, x, y, radius, colour, glyph=None):
    """A round coloured badge (a ball) with a white glyph(pen, x, y, r)."""
    sphere(pen, x, y, radius, colour)
    if glyph is not None:
        glyph(pen, x, y, radius)
    if not pen.tiny:
        sphere_gloss(pen, x, y, radius, 0.55)


# --- globes --------------------------------------------------------------------------

CONTINENTS = [
    [(-0.62, -0.55), (-0.25, -0.78), (0.05, -0.62), (-0.05, -0.38), (-0.3, -0.28), (-0.36, 0.02),
     (-0.18, 0.2), (-0.32, 0.5), (-0.5, 0.36), (-0.72, 0.0), (-0.86, -0.22)],
    [(0.18, -0.2), (0.48, -0.42), (0.78, -0.3), (0.88, 0.05), (0.66, 0.2), (0.52, 0.55), (0.3, 0.72),
     (0.2, 0.42), (0.28, 0.12)],
    [(-0.1, 0.6), (0.08, 0.55), (0.12, 0.8), (-0.05, 0.9)],
]


def globe(pen, x, y, radius, land=True):
    ocean = pen.radial(x - radius * 0.35, y - radius * 0.4, radius * 1.5,
                       [(0, '#b4ecff'), (0.35, '#3d9ee8'), (0.8, '#1a5bb5'), (1, '#0f3a80')])
    pen.shape(circle_path(x, y, radius), ocean)
    if land:
        ctx = pen.ctx
        ctx.save()
        ctx.new_path()
        pen.circle(x, y, radius)
        ctx.clip()
        green = pen.radial(x - radius * 0.3, y - radius * 0.4, radius * 1.4,
                           [(0, '#a6ec6e'), (0.55, '#3faa38'), (1, '#1d6a1c')])
        for continent in CONTINENTS:
            if pen.tiny and len(continent) < 5:
                continue
            ctx.new_path()
            pen.polygon([(x + px * radius, y + py * radius) for px, py in continent])
            pen.source(green)
            ctx.fill_preserve()
            pen.stroke((darker(GREEN_DEEP, 0.2), 0.6), pen.thin)
        ctx.restore()
    sphere_gloss(pen, x, y, radius, 0.7)
    pen.ctx.new_path()
    pen.circle(x, y, radius)
    pen.stroke(NAVY)


# --- arrows --------------------------------------------------------------------------

def block_arrow_points(length=36.0, shaft=12.0, head=24.0, head_length=16.0):
    """A block arrow pointing right, centred on (0, 0)."""
    half = length / 2.0
    neck = half - head_length
    return [(-half, -shaft / 2), (neck, -shaft / 2), (neck, -head / 2), (half, 0), (neck, head / 2),
            (neck, shaft / 2), (-half, shaft / 2)]


def block_arrow(pen, x, y, angle, colour=BLUE, length=38.0, shaft=13.0, head=27.0, head_length=17.0,
                depth=2.4):
    """A thick arrow at (x, y) pointing at angle (degrees, 0 right,
    90 down), with a darker extrusion below it and a sheen on top."""
    points = block_arrow_points(length, shaft, head, head_length)
    radians = math.radians(angle)
    cosine = math.cos(radians)
    sine = math.sin(radians)
    placed = [(x + px * cosine - py * sine, y + px * sine + py * cosine) for px, py in points]
    outline = outline_of(colour)
    if pen.small:
        depth *= 0.6
    if depth > 0:
        shadow = [(px + depth * 0.5, py + depth) for px, py in placed]
        pen.shape(poly_path(shadow), darker(colour, 0.45), outline)
    top = min(py for px, py in placed)
    bottom = max(py for px, py in placed)
    pen.shape(poly_path(placed), pen.vertical(lighter(colour, 0.35), darker(colour, 0.1), top, bottom), outline)
    if not pen.tiny:
        pen.gloss(poly_path(placed), top, top + (bottom - top) * 0.55, 0.5)
    pen.ctx.new_path()
    pen.polygon(placed)
    pen.stroke(outline)


def curved_arrow(pen, x, y, radius, start, end, colour=GREEN, width=7.0, head=1.0):
    """A thick arc from angle start to end (degrees, clockwise when end >
    start) with an arrow head at its end."""
    ctx = pen.ctx
    outline = outline_of(colour)
    a0 = math.radians(start)
    a1 = math.radians(end)
    clockwise = a1 > a0
    inner = radius - width / 2
    outer = radius + width / 2
    ctx.new_path()
    if clockwise:
        ctx.arc(x, y, outer, a0, a1)
        ctx.arc_negative(x, y, inner, a1, a0)
    else:
        ctx.arc_negative(x, y, outer, a0, a1)
        ctx.arc(x, y, inner, a1, a0)
    ctx.close_path()
    pen.fill(pen.vertical(lighter(colour, 0.3), darker(colour, 0.15), y - outer, y + outer), outline)
    # The head: a triangle across the arc's end, pointing along it.
    direction = 1 if clockwise else -1
    tangent = (-math.sin(a1) * direction, math.cos(a1) * direction)
    normal = (math.cos(a1), math.sin(a1))
    end_x = x + radius * math.cos(a1)
    end_y = y + radius * math.sin(a1)
    spread = width * 1.15 * head
    reach = width * 1.25 * head
    tip = (end_x + tangent[0] * reach, end_y + tangent[1] * reach)
    left = (end_x + normal[0] * spread, end_y + normal[1] * spread)
    right = (end_x - normal[0] * spread, end_y - normal[1] * spread)
    pen.shape(poly_path([left, tip, right]), pen.vertical(lighter(colour, 0.3), darker(colour, 0.1),
                                                          y - outer, y + outer), outline)


# --- gears ---------------------------------------------------------------------------

def gear_path(x, y, outer, inner, teeth, hole=0.0):
    def path(pen):
        ctx = pen.ctx
        step = 2 * math.pi / teeth
        points = []
        for index in range(teeth):
            angle = index * step
            for offset, radius in ((-0.27, inner), (-0.17, outer), (0.17, outer), (0.27, inner)):
                a = angle + offset * step * 1.6
                points.append((x + radius * math.cos(a), y + radius * math.sin(a)))
        pen.polygon(points)
        if hole > 0:
            ctx.new_sub_path()
            ctx.arc_negative(x, y, hole, 2 * math.pi, 0)
    return path


def gear(pen, x, y, radius, colour=SILVER_SIDE, teeth=8):
    outline = outline_of(colour)
    inner = radius * 0.78
    hole = radius * 0.32
    paint = pen.radial(x - radius * 0.4, y - radius * 0.45, radius * 1.6,
                       [(0, lighter(colour, 0.7)), (0.5, colour), (1, darker(colour, 0.35))])
    pen.ctx.set_fill_rule(cairo.FILL_RULE_EVEN_ODD)
    pen.shape(gear_path(x, y, radius, inner, teeth, hole), paint, outline)
    pen.ctx.set_fill_rule(cairo.FILL_RULE_WINDING)
    if not pen.small:
        pen.ctx.new_path()
        pen.circle(x, y, (inner + hole) / 2)
        pen.stroke((darker(colour, 0.3), 0.5), pen.thin)


# --- small glyphs (white, on badges) ------------------------------------------------------

def glyph_check(pen, x, y, r, colour=(1, 1, 1)):
    ctx = pen.ctx
    ctx.new_path()
    ctx.move_to(x - r * 0.5, y + r * 0.02)
    ctx.line_to(x - r * 0.12, y + r * 0.42)
    ctx.line_to(x + r * 0.52, y - r * 0.38)
    pen.stroke(colour, r * 0.32)


def glyph_cross(pen, x, y, r, colour=(1, 1, 1)):
    ctx = pen.ctx
    ctx.new_path()
    d = r * 0.42
    ctx.move_to(x - d, y - d)
    ctx.line_to(x + d, y + d)
    ctx.move_to(x + d, y - d)
    ctx.line_to(x - d, y + d)
    pen.stroke(colour, r * 0.3)


def glyph_exclamation(pen, x, y, r, colour=(1, 1, 1)):
    ctx = pen.ctx
    ctx.new_path()
    ctx.move_to(x, y - r * 0.55)
    ctx.line_to(x, y + r * 0.12)
    pen.stroke(colour, r * 0.3)
    ctx.new_path()
    pen.circle(x, y + r * 0.5, r * 0.17)
    pen.fill(colour)


def glyph_info(pen, x, y, r, colour=(1, 1, 1)):
    ctx = pen.ctx
    ctx.new_path()
    pen.circle(x, y - r * 0.5, r * 0.17)
    pen.fill(colour)
    ctx.new_path()
    ctx.move_to(x, y - r * 0.12)
    ctx.line_to(x, y + r * 0.55)
    pen.stroke(colour, r * 0.3)


def glyph_question(pen, x, y, r, colour=(1, 1, 1)):
    ctx = pen.ctx
    ctx.new_path()
    ctx.arc(x, y - r * 0.25, r * 0.32, math.radians(200), math.radians(400))
    ctx.line_to(x, y + r * 0.2)
    pen.stroke(colour, r * 0.26)
    ctx.new_path()
    pen.circle(x, y + r * 0.55, r * 0.15)
    pen.fill(colour)


def glyph_plus(pen, x, y, r, colour=(1, 1, 1)):
    ctx = pen.ctx
    ctx.new_path()
    ctx.move_to(x - r * 0.5, y)
    ctx.line_to(x + r * 0.5, y)
    ctx.move_to(x, y - r * 0.5)
    ctx.line_to(x, y + r * 0.5)
    pen.stroke(colour, r * 0.3)


def glyph_arrows_round(pen, x, y, r, colour=(1, 1, 1)):
    """Two arrows chasing round: synced or updating."""
    ctx = pen.ctx
    width = r * 0.24
    for start in (200, 20):
        ctx.new_path()
        ctx.arc(x, y, r * 0.5, math.radians(start), math.radians(start + 120))
        pen.stroke(colour, width)
        a = math.radians(start + 120)
        tip_x = x + r * 0.5 * math.cos(a)
        tip_y = y + r * 0.5 * math.sin(a)
        tangent = (-math.sin(a), math.cos(a))
        normal = (math.cos(a), math.sin(a))
        ctx.new_path()
        pen.polygon([(tip_x + normal[0] * r * 0.25, tip_y + normal[1] * r * 0.25),
                     (tip_x + tangent[0] * r * 0.32, tip_y + tangent[1] * r * 0.32),
                     (tip_x - normal[0] * r * 0.25, tip_y - normal[1] * r * 0.25)])
        pen.fill(colour)


def glyph_shortcut(pen, x, y, r, colour=BLUE_DEEP):
    ctx = pen.ctx
    ctx.new_path()
    ctx.move_to(x - r * 0.45, y + r * 0.5)
    ctx.curve_to(x - r * 0.45, y - r * 0.1, x - r * 0.1, y - r * 0.25, x + r * 0.2, y - r * 0.25)
    pen.stroke(colour, r * 0.28)
    ctx.new_path()
    pen.polygon([(x + r * 0.05, y - r * 0.62), (x + r * 0.6, y - r * 0.25), (x + r * 0.05, y + r * 0.12)])
    pen.fill(colour)


# --- common objects ---------------------------------------------------------------------

def warning_triangle(pen, x, y, size, colour='#ffcc1a'):
    """A rounded yellow warning sign, size across, centred at (x, y)."""
    height = size * 0.88
    top = (x, y - height / 2)
    left = (x - size / 2, y + height / 2)
    right = (x + size / 2, y + height / 2)
    outline = '#5a3a00'
    paint = pen.vertical(lighter(colour, 0.45), darker(colour, 0.12), top[1], left[1])
    ctx = pen.ctx
    ctx.save()
    ctx.set_line_join(cairo.LINE_JOIN_ROUND)
    pen.shape(poly_path([top, right, left]), paint, outline, pen.line * 1.2)
    ctx.restore()
    if not pen.tiny:
        pen.gloss(poly_path([top, right, left]), top[1], y + height * 0.2, 0.45)
    r = size * 0.42
    ctx.new_path()
    ctx.move_to(x, y - r * 0.38)
    ctx.line_to(x, y + r * 0.42)
    pen.stroke(INK, max(size * 0.12, pen.px(1.6)))
    ctx.new_path()
    pen.circle(x, y + height * 0.33, max(size * 0.07, pen.px(1)))
    pen.fill(INK)


def padlock(pen, x, y, size, colour=GOLD):
    """A padlock: its shackle above a body size wide, top left at (x, y)."""
    ctx = pen.ctx
    body_top = y + size * 0.45
    ctx.new_path()
    ctx.arc(x + size / 2, body_top, size * 0.3, math.pi, 2 * math.pi)
    pen.stroke(SILVER_OUTLINE, size * 0.2)
    ctx.new_path()
    ctx.arc(x + size / 2, body_top, size * 0.3, math.pi, 2 * math.pi)
    pen.stroke(SILVER, size * 0.1)
    pen.shape(rect_path(x, body_top, size, size * 0.62, size * 0.1),
              pen.vertical(lighter(colour, 0.4), darker(colour, 0.2), body_top, body_top + size * 0.62),
              outline_of(colour))
    ctx.new_path()
    pen.circle(x + size / 2, body_top + size * 0.26, size * 0.09)
    pen.fill(INK)


def magnifier(pen, x, y, radius, handle=1.0):
    """A magnifying glass: its lens centred at (x, y), the handle to the
    bottom right."""
    ctx = pen.ctx
    a = math.radians(45)
    start = (x + radius * 1.05 * math.cos(a), y + radius * 1.05 * math.sin(a))
    end = (x + radius * (1.05 + 1.15 * handle) * math.cos(a), y + radius * (1.05 + 1.15 * handle) * math.sin(a))
    ctx.new_path()
    ctx.move_to(*start)
    ctx.line_to(*end)
    pen.stroke(INK, radius * 0.62 + pen.line * 2)
    ctx.new_path()
    ctx.move_to(*start)
    ctx.line_to(*end)
    pen.stroke('#8a5a2b', radius * 0.62)
    lens = pen.radial(x - radius * 0.3, y - radius * 0.35, radius * 1.3,
                      [(0, ('#ffffff', 0.95)), (0.6, ('#bfe4ff', 0.75)), (1, ('#6fa8e0', 0.8))])
    pen.shape(circle_path(x, y, radius), lens)
    ctx.new_path()
    pen.circle(x, y, radius)
    pen.stroke(INK, radius * 0.3 + pen.line * 2)
    ctx.new_path()
    pen.circle(x, y, radius)
    pen.stroke(SILVER, radius * 0.3)
