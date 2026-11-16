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

"""The JPEG XL fixtures of ImageTest.

    make-jxl-fixtures.py OUTPUT_DIRECTORY

Pictures are made here (with Pillow, or byte by byte for 16-bit PNGs and
the ICC profile), encoded with libjxl's cjxl and decoded with its djxl;
djxl's output is the reference (name.rgba). Written with libjxl 0.12.0
(cjxl and djxl v0.12.0); the version found is written to
jxl-provenance.txt. Without cjxl and djxl on the host nothing is
written and ImageTest skips every JPEG XL check.

Samples come from djxl as PAM (exact, at the file's own bit depth); a
sample of B bits becomes 8-bit as (V x 255 + (2^B - 1) div 2) div
(2^B - 1), the rounding libimage uses. djxl applies the orientation, so
the reference of an oriented file is the picture as seen.

  jxl-lossless-e1.jxl, -e3, -e7     8-bit RGB, -d 0 at efforts 1, 3, 7
                                   (prefix codes, ANS, MA trees)
  jxl-lossless-e9.jxl               -d 0 -e 9 (palette, delta palette)
  jxl-lossless-palette.jxl          few colours, palette transform
  jxl-lossless-predictors.jxl       one per predictor (-P 0 to 13)
                                    (jxl-lossless-p0.jxl...)
  jxl-lossless-grey.jxl             8-bit greyscale
  jxl-lossless-16bit.jxl            16-bit RGB from a 16-bit PNG
  jxl-lossless-alpha.jxl            8-bit RGBA
  jxl-lossless-grey-alpha.jxl       greyscale and alpha
  jxl-lossless-groups.jxl           600 x 300: several 256 px groups
  jxl-lossless-group128.jxl         -g 0 (128 px groups)
  jxl-lossless-group1024.jxl        -g 3 (1024 px groups)
  jxl-lossless-rct.jxl              -C 6 (YCoCg)
  jxl-lossless-large.jxl            1000 x 700, several groups, -e 2
  jxl-modular-lossy.jxl             -m 1 -d 1 (squeeze, XYB)
  jxl-vardct-d05.jxl, -d1, -d2, -d4 VarDCT at those distances
  jxl-vardct-alpha.jxl              VarDCT with alpha (modular extra channel)
  jxl-vardct-grey.jxl               VarDCT greyscale
  jxl-vardct-odd.jxl                37 x 29
  jxl-vardct-resampling2.jxl        --resampling=2 (2x upsampling)
  jxl-vardct-e3.jxl, -e9.jxl        efforts 3 and 9 (block types)
  jxl-vardct-large.jxl              1000 x 700, -d 1
  jxl-vardct-progressive.jxl        -p (progressive passes)
  jxl-vardct-noepf.jxl              --epf=0 --gaborish=0
  jxl-vardct-epf3.jxl               --epf=3
  jxl-vardct-noise.jxl              --photon_noise_iso=3200 (noise is
                                    random-free in libjxl, but small)
  jxl-animation.jxl                 lossless APNG input: crops, offsets,
                                    delays, blends; one reference per
                                    frame (-frameN.rgba) and
                                    jxl-animation.txt: "loops N" and
                                    "delays D0 D1 ..." in milliseconds
  jxl-animation-lossy.jxl           the same, -d 2
  jxl-orientation.jxl               EXIF orientation 6 (container, Exif in a
                                    brob box); -stored.rgba is the
                                    picture as stored (40 x 20)
  jxl-icc.jxl (+ jxl-icc.icc)       lossless with an ICC profile kept as
                                    want_icc (a table curve no enum
                                    describes)
  jxl-boxes.jxl                     container with Exif and xml boxes
  jxl-jpeg-reconstruction.jxl       a JPEG recompressed losslessly (jbrd)
"""

import os
import random
import shutil
import struct
import subprocess
import sys
import tempfile
import zlib

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from PIL import Image, PngImagePlugin  # noqa: E402

import fixturecommon  # noqa: E402


