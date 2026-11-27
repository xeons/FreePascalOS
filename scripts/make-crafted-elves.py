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
Writes the crafted ELF files of loadertest (userland/tests/loadertest.pas):
programs and libraries that try to make the kernel's loader reach kernel
memory, pages other processes share, or past its own buffers, and two
good ones that show the files are otherwise well formed.

    make-crafted-elves.py <amd64|arm64> <output-directory>

Every file is a small ELF64 object made from scratch: a read-only page
(headers, code) and a read-write page (dynamic section, symbols, hash
table, strings, relocations, data), with one thing wrong in each bad one.
The addresses below are shared with loadertest.pas (the fixed places of
the ET_EXEC files, the kernel address aimed at).
"""

import os
import struct
import sys

PAGE = 0x1000

# Shared with loadertest.pas.
KERNEL_ADDRESS = 0xFFFF800000100000
GAP_LIBRARY_BASE = 0x00005A5A00000000          # reloc-gap-library: two pages of gap
PROVIDER_LIBRARY_BASE = 0x00005A5A10000000     # copy-provider-library
KERNEL_RELOCATION_LIBRARY_BASE = 0x00005A5A20000000
INIT_ARRAY_LIBRARY_BASE = 0x00005A5A30000000
FIXED_PROGRAM_BASE = 0x00005A5B00000000
GOOD_PROGRAM_EXIT_CODE = 42

PT_LOAD, PT_DYNAMIC, PT_TLS = 1, 2, 7
PF_X, PF_W, PF_R = 1, 2, 4
ET_EXEC, ET_DYN = 2, 3
DT_NULL, DT_NEEDED, DT_HASH, DT_STRTAB, DT_SYMTAB = 0, 1, 4, 5, 6
DT_RELA, DT_RELASZ, DT_RELAENT, DT_STRSZ, DT_SYMENT = 7, 8, 9, 10, 11
DT_INIT_ARRAY, DT_INIT_ARRAYSZ = 25, 27

ARCHITECTURES = {
    'amd64': {
        'machine': 62,
        'relative': 8, 'absolute': 1, 'copy': 5,
        # mov edi, 42; xor eax, eax (CallExit); syscall; jmp .
        'exit_code': bytes([0xBF, GOOD_PROGRAM_EXIT_CODE, 0, 0, 0, 0x31, 0xC0, 0x0F, 0x05, 0xEB, 0xFE]),
    },
    'arm64': {
        'machine': 183,
        'relative': 1027, 'absolute': 257, 'copy': 1024,
        # mov x0, #42; mov x8, #0 (CallExit); svc #0; b .
        'exit_code': struct.pack('<4I', 0xD2800000 | (GOOD_PROGRAM_EXIT_CODE << 5), 0xD2800008, 0xD4000001,
                                 0x14000000),
    },
}


class Image:
    """One ELF file: page 0 read-only (headers, code), page 1 read-write
    (the dynamic section and its tables, then data), at link address
    Base (0 for a shared object)."""

    def __init__(self, arch, file_type, base=0):
        self.arch = ARCHITECTURES[arch]
        self.file_type = file_type
        self.base = base
        self.code = b''
        self.entry_offset = 0x800
        self.symbols = []         # (name, value, size, defined)
        self.relocations = []     # (offset, type, symbol index, addend)
        self.needed = []
        self.data = bytearray()   # after the tables in page 1
        self.extra_dynamic = []   # (tag, value)
        self.relasz_override = None
        self.strings_terminated = True
        self.unterminated_tail = b''
        self.tls = None           # (virtual address, file size, memory size)
        self.segments = None      # custom PT_LOAD list: (offset, vaddr, filesz, memsz, flags)
        self.data_page_address = None  # where page 1 is linked (default base + PAGE)

    def page1_address(self):
        if self.data_page_address is not None:
            return self.data_page_address
        return self.base + PAGE

    def add_symbol(self, name, value, size=8, defined=True):
        self.symbols.append((name, value, size, defined))
        return len(self.symbols)  # its index (0 is the null symbol)

    def data_address(self, offset):
        """The link address of byte Offset of the data area. The tables
        come first, so every symbol and relocation must be there (their
        values may change later) before this is asked."""
        self.layout()
        return self.page1_address() + self.data_start + offset

    def layout(self):
        """Lays out page 1: dynamic section, hash, symbols, strings,
        relocations, data. Returns the page's bytes."""
        strings = bytearray(b'\0')
        name_offsets = []
        for name, _, _, _ in self.symbols:
            name_offsets.append(len(strings))
            strings += name.encode() + b'\0'
        needed_offsets = []
        for name in self.needed:
            needed_offsets.append(len(strings))
            strings += name.encode() + b'\0'
        if not self.strings_terminated:
            needed_offsets.append(len(strings))
            strings += self.unterminated_tail

        symbol_count = len(self.symbols) + 1
        symtab = bytearray(24)
        for (name, value, size, defined), name_offset in zip(self.symbols, name_offsets):
            info = (1 << 4) | 1  # global object
            section = 1 if defined else 0
            symtab += struct.pack('<IBBHQQ', name_offset, info, 0, section, value, size)
        buckets = [1 if symbol_count > 1 else 0]
        chains = [0] + [index + 1 if index + 1 < symbol_count else 0 for index in range(1, symbol_count)]
        hash_table = struct.pack('<II', 1, symbol_count) + struct.pack('<%dI' % len(buckets), *buckets) + \
            struct.pack('<%dI' % len(chains), *chains)

        rela = bytearray()
        for offset, kind, symbol, addend in self.relocations:
            rela += struct.pack('<QQq', offset, (symbol << 32) | kind, addend)

        dynamic_entries = len(needed_offsets) + 8 + len(self.extra_dynamic) + 1
        dynamic_size = dynamic_entries * 16
        position = dynamic_size

        def place(blob, alignment=8):
            nonlocal position
            position = (position + alignment - 1) // alignment * alignment
            start = position
            position += len(blob)
            return start

        hash_start = place(hash_table)
        symtab_start = place(symtab)
        strings_start = place(strings, 1)
        rela_start = place(rela)
        self.data_start = (position + 15) // 16 * 16

        address = self.page1_address()
        relasz = self.relasz_override if self.relasz_override is not None else len(rela)
        dynamic = []
        for offset in needed_offsets:
            dynamic.append((DT_NEEDED, offset))
        dynamic += [(DT_HASH, address + hash_start), (DT_STRTAB, address + strings_start),
                    (DT_SYMTAB, address + symtab_start), (DT_STRSZ, len(strings)), (DT_SYMENT, 24),
                    (DT_RELA, address + rela_start), (DT_RELASZ, relasz), (DT_RELAENT, 24)]
        dynamic += self.extra_dynamic
        dynamic.append((DT_NULL, 0))

        page = bytearray()
        for tag, value in dynamic:
            page += struct.pack('<qQ', tag, value)
        page += bytes(hash_start - len(page)) + hash_table
        page += bytes(symtab_start - len(page)) + symtab
        page += bytes(strings_start - len(page)) + strings
        page += bytes(rela_start - len(page)) + rela
        page += bytes(self.data_start - len(page)) + self.data
        if len(page) > PAGE:
            raise ValueError('page 1 overflows')
        return bytes(page) + bytes(PAGE - len(page)), dynamic_size

    def build(self):
        page1, dynamic_size = self.layout()
        if self.segments is None:
            code_flags = PF_R | (PF_X if self.code else 0)
            segments = [(0, self.base, PAGE, PAGE, code_flags),
                        (PAGE, self.page1_address(), PAGE, PAGE, PF_R | PF_W)]
        else:
            segments = self.segments
        program_headers = []
        for offset, vaddr, filesz, memsz, flags in segments:
            program_headers.append(struct.pack('<IIQQQQQQ', PT_LOAD, flags, offset, vaddr, vaddr, filesz, memsz,
                                               PAGE))
        program_headers.append(struct.pack('<IIQQQQQQ', PT_DYNAMIC, PF_R | PF_W, PAGE, self.page1_address(),
                                           self.page1_address(), dynamic_size, dynamic_size, 8))
        if self.tls is not None:
            vaddr, filesz, memsz = self.tls
            program_headers.append(struct.pack('<IIQQQQQQ', PT_TLS, PF_R, PAGE, vaddr, vaddr, filesz, memsz, 8))
        header = struct.pack('<4sBBBBB7sHHIQQQIHHHHHH', b'\x7fELF', 2, 1, 1, 0, 0, bytes(7),
                             self.file_type, self.arch['machine'], 1, self.base + self.entry_offset, 64, 0, 0,
                             64, 56, len(program_headers), 64, 0, 0)
        page0 = bytearray(PAGE)
        page0[0:len(header)] = header
        phdrs = b''.join(program_headers)
        page0[64:64 + len(phdrs)] = phdrs
        page0[self.entry_offset:self.entry_offset + len(self.code)] = self.code
        return bytes(page0) + page1


