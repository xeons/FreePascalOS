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

"""Actions and messages: blue arrows (back, forward, up, undo, redo), a
green refresh, a red cross (delete), a green plus and a red minus, the
magnifier (search), binoculars (find), a gear (options), the round
information, error and question badges and the warning sign (also the
message boxes' pictures), and the editing commands: new, open, save,
print, cut, copy, paste, bold, play, stop, zoom."""

import math

import cairo

from .catalog import icon, group
from .pen import Projection, lighter, darker, outline_of
from .shapes import (box, plane_shape, plane_stroke, poly_path, rect_path, circle_path, block_arrow, curved_arrow,
                     gear, badge, sphere, sphere_gloss, magnifier, warning_triangle, padlock, glyph_plus, glyph_info, glyph_cross,
                     glyph_question, glyph_exclamation, BLUE, BLUE_LIGHT, BLUE_DEEP, GREEN, GREEN_LIGHT, GREEN_DEEP,
                     RED, RED_LIGHT, RED_DEEP, INK, SILVER, SILVER_TOP, SILVER_SIDE, SILVER_OUTLINE, CHARCOAL, GOLD,
                     GOLD_LIGHT, GOLD_DEEP, GOLD_OUTLINE, PAPER)
from .folders import folder
from .filetypes import page, text_lines

group('Actions')


def arrow_size(pen):
    if pen.small:
        return dict(length=42.0, shaft=15.0, head=32.0, head_length=19.0)
    return dict(length=40.0, shaft=13.0, head=28.0, head_length=18.0)


@icon('action-back', 'Back')
def draw_back(pen):
    block_arrow(pen, 23.0, 23.0, 180, BLUE, **arrow_size(pen))


@icon('action-forward', 'Forward')
def draw_forward(pen):
    block_arrow(pen, 24.0, 23.0, 0, BLUE, **arrow_size(pen))


@icon('action-up', 'Up')
def draw_up(pen):
    block_arrow(pen, 23.0, 24.0, 270, BLUE, **arrow_size(pen))


@icon('action-down', 'Down')
def draw_down(pen):
    block_arrow(pen, 23.0, 23.0, 90, BLUE, **arrow_size(pen))


@icon('action-refresh', 'Refresh')
def draw_refresh(pen):
    width = 8.0 if not pen.small else 10.0
    radius = 14.0 if not pen.small else 13.5
    curved_arrow(pen, 24.0, 24.0, radius, 190, 330, GREEN, width)
    curved_arrow(pen, 24.0, 24.0, radius, 10, 150, GREEN, width)


def thick_cross(pen, x, y, size, colour):
    half = size / 2
    arm = size * 0.17
    # The twelve corners of an X.
    points = []
    for index in range(4):
        a = math.radians(45 + 90 * index)
        ux, uy = math.cos(a), math.sin(a)
        px, py = -uy, ux
        points.append((x + ux * half - px * arm, y + uy * half - py * arm))
        points.append((x + ux * half + px * arm, y + uy * half + py * arm))
        c = math.radians(90 + 90 * index)
        points.append((x + math.cos(c) * arm * math.sqrt(2), y + math.sin(c) * arm * math.sqrt(2)))
    return points


def solid_mark(pen, points, colour, depth=2.2):
    outline = outline_of(colour)
    if pen.small:
        depth *= 0.6
    pen.shape(poly_path([(px + depth * 0.5, py + depth) for px, py in points]), darker(colour, 0.45), outline)
    top = min(py for px, py in points)
    bottom = max(py for px, py in points)
    pen.shape(poly_path(points), pen.vertical(lighter(colour, 0.4), darker(colour, 0.1), top, bottom), outline)
    if not pen.tiny:
        pen.gloss(poly_path(points), top, top + (bottom - top) * 0.55, 0.5)
        pen.ctx.new_path()
        pen.polygon(points)
        pen.stroke(outline)


def plus_points(x, y, size, arm):
    half = size / 2
    a = arm / 2
    return [(x - a, y - half), (x + a, y - half), (x + a, y - a), (x + half, y - a), (x + half, y + a), (x + a, y + a),
            (x + a, y + half), (x - a, y + half), (x - a, y + a), (x - half, y + a), (x - half, y - a), (x - a, y - a)]


@icon('action-delete', 'Delete')
def draw_delete(pen):
    size = 36.0 if not pen.small else 40.0
    solid_mark(pen, thick_cross(pen, 23.0, 23.0, size, RED), RED)


@icon('action-add', 'Add')
def draw_add(pen):
    size = 36.0 if not pen.small else 40.0
    solid_mark(pen, plus_points(23.0, 23.0, size, size * 0.34), GREEN)


