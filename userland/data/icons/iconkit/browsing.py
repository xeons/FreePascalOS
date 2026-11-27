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

"""Browsing files: the file manager's commands (rename, share, sort,
view, filter, more, pin and unpin, star, compress, extract, properties,
select all, new folder, new tab, close, the preview and details panes,
the undo history) and its places (the desktop folder, the gallery,
recent files, a network drive and a network share), in the set's
three-quarter view and shading."""

import math

from .catalog import icon, group
from .pen import Projection, lighter, darker, outline_of
from .shapes import (box, plane_shape, plane_stroke, poly_path, rect_path, circle_path, block_arrow, curved_arrow,
                     gear, sphere, sphere_gloss, glyph_plus, glyph_check, BLUE, BLUE_LIGHT, BLUE_DEEP, NAVY, GREEN,
                     GREEN_DEEP, RED, RED_DEEP, ORANGE, INK, SILVER, SILVER_TOP, SILVER_SIDE, SILVER_OUTLINE,
                     CHARCOAL, GOLD, GOLD_LIGHT, GOLD_DEEP, GOLD_OUTLINE, PAPER, PAPER_SHADE, TEAL)
from .folders import folder
from .filetypes import page, text_lines
from .objects import monitor, star, slab
from .actions import solid_mark, thick_cross

group('Browsing')


# --- pieces shared by several icons ---------------------------------------------------------

def corner_badge_plus(pen, x=36.0, y=12.0):
    """A small green ball with a plus at the top right: something new."""
    radius = 9.0 if not pen.small else 10.5
    sphere(pen, x, y, radius, GREEN)
    glyph_plus(pen, x, y, radius * 1.15)
    if not pen.tiny:
        sphere_gloss(pen, x, y, radius, 0.5)


def window_frame(pen, x, y, width, height, depth=2.5):
    """A window seen from the front a little turned: a silver frame with a
    gold title band and a white client area; returns (face matrix,
    client rectangle in face coordinates: left, top, width, height)."""
    projection = Projection(x, y)
    box(pen, projection, width, depth, height, SILVER, SILVER_OUTLINE, top=SILVER_TOP, side=SILVER_SIDE, gloss=False)
    face = projection.front_matrix(0)
    band = 6.0 if not pen.small else 8.0
    plane_shape(pen, face, rect_path(1.2, -height + 1.2, width - 2.4, band),
                pen.vertical(GOLD_LIGHT, GOLD_DEEP, -height, -height + band), None)
    client = (1.6, -height + band + 1.6, width - 3.2, height - band - 3.2)
    plane_shape(pen, face, rect_path(*client), PAPER, SILVER_OUTLINE, pen.thin)
    return face, client


def clock_face(pen, x, y, radius, hour_angle=300.0, minute_angle=60.0):
    """A round clock: a blue rim, a white face, ticks and two hands."""
    ring = max(2.4, radius * 0.2)
    sphere(pen, x, y, radius, BLUE)
    face = pen.radial(x - radius * 0.3, y - radius * 0.3, radius, [(0, PAPER), (1, PAPER_SHADE)])
    pen.shape(circle_path(x, y, radius - ring), face, BLUE_DEEP, pen.thin)
    ctx = pen.ctx
    if not pen.small:
        for index in range(12):
            a = math.radians(index * 30)
            inner = radius - ring - (2.4 if index % 3 == 0 else 1.4)
            ctx.new_path()
            ctx.move_to(x + math.cos(a) * inner, y + math.sin(a) * inner)
            ctx.line_to(x + math.cos(a) * (radius - ring - 0.6), y + math.sin(a) * (radius - ring - 0.6))
            pen.stroke(CHARCOAL, pen.thin * 1.4)
    width = 2.2 if not pen.small else 3.0
    for angle, length in ((hour_angle, 0.45), (minute_angle, 0.68)):
        a = math.radians(angle - 90)
        ctx.new_path()
        ctx.move_to(x, y)
        ctx.line_to(x + math.cos(a) * (radius - ring) * length / 0.8, y + math.sin(a) * (radius - ring) * length / 0.8)
        pen.stroke(INK, width)
    ctx.new_path()
    pen.circle(x, y, width * 0.7)
    pen.fill(RED)
    if not pen.tiny:
        sphere_gloss(pen, x, y, radius, 0.45)


