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

"""Helpers shared by the Raspberry Pi 5 card scripts: an SD card image
with one FAT32 partition (MBR, type 0Ch), its compressed copy, and this
machine's address on its default route. Needs sfdisk and mtools; no root.
"""

import gzip
import os
import shutil
import socket
import subprocess

SECTOR_SIZE = 512
FIRST_PARTITION_SECTOR = 2048
DEFAULT_PARTITION_MIB = 256


class BootMediaError(Exception):
    pass


def run(*command, **options):
    subprocess.run(command, check=True, **options)


def check_tools():
    for tool in ("sfdisk", "mformat", "mcopy", "mmd"):
        if not shutil.which(tool):
            raise BootMediaError(f"{tool} is needed (util-linux and mtools)")


def default_server_address():
    """This machine's IPv4 address on its default route (nothing is sent)."""
    try:
        probe = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        probe.connect(("192.0.2.1", 9))
        address = probe.getsockname()[0]
        probe.close()
        return address
    except OSError:
        raise BootMediaError("could not find this machine's address; pass SERVER=<address>")


def copy_tree_into_fat(partition, source_directory):
    """Copies a directory tree into the FAT volume, following symbolic links."""
    for root, directories, files in os.walk(source_directory, followlinks=True):
        directories.sort()
        relative = os.path.relpath(root, source_directory)
        for directory in directories:
            target = os.path.normpath(os.path.join(relative, directory)).replace(os.sep, "/")
            run("mmd", "-i", partition, "::/" + target)
        for name in sorted(files):
            target = os.path.normpath(os.path.join(relative, name)).replace(os.sep, "/")
            run("mcopy", "-i", partition, os.path.realpath(os.path.join(root, name)), "::/" + target)


def directory_size(source_directory):
    total = 0
    for root, _, files in os.walk(source_directory, followlinks=True):
        for name in files:
            total += os.path.getsize(os.path.join(root, name))
    return total


def build_fat_card_image(image, source_directory, label, partition_mib=DEFAULT_PARTITION_MIB):
    """Writes an SD card image: an MBR with one bootable FAT32 partition
    (type 0Ch) holding the files of source_directory. Returns its size."""
    needed_mib = directory_size(source_directory) // (1024 * 1024) + 16
    if needed_mib > partition_mib:
        raise BootMediaError(f"the files need {needed_mib} MiB, more than the {partition_mib} MiB partition")
    partition_sectors = partition_mib * 1024 * 1024 // SECTOR_SIZE
    total_sectors = FIRST_PARTITION_SECTOR + partition_sectors

    if os.path.exists(image):
        os.remove(image)
    with open(image, "wb") as output:
        output.truncate(total_sectors * SECTOR_SIZE)

    layout = "label: dos\n"
    layout += f"start={FIRST_PARTITION_SECTOR}, size={partition_sectors}, type=c, bootable\n"
    run("sfdisk", "--quiet", image, input=layout.encode())

    partition = f"{image}@@{FIRST_PARTITION_SECTOR * SECTOR_SIZE}"
    run("mformat", "-i", partition, "-F", "-T", str(partition_sectors), "-H", str(FIRST_PARTITION_SECTOR),
        "-v", label, "::")
    copy_tree_into_fat(partition, source_directory)
    return total_sectors * SECTOR_SIZE


def compress(image):
    """Writes image.xz (or image.gz without xz) and returns its name."""
    if shutil.which("xz"):
        compressed = image + ".xz"
        with open(compressed, "wb") as output:
            run("xz", "-T0", "-6", "-c", image, stdout=output)
    else:
        compressed = image + ".gz"
        with open(image, "rb") as source, gzip.open(compressed, "wb") as output:
            shutil.copyfileobj(source, output)
    return compressed


def flash_instructions(compressed):
    reader = "xzcat" if compressed.endswith(".xz") else "zcat"
    return ("Flash it (check the card's device name with lsblk first; everything on it is lost):\n"
            f"    {reader} {compressed} | sudo dd of=/dev/sdX bs=4M conv=fsync status=progress")
