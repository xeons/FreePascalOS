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

"""The JPEG fixtures of ImageTest.

    make-jpeg-fixtures.py OUTPUT_DIRECTORY

Writes JPEG files made by Pillow (libjpeg-turbo) and, for each, a
reference (name.rgba) from Pillow's own decoding, which uses libjpeg's
accurate integer inverse DCT and fancy upsampling, as libimage does:

  jpeg-444.jpg, jpeg-422.jpg, jpeg-420.jpg   baseline, each subsampling
  jpeg-420-odd.jpg                           37 x 29: partial MCUs
  jpeg-progressive-420.jpg, -444.jpg         progressive
  jpeg-grey.jpg                              one component
  jpeg-restart.jpg                           restart markers every 3 MCUs
  jpeg-cmyk.jpg                              CMYK with an Adobe segment
  jpeg-orientation-6.jpg                     EXIF orientation 6
  jpeg-icc.jpg (+ jpeg-icc.bin)              a 70000 byte ICC profile in
                                             two APP2 chunks
  jpeg-density.jpg                           JFIF 300 x 150 dpi
  jpeg-large.jpg                             4000 x 3000, 4:2:0 (speed)

CMYK has no reference decoding to RGB in Pillow that libimage follows,
so its reference is computed here from Pillow's CMYK samples by the
simple rule libimage uses: each of red, green and blue is
(255 - ink) x (255 - black) / 255, rounded.

With cjpeg (libjpeg-turbo's tool) on the host, sampling factors Pillow
cannot write are made too (they are skipped otherwise):

  jpeg-440.jpg   chroma at half height (luma 1x2)
  jpeg-411.jpg   chroma at a quarter width (luma 4x1)
  jpeg-h1v2.jpg  luma 2x2, chroma 2x1 (chroma at half height only)
"""

import io
import os
import random
import shutil
import subprocess
import sys

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from PIL import Image  # noqa: E402

import fixturecommon  # noqa: E402


def save(directory, name, image, **options):
    path = fixturecommon.output_path(directory, name)
    image.save(path, "JPEG", **options)
    with Image.open(path) as decoded:
        decoded.load()
        fixturecommon.write_reference(path[:-4] + ".rgba", decoded)
    return path


def picture(width, height):
    """Smooth areas, hard edges and noise blended, for a fair test."""
    smooth = fixturecommon.smooth_picture(width, height)
    detail = fixturecommon.test_picture(width, height, seed=7)
    return Image.blend(smooth, detail, 0.35)


def cmyk_fixture(directory):
    source = picture(48, 40)
    pixels = source.load()
    cmyk = Image.new("CMYK", source.size)
    target = cmyk.load()
    for y in range(source.height):
        for x in range(source.width):
            red, green, blue = pixels[x, y]
            black = 255 - max(red, green, blue)
            target[x, y] = (255 - red - black, 255 - green - black, 255 - blue - black, black)
    path = fixturecommon.output_path(directory, "jpeg-cmyk.jpg")
    cmyk.save(path, "JPEG", quality=92)
    with Image.open(path) as decoded:
        decoded.load()
        assert decoded.mode == "CMYK"
        samples = decoded.load()
        reference = []
        for y in range(decoded.height):
            for x in range(decoded.width):
                cyan, magenta, yellow, black = samples[x, y]
                remaining_black = 255 - black
                reference.append((((255 - cyan) * remaining_black + 127) // 255,
                                  ((255 - magenta) * remaining_black + 127) // 255,
                                  ((255 - yellow) * remaining_black + 127) // 255,
                                  255))
        fixturecommon.write_reference_pixels(path[:-4] + ".rgba", decoded.width, decoded.height, reference)


def orientation_fixture(directory):
    exif = Image.Exif()
    exif[0x0112] = 6
    save(directory, "jpeg-orientation-6.jpg", picture(40, 24), quality=90, exif=exif.tobytes())


def icc_fixture(directory):
    profile = bytes((index * 37 + index // 251) % 256 for index in range(70000))
    save(directory, "jpeg-icc.jpg", picture(24, 16), quality=90, icc_profile=profile)
    with open(fixturecommon.output_path(directory, "jpeg-icc.bin"), "wb") as output:
        output.write(profile)


def cjpeg_fixtures(directory):
    cjpeg = shutil.which("cjpeg")
    if cjpeg is None:
        return
    source = picture(53, 41)
    ppm = io.BytesIO()
    source.save(ppm, "PPM")
    for name, sampling in (("jpeg-440.jpg", "1x2,1x1,1x1"), ("jpeg-411.jpg", "4x1,1x1,1x1"),
                           ("jpeg-h1v2.jpg", "2x2,2x1,2x1")):
        path = fixturecommon.output_path(directory, name)
        result = subprocess.run([cjpeg, "-quality", "90", "-sample", sampling, "-outfile", path],
                                input=ppm.getvalue(), capture_output=True)
        if result.returncode != 0:
            continue
        with Image.open(path) as decoded:
            decoded.load()
            fixturecommon.write_reference(path[:-4] + ".rgba", decoded)


def main():
    if len(sys.argv) != 2:
        sys.exit("usage: make-jpeg-fixtures.py OUTPUT_DIRECTORY")
    directory = sys.argv[1]
    os.makedirs(directory, exist_ok=True)
    save(directory, "jpeg-444.jpg", picture(64, 48), quality=90, subsampling=0)
    save(directory, "jpeg-422.jpg", picture(64, 48), quality=90, subsampling=1)
    save(directory, "jpeg-420.jpg", picture(64, 48), quality=90, subsampling=2)
    save(directory, "jpeg-420-odd.jpg", picture(37, 29), quality=85, subsampling=2)
    save(directory, "jpeg-progressive-420.jpg", picture(70, 50), quality=88, subsampling=2, progressive=True)
    save(directory, "jpeg-progressive-444.jpg", picture(45, 33), quality=95, subsampling=0, progressive=True)
    save(directory, "jpeg-grey.jpg", picture(50, 30).convert("L"), quality=90)
    save(directory, "jpeg-restart.jpg", picture(61, 45), quality=90, subsampling=2, restart_marker_blocks=3)
    save(directory, "jpeg-density.jpg", picture(16, 16), quality=90, dpi=(300, 150))
    cmyk_fixture(directory)
    orientation_fixture(directory)
    icc_fixture(directory)
    cjpeg_fixtures(directory)
    smooth = fixturecommon.smooth_picture(400, 300).resize((4000, 3000), Image.BILINEAR)
    noise = Image.frombytes("RGB", (4000, 3000), random.Random(3).randbytes(4000 * 3000 * 3))
    large = Image.blend(smooth, noise, 0.12)
    large.save(fixturecommon.output_path(directory, "jpeg-large.jpg"), "JPEG", quality=90, subsampling=2)


if __name__ == "__main__":
    main()