def pencil(pen, x0, y0, x1, y1, thickness=6.0):
    """An orange pencil from its tip (x0, y0) to its end (x1, y1)."""
    ctx = pen.ctx
    length = math.hypot(x1 - x0, y1 - y0)
    ctx.save()
    ctx.translate(x0, y0)
    ctx.rotate(math.atan2(y1 - y0, x1 - x0))
    half = thickness / 2
    tip = thickness * 1.3
    pen.shape(poly_path([(tip, -half), (length - 3.0, -half), (length - 3.0, half), (tip, half)]),
              pen.linear(0, -half, 0, half, [(0, lighter(ORANGE, 0.4)), (0.5, ORANGE), (1, darker(ORANGE, 0.3))]),
              outline_of(ORANGE))
    pen.shape(rect_path(length - 3.0, -half, 3.0, thickness, 0.8), '#e88aa0', outline_of('#e88aa0'), pen.thin)
    pen.shape(poly_path([(0, 0), (tip, -half), (tip, half)]), '#f2d2a0', '#4a2a0c', pen.thin)
    pen.shape(poly_path([(0, 0), (tip * 0.4, -half * 0.4), (tip * 0.4, half * 0.4)]), INK)
    ctx.restore()


def photo(pen, x, y, width, height, sky='#7cc4ff'):
    """A photograph in a white border: sky, sun and green hills."""
    projection = Projection(x, y)
    box(pen, projection, width, 1.6, height, PAPER, '#3a4152', top='#eef1f6', side='#b9c1cf', gloss=False)
    face = projection.front_matrix(0)
    border = 2.2 if not pen.small else 2.6
    inner = (border, -height + border, width - 2 * border, height - 2 * border)

    def picture(pen):
        l, t, w, h = inner
        pen.shape(rect_path(l, t, w, h), pen.vertical(lighter(sky, 0.3), sky, t, t + h))
        pen.shape(circle_path(l + w * 0.72, t + h * 0.3, h * 0.14), GOLD_LIGHT)
        pen.shape(poly_path([(l, t + h), (l, t + h * 0.62), (l + w * 0.35, t + h * 0.4), (l + w * 0.62, t + h * 0.66),
                             (l + w * 0.8, t + h * 0.55), (l + w, t + h * 0.7), (l + w, t + h)]),
                  pen.vertical(lighter(GREEN, 0.25), GREEN_DEEP, t + h * 0.4, t + h))
    ctx = pen.ctx
    ctx.save()
    ctx.transform(face)
    ctx.new_path()
    pen.rounded(*inner, 0)
    ctx.clip()
    picture(pen)
    ctx.restore()
    plane_stroke(pen, face, rect_path(*inner), '#3a4152', pen.thin)


def cable(pen, points, colour=GREEN):
    ctx = pen.ctx
    for colour_width in ((INK, 4.4 if not pen.small else 5.2), (colour, 2.4 if not pen.small else 3.0)):
        ctx.new_path()
        ctx.move_to(*points[0])
        for point in points[1:]:
            ctx.line_to(*point)
        pen.stroke(colour_width[0], colour_width[1])


def network_plug(pen, x, y):
    """A small blue connector box with the cable running out below."""
    cable(pen, [(x + 3.0, y), (x + 3.0, y + 5.0), (x - 14.0, y + 5.0)], GREEN)
    box(pen, Projection(x - 1.0, y + 1.0), 8.0, 4.0, 6.0, BLUE, outline_of(BLUE), gloss=False)


# --- commands ----------------------------------------------------------------------------------

