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

"""The colour management and resampling fixtures of ImageTest.

    make-color-fixtures.py OUTPUT_DIRECTORY

ICC profiles are written byte by byte here (versions 2 and 4), and PNGs
carry them in iCCP; the reference (name.rgba) is LittleCMS's conversion
to sRGB through Pillow's ImageCms, relative colorimetric (libimage's
intent; LittleCMS's perceptual differs only for version 4 LUTs, where it
moves the black point). The LUT profiles are tried on mid-tones only:
near the edge of sRGB's gamut a channel close to 0 magnifies the small
differences between interpolations (LittleCMS's tetrahedral, libimage's
trilinear) tenfold through sRGB's steep curve there.

  icc-display-p3      v4, P3 primaries, sRGB's parametric curve, chad
  icc-adobe-rgb       v2, gamma 563/256 (curv), D65 media white point
  icc-gamma18         v2, Apple RGB primaries, gamma 1.8
  icc-prophoto-table  v2, ProPhoto primaries, 256-entry table curves
  icc-grey22          v2 grey, kTRC gamma 2.2 (a grey PNG)
  icc-grey-linear     v4 grey, kTRC parametric gamma 1.0
  icc-lut16-xyz       v2 mft2 A2B0 to XYZ (matrix/TRC tags that disagree,
                      so the LUT must be the one used)
  icc-mab-lab         v4 mAB A2B0 to Lab, with A curves and a grid
  icc-srgb            LittleCMS's own sRGB profile: nothing to convert
  icc-lab-unsupported an abstract Lab profile: left alone
  icc-cmyk.jpg        a CMYK JPEG with a (bare) CMYK profile: the naive
                      inks to RGB, called approximate

PNGs with gAMA (and cHRM) and no profile, their references worked out
here: png-gamma10 (linear light), png-gamma-srgb (1/2.2: taken as
sRGB, unchanged), png-chrm-p3 (P3 primaries, gamma 1/2.2).

Resampling: Pillow's resize with LANCZOS, BILINEAR and BOX of an opaque
smooth picture, shrunk and enlarged (resample-*.png and .rgba).
"""

import io
import math
import os
import struct
import sys
import zlib

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from PIL import Image, ImageCms  # noqa: E402

import fixturecommon  # noqa: E402

OUTPUT = sys.argv[1] if len(sys.argv) > 1 else "build/tools/image-fixtures"

D50 = (0.9642, 1.0, 0.8249)
D65_XY = (0.3127, 0.3290)
BRADFORD = [[0.8951, 0.2664, -0.1614], [-0.7502, 1.7135, 0.0367], [0.0389, -0.0685, 1.0296]]


def path(name):
    return fixturecommon.output_path(OUTPUT, name)


# --- Colour arithmetic -------------------------------------------------------

def multiply(a, b):
    return [[sum(a[i][k] * b[k][j] for k in range(3)) for j in range(3)] for i in range(3)]


def apply(m, v):
    return [sum(m[i][k] * v[k] for k in range(3)) for i in range(3)]


def invert(m):
    a, b, c = m[0]
    d, e, f = m[1]
    g, h, i = m[2]
    det = a * (e * i - f * h) - b * (d * i - f * g) + c * (d * h - e * g)
    return [[(e * i - f * h) / det, (c * h - b * i) / det, (b * f - c * e) / det],
            [(f * g - d * i) / det, (a * i - c * g) / det, (c * d - a * f) / det],
            [(d * h - e * g) / det, (b * g - a * h) / det, (a * e - b * d) / det]]


def xy_to_xyz(xy):
    x, y = xy
    return [x / y, 1.0, (1 - x - y) / y]


def rgb_to_xyz(red, green, blue, white):
    primaries = [list(column) for column in zip(xy_to_xyz(red), xy_to_xyz(green), xy_to_xyz(blue))]
    scale = apply(invert(primaries), xy_to_xyz(white))
    return [[primaries[i][j] * scale[j] for j in range(3)] for i in range(3)]


def bradford(source, target):
    s = apply(BRADFORD, source)
    t = apply(BRADFORD, target)
    scaling = [[t[0] / s[0], 0, 0], [0, t[1] / s[1], 0], [0, 0, t[2] / s[2]]]
    return multiply(invert(BRADFORD), multiply(scaling, BRADFORD))


