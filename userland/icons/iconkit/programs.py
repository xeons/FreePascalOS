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

"""Programs: the file manager, terminal, text editor, web browser, mail,
calendar, contacts, media player, image viewer, paint, calculator, the
Control Panel, task manager, help, system information, volume control,
the controls' tour and demo, the dialogs, and a program of no icon of
its own."""

import math

from .catalog import icon, group
from .pen import Projection, lighter, darker, outline_of, mix
from .shapes import (box, plane_shape, plane_stroke, poly_path, rect_path, circle_path, globe, sphere, sphere_gloss,
                     badge, gear, block_arrow, magnifier, glyph_question, glyph_info,
                     SILVER, SILVER_TOP, SILVER_SIDE, SILVER_OUTLINE, BLUE, BLUE_LIGHT, BLUE_DEEP, NAVY, TEAL, INK,
                     GREEN, GREEN_LIGHT, GREEN_DEEP, RED, RED_LIGHT, RED_DEEP, ORANGE, PURPLE, PURPLE_LIGHT, CHARCOAL,
                     GOLD, GOLD_LIGHT, GOLD_DEEP, GOLD_OUTLINE, PAPER, PAPER_SHADE)
from .objects import monitor, loudspeaker, sound_waves
from .folders import folder, emblem_pictures
from .filetypes import page, text_lines

group('Programs')


@icon('app-file-manager', 'File manager')
def draw_file_manager(pen):
    folder(pen, papers=True, open_front=True)
    if not pen.small:
        magnifier(pen, 33.0, 30.0, 6.0, 0.8)


@icon('app-terminal', 'Terminal')
def draw_terminal(pen):
    projection = Projection(5.0, 42.0)
    width, height = 34.0, 28.0
    box(pen, projection, width, 5.0, height, '#2c313b', INK, top='#5b6372', side='#1a1d24')
    face = projection.front_matrix(0)
    plane_shape(pen, face, rect_path(2.0, -height + 2.0, width - 4.0, height - 4.0, 0.8),
                pen.vertical('#1b2a24', '#0b1210', -height, 0), None)
    prompt = '#6ef08c'
    width_line = 2.4 if not pen.small else 3.2
    ctx = pen.ctx
    ctx.save()
    ctx.transform(face)
    ctx.new_path()
    ctx.move_to(6.0, -20.0)
    ctx.line_to(11.0, -15.5)
    ctx.line_to(6.0, -11.0)
    ctx.restore()
    pen.stroke(prompt, width_line)
    plane_stroke(pen, face, lambda pen: (pen.ctx.move_to(14.0, -10.0), pen.ctx.line_to(22.0, -10.0)), prompt,
                 width_line)


@icon('app-text-editor', 'Text editor', aliases=('app-notepad',))
def draw_text_editor(pen):
    page(pen, lambda pen: text_lines(pen, '#4a6fae'))
    # A pencil across the page.
    ctx = pen.ctx
    ctx.save()
    ctx.translate(30.0, 26.0)
    ctx.rotate(math.radians(45))
    length = 30.0 if not pen.small else 28.0
    thickness = 6.0 if not pen.small else 7.0
    body = rect_path(-length / 2, -thickness / 2, length * 0.72, thickness)
    pen.shape(body, pen.vertical('#ffe27a', '#e0a020', -thickness / 2, thickness / 2), GOLD_OUTLINE)
    pen.shape(rect_path(-length / 2 - 3.0, -thickness / 2, 3.5, thickness, 1.0), '#f07aa0', '#6a2038')
    tip_x = -length / 2 + length * 0.72
    pen.shape(poly_path([(tip_x, -thickness / 2), (length / 2, 0), (tip_x, thickness / 2)]), '#f2d2a8', '#6a4a20')
    pen.shape(poly_path([(length / 2 - 2.6, -1.0), (length / 2, 0), (length / 2 - 2.6, 1.0)]), INK)
    ctx.restore()