@icon('action-rename', 'Rename')
def draw_rename(pen):
    # A text field with letters, and a pencil writing in it.
    projection = Projection(3.0, 36.0)
    width, height = 34.0, 16.0
    box(pen, projection, width, 3.0, height, PAPER, '#3a4152', top='#eef1f6', side='#b9c1cf', gloss=False)
    face = projection.front_matrix(0)
    if not pen.small:
        plane_stroke(pen, face, lambda pen: (pen.ctx.move_to(4.0, -8.0), pen.ctx.line_to(17.0, -8.0)), BLUE, 3.0)
    else:
        plane_stroke(pen, face, lambda pen: (pen.ctx.move_to(4.0, -8.0), pen.ctx.line_to(15.0, -8.0)), BLUE, 4.0)
    plane_stroke(pen, face, lambda pen: (pen.ctx.move_to(21.0, -13.0), pen.ctx.line_to(21.0, -3.0)), INK,
                 1.6 if not pen.small else 2.4)
    pencil(pen, 24.0, 30.0, 44.0, 6.0, 6.0 if not pen.small else 7.5)


@icon('action-share', 'Share')
def draw_share(pen):
    # Three balls joined: one handing on to two.
    nodes = [(13.0, 24.0), (35.0, 11.0), (35.0, 37.0)]
    ctx = pen.ctx
    for target in nodes[1:]:
        for colour, width in ((INK, 4.6 if not pen.small else 5.4), (SILVER, 2.6 if not pen.small else 3.2)):
            ctx.new_path()
            ctx.move_to(*nodes[0])
            ctx.line_to(*target)
            pen.stroke(colour, width)
    radius = 7.5 if not pen.small else 9.0
    for (x, y), colour in zip(nodes, (BLUE, GREEN, GREEN)):
        sphere(pen, x, y, radius, colour)
        if not pen.tiny:
            sphere_gloss(pen, x, y, radius, 0.6)


@icon('action-sort', 'Sort')
def draw_sort(pen):
    small = pen.small
    block_arrow(pen, 14.0, 24.0, 270, BLUE, length=40.0 if not small else 44.0, shaft=9.0 if not small else 11.0,
                head=20.0 if not small else 22.0, head_length=12.0, depth=1.6)
    block_arrow(pen, 33.0, 24.0, 90, GREEN, length=40.0 if not small else 44.0, shaft=9.0 if not small else 11.0,
                head=20.0 if not small else 22.0, head_length=12.0, depth=1.6)


@icon('action-view', 'View')
def draw_view(pen):
    # Four tiles in a grid, lying back like the set's boxes.
    colours = [BLUE, GOLD, GREEN, '#8a5ad6']
    size = 15.0 if not pen.small else 16.0
    gap = 3.0 if not pen.small else 2.0
    positions = [(5.0, 42.0), (5.0 + size + gap, 42.0 - (size + gap) * Projection.RISE)]
    positions = [(x, y - row * (size + gap)) for row in (1, 0) for x, y in positions]
    for (x, y), colour in zip(positions, colours):
        box(pen, Projection(x, y), size, 3.0, size, colour, outline_of(colour))


@icon('action-filter', 'Filter')
def draw_filter(pen):
    # A funnel: a wide rim narrowing to a spout.
    rim_y = 9.0
    top = [(4.0, rim_y), (44.0, rim_y), (29.0, 26.0), (29.0, 41.0), (19.0, 45.0), (19.0, 26.0)]
    pen.shape(poly_path(top), pen.linear(4, 0, 44, 0, [(0, lighter(BLUE, 0.35)), (0.45, BLUE), (1, BLUE_DEEP)]),
              outline_of(BLUE))
    pen.ctx.new_path()
    pen.ellipse(24.0, rim_y, 20.0, 4.0 if not pen.small else 3.0)
    pen.fill(pen.vertical(BLUE_DEEP, lighter(BLUE, 0.5), rim_y - 4, rim_y + 4), outline_of(BLUE))
    if not pen.tiny:
        pen.gloss(poly_path(top), rim_y, 30.0, 0.45)


