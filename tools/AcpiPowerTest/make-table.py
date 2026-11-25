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
# Writes the table the ACPI power test (AcpiPowerTest.pas) reads: AML
# assembled by hand with
#   \_TZ_.TZ00  a thermal zone at 40.0 C (_TMP a method), passive 80 C,
#               critical 100 C, hot 95 C, polled every 5 s (_TZP 50);
#   \_TZ_.TZ01  a zone whose _TMP makes no sense (0) and no trip points;
#   \_SB_.BAT0  a battery with _BIF and _BST (discharging, 2500 of 4000 mWh);
#   \_SB_.BAT1  a battery with _BIX (mAh, charging);
#   \_SB_.BAT2  an empty battery slot (_STA without bit 4);
#   \_PR_.CPU0  a Processor object with a _CST: C1 through FFH class 1
#               (halt), C2 and C3 through FFH class 2 (MWAIT hints 10h and
#               20h, 20 and 100 us), and a C3 read from an I/O port; an
#               _OSC that keeps what it is told (OSCB), _PSS (2400, 1800,
#               800 MHz), _PCT (the performance MSRs), _PPC 1, _MAT (a
#               local APIC entry, id 5);
#   \_PR_.CPU1  a Processor object with a _PDC that keeps what it is told
#               (PDCB) and a _MAT x2APIC entry (id 300);
#   \_SB_.EC0_  an embedded controller (ports 62h and 66h, GPE 17h): _REG
#               (ECAV), a region with TMP0 at 10h, FANS at 20h, FSPD (16
#               bits) at 21h, and a query method _Q42 (QHIT);
#   \_SB_.FAN0  a fan with _FSL (writes FANS in the controller);
#   \_SB_.FAN1  a fan switched by its power resource PRF1 (_PR0);
#   \_TZ_.TZ02  a zone reading TMP0 from the controller, _AC0 60 C (FAN0)
#               and _AC1 45 C (FAN1);
#   \_SB_.PCI0  a root bridge with XHC_ (_PRW GPE 6Dh, S3, power resource
#               PRW0, _DSW keeping its argument in DSWA) and GLAN (_PRW
#               6Dh, S4, _PSW into PSWA); \_SB_.PWRB (power button, _PRW
#               1Dh S5) and \_SB_.LID0 (_PRW of a GPE block device).
#
#   make-table.py <output.aml> [--ssdt]
#
# With --ssdt the same thermal zones and batteries come as an SSDT for
# QEMU's -acpitable (QEMU has no thermal zone or battery of its own),
# without the processor (QEMU's are devices of its own DSDT).

import struct
import sys


def package_length(body_length):
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


def thermal_zone(segment, *terms):
    body = name_segment(segment) + b"".join(terms)
    return b"\x5B\x85" + package_length(len(body)) + body


def processor(segment, number, *terms):
    body = name_segment(segment) + bytes([number]) + struct.pack("<IB", 0, 0) + b"".join(terms)
    return b"\x5B\x83" + package_length(len(body)) + body


def method_returning(segment, value):
    body = name_segment(segment) + b"\x00" + b"\xA4" + value
    return b"\x14" + package_length(len(body)) + body


def eisa_id(text):
    vendor = ((ord(text[0]) - 0x40) << 10) | ((ord(text[1]) - 0x40) << 5) | (ord(text[2]) - 0x40)
    product = int(text[3:], 16)
    value = ((vendor >> 8) & 0xFF) | ((vendor & 0xFF) << 8) | (((product >> 8) & 0xFF) << 16) | ((product & 0xFF) << 24)
    return integer(value)


def generic_register(space, width, offset, access, address):
    body = struct.pack("<BBBBQ", space, width, offset, access, address)
    return buffer(b"\x82" + struct.pack("<H", len(body)) + body + b"\x79\x00")


def path_string(path):
    root = path.startswith("\\")
    segments = [name_segment(part) for part in path.lstrip("\\").split(".")]
    prefix = b"\\" if root else b""
    if len(segments) == 1:
        return prefix + segments[0]
    if len(segments) == 2:
        return prefix + b"\x2E" + b"".join(segments)
    return prefix + b"\x2F" + bytes([len(segments)]) + b"".join(segments)


def method(segment, argument_count, *terms):
    body = name_segment(segment) + bytes([argument_count]) + b"".join(terms)
    return b"\x14" + package_length(len(body)) + body


def store(source, target):
    return b"\x70" + source + target


