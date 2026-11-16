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

"""What the fixture scripts of ImageTest share.

A reference (name.rgba) is the width and height as little-endian 32-bit
numbers, then the pixels as red, green, blue, alpha, line after line
from the top (ImageTest.Checks reads it).
"""

import os
import random
import struct

from PIL import Image


def write_reference(path, image):
    """Writes a Pillow image as a reference file (converted to RGBA)."""
    rgba = image.convert("RGBA")
    with open(path, "wb") as output:
        output.write(struct.pack("<II", rgba.width, rgba.height))
        output.write(rgba.tobytes())


def rgba_pixels(image):
    """A Pillow image's pixels as (red, green, blue, alpha) tuples."""
    data = image.convert("RGBA").tobytes()
    return [tuple(data[index:index + 4]) for index in range(0, len(data), 4)]


def write_reference_pixels(path, width, height, pixels):
    """Writes (red, green, blue, alpha) tuples as a reference file."""
    with open(path, "wb") as output:
        output.write(struct.pack("<II", width, height))
        for red, green, blue, alpha in pixels:
            output.write(bytes((red, green, blue, alpha)))


def test_picture(width, height, seed=1, alpha=False):
    """A picture with gradients, edges and some noise: smooth areas for
    lossy formats and sharp ones for exact formats."""
    generator = random.Random(seed)
    image = Image.new("RGBA" if alpha else "RGB", (width, height))
    pixels = image.load()
    for y in range(height):
        for x in range(width):
            red = (x * 255) // max(1, width - 1)
            green = (y * 255) // max(1, height - 1)
            blue = ((x + y) * 7) % 256 if (x // 8 + y // 8) % 2 else 64
            if alpha:
                pixels[x, y] = (red, green, blue, ((x * 3 + y * 5) % 256))
            else:
                pixels[x, y] = (red, green, blue)
    for _ in range(width * height // 50):
        x = generator.randrange(width)
        y = generator.randrange(height)
        if alpha:
            pixels[x, y] = (generator.randrange(256), generator.randrange(256), generator.randrange(256), 255)
        else:
            pixels[x, y] = (generator.randrange(256), generator.randrange(256), generator.randrange(256))
    return image


def smooth_picture(width, height):
    """A photograph-like picture: smooth gradients and a few soft shapes."""
    image = Image.new("RGB", (width, height))
    pixels = image.load()
    for y in range(height):
        for x in range(width):
            red = int(128 + 100 * ((x / max(1, width)) - 0.5) * 2)
            green = int(128 + 90 * ((y / max(1, height)) - 0.5) * 2)
            blue = int(128 + 60 * (((x + y) / max(1, width + height)) - 0.5) * 2)
            dx = x - width / 3
            dy = y - height / 2
            if dx * dx + dy * dy < (min(width, height) / 4) ** 2:
                red, green, blue = 230, 60, 40
            if abs(x - 2 * width / 3) < width / 10 and abs(y - height / 2) < height / 4:
                red, green, blue = 30, 70, 200
            pixels[x, y] = (max(0, min(255, red)), max(0, min(255, green)), max(0, min(255, blue)))
    return image


def output_path(directory, name):
    os.makedirs(directory, exist_ok=True)
    return os.path.join(directory, name)
