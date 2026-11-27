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

"""Files by type: a sheet of paper in the three-quarter view, its corner
folded, with what kind of file it is drawn on it in the type's colour
(lines of text, a grid, a chart, a picture, a note, a film, a zip, a
window, a gear, a letter A, a question mark)."""

import math

from .catalog import icon, group
from .pen import Projection, lighter, darker, outline_of
from .shapes import (plane_shape, plane_stroke, poly_path, rect_path, circle_path, gear, block_arrow,
                     PAPER, PAPER_SHADE, INK, BLUE, BLUE_DEEP, BLUE_LIGHT, GREEN, GREEN_DEEP, ORANGE, RED, RED_DEEP,
                     PURPLE, GOLD, GOLD_DEEP, GOLD_LIGHT, GOLD_OUTLINE, SILVER, SILVER_SIDE, NAVY, CHARCOAL)
from .folders import note_path, film_strip

PAGE_WIDTH = 26.0
PAGE_HEIGHT = 38.0
FOLD = 8.0
THICKNESS = 2.2
PAGE_OUTLINE = '#3a4152'
PAGE_GROWTH = 1.16


def page_projection():
    return Projection(9.0, 45.5)


def page(pen, content=None, tint=None):
    """The sheet; content(pen) draws on its face in face coordinates:
    u from 0 to PAGE_WIDTH, v from -PAGE_HEIGHT (top) to 0."""
    ctx = pen.ctx
    ctx.save()
    # The sheet is designed narrow: grown about the grid's middle so it
    # fills about as much of the square as the other icons.
    ctx.translate(24.0, 25.0)
    ctx.scale(PAGE_GROWTH, PAGE_GROWTH)
    ctx.translate(-24.0, -25.0)
    projection = page_projection()
    p = projection.point
    w = PAGE_WIDTH
    h = PAGE_HEIGHT
    fold = FOLD if not pen.small else FOLD + 1
    # The sheet's edge at the right and the top (its thickness).
    pen.shape(poly_path([p(w, 0, 0), p(w, THICKNESS, 0), p(w, THICKNESS, h - fold), p(w, 0, h - fold)]),
              '#b9c1cf', PAGE_OUTLINE, pen.thin)
    pen.shape(poly_path([p(0, 0, h), p(w - fold, 0, h), p(w - fold, THICKNESS, h), p(0, THICKNESS, h)]),
              '#eef1f6', PAGE_OUTLINE, pen.thin)
    face = projection.front_matrix(0)
    outline_points = [(0, 0), (w, 0), (w, -h + fold), (w - fold, -h), (0, -h)]
    paper = pen.linear(0, -h, w, 0, [(0, PAPER), (1, tint or PAPER_SHADE)])
    plane_shape(pen, face, poly_path(outline_points), paper)
    if content is not None:
        ctx = pen.ctx
        ctx.save()
        ctx.transform(face)
        ctx.new_path()
        pen.polygon(outline_points)
        ctx.clip()
        content(pen)
        ctx.restore()
    plane_shape(pen, face, poly_path([(w - fold, -h), (w - fold, -h + fold), (w, -h + fold)]),
                pen.linear(w - fold, -h, w, -h + fold, [(0, '#ffffff'), (1, '#c3cad8')]), PAGE_OUTLINE, pen.thin)
    plane_stroke(pen, face, poly_path(outline_points), PAGE_OUTLINE, pen.line / PAGE_GROWTH)
    ctx.restore()


def text_lines(pen, colour=BLUE, top=-29.0, bottom=-6.0, left=4.5, right=21.5, count=None):
    count = count or (6 if not pen.small else 3)
    step = (bottom - top) / max(1, count - 1)
    width = 1.6 if not pen.small else 2.6
    for index in range(count):
        y = top + index * step
        end = right if index % 3 != 2 else left + (right - left) * 0.6
        pen.ctx.new_path()
        pen.ctx.move_to(left, y)
        pen.ctx.line_to(end, y)
        pen.stroke(colour, width)


def corner_badge(pen, colour, glyph=None):
    """A coloured tab at the page's bottom left with an optional glyph."""
    pen.shape(rect_path(-1.5, -14.0, 15.0, 11.0, 1.5),
              pen.vertical(lighter(colour, 0.3), darker(colour, 0.15), -14, -3), outline_of(colour), pen.thin)
    if glyph is not None:
        glyph(pen, 6.0, -8.5)


