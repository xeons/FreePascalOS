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

"""
Names the addresses of a user program's crash report ("An unhandled
exception occurred at $...", then one address per line).

    scripts/symbolize.py PROGRAM LIBRARY_DIRECTORY ADDRESS...

PROGRAM is the program's file in the build (e.g.
build/amd64/user/app/files/files), LIBRARY_DIRECTORY the build's
libraries (build/amd64/user/lib). The program is linked at 0x400000;
its libraries load one after another from 0x7F0000000000, depth first
in DT_NEEDED order, each a page after the last (Processes.ImageLoader),
which this repeats. Use the build that produced the crash: a rebuilt
library moves everything after it.
"""

import re
import subprocess
import sys

PAGE_SIZE = 4096
PROGRAM_BASE = 0x400000
FIRST_LIBRARY_BASE = 0x7F0000000000


def needed_libraries(path):
    dynamic = subprocess.run(['readelf', '-d', path], capture_output=True, text=True).stdout
    return re.findall(r'Shared library: \[(.*?)\]', dynamic)


def loaded_span(path):
    """The page-aligned span of the image's LOAD segments."""
    headers = subprocess.run(['readelf', '-lW', path], capture_output=True, text=True).stdout
    low, high = None, 0
    for line in headers.splitlines():
        fields = line.split()
        if fields and fields[0] == 'LOAD':
            address, memory_size = int(fields[2], 16), int(fields[5], 16)
            start = address & ~(PAGE_SIZE - 1)
            end = (address + memory_size + PAGE_SIZE - 1) & ~(PAGE_SIZE - 1)
            low = start if low is None else min(low, start)
            high = max(high, end)
    return low, high


def lay_out(program, library_directory):
    """Each image as (name, path, bias, start, end), in load order."""
    images = []
    loaded = set()
    next_base = FIRST_LIBRARY_BASE

    def load(path, is_program):
        nonlocal next_base
        name = path.split('/')[-1]
        low, high = loaded_span(path)
        if is_program:
            bias = PROGRAM_BASE - low
        else:
            bias = next_base - low
            next_base += (high - low) + PAGE_SIZE
        images.append((name, path, bias, low + bias, high + bias))
        loaded.add(name)
        for library in needed_libraries(path):
            if library not in loaded:
                load(library_directory + '/' + library, False)

    load(program, True)
    return images


def main():
    if len(sys.argv) < 4:
        print(__doc__)
        sys.exit(2)
    images = lay_out(sys.argv[1], sys.argv[2])
    for name, _path, _bias, start, end in images:
        print('%-22s %x-%x' % (name, start, end))
    for text in sys.argv[3:]:
        address = int(text.lstrip('$'), 16)
        for name, path, bias, start, end in images:
            if start <= address < end:
                lines = subprocess.run(['addr2line', '-f', '-C', '-e', path, hex(address - bias)],
                                       capture_output=True, text=True).stdout.split('\n')
                where = lines[1].split('/')[-1] if len(lines) > 1 else ''
                print('%x %s+%x %s %s' % (address, name, address - bias, lines[0], where))
                break
        else:
            print('%x ?' % address)


if __name__ == '__main__':
    main()