def self_pointer(image, arch):
    """A relocated self pointer in the data area: after relocation the
    value is its own address. Returns its link address."""
    image.data += bytes(16)
    image.relocations.append((0, ARCHITECTURES[arch]['relative'], 0, 0))
    value = image.data_address(0)
    image.relocations[-1] = (value, ARCHITECTURES[arch]['relative'], 0, value)
    return value


def good_library(arch):
    image = Image(arch, ET_DYN)
    symbol = image.add_symbol('loadertest_value', 0)
    value = self_pointer(image, arch)
    image.symbols[symbol - 1] = ('loadertest_value', value, 8, True)
    return image.build()


def good_program(arch):
    image = Image(arch, ET_DYN)
    image.code = ARCHITECTURES[arch]['exit_code']
    self_pointer(image, arch)
    return image.build()


def relocation_library(arch, file_type, base, target):
    image = Image(arch, file_type, base)
    image.relocations.append((target, ARCHITECTURES[arch]['relative'], 0, 0x1234))
    return image.build()


def gap_library(arch):
    """Code page at GAP_LIBRARY_BASE, data page three pages up: the two
    pages between belong to nobody, and its relocation aims there."""
    image = Image(arch, ET_EXEC, GAP_LIBRARY_BASE)
    image.data_page_address = GAP_LIBRARY_BASE + 3 * PAGE
    image.relocations.append((GAP_LIBRARY_BASE + PAGE + 8, ARCHITECTURES[arch]['relative'], 0, 0x4142434445464748))
    return image.build()