def return_value(value):
    return b"\xA4" + value


def argument(number):
    return bytes([0x68 + number])


def add(first, second):
    return b"\x72" + first + second + b"\x00"


def multiply(first, second):
    return b"\x77" + first + second + b"\x00"


def operation_region(segment, space, offset, length):
    return b"\x5B\x80" + name_segment(segment) + bytes([space]) + integer(offset) + integer(length)


def field_length(bits):
    if bits < 64:
        return bytes([bits])
    return bytes([(1 << 6) | (bits & 0xF), bits >> 4])


def field(region, flags, *items):
    body = name_segment(region) + bytes([flags])
    for item_name, bits in items:
        if item_name is None:
            body += b"\x00" + field_length(bits)
        else:
            body += name_segment(item_name) + field_length(bits)
    return b"\x5B\x81" + package_length(len(body)) + body


def power_resource(segment, *terms):
    body = name_segment(segment) + b"\x00" + struct.pack("<H", 0) + b"".join(terms)
    return b"\x5B\x84" + package_length(len(body)) + body


def io_descriptor(port):
    return bytes([0x47, 1]) + struct.pack("<HH", port, port) + bytes([1, 1])


def switched_resource(segment):
    return power_resource(
        segment,
        name("STAT", integer(0)),
        method("_STA", 0, return_value(path_string("STAT"))),
        method("_ON_", 0, store(integer(1), path_string("STAT"))),
        method("_OFF", 0, store(integer(0), path_string("STAT"))),
    )


def kelvin(celsius_tenths):
    return 2732 + celsius_tenths


thermal = scope(
    "\\_TZ_",
    thermal_zone(
        "TZ00",
        method_returning("_TMP", integer(kelvin(400))),
        name("_PSV", integer(kelvin(800))),
        name("_CRT", integer(kelvin(1000))),
        name("_HOT", integer(kelvin(950))),
        name("_TZP", integer(50)),
    ),
    thermal_zone(
        "TZ01",
        method_returning("_TMP", integer(0)),
    ),
)

batteries = scope(
    "\\_SB_",
    device(
        "BAT0",
        name("_HID", eisa_id("PNP0C0A")),
        name("_UID", integer(0)),
        method_returning("_STA", integer(0x1F)),
        method_returning("_BIF", package(
            integer(0), integer(5000), integer(4000), integer(1), integer(11100),
            integer(400), integer(200), integer(10), integer(10),
            string("TestCell 4000"), string("SN0042"), string("LION"), string("FPOS Power"))),
        method_returning("_BST", package(integer(1), integer(1500), integer(2500), integer(11400))),
    ),
    device(
        "BAT1",
        name("_HID", eisa_id("PNP0C0A")),
        name("_UID", integer(1)),
        name("_STA", integer(0x1F)),
        name("_BIX", package(
            integer(0), integer(1), integer(3000), integer(2900), integer(1), integer(7400),
            integer(300), integer(100), integer(17), integer(95000), integer(1000), integer(1000),
            integer(5000), integer(5000), integer(10), integer(10),
            string("Second 3000"), string("SN0007"), string("LiP"), string("FPOS Power"))),
        name("_BST", package(integer(2), integer(800), integer(0xFFFFFFFF), integer(8000))),
    ),
    device(
        "BAT2",
        name("_HID", eisa_id("PNP0C0A")),
        name("_UID", integer(2)),
        name("_STA", integer(0x0F)),
    ),
)

processors = scope(
    "\\_PR_",
    processor(
        "CPU0", 0,
        name("_CST", package(
            integer(4),
            package(generic_register(0x7F, 1, 1, 0, 0x00), integer(1), integer(1), integer(1000)),
            package(generic_register(0x7F, 1, 2, 1, 0x10), integer(2), integer(20), integer(500)),
            package(generic_register(0x7F, 1, 2, 3, 0x20), integer(3), integer(100), integer(100)),
            package(generic_register(0x01, 8, 0, 0, 0x414), integer(3), integer(200), integer(50)),
        )),
        name("OSCB", buffer(bytes(8))),
        method("_OSC", 4, store(argument(3), path_string("OSCB")), return_value(argument(3))),
        name("_PSS", package(
            package(integer(2400), integer(35000), integer(10), integer(10), integer(0x1800), integer(0x1800)),
            package(integer(1800), integer(20000), integer(10), integer(10), integer(0x1200), integer(0x1200)),
            package(integer(800), integer(8000), integer(10), integer(10), integer(0x0800), integer(0x0800)),
        )),
        name("_PCT", package(generic_register(0x7F, 0, 0, 0, 0x199), generic_register(0x7F, 0, 0, 0, 0x198))),
        method("_PPC", 0, return_value(integer(1))),
        name("_MAT", buffer(bytes([0, 8, 1, 5, 1, 0, 0, 0]))),
        name("_STA", integer(0x0F)),
    ),
)

