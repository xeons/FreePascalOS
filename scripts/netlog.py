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

"""Receives the FreePascalOS kernel log sent with the netlog option.

    scripts/netlog.py [--port 5140] [--bind 0.0.0.0] [--output FILE]

Each datagram is one line of the kernel log, "SEQUENCE UPTIME TEXT"
(SEQUENCE followed by "+" for the rest of a long line). Lines are
printed with the address they came from. Sequence numbers start at 1
each boot: when they start again the machine rebooted, and that is
said; numbers skipped are lines lost (or no longer kept by the time the
network came up), and that is said too.

With --output the same lines are added to FILE, one per line:
"SOURCE SEQUENCE UPTIME TEXT", with the notes about reboots and gaps as
lines starting with "#".

Ctrl-C ends it.
"""

import argparse
import socket
import sys
import time

DEFAULT_PORT = 5140


class Sender:
    """What is known about one machine that sends its log."""

    def __init__(self):
        self.last_sequence = None
        self.boot_count = 0


def parse_datagram(data):
    """Returns (sequence, continued, uptime, text), or None."""
    text = data.decode("utf-8", errors="replace").rstrip("\r\n")
    parts = text.split(" ", 2)
    if len(parts) < 2:
        return None
    number = parts[0]
    continued = number.endswith("+")
    if continued:
        number = number[:-1]
    if not number.isdigit():
        return None
    try:
        uptime = float(parts[1])
    except ValueError:
        return None
    return int(number), continued, uptime, parts[2] if len(parts) > 2 else ""


class Listener:
    def __init__(self, output, use_color):
        self.senders = {}
        self.output = output
        self.use_color = use_color

    def note(self, source, message):
        line = "# %s %s" % (source, message)
        if self.use_color:
            print("\x1b[33m%s\x1b[0m" % line, flush=True)
        else:
            print(line, flush=True)
        if self.output:
            self.output.write(line + "\n")
            self.output.flush()

    def receive(self, data, address):
        source = address[0]
        parsed = parse_datagram(data)
        if parsed is None:
            self.note(source, "not a log line: %r" % data[:80])
            return
        sequence, continued, uptime, text = parsed
        sender = self.senders.setdefault(source, Sender())
        last = sender.last_sequence
        if last is None:
            sender.boot_count = 1
            self.note(source, "first line %d at %.6f s (%s)" % (sequence, uptime, time.strftime("%H:%M:%S")))
        elif sequence <= last:
            # Numbers start again: a new boot. (A repeated line after a
            # retry would also land here, but the kernel only resends what
            # it has not had sent.)
            sender.boot_count += 1
            self.note(source, "REBOOT: line %d after line %d - boot %d (%s)"
                      % (sequence, last, sender.boot_count, time.strftime("%H:%M:%S")))
        elif sequence > last + 1:
            self.note(source, "GAP: lines %d to %d lost or no longer kept" % (last + 1, sequence - 1))
        sender.last_sequence = sequence
        marker = "+" if continued else ""
        line = "%s %d%s %.6f %s" % (source, sequence, marker, uptime, text)
        print(line, flush=True)
        if self.output:
            self.output.write(line + "\n")
            self.output.flush()


def main():
    parser = argparse.ArgumentParser(description="Receive the FreePascalOS kernel log (netlog option).")
    parser.add_argument("--port", type=int, default=DEFAULT_PORT, help="UDP port (default 5140)")
    parser.add_argument("--bind", default="0.0.0.0", help="address to listen on (default all)")
    parser.add_argument("--output", help="also add the lines to this file")
    parser.add_argument("--no-color", action="store_true", help="no colour for the notes")
    arguments = parser.parse_args()

    receiver = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    receiver.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    # A boot's replay comes in a burst: room for it.
    receiver.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4 * 1024 * 1024)
    receiver.bind((arguments.bind, arguments.port))

    output = open(arguments.output, "a", encoding="utf-8") if arguments.output else None
    listener = Listener(output, sys.stdout.isatty() and not arguments.no_color)
    print("# listening on %s:%d" % (arguments.bind, arguments.port), flush=True)
    try:
        while True:
            data, address = receiver.recvfrom(2048)
            listener.receive(data, address)
    except KeyboardInterrupt:
        pass
    finally:
        if output:
            output.close()


if __name__ == "__main__":
    main()
