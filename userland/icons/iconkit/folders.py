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

"""Folders: the golden folder in the three-quarter view (its back with
the tab, the front leaning on it) and the folders with an emblem on
their front: documents, pictures, music, videos, downloads, projects,
public, templates, compressed; and the open folder."""

import math

from .catalog import icon, group
from .pen import Projection, lighter, darker, outline_of
from .shapes import (plane_shape, plane_stroke, poly_path, rect_path, circle_path, block_arrow, gear,
                     GOLD, GOLD_LIGHT, GOLD_DEEP, GOLD_OUTLINE, BLUE, BLUE_DEEP, BLUE_LIGHT, GREEN, PURPLE,
                     RED, PAPER, PAPER_SHADE, INK, SILVER, SILVER_SIDE, NAVY, ORANGE, TEAL)

WIDTH = 34.0
BACK_HEIGHT = 29.0
FRONT_HEIGHT = 24.0
DEPTH = 4.5


def folder_projection():
    return Projection(5.0, 43.0)


def folder(pen, emblem=None, papers=False, colour=GOLD, open_front=False):
    """The folder; emblem(pen, cx, cy, size) is drawn on its front in the
    front's own coordinates (a face matrix is in force)."""
    projection = folder_projection()
    back = projection.front_matrix(DEPTH)
    front = projection.front_matrix(0)
    outline = GOLD_OUTLINE
    width = WIDTH
    tab_width = 13.0
    tab_height = 3.6 if not pen.small else 4.2
    back_points = [(0, 0), (width, 0), (width, -BACK_HEIGHT), (tab_width + 2.5, -BACK_HEIGHT),
                   (tab_width, -BACK_HEIGHT - tab_height), (1.5, -BACK_HEIGHT - tab_height), (0, -BACK_HEIGHT + 0.5)]
    plane_shape(pen, back, poly_path(back_points),
                pen.vertical(lighter(GOLD_DEEP, 0.15), darker(GOLD_DEEP, 0.12), -BACK_HEIGHT - tab_height, 0),
                outline)
    if papers:
        plane_shape(pen, projection.front_matrix(DEPTH * 0.5),
                    rect_path(3.0, -BACK_HEIGHT + 1.5, width - 7.0, BACK_HEIGHT - 2.0, 0.6), PAPER, INK, pen.thin)
    # The front leans forward: its top edge stands a little to the right.
    lean = 2.0 if not open_front else 6.0
    front_height = FRONT_HEIGHT if not open_front else FRONT_HEIGHT - 3.0
    front_points = [(0, 0), (width, 0), (width + lean, -front_height), (lean, -front_height)]
    # The folder's thickness at the right, between back and front.
    p = projection.point
    side = [p(width, 0, 0), p(width, DEPTH, 0), p(width, DEPTH, BACK_HEIGHT * 0.9), p(width + lean, 0, front_height)]
    pen.shape(poly_path(side), darker(GOLD_DEEP, 0.2), outline, pen.thin)
    plane_shape(pen, front, poly_path(front_points),
                pen.linear(0, -front_height, 0, 0, [(0, GOLD_LIGHT), (0.55, GOLD), (1, GOLD_DEEP)]), outline)
    # A sheen on the upper part of the front and a light top edge.
    ctx = pen.ctx
    if not pen.tiny:
        ctx.save()
        ctx.transform(front)
        pen.gloss(poly_path(front_points), -front_height, -front_height * 0.45, 0.5)
        ctx.restore()
    plane_stroke(pen, front, lambda pen: (pen.ctx.move_to(lean + 1.0, -front_height + 0.9),
                                          pen.ctx.line_to(width + lean - 0.6, -front_height + 0.9)),
                 ((1, 1, 1), 0.85), pen.thin)
    ctx.new_path()
    ctx.save()
    ctx.transform(front)
    pen.polygon(front_points)
    ctx.restore()
    pen.stroke(outline)
    if emblem is not None:
        ctx.save()
        ctx.transform(front)
        size = 15.0 if not pen.small else 17.0
        emblem(pen, width / 2 + lean / 2, -front_height / 2 + 0.5, size)
        ctx.restore()


