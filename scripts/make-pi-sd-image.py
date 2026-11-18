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

"""Builds an SD card image for a Raspberry Pi 4, flashed once.

    make-pi-sd-image.py --esp build/arm64/esp --output build/arm64/pi-sd.img
                        [--firmware RPi4_UEFI_Firmware_v1.xx.zip]
                        [--server ADDRESS] [--port 8000] [--netlog HOST]
                        [--standalone --system-image build/arm64/system-disk.img]

The image has an MBR partition table with a bootable FAT32 partition
(type 0Ch, 256 MiB) holding
    the pftf Raspberry Pi 4 UEFI firmware (its zip extracted as it is:
        RPI_EFI.fd, start4.elf, fixup4.dat, config.txt with enable_uart=1,
        the device trees and overlays, firmware/),
    EFI/BOOT/BOOTAA64.EFI (the loader),
    FreePascalOS/kernel.elf (used only when the network boot fails),
    FreePascalOS/options.txt: netboot=http://SERVER:PORT/ and
        netlog=HOST, so the Pi loads everything else from
        scripts/netboot-serve.py on the build machine.
With --standalone the options have no netboot= and a second partition
(Linux, ext4) holds the system volume from the system image, so the Pi
boots without a server.

The firmware zip is the user's download (github.com/pftf/RPi4/releases,
v1.35 or later); by default the newest ~/Downloads/RPi4_UEFI_Firmware_v*.zip.
SERVER defaults to this machine's address on its default route.

Writes the image and a compressed copy next to it (.xz, or .gz without
xz). Needs sfdisk and mtools; no root.
"""

import argparse
import glob
import gzip
import os
import re
import shutil
import socket
import struct
import subprocess
import sys
import tempfile
import zipfile

FIRMWARE_RELEASES_URL = "https://github.com/pftf/RPi4/releases"
SECTOR_SIZE = 512
FIRST_PARTITION_SECTOR = 2048
BOOT_PARTITION_MIB = 256
SYSTEM_PARTITION_SPARE_MIB = 8


def fail(message):
    sys.exit(f"make-pi-sd-image: {message}")


def run(*command, **options):
    subprocess.run(command, check=True, **options)


def version_key(path):
    numbers = re.findall(r"\d+", os.path.basename(path))
    return [int(number) for number in numbers]


def find_firmware_zip(requested):
    if requested:
        path = os.path.expanduser(requested)
        if not os.path.isfile(path):
            fail(f"no firmware zip at {path}.\nDownload RPi4_UEFI_Firmware_v1.xx.zip (v1.35 or later) from "
                 f"{FIRMWARE_RELEASES_URL} and pass PI_FIRMWARE=<path>.")
        return path
    candidates = glob.glob(os.path.expanduser("~/Downloads/RPi4_UEFI_Firmware_v*.zip"))
    if not candidates:
        fail("the Raspberry Pi 4 UEFI firmware is missing.\nDownload RPi4_UEFI_Firmware_v1.xx.zip (v1.35 or "
             f"later) from {FIRMWARE_RELEASES_URL} into ~/Downloads, or pass PI_FIRMWARE=<path>.")
    return max(candidates, key=version_key)


def default_server_address():
    try:
        probe = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        probe.connect(("192.0.2.1", 9))  # nothing is sent
        address = probe.getsockname()[0]
        probe.close()
        return address
    except OSError:
        fail("could not find this machine's address; pass SERVER=<address>")


def extract_firmware(zip_path, destination):
    with zipfile.ZipFile(zip_path) as archive:
        names = archive.namelist()
        if "RPI_EFI.fd" not in names or "start4.elf" not in names:
            fail(f"{zip_path} does not look like the pftf RPi4 UEFI firmware (no RPI_EFI.fd or start4.elf)")
        for member in archive.infolist():
            target = os.path.realpath(os.path.join(destination, member.filename))
            if not target.startswith(os.path.realpath(destination) + os.sep):
                fail(f"unsafe path in the firmware zip: {member.filename}")
            if member.is_dir():
                os.makedirs(target, exist_ok=True)
                continue
            os.makedirs(os.path.dirname(target), exist_ok=True)
            with archive.open(member) as source, open(target, "wb") as output:
                shutil.copyfileobj(source, output)


