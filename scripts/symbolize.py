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

    scripts/symbolize.py PROGRAM LIBRARY_DIRECTORY [OPTION]... ADDRESS...

PROGRAM is the program's file in the build (e.g.
build/amd64/user/app/files/files), LIBRARY_DIRECTORY the build's
libraries (build/amd64/user/lib). Use the build that produced the crash.

Address space layout randomization puts the program and each library at
a different place in every process, so their load bases must come from
the crashed process (the kernel keeps them in the process's module list,
Processes.ImageLoader; the crash report or the debug shell's
"modules ID" command shows them):

    --base NAME=HEX     NAME's load bias (address = link address + bias),
                        as the module list's Base
    --start NAME=HEX    the address NAME's lowest segment page was put at
    --modules FILE      lines naming a module and its bias: the debug
                        shell's "modules ID" output (BASE START-END NAME),
                        or any line with NAME and "base" or "bias"
                        followed by a hexadecimal number

Modules not given that way are placed as the fixed layout of aslr=off
does: the program at 0x400000, its libraries one after another from
0x7F0000000000, depth first in DT_NEEDED order, each a page after the
last.
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


HEX = r'(?:0x|\$)?([0-9A-Fa-f]+)'


def parse_number(text):
    return int(text.lstrip('$').replace('0x', '').replace('0X', ''), 16)


def read_module_file(path, names, biases, starts):
    """Biases (or starts) of the modules named in the lines of a file."""
    with open(path, encoding='utf-8', errors='replace') as source:
        for line in source:
            words = line.split()
            named = [word.strip('():,"\'') for word in words]
            for name in names:
                if name not in named:
                    continue
                labelled = re.search(r'(?:base|bias)\s*[=:]?\s*' + HEX, line, re.IGNORECASE)
                if labelled:
                    biases[name] = int(labelled.group(1), 16)
                    continue
                # The debug shell: BASE START-END NAME.
                shell = re.match(r'\s*([0-9A-Fa-f]+)\s+([0-9A-Fa-f]+)-([0-9A-Fa-f]+)\s+(\S+)\s*$', line)
                if shell and shell.group(4) == name:
                    biases[name] = int(shell.group(1), 16)


def main():
    arguments = sys.argv[1:]
    if len(arguments) < 3:
        print(__doc__)
        sys.exit(2)
    program, library_directory = arguments[0], arguments[1]
    biases, starts, module_files, addresses = {}, {}, [], []
    index = 2
    while index < len(arguments):
        argument = arguments[index]
        if argument in ('--base', '--start', '--modules') and index + 1 < len(arguments):
            value = arguments[index + 1]
            index += 2
            if argument == '--modules':
                module_files.append(value)
            else:
                name, _, number = value.partition('=')
                (biases if argument == '--base' else starts)[name] = parse_number(number)
            continue
        addresses.append(argument)
        index += 1

    images = lay_out(program, library_directory)
    names = [image[0] for image in images]
    for path in module_files:
        read_module_file(path, names, biases, starts)
    placed = []
    for name, path, bias, start, end in images:
        low = start - bias
        if name in biases:
            bias = biases[name]
        elif name in starts:
            bias = starts[name] - low
        placed.append((name, path, bias, low + bias, end - start + low + bias))
    images = placed

    for name, _path, _bias, start, end in images:
        print('%-22s %x-%x' % (name, start, end))
    for text in addresses:
        address = parse_number(text)
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