group('Files')


@icon('file', 'File')
def draw_file(pen):
    page(pen)


@icon('file-text', 'Text')
def draw_text(pen):
    page(pen, lambda pen: text_lines(pen, '#4a6fae'))


@icon('file-document', 'Document')
def draw_document(pen):
    def content(pen):
        # A heading bar, then a paragraph, and a blue band at the top.
        pen.shape(rect_path(0, -38, 26, 7), pen.vertical(BLUE_LIGHT, BLUE, -38, -31))
        if pen.small:
            text_lines(pen, BLUE_DEEP, -25, -7, count=3)
            return
        pen.shape(rect_path(4.5, -27.5, 12, 3), BLUE_DEEP)
        text_lines(pen, '#5a76a8', -20, -6, count=5)
    page(pen, content)


@icon('file-spreadsheet', 'Spreadsheet')
def draw_spreadsheet(pen):
    def content(pen):
        left, top, right, bottom = 3.5, -31.0, 22.5, -5.0
        rows = 6 if not pen.small else 3
        columns = 3 if not pen.small else 2
        pen.shape(rect_path(left, top, right - left, bottom - top), '#e9f7e4')
        pen.shape(rect_path(left, top, right - left, (bottom - top) / rows), lighter(GREEN, 0.25))
        ctx = pen.ctx
        ctx.new_path()
        for index in range(rows + 1):
            y = top + index * (bottom - top) / rows
            ctx.move_to(left, y)
            ctx.line_to(right, y)
        for index in range(columns + 1):
            x = left + index * (right - left) / columns
            ctx.move_to(x, top)
            ctx.line_to(x, bottom)
        pen.stroke(GREEN_DEEP, 1.0 if not pen.small else 1.8)
    page(pen, content)


@icon('file-presentation', 'Presentation')
def draw_presentation(pen):
    def content(pen):
        pen.shape(rect_path(3.0, -31.0, 20.0, 15.0, 1.0), pen.vertical('#fff1e0', '#ffd7ad', -31, -16), ORANGE,
                  1.0 if not pen.small else 1.6)
        bars = [(6.0, 5.0), (11.0, 9.0), (16.0, 7.0)]
        for x, height in bars:
            pen.shape(rect_path(x, -17.5 - height, 3.6, height), pen.vertical(lighter(ORANGE, 0.2), RED, -27, -17))
        if not pen.small:
            text_lines(pen, '#b0703a', -11, -6, count=2)
    page(pen, content)


@icon('file-pdf', 'PDF')
def draw_pdf(pen):
    def content(pen):
        # A red band at the top, the text, and a red seal at the foot.
        pen.shape(rect_path(0, -38, 26, 7), pen.vertical(RED_LIGHT_LOCAL, RED, -38, -31))
        text_lines(pen, '#7a8396', -26, -14, count=4 if not pen.small else 2)
        pen.shape(circle_path(17.5, -8.5, 5.0 if not pen.small else 6.0),
                  pen.vertical(RED_LIGHT_LOCAL, RED_DEEP, -14, -3), RED_DEEP, pen.thin)
        if not pen.small:
            pen.ctx.new_path()
            pen.circle(17.5, -8.5, 3.0)
            pen.stroke((1, 1, 1), 1.0)
    page(pen, content)


RED_LIGHT_LOCAL = '#ff9c8a'


@icon('file-image', 'Image')
def draw_image(pen):
    def content(pen):
        left, top, width, height = 3.0, -32.0, 20.0, 24.0
        pen.shape(rect_path(left, top, width, height), pen.vertical('#a8dcff', '#4d98e6', top, top + height))
        pen.shape(poly_path([(left, top + height), (left, top + 15), (left + 7, top + 9), (left + 13, top + 16),
                             (left + 16, top + 13), (left + width, top + 18), (left + width, top + height)]),
                  pen.vertical(GREEN_LIGHT_LOCAL, GREEN_DEEP, top + 9, top + height))
        pen.shape(circle_path(left + 14.5, top + 5.5, 2.6), '#fff07a')
        pen.ctx.new_path()
        pen.rounded(left, top, width, height, 0)
        pen.stroke(INK, pen.thin)
    page(pen, content)


