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

"""System places and drives: the computer, home, the network, the
internet, the drives (hard disk, removable, optical, USB stick, memory
card, solid state), the trash empty and full, the applications, the
favourites and the library."""

import math

from .catalog import icon, group
from .pen import Projection, lighter, darker, outline_of, mix
from .shapes import (box, plane_shape, plane_stroke, poly_path, rect_path, circle_path, globe, sphere,
                     sphere_gloss, SILVER, SILVER_TOP, SILVER_SIDE, SILVER_OUTLINE, BLUE, BLUE_LIGHT, BLUE_DEEP, NAVY,
                     TEAL, INK, GREEN, GREEN_DEEP, RED, ORANGE, PURPLE, CHARCOAL, GOLD, GOLD_LIGHT, GOLD_DEEP,
                     GOLD_OUTLINE, PAPER, PAPER_SHADE)
from .objects import monitor, tower, slab, drive_light, star

group('Places')


@icon('computer', 'Computer')
def draw_computer(pen):
    if pen.small:
        monitor(pen, 5.0, 36.0, 34.0, 25.0, 4.0)
        return
    tower(pen, 2.0, 41.0, 11.0, 30.0, 8.0)
    monitor(pen, 12.0, 35.0, 30.0, 22.0, 4.0)


@icon('home', 'Home')
def draw_home(pen):
    projection = Projection(6.0, 44.0)
    p = projection.point
    width, depth, height = 24.0, 14.0, 17.0
    wall = '#f6ead0'
    box(pen, projection, width, depth, height, wall, '#5a3f1c', top=wall, side='#d8c4a0')
    face = projection.front_matrix(0)
    # The door and a window.
    plane_shape(pen, face, rect_path(4.0, -12.0, 6.5, 12.0, 0.6), pen.vertical('#b5702d', '#7a4515', -12, 0),
                '#4a2a0c', pen.thin)
    if not pen.small:
        plane_shape(pen, face, rect_path(14.0, -12.0, 7.0, 6.0, 0.4), pen.vertical('#bfe8ff', '#5fa8e0', -12, -6),
                    '#4a2a0c', pen.thin)
    # The roof: a ridge running back, its front gable and its right slope.
    overhang = 2.0
    ridge_front = p(width / 2, -overhang, height + 13.0)
    ridge_back = p(width / 2, depth + overhang, height + 13.0)
    roof_colour = '#e0582f'
    gable = [p(-overhang, -overhang * 0.2, height - 1.0), ridge_front, p(width + overhang, -overhang * 0.2,
                                                                            height - 1.0)]
    slope = [p(width + overhang, -overhang * 0.2, height - 1.0), ridge_front, ridge_back,
             p(width + overhang, depth + overhang, height - 1.0)]
    pen.shape(poly_path(slope), pen.linear(*ridge_front, *p(width + overhang, depth, height),
                                           [(0, lighter(roof_colour, 0.2)), (1, darker(roof_colour, 0.25))]),
              '#5a1c0a')
    pen.shape(poly_path([p(0, 0, height), ridge_front, p(width, 0, height)]), wall, '#5a3f1c', pen.thin)
    # The gable's triangle in the wall's colour with a round window.
    if not pen.small:
        cx, cy = p(width / 2, 0, height + 5.0)
        pen.shape(circle_path(cx, cy, 2.0), pen.vertical('#bfe8ff', '#5fa8e0', cy - 2, cy + 2), '#4a2a0c', pen.thin)
    # The roof's front edge, thick.
    ctx = pen.ctx
    ctx.new_path()
    ctx.move_to(*gable[0])
    ctx.line_to(*gable[1])
    ctx.line_to(*gable[2])
    pen.stroke('#5a1c0a', 4.2 if not pen.small else 5.0)
    ctx.new_path()
    ctx.move_to(*gable[0])
    ctx.line_to(*gable[1])
    ctx.line_to(*gable[2])
    pen.stroke(roof_colour, 2.4 if not pen.small else 3.0)
    # The chimney.
    if not pen.small:
        box(pen, Projection(*p(width * 0.72, depth * 0.55, height + 4.0)), 3.0, 3.0, 7.0, '#b0503a', '#4a1a0a',
            gloss=False)


