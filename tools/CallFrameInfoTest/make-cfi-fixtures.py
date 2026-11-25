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
Writes the fixtures of CallFrameInfoTest (the kernel's call frame
information unwinder, Processes.CallFrameEntries and .CallFrameRules):

    make-cfi-fixtures.py OUTPUT_DIRECTORY

memory.bin       a process's memory as records of (address: u64,
                 length: u64, bytes): an x86-64 .eh_frame with its
                 .eh_frame_hdr as a C compiler and linker lay them out
                 (CIE "zR", pc-relative signed 4-byte pointers, a
                 binary search table), an AArch64 one, and the stacks
                 the test unwinds.
fpc-debug-frame.bin       a .debug_frame as Free Pascal's internal
                          assembler writes it (an 8-byte CIE pointer).
standard-debug-frame.bin  a version 3 .debug_frame in the standard
                          layout.

The addresses and values are the ones tools/CallFrameInfoTest checks.
"""

import os
import struct
import sys


def uleb(value):
    out = bytearray()
    while True:
        byte = value & 0x7F
        value >>= 7
        if value:
            out.append(byte | 0x80)
        else:
            out.append(byte)
            return bytes(out)


def sleb(value):
    out = bytearray()
    while True:
        byte = value & 0x7F
        value >>= 7
        if (value == 0 and not byte & 0x40) or (value == -1 and byte & 0x40):
            out.append(byte)
            return bytes(out)
        out.append(byte | 0x80)


def padded(body, alignment=4):
    """An entry's length field and body, padded with DW_CFA_nop."""
    while (len(body) + 4) % alignment:
        body += b'\x00'
    return struct.pack('<I', len(body)) + body


class EhFrame:
    """An .eh_frame at a known address with one CIE ("zR", pc-relative
    signed 4-byte pointers) and FDEs; with its .eh_frame_hdr."""

    def __init__(self, address, code_alignment, data_alignment, return_column, initial):
        self.address = address
        body = struct.pack('<I', 0) + b'\x01' + b'zR\x00' + uleb(code_alignment) + sleb(data_alignment)
        body += bytes([return_column]) + uleb(1) + b'\x1b' + initial
        self.data = bytearray(padded(body, 8))
        self.fdes = []

    def add(self, start, length, instructions):
        offset = len(self.data)
        field = self.address + offset + 8
        body = struct.pack('<I', offset + 4)
        body += struct.pack('<i', start - field) + struct.pack('<I', length) + uleb(0) + instructions
        self.data += padded(body, 8)
        self.fdes.append((start, self.address + offset))

    def finish(self):
        return bytes(self.data) + b'\x00' * 4

    def header(self, address):
        hdr = bytearray(b'\x01\x1b\x03\x3b')
        hdr += struct.pack('<i', self.address - (address + 4))
        hdr += struct.pack('<I', len(self.fdes))
        for start, fde in sorted(self.fdes):
            hdr += struct.pack('<ii', start - address, fde - address)
        return bytes(hdr)


def words(*values):
    return b''.join(struct.pack('<Q', value) for value in values)


def x86_64_frames():
    """F at 401000: PUSH RBX; SUB RSP, 32. G at 402300: PUSH RBP;
    MOV RBP, RSP; an epilogue at 402364 inside remember/restore state."""
    frame = EhFrame(0x400800, 1, -8, 16, b'\x0c\x07\x08' + b'\x90\x01')
    frame.add(0x401000, 0x40, b'\x41' + b'\x0e\x10' + b'\x83\x02' + b'\x44' + b'\x0e\x30')
    frame.add(0x402300, 0x100, b'\x41' + b'\x0e\x10' + b'\x86\x02' + b'\x43' + b'\x0d\x06' +
              b'\x02\x60' + b'\x0a' + b'\x0c\x07\x08' + b'\x41' + b'\x0b')
    return frame


def aarch64_frames():
    """K at 501000: STP X29, X30, [SP, #-32]!."""
    frame = EhFrame(0x500800, 4, -8, 30, b'\x0c\x1f\x00')
    frame.add(0x501000, 0x40, b'\x41' + b'\x0e\x20' + b'\x9d\x04' + b'\x9e\x03')
    return frame


def memory_image():
    records = []
    x86 = x86_64_frames()
    records.append((0x400800, x86.finish()))
    records.append((0x400700, x86.header(0x400700)))
    arm = aarch64_frames()
    records.append((0x500800, arm.finish()))
    records.append((0x500700, arm.header(0x500700)))
    # The x86-64 stack: F saved RBX and was called from 402345; G's
    # frame record at 70000100.
    records.append((0x70000020, words(0x1111, 0x402345)))
    records.append((0x70000100, words(0x70000200, 0x403000)))
    # The Free Pascal routine's stack, before and after its prologue.
    records.append((0x70FFFFF8, words(0x71000100, 0x10008999)))
    # The AArch64 stack: K's frame record.
    records.append((0x72000000, words(0x72000100, 0x501234)))
    # A frame pointer chain.
    records.append((0x73000000, words(0x73000040, 0x404040)))
    out = bytearray()
    for address, data in records:
        out += struct.pack('<QQ', address, len(data)) + data
    return bytes(out)


FPC_CIE = bytes.fromhex('10000000ffffffff0100017c100c070805100200')


def fpc_debug_frame():
    """Free Pascal's: the routine at link address 8330 (PUSH RBP; MOV
    RBP, RSP), its FDE with the 8-byte CIE pointer."""
    instructions = bytes.fromhex('0401000000' '0e10' '0400000000' '050604' '0403000000' '0d06' '0000')
    body = struct.pack('<Q', 0) + struct.pack('<QQ', 0x8330, 0xFA) + instructions
    return FPC_CIE + struct.pack('<I', len(body)) + body


def standard_debug_frame():
    """Version 3, standard layout: the routine at 8500 pushes one word."""
    cie = struct.pack('<I', 0xFFFFFFFF) + b'\x03' + b'\x00' + uleb(1) + sleb(-8) + uleb(16)
    cie += b'\x0c\x07\x08' + b'\x90\x01'
    data = padded(cie, 8)
    body = struct.pack('<I', 0) + struct.pack('<QQ', 0x8500, 0x20) + b'\x41' + b'\x0e\x10'
    return data + padded(body, 8)


def main():
    if len(sys.argv) != 2:
        print(__doc__)
        sys.exit(2)
    directory = sys.argv[1]
    os.makedirs(directory, exist_ok=True)
    for name, data in (('memory.bin', memory_image()), ('fpc-debug-frame.bin', fpc_debug_frame()),
                       ('standard-debug-frame.bin', standard_debug_frame())):
        with open(os.path.join(directory, name), 'wb') as output:
            output.write(data)


if __name__ == '__main__':
    main()
