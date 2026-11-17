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

"""Hardware: printer, scanner, camera, webcam, audio device, keyboard,
mouse and display."""

import math

from .catalog import icon, group
from .pen import Projection, lighter, darker, outline_of
from .shapes import (box, plane_shape, plane_stroke, poly_path, rect_path, circle_path, sphere, sphere_gloss,
                     SILVER, SILVER_TOP, SILVER_SIDE, SILVER_OUTLINE, BLUE, BLUE_LIGHT, BLUE_DEEP, INK, GREEN,
                     CHARCOAL, PAPER, ORANGE)
from .objects import monitor, loudspeaker, sound_waves

group('Devices')


def printer(pen):
    # The paper standing in the back, the body, the paper coming out.
    paper = Projection(14.0, 22.0)
    box(pen, paper, 18.0, 1.5, 14.0, PAPER, '#3a4152', top='#ffffff', side='#c5ccd8', gloss=False)
    projection = Projection(4.0, 38.0)
    width, depth, height = 32.0, 16.0, 12.0
    box(pen, projection, width, depth, height, SILVER, SILVER_OUTLINE, top=SILVER_TOP, side=SILVER_SIDE)
    face = projection.front_matrix(0)
    plane_shape(pen, face, rect_path(4.0, -4.5, width - 8.0, 2.4, 0.6), '#2b2f38', None)
    plane_shape(pen, face, circle_path(width - 4.0, -height + 3.5, 1.3 if not pen.small else 1.8), '#45e04a', None)
    out = Projection(8.0, 44.0)
    box(pen, out, 22.0, 6.0, 1.2, PAPER, '#3a4152', top='#ffffff', side='#c5ccd8', gloss=False)


@icon('device-printer', 'Printer')
def draw_printer(pen):
    printer(pen)


@icon('device-scanner', 'Scanner')
def draw_scanner(pen):
    projection = Projection(3.0, 40.0)
    width, depth, height = 34.0, 20.0, 7.0
    box(pen, projection, width, depth, height, SILVER, SILVER_OUTLINE, top=SILVER_TOP, side=SILVER_SIDE)
    ctx = pen.ctx
    ctx.save()
    ctx.transform(projection.top_matrix(height))
    ctx.new_path()
    pen.rounded(2.5, 2.5, width - 5.0, depth - 5.0, 0.8)
    ctx.restore()
    pen.fill(pen.linear(10, 20, 30, 10, [(0, '#3a5aa8'), (0.5, '#8ac0ff'), (1, '#2a4a90')]), INK, pen.thin)
    # The light bar.
    ctx.save()
    ctx.transform(projection.top_matrix(height))
    ctx.new_path()
    pen.rounded(width * 0.45, 2.5, 2.0, depth - 5.0, 0.3)
    ctx.restore()
    pen.fill('#c8f8ff')


@icon('device-camera', 'Camera')
def draw_camera(pen):
    projection = Projection(4.0, 40.0)
    width, depth, height = 32.0, 8.0, 20.0
    box(pen, projection, width, depth, height, '#4a505c', INK, top='#7a818e', side='#2c3038')
    # The viewfinder hump and a button.
    box(pen, Projection(*projection.point(9.0, 2.0, height)), 10.0, 5.0, 4.0, '#4a505c', INK, top='#7a818e',
        side='#2c3038', gloss=False)
    face = projection.front_matrix(0)
    ctx = pen.ctx
    ctx.save()
    ctx.transform(face)
    cx, cy = width * 0.5, -height * 0.5
    pen.shape(circle_path(cx, cy, 8.5), pen.vertical(SILVER_TOP, SILVER_SIDE, cy - 8, cy + 8), INK)
    pen.shape(circle_path(cx, cy, 5.8), pen.radial(cx - 2, cy - 2, 7, [(0, '#8ab8ff'), (0.5, '#1a3a7a'),
                                                                     (1, '#050a18')]), INK, pen.thin)
    if not pen.small:
        sphere_gloss(pen, cx, cy, 5.8, 0.6)
        pen.shape(rect_path(width - 7.0, -height + 2.5, 4.0, 2.5, 0.6), ORANGE, None)
    ctx.restore()