def adapted_colorants(red, green, blue, white_xy):
    """The colorants adapted to D50 and the adaptation matrix."""
    adaptation = bradford(xy_to_xyz(white_xy), list(D50))
    return multiply(adaptation, rgb_to_xyz(red, green, blue, white_xy)), adaptation


def srgb_to_linear(v):
    return v / 12.92 if v <= 0.04045 else ((v + 0.055) / 1.055) ** 2.4


def linear_to_srgb(v):
    if v <= 0:
        return 0.0
    if v >= 1:
        return 1.0
    return v * 12.92 if v <= 0.0031308 else 1.055 * v ** (1 / 2.4) - 0.055


def xyz_to_lab(xyz):
    def f(t):
        return t ** (1 / 3) if t > (6 / 29) ** 3 else t / (3 * (6 / 29) ** 2) + 4 / 29
    fx, fy, fz = (f(xyz[i] / D50[i]) for i in range(3))
    return 116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz)


# --- ICC profiles --------------------------------------------------------------

def s15(value):
    return struct.pack(">i", int(round(value * 65536)))


def pad4(data):
    return data + b"\0" * (-len(data) % 4)


def xyz_tag(xyz):
    return b"XYZ " + b"\0" * 4 + s15(xyz[0]) + s15(xyz[1]) + s15(xyz[2])


def curv_gamma(gamma_u8f8):
    return pad4(b"curv" + b"\0" * 4 + struct.pack(">IH", 1, gamma_u8f8))


def curv_table(values):
    return pad4(b"curv" + b"\0" * 4 + struct.pack(">I", len(values)) +
                b"".join(struct.pack(">H", max(0, min(65535, int(round(v * 65535))))) for v in values))


def para(function_type, parameters):
    return pad4(b"para" + b"\0" * 4 + struct.pack(">HH", function_type, 0) + b"".join(s15(p) for p in parameters))


SRGB_PARA = (2.4, 1 / 1.055, 0.055 / 1.055, 1 / 12.92, 0.04045)


def desc_v2(text):
    raw = text.encode("ascii") + b"\0"
    return pad4(b"desc" + b"\0" * 4 + struct.pack(">I", len(raw)) + raw + b"\0" * 8 + b"\0" * 3 + b"\0" * 67)


def mluc(text):
    raw = text.encode("utf-16-be")
    return pad4(b"mluc" + b"\0" * 4 + struct.pack(">II", 1, 12) + b"enUS" + struct.pack(">II", len(raw), 28) + raw)


def sf32(matrix):
    return b"sf32" + b"\0" * 4 + b"".join(s15(matrix[i][j]) for i in range(3) for j in range(3))


def profile(version, device_class, space, pcs, tags):
    """tags: [(signature, data)] in order."""
    count = len(tags)
    offset = 128 + 4 + 12 * count
    table = struct.pack(">I", count)
    body = b""
    for signature, data in tags:
        table += signature + struct.pack(">II", offset + len(body), len(data))
        body += pad4(data)
    size = offset + len(body)
    header = struct.pack(">I", size) + b"\0" * 4 + struct.pack(">I", version) + device_class + space + pcs
    header += b"\0" * 12 + b"acsp" + b"\0" * 4 + b"\0" * 4 + b"\0" * 8 + b"\0" * 8 + struct.pack(">I", 0)
    header += s15(D50[0]) + s15(D50[1]) + s15(D50[2]) + b"\0" * 4 + b"\0" * 16 + b"\0" * 28
    assert len(header) == 128
    return header + table + body


def matrix_trc_profile(version, name, colorants, curves, white_point, adaptation=None):
    tags = [(b"desc", desc_v2(name) if version < 0x04000000 else mluc(name)),
            (b"wtpt", xyz_tag(white_point))]
    for index, signature in enumerate((b"rXYZ", b"gXYZ", b"bXYZ")):
        tags.append((signature, xyz_tag([colorants[row][index] for row in range(3)])))
    for signature, curve in zip((b"rTRC", b"gTRC", b"bTRC"), curves):
        tags.append((signature, curve))
    if adaptation is not None:
        tags.append((b"chad", sf32(adaptation)))
    return profile(version, b"mntr", b"RGB ", b"XYZ ", tags)


def grey_profile(version, name, curve):
    tags = [(b"desc", desc_v2(name) if version < 0x04000000 else mluc(name)), (b"wtpt", xyz_tag(D50)),
            (b"kTRC", curve)]
    return profile(version, b"mntr", b"GRAY", b"XYZ ", tags)


