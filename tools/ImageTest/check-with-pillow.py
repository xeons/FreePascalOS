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

"""Pillow reads what ImageTest wrote.

    check-with-pillow.py WRITTEN_DIRECTORY

ImageTest writes each file its encoders made (name.png, name.tif...)
with the pixels it was made from beside it (name.rgba, see
fixturecommon.py). Every file must open in Pillow and give exactly
those pixels; the exit code is 1 if any does not. An animation (APNG,
WebP) is checked by its first frame as Pillow shows it, and by every
frame when references name-frame1.rgba, name-frame2.rgba... are there
too (name-frame0.rgba being name.rgba).
"""

import os
import struct
import sys

from PIL import Image


def read_reference(path):
    with open(path, "rb") as source:
        data = source.read()
    width, height = struct.unpack("<II", data[:8])
    return width, height, data[8:8 + width * height * 4]


def first_difference(actual, expected, width):
    for index in range(0, len(expected), 4):
        if actual[index:index + 4] != expected[index:index + 4]:
            pixel = index // 4
            return (pixel % width, pixel // width, tuple(actual[index:index + 4]),
                    tuple(expected[index:index + 4]))
    return None


def compare(name, image, reference_path, label):
    width, height, expected = read_reference(reference_path)
    decoded = image.convert("RGBA")
    if decoded.size != (width, height):
        return f"{name}{label}: Pillow reads {decoded.size[0]} x {decoded.size[1]}, written {width} x {height}"
    actual = decoded.tobytes()
    if actual != expected:
        x, y, got, wanted = first_difference(actual, expected, width)
        return f"{name}{label}: pixel ({x}, {y}) is {got}, written {wanted}"
    return None


def check(directory, name):
    base = os.path.join(directory, os.path.splitext(name)[0])
    reference_path = base + ".rgba"
    if not os.path.exists(reference_path):
        return f"{name}: no reference"
    try:
        with Image.open(os.path.join(directory, name)) as image:
            image.load()
            problem = compare(name, image, reference_path, "")
            index = 1
            while problem is None and os.path.exists(f"{base}-frame{index}.rgba"):
                if getattr(image, "n_frames", 1) <= index:
                    return f"{name}: Pillow sees {getattr(image, 'n_frames', 1)} frames, more were written"
                image.seek(index)
                problem = compare(name, image, f"{base}-frame{index}.rgba", f" frame {index}")
                index += 1
            return problem
    except Exception as error:
        return f"{name}: Pillow cannot read it ({error})"


def main():
    directory = sys.argv[1]
    names = sorted(name for name in os.listdir(directory) if not name.endswith(".rgba"))
    failures = [problem for problem in (check(directory, name) for name in names) if problem]
    for problem in failures:
        print("FAIL", problem)
    print(f"Pillow read {len(names) - len(failures)} of {len(names)} written files as written")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