@icon('action-more', 'More')
def draw_more(pen):
    radius = 5.5 if not pen.small else 6.5
    for x in (9.0, 24.0, 39.0):
        sphere(pen, x, 25.0, radius, SILVER_SIDE, SILVER_OUTLINE)
        if not pen.tiny:
            sphere_gloss(pen, x, 25.0, radius, 0.7)


def pushpin(pen):
    ctx = pen.ctx
    # The needle, then the head over it.
    for colour, width in ((SILVER_OUTLINE, 3.6 if not pen.small else 4.4), (SILVER, 1.8 if not pen.small else 2.4)):
        ctx.new_path()
        ctx.move_to(22.0, 26.0)
        ctx.line_to(7.0, 42.0)
        pen.stroke(colour, width)
    ctx.save()
    ctx.translate(28.0, 19.0)
    ctx.rotate(math.radians(45))
    pen.shape(rect_path(-9.0, -3.0, 18.0, 6.0, 2.0), pen.vertical(lighter(RED, 0.3), RED_DEEP, -3, 3), outline_of(RED))
    pen.shape(rect_path(-5.0, -14.0, 10.0, 12.0, 2.0), pen.linear(-5, 0, 5, 0, [(0, lighter(RED, 0.4)), (1, RED)]),
              outline_of(RED))
    pen.shape(rect_path(-8.0, -19.0, 16.0, 6.0, 3.0), pen.vertical(lighter(RED, 0.5), RED, -19, -13), outline_of(RED))
    ctx.restore()


@icon('action-pin', 'Pin')
def draw_pin(pen):
    pushpin(pen)


@icon('action-unpin', 'Unpin')
def draw_unpin(pen):
    pushpin(pen)
    ctx = pen.ctx
    for colour, width in ((INK, 6.4 if not pen.small else 7.2), ((1.0, 1.0, 1.0), 3.8 if not pen.small else 4.6)):
        ctx.new_path()
        ctx.move_to(8.0, 8.0)
        ctx.line_to(40.0, 40.0)
        pen.stroke(colour, width)


@icon('action-star', 'Star')
def draw_star(pen):
    star(pen, 23.0, 24.0, 20.0 if not pen.small else 22.0)


def archive_box(pen):
    projection = Projection(10.0, 44.0)
    width, height = 26.0, 22.0
    box(pen, projection, width, 10.0, height, GOLD, GOLD_OUTLINE, top=GOLD_LIGHT, side=GOLD_DEEP)
    face = projection.front_matrix(0)
    # A strap round it.
    plane_shape(pen, face, rect_path(width / 2 - 2.0, -height, 4.0, height), pen.vertical('#8a5a28', '#5a3a14',
                                                                                          -height, 0), None)
    return projection


@icon('action-compress', 'Compress')
def draw_compress(pen):
    archive_box(pen)
    small = pen.small
    for x, angle in ((7.0, 0), (41.0, 180)):
        block_arrow(pen, x, 30.0, angle, BLUE, length=14.0 if not small else 16.0, shaft=5.0 if not small else 6.5,
                    head=12.0 if not small else 14.0, head_length=7.0, depth=1.0)


@icon('action-extract', 'Extract')
def draw_extract(pen):
    archive_box(pen)
    block_arrow(pen, 24.0, 14.0, 270, GREEN, length=24.0 if not pen.small else 26.0, shaft=8.0 if not pen.small else 10.0,
                head=18.0 if not pen.small else 21.0, head_length=10.0, depth=1.4)


@icon('action-properties', 'Properties')
def draw_properties(pen):
    page(pen, lambda pen: text_lines(pen, BLUE_DEEP))
    gear(pen, 35.0, 35.0, 11.0 if not pen.small else 12.5, '#9aa3b2', 8 if not pen.small else 6)


