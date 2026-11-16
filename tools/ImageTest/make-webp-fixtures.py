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

"""The WebP fixtures of ImageTest.

    make-webp-fixtures.py OUTPUT_DIRECTORY

Every reference (name.rgba, see fixturecommon.py) is Pillow's decoding,
which is libwebp's; lossless files must also give back exactly the
pixels they were made from.

Files Pillow writes:

  webp-lossless-*        lossless: a picture with noise, alpha, palettes
                         of 2, 4, 16 and 200 colours (pixels packed 8,
                         4, 2 and 1 to a byte), one colour, 1 x 1, one
                         column, and the encoder's fastest and most
                         thorough settings on a large picture (colour
                         cache, several prefix code groups)
  webp-lossy-*           lossy at qualities 10 to 100, both ends of the
                         encoder's effort, odd and tiny sizes, a large
                         picture, alpha (lossless and quantised ALPH)
  webp-metadata          an ICC profile (webp-metadata.icc), EXIF with
                         orientation 6 and XMP (webp-metadata.xmp)
  webp-anim-pillow-*     animations Pillow's encoder puts together,
                         lossless and lossy; every frame as Pillow shows
                         it (name-frameN.rgba)

Files put together here from parts Pillow writes:

  webp-alpha-filter-N    a lossy picture with an ALPH chunk filtered
                         each way (0 none, 1 horizontal, 2 vertical,
                         3 gradient), raw; webp-alpha-lossless-N the
                         same compressed as a headerless VP8L stream
  webp-anim-*            ANMF frames with every blend and dispose
                         flag, offsets, durations and a loop count;
                         binary alpha (compositing must be exact), a
                         translucent one, lossy and lossless frames
                         mixed, and one cut short in its fourth frame

With libwebp itself (through ctypes, when it can be loaded) the encoder
settings Pillow does not reach: the simple loop filter, sharpness, four
token partitions, no filter, one segment, raw alpha (webp-libwebp-*).
"""

import ctypes
import ctypes.util
import io
import os
import random
import struct
import sys

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from PIL import Image  # noqa: E402

import fixturecommon  # noqa: E402

OUTPUT = sys.argv[1] if len(sys.argv) > 1 else "build/tools/image-fixtures"
WARNINGS = []


def path(name):
    return fixturecommon.output_path(OUTPUT, name)


def write_file(name, data):
    with open(path(name), "wb") as output:
        output.write(data)


def pillow_frames(data):
    """Every frame of a WebP file as Pillow shows it (RGBA), with the
    file's info."""
    frames = []
    with Image.open(io.BytesIO(data)) as image:
        info = dict(image.info)
        count = getattr(image, "n_frames", 1)
        for index in range(count):
            image.seek(index)
            frames.append(image.convert("RGBA"))
            frames[-1].info["duration"] = image.info.get("duration", 0)
    return frames, info


def save_with_reference(name, data, source=None):
    """Writes name.webp and Pillow's decoding as name.rgba; a source
    the decoding must equal exactly."""
    write_file(name + ".webp", data)
    frames, _ = pillow_frames(data)
    fixturecommon.write_reference(path(name + ".rgba"), frames[0])
    if source is not None and frames[0].tobytes() != source.convert("RGBA").tobytes():
        WARNINGS.append(f"{name}: Pillow does not give back the pixels written losslessly")
    return frames[0]


def encode(image, **options):
    buffer = io.BytesIO()
    image.save(buffer, "WEBP", **options)
    return buffer.getvalue()


def chunks_of(data):
    """The (tag, payload) chunks of a RIFF WebP file."""
    result = []
    position = 12
    end = 8 + struct.unpack("<I", data[4:8])[0]
    while position + 8 <= end:
        tag = data[position:position + 4]
        size = struct.unpack("<I", data[position + 4:position + 8])[0]
        result.append((tag, data[position + 8:position + 8 + size]))
        position += 8 + size + (size & 1)
    return result


def chunk(tag, payload):
    return tag + struct.pack("<I", len(payload)) + payload + (b"\0" if len(payload) & 1 else b"")


def riff(body):
    return b"RIFF" + struct.pack("<I", 4 + len(body)) + b"WEBP" + body


def long24(value):
    return struct.pack("<I", value)[:3]


def vp8x(flags, width, height):
    return chunk(b"VP8X", bytes((flags, 0, 0, 0)) + long24(width - 1) + long24(height - 1))


