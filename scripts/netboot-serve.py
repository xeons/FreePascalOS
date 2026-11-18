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

"""Network boot server for FreePascalOS (the loader's netboot=).

    netboot-serve.py [--esp DIR] [--system-image FILE] [--options-file FILE]
                     [--port 8000] [--bind ADDRESS] [--tftp] [--tftp-port 69]

Serves the boot files of a build over HTTP, and over TFTP with --tftp:

    EFI/BOOT/BOOTAA64.EFI      the loader         (from the ESP directory)
    FreePascalOS/kernel.elf    the kernel         (from the ESP directory)
    FreePascalOS/options.txt   the kernel options (--options-file, else the
                               ESP's options.txt; none: the loader keeps
                               the options of its own boot volume)
    FreePascalOS/system.img    the system volume  (--system-image), which
                               the kernel runs from as a RAM disk

Files are read at each request, so a rebuild takes effect at the next
boot without restarting the server. HTTP needs no root; TFTP's port 69
does (use --tftp-port for another port, which only the loader's
netboot=tftp:// cannot name: it always uses 69). The TFTP server is
built in (read requests with the blksize and tsize options).

Prints this machine's addresses and the options.txt line to use.
"""

import argparse
import http.server
import os
import socket
import socketserver
import struct
import subprocess
import sys
import threading
import time

SYSTEM_IMAGE_PATH = "FreePascalOS/system.img"
OPTIONS_PATH = "FreePascalOS/options.txt"


class BootFiles:
    """Maps a requested path to a file of the build."""

    def __init__(self, esp_directory, system_image, options_file):
        self.esp_directory = os.path.realpath(esp_directory)
        self.system_image = system_image
        self.options_file = options_file

    def resolve(self, requested):
        path = requested.split("?", 1)[0].replace("\\", "/").lstrip("/")
        parts = [part for part in path.split("/") if part not in ("", ".")]
        if ".." in parts:
            return None
        path = "/".join(parts)
        lowered = path.lower()
        if lowered == SYSTEM_IMAGE_PATH.lower():
            return self.system_image
        if lowered == OPTIONS_PATH.lower() and self.options_file:
            return self.options_file
        candidate = self.find_ignoring_case(parts)
        if candidate and os.path.isfile(candidate):
            return candidate
        return None

    def find_ignoring_case(self, parts):
        """FAT is case-insensitive, and firmware asks for EFI/BOOT/BOOTAA64.EFI
        or efi/boot/bootaa64.efi alike."""
        current = self.esp_directory
        for part in parts:
            exact = os.path.join(current, part)
            if os.path.exists(exact):
                current = exact
                continue
            try:
                matches = [name for name in os.listdir(current) if name.lower() == part.lower()]
            except OSError:
                return None
            if not matches:
                return None
            current = os.path.join(current, matches[0])
        return current


def log(message):
    print(time.strftime("%H:%M:%S"), message, flush=True)


def describe_size(size):
    if size >= 1024 * 1024:
        return f"{size / (1024 * 1024):.1f} MiB"
    return f"{size / 1024:.1f} KiB"


# --- HTTP --------------------------------------------------------------------

def make_http_handler(boot_files):
    class Handler(http.server.BaseHTTPRequestHandler):
        server_version = "FreePascalOS-netboot/1"
        # HTTP/1.0: one request per connection, which the loader expects.
        protocol_version = "HTTP/1.0"

        def do_GET(self):
            self.send_file(with_body=True)

        def do_HEAD(self):
            self.send_file(with_body=False)

        def send_file(self, with_body):
            path = boot_files.resolve(self.path)
            if path is None or not os.path.isfile(path):
                self.send_error(404, "Not found")
                log(f"HTTP {self.client_address[0]} {self.path}: not found")
                return
            started = time.monotonic()
            with open(path, "rb") as source:
                size = os.fstat(source.fileno()).st_size
                self.send_response(200)
                self.send_header("Content-Type", "application/octet-stream")
                self.send_header("Content-Length", str(size))
                self.end_headers()
                if with_body:
                    try:
                        while True:
                            chunk = source.read(1024 * 1024)
                            if not chunk:
                                break
                            self.wfile.write(chunk)
                    except (BrokenPipeError, ConnectionResetError):
                        log(f"HTTP {self.client_address[0]} {self.path}: connection lost")
                        return
            seconds = time.monotonic() - started
            log(f"HTTP {self.client_address[0]} {self.path}: {describe_size(size)} in {seconds:.1f} s")

        def log_message(self, format, *args):
            pass

    return Handler