@icon('device-webcam', 'Webcam')
def draw_webcam(pen):
    # A ball on a stand.
    box(pen, Projection(14.0, 44.0), 18.0, 8.0, 3.0, SILVER, SILVER_OUTLINE, top=SILVER_TOP, side=SILVER_SIDE,
        gloss=False)
    pen.shape(rect_path(21.5, 30.0, 4.0, 10.0), pen.vertical(SILVER, SILVER_SIDE, 30, 40), SILVER_OUTLINE)
    sphere(pen, 23.5, 20.0, 15.0 if not pen.small else 16.5, '#d8dde6', SILVER_OUTLINE)
    pen.shape(circle_path(23.5, 21.0, 7.5), pen.vertical('#5a6070', '#1a1e26', 13, 28), INK)
    pen.shape(circle_path(23.5, 21.0, 4.5), pen.radial(22, 19.5, 6, [(0, '#8ab8ff'), (0.5, '#1a3a7a'),
                                                                   (1, '#050a18')]), INK, pen.thin)
    if not pen.small:
        sphere_gloss(pen, 23.5, 20.0, 15.0, 0.65)


@icon('device-audio', 'Audio device')
def draw_audio_device(pen):
    projection = Projection(6.0, 44.0)
    width, height = 22.0, 34.0
    box(pen, projection, width, 12.0, height, '#4a505c', INK, top='#7a818e', side='#2c3038')
    face = projection.front_matrix(0)
    ctx = pen.ctx
    ctx.save()
    ctx.transform(face)
    for cy, radius in ((-height * 0.3, 7.0), (-height * 0.75, 4.0)):
        pen.shape(circle_path(width / 2, cy, radius), pen.radial(width / 2 - 1, cy - 1, radius * 1.2,
                                                                 [(0, '#9aa3b2'), (0.6, '#3a3f4a'), (1, '#1a1d24')]),
                  INK, pen.thin)
        pen.shape(circle_path(width / 2, cy, radius * 0.35), '#c8cdd6', None)
    ctx.restore()
    if not pen.small:
        sound_waves(pen, 36.0, 22.0, 18.0, 2)


@icon('device-keyboard', 'Keyboard')
def draw_keyboard(pen):
    projection = Projection(2.0, 38.0)
    width, depth, height = 36.0, 16.0, 3.0
    if pen.small:
        projection = Projection(1.0, 42.0)
        width, depth, height = 36.0, 24.0, 5.0
    box(pen, projection, width, depth, height, '#e4e8ee', SILVER_OUTLINE, top='#f4f6fa', side=SILVER_SIDE)
    ctx = pen.ctx
    rows, columns = (3, 9) if not pen.small else (2, 5)
    for row in range(rows):
        for column in range(columns):
            u = 1.6 + column * (width - 3.2) / columns
            w = 1.6 + row * (depth - 3.2) / rows
            ctx.save()
            ctx.transform(projection.top_matrix(height))
            ctx.new_path()
            pen.rounded(u, w, (width - 3.2) / columns - 0.9, (depth - 3.2) / rows - 0.9, 0.4)
            ctx.restore()
            pen.fill('#ffffff', '#6a7280', pen.thin * 0.8)


@icon('device-mouse', 'Mouse')
def draw_mouse(pen):
    ctx = pen.ctx
    # The cable.
    ctx.new_path()
    ctx.move_to(24.0, 10.0)
    ctx.curve_to(24.0, 2.0, 36.0, 6.0, 40.0, 2.0)
    pen.stroke(INK, 2.4)
    ctx.save()
    ctx.translate(24.0, 27.0)
    ctx.scale(1.0, 1.35)
    ctx.new_path()
    ctx.arc(0, 0, 13.5, 0, 2 * math.pi)
    ctx.restore()
    pen.fill(pen.radial(18, 18, 26, [(0, '#ffffff'), (0.6, '#d3d8e0'), (1, '#8a93a2')]), SILVER_OUTLINE)
    ctx.new_path()
    ctx.move_to(24.0, 9.0)
    ctx.line_to(24.0, 24.0)
    ctx.move_to(11.0, 24.0)
    ctx.curve_to(18.0, 26.0, 30.0, 26.0, 37.0, 24.0)
    pen.stroke(SILVER_OUTLINE, pen.thin * 1.4)
    pen.shape(rect_path(22.3, 13.0, 3.4, 7.0, 1.7), '#3a3f4a', None)


@icon('device-display', 'Display')
def draw_display(pen):
    monitor(pen, 5.0, 36.0, 34.0, 25.0, 4.0)
