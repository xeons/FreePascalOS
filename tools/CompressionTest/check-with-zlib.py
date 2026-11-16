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

"""Decompresses what CompressionTest compressed with Python's zlib and
gzip (zlib itself), and compares it with the original:

    python3 tools/CompressionTest/check-with-zlib.py build/tools/compression-samples

For every <name>.data there are <name>.zlib, <name>.gz and <name>.raw.
"""

import gzip
import pathlib
import sys
import zlib


def main():
    directory = pathlib.Path(sys.argv[1])
    checked = 0
    failed = 0
    for original_path in sorted(directory.glob("*.data")):
        original = original_path.read_bytes()
        for suffix, decompress in ((".zlib", zlib.decompress),
                                   (".gz", gzip.decompress),
                                   (".raw", lambda data: zlib.decompress(data, -15))):
            path = original_path.with_suffix(suffix)
            checked += 1
            try:
                if decompress(path.read_bytes()) == original:
                    continue
                print("FAIL %s: decompresses to different data" % path.name)
            except Exception as error:
                print("FAIL %s: %s" % (path.name, error))
            failed += 1
    if checked == 0:
        print("FAIL no samples in %s" % directory)
        return 1
    if failed:
        print("ZLIB CROSS-CHECK FAILED: %d of %d files" % (failed, checked))
        return 1
    print("ZLIB CROSS-CHECK PASSED: zlib decompresses all %d files" % checked)
    return 0


if __name__ == "__main__":
    sys.exit(main())