def lut16_profile():
    """mft2: gamma 2.2 input tables, a 17-point grid that is a matrix to
    XYZ (linear in the grid, so any interpolation agrees), identity
    output tables. Its matrix/TRC tags say something else."""
    colorants, _ = adapted_colorants((0.64, 0.33), (0.30, 0.60), (0.15, 0.06), D65_XY)
    points = 17
    input_entries = 256
    data = b"mft2" + b"\0" * 4 + bytes([3, 3, points, 0])
    for i in range(3):
        for j in range(3):
            data += s15(1.0 if i == j else 0.0)
    data += struct.pack(">HH", input_entries, 2)
    for _ in range(3):
        for index in range(input_entries):
            data += struct.pack(">H", int(round(((index / 255) ** 2.2) * 65535)))
    for r in range(points):
        for g in range(points):
            for b in range(points):
                xyz = apply(colorants, [r / (points - 1), g / (points - 1), b / (points - 1)])
                for value in xyz:
                    data += struct.pack(">H", max(0, min(65535, int(round(value * 32768)))))
    for _ in range(3):
        data += struct.pack(">HH", 0, 65535)
    wrong_colorants, _ = adapted_colorants((0.70, 0.29), (0.17, 0.80), (0.13, 0.04), D65_XY)
    tags = [(b"desc", desc_v2("LUT16 XYZ test")), (b"wtpt", xyz_tag(D50)), (b"A2B0", data)]
    for index, signature in enumerate((b"rXYZ", b"gXYZ", b"bXYZ")):
        tags.append((signature, xyz_tag([wrong_colorants[row][index] for row in range(3)])))
    for signature in (b"rTRC", b"gTRC", b"bTRC"):
        tags.append((signature, curv_gamma(256)))
    return profile(0x02100000, b"mntr", b"RGB ", b"XYZ ", tags)


def mab_profile():
    """mAB to Lab: A curves (parametric gamma 1.1), a 17-point grid of
    Lab of sRGB's primaries (so mid-tones stay well inside sRGB) over values that the grid decodes by a
    further gamma 2 (2.2 in all; the grid stays close to perceptually
    even, as real LUT profiles make it), identity B curves."""
    colorants, _ = adapted_colorants((0.64, 0.33), (0.30, 0.60), (0.15, 0.06), D65_XY)
    points = 17
    b_curves = b"".join(para(0, (1.0,)) for _ in range(3))
    a_curves = b"".join(para(0, (1.1,)) for _ in range(3))
    grid = bytes([points, points, points]) + b"\0" * 13 + bytes([2, 0, 0, 0])
    for r in range(points):
        for g in range(points):
            for b in range(points):
                linear = [(value / (points - 1)) ** 2.0 for value in (r, g, b)]
                lab = xyz_to_lab(apply(colorants, linear))
                encoded = (lab[0] / 100, (lab[1] + 128) / 255, (lab[2] + 128) / 255)
                for value in encoded:
                    grid += struct.pack(">H", max(0, min(65535, int(round(value * 65535)))))
    grid = pad4(grid)
    header_size = 32
    b_offset = header_size
    grid_offset = b_offset + len(b_curves)
    a_offset = grid_offset + len(grid)
    data = b"mAB " + b"\0" * 4 + bytes([3, 3, 0, 0]) + struct.pack(">IIIII", b_offset, 0, 0, grid_offset, a_offset)
    data += b_curves + grid + a_curves
    tags = [(b"desc", mluc("mAB Lab test")), (b"wtpt", xyz_tag(D50)), (b"A2B0", data)]
    return profile(0x04300000, b"mntr", b"RGB ", b"Lab ", tags)


def cmyk_profile():
    tags = [(b"desc", desc_v2("CMYK placeholder"))]
    return profile(0x02100000, b"prtr", b"CMYK", b"Lab ", tags)


LUT_FIXTURES = ("icc-lut16-xyz", "icc-mab-lab")


