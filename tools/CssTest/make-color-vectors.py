#!/usr/bin/env python3
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

# Writes the color conversion answers the libcss test checks against
# (CssTest.ColorVectors.inc): CSS colors in every space of CSS Color 4,
# and color-mix() results, converted to unclipped sRGB here with the
# formulas of the specification's sample code (conversions.js),
# written out from the matrix definitions (primaries and white points)
# rather than copied constants.

import math


def mat_mul(m, v):
    return [sum(m[r][c] * v[c] for c in range(3)) for r in range(3)]


def mat_inv(m):
    a, b, c = m[0]
    d, e, f = m[1]
    g, h, i = m[2]
    det = a * (e * i - f * h) - b * (d * i - f * g) + c * (d * h - e * g)
    return [[(e * i - f * h) / det, (c * h - b * i) / det, (b * f - c * e) / det],
            [(f * g - d * i) / det, (a * i - c * g) / det, (c * d - a * f) / det],
            [(d * h - e * g) / det, (b * g - a * h) / det, (a * e - b * d) / det]]


def xy_to_xyz(x, y):
    return [x / y, 1.0, (1 - x - y) / y]


def rgb_to_xyz_matrix(primaries, white):
    columns = [xy_to_xyz(*p) for p in primaries]
    m = [[columns[c][r] for c in range(3)] for r in range(3)]
    s = mat_mul(mat_inv(m), white)
    return [[m[r][c] * s[c] for c in range(3)] for r in range(3)]


D65 = xy_to_xyz(0.3127, 0.3290)
D50 = xy_to_xyz(0.3457, 0.3585)
SRGB = rgb_to_xyz_matrix([(0.64, 0.33), (0.30, 0.60), (0.15, 0.06)], D65)
P3 = rgb_to_xyz_matrix([(0.680, 0.320), (0.265, 0.690), (0.150, 0.060)], D65)
A98 = rgb_to_xyz_matrix([(0.64, 0.33), (0.21, 0.71), (0.15, 0.06)], D65)
REC2020 = rgb_to_xyz_matrix([(0.708, 0.292), (0.170, 0.797), (0.131, 0.046)], D65)
PROPHOTO = rgb_to_xyz_matrix([(0.734699, 0.265301), (0.159597, 0.840403), (0.036598, 0.000105)], D50)

# Bradford chromatic adaptation between D50 and D65.
BRADFORD = [[0.8951, 0.2664, -0.1614], [-0.7502, 1.7135, 0.0367], [0.0389, -0.0685, 1.0296]]


def adaptation(source, target):
    s = mat_mul(BRADFORD, source)
    t = mat_mul(BRADFORD, target)
    scale = [[t[0] / s[0], 0, 0], [0, t[1] / s[1], 0], [0, 0, t[2] / s[2]]]
    inner = [[sum(scale[r][k] * BRADFORD[k][c] for k in range(3)) for c in range(3)] for r in range(3)]
    inv = mat_inv(BRADFORD)
    return [[sum(inv[r][k] * inner[k][c] for k in range(3)) for c in range(3)] for r in range(3)]


D50_TO_D65 = adaptation(D50, D65)
D65_TO_D50 = adaptation(D65, D50)


def signed(f, v):
    return math.copysign(f(abs(v)), v)


def srgb_to_linear(c):
    return signed(lambda a: a / 12.92 if a <= 0.04045 else ((a + 0.055) / 1.055) ** 2.4, c)


def linear_to_srgb(c):
    return signed(lambda a: 12.92 * a if a <= 0.0031308 else 1.055 * a ** (1 / 2.4) - 0.055, c)


def a98_to_linear(c):
    return signed(lambda a: a ** (563 / 256), c)


def prophoto_to_linear(c):
    return signed(lambda a: a / 16 if a <= 16 / 512 else a ** 1.8, c)


ALPHA = 1.09929682680944
BETA = 0.018053968510807


def rec2020_to_linear(c):
    return signed(lambda a: a / 4.5 if a < BETA * 4.5 else ((a + ALPHA - 1) / ALPHA) ** (1 / 0.45), c)


def xyz_to_srgb(xyz):
    return [linear_to_srgb(c) for c in mat_mul(mat_inv(SRGB), xyz)]


def lab_to_xyz_d65(lab):
    kappa = 24389 / 27
    epsilon = 216 / 24389
    l, a, b = lab
    f1 = (l + 16) / 116
    f0 = a / 500 + f1
    f2 = f1 - b / 200
    x = f0 ** 3 if f0 ** 3 > epsilon else (116 * f0 - 16) / kappa
    y = ((l + 16) / 116) ** 3 if l > kappa * epsilon else l / kappa
    z = f2 ** 3 if f2 ** 3 > epsilon else (116 * f2 - 16) / kappa
    return mat_mul(D50_TO_D65, [x * D50[0], y * D50[1], z * D50[2]])


OKLAB_M1 = [[0.8190224379967030, 0.3619062600528904, -0.1288737815209879],
            [0.0329836539323885, 0.9292868615863434, 0.0361446663506424],
            [0.0481771893596242, 0.2642395317527308, 0.6335478284694309]]
OKLAB_M2 = [[0.2104542683093140, 0.7936177747023054, -0.0040720430116193],
            [1.9779985324311684, -2.4285922420485799, 0.4505937096174110],
            [0.0259040424655478, 0.7827717124575296, -0.8086757549230774]]


def oklab_to_xyz(lab):
    lms = mat_mul(mat_inv(OKLAB_M2), lab)
    return mat_mul(mat_inv(OKLAB_M1), [c ** 3 for c in lms])


def xyz_to_oklab(xyz):
    lms = mat_mul(OKLAB_M1, xyz)
    return mat_mul(OKLAB_M2, [math.copysign(abs(c) ** (1 / 3), c) for c in lms])


