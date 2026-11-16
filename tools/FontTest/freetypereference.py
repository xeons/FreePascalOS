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

"""
FreeType as the font test's reference: glyphs rendered unhinted and
anti-aliased, character map lookups, advances and the kern table.

freetype-py is used when it is installed; otherwise the FreeType
library itself (the one Pillow uses) through ctypes, with only the
structure fields the test needs declared.
"""

import ctypes
import ctypes.util

LOAD_NO_SCALE = 0x1
LOAD_NO_HINTING = 0x2
LOAD_RENDER = 0x4
LOAD_NO_BITMAP = 0x8
KERNING_UNSCALED = 2


class FreeTypeMissing(Exception):
    pass


try:
    import freetype as _freetype_py
except ImportError:
    _freetype_py = None


class _Generic(ctypes.Structure):
    _fields_ = [('data', ctypes.c_void_p), ('finalizer', ctypes.c_void_p)]


class _BBox(ctypes.Structure):
    _fields_ = [('xMin', ctypes.c_long), ('yMin', ctypes.c_long), ('xMax', ctypes.c_long), ('yMax', ctypes.c_long)]


class _Vector(ctypes.Structure):
    _fields_ = [('x', ctypes.c_long), ('y', ctypes.c_long)]


class _GlyphMetrics(ctypes.Structure):
    _fields_ = [(name, ctypes.c_long) for name in ('width', 'height', 'horiBearingX', 'horiBearingY',
                                                    'horiAdvance', 'vertBearingX', 'vertBearingY', 'vertAdvance')]


class _Bitmap(ctypes.Structure):
    _fields_ = [('rows', ctypes.c_uint), ('width', ctypes.c_uint), ('pitch', ctypes.c_int),
                ('buffer', ctypes.POINTER(ctypes.c_ubyte)), ('num_grays', ctypes.c_ushort),
                ('pixel_mode', ctypes.c_ubyte), ('palette_mode', ctypes.c_ubyte), ('palette', ctypes.c_void_p)]


class _GlyphSlot(ctypes.Structure):
    _fields_ = [('library', ctypes.c_void_p), ('face', ctypes.c_void_p), ('next', ctypes.c_void_p),
                ('glyph_index', ctypes.c_uint), ('generic', _Generic), ('metrics', _GlyphMetrics),
                ('linearHoriAdvance', ctypes.c_long), ('linearVertAdvance', ctypes.c_long),
                ('advance', _Vector), ('format', ctypes.c_uint), ('bitmap', _Bitmap),
                ('bitmap_left', ctypes.c_int), ('bitmap_top', ctypes.c_int)]


class _Face(ctypes.Structure):
    _fields_ = [('num_faces', ctypes.c_long), ('face_index', ctypes.c_long), ('face_flags', ctypes.c_long),
                ('style_flags', ctypes.c_long), ('num_glyphs', ctypes.c_long), ('family_name', ctypes.c_char_p),
                ('style_name', ctypes.c_char_p), ('num_fixed_sizes', ctypes.c_int),
                ('available_sizes', ctypes.c_void_p), ('num_charmaps', ctypes.c_int), ('charmaps', ctypes.c_void_p),
                ('generic', _Generic), ('bbox', _BBox), ('units_per_EM', ctypes.c_ushort),
                ('ascender', ctypes.c_short), ('descender', ctypes.c_short), ('height', ctypes.c_short),
                ('max_advance_width', ctypes.c_short), ('max_advance_height', ctypes.c_short),
                ('underline_position', ctypes.c_short), ('underline_thickness', ctypes.c_short),
                ('glyph', ctypes.POINTER(_GlyphSlot))]


