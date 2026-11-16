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
For every <name>.dictdata there is its dictionary (<name>.dict) and the
data compressed with it as zlib (<name>.zdict) and raw (<name>.rdict);
for every <name>.flushdata, zlib data with flushes (<name>.zflush) and
where they are (<name>.points: compressed length, input length, 1 for a
full flush): what zlib gives from the data up to each flush must be all
the input before it, and after a full flush the rest must decompress on
its own.
"""

import gzip
import pathlib
import sys
import zlib


def check_dictionaries(directory):
    checked = 0
    failed = 0
    for original_path in sorted(directory.glob("*.dictdata")):
        original = original_path.read_bytes()
        dictionary = original_path.with_suffix(".dict").read_bytes()
        for suffix, wbits in ((".zdict", 15), (".rdict", -15)):
            path = original_path.with_suffix(suffix)
            checked += 1
            try:
                decompressor = zlib.decompressobj(wbits, zdict=dictionary)
                if decompressor.decompress(path.read_bytes()) + decompressor.flush() == original:
                    continue
                print("FAIL %s: decompresses to different data" % path.name)
            except Exception as error:
                print("FAIL %s: %s" % (path.name, error))
            failed += 1
    return checked, failed


def check_flushes(directory):
    checked = 0
    failed = 0
    for original_path in sorted(directory.glob("*.flushdata")):
        original = original_path.read_bytes()
        path = original_path.with_suffix(".zflush")
        compressed = path.read_bytes()
        points = [tuple(int(field) for field in line.split())
                  for line in original_path.with_suffix(".points").read_text().splitlines() if line]
        checked += 1
        try:
            decompressor = zlib.decompressobj()
            output = b""
            start = 0
            problem = None
            for compressed_length, input_length, full in points:
                output += decompressor.decompress(compressed[start:compressed_length])
                start = compressed_length
                if output != original[:input_length]:
                    problem = "not all the input before the flush at %d comes out" % compressed_length
                    break
                if full:
                    rest = zlib.decompress(compressed[compressed_length:-4], -15)
                    if rest != original[input_length:]:
                        problem = "does not decompress on its own after the full flush at %d" % compressed_length
                        break
            if problem is None:
                output += decompressor.decompress(compressed[start:]) + decompressor.flush()
                if output != original or not decompressor.eof:
                    problem = "decompresses to different data"
            if problem is None:
                continue
            print("FAIL %s: %s" % (path.name, problem))
        except Exception as error:
            print("FAIL %s: %s" % (path.name, error))
        failed += 1
    return checked, failed


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
    for check in (check_dictionaries, check_flushes):
        more_checked, more_failed = check(directory)
        checked += more_checked
        failed += more_failed
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