# --- emblems (cx, cy at their middle, size across) ------------------------------------------------

def emblem_documents(pen, cx, cy, s):
    x = cx - s * 0.36
    y = cy - s * 0.5
    w = s * 0.72
    h = s
    pen.shape(rect_path(x, y, w, h, s * 0.04), PAPER, INK, pen.thin * 1.2)
    lines = 4 if not pen.small else 2
    for index in range(lines):
        ly = y + h * (0.25 + index * 0.6 / max(1, lines - 1)) if lines > 1 else y + h / 2
        pen.ctx.new_path()
        pen.ctx.move_to(x + w * 0.18, ly)
        pen.ctx.line_to(x + w * (0.82 if index % 2 == 0 else 0.62), ly)
        pen.stroke(BLUE, s * (0.08 if not pen.small else 0.12))


def emblem_pictures(pen, cx, cy, s):
    x = cx - s * 0.55
    y = cy - s * 0.4
    w = s * 1.1
    h = s * 0.8
    pen.shape(rect_path(x, y, w, h, s * 0.04), pen.vertical('#9fd8ff', '#4f9de8', y, y + h), INK, pen.thin * 1.2)
    ctx = pen.ctx
    ctx.save()
    ctx.new_path()
    pen.rounded(x, y, w, h, s * 0.04)
    ctx.clip()
    pen.shape(poly_path([(x, y + h), (x + w * 0.35, y + h * 0.45), (x + w * 0.6, y + h * 0.75),
                         (x + w * 0.78, y + h * 0.55), (x + w, y + h * 0.8), (x + w, y + h)]), GREEN)
    ctx.restore()
    pen.shape(circle_path(x + w * 0.74, y + h * 0.28, s * 0.11), '#fff27a')
    ctx.new_path()
    pen.rounded(x, y, w, h, s * 0.04)
    pen.stroke(INK, pen.thin * 1.2)


def note_path(pen, cx, cy, s):
    """Two joined quavers."""
    ctx = pen.ctx
    stem = s * 0.1
    left = cx - s * 0.32
    right = cx + s * 0.3
    top = cy - s * 0.48
    ctx.new_path()
    pen.polygon([(left, top + s * 0.14), (right + stem, top), (right + stem, top + s * 0.24),
                 (left + stem, top + s * 0.38), (left + stem, cy + s * 0.32), (left, cy + s * 0.32)])
    pen.ellipse(left - s * 0.1, cy + s * 0.34, s * 0.19, s * 0.14)
    ctx.new_sub_path()
    pen.polygon([(right, top + s * 0.02), (right + stem, top), (right + stem, cy + s * 0.2), (right, cy + s * 0.2)])
    pen.ellipse(right - s * 0.1, cy + s * 0.22, s * 0.19, s * 0.14)


def emblem_music(pen, cx, cy, s):
    note_path(pen, cx, cy, s)
    pen.fill(pen.vertical(PURPLE, darker(PURPLE, 0.3), cy - s / 2, cy + s / 2), INK, pen.thin * 1.2)


def film_strip(pen, cx, cy, s):
    x = cx - s * 0.55
    y = cy - s * 0.42
    w = s * 1.1
    h = s * 0.84
    pen.shape(rect_path(x, y, w, h, s * 0.05), '#2a2d36', INK, pen.thin * 1.2)
    pen.shape(rect_path(x + w * 0.2, y + h * 0.12, w * 0.6, h * 0.76), pen.vertical('#8fd0ff', '#3270c8', y, y + h))
    holes = 4 if not pen.small else 3
    for index in range(holes):
        hy = y + h * (0.12 + index * 0.76 / (holes - 1)) - s * 0.05
        for hx in (x + w * 0.05, x + w * 0.85):
            pen.shape(rect_path(hx, hy, w * 0.1, s * 0.1, 0.2), '#e8ecf4')


def emblem_videos(pen, cx, cy, s):
    film_strip(pen, cx, cy, s)


