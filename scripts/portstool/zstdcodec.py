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

"""Zstandard for packages: Python's compression.zstd (3.14 and later),
else the zstd program, so an older Python on the build machine works
too (packages are then the same only between builds with the same one)."""

import shutil
import subprocess

try:
    from compression import zstd as _zstd
except ImportError:  # Python before 3.14
    _zstd = None


class ZstdError(Exception):
    pass


def _program():
    path = shutil.which("zstd")
    if path is None:
        raise ZstdError("Zstandard needs Python 3.14 or the zstd program")
    return path


def compress(data, level=3):
    if _zstd is not None:
        return _zstd.compress(data, level=level)
    result = subprocess.run([_program(), "-q", "-c", f"-{level}"], input=data, stdout=subprocess.PIPE)
    if result.returncode != 0:
        raise ZstdError("zstd could not compress")
    return result.stdout


def decompress(data):
    if _zstd is not None:
        try:
            return _zstd.decompress(data)
        except _zstd.ZstdError as error:
            raise ZstdError(str(error)) from None
    result = subprocess.run([_program(), "-q", "-d", "-c"], input=data, stdout=subprocess.PIPE,
                            stderr=subprocess.DEVNULL)
    if result.returncode != 0:
        raise ZstdError("not Zstandard data")
    return result.stdout