GREEN_LIGHT_LOCAL = '#a6e878'


@icon('file-audio', 'Audio')
def draw_audio(pen):
    def content(pen):
        note_path(pen, 13.0, -18.0, 18.0)
        pen.fill(pen.vertical(PURPLE, darker(PURPLE, 0.3), -27, -9), INK, pen.thin * 1.2)
    page(pen, content)


@icon('file-video', 'Video')
def draw_video(pen):
    page(pen, lambda pen: film_strip(pen, 13.0, -18.0, 19.0))


@icon('file-archive', 'Archive')
def draw_archive(pen):
    def content(pen):
        # A small golden box with a zipper over it.
        pen.shape(rect_path(4.0, -30.0, 18.0, 24.0, 1.5), pen.vertical(GOLD_LIGHT, GOLD_DEEP, -30, -6), GOLD_OUTLINE,
                  pen.thin)
        pen.shape(rect_path(11.5, -30.0, 3.0, 24.0), '#6e7480')
        teeth = 5 if not pen.small else 3
        for index in range(teeth):
            y = -29 + index * 18.0 / teeth
            pen.shape(rect_path(10.0 if index % 2 == 0 else 13.0, y, 3.0, 1.8), SILVER, INK, pen.thin * 0.7)
        pen.shape(rect_path(10.0, -12.0, 6.0, 5.0, 1.0), pen.vertical('#ffffff', '#99a2b0', -12, -7), INK, pen.thin)
    page(pen, content)


@icon('file-executable', 'Program')
def draw_executable(pen):
    def content(pen):
        # A little window with a blue title bar.
        pen.shape(rect_path(2.5, -30.0, 21.0, 20.0, 1.2), '#eef1f7', INK, pen.thin * 1.4)
        pen.shape(rect_path(3.2, -29.3, 19.6, 4.6), pen.vertical(BLUE_LIGHT, BLUE_DEEP, -29, -25))
        if not pen.small:
            pen.shape(rect_path(5.5, -21.0, 6.5, 6.5), '#cfd6e4', INK, pen.thin)
            text_lines(pen, '#7a8396', -20, -15, left=14, right=21, count=2)
    page(pen, content)


@icon('file-settings', 'Settings file')
def draw_settings_file(pen):
    page(pen, lambda pen: gear(pen, 13.0, -18.0, 8.5 if not pen.small else 9.5, '#8f99aa', 8))


def letter_a(pen, x, y, size, colour):
    """A bold capital A, its bottom centre at (x, y)."""
    w = size * 0.9
    stem = size * 0.24
    points = [(x - w / 2, y), (x - w * 0.12, y - size), (x + w * 0.12, y - size), (x + w / 2, y),
              (x + w / 2 - stem, y), (x + w * 0.18, y - size * 0.3), (x - w * 0.18, y - size * 0.3),
              (x - w / 2 + stem, y)]
    pen.shape(poly_path(points), pen.vertical(lighter(colour, 0.35), darker(colour, 0.2), y - size, y), INK,
              pen.thin * 1.2)
    pen.shape(poly_path([(x - w * 0.1, y - size * 0.48), (x + w * 0.1, y - size * 0.48), (x, y - size * 0.78)]),
              PAPER, INK, pen.thin)


@icon('file-font', 'Font')
def draw_font(pen):
    page(pen, lambda pen: letter_a(pen, 13.0, -7.0, 22.0, PURPLE))


@icon('file-unknown', 'Unknown')
def draw_unknown(pen):
    def content(pen):
        ctx = pen.ctx
        ctx.new_path()
        ctx.arc(13.0, -24.0, 5.5, math.radians(190), math.radians(400))
        ctx.line_to(13.0, -15.0)
        pen.stroke(INK, 5.4 if not pen.small else 6.4)
        ctx.new_path()
        ctx.arc(13.0, -24.0, 5.5, math.radians(190), math.radians(400))
        ctx.line_to(13.0, -15.0)
        pen.stroke(BLUE, 3.2 if not pen.small else 4.0)
        pen.shape(circle_path(13.0, -9.0, 2.4 if not pen.small else 3.0), BLUE, INK, pen.thin)
    page(pen, content)
