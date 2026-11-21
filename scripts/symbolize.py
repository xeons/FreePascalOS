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
Names the addresses of a user program's crash report.

From a report (the usual way):

    scripts/symbolize.py --report REPORT DIRECTORY...

REPORT is a file holding the report (or - for standard input): the
runtime's ("An unhandled exception occurred at $...", "Runtime error
216 at $...", then one address per line, each with its module and
offset, and the "Modules:" list after it, rtl/fpc/syscrash.inc), or the
kernel's for a program it had to end ("[process] coretest (12): page
fault at 0x... (coretest+0x7AB6) ..." and "[process]   module NAME at
0xBASE-0xLIMIT" lines, Processes.LoadedModules), or a whole serial log
holding one. The modules' load addresses come from the report, so it
does not matter where they were loaded. Each module's file is looked
for by its name under the DIRECTORY arguments (e.g. build/amd64/user);
use the build that produced the crash.

At the fixed addresses of a system without load address randomization
(for an old report without module information):

    scripts/symbolize.py PROGRAM LIBRARY_DIRECTORY ADDRESS...

PROGRAM is the program's file in the build (e.g.
build/amd64/user/app/files/files), LIBRARY_DIRECTORY the build's
libraries (build/amd64/user/lib). Modules are placed as the fixed
layout of aslr=off does: the program at 0x400000, its libraries one
after another from 0x7F0000000000, depth first in DT_NEEDED order, each
a page after the last (Processes.ImageLoader). A rebuilt library moves
everything after it. Under address space layout randomization give the
crashed process's load bases (the kernel keeps them in its module list;
the debug shell's "modules ID" command shows them):

    --base NAME=HEX     NAME's load bias (address = link address + bias)
    --start NAME=HEX    the address NAME's lowest segment page was put at
    --modules FILE      lines naming a module and its bias: the debug
                        shell's "modules ID" output (BASE START-END NAME),
                        or any line with NAME and "base" or "bias"
                        followed by a hexadecimal number