def keep_uart_enabled(config_path):
    """The firmware's config.txt has enable_uart=1; it stays as it is then."""
    with open(config_path, newline="") as config:
        lines = config.read().splitlines()
    if any(line.strip() == "enable_uart=1" for line in lines):
        return
    lines = [line for line in lines if not line.strip().startswith("enable_uart=")]
    lines.append("enable_uart=1")
    with open(config_path, "w") as config:
        config.write("\n".join(lines) + "\n")


def system_partition_of(system_image):
    """The first partition of the system image (a GPT disk): offset and size."""
    with open(system_image, "rb") as image:
        image.seek(SECTOR_SIZE)
        header = image.read(92)
        if header[:8] != b"EFI PART":
            fail(f"{system_image} has no GPT partition table")
        entries_lba, _, entry_size = struct.unpack_from("<QII", header, 72)
        image.seek(entries_lba * SECTOR_SIZE)
        entry = image.read(entry_size)
        first_lba, last_lba = struct.unpack_from("<QQ", entry, 32)
    return first_lba * SECTOR_SIZE, (last_lba - first_lba + 1) * SECTOR_SIZE


def copy_tree_into_fat(partition, source_directory):
    for root, directories, files in os.walk(source_directory):
        directories.sort()
        relative = os.path.relpath(root, source_directory)
        for directory in directories:
            target = os.path.normpath(os.path.join(relative, directory)).replace(os.sep, "/")
            run("mmd", "-i", partition, "::/" + target)
        for name in sorted(files):
            target = os.path.normpath(os.path.join(relative, name)).replace(os.sep, "/")
            run("mcopy", "-i", partition, os.path.join(root, name), "::/" + target)


def build_image(arguments, staging_directory):
    boot_sectors = BOOT_PARTITION_MIB * 1024 * 1024 // SECTOR_SIZE
    system_offset = system_size = 0
    if arguments.standalone:
        system_offset, system_size = system_partition_of(arguments.system_image)
    system_sectors = (system_size + SYSTEM_PARTITION_SPARE_MIB * 1024 * 1024) // SECTOR_SIZE if system_size else 0
    second_partition_sector = FIRST_PARTITION_SECTOR + boot_sectors
    total_sectors = second_partition_sector + system_sectors

    image = arguments.output
    if os.path.exists(image):
        os.remove(image)
    with open(image, "wb") as output:
        output.truncate(total_sectors * SECTOR_SIZE)

    layout = "label: dos\n"
    layout += f"start={FIRST_PARTITION_SECTOR}, size={boot_sectors}, type=c, bootable\n"
    if system_sectors:
        layout += f"start={second_partition_sector}, size={system_sectors}, type=83\n"
    run("sfdisk", "--quiet", image, input=layout.encode())

    partition = f"{image}@@{FIRST_PARTITION_SECTOR * SECTOR_SIZE}"
    run("mformat", "-i", partition, "-F", "-T", str(boot_sectors), "-H", str(FIRST_PARTITION_SECTOR),
        "-v", "RPI4BOOT", "::")
    copy_tree_into_fat(partition, staging_directory)

    if system_sectors:
        with open(arguments.system_image, "rb") as source, open(image, "r+b") as output:
            source.seek(system_offset)
            output.seek(second_partition_sector * SECTOR_SIZE)
            remaining = system_size
            while remaining > 0:
                chunk = source.read(min(remaining, 4 * 1024 * 1024))
                if not chunk:
                    break
                output.write(chunk)
                remaining -= len(chunk)
    return total_sectors * SECTOR_SIZE