class ThreadingHttpServer(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True


# --- TFTP (RFC 1350, options RFC 2347/2348/2349) ------------------------------

TFTP_READ_REQUEST = 1
TFTP_DATA = 3
TFTP_ACKNOWLEDGEMENT = 4
TFTP_ERROR = 5
TFTP_OPTION_ACKNOWLEDGEMENT = 6
TFTP_RETRIES = 6
TFTP_TIMEOUT_SECONDS = 1.0


def tftp_error(sock, address, code, message):
    sock.sendto(struct.pack("!HH", TFTP_ERROR, code) + message.encode() + b"\0", address)


def parse_read_request(packet):
    fields = packet[2:].split(b"\0")
    if len(fields) < 2:
        return None, None
    name = fields[0].decode(errors="replace")
    options = {}
    index = 2
    while index + 1 < len(fields):
        if fields[index]:
            options[fields[index].decode(errors="replace").lower()] = fields[index + 1].decode(errors="replace")
        index += 2
    return name, options


def tftp_exchange(sock, address, packet, expected_block):
    """Sends packet until the matching acknowledgement comes. False if the
    client gave up or never answered."""
    for _ in range(TFTP_RETRIES):
        sock.sendto(packet, address)
        deadline = time.monotonic() + TFTP_TIMEOUT_SECONDS
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                break
            sock.settimeout(remaining)
            try:
                reply, sender = sock.recvfrom(65536)
            except socket.timeout:
                break
            if sender != address or len(reply) < 4:
                continue
            opcode, block = struct.unpack("!HH", reply[:4])
            if opcode == TFTP_ERROR:
                return False
            if opcode == TFTP_ACKNOWLEDGEMENT and block == expected_block:
                return True
    return False


def serve_tftp_transfer(boot_files, request, address):
    name, options = parse_read_request(request)
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        sock.bind(("", 0))
        path = boot_files.resolve(name or "")
        if path is None or not os.path.isfile(path):
            tftp_error(sock, address, 1, "File not found")
            log(f"TFTP {address[0]} {name}: not found")
            return
        with open(path, "rb") as source:
            data = source.read()
        block_size = 512
        accepted = {}
        if "blksize" in options:
            try:
                block_size = max(8, min(int(options["blksize"]), 65464))
                accepted["blksize"] = str(block_size)
            except ValueError:
                pass
        if "tsize" in options:
            accepted["tsize"] = str(len(data))
        if "timeout" in options:
            accepted["timeout"] = options["timeout"]
        if accepted:
            payload = b"".join(key.encode() + b"\0" + value.encode() + b"\0" for key, value in accepted.items())
            if not tftp_exchange(sock, address, struct.pack("!H", TFTP_OPTION_ACKNOWLEDGEMENT) + payload, 0):
                # A size query: the client ends it after the answer.
                if "tsize" in options:
                    log(f"TFTP {address[0]} {name}: size {len(data)}")
                return
        started = time.monotonic()
        block = 1
        offset = 0
        while True:
            chunk = data[offset:offset + block_size]
            packet = struct.pack("!HH", TFTP_DATA, block & 0xFFFF) + chunk
            if not tftp_exchange(sock, address, packet, block & 0xFFFF):
                log(f"TFTP {address[0]} {name}: client stopped at byte {offset}")
                return
            offset += len(chunk)
            block += 1
            if len(chunk) < block_size:
                break
        seconds = time.monotonic() - started
        log(f"TFTP {address[0]} {name}: {describe_size(len(data))} in {seconds:.1f} s")
    finally:
        sock.close()


def run_tftp_server(boot_files, bind_address, port):
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind((bind_address, port))
    while True:
        request, address = sock.recvfrom(65536)
        if len(request) < 4 or struct.unpack("!H", request[:2])[0] != TFTP_READ_REQUEST:
            continue
        threading.Thread(target=serve_tftp_transfer, args=(boot_files, request, address),
                         daemon=True).start()


# --- Addresses ---------------------------------------------------------------

def local_addresses():
    """This machine's IPv4 addresses other than loopback, the one with the
    default route first."""
    addresses = []
    try:
        probe = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        probe.connect(("192.0.2.1", 9))  # nothing is sent
        addresses.append(probe.getsockname()[0])
        probe.close()
    except OSError:
        pass
    try:
        output = subprocess.run(["ip", "-4", "-o", "address", "show"], capture_output=True,
                                text=True, timeout=5).stdout
        for line in output.splitlines():
            fields = line.split()
            if "inet" in fields:
                address = fields[fields.index("inet") + 1].split("/")[0]
                if address not in addresses:
                    addresses.append(address)
    except (OSError, subprocess.SubprocessError):
        pass
    return [address for address in addresses if not address.startswith("127.")]


def main():
    parser = argparse.ArgumentParser(description="Serve FreePascalOS boot files for a network boot.")
    parser.add_argument("--esp", default="build/arm64/esp", help="the ESP directory of the build")
    parser.add_argument("--system-image", default="build/arm64/system-disk.img",
                        help="the system volume image served as FreePascalOS/system.img")
    parser.add_argument("--no-system-image", action="store_true",
                        help="serve no system image (the kernel then uses its disks)")
    parser.add_argument("--options-file", help="served as FreePascalOS/options.txt")
    parser.add_argument("--bind", default="0.0.0.0", help="address to listen on")
    parser.add_argument("--port", type=int, default=8000, help="HTTP port")
    parser.add_argument("--tftp", action="store_true", help="serve TFTP as well")
    parser.add_argument("--tftp-port", type=int, default=69, help="TFTP port (69 needs root)")
    arguments = parser.parse_args()

    if not os.path.isdir(arguments.esp):
        sys.exit(f"No ESP directory {arguments.esp}: build first (make ARCH=arm64)")
    system_image = None if arguments.no_system_image else arguments.system_image
    if system_image and not os.path.isfile(system_image):
        print(f"Warning: {system_image} does not exist yet (make ARCH=arm64 system-disk)")
    boot_files = BootFiles(arguments.esp, system_image, arguments.options_file)

    if arguments.tftp:
        try:
            threading.Thread(target=run_tftp_server,
                             args=(boot_files, arguments.bind, arguments.tftp_port), daemon=True).start()
        except OSError as error:
            sys.exit(f"TFTP port {arguments.tftp_port}: {error}")

    server = ThreadingHttpServer((arguments.bind, arguments.port), make_http_handler(boot_files))
    addresses = local_addresses()
    print(f"Serving {arguments.esp}" + (f" and {system_image}" if system_image else ""))
    print("This machine's addresses: " + (", ".join(addresses) if addresses else "none found"))
    first = addresses[0] if addresses else "<this-machine>"
    print("Put this line in FreePascalOS/options.txt on the Pi's SD card:")
    print(f"    netboot=http://{first}:{arguments.port}/")
    if arguments.tftp:
        print(f"or, over TFTP (port {arguments.tftp_port}): netboot=tftp://{first}/")
        print(f"For a PXE boot by the firmware, the DHCP server names next-server {first}"
              " and boot file EFI/BOOT/BOOTAA64.EFI")
    print("Rebuild (make ARCH=arm64 esp system-disk) and reset the Pi; Ctrl-C ends the server.",
          flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