"""

import importlib.util
import os
import re
import subprocess
import sys


def load_kernel_symbols_script():
    sys.dont_write_bytecode = True
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'make-kernel-symbols.py')
    specification = importlib.util.spec_from_file_location('make_kernel_symbols', path)
    module = importlib.util.module_from_spec(specification)
    specification.loader.exec_module(module)
    return module


KERNEL_SYMBOLS = load_kernel_symbols_script()

PAGE_SIZE = 4096
PROGRAM_BASE = 0x400000
FIRST_LIBRARY_BASE = 0x7F0000000000

RUNTIME_MODULE_LINE = re.compile(r'^\s*\$([0-9A-Fa-f]+)-\$([0-9A-Fa-f]+) (\S+)\s*$')
KERNEL_MODULE_LINE = re.compile(r'module (\S+) at 0x([0-9A-Fa-f]+)-0x([0-9A-Fa-f]+)')
TRACE_LINE = re.compile(r'^\s*\$([0-9A-Fa-f]+)(?:\s+(\S+)\+\$([0-9A-Fa-f]+))?\s*$')
RUNTIME_HEADER = re.compile(r'(?:An unhandled exception occurred|Runtime error \d+) at \$')
KERNEL_FAULT_LINE = re.compile(r'\[process\] \S+ \(\d+\): .*? at 0x([0-9A-Fa-f]+)(?: \((\S+)\+0x([0-9A-Fa-f]+)\))?')
TERMINAL_CODES = re.compile(r'\x1b\[[0-9;]*[a-zA-Z]')


# --- Fixed addresses ---------------------------------------------------------

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


def read_module_file(path, names, biases):
    """Biases of the modules named in the lines of a file."""
    with open(path, encoding='utf-8', errors='replace') as source:
        for line in source:
            named = [word.strip('():,"\'') for word in line.split()]
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


def symbolize_fixed(program, library_directory, arguments):
    biases, starts, module_files, texts = {}, {}, [], []
    index = 0
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
        texts.append(argument)
        index += 1
    images = lay_out(program, library_directory)
    names = [image[0] for image in images]
    for path in module_files:
        read_module_file(path, names, biases)
    placed = []
    for name, path, bias, start, end in images:
        low = start - bias
        if name in biases:
            bias = biases[name]
        elif name in starts:
            bias = starts[name] - low
        placed.append((name, path, bias, low + bias, end - start + low + bias))
    for name, _path, _bias, start, end in placed:
        print('%-22s %x-%x' % (name, start, end))
    for text in texts:
        address = parse_number(text)
        for name, path, bias, start, end in placed:
            if start <= address < end:
                print('%x %s+%x %s' % (address, name, address - bias, describe(path, address - bias)))
                break
        else:
            print('%x ?' % address)


# --- From a report -----------------------------------------------------------

def readable_name(symbol):
    """Free Pascal's "P$CORETEST_$$_CRASHONPURPOSE" as
    "CORETEST.CRASHONPURPOSE" (make-kernel-symbols.py's demangler)."""
    if '_$$_' not in symbol:
        return symbol
    unit, routine = KERNEL_SYMBOLS.demangle(symbol)
    if unit.startswith('P$'):
        unit = unit[2:]
    return '%s.%s' % (unit, routine)


def describe(path, offset):
    """'Routine file:line' for an offset into a module's file."""
    lines = subprocess.run(['addr2line', '-f', '-C', '-e', path, hex(offset)],
                           capture_output=True, text=True).stdout.split('\n')
    routine = readable_name(lines[0]) if lines and lines[0] else '??'
    where = lines[1].split('/')[-1] if len(lines) > 1 else ''
    return '%s %s' % (routine, where)


def is_elf(path):
    try:
        with open(path, 'rb') as candidate:
            return candidate.read(4) == b'\x7fELF'
    except OSError:
        return False


def find_module_file(name, directories, cache):
    if name not in cache:
        cache[name] = None
        for directory in directories:
            for root, _subdirectories, files in os.walk(directory):
                if name in files and is_elf(os.path.join(root, name)):
                    cache[name] = os.path.join(root, name)
                    break
            if cache[name]:
                break
    return cache[name]


def parse_reports(text):
    """The reports in the text, each as (modules, addresses): the modules
    as {name: (base, limit)}, the addresses in order, each as (address,
    module or None, offset or None). A report starts at its first line
    (the runtime's, or the kernel's fault line), so a log with several
    processes' reports keeps each one's modules apart."""
    reports = []

    def start_report():
        reports.append(({}, []))

    for raw_line in text.splitlines():
        line = TERMINAL_CODES.sub('', raw_line).rstrip('\r')
        if RUNTIME_HEADER.search(line):
            start_report()
            continue
        fault = KERNEL_FAULT_LINE.search(line)
        if fault:
            start_report()
        if not reports:
            continue
        modules, addresses = reports[-1]
        match = RUNTIME_MODULE_LINE.match(line)
        if match:
            modules[match.group(3)] = (int(match.group(1), 16), int(match.group(2), 16))
            continue
        match = KERNEL_MODULE_LINE.search(line)
        if match:
            modules[match.group(1)] = (int(match.group(2), 16), int(match.group(3), 16))
            continue
        match = fault or TRACE_LINE.match(line)
        if match:
            module = match.group(2)
            offset = int(match.group(3), 16) if match.group(3) else None
            addresses.append((int(match.group(1), 16), module, offset))
    return reports


def locate(address, module, offset, modules):
    """The module and offset of an address: from the module list, else
    from the address's own annotation."""
    for name, (base, limit) in modules.items():
        if base <= address < limit:
            return name, address - base
    if module is not None and offset is not None:
        return module, offset
    return None, None


def symbolize_report(report_path, directories):
    if report_path == '-':
        text = sys.stdin.read()
    else:
        with open(report_path, 'rb') as report:
            text = report.read().decode('utf-8', 'replace')
    cache = {}
    reports = parse_reports(text)
    for number, (modules, addresses) in enumerate(reports):
        if len(reports) > 1:
            print('%sreport %d:' % ('\n' if number > 0 else '', number + 1))
        for name, (base, limit) in modules.items():
            print('%-22s %x-%x' % (name, base, limit))
        for address, module, offset in addresses:
            name, offset = locate(address, module, offset, modules)
            if name is None:
                print('%x ?' % address)
                continue
            path = find_module_file(name, directories, cache)
            if path is None:
                print('%x %s+%x (no file named %s found)' % (address, name, offset, name))
                continue
            print('%x %s+%x %s' % (address, name, offset, describe(path, offset)))


def main():
    if len(sys.argv) >= 4 and sys.argv[1] == '--report':
        symbolize_report(sys.argv[2], sys.argv[3:])
    elif len(sys.argv) >= 4:
        symbolize_fixed(sys.argv[1], sys.argv[2], sys.argv[3:])
    else:
        print(__doc__)
        sys.exit(2)


if __name__ == '__main__':
    main()
