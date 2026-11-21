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
The kernel's symbol table: the names of its routines, so a panic's back
trace (Debug.StackTrace) can say "Kernel.Panic.KernelAssert+0x2C"
instead of an address.

The kernel is linked twice (see the Makefile). The first link carries an
empty table; this script reads that image's code symbols with nm and
writes an assembly file holding the table, which the second link puts
at the end of the read-only data. The code comes before the read-only
data, so it does not move between the links; --verify checks that.

    make-kernel-symbols.py --empty OUTPUT.s
    make-kernel-symbols.py --nm NM [--source DIRECTORY]... KERNEL.elf OUTPUT.s
    make-kernel-symbols.py --nm NM --verify FIRST.elf SECOND.elf

The table (Debug.KernelSymbols reads it; little endian):

    header   Magic 'KSYM', Version 1, Count, EntriesOffset, NamesOffset,
             NamesSize, TextEndOffset (LongWords), Reserved (LongWord),
             TextBase (QWord): 40 bytes
    entries  Count times (AddressOffset, UnitNameOffset,
             RoutineNameOffset), LongWords, sorted by address;
             addresses are offsets from TextBase, names offsets into the
             names (UnitNameOffset NoUnit for routines outside any unit)
    names    zero-ended strings, each unit name once

Free Pascal's names are decorated and upper case
("KERNEL.PANIC_$$_KERNELASSERT$BOOLEAN$PCHAR"); the table holds them as
written in the sources ("Kernel.Panic", "KernelAssert"), the case taken
from the declarations found in the --source directories. Nested
routines are named Outer.Inner, methods Type.Method.
"""

import argparse
import os
import re
import struct
import subprocess
import sys

MAGIC = 0x4D59534B  # 'KSYM'
VERSION = 1
HEADER_FORMAT = '<8IQ'
HEADER_SIZE = struct.calcsize(HEADER_FORMAT)
ENTRY_FORMAT = '<3I'
NO_UNIT = 0xFFFFFFFF
TABLE_SYMBOL = 'KernelSymbolTable'
SECTION = '.rodata.kernelsymbols'
IMAGE_START_SYMBOL = 'KernelImageStart'
TEXT_END_SYMBOL = 'KernelTextEnd'

DECLARATION = re.compile(
    r'^\s*(?:class\s+)?(?:unit|program|procedure|function|constructor|destructor|operator)\s+'
    r'([A-Za-z_][A-Za-z0-9_.]*)', re.IGNORECASE | re.MULTILINE)
TYPE_DECLARATION = re.compile(
    r'^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(?:packed\s+)?(?:record|object|class)\b',
    re.IGNORECASE | re.MULTILINE)


def read_text_symbols(nm, image):
    """The image's code symbols as (address, name)."""
    output = subprocess.run([nm, image], capture_output=True, text=True, check=True).stdout
    symbols = []
    for line in output.splitlines():
        fields = line.split()
        if len(fields) == 3 and fields[1] in ('T', 't', 'W', 'w'):
            symbols.append((int(fields[0], 16), fields[2]))
    return symbols


def find_symbol(nm, image, wanted):
    output = subprocess.run([nm, image], capture_output=True, text=True, check=True).stdout
    for line in output.splitlines():
        fields = line.split()
        if len(fields) == 3 and fields[2] == wanted:
            return int(fields[0], 16)
    sys.exit('make-kernel-symbols: %s has no symbol %s' % (image, wanted))


def collect_spellings(directories):
    """Upper case identifier -> its spelling in the declarations."""
    spellings = {}
    for directory in directories:
        if not os.path.isdir(directory):
            continue
        for name in sorted(os.listdir(directory)):
            if not name.lower().endswith(('.pas', '.pp', '.inc')):
                continue
            with open(os.path.join(directory, name), encoding='utf-8', errors='replace') as source:
                text = source.read()
            for match in DECLARATION.finditer(text):
                whole = match.group(1)
                spellings.setdefault(whole.upper(), whole)
                for part in whole.split('.'):
                    spellings.setdefault(part.upper(), part)
            for match in TYPE_DECLARATION.finditer(text):
                spellings.setdefault(match.group(1).upper(), match.group(1))
    return spellings


def plain_name(piece):
    """A decorated piece without its parameter list ("$PCHAR$$BOOLEAN")."""
    name = piece.split('$', 1)[0]
    return name.rstrip('_') or name