@icon('action-select-all', 'Select all')
def draw_select_all(pen):
    # Tiles inside a dashed selection, with a check.
    ctx = pen.ctx
    size = 11.0 if not pen.small else 13.0
    for row in range(2):
        for column in range(2):
            x = 9.0 + column * (size + 3.0)
            y = 22.0 + row * (size + 3.0)
            pen.shape(rect_path(x, y - size, size, size, 1.2), pen.vertical(lighter(BLUE, 0.4), BLUE, y - size, y),
                      outline_of(BLUE), pen.thin * 1.4)
    if not pen.tiny:
        ctx.new_path()
        pen.rounded(4.0, 4.0, 36.0, 36.0, 2.0)
        ctx.set_dash([3.0, 2.2])
        pen.stroke(NAVY, 1.6 if not pen.small else 2.4)
        ctx.set_dash([])
    radius = 8.5 if not pen.small else 10.0
    sphere(pen, 37.0, 37.0, radius, GREEN)
    glyph_check(pen, 37.0, 37.0, radius * 1.1)


@icon('action-new-folder', 'New folder')
def draw_new_folder(pen):
    folder(pen)
    corner_badge_plus(pen, 37.0, 11.0)


@icon('action-new-tab', 'New tab')
def draw_new_tab(pen):
    # A window with a tab standing on its top edge.
    projection = Projection(4.0, 44.0)
    width, height = 32.0, 24.0
    p = projection.point
    tab = [p(2.0, 0, height - 0.5), p(3.5, 0, height + 6.0), p(15.0, 0, height + 6.0), p(16.5, 0, height - 0.5)]
    pen.shape(poly_path(tab), pen.vertical(GOLD_LIGHT, GOLD, p(0, 0, height + 6)[1], p(0, 0, height)[1]), GOLD_OUTLINE)
    box(pen, projection, width, 3.0, height, SILVER, SILVER_OUTLINE, top=SILVER_TOP, side=SILVER_SIDE, gloss=False)
    face = projection.front_matrix(0)
    plane_shape(pen, face, rect_path(1.6, -height + 1.6, width - 3.2, height - 3.2), PAPER, SILVER_OUTLINE, pen.thin)
    corner_badge_plus(pen, 37.0, 13.0)


@icon('action-close', 'Close')
def draw_close(pen):
    size = 30.0 if not pen.small else 36.0
    solid_mark(pen, thick_cross(pen, 23.0, 23.0, size, CHARCOAL), CHARCOAL)


def pane_window(pen):
    """A window split in two, its right pane shaded; returns the face and
    the right pane (left, top, width, height)."""
    face, (left, top, width, height) = window_frame(pen, 3.0, 43.0, 36.0, 30.0)
    split = left + width * 0.5
    pane = (split, top, left + width - split, height)
    plane_shape(pen, face, rect_path(*pane), pen.vertical('#e4ecfa', '#c8d6f0', top, top + height), None)
    plane_stroke(pen, face, lambda pen: (pen.ctx.move_to(split, top), pen.ctx.line_to(split, top + height)),
                 SILVER_OUTLINE, pen.thin * 1.4)
    if not pen.small:
        for index in range(3):
            y = top + 4.0 + index * 5.0
            plane_stroke(pen, face, lambda pen, y=y: (pen.ctx.move_to(left + 2.0, y),
                                                      pen.ctx.line_to(split - 2.5, y)), '#9aa8c4', 1.6)
    return face, pane


@icon('action-preview-pane', 'Preview pane')
def draw_preview_pane(pen):
    face, (left, top, width, height) = pane_window(pen)

    def picture(pen):
        pen.shape(rect_path(left + 1.5, top + 2.0, width - 3.0, height - 4.0), pen.vertical('#bfe4ff', '#7cc4ff',
                                                                                             top, top + height))
        pen.shape(poly_path([(left + 1.5, top + height - 2.0), (left + width * 0.45, top + height * 0.45),
                             (left + width - 1.5, top + height - 2.0)]), pen.vertical(GREEN, GREEN_DEEP,
                                                                                      top + height * 0.45,
                                                                                      top + height))
        pen.shape(circle_path(left + width * 0.7, top + height * 0.3, 2.2), GOLD_LIGHT)
    ctx = pen.ctx
    ctx.save()
    ctx.transform(face)
    picture(pen)
    ctx.restore()


