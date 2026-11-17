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

#
# Writes the DSDT the ACPI device test (AcpiDeviceTest.pas) walks: AML
# assembled by hand, laid out like the Raspberry Pi 4 UEFI firmware's
# tables in ACPI mode (a container with _CCA 0 and a _DMA window seen at
# bus address C0000000h, the mailbox, EMMC2 and GENET under it, the xHCI
# controller described by its registers above 4 GiB) plus a PCI root
# bridge, a device that is not present (with a child) and a _CRS that is
# a method.
#
#   make-table.py <output.aml>

import struct
import sys


def package_length(body_length):
    """The PkgLength encoding of a package whose body is body_length bytes
    (the encoding counts its own bytes too)."""
    for extra in range(4):
        total = body_length + 1 + extra
        if extra == 0 and total < 64:
            return bytes([total])
        if extra > 0 and total < (1 << (4 + 8 * extra)):
            encoded = [(extra << 6) | (total & 0xF)]
            remaining = total >> 4
            for _ in range(extra):
                encoded.append(remaining & 0xFF)
                remaining >>= 8
            return bytes(encoded)
    raise ValueError("package too long")


def name_segment(name):
    return name.ljust(4, "_").encode()


def name_string(path):
    """A name string: "\\_SB_" or a relative single segment."""
    if path.startswith("\\"):
        return b"\\" + name_segment(path[1:])
    return name_segment(path)


def integer(value):
    if value == 0:
        return b"\x00"
    if value == 1:
        return b"\x01"
    if value <= 0xFF:
        return b"\x0A" + struct.pack("<B", value)
    if value <= 0xFFFF:
        return b"\x0B" + struct.pack("<H", value)
    if value <= 0xFFFFFFFF:
        return b"\x0C" + struct.pack("<I", value)
    return b"\x0E" + struct.pack("<Q", value)


def string(text):
    return b"\x0D" + text.encode() + b"\x00"


def buffer(data):
    body = integer(len(data)) + data
    return b"\x11" + package_length(len(body)) + body


def package(*elements):
    body = bytes([len(elements)]) + b"".join(elements)
    return b"\x12" + package_length(len(body)) + body


def name(segment, value):
    return b"\x08" + name_segment(segment) + value


def scope(path, *terms):
    body = name_string(path) + b"".join(terms)
    return b"\x10" + package_length(len(body)) + body


def device(segment, *terms):
    body = name_segment(segment) + b"".join(terms)
    return b"\x5B\x82" + package_length(len(body)) + body


def method_returning(segment, value):
    body = name_segment(segment) + b"\x00" + b"\xA4" + value
    return b"\x14" + package_length(len(body)) + body


def eisa_id(text):
    vendor = ((ord(text[0]) - 0x40) << 10) | ((ord(text[1]) - 0x40) << 5) | (ord(text[2]) - 0x40)
    product = int(text[3:], 16)
    value = ((vendor >> 8) & 0xFF) | ((vendor & 0xFF) << 8) | (((product >> 8) & 0xFF) << 16) | ((product & 0xFF) << 24)
    return integer(value)


def uuid(text):
    parts = text.split("-")
    data = struct.pack("<IHH", int(parts[0], 16), int(parts[1], 16), int(parts[2], 16))
    data += bytes.fromhex(parts[3] + parts[4])
    return buffer(data)


# --- Resource descriptors ---

def memory32_fixed(base, length):
    return b"\x86\x09\x00\x01" + struct.pack("<II", base, length)


def interrupts(numbers, level=True, active_low=False):
    flags = 0x01  # consumer
    if not level:
        flags |= 0x02
    if active_low:
        flags |= 0x04
    body = bytes([flags, len(numbers)]) + b"".join(struct.pack("<I", n) for n in numbers)
    return b"\x89" + struct.pack("<H", len(body)) + body


def qword_memory(minimum, maximum, translation, length, consumer=True):
    general = 0x0C | (1 if consumer else 0)
    body = bytes([0, general, 0x01]) + struct.pack("<QQQQQ", 0, minimum, maximum, translation, length)
    return b"\x8A" + struct.pack("<H", len(body)) + body


def dword_memory(minimum, maximum, length, consumer=True):
    general = 0x0C | (1 if consumer else 0)
    body = bytes([0, general, 0x01]) + struct.pack("<IIIII", 0, minimum, maximum, 0, length)
    return b"\x87" + struct.pack("<H", len(body)) + body


def io_ports(minimum, length):
    return b"\x47\x01" + struct.pack("<HHBB", minimum, minimum, 1, length)


def template(*descriptors):
    return buffer(b"".join(descriptors) + b"\x79\x00")


DEVICE_PROPERTIES = "daffd814-6eba-4d8c-8a91-bc9bbf4aa301"

body = scope(
    "\\_SB_",
    device(
        "GDV0",
        name("_HID", string("ACPI0004")),
        name("_UID", integer(0)),
        name("_CCA", integer(0)),
        name("_DMA", template(qword_memory(0xC0000000, 0xFFFFFFFF, 0xFFFFFFFF40000000, 0x40000000))),
        device(
            "RPIQ",
            name("_HID", string("BCM2849")),
            name("_CRS", template(memory32_fixed(0xFE00B880, 0x24), interrupts([0x61]))),
        ),
        device(
            "SDC3",
            name("_HID", string("BRCME88C")),
            name("_UID", integer(1)),
            method_returning("_CRS", template(memory32_fixed(0xFE340000, 0x100), interrupts([0x9E]))),
        ),
        device(
            "ETH0",
            name("_HID", string("BCM6E4E")),
            name("_CID", string("BCM6E4E")),
            name("_CRS", template(memory32_fixed(0xFD580000, 0x10000), interrupts([0xBD, 0xBE]))),
            name(
                "_DSD",
                package(
                    uuid(DEVICE_PROPERTIES),
                    package(
                        package(string("local-mac-address"), buffer(bytes([0xDC, 0xA6, 0x32, 0x01, 0x02, 0x03]))),
                        package(string("phy-mode"), string("rgmii-rxid")),
                        package(string("phy-address"), integer(1)),
                        package(string("byte-list"), package(integer(1), integer(2), integer(3))),
                    ),
                ),
            ),
        ),
        device(
            "GONE",
            name("_HID", string("TEST0001")),
            name("_STA", integer(0)),
            device("KIDS", name("_HID", string("TEST0002"))),
        ),
    ),
    device(
        "XHC0",
        name("_HID", eisa_id("PNP0D10")),
        name("_CID", package(eisa_id("PNP0D10"), string("XHCI0001"))),
        name("_CCA", integer(1)),
        name("_CRS", template(qword_memory(0x600000000, 0x600000FFF, 0, 0x1000), interrupts([175]))),
    ),
    device(
        "PCI0",
        name("_HID", eisa_id("PNP0A08")),
        name("_CID", eisa_id("PNP0A03")),
        name("_SEG", integer(1)),
        name("_CRS", template(dword_memory(0x10000000, 0x3EFEFFFF, 0x2EFF0000, consumer=False), io_ports(0xCF8, 8))),
    ),
)

header_length = 36
table = bytearray(b"DSDT" + struct.pack("<I", header_length + len(body)) + bytes([2, 0]) + b"FPOS  " +
                  b"DEVTEST " + struct.pack("<I", 1) + b"FPOS" + struct.pack("<I", 1) + body)
table[9] = (-sum(table)) & 0xFF
with open(sys.argv[1], "wb") as output:
    output.write(table)