def all_profiles():
    p3, p3_adaptation = adapted_colorants((0.680, 0.320), (0.265, 0.690), (0.150, 0.060), D65_XY)
    adobe, _ = adapted_colorants((0.64, 0.33), (0.21, 0.71), (0.15, 0.06), D65_XY)
    apple, _ = adapted_colorants((0.625, 0.34), (0.28, 0.595), (0.155, 0.07), D65_XY)
    prophoto = rgb_to_xyz((0.7347, 0.2653), (0.1596, 0.8404), (0.0366, 0.0001), (0.3457, 0.3585))
    return {
        "icc-display-p3": matrix_trc_profile(0x04300000, "Display P3 test", p3, [para(3, SRGB_PARA)] * 3, D50,
                                             p3_adaptation),
        "icc-adobe-rgb": matrix_trc_profile(0x02100000, "Adobe RGB test", adobe, [curv_gamma(563)] * 3,
                                            (0.95045, 1.0, 1.08905)),
        "icc-gamma18": matrix_trc_profile(0x02100000, "Gamma 1.8 test", apple, [curv_gamma(461)] * 3, D50),
        "icc-prophoto-table": matrix_trc_profile(0x02100000, "ProPhoto table test", prophoto,
                                                 [curv_table([(i / 255) ** 1.8 for i in range(256)])] * 3, D50),
        "icc-lut16-xyz": lut16_profile(),
        "icc-mab-lab": mab_profile(),
    }


# --- Pictures ------------------------------------------------------------------