controller = scope(
    "\\_SB_",
    device(
        "EC0",
        name("_HID", eisa_id("PNP0C09")),
        name("_CRS", buffer(io_descriptor(0x62) + io_descriptor(0x66) + b"\x79\x00")),
        name("_GPE", integer(0x17)),
        name("ECAV", integer(0)),
        name("QHIT", integer(0)),
        method("_REG", 2, store(argument(1), path_string("ECAV"))),
        operation_region("ECOR", 3, 0, 0x100),
        field("ECOR", 0x01, (None, 0x80), ("TMP0", 8), (None, 0x78), ("FANS", 8), ("FSPD", 16)),
        method("_Q42", 0, store(integer(0x42), path_string("QHIT"))),
    ),
    device(
        "FAN0",
        name("_HID", eisa_id("PNP0C0B")),
        method("_FSL", 1, store(argument(0), path_string("\\_SB_.EC0_.FANS"))),
    ),
    device(
        "FAN1",
        name("_HID", eisa_id("PNP0C0B")),
        name("_PR0", package(path_string("\\_SB_.PRF1"))),
    ),
    switched_resource("PRF1"),
    switched_resource("PRW0"),
    device(
        "PCI0",
        name("_HID", eisa_id("PNP0A08")),
        name("_BBN", integer(0)),
        device(
            "XHC",
            name("_ADR", integer(0x00140000)),
            name("_PRW", package(integer(0x6D), integer(3), path_string("\\_SB_.PRW0"))),
            name("DSWA", integer(0xFF)),
            method("_DSW", 3, store(argument(0), path_string("DSWA"))),
        ),
        device(
            "GLAN",
            name("_ADR", integer(0x00190000)),
            name("_PRW", package(integer(0x6D), integer(4))),
            name("PSWA", integer(0xFF)),
            method("_PSW", 1, store(argument(0), path_string("PSWA"))),
        ),
    ),
    device(
        "PWRB",
        name("_HID", eisa_id("PNP0C0C")),
        name("_PRW", package(integer(0x1D), integer(5))),
    ),
    device(
        "LID0",
        name("_HID", eisa_id("PNP0C0D")),
        name("_PRW", package(package(path_string("\\_SB_.PCI0"), integer(2)), integer(3))),
    ),
)

cooled_zone = scope(
    "\\_TZ_",
    thermal_zone(
        "TZ02",
        method("_TMP", 0, return_value(add(multiply(path_string("\\_SB_.EC0_.TMP0"), integer(10)), integer(2732)))),
        name("_AC0", integer(kelvin(600))),
        name("_AL0", package(path_string("\\_SB_.FAN0"))),
        name("_AC1", integer(kelvin(450))),
        name("_AL1", package(path_string("\\_SB_.FAN1"))),
    ),
)

control_processors = scope(
    "\\_PR_",
    processor(
        "CPU1", 1,
        name("PDCB", buffer(bytes(12))),
        method("_PDC", 1, store(argument(0), path_string("PDCB"))),
        name("_MAT", buffer(bytes([9, 16, 0, 0]) + struct.pack("<III", 300, 1, 1))),
        method("_STA", 0, return_value(integer(0x0F))),
    ),
)

as_ssdt = len(sys.argv) > 2 and sys.argv[2] == "--ssdt"
if as_ssdt:
    signature, body, table_id = b"SSDT", thermal + batteries, b"PWRTEST "
else:
    signature, body, table_id = b"DSDT", (thermal + batteries + processors + controller + cooled_zone +
                                          control_processors), b"PWRTEST "

header_length = 36
table = bytearray(signature + struct.pack("<I", header_length + len(body)) + bytes([2, 0]) + b"FPOS  " +
                  table_id + struct.pack("<I", 1) + b"FPOS" + struct.pack("<I", 1) + body)
table[9] = (-sum(table)) & 0xFF
with open(sys.argv[1], "wb") as output:
    output.write(table)