@icon('action-remove', 'Remove')
def draw_remove(pen):
    size = 36.0 if not pen.small else 40.0
    arm = size * 0.34
    solid_mark(pen, [(23.0 - size / 2, 23.0 - arm / 2), (23.0 + size / 2, 23.0 - arm / 2),
                     (23.0 + size / 2, 23.0 + arm / 2), (23.0 - size / 2, 23.0 + arm / 2)], RED)


@icon('action-search', 'Search')
def draw_search(pen):
    magnifier(pen, 19.0, 19.0, 12.0 if not pen.small else 13.0, 1.0)


@icon('action-find', 'Find')
def draw_find(pen):
    # Binoculars: two barrels joined at the top.
    for x in (14.0, 32.0):
        pen.shape(rect_path(x - 7.0, 12.0, 14.0, 24.0, 4.0), pen.linear(x - 7, 0, x + 7, 0,
                                                                         [(0, '#5a8ee8'), (0.4, '#a8ccff'),
                                                                          (1, BLUE_DEEP)]), INK)
        pen.shape(circle_path(x, 38.0, 7.5), pen.radial(x - 2, 36, 9, [(0, '#e0f0ff'), (1, '#3a6ab8')]), INK)
        pen.ctx.new_path()
        pen.circle(x, 38.0, 4.0)
        pen.fill('#1a2a4a')
    pen.shape(rect_path(19.0, 16.0, 10.0, 9.0, 1.5), '#3a3f4a', INK)


@icon('action-options', 'Options')
def draw_options(pen):
    gear(pen, 24.0, 24.0, 19.0 if not pen.small else 21.0, '#9aa3b2', 10 if not pen.small else 8)


def round_badge(pen, colour, glyph):
    badge(pen, 24.0, 24.0, 19.5 if not pen.small else 21.5, colour, glyph)


@icon('action-info', 'Information', aliases=('dialog-information',))
def draw_info(pen):
    round_badge(pen, BLUE, glyph_info)


@icon('action-error', 'Error', aliases=('dialog-error',))
def draw_error(pen):
    round_badge(pen, RED, glyph_cross)


@icon('action-question', 'Question', aliases=('dialog-question',))
def draw_question(pen):
    round_badge(pen, BLUE, glyph_question)


@icon('action-warning', 'Warning', aliases=('dialog-warning',))
def draw_warning(pen):
    warning_triangle(pen, 24.0, 25.0, 42.0 if not pen.small else 46.0)


def starburst(pen, x, y, radius):
    points = []
    for index in range(16):
        r = radius if index % 2 == 0 else radius * 0.62
        a = math.radians(index * 22.5 - 90)
        points.append((x + r * math.cos(a), y + r * math.sin(a)))
    pen.shape(poly_path(points), pen.radial(x, y, radius, [(0, '#fff8b0'), (1, GOLD)]), GOLD_OUTLINE, pen.thin * 1.4)


@icon('action-new', 'New')
def draw_new(pen):
    page(pen)
    starburst(pen, 13.0, 13.0, 10.0 if not pen.small else 12.0)


@icon('action-open', 'Open')
def draw_open(pen):
    folder(pen, papers=True, open_front=True)
    if not pen.small:
        block_arrow(pen, 33.0, 13.0, 300, GREEN, length=18.0, shaft=6.0, head=13.0, head_length=8.0, depth=1.2)


@icon('action-save', 'Save')
def draw_save(pen):
    # A diskette in the three-quarter view.
    projection = Projection(7.0, 43.0)
    width, height = 32.0, 34.0
    box(pen, projection, width, 3.0, height, '#3a5aa8', '#101a3a', top='#7a9ae0', side='#22386e')
    face = projection.front_matrix(0)
    plane_shape(pen, face, rect_path(6.0, -height, 20.0, 12.0), pen.vertical('#e8ecf2', '#9aa3b2', -height, -height + 12),
                '#101a3a', pen.thin)
    plane_shape(pen, face, rect_path(19.0, -height + 2.0, 4.0, 8.0), '#3a5aa8', None)
    plane_shape(pen, face, rect_path(4.5, -17.0, width - 9.0, 15.0, 1.0), PAPER, '#101a3a', pen.thin)
    if not pen.small:
        plane_stroke(pen, face, lambda pen: (pen.ctx.move_to(8.0, -12.0), pen.ctx.line_to(24.0, -12.0),
                                             pen.ctx.move_to(8.0, -7.0), pen.ctx.line_to(24.0, -7.0)),
                     '#9aa8c4', pen.thin * 1.5)