def run(arguments):
    subprocess.run(arguments, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def to_8(value, bits):
    maximum = (1 << bits) - 1
    return (value * 255 + maximum // 2) // maximum


def read_pam(path):
    """djxl's PAM output: (width, height, depth, maxval, samples)."""
    with open(path, "rb") as source:
        data = source.read()
    header_end = data.index(b"ENDHDR\n") + len(b"ENDHDR\n")
    fields = {}
    for line in data[:header_end].decode("ascii").splitlines()[1:]:
        parts = line.split()
        if len(parts) >= 2:
            fields[parts[0]] = parts[1]
    width = int(fields["WIDTH"])
    height = int(fields["HEIGHT"])
    depth = int(fields["DEPTH"])
    maxval = int(fields["MAXVAL"])
    count = width * height * depth
    body = data[header_end:]
    if maxval > 255:
        samples = struct.unpack(">%dH" % count, body[:count * 2])
    else:
        samples = body[:count]
    return width, height, depth, maxval, samples


def pam_reference(pam_path, reference_path):
    width, height, depth, maxval, samples = read_pam(pam_path)
    bits = maxval.bit_length()
    pixels = []
    for index in range(width * height):
        values = [to_8(sample, bits) for sample in samples[index * depth:(index + 1) * depth]]
        if depth == 1:
            pixels.append((values[0], values[0], values[0], 255))
        elif depth == 2:
            pixels.append((values[0], values[0], values[0], values[1]))
        elif depth == 3:
            pixels.append((values[0], values[1], values[2], 255))
        else:
            pixels.append(tuple(values[:4]))
    fixturecommon.write_reference_pixels(reference_path, width, height, pixels)


class Maker:
    def __init__(self, directory):
        self.directory = directory
        self.work = tempfile.mkdtemp(prefix="jxl-fixtures-")

    def path(self, name):
        return fixturecommon.output_path(self.directory, name)

    def work_path(self, name):
        return os.path.join(self.work, name)

    def encode(self, name, source_path, options):
        """cjxl source_path into name.jxl and djxl it into name.rgba."""
        output = self.path(name + ".jxl")
        run(["cjxl", "--quiet"] + options + [source_path, output])
        pam = self.work_path(name + ".pam")
        run(["djxl", "--quiet", output, pam])
        pam_reference(pam, self.path(name + ".rgba"))
        return output

    def encode_image(self, name, image, options, **save_options):
        source = self.work_path(name + ".png")
        image.save(source, "PNG", **save_options)
        return self.encode(name, source, options)

    def encode_animation(self, name, source_path, options):
        output = self.path(name + ".jxl")
        run(["cjxl", "--quiet"] + options + [source_path, output])
        decoded = self.work_path(name + "-decoded.png")
        run(["djxl", "--quiet", output, decoded])
        delays = []
        with Image.open(decoded) as animation:
            loops = animation.info.get("loop", 0)
            for index in range(animation.n_frames):
                animation.seek(index)
                frame = animation.convert("RGBA")
                fixturecommon.write_reference(self.path("%s-frame%d.rgba" % (name, index)), frame)
                delays.append(int(round(animation.info.get("duration", 0))))
        with open(self.path(name + ".txt"), "w") as description:
            description.write("loops %d\n" % loops)
            description.write("delays %s\n" % " ".join(str(delay) for delay in delays))

    def close(self):
        shutil.rmtree(self.work, ignore_errors=True)


def picture(width, height, seed=7):
    """Smooth areas, hard edges and noise blended, as the JPEG fixtures."""
    smooth = fixturecommon.smooth_picture(width, height)
    detail = fixturecommon.test_picture(width, height, seed=seed)
    return Image.blend(smooth, detail, 0.35)


def few_colours(width, height):
    colours = [(250, 20, 20), (20, 200, 40), (30, 40, 220), (240, 240, 240), (10, 10, 10), (200, 180, 30)]
    image = Image.new("RGB", (width, height))
    pixels = image.load()
    for y in range(height):
        for x in range(width):
            pixels[x, y] = colours[((x // 5) + (y // 7) * 3 + (x * y) // 97) % len(colours)]
    return image


def png_16bit(path, width, height):
    """An RGB PNG with 16-bit samples (Pillow writes none)."""
    rows = bytearray()
    generator = random.Random(16)
    for y in range(height):
        rows.append(0)
        for x in range(width):
            red = (x * 65535) // max(1, width - 1)
            green = (y * 65535) // max(1, height - 1)
            blue = generator.randrange(65536) if (x + y) % 5 == 0 else ((x * 977 + y * 131) * 37) % 65536
            rows += struct.pack(">HHH", red, green, blue)

    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)

    with open(path, "wb") as output:
        output.write(b"\x89PNG\r\n\x1a\n")
        output.write(chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 16, 2, 0, 0, 0)))
        output.write(chunk(b"IDAT", zlib.compress(bytes(rows), 9)))
        output.write(chunk(b"IEND", b""))


def s15_fixed16(value):
    return struct.pack(">i", int(round(value * 65536)))


def xyz_tag(x, y, z):
    return b"XYZ " + bytes(4) + s15_fixed16(x) + s15_fixed16(y) + s15_fixed16(z)


def icc_profile():
    """A display RGB profile (ICC v2) with sRGB-like primaries and a
    1024-entry table curve: no JPEG XL colour enum describes it, so cjxl
    keeps it as an ICC profile."""
    description = b"FreePascalOS test profile"
    desc = b"desc" + bytes(4) + struct.pack(">I", len(description) + 1) + description + b"\x00"
    desc += bytes(4) + bytes(4) + bytes(2) + bytes(1) + bytes(67)
    text = b"text" + bytes(4) + b"No copyright, test data\x00"
    curve_values = []
    for index in range(1024):
        linear = index / 1023
        curve_values.append(int(round(65535 * (linear ** 2.1 * 0.7 + linear * 0.3))))
    curve = b"curv" + bytes(4) + struct.pack(">I", len(curve_values)) + b"".join(
        struct.pack(">H", value) for value in curve_values)
    tags = [
        (b"desc", desc),
        (b"cprt", text),
        (b"wtpt", xyz_tag(0.9642, 1.0, 0.8249)),
        (b"rXYZ", xyz_tag(0.4361, 0.2225, 0.0139)),
        (b"gXYZ", xyz_tag(0.3851, 0.7169, 0.0971)),
        (b"bXYZ", xyz_tag(0.1431, 0.0606, 0.7139)),
        (b"rTRC", curve),
        (b"gTRC", curve),
        (b"bTRC", curve),
    ]
    offset = 128 + 4 + 12 * len(tags)
    table = struct.pack(">I", len(tags))
    body = b""
    for signature, data in tags:
        while len(data) % 4:
            data += b"\x00"
        table += signature + struct.pack(">II", offset + len(body), len(data))
        body += data
    size = offset + len(body)
    header = struct.pack(">I", size) + b"none" + bytes([2, 0x20, 0, 0]) + b"mntrRGB XYZ "
    header += struct.pack(">HHHHHH", 2026, 1, 1, 0, 0, 0) + b"acsp" + b"APPL" + bytes(4)
    header += bytes(4) + bytes(4) + bytes(8) + bytes(4)
    header += s15_fixed16(0.9642) + s15_fixed16(1.0) + s15_fixed16(0.8249) + b"none"
    header += bytes(128 - len(header))
    return header + table + body


def make_lossless(maker):
    base = fixturecommon.test_picture(96, 64, seed=3)
    for effort in (1, 3, 7):
        maker.encode_image("jxl-lossless-e%d" % effort, base, ["-d", "0", "-e", str(effort)])
    maker.encode_image("jxl-lossless-e9", fixturecommon.test_picture(48, 40, seed=4), ["-d", "0", "-e", "9"])
    maker.encode_image("jxl-lossless-palette", few_colours(80, 60), ["-d", "0", "-e", "7"])
    small = fixturecommon.test_picture(40, 30, seed=5)
    for predictor in range(14):
        maker.encode_image("jxl-lossless-p%d" % predictor, small, ["-d", "0", "-e", "3", "-P", str(predictor)])
    maker.encode_image("jxl-lossless-grey", base.convert("L"), ["-d", "0"])
    source16 = maker.work_path("sixteen.png")
    png_16bit(source16, 50, 40)
    maker.encode("jxl-lossless-16bit", source16, ["-d", "0"])
    alpha = fixturecommon.test_picture(72, 56, seed=6, alpha=True)
    maker.encode_image("jxl-lossless-alpha", alpha, ["-d", "0"])
    maker.encode_image("jxl-lossless-grey-alpha", alpha.convert("LA"), ["-d", "0"])
    groups = picture(600, 300, seed=8)
    maker.encode_image("jxl-lossless-groups", groups, ["-d", "0", "-e", "3"])
    maker.encode_image("jxl-lossless-group128", picture(300, 200, seed=9), ["-d", "0", "-g", "0"])
    maker.encode_image("jxl-lossless-group1024", picture(300, 200, seed=10), ["-d", "0", "-g", "3"])
    maker.encode_image("jxl-lossless-rct", picture(64, 48, seed=11), ["-d", "0", "-C", "6"])
    maker.encode_image("jxl-lossless-large", picture(1000, 700, seed=12), ["-d", "0", "-e", "2"])


def make_lossy(maker):
    photo = picture(160, 120)
    maker.encode_image("jxl-modular-lossy", photo, ["-m", "1", "-d", "1"])
    for label, distance in (("d05", "0.5"), ("d1", "1"), ("d2", "2"), ("d4", "4")):
        maker.encode_image("jxl-vardct-" + label, photo, ["-d", distance])
    alpha = fixturecommon.test_picture(96, 72, seed=13, alpha=True)
    maker.encode_image("jxl-vardct-alpha", Image.blend(picture(96, 72).convert("RGBA"), alpha, 0.5), ["-d", "1"])
    maker.encode_image("jxl-vardct-grey", photo.convert("L"), ["-d", "1"])
    maker.encode_image("jxl-vardct-odd", picture(37, 29), ["-d", "1"])
    maker.encode_image("jxl-vardct-resampling2", photo, ["-d", "2", "--resampling=2"])
    maker.encode_image("jxl-vardct-e3", photo, ["-d", "1", "-e", "3"])
    maker.encode_image("jxl-vardct-e9", photo, ["-d", "1", "-e", "9"])
    maker.encode_image("jxl-vardct-large", picture(1000, 700, seed=14), ["-d", "1"])
    maker.encode_image("jxl-vardct-progressive", photo, ["-d", "1", "-p"])
    maker.encode_image("jxl-vardct-noepf", photo, ["-d", "2", "--epf=0", "--gaborish=0"])
    maker.encode_image("jxl-vardct-epf3", photo, ["-d", "3", "--epf=3"])
    maker.encode_image("jxl-vardct-noise", photo, ["-d", "1", "--photon_noise_iso=3200"])


def animation_source(path):
    width, height = 64, 48
    frames = []
    background = fixturecommon.test_picture(width, height, seed=20, alpha=False).convert("RGBA")
    frames.append(background)
    second = background.copy()
    second.paste((255, 0, 0, 255), (10, 8, 30, 24))
    frames.append(second)
    third = second.copy()
    third.paste((0, 0, 255, 128), (30, 20, 60, 44))
    frames.append(third)
    fourth = third.copy()
    fourth.paste(fixturecommon.test_picture(16, 16, seed=21, alpha=True), (40, 4))
    frames.append(fourth)
    frames[0].save(path, "PNG", save_all=True, append_images=frames[1:], duration=[100, 250, 40, 1000], loop=3,
                   disposal=0, blend=0)


def make_animations(maker):
    source = maker.work_path("animation.png")
    animation_source(source)
    maker.encode_animation("jxl-animation", source, ["-d", "0"])
    maker.encode_animation("jxl-animation-lossy", source, ["-d", "2"])


def make_metadata(maker):
    image = picture(40, 20)
    exif = Image.Exif()
    exif[0x0112] = 6
    maker.encode_image("jxl-orientation", image, ["-d", "0"], exif=exif.tobytes())
    fixturecommon.write_reference(maker.path("jxl-orientation-stored.rgba"), image)

    profile = icc_profile()
    with open(maker.path("jxl-icc.icc"), "wb") as output:
        output.write(profile)
    maker.encode_image("jxl-icc", picture(48, 32), ["-d", "0"], icc_profile=profile)

    information = PngImagePlugin.PngInfo()
    information.add_itxt("XML:com.adobe.xmp", "<x:xmpmeta xmlns:x=\"adobe:ns:meta/\">FreePascalOS</x:xmpmeta>")
    exif = Image.Exif()
    exif[0x010E] = "FreePascalOS test"
    maker.encode_image("jxl-boxes", picture(32, 24), ["-d", "0", "--container=1", "--compress_boxes=0"],
                       exif=exif.tobytes(), pnginfo=information)

    jpeg = maker.work_path("reconstruction.jpg")
    picture(64, 48).save(jpeg, "JPEG", quality=90, subsampling=2)
    maker.encode("jxl-jpeg-reconstruction", jpeg, ["-j", "1"])


def tool_version(tool):
    result = subprocess.run([tool, "--version"], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    return result.stdout.splitlines()[0] if result.stdout else "unknown"


def main():
    if len(sys.argv) != 2:
        sys.exit("usage: make-jxl-fixtures.py OUTPUT_DIRECTORY")
    directory = sys.argv[1]
    os.makedirs(directory, exist_ok=True)
    if shutil.which("cjxl") is None or shutil.which("djxl") is None:
        print("make-jxl-fixtures.py: cjxl and djxl (libjxl) not found, JPEG XL fixtures not made")
        return
    maker = Maker(directory)
    try:
        make_lossless(maker)
        make_lossy(maker)
        make_animations(maker)
        make_metadata(maker)
        with open(maker.path("jxl-provenance.txt"), "w") as provenance:
            provenance.write("%s\n%s\n" % (tool_version("cjxl"), tool_version("djxl")))
    finally:
        maker.close()


if __name__ == "__main__":
    main()