def demangle(symbol):
    """(unit, routine) of a Free Pascal symbol; unit None for other names."""
    for prefix, what in (('INIT$_$', 'initialization'), ('FINALIZE$_$', 'finalization')):
        if symbol.startswith(prefix):
            return symbol[len(prefix):], what
    if '_$$_' not in symbol:
        return None, symbol
    parts = symbol.split('_$$_')
    head = parts[0].split('$_$')
    unit = head[0]
    routine = [plain_name(piece) for piece in head[1:]]
    for part in parts[1:]:
        routine.extend(plain_name(piece) for piece in part.split('$_$'))
    return unit, '.'.join(name for name in routine if name)


def spell(name, spellings):
    if name is None:
        return None
    whole = spellings.get(name.upper())
    if whole:
        return whole
    return '.'.join(spellings.get(part.upper(), part) for part in name.split('.'))


def choose_names(symbols):
    """One name per address, preferring a decorated Pascal name."""
    chosen = {}
    for address, name in symbols:
        if name in (IMAGE_START_SYMBOL, TEXT_END_SYMBOL) or name.startswith('.'):
            continue
        current = chosen.get(address)
        if current is None:
            chosen[address] = name
        elif ('_$$_' in name) and ('_$$_' not in current):
            chosen[address] = name
        elif (('_$$_' in name) == ('_$$_' in current)) and name < current:
            chosen[address] = name
    return sorted(chosen.items())


def build_table(symbols, spellings, text_base, text_end):
    names = bytearray()
    offsets = {}

    def intern(text):
        if text not in offsets:
            offsets[text] = len(names)
            names.extend(text.encode('ascii', 'replace') + b'\0')
        return offsets[text]

    entries = bytearray()
    count = 0
    for address, symbol in symbols:
        if not (text_base <= address < text_end):
            continue
        unit, routine = demangle(symbol)
        unit = spell(unit, spellings)
        routine = spell(routine, spellings)
        unit_offset = NO_UNIT if unit is None else intern(unit)
        entries.extend(struct.pack(ENTRY_FORMAT, address - text_base, unit_offset, intern(routine)))
        count += 1

    entries_offset = HEADER_SIZE
    names_offset = entries_offset + len(entries)
    header = struct.pack(HEADER_FORMAT, MAGIC, VERSION, count, entries_offset, names_offset,
                         len(names), text_end - text_base, 0, text_base)
    return header + bytes(entries) + bytes(names)


def write_assembly(path, table):
    lines = [
        '// The kernel symbol table, written by scripts/make-kernel-symbols.py.',
        '    .section %s,"a"' % SECTION,
        '    .balign 8',
        '    .global %s' % TABLE_SYMBOL,
        '%s:' % TABLE_SYMBOL,
    ]
    for start in range(0, len(table), 32):
        chunk = table[start:start + 32]
        lines.append('    .byte ' + ','.join(str(byte) for byte in chunk))
    with open(path, 'w') as output:
        output.write('\n'.join(lines) + '\n')


def empty_table():
    return struct.pack(HEADER_FORMAT, MAGIC, VERSION, 0, HEADER_SIZE, HEADER_SIZE, 0, 0, 0, 0)


def verify(nm, first, second):
    """The code symbols must not have moved between the links."""
    before = dict((name, address) for address, name in read_text_symbols(nm, first))
    after = dict((name, address) for address, name in read_text_symbols(nm, second))
    moved = [name for name in before if after.get(name) != before[name]]
    if moved:
        sys.exit('make-kernel-symbols: the code moved between the links (%s, ...)' % moved[0])


def main():
    parser = argparse.ArgumentParser(description='Writes the kernel symbol table.')
    parser.add_argument('--nm', default='nm')
    parser.add_argument('--empty', action='store_true', help='write an empty table')
    parser.add_argument('--verify', action='store_true', help='compare two links')
    parser.add_argument('--source', action='append', default=[], help='a directory of the kernel sources')
    parser.add_argument('files', nargs='+')
    arguments = parser.parse_args()

    if arguments.empty:
        write_assembly(arguments.files[0], empty_table())
        return
    if arguments.verify:
        verify(arguments.nm, arguments.files[0], arguments.files[1])
        return
    image, output = arguments.files
    text_base = find_symbol(arguments.nm, image, IMAGE_START_SYMBOL)
    text_end = find_symbol(arguments.nm, image, TEXT_END_SYMBOL)
    symbols = choose_names(read_text_symbols(arguments.nm, image))
    table = build_table(symbols, collect_spellings(arguments.source), text_base, text_end)
    write_assembly(output, table)


if __name__ == '__main__':
    main()