def two_screens(pen, offline=False):
    bezel = '#4f78b8' if not offline else '#8a8f99'
    if pen.small:
        monitor(pen, 20.0, 22.0, 24.0, 18.0, 3.0, stand=False, bezel=bezel)
        monitor(pen, 3.0, 41.0, 24.0, 18.0, 3.0, stand=False, bezel=bezel)
        return
    monitor(pen, 20.0, 24.0, 22.0, 15.0, 3.0, bezel=bezel)
    monitor(pen, 4.0, 38.0, 22.0, 15.0, 3.0, bezel=bezel)


@icon('network', 'Network')
def draw_network(pen):
    ctx = pen.ctx
    ctx.new_path()
    ctx.move_to(14.0, 23.0)
    ctx.line_to(26.0, 30.0)
    pen.stroke(INK, 3.4)
    ctx.new_path()
    ctx.move_to(14.0, 23.0)
    ctx.line_to(26.0, 30.0)
    pen.stroke('#ffd23a', 1.8)
    two_screens(pen)


@icon('internet', 'Internet')
def draw_internet(pen):
    globe(pen, 24.0, 24.0, 19.5 if not pen.small else 21.0)


def drive_box(pen, colour=SILVER):
    """The hard disk's slab: (projection, width, height)."""
    width, depth, height = 32.0, 14.0, 9.0
    origin = (4.0, 40.0)
    if pen.small:
        width, depth, height = 36.0, 10.0, 15.0
        origin = (3.0, 41.0)
    projection = slab(pen, origin[0], origin[1], width, depth, height, colour)
    return projection, width, height


@icon('drive', 'Drive', aliases=('drive-harddisk',))
def draw_drive(pen):
    projection, width, height = drive_box(pen)
    face = projection.front_matrix(0)
    plane_shape(pen, face, rect_path(4.0, -height / 2 - 1.0, width * 0.45, 2.0, 0.6), '#5d6472', None)
    drive_light(pen, projection, width - 4.5, -height / 2)


@icon('drive-removable', 'Removable drive')
def draw_drive_removable(pen):
    projection, width, height = drive_box(pen)
    face = projection.front_matrix(0)
    # A slot for the medium and a blue eject mark.
    plane_shape(pen, face, rect_path(4.0, -height / 2 - 1.2, width * 0.55, 2.4, 1.0), '#2b2f38', None)
    plane_shape(pen, face, poly_path([(width - 8.5, -height / 2 + 0.2), (width - 5.0, -height / 2 + 0.2),
                                      (width - 6.75, -height / 2 - 2.6)]), BLUE, None)
    plane_shape(pen, face, rect_path(width - 8.5, -height / 2 + 1.2, 3.5, 0.9), BLUE, None)


@icon('drive-optical', 'Optical drive')
def draw_drive_optical(pen):
    projection, width, height = drive_box(pen)
    p = projection.point
    face = projection.front_matrix(0)
    plane_shape(pen, face, rect_path(3.0, -height / 2 - 0.8, width - 12.0, 1.6, 0.6), '#2b2f38', None)
    drive_light(pen, projection, width - 4.5, -height / 2, '#ffb03a')
    # A disc lying on the drive's top.
    ctx = pen.ctx
    ctx.save()
    ctx.transform(projection.top_matrix(height))
    cx, cy = width * 0.48, (14.0 if not pen.small else 12.0) * 0.5
    radius = 11.0 if not pen.small else 10.0
    ctx.new_path()
    pen.circle(cx, cy, radius)
    disc = pen.linear(cx - radius, cy - radius, cx + radius, cy + radius,
                      [(0, '#fdfdff'), (0.3, '#c8e8ff'), (0.5, '#ffd6f4'), (0.7, '#d4ffd0'), (1, '#b8c0d0')])
    pen.source(disc)
    ctx.fill_preserve()
    ctx.restore()
    pen.stroke(SILVER_OUTLINE)
    ctx.save()
    ctx.transform(projection.top_matrix(height))
    ctx.new_path()
    pen.circle(cx, cy, radius * 0.25)
    ctx.restore()
    pen.fill('#e8ecf2', SILVER_OUTLINE, pen.thin)


