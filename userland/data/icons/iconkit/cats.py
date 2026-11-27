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

"""The tuxedo cat of Tuxcat, the web browser: a black cat's head and
shoulders with the white blaze, muzzle and bib of a tuxedo, green-gold
eyes and a pink nose, lit from the top left like the rest of the set.
Small sizes keep the silhouette, the white and the eyes."""

from .pen import lighter, darker, outline_of

FUR = '#2a2c33'
FUR_LIGHT = '#4a4e5a'
WHITE_FUR = '#f7f7f4'
WHITE_SHADE = '#cfd2d8'
EAR_PINK = '#e89aae'
NOSE_PINK = '#f0899f'
EYE_LIGHT = '#e4f27a'
EYE_DEEP = '#7fa61c'
PUPIL = '#101114'


def _ear(pen, tip, outer, inner, scale_inside):
    """An ear: the outer triangle in fur, a pink one inside it."""
    pen.ctx.new_path()
    pen.polygon([outer, tip, inner])
    pen.fill(pen.vertical(FUR_LIGHT, FUR, tip[1], outer[1]), outline_of(FUR))
    if pen.tiny:
        return
    centre_x = (tip[0] + outer[0] + inner[0]) / 3.0
    centre_y = (tip[1] + outer[1] + inner[1]) / 3.0

    def towards_centre(point):
        return (centre_x + (point[0] - centre_x) * scale_inside, centre_y + (point[1] - centre_y) * scale_inside)

    pen.ctx.new_path()
    pen.polygon([towards_centre(outer), towards_centre(tip), towards_centre(inner)])
    pen.fill(pen.vertical(lighter(EAR_PINK, 0.2), darker(EAR_PINK, 0.15), tip[1], outer[1]))


def _shoulders(pen):
    """The body under the head, with the white bib down the chest."""
    ctx = pen.ctx
    ctx.new_path()
    ctx.move_to(7.0, 48.0)
    ctx.curve_to(7.0, 38.0, 14.0, 33.0, 24.0, 33.0)
    ctx.curve_to(34.0, 33.0, 41.0, 38.0, 41.0, 48.0)
    ctx.close_path()
    pen.fill(pen.vertical(FUR_LIGHT, FUR, 33.0, 48.0), outline_of(FUR))
    ctx.new_path()
    ctx.move_to(17.5, 48.0)
    ctx.curve_to(18.5, 41.0, 21.0, 36.0, 24.0, 35.0)
    ctx.curve_to(27.0, 36.0, 29.5, 41.0, 30.5, 48.0)
    ctx.close_path()
    pen.fill(pen.vertical(WHITE_FUR, WHITE_SHADE, 35.0, 48.0), outline_of(WHITE_SHADE), pen.thin)


def _head(pen):
    paint = pen.radial(19.0, 17.0, 20.0, [(0, FUR_LIGHT), (0.55, FUR), (1, darker(FUR, 0.3))])
    pen.ctx.new_path()
    pen.ellipse(24.0, 24.5, 15.5, 13.0)
    pen.fill(paint, outline_of(FUR))


def _blaze_and_muzzle(pen):
    """The white stripe up the nose and the white muzzle and chin."""
    ctx = pen.ctx
    if not pen.tiny:
        ctx.new_path()
        ctx.move_to(24.0, 15.0)
        ctx.curve_to(25.6, 18.0, 26.4, 22.0, 27.0, 26.0)
        ctx.line_to(21.0, 26.0)
        ctx.curve_to(21.6, 22.0, 22.4, 18.0, 24.0, 15.0)
        ctx.close_path()
        pen.fill(pen.vertical(WHITE_FUR, WHITE_SHADE, 15.0, 26.0))
    ctx.new_path()
    pen.ellipse(24.0, 30.5, 8.5 if not pen.small else 9.0, 6.0)
    pen.fill(pen.vertical(WHITE_FUR, WHITE_SHADE, 25.0, 36.5), outline_of(WHITE_SHADE), pen.thin)


def _eye(pen, x, y):
    ctx = pen.ctx
    radius_x, radius_y = (3.3, 3.7) if not pen.small else (3.8, 4.0)
    ctx.new_path()
    pen.ellipse(x, y, radius_x, radius_y)
    pen.fill(pen.radial(x - 1.0, y - 1.2, radius_y * 1.4, [(0, EYE_LIGHT), (1, EYE_DEEP)]), PUPIL, pen.thin)
    ctx.new_path()
    pen.ellipse(x, y + 0.2, 1.0 if not pen.small else 1.4, radius_y * 0.75)
    pen.fill(PUPIL)
    if not pen.tiny:
        ctx.new_path()
        pen.circle(x - 1.1, y - 1.4, 0.8 if not pen.small else 1.0)
        pen.fill(WHITE_FUR)


def _nose_and_mouth(pen):
    ctx = pen.ctx
    ctx.new_path()
    pen.polygon([(22.0, 27.0), (26.0, 27.0), (24.0, 29.4)])
    pen.fill(NOSE_PINK, darker(NOSE_PINK, 0.45), pen.thin)
    if pen.small:
        return
    ctx.new_path()
    ctx.move_to(24.0, 29.4)
    ctx.line_to(24.0, 31.0)
    ctx.curve_to(23.0, 32.4, 21.4, 32.4, 20.6, 31.2)
    ctx.move_to(24.0, 31.0)
    ctx.curve_to(25.0, 32.4, 26.6, 32.4, 27.4, 31.2)
    pen.stroke(darker(WHITE_SHADE, 0.45), pen.thin)


def _whiskers(pen):
    ctx = pen.ctx
    ctx.new_path()
    for side in (-1.0, 1.0):
        for rise, end_y in ((-0.6, 27.0), (0.0, 30.5), (0.6, 34.0)):
            ctx.move_to(24.0 + side * 6.5, 30.5 + rise)
            ctx.line_to(24.0 + side * 18.5, end_y)
    pen.stroke((lighter(WHITE_SHADE, 0.3), 0.9), pen.thin)


def tuxedo_cat(pen):
    _shoulders(pen)
    _ear(pen, (11.0, 5.5), (9.5, 21.0), (20.5, 13.0), 0.55)
    _ear(pen, (37.0, 5.5), (38.5, 21.0), (27.5, 13.0), 0.55)
    _head(pen)
    _blaze_and_muzzle(pen)
    _eye(pen, 18.0, 21.5)
    _eye(pen, 30.0, 21.5)
    _nose_and_mouth(pen)
    if not pen.small:
        _whiskers(pen)