def picture_chunks(data):
    """The ALPH/VP8 or VP8L chunks of a still WebP file, as bytes."""
    return b"".join(chunk(tag, payload) for tag, payload in chunks_of(data) if tag in (b"ALPH", b"VP8 ", b"VP8L"))


def palette_picture(width, height, colours, seed):
    generator = random.Random(seed)
    palette = [(generator.randrange(256), generator.randrange(256), generator.randrange(256), 255)
               for _ in range(colours)]
    image = Image.new("RGBA", (width, height))
    image.putdata([palette[(x * 3 + y * 7 + (x * y) // 5) % colours] for y in range(height) for x in range(width)])
    return image


# --- Lossless ----------------------------------------------------------

def lossless_files():
    photo = fixturecommon.test_picture(64, 48, seed=11)
    save_with_reference("webp-lossless-photo", encode(photo, lossless=True, exact=True), photo)
    alpha = fixturecommon.test_picture(37, 29, seed=12, alpha=True)
    save_with_reference("webp-lossless-alpha", encode(alpha, lossless=True, exact=True), alpha)
    for colours in (2, 4, 16, 200):
        picture = palette_picture(45, 21, colours, colours)
        save_with_reference(f"webp-lossless-palette{colours}", encode(picture, lossless=True, exact=True), picture)
    flat = Image.new("RGB", (23, 17), (40, 120, 200))
    save_with_reference("webp-lossless-flat", encode(flat, lossless=True, exact=True), flat)
    single = Image.new("RGBA", (1, 1), (10, 20, 30, 40))
    save_with_reference("webp-lossless-1x1", encode(single, lossless=True, exact=True), single)
    column = fixturecommon.test_picture(1, 40, seed=13)
    save_with_reference("webp-lossless-column", encode(column, lossless=True, exact=True), column)
    large = fixturecommon.test_picture(300, 200, seed=14, alpha=True)
    save_with_reference("webp-lossless-fast", encode(large, lossless=True, exact=True, quality=0, method=0), large)
    save_with_reference("webp-lossless-best", encode(large, lossless=True, exact=True, quality=100, method=6), large)
    smooth = fixturecommon.smooth_picture(200, 150)
    save_with_reference("webp-lossless-smooth", encode(smooth, lossless=True, quality=90, method=5), smooth)


# --- Lossy -------------------------------------------------------------

def lossy_files():
    smooth = fixturecommon.smooth_picture(96, 64)
    for quality in (10, 50, 75, 95, 100):
        save_with_reference(f"webp-lossy-q{quality}", encode(smooth, quality=quality))
    photo = fixturecommon.test_picture(80, 60, seed=21)
    save_with_reference("webp-lossy-fast", encode(photo, quality=80, method=0))
    save_with_reference("webp-lossy-best", encode(photo, quality=80, method=6))
    save_with_reference("webp-lossy-odd", encode(fixturecommon.smooth_picture(33, 17), quality=70))
    save_with_reference("webp-lossy-1x1", encode(Image.new("RGB", (1, 1), (200, 30, 90)), quality=90))
    save_with_reference("webp-lossy-3x2", encode(fixturecommon.test_picture(3, 2, seed=22), quality=90))
    large = fixturecommon.test_picture(250, 170, seed=23)
    save_with_reference("webp-lossy-large", encode(large, quality=85))
    alpha = fixturecommon.test_picture(45, 35, seed=24, alpha=True)
    save_with_reference("webp-lossy-alpha", encode(alpha, quality=80))
    save_with_reference("webp-lossy-alpha-q30", encode(alpha, quality=60, alpha_quality=30))


def metadata_file():
    picture = fixturecommon.test_picture(30, 20, seed=31)
    try:
        from PIL import ImageCms
        profile = ImageCms.ImageCmsProfile(ImageCms.createProfile("sRGB")).tobytes()
    except Exception:
        profile = b"\0\0\0\x80fake-profile" + bytes(range(116))
    exif = Image.Exif()
    exif[0x0112] = 6
    xmp = b'<x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF/></x:xmpmeta>'
    data = encode(picture, lossless=True, icc_profile=profile, exif=exif, xmp=xmp)
    save_with_reference("webp-metadata", data, picture)
    write_file("webp-metadata.icc", profile)
    write_file("webp-metadata.xmp", xmp)


# --- ALPH filters --------------------------------------------------------

def alpha_plane(width, height):
    values = []
    for y in range(height):
        for x in range(width):
            value = (x * 255) // max(1, width - 1)
            if (x - width // 2) ** 2 + (y - height // 2) ** 2 < (min(width, height) // 3) ** 2:
                value = 255 - (y * 4) % 256
            values.append(value)
    return values


def filter_alpha(values, width, height, method):
    """The deltas that ALPH filter method (0 to 3) leaves."""
    deltas = []
    for y in range(height):
        for x in range(width):
            value = values[y * width + x]
            left = values[y * width + x - 1] if x > 0 else None
            top = values[(y - 1) * width + x] if y > 0 else None
            if method == 0:
                prediction = 0
            elif y == 0:
                prediction = left if x > 0 else 0
            elif x == 0:
                prediction = top
            elif method == 1:
                prediction = left
            elif method == 2:
                prediction = top
            else:
                top_left = values[(y - 1) * width + x - 1]
                prediction = max(0, min(255, left + top - top_left))
            deltas.append((value - prediction) & 255)
    return bytes(deltas)


def alpha_files():
    width, height = 40, 26
    picture = fixturecommon.smooth_picture(width, height)
    lossy = [payload for tag, payload in chunks_of(encode(picture, quality=85)) if tag == b"VP8 "][0]
    values = alpha_plane(width, height)
    for method in range(4):
        deltas = filter_alpha(values, width, height, method)
        raw = bytes((method << 2,)) + deltas
        grey = Image.new("RGB", (width, height))
        grey.putdata([(0, delta, 0) for delta in deltas])
        stream = [payload for tag, payload in chunks_of(encode(grey, lossless=True)) if tag == b"VP8L"][0][5:]
        compressed = bytes((1 | (method << 2),)) + stream
        for name, alph in ((f"webp-alpha-filter-{method}", raw), (f"webp-alpha-lossless-{method}", compressed)):
            data = riff(vp8x(0x10, width, height) + chunk(b"ALPH", alph) + chunk(b"VP8 ", lossy))
            decoded = save_with_reference(name, data)
            if decoded.getchannel("A").tobytes() != bytes(values):
                WARNINGS.append(f"{name}: Pillow reads another alpha")


# --- Animations -----------------------------------------------------------

def frame_image(width, height, seed, alpha_kind):
    """A frame picture; alpha_kind is 'opaque', 'binary' or 'translucent'."""
    generator = random.Random(seed)
    image = Image.new("RGBA", (width, height))
    pixels = []
    for y in range(height):
        for x in range(width):
            red = (x * 40 + seed * 50) % 256
            green = (y * 30 + seed * 20) % 256
            blue = generator.randrange(256) if (x + y) % 5 == 0 else (seed * 70) % 256
            if alpha_kind == "opaque":
                alpha = 255
            elif alpha_kind == "binary":
                alpha = 0 if (x // 3 + y // 3) % 3 == 0 else 255
            else:
                alpha = (x * 23 + y * 11 + seed * 40) % 256
            pixels.append((red, green, blue, alpha))
    image.putdata(pixels)
    return image


def frame_chunk(image, left, top, duration, dispose, no_blend, lossy=False):
    if lossy:
        bitstream = picture_chunks(encode(image, quality=80))
    else:
        bitstream = picture_chunks(encode(image, lossless=True, exact=True))
    flags = (2 if dispose else 0) | (1 if no_blend else 0)
    header = long24(left // 2) + long24(top // 2) + long24(image.width - 1) + long24(image.height - 1) + \
        long24(duration) + bytes((flags,))
    return chunk(b"ANMF", header + bitstream)


def animation(width, height, background, loops, frames):
    body = vp8x(0x02 | 0x10, width, height) + chunk(b"ANIM", struct.pack("<IH", background, loops))
    return riff(body + b"".join(frames))


def save_animation(name, data, expected_count=None):
    write_file(name + ".webp", data)
    frames, info = pillow_frames(data)
    if expected_count is not None and len(frames) != expected_count:
        WARNINGS.append(f"{name}: Pillow sees {len(frames)} frames, {expected_count} written")
    for index, frame in enumerate(frames):
        fixturecommon.write_reference(path(f"{name}-frame{index}.rgba"), frame)
    fixturecommon.write_reference(path(name + ".rgba"), frames[0])
    return frames


def constructed_animations():
    # Frame: size, offset, duration, dispose to background, no blend, alpha.
    plan = [
        ((40, 30), (0, 0), 100, False, True, "opaque"),
        ((16, 12), (4, 6), 200, True, False, "binary"),
        ((20, 10), (10, 14), 50, False, True, "binary"),
        ((12, 12), (24, 2), 0, True, False, "binary"),
        ((8, 8), (0, 0), 300, False, False, "binary"),
    ]
    frames = [frame_chunk(frame_image(size[0], size[1], index + 1, kind), offset[0], offset[1], duration, dispose,
                          no_blend)
              for index, (size, offset, duration, dispose, no_blend, kind) in enumerate(plan)]
    data = animation(40, 30, 0xFF336699, 3, frames)
    save_animation("webp-anim-flags", data, len(plan))
    # Cut inside the fourth frame: three frames are left.
    fourth = data.index(frames[3])
    save_animation_cut("webp-anim-truncated", data[:fourth + len(frames[3]) // 2])

    translucent = [
        frame_chunk(frame_image(30, 20, 1, "translucent"), 0, 0, 80, False, True),
        frame_chunk(frame_image(18, 12, 2, "translucent"), 6, 4, 80, False, False),
        frame_chunk(frame_image(10, 10, 3, "translucent"), 14, 8, 80, True, False),
        frame_chunk(frame_image(12, 8, 4, "translucent"), 2, 10, 80, False, False),
    ]
    save_animation("webp-anim-translucent", animation(30, 20, 0, 0, translucent), 4)

    mixed = [
        frame_chunk(frame_image(32, 24, 5, "opaque"), 0, 0, 120, False, True, lossy=True),
        frame_chunk(frame_image(16, 16, 6, "binary"), 8, 4, 120, True, False),
        frame_chunk(frame_image(20, 14, 7, "translucent"), 12, 10, 120, False, True, lossy=True),
    ]
    save_animation("webp-anim-mixed", animation(32, 24, 0xFFFFFFFF, 1, mixed), 3)


def save_animation_cut(name, data):
    write_file(name + ".webp", data)


def pillow_animations():
    frames = [frame_image(36, 28, seed, "binary" if seed % 2 else "opaque") for seed in range(1, 5)]
    for name, options in (("webp-anim-pillow-lossless", {"lossless": True}),
                          ("webp-anim-pillow-lossy", {"quality": 70})):
        buffer = io.BytesIO()
        frames[0].save(buffer, "WEBP", save_all=True, append_images=frames[1:], duration=[70, 140, 210, 280],
                       loop=2, **options)
        save_animation(name, buffer.getvalue(), len(frames))


# --- libwebp's own settings ------------------------------------------------

class WebPConfig(ctypes.Structure):
    _fields_ = [(name, ctypes.c_float if name in ("quality", "target_PSNR") else ctypes.c_int) for name in (
        "lossless", "quality", "method", "image_hint", "target_size", "target_PSNR", "segments", "sns_strength",
        "filter_strength", "filter_sharpness", "filter_type", "autofilter", "alpha_compression", "alpha_filtering",
        "alpha_quality", "pass_count", "show_compressed", "preprocessing", "partitions", "partition_limit",
        "emulate_jpeg_size", "thread_level", "low_memory", "near_lossless", "exact", "use_delta_palette",
        "use_sharp_yuv", "qmin", "qmax")]


class WebPPicture(ctypes.Structure):
    _fields_ = [
        ("use_argb", ctypes.c_int), ("colorspace", ctypes.c_int), ("width", ctypes.c_int),
        ("height", ctypes.c_int), ("y", ctypes.c_void_p), ("u", ctypes.c_void_p), ("v", ctypes.c_void_p),
        ("y_stride", ctypes.c_int), ("uv_stride", ctypes.c_int), ("a", ctypes.c_void_p), ("a_stride", ctypes.c_int),
        ("pad1", ctypes.c_uint32 * 2), ("argb", ctypes.c_void_p), ("argb_stride", ctypes.c_int),
        ("pad2", ctypes.c_uint32 * 3), ("writer", ctypes.c_void_p), ("custom_ptr", ctypes.c_void_p),
        ("extra_info_type", ctypes.c_int), ("extra_info", ctypes.c_void_p), ("stats", ctypes.c_void_p),
        ("error_code", ctypes.c_int), ("progress_hook", ctypes.c_void_p), ("user_data", ctypes.c_void_p),
        ("pad3", ctypes.c_uint32 * 3), ("pad4", ctypes.c_void_p), ("pad5", ctypes.c_void_p),
        ("pad6", ctypes.c_uint32 * 8), ("memory_", ctypes.c_void_p), ("memory_argb_", ctypes.c_void_p),
        ("pad7", ctypes.c_void_p * 2)]


class WebPMemoryWriter(ctypes.Structure):
    _fields_ = [("mem", ctypes.c_void_p), ("size", ctypes.c_size_t), ("max_size", ctypes.c_size_t),
                ("pad", ctypes.c_uint32 * 1)]


ENCODER_ABI_VERSION = 0x0210


def load_libwebp():
    name = ctypes.util.find_library("webp")
    if name is None:
        return None
    try:
        library = ctypes.CDLL(name)
        library.WebPConfigInitInternal.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_float, ctypes.c_int]
        library.WebPPictureInitInternal.argtypes = [ctypes.c_void_p, ctypes.c_int]
        library.WebPPictureImportRGBA.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_int]
        library.WebPEncode.argtypes = [ctypes.c_void_p, ctypes.c_void_p]
        library.WebPValidateConfig.argtypes = [ctypes.c_void_p]
        library.WebPMemoryWriterInit.argtypes = [ctypes.c_void_p]
        library.WebPMemoryWriterClear.argtypes = [ctypes.c_void_p]
        library.WebPPictureFree.argtypes = [ctypes.c_void_p]
        library.WebPGetEncoderVersion.restype = ctypes.c_int
        if library.WebPGetEncoderVersion() >> 16 < 1:
            return None
        return library
    except (OSError, AttributeError):
        return None


def libwebp_encode(library, image, quality, **settings):
    config = WebPConfig()
    if not library.WebPConfigInitInternal(ctypes.byref(config), 0, ctypes.c_float(quality), ENCODER_ABI_VERSION):
        return None
    for key, value in settings.items():
        setattr(config, key, value)
    if not library.WebPValidateConfig(ctypes.byref(config)):
        return None
    picture = WebPPicture()
    if not library.WebPPictureInitInternal(ctypes.byref(picture), ENCODER_ABI_VERSION):
        return None
    rgba = image.convert("RGBA")
    picture.width, picture.height = rgba.size
    picture.use_argb = 0
    writer = WebPMemoryWriter()
    library.WebPMemoryWriterInit(ctypes.byref(writer))
    try:
        if not library.WebPPictureImportRGBA(ctypes.byref(picture), rgba.tobytes(), rgba.width * 4):
            return None
        picture.writer = ctypes.cast(library.WebPMemoryWrite, ctypes.c_void_p).value
        picture.custom_ptr = ctypes.addressof(writer)
        if not library.WebPEncode(ctypes.byref(config), ctypes.byref(picture)):
            return None
        return ctypes.string_at(writer.mem, writer.size)
    finally:
        library.WebPPictureFree(ctypes.byref(picture))
        library.WebPMemoryWriterClear(ctypes.byref(writer))


def libwebp_files():
    library = load_libwebp()
    if library is None:
        WARNINGS.append("libwebp cannot be loaded through ctypes: the webp-libwebp-* fixtures are left out")
        return
    picture = fixturecommon.test_picture(120, 88, seed=41)
    alpha = fixturecommon.test_picture(48, 40, seed=42, alpha=True)
    variants = [
        ("webp-libwebp-simple-filter", picture, 75, {"filter_type": 0, "filter_strength": 60}),
        ("webp-libwebp-sharp", picture, 75, {"filter_sharpness": 7, "filter_strength": 80}),
        ("webp-libwebp-soft", picture, 60, {"filter_sharpness": 2, "filter_strength": 100, "sns_strength": 100}),
        ("webp-libwebp-partitions", fixturecommon.test_picture(200, 150, seed=43), 80, {"partitions": 3}),
        ("webp-libwebp-no-filter", picture, 75, {"filter_strength": 0, "autofilter": 0}),
        ("webp-libwebp-one-segment", picture, 75, {"segments": 1, "sns_strength": 0}),
        ("webp-libwebp-alpha-raw", alpha, 75, {"alpha_compression": 0, "alpha_filtering": 1}),
        ("webp-libwebp-alpha-best", alpha, 75, {"alpha_filtering": 2, "alpha_quality": 50, "preprocessing": 2}),
    ]
    for name, image, quality, settings in variants:
        data = libwebp_encode(library, image, quality, **settings)
        if data is None:
            WARNINGS.append(f"{name}: libwebp would not encode it")
            continue
        save_with_reference(name, data)


def main():
    lossless_files()
    lossy_files()
    metadata_file()
    alpha_files()
    constructed_animations()
    pillow_animations()
    libwebp_files()
    for warning in WARNINGS:
        print("warning:", warning)


if __name__ == "__main__":
    main()