def copy_provider_library(arch):
    image = Image(arch, ET_EXEC, PROVIDER_LIBRARY_BASE)
    image.add_symbol('loadertest_kernel_symbol', KERNEL_ADDRESS, 64)
    return image.build()


def copy_kernel_library(arch):
    image = Image(arch, ET_DYN)
    image.data += bytes(64)
    symbol = image.add_symbol('loadertest_kernel_symbol', 0, 64, defined=False)
    image.relocations.append((0, ARCHITECTURES[arch]['copy'], symbol, 0))
    image.relocations[-1] = (image.data_address(0), ARCHITECTURES[arch]['copy'], symbol, 0)
    return image.build()


def unterminated_strings_library(arch):
    image = Image(arch, ET_DYN)
    image.strings_terminated = False
    image.unterminated_tail = b'libloadertest-missing'
    return image.build()


def odd_relocation_size(arch, file_type, base):
    image = Image(arch, file_type, base)
    if file_type == ET_DYN and base == 0:
        image.code = ARCHITECTURES[arch]['exit_code']
    image.data += bytes(16)
    image.relocations += [(0, ARCHITECTURES[arch]['relative'], 0, 0)] * 2
    image.relocations[0] = (image.data_address(0), ARCHITECTURES[arch]['relative'], 0, 0)
    image.relocations[1] = (image.data_address(8), ARCHITECTURES[arch]['relative'], 0, 0)
    image.relasz_override = 24 + 5
    return image.build()