def polar(l, c, h):
    return [l, c * math.cos(math.radians(h)), c * math.sin(math.radians(h))]


def hsl_to_srgb(h, s, l):
    s /= 100
    l /= 100

    def f(n):
        k = (n + h / 30) % 12
        a = s * min(l, 1 - l)
        return l - a * max(-1, min(k - 3, 9 - k, 1))
    return [f(0), f(8), f(4)]


def hwb_to_srgb(h, w, b):
    w /= 100
    b /= 100
    if w + b >= 1:
        g = w / (w + b)
        return [g, g, g]
    return [c * (1 - w - b) + w for c in hsl_to_srgb(h, 100, 50)]


def to_xyz(space, c):
    if space == 'srgb':
        return mat_mul(SRGB, [srgb_to_linear(v) for v in c])
    if space == 'srgb-linear':
        return mat_mul(SRGB, c)
    if space == 'display-p3':
        return mat_mul(P3, [srgb_to_linear(v) for v in c])
    if space == 'a98-rgb':
        return mat_mul(A98, [a98_to_linear(v) for v in c])
    if space == 'prophoto-rgb':
        return mat_mul(D50_TO_D65, mat_mul(PROPHOTO, [prophoto_to_linear(v) for v in c]))
    if space == 'rec2020':
        return mat_mul(REC2020, [rec2020_to_linear(v) for v in c])
    if space == 'xyz-d65':
        return c
    if space == 'xyz-d50':
        return mat_mul(D50_TO_D65, c)
    if space == 'lab':
        return lab_to_xyz_d65(c)
    if space == 'lch':
        return lab_to_xyz_d65(polar(*c))
    if space == 'oklab':
        return oklab_to_xyz(c)
    if space == 'oklch':
        return oklab_to_xyz(polar(*c))
    if space == 'hsl':
        return to_xyz('srgb', hsl_to_srgb(*c))
    if space == 'hwb':
        return to_xyz('srgb', hwb_to_srgb(*c))
    raise ValueError(space)


VECTORS = [
    ('rgb(10 20 30)', 'srgb', [10 / 255, 20 / 255, 30 / 255]),
    ('hsl(120 100% 25%)', 'hsl', [120, 100, 25]),
    ('hsl(30deg, 50%, 60%)', 'hsl', [30, 50, 60]),
    ('hwb(120 20% 30%)', 'hwb', [120, 20, 30]),
    ('lab(50 20 -30)', 'lab', [50, 20, -30]),
    ('lab(75% 50% 0)', 'lab', [75, 62.5, 0]),
    ('lch(60 40 120)', 'lch', [60, 40, 120]),
    ('oklab(0.6 0.1 -0.1)', 'oklab', [0.6, 0.1, -0.1]),
    ('oklch(70% 0.1 200)', 'oklch', [0.7, 0.1, 200]),
    ('oklch(0.5 50% 1.5rad)', 'oklch', [0.5, 0.2, math.degrees(1.5)]),
    ('color(display-p3 1 0 0)', 'display-p3', [1, 0, 0]),
    ('color(a98-rgb 0.5 0.5 0.2)', 'a98-rgb', [0.5, 0.5, 0.2]),
    ('color(prophoto-rgb 0.3 0.6 0.4)', 'prophoto-rgb', [0.3, 0.6, 0.4]),
    ('color(rec2020 0.4 0.5 0.6)', 'rec2020', [0.4, 0.5, 0.6]),
    ('color(xyz-d65 0.3 0.4 0.5)', 'xyz-d65', [0.3, 0.4, 0.5]),
    ('color(xyz-d50 0.3 0.4 0.5)', 'xyz-d50', [0.3, 0.4, 0.5]),
    ('color(xyz 0.2 0.2 0.2)', 'xyz-d65', [0.2, 0.2, 0.2]),
    ('color(srgb-linear 0.2 0.4 0.6)', 'srgb-linear', [0.2, 0.4, 0.6]),
]


def mix(space, first, second, p1, p2):
    """color-mix of two sRGB colors (alpha 1) in a rectangular space."""
    def into(c):
        xyz = to_xyz('srgb', c)
        if space == 'srgb':
            return c
        if space == 'oklab':
            return xyz_to_oklab(xyz)
        if space == 'srgb-linear':
            return [srgb_to_linear(v) for v in c]
        raise ValueError(space)

    def out_of(c):
        if space == 'srgb':
            return c
        if space == 'oklab':
            return xyz_to_srgb(oklab_to_xyz(c))
        if space == 'srgb-linear':
            return [linear_to_srgb(v) for v in c]
        raise ValueError(space)
    a = into(first)
    b = into(second)
    total = p1 + p2
    return out_of([a[i] * p1 / total + b[i] * p2 / total for i in range(3)])


MIXES = [
    ('color-mix(in srgb, red, blue)', mix('srgb', [1, 0, 0], [0, 0, 1], 50, 50)),
    ('color-mix(in oklab, red 30%, blue)', mix('oklab', [1, 0, 0], [0, 0, 1], 30, 70)),
    ('color-mix(in srgb-linear, white, black 25%)', mix('srgb-linear', [1, 1, 1], [0, 0, 0], 75, 25)),
]

print('{ Made by make-color-vectors.py: do not edit. }')
for text, space, components in VECTORS:
    r, g, b = xyz_to_srgb(to_xyz(space, components))
    print("  CheckColorVector('%s', %.10f, %.10f, %.10f);" % (text, r, g, b))
for text, (r, g, b) in MIXES:
    print("  CheckColorVector('%s', %.10f, %.10f, %.10f);" % (text, r, g, b))