def colour_picture(width, height):
    """Gradients across the whole cube, saturated colours and greys."""
    image = Image.new("RGB", (width, height))
    pixels = image.load()
    for y in range(height):
        for x in range(width):
            if y < height // 4:
                value = x * 255 // (width - 1)
                pixels[x, y] = (value, value, value)
            elif y < height // 2:
                pixels[x, y] = (x * 255 // (width - 1), (y * 37) % 256, 255 - x * 255 // (width - 1))
            else:
                corner = (x * 4 // width, (y - height // 2) * 2 // (height - height // 2))
                colours = [(255, 0, 0), (0, 255, 0), (0, 0, 255), (255, 255, 0),
                           (0, 255, 255), (255, 0, 255), (40, 90, 160), (200, 120, 60)]
                base = colours[(corner[0] + 4 * corner[1]) % 8]
                fade = (x * 5 + y * 3) % 64
                pixels[x, y] = tuple(max(0, min(255, c - fade)) for c in base)
    return image


def midtone_picture(width, height):
    """Colours from 64 to 191 in every channel."""
    image = colour_picture(width, height)
    return Image.eval(image, lambda value: 64 + value // 2)


def reference_conversion(image, profile_bytes):
    """LittleCMS unoptimised: its optimised 8-bit transforms sample the
    curves into coarse tables, which near black (where a linear-to-sRGB
    curve is steepest) is off by up to 10 levels."""
    source = ImageCms.ImageCmsProfile(io.BytesIO(profile_bytes))
    target = ImageCms.createProfile("sRGB")
    return ImageCms.profileToProfile(image, source, target, renderingIntent=ImageCms.Intent.RELATIVE_COLORIMETRIC,
                                     outputMode="RGB", flags=ImageCms.Flags.NOOPTIMIZE)


def save_icc_fixture(name, image, profile_bytes):
    image.save(path(name + ".png"), icc_profile=profile_bytes)
    fixturecommon.write_reference(path(name + ".rgba"), reference_conversion(image, profile_bytes))


def make_icc_fixtures():
    picture = colour_picture(64, 48)
    midtones = midtone_picture(64, 48)
    for name, profile_bytes in all_profiles().items():
        save_icc_fixture(name, midtones if name in LUT_FIXTURES else picture, profile_bytes)
        with open(path(name + ".icc"), "wb") as output:
            output.write(profile_bytes)
    grey = Image.new("L", (64, 8))
    for x in range(64):
        for y in range(8):
            grey.putpixel((x, y), (x * 4 + y * 13) % 256)
    save_icc_fixture("icc-grey22", grey, grey_profile(0x02100000, "Grey 2.2 test", curv_gamma(563)))
    save_icc_fixture("icc-grey-linear", grey, grey_profile(0x04300000, "Grey linear test", para(0, (1.0,))))
    srgb = ImageCms.ImageCmsProfile(ImageCms.createProfile("sRGB")).tobytes()
    picture.save(path("icc-srgb.png"), icc_profile=srgb)
    fixturecommon.write_reference(path("icc-srgb.rgba"), picture)
    lab = ImageCms.ImageCmsProfile(ImageCms.createProfile("LAB")).tobytes()
    picture.save(path("icc-lab-unsupported.png"), icc_profile=lab)
    fixturecommon.write_reference(path("icc-lab-unsupported.rgba"), picture)
    cmyk = Image.new("CMYK", (32, 16))
    for y in range(16):
        for x in range(32):
            cmyk.putpixel((x, y), (x * 8, y * 16, (x + y) * 5, (x * y) % 128))
    cmyk.save(path("icc-cmyk.jpg"), quality=95, icc_profile=cmyk_profile())


# --- PNG gamma and chromaticities -------------------------------------------------

def png_chunk(kind, data):
    return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)


def png_with_chunks(image, extra_chunks):
    """Pillow's PNG with chunks put in after IHDR."""
    buffer = io.BytesIO()
    image.save(buffer, "PNG")
    data = buffer.getvalue()
    ihdr_end = 8 + 8 + 13 + 4
    return data[:ihdr_end] + b"".join(png_chunk(kind, body) for kind, body in extra_chunks) + data[ihdr_end:]


def convert_by_gamma(image, gamma, matrix):
    """The libimage rule: decode by 1/gamma, the matrix to linear sRGB,
    encode by sRGB's curve."""
    result = Image.new("RGB", image.size)
    source = image.load()
    target = result.load()
    for y in range(image.height):
        for x in range(image.width):
            linear = [(c / 255) ** (1 / gamma) for c in source[x, y]]
            out = apply(matrix, linear)
            target[x, y] = tuple(int(round(255 * linear_to_srgb(v))) for v in out)
    return result


def make_png_gamma_fixtures():
    picture = colour_picture(48, 32)
    srgb_to_pcs = multiply(bradford(xy_to_xyz(D65_XY), list(D50)), rgb_to_xyz((0.64, 0.33), (0.30, 0.60),
                                                                             (0.15, 0.06), D65_XY))
    pcs_to_srgb = invert(srgb_to_pcs)
    with open(path("png-gamma10.png"), "wb") as output:
        output.write(png_with_chunks(picture, [(b"gAMA", struct.pack(">I", 100000))]))
    identity = [[1, 0, 0], [0, 1, 0], [0, 0, 1]]
    fixturecommon.write_reference(path("png-gamma10.rgba"), convert_by_gamma(picture, 1.0, identity))
    with open(path("png-gamma-srgb.png"), "wb") as output:
        output.write(png_with_chunks(picture, [(b"gAMA", struct.pack(">I", 45455))]))
    fixturecommon.write_reference(path("png-gamma-srgb.rgba"), picture)
    p3_xy = [D65_XY, (0.680, 0.320), (0.265, 0.690), (0.150, 0.060)]
    chrm = b"".join(struct.pack(">II", int(round(x * 100000)), int(round(y * 100000))) for x, y in p3_xy)
    with open(path("png-chrm-p3.png"), "wb") as output:
        output.write(png_with_chunks(picture, [(b"gAMA", struct.pack(">I", 45455)), (b"cHRM", chrm)]))
    stored = [tuple(int(round(v * 100000)) / 100000 for v in xy) for xy in p3_xy]
    p3_to_pcs = multiply(bradford(xy_to_xyz(stored[0]), list(D50)), rgb_to_xyz(stored[1], stored[2], stored[3],
                                                                             stored[0]))
    fixturecommon.write_reference(path("png-chrm-p3.rgba"),
                                  convert_by_gamma(picture, 0.45455, multiply(pcs_to_srgb, p3_to_pcs)))


# --- Resampling -------------------------------------------------------------------

def make_resampling_fixtures():
    picture = fixturecommon.smooth_picture(97, 61)
    picture.save(path("resample-source.png"))
    small = fixturecommon.smooth_picture(31, 23)
    small.save(path("resample-small.png"))
    for name, image, size, method in [
            ("resample-lanczos-down", picture, (40, 25), Image.Resampling.LANCZOS),
            ("resample-lanczos-up", small, (70, 50), Image.Resampling.LANCZOS),
            ("resample-bilinear-down", picture, (45, 30), Image.Resampling.BILINEAR),
            ("resample-box-down", picture, (32, 20), Image.Resampling.BOX)]:
        fixturecommon.write_reference(path(name + ".rgba"), image.resize(size, method))


def main():
    make_icc_fixtures()
    make_png_gamma_fixtures()
    make_resampling_fixtures()


if __name__ == "__main__":
    main()
