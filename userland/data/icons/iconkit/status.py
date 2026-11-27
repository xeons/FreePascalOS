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

"""Status pictures, mostly for the taskbar's notification area: the
network (online: green bars; connecting: bars filling in amber;
limited: bars with a warning sign; no cable: grey bars with a red
cross; no adapter: grey bars), the sound on and muted, the battery's
levels and charging, mains power, security fine and in danger, and a
notification bell."""

import math

from .catalog import icon, group
from .pen import lighter, darker, outline_of
from .shapes import (poly_path, rect_path, circle_path, badge, sphere, sphere_gloss, warning_triangle, glyph_check,
                     glyph_cross, glyph_exclamation, BLUE, BLUE_LIGHT, GREEN, GREEN_LIGHT, GREEN_DEEP, RED, RED_DEEP,
                     INK, GOLD, GOLD_LIGHT, GOLD_DEEP, GOLD_OUTLINE, SILVER, SILVER_TOP, SILVER_SIDE, SILVER_OUTLINE,
                     ORANGE)
from .objects import loudspeaker, sound_waves

group('Status')

GREY_BAR = '#b4bac4'
AMBER = '#f5a623'


def bars(pen, colours):
    """Four bars rising to the right, each its colour, in 3D."""
    count = len(colours)
    left = 4.0
    right = 44.0
    gap = 2.0 if not pen.small else 3.0
    width = (right - left - gap * (count - 1)) / count
    bottom = 43.0
    for index, colour in enumerate(colours):
        height = 10.0 + index * (30.0 / (count - 1))
        x = left + index * (width + gap)
        top = bottom - height
        depth = 2.4 if not pen.small else 0.0
        if depth:
            pen.shape(poly_path([(x + width, top), (x + width + depth, top - depth * 0.8),
                                 (x + width + depth, bottom - depth * 0.8), (x + width, bottom)]), darker(colour, 0.4),
                      outline_of(colour), pen.thin)
            pen.shape(poly_path([(x, top), (x + depth, top - depth * 0.8), (x + width + depth, top - depth * 0.8),
                                 (x + width, top)]), lighter(colour, 0.4), outline_of(colour), pen.thin)
        pen.shape(rect_path(x, top, width, height), pen.linear(x, 0, x + width, 0, [(0, lighter(colour, 0.3)),
                                                                                 (1, darker(colour, 0.1))]),
                  outline_of(colour))


@icon('status-network-online', 'Network (online)')
def draw_network_online(pen):
    bars(pen, [GREEN] * 4)


@icon('status-network-connecting', 'Network (connecting)')
def draw_network_connecting(pen):
    bars(pen, [AMBER, AMBER, GREY_BAR, GREY_BAR])


@icon('status-network-limited', 'Network (limited)')
def draw_network_limited(pen):
    bars(pen, [GREEN, GREEN, GREEN, GREY_BAR])
    warning_triangle(pen, 14.0, 15.0, 24.0 if not pen.small else 28.0)


@icon('status-network-no-link', 'Network (no cable)')
def draw_network_no_link(pen):
    bars(pen, [GREY_BAR] * 4)
    badge(pen, 14.0, 14.0, 11.0 if not pen.small else 13.0, RED, glyph_cross)


@icon('status-network-offline', 'Network (offline)')
def draw_network_offline(pen):
    bars(pen, [GREY_BAR] * 4)


def speaker(pen):
    loudspeaker(pen, 3.0, 24.0, 36.0 if not pen.small else 40.0)


@icon('status-sound-on', 'Sound (on)')
def draw_sound_on(pen):
    speaker(pen)
    sound_waves(pen, 26.0, 24.0, 30.0 if not pen.small else 34.0, 2 if not pen.tiny else 2)


@icon('status-sound-muted', 'Sound (muted)')
def draw_sound_muted(pen):
    speaker(pen)
    ctx = pen.ctx
    width = 5.0 if not pen.small else 6.0
    for start, end in (((32.0, 16.0), (45.0, 32.0)), ((45.0, 16.0), (32.0, 32.0))):
        ctx.new_path()
        ctx.move_to(*start)
        ctx.line_to(*end)
        pen.stroke(RED_DEEP, width + pen.line * 2)
    for start, end in (((32.0, 16.0), (45.0, 32.0)), ((45.0, 16.0), (32.0, 32.0))):
        ctx.new_path()
        ctx.move_to(*start)
        ctx.line_to(*end)
        pen.stroke(RED, width)


def battery(pen, level, colour, charging=False):
    """A battery standing up, filled to level (0..1)."""
    x, y, width, height = 12.0, 9.0, 24.0, 35.0
    if pen.small:
        x, width = 10.0, 28.0
    ctx = pen.ctx
    pen.shape(rect_path(x + width * 0.32, y - 4.0, width * 0.36, 5.0, 1.0), pen.vertical(SILVER_TOP, SILVER_SIDE,
                                                                                         y - 4, y + 1), SILVER_OUTLINE)
    case = rect_path(x, y, width, height, 3.0)
    pen.shape(case, pen.linear(x, 0, x + width, 0, [(0, '#e8ecf2'), (0.4, '#ffffff'), (1, '#a8b0bc')]),
              SILVER_OUTLINE)
    if level > 0:
        inset = 2.5 if not pen.small else 3.0
        fill_height = (height - 2 * inset) * level
        top = y + height - inset - fill_height
        pen.shape(rect_path(x + inset, top, width - 2 * inset, fill_height, 1.2),
                  pen.linear(x, 0, x + width, 0, [(0, lighter(colour, 0.35)), (0.45, colour), (1, darker(colour, 0.3))]),
                  None)
    if not pen.tiny:
        pen.gloss(case, y, y + height * 0.5, 0.35)
    ctx.new_path()
    pen.rounded(x, y, width, height, 3.0)
    pen.stroke(SILVER_OUTLINE)
    if charging:
        bolt = [(x + width * 0.6, y + 6.0), (x + width * 0.25, y + height * 0.55), (x + width * 0.48, y + height * 0.55),
                (x + width * 0.38, y + height - 5.0), (x + width * 0.78, y + height * 0.42),
                (x + width * 0.54, y + height * 0.42)]
        pen.shape(poly_path(bolt), pen.vertical(GOLD_LIGHT, GOLD_DEEP, y, y + height), GOLD_OUTLINE)