@icon('drive-usb', 'USB drive')
def draw_drive_usb(pen):
    # A stick lying diagonally: the blue body and the metal plug.
    ctx = pen.ctx
    ctx.save()
    ctx.translate(24.0, 26.0)
    ctx.rotate(math.radians(-32))
    body = Projection(-17.0, 6.0)
    box(pen, body, 24.0, 8.0, 10.0, BLUE, outline_of(BLUE))
    plug = Projection(7.0, 3.5)
    box(pen, plug, 10.0, 6.0, 6.0, SILVER, SILVER_OUTLINE, top=SILVER_TOP, side=SILVER_SIDE, gloss=False)
    face = plug.front_matrix(0)
    for u in (2.5, 6.0):
        plane_shape(pen, face, rect_path(u, -4.2, 1.8, 1.8), '#2b2f38', None)
    if not pen.small:
        face = body.front_matrix(0)
        plane_shape(pen, face, circle_path(4.0, -5.0, 1.4), '#7fffb0', None)
    ctx.restore()


@icon('memory-card', 'Memory card')
def draw_memory_card(pen):
    projection = Projection(9.0, 44.0)
    width, height = 26.0, 32.0
    cut = 7.0
    face = projection.front_matrix(0)
    p = projection.point
    depth = 2.5
    pen.shape(poly_path([p(width, 0, 0), p(width, depth, 0), p(width, depth, height), p(width, 0, height)]),
              '#1c1f26', INK, pen.thin)
    pen.shape(poly_path([p(cut, 0, height), p(width, 0, height), p(width, depth, height), p(cut, depth, height)]),
              '#5a606c', INK, pen.thin)
    outline_points = [(0, 0), (width, 0), (width, -height), (cut, -height), (0, -height + cut)]
    plane_shape(pen, face, poly_path(outline_points), pen.vertical('#4a505c', '#262a32', -height, 0), INK)
    # A label and the gold contacts.
    plane_shape(pen, face, rect_path(3.0, -18.0, width - 6.0, 13.0, 1.0), pen.vertical('#5aa0ff', BLUE_DEEP, -18, -5),
                INK, pen.thin)
    contacts = 5 if not pen.small else 3
    for index in range(contacts):
        u = cut + 1.0 + index * (width - cut - 2.0) / contacts
        plane_shape(pen, face, rect_path(u, -height + 1.2, (width - cut - 2.0) / contacts - 1.0, 5.5),
                    pen.vertical(GOLD_LIGHT, GOLD_DEEP, -height, -height + 6), None)


@icon('drive-ssd', 'Solid state drive')
def draw_drive_ssd(pen):
    width, depth, height = 32.0, 18.0, 5.0
    projection = Projection(4.0, 38.0)
    colour = '#3c424e'
    box(pen, projection, width, depth, height, colour, INK, top='#545b69', side='#2a2e36')
    ctx = pen.ctx
    ctx.save()
    ctx.transform(projection.top_matrix(height))
    ctx.new_path()
    pen.rounded(4.0, 3.0, width - 8.0, depth - 6.0, 1.0)
    ctx.restore()
    pen.fill(pen.vertical('#d9dee8', '#9aa3b2', 10, 30), INK, pen.thin)
    if not pen.small:
        ctx.save()
        ctx.transform(projection.top_matrix(height))
        ctx.new_path()
        pen.rounded(8.0, 6.5, width - 16.0, 5.0, 0.6)
        ctx.restore()
        pen.fill(BLUE)
    drive_light(pen, projection, width - 3.5, -height / 2, '#45e04a')