def compress(image):
    if shutil.which("xz"):
        compressed = image + ".xz"
        with open(compressed, "wb") as output:
            run("xz", "-T0", "-6", "-c", image, stdout=output)
    else:
        compressed = image + ".gz"
        with open(image, "rb") as source, gzip.open(compressed, "wb") as output:
            shutil.copyfileobj(source, output)
    return compressed


def main():
    parser = argparse.ArgumentParser(description="Build a Raspberry Pi 4 SD card image.")
    parser.add_argument("--esp", default="build/arm64/esp", help="the ESP directory of the build")
    parser.add_argument("--output", default="build/arm64/pi-sd.img", help="the image to write")
    parser.add_argument("--firmware", help="the pftf RPi4 UEFI firmware zip")
    parser.add_argument("--server", help="the network boot server's address (default: this machine)")
    parser.add_argument("--port", type=int, default=8000, help="its HTTP port")
    parser.add_argument("--netlog", help="the host the kernel sends its log to (default: the server)")
    parser.add_argument("--standalone", action="store_true",
                        help="hold the system volume too, for booting without a server")
    parser.add_argument("--system-image", default="build/arm64/system-disk.img",
                        help="the system image (--standalone)")
    parser.add_argument("--options", default="", help="more kernel options for options.txt")
    arguments = parser.parse_args()

    for tool in ("sfdisk", "mformat", "mcopy", "mmd"):
        if not shutil.which(tool):
            fail(f"{tool} is needed (util-linux and mtools)")
    loader = os.path.join(arguments.esp, "EFI", "BOOT", "BOOTAA64.EFI")
    kernel = os.path.join(arguments.esp, "FreePascalOS", "kernel.elf")
    if not os.path.isfile(loader) or not os.path.isfile(kernel):
        fail(f"no loader or kernel in {arguments.esp}: build first (make ARCH=arm64)")
    if arguments.standalone and not os.path.isfile(arguments.system_image):
        fail(f"no system image {arguments.system_image}: make ARCH=arm64 system-disk")

    firmware_zip = find_firmware_zip(arguments.firmware)
    server = arguments.server or default_server_address()
    netlog = arguments.netlog or server

    options = []
    if not arguments.standalone:
        options.append(f"netboot=http://{server}:{arguments.port}/")
    options.append(f"netlog={netlog}")
    if arguments.options:
        options.append(arguments.options)

    with tempfile.TemporaryDirectory(prefix="pi-sd-", dir=os.path.dirname(os.path.abspath(arguments.output))) \
            as staging_directory:
        extract_firmware(firmware_zip, staging_directory)
        keep_uart_enabled(os.path.join(staging_directory, "config.txt"))
        os.makedirs(os.path.join(staging_directory, "EFI", "BOOT"), exist_ok=True)
        os.makedirs(os.path.join(staging_directory, "FreePascalOS"), exist_ok=True)
        shutil.copyfile(loader, os.path.join(staging_directory, "EFI", "BOOT", "BOOTAA64.EFI"))
        shutil.copyfile(kernel, os.path.join(staging_directory, "FreePascalOS", "kernel.elf"))
        with open(os.path.join(staging_directory, "FreePascalOS", "options.txt"), "w") as options_file:
            options_file.write("\n".join(options) + "\n")
        size = build_image(arguments, staging_directory)

    compressed = compress(arguments.output)
    print(f"Firmware: {firmware_zip}")
    print(f"Options:  {' '.join(options)}")
    print(f"Image:    {arguments.output} ({size // (1024 * 1024)} MiB), compressed {compressed} "
          f"({os.path.getsize(compressed) // 1024} KiB)")
    print("Flash it (check the card's device name with lsblk first; everything on it is lost):")
    reader = "xzcat" if compressed.endswith(".xz") else "zcat"
    print(f"    {reader} {compressed} | sudo dd of=/dev/sdX bs=4M conv=fsync status=progress")
    if not arguments.standalone:
        print(f"Then run the server here: make pi-netboot-serve (the Pi asks http://{server}:{arguments.port}/)")


if __name__ == "__main__":
    main()