@icon('status-battery-full', 'Battery (full)')
def draw_battery_full(pen):
    battery(pen, 1.0, GREEN)


@icon('status-battery-good', 'Battery (good)')
def draw_battery_good(pen):
    battery(pen, 0.72, GREEN)


@icon('status-battery-medium', 'Battery (medium)')
def draw_battery_medium(pen):
    battery(pen, 0.48, GOLD)


@icon('status-battery-low', 'Battery (low)')
def draw_battery_low(pen):
    battery(pen, 0.22, RED)


@icon('status-battery-empty', 'Battery (empty)')
def draw_battery_empty(pen):
    battery(pen, 0.0, RED)
    badge(pen, 34.0, 34.0, 10.0 if not pen.small else 12.0, RED, glyph_exclamation)


@icon('status-battery-charging', 'Battery (charging)')
def draw_battery_charging(pen):
    battery(pen, 0.6, GREEN, True)


@icon('status-ac-power', 'Mains power')
def draw_ac_power(pen):
    ctx = pen.ctx
    # The cable leaving at the bottom.
    ctx.new_path()
    ctx.move_to(24.0, 36.0)
    ctx.curve_to(24.0, 44.0, 30.0, 46.0, 38.0, 46.0)
    pen.stroke(INK, 4.6)
    ctx.new_path()
    ctx.move_to(24.0, 36.0)
    ctx.curve_to(24.0, 44.0, 30.0, 46.0, 38.0, 46.0)
    pen.stroke('#5a6070', 2.4)
    # The pins and the body.
    for x in (17.0, 27.0):
        pen.shape(rect_path(x, 3.0, 4.0, 12.0, 1.0), pen.linear(x, 0, x + 4, 0, [(0, '#ffffff'), (1, SILVER_SIDE)]),
                  SILVER_OUTLINE)
    body = [(10.0, 14.0), (38.0, 14.0), (38.0, 24.0), (30.0, 36.0), (18.0, 36.0), (10.0, 24.0)]
    pen.shape(poly_path(body), pen.linear(10, 0, 38, 0, [(0, '#5a6070'), (0.4, '#8a92a2'), (1, '#2c3038')]), INK)
    if not pen.tiny:
        pen.gloss(poly_path(body), 14.0, 26.0, 0.4)


def shield_path(x, y, width, height):
    def path(pen):
        ctx = pen.ctx
        top = y
        ctx.move_to(x + width / 2, top)
        ctx.curve_to(x + width * 0.75, top + height * 0.1, x + width * 0.9, top + height * 0.1, x + width, top + height * 0.1)
        ctx.curve_to(x + width, top + height * 0.6, x + width * 0.8, top + height * 0.85, x + width / 2, top + height)
        ctx.curve_to(x + width * 0.2, top + height * 0.85, x, top + height * 0.6, x, top + height * 0.1)
        ctx.curve_to(x + width * 0.1, top + height * 0.1, x + width * 0.25, top + height * 0.1, x + width / 2, top)
        ctx.close_path()
    return path


def shield(pen, colour, glyph):
    x, y, width, height = 7.0, 4.0, 34.0, 40.0
    if pen.small:
        x, y, width, height = 5.0, 3.0, 38.0, 43.0
    path = shield_path(x, y, width, height)
    pen.shape(path, pen.radial(x + width * 0.35, y + height * 0.3, height, [(0, lighter(colour, 0.45)), (0.5, colour),
                                                                          (1, darker(colour, 0.4))]), outline_of(colour))
    if not pen.tiny:
        pen.gloss(path, y, y + height * 0.5, 0.45)
    glyph(pen, x + width / 2, y + height * 0.47, width * 0.48)


@icon('status-security-ok', 'Security (fine)')
def draw_security_ok(pen):
    shield(pen, GREEN, glyph_check)


@icon('status-security-warning', 'Security (warning)')
def draw_security_warning(pen):
    shield(pen, RED, glyph_exclamation)


@icon('status-notification', 'Notification')
def draw_notification(pen):
    ctx = pen.ctx
    ctx.new_path()
    ctx.move_to(24.0, 6.0)
    ctx.curve_to(35.0, 6.0, 35.0, 18.0, 36.0, 26.0)
    ctx.curve_to(37.0, 32.0, 41.0, 34.0, 42.0, 37.0)
    ctx.line_to(6.0, 37.0)
    ctx.curve_to(7.0, 34.0, 11.0, 32.0, 12.0, 26.0)
    ctx.curve_to(13.0, 18.0, 13.0, 6.0, 24.0, 6.0)
    ctx.close_path()
    pen.fill(pen.linear(8, 0, 40, 0, [(0, GOLD_LIGHT), (0.45, GOLD), (1, GOLD_DEEP)]), GOLD_OUTLINE)
    pen.shape(circle_path(24.0, 40.0, 4.5), GOLD_DEEP, GOLD_OUTLINE)
    pen.shape(circle_path(24.0, 4.5, 2.5), GOLD, GOLD_OUTLINE)
    badge(pen, 37.0, 11.0, 8.0 if not pen.small else 10.0, RED)
