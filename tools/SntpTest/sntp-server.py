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
# A small SNTP server for the host test (SntpTest.pas), on 127.0.0.1:
#   the first port answers as a stratum 2 server whose clock is
#   OFFSET seconds ahead of the host's (default 1234.5), after holding
#   each reply DELAY seconds (default 0.01);
#   the second port answers every request with a kiss of death
#   (stratum 0, "RATE").
# Both ports (chosen by the system) are written to PORT-FILE as
# "normal kiss" once the server listens. It ends after TIMEOUT seconds
# (default 30) or when its parent goes.
#
#   sntp-server.py <port-file> [--offset SECONDS] [--delay SECONDS] [--timeout SECONDS]

import argparse
import os
import select
import socket
import struct
import time

NTP_TO_UNIX = 2208988800


def ntp_timestamp(unix_seconds):
    seconds = int(unix_seconds) + NTP_TO_UNIX
    fraction = int((unix_seconds - int(unix_seconds)) * (1 << 32))
    return ((seconds & 0xFFFFFFFF) << 32) | (fraction & 0xFFFFFFFF)


def reply(request, received, offset, stratum, reference):
    origin = request[40:48]
    header = struct.pack("!BBbb", (0 << 6) | (4 << 3) | 4, stratum, 6, -20)
    root = struct.pack("!II", 0, 0) + reference
    reference_time = struct.pack("!Q", ntp_timestamp(received + offset - 60))
    receive = struct.pack("!Q", ntp_timestamp(received + offset))
    transmit = struct.pack("!Q", ntp_timestamp(time.time() + offset))
    return header + root + reference_time + origin + receive + transmit


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("port_file")
    parser.add_argument("--offset", type=float, default=1234.5)
    parser.add_argument("--delay", type=float, default=0.01)
    parser.add_argument("--timeout", type=float, default=30)
    arguments = parser.parse_args()

    normal = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    normal.bind(("127.0.0.1", 0))
    kiss = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    kiss.bind(("127.0.0.1", 0))
    temporary = arguments.port_file + ".new"
    with open(temporary, "w") as port_file:
        port_file.write(f"{normal.getsockname()[1]} {kiss.getsockname()[1]}\n")
    os.replace(temporary, arguments.port_file)

    parent = os.getppid()
    deadline = time.time() + arguments.timeout
    while time.time() < deadline and os.getppid() == parent:
        readable, _, _ = select.select([normal, kiss], [], [], 0.5)
        for sock in readable:
            request, peer = sock.recvfrom(512)
            received = time.time()
            if len(request) < 48:
                continue
            if sock is normal:
                time.sleep(arguments.delay)
                sock.sendto(reply(request, received, arguments.offset, 2, b"\x7f\x00\x00\x01"), peer)
            else:
                sock.sendto(reply(request, received, 0, 0, b"RATE"), peer)


if __name__ == "__main__":
    main()