def trash_can(pen, full=False):
    ctx = pen.ctx
    cx = 24.0
    top_y = 13.0
    bottom_y = 44.0
    top_rx, bottom_rx = 14.5, 11.0
    ry = 4.2
    body = pen.linear(cx - top_rx, 0, cx + top_rx, 0, [(0, '#c3c9d3'), (0.35, '#f4f6fa'), (0.7, '#b7bec9'),
                                                        (1, '#7f8794')])
    ctx.new_path()
    ctx.move_to(cx - top_rx, top_y)
    ctx.line_to(cx - bottom_rx, bottom_y)
    ctx.save()
    ctx.translate(cx, bottom_y)
    ctx.scale(bottom_rx, ry * 0.8)
    ctx.arc_negative(0, 0, 1, math.pi, 0)
    ctx.restore()
    ctx.line_to(cx + top_rx, top_y)
    ctx.close_path()
    pen.fill(body, SILVER_OUTLINE)
    # Vertical ribs.
    ribs = 5 if not pen.small else 3
    for index in range(1, ribs):
        t = index / ribs
        ctx.new_path()
        ctx.move_to(cx - top_rx + 2 * top_rx * t, top_y + ry)
        ctx.line_to(cx - bottom_rx + 2 * bottom_rx * t, bottom_y + ry * 0.4)
        pen.stroke(('#5d6472', 0.55), pen.thin * 1.3)
    if full:
        # Crumpled paper over the rim.
        papers = [(cx - 6.0, top_y - 2.0, 6.0), (cx + 5.0, top_y - 3.0, 6.5), (cx, top_y - 7.0, 6.0)]
        if pen.small:
            papers = [(cx - 4.0, top_y - 2.5, 7.0), (cx + 5.0, top_y - 4.0, 6.5)]
        for px, py, radius in papers:
            points = []
            for index in range(9):
                a = index * 2 * math.pi / 9
                r = radius * (1.0 if index % 2 == 0 else 0.78)
                points.append((px + r * math.cos(a), py + r * math.sin(a) * 0.85))
            pen.shape(poly_path(points), pen.vertical('#ffffff', '#cdd4e0', py - radius, py + radius),
                      '#4a5162', pen.thin * 1.4)
    # The rim: an ellipse with the dark inside showing.
    ctx.new_path()
    pen.ellipse(cx, top_y, top_rx, ry)
    if full:
        pen.stroke(SILVER_OUTLINE, pen.line * 2.6)
        ctx.new_path()
        pen.ellipse(cx, top_y, top_rx, ry)
        pen.stroke('#e9edf3', pen.line * 1.2)
    else:
        pen.fill(pen.vertical('#3a3f4a', '#7d8492', top_y - ry, top_y + ry), SILVER_OUTLINE, pen.line * 1.8)
        ctx.new_path()
        pen.ellipse(cx, top_y, top_rx, ry)
        pen.stroke('#eef1f5', pen.thin)


@icon('trash-empty', 'Trash (empty)')
def draw_trash_empty(pen):
    trash_can(pen)


@icon('trash-full', 'Trash (full)')
def draw_trash_full(pen):
    trash_can(pen, True)


@icon('applications', 'Applications')
def draw_applications(pen):
    # A golden box with coloured blocks standing in it.
    blocks = [(15.0, 22.0, '#e04a3a'), (22.0, 18.0, '#3a8ee0'), (26.0, 24.0, '#4ab84a')]
    for x, y, colour in blocks:
        box(pen, Projection(x, y), 8.0, 6.0, 8.0, colour, outline_of(colour))
    projection = Projection(6.0, 44.0)
    box(pen, projection, 28.0, 14.0, 16.0, GOLD, GOLD_OUTLINE, top=GOLD_LIGHT, side=GOLD_DEEP)


@icon('favourites', 'Favourites')
def draw_favourites(pen):
    star(pen, 23.0, 24.0, 20.0 if not pen.small else 22.0)


@icon('library', 'Library')
def draw_library(pen):
    books = [(5.0, '#3a8ee0', 30.0), (13.0, '#4ab84a', 33.0), (21.0, '#e0a83a', 28.0), (29.0, '#8a5ad6', 32.0)]
    for x, colour, height in books:
        projection = Projection(x, 44.0)
        box(pen, projection, 7.5, 9.0, height, colour, outline_of(colour))
        face = projection.front_matrix(0)
        plane_shape(pen, face, rect_path(1.2, -height + 4.0, 5.1, 3.0), lighter(colour, 0.6), None)