@icon('action-print', 'Print')
def draw_print(pen):
    from .devices import printer
    printer(pen)


def scissors(pen):
    ctx = pen.ctx
    for sign in (-1, 1):
        ctx.new_path()
        ctx.move_to(24.0, 24.0)
        ctx.line_to(24.0 + sign * 10.0, 4.0)
        pen.stroke(INK, 5.4)
        ctx.new_path()
        ctx.move_to(24.0, 24.0)
        ctx.line_to(24.0 + sign * 10.0, 4.0)
        pen.stroke(SILVER, 3.0)
    for sign in (-1, 1):
        ctx.new_path()
        pen.circle(24.0 + sign * 8.5, 35.0, 6.5)
        pen.stroke(INK, 5.4)
        ctx.new_path()
        pen.circle(24.0 + sign * 8.5, 35.0, 6.5)
        pen.stroke(RED, 3.2)
        ctx.new_path()
        ctx.move_to(24.0, 24.0)
        ctx.line_to(24.0 + sign * 6.0, 30.0)
        pen.stroke(INK, 5.0)
        ctx.new_path()
        ctx.move_to(24.0, 24.0)
        ctx.line_to(24.0 + sign * 6.0, 30.0)
        pen.stroke(RED, 2.8)
    ctx.new_path()
    pen.circle(24.0, 24.0, 1.8)
    pen.fill(SILVER, INK, pen.thin)


@icon('action-cut', 'Cut')
def draw_cut(pen):
    scissors(pen)


def small_sheet(pen, x, y, width, height, lines=True):
    projection = Projection(x, y)
    box(pen, projection, width, 1.6, height, PAPER, '#3a4152', top='#eef1f6', side='#b9c1cf', gloss=False)
    if lines and not pen.tiny:
        face = projection.front_matrix(0)
        count = 4 if not pen.small else 2
        for index in range(count):
            v = -height + 5.0 + index * (height - 9.0) / max(1, count - 1)
            plane_stroke(pen, face, lambda pen, v=v: (pen.ctx.move_to(3.0, v), pen.ctx.line_to(width - 3.0, v)),
                         '#5a7ab8', 1.4 if not pen.small else 2.2)


@icon('action-copy', 'Copy')
def draw_copy(pen):
    small_sheet(pen, 6.0, 34.0, 22.0, 28.0)
    small_sheet(pen, 18.0, 45.0, 22.0, 28.0)


@icon('action-paste', 'Paste')
def draw_paste(pen):
    projection = Projection(6.0, 44.0)
    width, height = 28.0, 36.0
    box(pen, projection, width, 3.0, height, '#c08a4a', '#4a2a0c', top='#e8b878', side='#8a5a28')
    face = projection.front_matrix(0)
    plane_shape(pen, face, rect_path(8.0, -height - 2.0, 12.0, 6.0, 1.5), pen.vertical(SILVER_TOP, SILVER_SIDE,
                                                                                        -height - 2, -height + 4),
                SILVER_OUTLINE, pen.thin)
    small_sheet(pen, 20.0, 46.0, 20.0, 24.0)


def swoop(pen, mirrored):
    """A curved arrow over the top, pointing left (undo) or right."""
    ctx = pen.ctx
    ctx.save()
    if mirrored:
        ctx.translate(48.0, 0)
        ctx.scale(-1.0, 1.0)
    width = 8.0 if not pen.small else 10.0
    curved_arrow(pen, 27.0, 30.0, 14.0, -10, -150, BLUE, width)
    ctx.restore()


@icon('action-undo', 'Undo')
def draw_undo(pen):
    swoop(pen, False)


@icon('action-redo', 'Redo')
def draw_redo(pen):
    swoop(pen, True)


@icon('action-bold', 'Bold')
def draw_bold(pen):
    # A heavy capital B of shapes.
    ctx = pen.ctx
    ctx.new_path()
    left, top, bottom = 11.0, 6.0, 42.0
    middle = 23.0
    ctx.move_to(left, top)
    ctx.line_to(26.0, top)
    ctx.curve_to(36.0, top, 36.5, middle - 1.0, 28.0, middle)
    ctx.curve_to(38.5, middle + 1.0, 38.5, bottom, 27.0, bottom)
    ctx.line_to(left, bottom)
    ctx.close_path()
    ctx.new_sub_path()
    ctx.move_to(19.0, 12.5)
    ctx.line_to(19.0, 19.5)
    ctx.line_to(24.5, 19.5)
    ctx.curve_to(28.5, 19.5, 28.5, 12.5, 24.5, 12.5)
    ctx.close_path()
    ctx.new_sub_path()
    ctx.move_to(19.0, 26.0)
    ctx.line_to(19.0, 35.5)
    ctx.line_to(25.5, 35.5)
    ctx.curve_to(30.5, 35.5, 30.5, 26.0, 25.5, 26.0)
    ctx.close_path()
    ctx.set_fill_rule(cairo.FILL_RULE_EVEN_ODD)
    pen.fill(pen.vertical('#5a6478', INK, top, bottom), INK)
    ctx.set_fill_rule(cairo.FILL_RULE_WINDING)