@icon('app-web-browser', 'Web browser')
def draw_web_browser(pen):
    globe(pen, 24.0, 24.0, 19.5 if not pen.small else 21.0)
    if not pen.small:
        # A ring round it, as an orbit.
        ctx = pen.ctx
        ctx.save()
        ctx.translate(24.0, 24.0)
        ctx.rotate(math.radians(-20))
        ctx.scale(1.0, 0.32)
        ctx.new_path()
        ctx.arc(0, 0, 23.0, math.radians(-10), math.radians(190))
        ctx.restore()
        pen.stroke(INK, 3.6)
        ctx.save()
        ctx.translate(24.0, 24.0)
        ctx.rotate(math.radians(-20))
        ctx.scale(1.0, 0.32)
        ctx.new_path()
        ctx.arc(0, 0, 23.0, math.radians(-10), math.radians(190))
        ctx.restore()
        pen.stroke(GOLD, 2.0)


def envelope(pen, x, y, width, height):
    projection = Projection(x, y)
    box(pen, projection, width, 3.0, height, '#f4f6fb', '#3a4152', top='#ffffff', side='#c5ccd8')
    face = projection.front_matrix(0)
    plane_stroke(pen, face, lambda pen: (pen.ctx.move_to(0.8, -height + 0.8), pen.ctx.line_to(width / 2, -height * 0.4),
                                         pen.ctx.line_to(width - 0.8, -height + 0.8)), '#3a4152', pen.line)
    plane_stroke(pen, face, lambda pen: (pen.ctx.move_to(0.8, -0.8), pen.ctx.line_to(width * 0.38, -height * 0.5),
                                         pen.ctx.move_to(width - 0.8, -0.8), pen.ctx.line_to(width * 0.62,
                                                                                            -height * 0.5)),
                 '#8a93a6', pen.thin)


@icon('app-mail', 'Mail')
def draw_mail(pen):
    envelope(pen, 5.0, 40.0, 34.0, 22.0)


@icon('app-calendar', 'Calendar')
def draw_calendar(pen):
    projection = Projection(7.0, 44.0)
    width, height = 30.0, 30.0
    box(pen, projection, width, 4.0, height, '#ffffff', '#3a4152', top='#f2f4f8', side='#c5ccd8')
    face = projection.front_matrix(0)
    plane_shape(pen, face, rect_path(0, -height, width, 8.0), pen.vertical(RED_LIGHT, RED, -height, -height + 8),
                RED_DEEP, pen.thin)
    rows, columns = (4, 5) if not pen.small else (3, 3)
    for row in range(rows):
        for column in range(columns):
            u = 3.0 + column * (width - 6.0) / columns
            v = -height + 11.0 + row * (height - 13.0) / rows
            cell_w = (width - 6.0) / columns - 1.4
            cell_h = (height - 13.0) / rows - 1.4
            colour = '#c9d3e4' if (row, column) != (1, 2) else BLUE
            plane_shape(pen, face, rect_path(u, v, cell_w, cell_h), colour, None)
    # Rings at the top.
    for u in (8.0, width - 8.0):
        plane_shape(pen, face, rect_path(u - 1.2, -height - 3.0, 2.4, 5.5, 1.2), SILVER, SILVER_OUTLINE, pen.thin)


@icon('app-contacts', 'Contacts')
def draw_contacts(pen):
    projection = Projection(8.0, 44.0)
    width, height = 28.0, 34.0
    box(pen, projection, width, 5.0, height, '#e08a2a', '#5a2e06', top='#f8c27a', side='#a85c14')
    face = projection.front_matrix(0)
    plane_shape(pen, face, rect_path(4.0, -height + 4.0, width - 8.0, height - 8.0, 1.0), '#fff6e6', '#5a2e06',
                pen.thin)
    ctx = pen.ctx
    ctx.save()
    ctx.transform(face)
    cx = width / 2
    pen.shape(lambda pen: (pen.ctx.new_sub_path(), pen.ctx.arc(cx, -8.0, 8.5, math.pi, 2 * math.pi),
                           pen.ctx.close_path()), pen.vertical(BLUE_LIGHT, BLUE_DEEP, -16, -8), INK, pen.thin)
    pen.shape(circle_path(cx, -19.5, 4.6), pen.vertical('#ffe0c0', '#e0a070', -24, -15), INK, pen.thin)
    ctx.restore()