def init_array_library(arch):
    image = Image(arch, ET_EXEC, INIT_ARRAY_LIBRARY_BASE)
    image.extra_dynamic = [(DT_INIT_ARRAY, KERNEL_ADDRESS), (DT_INIT_ARRAYSZ, 8)]
    return image.build()


def tls_outside_program(arch):
    image = Image(arch, ET_DYN)
    image.code = ARCHITECTURES[arch]['exit_code']
    image.tls = (0x0000700000000000, 16, 16)
    return image.build()


def segment_program(arch, vaddr):
    """One loadable segment at Vaddr with bss after its file data in the
    same page (a page the loader builds)."""
    image = Image(arch, ET_EXEC, FIXED_PROGRAM_BASE)
    image.code = ARCHITECTURES[arch]['exit_code']
    image.segments = [(0, FIXED_PROGRAM_BASE, PAGE, PAGE, PF_R | PF_X),
                      (PAGE, image.page1_address(), PAGE, PAGE, PF_R | PF_W),
                      (PAGE, vaddr, 16, 3 * PAGE, PF_R | PF_W)]
    return image.build()


def kernel_relocation_program(arch):
    image = Image(arch, ET_EXEC, FIXED_PROGRAM_BASE)
    image.code = ARCHITECTURES[arch]['exit_code']
    image.relocations.append((KERNEL_ADDRESS, ARCHITECTURES[arch]['absolute'], 0, 0x4142434445464748))
    return image.build()


def text_relocation_library(arch):
    """Two read-only segments sharing page 0 (so the loader builds it and
    every process maps the built page), with a relocation into the
    second: each process must get its own copy of the page."""
    image = Image(arch, ET_DYN)
    target = 0x900
    image.add_symbol('loadertest_text_value', target)
    image.relocations.append((target, ARCHITECTURES[arch]['relative'], 0, target))
    image.segments = [(0, 0, 0x800, 0x800, PF_R),
                      (0x800, 0x800, 0x800, 0x800, PF_R),
                      (PAGE, PAGE, PAGE, PAGE, PF_R | PF_W)]
    return image.build()


def main():
    if len(sys.argv) != 3 or sys.argv[1] not in ARCHITECTURES:
        sys.exit('usage: make-crafted-elves.py <amd64|arm64> <output-directory>')
    arch, output = sys.argv[1], sys.argv[2]
    os.makedirs(output, exist_ok=True)
    files = {
        'good-library.so': good_library(arch),
        'good-program': good_program(arch),
        'reloc-kernel-library.so': relocation_library(arch, ET_EXEC, KERNEL_RELOCATION_LIBRARY_BASE,
                                                      KERNEL_ADDRESS),
        'reloc-outside-library.so': relocation_library(arch, ET_DYN, 0, 0x40000000),
        'reloc-gap-library.so': gap_library(arch),
        'copy-provider-library.so': copy_provider_library(arch),
        'copy-kernel-library.so': copy_kernel_library(arch),
        'unterminated-strings-library.so': unterminated_strings_library(arch),
        'odd-relasz-library.so': odd_relocation_size(arch, ET_EXEC, KERNEL_RELOCATION_LIBRARY_BASE + 0x100000),
        'init-array-kernel-library.so': init_array_library(arch),
        'text-relocation-library.so': text_relocation_library(arch),
        'tls-outside-program': tls_outside_program(arch),
        'segment-kernel-program': segment_program(arch, KERNEL_ADDRESS),
        'segment-wrap-program': segment_program(arch, 0xFFFFFFFFFFFFF000),
        'reloc-kernel-program': kernel_relocation_program(arch),
        'odd-relasz-program': odd_relocation_size(arch, ET_DYN, 0),
    }
    for name, contents in files.items():
        path = os.path.join(output, name)
        with open(path, 'wb') as handle:
            handle.write(contents)
        os.chmod(path, 0o755)


if __name__ == '__main__':
    main()