@icon('action-play', 'Play')
def draw_play(pen):
    solid_mark(pen, [(13.0, 7.0), (40.0, 23.0), (13.0, 39.0)] if not pen.small else
               [(11.0, 5.0), (42.0, 23.0), (11.0, 41.0)], GREEN)


@icon('action-stop', 'Stop')
def draw_stop(pen):
    inset = 9.0 if not pen.small else 7.0
    solid_mark(pen, [(inset, inset), (46.0 - inset, inset), (46.0 - inset, 46.0 - inset), (inset, 46.0 - inset)], RED)


@icon('action-pause', 'Pause')
def draw_pause(pen):
    for x in (10.0, 27.0):
        solid_mark(pen, [(x, 8.0), (x + 10.0, 8.0), (x + 10.0, 38.0), (x, 38.0)], BLUE)


@icon('action-zoom', 'Zoom')
def draw_zoom(pen):
    magnifier(pen, 19.0, 19.0, 12.0 if not pen.small else 13.0, 1.0)
    glyph_plus(pen, 19.0, 19.0, 11.0, GREEN_DEEP)


# --- the session's commands (the Start menu) -------------------------------------------------

@icon('action-lock', 'Lock')
def draw_lock(pen):
    size = 30.0 if not pen.small else 34.0
    padlock(pen, 24.0 - size / 2, 46.0 - size * 1.1 - 2.0, size, GOLD)


@icon('action-log-off', 'Log off')
def draw_log_off(pen):
    # A door standing open and an arrow going out through it.
    projection = Projection(6.0, 44.0)
    box(pen, projection, 20.0, 3.0, 36.0, '#c08a4a', '#4a2a0c', top='#e8b878', side='#8a5a28', gloss=False)
    face = projection.front_matrix(0)
    plane_shape(pen, face, rect_path(3.0, -33.0, 14.0, 33.0), pen.vertical('#2a2f3a', '#4a5262', -33, 0), None)
    plane_shape(pen, face, poly_path([(3.0, 0), (3.0, -33.0), (11.0, -30.0), (11.0, 3.0)]),
                pen.vertical('#e0a860', '#a86a2a', -33, 3), '#4a2a0c', pen.thin)
    block_arrow(pen, 31.0, 24.0, 0, GREEN, length=26.0 if not pen.small else 30.0, shaft=9.0, head=20.0,
                head_length=12.0, depth=1.6)


def crescent_path(radius):
    def path(pen):
        pen.circle(24.0, 24.0, radius)
        pen.ctx.new_sub_path()
        pen.ctx.arc_negative(33.0, 17.0, radius * 0.82, 2 * math.pi, 0)
    return path


@icon('action-suspend', 'Suspend')
def draw_suspend(pen):
    # A crescent moon: a disc with a smaller one taken out of it.
    radius = 18.0 if not pen.small else 20.0
    ctx = pen.ctx
    ctx.set_fill_rule(cairo.FILL_RULE_EVEN_ODD)
    ctx.save()
    ctx.new_path()
    pen.circle(24.0, 24.0, radius)
    ctx.clip()
    pen.shape(crescent_path(radius), pen.radial(16.0, 18.0, radius * 1.6, [(0, '#fff6c0'), (0.5, GOLD),
                                                                          (1, GOLD_DEEP)]), GOLD_OUTLINE)
    ctx.restore()
    ctx.set_fill_rule(cairo.FILL_RULE_WINDING)


def glyph_power(pen, x, y, r, colour=(1, 1, 1)):
    ctx = pen.ctx
    ctx.new_path()
    ctx.arc(x, y + r * 0.05, r * 0.5, math.radians(-55), math.radians(235))
    pen.stroke(colour, r * 0.22)
    ctx.new_path()
    ctx.move_to(x, y - r * 0.62)
    ctx.line_to(x, y - r * 0.05)
    pen.stroke(colour, r * 0.22)


@icon('action-shut-down', 'Shut down')
def draw_shut_down(pen):
    round_badge(pen, RED, glyph_power)