@icon('app-media-player', 'Media player')
def draw_media_player(pen):
    def content(pen, width, height):
        cx, cy = width / 2, height / 2
        size = height * 0.36
        pen.shape(poly_path([(cx - size * 0.6, cy - size), (cx + size, cy), (cx - size * 0.6, cy + size)]),
                  '#ffffff', INK, pen.thin)
    monitor(pen, 5.0, 38.0, 34.0, 26.0, 4.0, stand=False, content=content, bezel='#3a4252')


@icon('app-image-viewer', 'Image viewer')
def draw_image_viewer(pen):
    projection = Projection(5.0, 42.0)
    width, height = 36.0, 28.0
    box(pen, projection, width, 3.0, height, '#b07a3a', '#4a2a0c', top='#e0b070', side='#7a4a18')
    face = projection.front_matrix(0)
    ctx = pen.ctx
    ctx.save()
    ctx.transform(face)
    emblem_pictures(pen, width / 2, -height / 2, width * 0.74)
    ctx.restore()


@icon('app-paint', 'Paint')
def draw_paint(pen):
    # A palette with paint blobs and a brush over it.
    ctx = pen.ctx
    ctx.save()
    ctx.translate(23.0, 26.0)
    ctx.scale(1.0, 0.82)
    ctx.new_path()
    ctx.arc(0, 0, 19.0, 0, 2 * math.pi)
    ctx.new_sub_path()
    ctx.arc_negative(7.0, 7.0, 3.6, 2 * math.pi, 0)
    ctx.restore()
    pen.fill(pen.vertical('#f6dcae', '#c99a5a', 10, 42), '#5a3a12')
    for x, y, colour in ((13.0, 20.0, RED), (21.0, 14.0, GOLD), (30.0, 16.0, GREEN), (14.0, 31.0, BLUE),
                         (33.0, 25.0, PURPLE)):
        sphere(pen, x, y, 3.6 if not pen.small else 4.2, colour)
    if not pen.small:
        ctx.save()
        ctx.translate(31.0, 30.0)
        ctx.rotate(math.radians(-50))
        pen.shape(rect_path(-2.0, 0, 4.0, 16.0, 1.5), pen.vertical('#c87a3a', '#7a4515', 0, 16), '#3a1a05')
        pen.shape(rect_path(-2.6, -3.0, 5.2, 4.0), SILVER, SILVER_OUTLINE, pen.thin)
        pen.shape(poly_path([(-2.6, -3.0), (2.6, -3.0), (0, -10.0)]), '#2a2a2a', INK, pen.thin)
        ctx.restore()


@icon('app-calculator', 'Calculator')
def draw_calculator(pen):
    projection = Projection(9.0, 45.0)
    width, height = 26.0, 36.0
    box(pen, projection, width, 5.0, height, '#4a5262', INK, top='#7a8394', side='#2c313b')
    face = projection.front_matrix(0)
    plane_shape(pen, face, rect_path(3.0, -height + 3.0, width - 6.0, 8.0, 0.6),
                pen.vertical('#d8f0c8', '#9cc890', -height, -height + 11), INK, pen.thin)
    rows, columns = (4, 3) if not pen.small else (3, 2)
    for row in range(rows):
        for column in range(columns):
            u = 3.0 + column * (width - 6.0) / columns
            v = -height + 14.0 + row * (height - 17.0) / rows
            colour = '#e8ecf2' if column < columns - 1 else ORANGE
            plane_shape(pen, face, rect_path(u, v, (width - 6.0) / columns - 1.6, (height - 17.0) / rows - 1.6, 0.6),
                        colour, None)


@icon('app-control-panel', 'Control Panel', aliases=('app-settings',))
def draw_control_panel(pen):
    if pen.small:
        gear(pen, 24.0, 24.0, 19.0, '#9aa3b2', 8)
        return
    globe(pen, 20.0, 20.0, 15.0)
    gear(pen, 32.0, 33.0, 12.0, '#9aa3b2', 8)


@icon('app-task-manager', 'Task manager')
def draw_task_manager(pen):
    def content(pen, width, height):
        ctx = pen.ctx
        ctx.new_path()
        pen.rounded(0, 0, width, height, 0)
        pen.fill('#0e1a14')
        ctx.new_path()
        ctx.move_to(0, height * 0.75)
        points = (0.6, 0.7, 0.3, 0.45, 0.2, 0.5, 0.35)
        for index, value in enumerate(points):
            ctx.line_to(width * (index + 1) / len(points), height * value)
        pen.stroke('#5af07a', 1.8 if not pen.small else 2.6)
    monitor(pen, 5.0, 38.0, 34.0, 26.0, 4.0, stand=False, content=content, bezel='#3a4252')