@icon('action-details-pane', 'Details pane')
def draw_details_pane(pen):
    face, (left, top, width, height) = pane_window(pen)
    rows = 4 if not pen.small else 2
    for index in range(rows):
        y = top + 4.0 + index * (height - 8.0) / max(1, rows - 1)
        plane_stroke(pen, face, lambda pen, y=y: (pen.ctx.move_to(left + 2.0, y), pen.ctx.line_to(left + 5.0, y)),
                     NAVY, 2.0 if not pen.small else 3.0)
        plane_stroke(pen, face, lambda pen, y=y: (pen.ctx.move_to(left + 7.0, y),
                                                  pen.ctx.line_to(left + width - 2.0, y)),
                     BLUE, 1.6 if not pen.small else 2.6)


@icon('action-undo-history', 'Undo history')
def draw_undo_history(pen):
    clock_face(pen, 26.0, 26.0, 16.0 if not pen.small else 18.0)
    curved_arrow(pen, 26.0, 26.0, 20.0, 160, 260, BLUE_DEEP, 4.0 if not pen.small else 5.0, 0.9)


# --- places --------------------------------------------------------------------------------------

def emblem_desktop(pen, cx, cy, s):
    """A small screen on a stand."""
    w = s * 0.9
    h = s * 0.62
    pen.shape(rect_path(cx - w / 2, cy - h / 2 - s * 0.1, w, h, s * 0.05), '#3a5aa8', INK, pen.thin * 1.2)
    pen.shape(rect_path(cx - w / 2 + s * 0.07, cy - h / 2 - s * 0.03, w - s * 0.14, h - s * 0.14),
              pen.vertical('#7cc4ff', '#2f74d6', cy - h / 2, cy + h / 2))
    pen.shape(rect_path(cx - s * 0.22, cy + h / 2 - s * 0.06, s * 0.44, s * 0.12, s * 0.04), SILVER, INK, pen.thin)


@icon('folder-desktop', 'Desktop')
def draw_folder_desktop(pen):
    folder(pen, emblem_desktop)


@icon('gallery', 'Gallery')
def draw_gallery(pen):
    photo(pen, 4.0, 36.0, 28.0, 22.0, '#9ab8ff')
    photo(pen, 14.0, 46.0, 28.0, 22.0)


@icon('recent', 'Recent')
def draw_recent(pen):
    page(pen, lambda pen: text_lines(pen, BLUE, count=4 if not pen.small else 2, bottom=-18.0))
    clock_face(pen, 31.0, 32.0, 13.0 if not pen.small else 14.5, 120.0, 0.0)


@icon('drive-network', 'Network drive')
def draw_drive_network(pen):
    width, depth, height = 32.0, 12.0, 9.0
    origin = (4.0, 32.0)
    if pen.small:
        width, depth, height = 36.0, 9.0, 13.0
        origin = (3.0, 32.0)
    cable(pen, [(origin[0] + width / 2, origin[1]), (origin[0] + width / 2, 44.0), (44.0, 44.0)])
    cable(pen, [(origin[0] + width / 2, 44.0), (3.0, 44.0)])
    projection = slab(pen, origin[0], origin[1], width, depth, height, SILVER)
    face = projection.front_matrix(0)
    plane_shape(pen, face, rect_path(4.0, -height / 2 - 1.0, width * 0.45, 2.0, 0.6), '#5d6472', None)
    plane_shape(pen, face, circle_path(width - 4.5, -height / 2, 1.6 if not pen.small else 2.2), '#45e04a', INK,
                pen.thin)


@icon('network-share', 'Network share')
def draw_network_share(pen):
    ctx = pen.ctx
    cable(pen, [(22.0, 34.0), (22.0, 43.0), (45.0, 43.0)])
    cable(pen, [(22.0, 43.0), (3.0, 43.0)])
    ctx.save()
    ctx.translate(4.0, -4.0)
    ctx.scale(0.84, 0.84)
    folder(pen)
    ctx.restore()
    box(pen, Projection(18.0, 46.5), 8.0, 3.0, 5.0, BLUE, outline_of(BLUE), gloss=False)