class _CtypesFace:
    """One face through the FreeType library."""

    _library_handle = None
    _library = None

    @classmethod
    def _load_library(cls):
        if cls._library is not None:
            return
        name = ctypes.util.find_library('freetype')
        if name is None:
            raise FreeTypeMissing('the FreeType library is not installed (freetype2)')
        cls._library_handle = ctypes.CDLL(name)
        library = ctypes.c_void_p()
        if cls._library_handle.FT_Init_FreeType(ctypes.byref(library)) != 0:
            raise FreeTypeMissing('FreeType did not start')
        cls._library = library
        handle = cls._library_handle
        handle.FT_New_Memory_Face.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_long, ctypes.c_long,
                                              ctypes.POINTER(ctypes.POINTER(_Face))]
        handle.FT_Set_Pixel_Sizes.argtypes = [ctypes.POINTER(_Face), ctypes.c_uint, ctypes.c_uint]
        handle.FT_Load_Glyph.argtypes = [ctypes.POINTER(_Face), ctypes.c_uint, ctypes.c_int32]
        handle.FT_Get_Char_Index.argtypes = [ctypes.POINTER(_Face), ctypes.c_ulong]
        handle.FT_Get_Char_Index.restype = ctypes.c_uint
        handle.FT_Get_Kerning.argtypes = [ctypes.POINTER(_Face), ctypes.c_uint, ctypes.c_uint, ctypes.c_uint,
                                          ctypes.POINTER(_Vector)]
        handle.FT_Set_Transform.argtypes = [ctypes.POINTER(_Face), ctypes.c_void_p, ctypes.POINTER(_Vector)]
        handle.FT_Set_Transform.restype = None
        handle.FT_Get_Advance.argtypes = [ctypes.POINTER(_Face), ctypes.c_uint, ctypes.c_int32,
                                          ctypes.POINTER(ctypes.c_long)]

    def __init__(self, data):
        self._load_library()
        self._data = ctypes.create_string_buffer(data, len(data))
        self._face = ctypes.POINTER(_Face)()
        if self._library_handle.FT_New_Memory_Face(self._library, self._data, len(data), 0,
                                                   ctypes.byref(self._face)) != 0:
            raise ValueError('FreeType refuses the font')

    def units_per_em(self):
        return self._face.contents.units_per_EM

    def glyph_count(self):
        return self._face.contents.num_glyphs

    def char_index(self, code_point):
        return self._library_handle.FT_Get_Char_Index(self._face, code_point)

    def advance_units(self, glyph):
        advance = ctypes.c_long()
        self._library_handle.FT_Get_Advance(self._face, glyph, LOAD_NO_SCALE, ctypes.byref(advance))
        return advance.value

    def kerning(self, left, right):
        vector = _Vector()
        self._library_handle.FT_Get_Kerning(self._face, left, right, KERNING_UNSCALED, ctypes.byref(vector))
        return vector.x

    def render(self, glyph, pixel_size, offset_64=0):
        """The unhinted glyph at pixel_size, the pen offset_64 sixty-fourths of a pixel right:
        (left, top below the baseline, width, height, coverage bytes, linear advance in pixels)."""
        handle = self._library_handle
        handle.FT_Set_Pixel_Sizes(self._face, 0, pixel_size)
        delta = _Vector(offset_64, 0)
        handle.FT_Set_Transform(self._face, None, ctypes.byref(delta))
        if handle.FT_Load_Glyph(self._face, glyph, LOAD_NO_HINTING | LOAD_RENDER | LOAD_NO_BITMAP) != 0:
            raise ValueError('FreeType cannot load glyph %d' % glyph)
        slot = self._face.contents.glyph.contents
        bitmap = slot.bitmap
        rows = []
        for row in range(bitmap.rows):
            start = row * bitmap.pitch
            rows.append(bytes(bitmap.buffer[start:start + bitmap.width]))
        return (slot.bitmap_left, -slot.bitmap_top, bitmap.width, bitmap.rows, b''.join(rows),
                slot.linearHoriAdvance / 65536.0)


class _FreetypePyFace:
    """One face through freetype-py."""

    def __init__(self, data):
        import io
        self._face = _freetype_py.Face(io.BytesIO(data))

    def units_per_em(self):
        return self._face.units_per_EM

    def glyph_count(self):
        return self._face.num_glyphs

    def char_index(self, code_point):
        return self._face.get_char_index(code_point)

    def advance_units(self, glyph):
        return self._face.get_advance(glyph, LOAD_NO_SCALE)

    def kerning(self, left, right):
        return self._face.get_kerning(left, right, KERNING_UNSCALED).x

    def render(self, glyph, pixel_size, offset_64=0):
        self._face.set_pixel_sizes(0, pixel_size)
        self._face.set_transform(_freetype_py.Matrix(65536, 0, 0, 65536), _freetype_py.Vector(offset_64, 0))
        self._face.load_glyph(glyph, LOAD_NO_HINTING | LOAD_RENDER | LOAD_NO_BITMAP)
        slot = self._face.glyph
        bitmap = slot.bitmap
        rows = []
        for row in range(bitmap.rows):
            start = row * bitmap.pitch
            rows.append(bytes(bitmap.buffer[start:start + bitmap.width]))
        return (slot.bitmap_left, -slot.bitmap_top, bitmap.width, bitmap.rows, b''.join(rows),
                slot.linearHoriAdvance / 65536.0)


def open_face(data):
    """A FreeType face for the font in data."""
    if _freetype_py is not None:
        return _FreetypePyFace(data)
    return _CtypesFace(data)
