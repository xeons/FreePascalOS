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
Minimal exFAT tool for building and checking test images without root.

exfatprogs can create and check an exFAT file system but cannot put files
on it or read them back without mounting, which needs root. This helper
works on the image directly.

    exfat-tool.py add <image> <source-directory> [--fragment NAME ...]
        Copies a directory tree into a freshly formatted image. Small files
        and directories are stored contiguously ("no FAT chain"); files
        named with --fragment are spread over every other free cluster and
        linked through the FAT, so readers must follow chains.

    exfat-tool.py cat <image> <path>
        Writes the contents of a file to standard output. Names are matched
        ignoring ASCII letter case.
"""

import argparse
import os
import struct
import sys

ENTRY_SIZE = 32
ENTRY_ALLOCATION_BITMAP = 0x81
ENTRY_UPCASE_TABLE = 0x82
ENTRY_FILE = 0x85
ENTRY_STREAM = 0xC0
ENTRY_FILE_NAME = 0xC1

ATTRIBUTE_DIRECTORY = 0x10
ATTRIBUTE_ARCHIVE = 0x20

STREAM_ALLOCATION_POSSIBLE = 0x01
STREAM_NO_FAT_CHAIN = 0x02

END_OF_CHAIN = 0xFFFFFFFF

# 2024-01-02 03:04:06 in exFAT/DOS packed form.
TIMESTAMP = ((2024 - 1980) << 25) | (1 << 21) | (2 << 16) | (3 << 11) | (4 << 5) | 3


class ExFatImage:
    def __init__(self, path):
        self.file = open(path, "r+b")
        boot = self.read(0, 512)
        if boot[3:11] != b"EXFAT   ":
            sys.exit("not an exFAT image")
        self.bytes_per_sector = 1 << boot[108]
        self.bytes_per_cluster = self.bytes_per_sector << boot[109]
        self.fat_offset = struct.unpack_from("<I", boot, 80)[0] * self.bytes_per_sector
        self.heap_offset = struct.unpack_from("<I", boot, 88)[0] * self.bytes_per_sector
        self.cluster_count = struct.unpack_from("<I", boot, 92)[0]
        self.root_cluster = struct.unpack_from("<I", boot, 96)[0]
        self.find_bitmap()

    def read(self, offset, length):
        self.file.seek(offset)
        return self.file.read(length)

    def write(self, offset, data):
        self.file.seek(offset)
        self.file.write(data)

    def cluster_offset(self, cluster):
        return self.heap_offset + (cluster - 2) * self.bytes_per_cluster

    def set_fat(self, cluster, value):
        self.write(self.fat_offset + cluster * 4, struct.pack("<I", value))

    def find_bitmap(self):
        root = self.read(self.cluster_offset(self.root_cluster), self.bytes_per_cluster)
        for position in range(0, len(root), ENTRY_SIZE):
            if root[position] == ENTRY_ALLOCATION_BITMAP:
                first_cluster, length = struct.unpack_from("<IQ", root, position + 20)
                self.bitmap_offset = self.cluster_offset(first_cluster)
                self.bitmap = bytearray(self.read(self.bitmap_offset, length))
                return
        sys.exit("allocation bitmap not found")

    def cluster_is_free(self, cluster):
        index = cluster - 2
        return not (self.bitmap[index // 8] >> (index % 8)) & 1

    def mark_used(self, cluster):
        index = cluster - 2
        self.bitmap[index // 8] |= 1 << (index % 8)

    def allocate_contiguous(self, count):
        run_start, run_length = None, 0
        for cluster in range(2, self.cluster_count + 2):
            if self.cluster_is_free(cluster):
                if run_start is None:
                    run_start = cluster
                run_length += 1
                if run_length == count:
                    for used in range(run_start, run_start + count):
                        self.mark_used(used)
                    return run_start
            else:
                run_start, run_length = None, 0
        sys.exit("out of space")

    def allocate_fragmented(self, count):
        """Takes every other free cluster and links them through the FAT."""
        clusters, skip = [], False
        for cluster in range(2, self.cluster_count + 2):
            if not self.cluster_is_free(cluster):
                continue
            if not skip:
                clusters.append(cluster)
                self.mark_used(cluster)
                if len(clusters) == count:
                    break
            skip = not skip
        if len(clusters) < count:
            sys.exit("out of space")
        for current, following in zip(clusters, clusters[1:]):
            self.set_fat(current, following)
        self.set_fat(clusters[-1], END_OF_CHAIN)
        return clusters

    def flush(self):
        self.write(self.bitmap_offset, bytes(self.bitmap))
        self.file.close()


def entry_set_checksum(entries):
    checksum = 0
    for entry_index, entry in enumerate(entries):
        for byte_index, value in enumerate(entry):
            if entry_index == 0 and byte_index in (2, 3):
                continue
            checksum = ((0x8000 if checksum & 1 else 0) + (checksum >> 1) + value) & 0xFFFF
    return checksum


def name_hash(name):
    checksum = 0
    for value in name.upper().encode("utf-16-le"):
        checksum = ((0x8000 if checksum & 1 else 0) + (checksum >> 1) + value) & 0xFFFF
    return checksum


def build_entry_set(name, attributes, first_cluster, data_length, contiguous):
    units = name.encode("utf-16-le")
    name_length = len(units) // 2
    name_entry_count = (name_length + 14) // 15
    flags = STREAM_ALLOCATION_POSSIBLE | (STREAM_NO_FAT_CHAIN if contiguous else 0)
    if data_length == 0:
        flags, first_cluster = 0, 0

    file_entry = bytearray(ENTRY_SIZE)
    struct.pack_into("<BBHH", file_entry, 0, ENTRY_FILE, 1 + name_entry_count, 0, attributes)
    struct.pack_into("<III", file_entry, 8, TIMESTAMP, TIMESTAMP, TIMESTAMP)

    stream_entry = bytearray(ENTRY_SIZE)
    struct.pack_into("<BBBBH", stream_entry, 0, ENTRY_STREAM, flags, 0, name_length, name_hash(name))
    struct.pack_into("<Q", stream_entry, 8, data_length)
    struct.pack_into("<IQ", stream_entry, 20, first_cluster, data_length)

    entries = [file_entry, stream_entry]
    for part in range(name_entry_count):
        name_entry = bytearray(ENTRY_SIZE)
        name_entry[0] = ENTRY_FILE_NAME
        chunk = units[part * 30:(part + 1) * 30]
        name_entry[2:2 + len(chunk)] = chunk
        entries.append(name_entry)

    struct.pack_into("<H", entries[0], 2, entry_set_checksum(entries))
    return b"".join(entries)


def write_file_data(image, data, fragment):
    if not data:
        return 0, True
    cluster_count = (len(data) + image.bytes_per_cluster - 1) // image.bytes_per_cluster
    if fragment:
        clusters = image.allocate_fragmented(cluster_count)
    else:
        start = image.allocate_contiguous(cluster_count)
        clusters = list(range(start, start + cluster_count))
    for index, cluster in enumerate(clusters):
        chunk = data[index * image.bytes_per_cluster:(index + 1) * image.bytes_per_cluster]
        image.write(image.cluster_offset(cluster), chunk)
    return clusters[0], not fragment


def populate_directory(image, source_path, fragment_names):
    """Writes the contents of source_path and returns the directory's entry bytes."""
    entries = b""
    for name in sorted(os.listdir(source_path)):
        path = os.path.join(source_path, name)
        if os.path.islink(path):
            continue
        if os.path.isdir(path):
            child_entries = populate_directory(image, path, fragment_names)
            # One spare entry slot so the end-of-directory marker always fits.
            size = len(child_entries) + ENTRY_SIZE
            cluster_count = max(1, (size + image.bytes_per_cluster - 1) // image.bytes_per_cluster)
            first_cluster = image.allocate_contiguous(cluster_count)
            data_length = cluster_count * image.bytes_per_cluster
            padded = child_entries + bytes(data_length - len(child_entries))
            image.write(image.cluster_offset(first_cluster), padded)
            entries += build_entry_set(name, ATTRIBUTE_DIRECTORY, first_cluster, data_length, True)
        else:
            with open(path, "rb") as source:
                data = source.read()
            first_cluster, contiguous = write_file_data(image, data, name in fragment_names)
            entries += build_entry_set(name, ATTRIBUTE_ARCHIVE, first_cluster, len(data), contiguous)
    return entries


def append_to_root(image, entries):
    root_offset = image.cluster_offset(image.root_cluster)
    root = image.read(root_offset, image.bytes_per_cluster)
    position = 0
    while position < len(root) and root[position] != 0:
        position += ENTRY_SIZE
    if position + len(entries) + ENTRY_SIZE > image.bytes_per_cluster:
        sys.exit("root directory entries do not fit in one cluster")
    image.write(root_offset + position, entries)


def read_chain(image, first_cluster, length, contiguous):
    """Returns `length` bytes of the data starting at first_cluster."""
    data = bytearray()
    cluster = first_cluster
    while len(data) < length:
        data += image.read(image.cluster_offset(cluster), image.bytes_per_cluster)
        if contiguous:
            cluster += 1
        else:
            cluster = struct.unpack("<I", image.read(image.fat_offset + cluster * 4, 4))[0]
            if cluster >= 0xFFFFFFF7 and len(data) < length:
                sys.exit("cluster chain ends early")
    return bytes(data[:length])


def directory_entries(image, data):
    """Yields (name, attributes, first_cluster, data_length, contiguous)."""
    position = 0
    while position + ENTRY_SIZE <= len(data):
        entry_type = data[position]
        if entry_type == 0:
            return
        if entry_type != ENTRY_FILE:
            position += ENTRY_SIZE
            continue
        secondary_count = data[position + 1]
        attributes = struct.unpack_from("<H", data, position + 4)[0]
        stream = position + ENTRY_SIZE
        flags = data[stream + 1]
        name_length = data[stream + 3]
        first_cluster, data_length = struct.unpack_from("<IQ", data, stream + 20)
        units = b""
        for part in range(2, secondary_count + 1):
            units += data[position + part * ENTRY_SIZE + 2:position + part * ENTRY_SIZE + 32]
        name = units[:name_length * 2].decode("utf-16-le")
        yield name, attributes, first_cluster, data_length, bool(flags & STREAM_NO_FAT_CHAIN)
        position += (1 + secondary_count) * ENTRY_SIZE


def root_directory_data(image):
    data = bytearray()
    cluster = image.root_cluster
    while cluster < 0xFFFFFFF7:
        data += image.read(image.cluster_offset(cluster), image.bytes_per_cluster)
        cluster = struct.unpack("<I", image.read(image.fat_offset + cluster * 4, 4))[0]
    return bytes(data)


def cat_file(image, path):
    directory_data = root_directory_data(image)
    components = [part for part in path.split("/") if part]
    for index, component in enumerate(components):
        for name, attributes, first_cluster, data_length, contiguous in directory_entries(image, directory_data):
            if name.upper() == component.upper():
                break
        else:
            sys.exit(f"not found: {component}")
        contents = read_chain(image, first_cluster, data_length, contiguous) if data_length else b""
        if index == len(components) - 1:
            return contents
        if not attributes & ATTRIBUTE_DIRECTORY:
            sys.exit(f"not a directory: {component}")
        directory_data = contents
    sys.exit("empty path")


def main():
    parser = argparse.ArgumentParser(description=__doc__.strip().splitlines()[0])
    commands = parser.add_subparsers(dest="command", required=True)
    add_command = commands.add_parser("add")
    add_command.add_argument("image")
    add_command.add_argument("source")
    add_command.add_argument("--fragment", action="append", default=[])
    cat_command = commands.add_parser("cat")
    cat_command.add_argument("image")
    cat_command.add_argument("path")
    arguments = parser.parse_args()

    image = ExFatImage(arguments.image)
    if arguments.command == "add":
        entries = populate_directory(image, arguments.source, set(arguments.fragment))
        append_to_root(image, entries)
        image.flush()
    else:
        sys.stdout.buffer.write(cat_file(image, arguments.path))


if __name__ == "__main__":
    main()