@icon('app-help', 'Help')
def draw_help(pen):
    badge(pen, 24.0, 24.0, 19.0 if not pen.small else 21.0, BLUE, glyph_question)


@icon('app-system-info', 'System information')
def draw_system_info(pen):
    monitor(pen, 5.0, 36.0, 34.0, 25.0, 4.0)
    badge(pen, 34.0, 34.0, 10.0 if not pen.small else 12.0, BLUE, glyph_info)


@icon('app-volume-control', 'Volume control')
def draw_volume_control(pen):
    projection = Projection(5.0, 44.0)
    width, height = 36.0, 26.0
    box(pen, projection, width, 6.0, height, '#d3d8e0', SILVER_OUTLINE, top=SILVER_TOP, side=SILVER_SIDE)
    face = projection.front_matrix(0)
    sliders = (0.35, 0.6, 0.25) if not pen.small else (0.35, 0.65)
    for index, level in enumerate(sliders):
        u = width * (index + 1) / (len(sliders) + 1)
        plane_shape(pen, face, rect_path(u - 0.9, -height + 4.0, 1.8, height - 8.0), '#3a3f4a', None)
        v = -height + 4.0 + (height - 8.0) * level
        plane_shape(pen, face, rect_path(u - 3.5, v - 2.0, 7.0, 4.0, 0.8), pen.vertical(BLUE_LIGHT, BLUE_DEEP, v - 2,
                                                                                         v + 2), INK, pen.thin)


@icon('app-components', 'Components')
def draw_components(pen):
    blocks = [(13.0, 30.0, '#e04a3a'), (26.0, 27.0, GOLD), (17.0, 45.0, BLUE), (30.0, 42.0, GREEN)]
    if pen.small:
        blocks = [(8.0, 27.0, '#e04a3a'), (24.0, 24.0, GOLD), (12.0, 45.0, BLUE), (28.0, 42.0, GREEN)]
    for x, y, colour in blocks:
        size = 12.0 if not pen.small else 14.0
        box(pen, Projection(x - 6.0, y), size, size * 0.8, size, colour, outline_of(colour))


@icon('app-themes', 'Themes')
def draw_themes(pen):
    colours = [RED, ORANGE, GOLD, GREEN, BLUE, PURPLE]
    if pen.small:
        colours = [RED, GOLD, GREEN, BLUE]
    count = len(colours)
    for index, colour in enumerate(colours):
        x = 7.0 + index * 30.0 / count
        projection = Projection(x, 44.0 - index * 1.2)
        box(pen, projection, 30.0 / count + 0.5, 4.0, 30.0, colour, outline_of(colour))


@icon('app-dialogs', 'Windows')
def draw_dialogs(pen):
    for x, y, title in ((14.0, 30.0, BLUE_DEEP), (6.0, 42.0, BLUE)):
        projection = Projection(x, y)
        box(pen, projection, 26.0, 3.0, 20.0, '#e8ebf2', '#2a3040', top='#ffffff', side='#b9c0cc')
        face = projection.front_matrix(0)
        plane_shape(pen, face, rect_path(0.6, -19.4, 24.8, 5.0), pen.vertical(lighter(title, 0.3), title, -20, -14),
                    None)


@icon('app-generic', 'Program')
def draw_generic(pen):
    projection = Projection(5.0, 42.0)
    width, height = 36.0, 28.0
    box(pen, projection, width, 3.0, height, '#e8ebf2', '#2a3040', top='#ffffff', side='#b9c0cc')
    face = projection.front_matrix(0)
    plane_shape(pen, face, rect_path(0.6, -height + 0.6, width - 1.2, 6.0),
                pen.vertical(BLUE_LIGHT, BLUE_DEEP, -height, -height + 6), None)
    ctx = pen.ctx
    ctx.save()
    ctx.transform(face)
    gear(pen, width / 2, -height / 2 + 2.5, 8.0 if not pen.small else 9.0, '#8f99aa', 8)
    ctx.restore()