def emblem_downloads(pen, cx, cy, s):
    block_arrow(pen, cx, cy, 90, BLUE, length=s * 1.15, shaft=s * 0.4, head=s * 0.9, head_length=s * 0.5,
                depth=0)


def emblem_projects(pen, cx, cy, s):
    gear(pen, cx, cy, s * 0.48, '#9aa3b2', 8 if not pen.small else 6)


def emblem_public(pen, cx, cy, s):
    """Two people."""
    for dx, colour, scale in ((s * 0.22, '#5a8de0', 0.85), (-s * 0.14, BLUE, 1.0)):
        head = s * 0.16 * scale
        hx = cx + dx
        hy = cy - s * 0.18
        body = pen.vertical(lighter(colour, 0.25), darker(colour, 0.2), hy, cy + s * 0.45)
        pen.shape(lambda pen, hx=hx, hy=hy, scale=scale: (
            pen.ctx.new_sub_path(),
            pen.ctx.arc(hx, cy + s * 0.45, s * 0.33 * scale, math.pi, 2 * math.pi),
            pen.ctx.close_path()), body, INK, pen.thin * 1.2)
        pen.shape(circle_path(hx, hy - s * 0.02, head), lighter(colour, 0.2), INK, pen.thin * 1.2)


def emblem_templates(pen, cx, cy, s):
    x = cx - s * 0.42
    y = cy - s * 0.5
    w = s * 0.84
    h = s
    pen.shape(rect_path(x, y, w, h, s * 0.04), (0.95, 0.97, 1.0))
    ctx = pen.ctx
    ctx.new_path()
    pen.rounded(x, y, w, h, s * 0.04)
    ctx.set_dash([s * 0.1, s * 0.08])
    pen.stroke(BLUE_DEEP, s * 0.07)
    ctx.set_dash([])
    pen.shape(rect_path(x + w * 0.2, y + h * 0.18, w * 0.6, h * 0.18), BLUE_LIGHT)


def emblem_compressed(pen, cx, cy, s):
    """A zipper down the middle."""
    ctx = pen.ctx
    pen.shape(rect_path(cx - s * 0.12, cy - s * 0.62, s * 0.24, s * 1.24), '#6e7480', INK, pen.thin)
    teeth = 6 if not pen.small else 4
    for index in range(teeth):
        ty = cy - s * 0.55 + index * s * 1.1 / teeth
        side = -1 if index % 2 == 0 else 1
        pen.shape(rect_path(cx + (side * s * 0.12 if side > 0 else -s * 0.3), ty, s * 0.18, s * 0.11),
                  SILVER, INK, pen.thin * 0.8)
    pen.shape(rect_path(cx - s * 0.18, cy + s * 0.15, s * 0.36, s * 0.34, s * 0.06),
              pen.vertical('#f4f6fa', '#9aa3b2', cy, cy + s * 0.5), INK, pen.thin)


group('Folders')


@icon('folder', 'Folder')
def draw_folder(pen):
    folder(pen)


@icon('folder-open', 'Open folder')
def draw_folder_open(pen):
    folder(pen, papers=True, open_front=True)


@icon('folder-documents', 'Documents')
def draw_folder_documents(pen):
    folder(pen, emblem_documents)


@icon('folder-pictures', 'Pictures')
def draw_folder_pictures(pen):
    folder(pen, emblem_pictures)


@icon('folder-music', 'Music')
def draw_folder_music(pen):
    folder(pen, emblem_music)


@icon('folder-videos', 'Videos')
def draw_folder_videos(pen):
    folder(pen, emblem_videos)


@icon('folder-downloads', 'Downloads')
def draw_folder_downloads(pen):
    folder(pen, emblem_downloads)


@icon('folder-projects', 'Projects')
def draw_folder_projects(pen):
    folder(pen, emblem_projects)


@icon('folder-public', 'Public')
def draw_folder_public(pen):
    folder(pen, emblem_public)


@icon('folder-templates', 'Templates')
def draw_folder_templates(pen):
    folder(pen, emblem_templates)


@icon('folder-compressed', 'Compressed')
def draw_folder_compressed(pen):
    folder(pen, emblem_compressed)
