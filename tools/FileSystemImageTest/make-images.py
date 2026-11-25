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

"""Disk images for FileSystemImageTest: small valid ext2, ext4, FAT12,
FAT16, FAT32 and exFAT volumes (the bases the fuzzer damages), and copies
of them with one specific kind of damage each - the shapes of the bugs the
file system audit found.  Writes the images and MANIFEST into the output
folder.

Needs mke2fs, debugfs, mkfs.fat, mtools (mcopy, mmd) and mkfs.exfat, as
scripts/make-test-disk.sh does.

    make-images.py OUTPUT_FOLDER
"""

import os
import shutil
import struct
import subprocess
import sys
import tempfile

MANIFEST = []


def run(*command, stdin=None):
    return subprocess.run(command, check=True, capture_output=True, text=True, input=stdin).stdout


def expect(name, expectation, description):
    MANIFEST.append(f"{name} {expectation} {description}")


def read(path):
    with open(path, "rb") as file:
        return bytearray(file.read())


def write(path, data):
    with open(path, "wb") as file:
        file.write(data)


def variant(output, base, name, change):
    """A copy of image BASE named NAME, with CHANGE(data) applied."""
    data = read(os.path.join(output, base))
    change(data)
    write(os.path.join(output, name), data)


def put16(data, offset, value):
    struct.pack_into("<H", data, offset, value)


def put32(data, offset, value):
    struct.pack_into("<I", data, offset, value)


def get16(data, offset):
    return struct.unpack_from("<H", data, offset)[0]


def get32(data, offset):
    return struct.unpack_from("<I", data, offset)[0]


def make_staging(folder):
    os.makedirs(os.path.join(folder, "docs", "deeper"))
    with open(os.path.join(folder, "readme.txt"), "w") as file:
        file.write("hello from the image test\n")
    with open(os.path.join(folder, "docs", "notes.txt"), "w") as file:
        file.write("notes " * 400)
    with open(os.path.join(folder, "docs", "deeper", "leaf.txt"), "w") as file:
        file.write("leaf\n")
    # Larger files hold zeros, so that what is not zero in an image is
    # mostly metadata: what the fuzzer aims at.
    with open(os.path.join(folder, "victim"), "wb") as file:
        file.write(bytes(80 * 1024))
    with open(os.path.join(folder, "big.bin"), "wb") as file:
        file.write(bytes(300 * 1024))
    os.symlink("readme.txt", os.path.join(folder, "short-link"))
    os.symlink("docs/" + "x" * 90 + "/target", os.path.join(folder, "long-link"))


# --- ext ------------------------------------------------------------------

SUPERBLOCK = 1024


def debugfs(image, request):
    return run("debugfs", "-R", request, image)


def inode_number(image, path):
    for line in debugfs(image, f"stat {path}").splitlines():
        if line.startswith("Inode:"):
            return int(line.split()[1])
    raise RuntimeError(f"no inode for {path}")


def first_block(image, path):
    return int(debugfs(image, f"bmap {path} 0").strip())


def ext_inode_offset(data, number):
    block_size = 1024 << get32(data, SUPERBLOCK + 0x18)
    inodes_per_group = get32(data, SUPERBLOCK + 0x28)
    inode_size = get16(data, SUPERBLOCK + 0x58) if get32(data, SUPERBLOCK + 0x4C) else 128
    group = (number - 1) // inodes_per_group
    first_data_block = get32(data, SUPERBLOCK + 0x14)
    descriptor_size = 32
    if get32(data, SUPERBLOCK + 0x60) & 0x80:  # 64bit
        descriptor_size = max(32, get16(data, SUPERBLOCK + 0xFE))
    descriptor = (first_data_block + 1) * block_size + group * descriptor_size
    table = get32(data, descriptor + 8)
    return table * block_size + ((number - 1) % inodes_per_group) * inode_size


def make_ext(output, staging, name, *options, size_kib):
    image = os.path.join(output, name)
    if os.path.exists(image):
        os.remove(image)
    run("mke2fs", "-q", "-F", "-b", "1024", *options, "-d", staging, image, str(size_kib))
    return image


def ext_images(output, staging):
    # ext2 without the file type feature: names may claim 16-bit lengths.
    ext2 = make_ext(output, staging, "ext2.img", "-t", "ext2", "-O", "^filetype,^dir_index",
                    size_kib=2048)
    expect("ext2.img", "clean", "ext2 without file types, undamaged")
    root_block = first_block(ext2, "/")

    def long_name(data):
        # The last record of the root directory's first block claims a name
        # longer than any name can be (but within its record).
        block = root_block * 1024
        offset = 0
        while True:
            record_length = get16(data, block + offset + 4)
            if offset + record_length >= 1024:
                break
            offset += record_length
        record_length = get16(data, block + offset + 4)
        name_length = min(record_length - 8, 900)
        assert name_length > 255, "the last root record is too short"
        put16(data, block + offset + 6, name_length)
    variant(output, "ext2.img", "ext2-long-name.img", long_name)
    expect("ext2-long-name.img", "corrupted", "a directory record with a 16-bit name length past 255")

    # ext4 with extents, a journal and checksums: the fuzzer's base.
    make_ext(output, staging, "ext4.img", "-t", "ext4", "-J", "size=1", size_kib=8192)
    expect("ext4.img", "clean", "ext4 with journal and metadata checksums, undamaged")
    # The same without checksums, for damage that is not hidden behind them.
    ext4 = make_ext(output, staging, "ext4-plain.img", "-t", "ext4", "-J", "size=1", "-O", "^metadata_csum",
                    size_kib=8192)
    expect("ext4-plain.img", "clean", "ext4 without checksums, undamaged")
    victim = inode_number(ext4, "/victim")
    journal_inode = 8

    def extent_entries(data):
        put16(data, ext_inode_offset(data, victim) + 40 + 2, 0xFFFF)
    variant(output, "ext4-plain.img", "ext4-extent-entries.img", extent_entries)
    expect("ext4-extent-entries.img", "corrupted", "an inode's extent root claims 65535 entries")

    def extent_depth(data):
        put16(data, ext_inode_offset(data, victim) + 40 + 6, 0xFFFF)
    variant(output, "ext4-plain.img", "ext4-extent-depth.img", extent_depth)
    expect("ext4-extent-depth.img", "corrupted", "an inode's extent tree claims depth 65535")

    def orphan_ring(data):
        put32(data, SUPERBLOCK + 0xE8, victim)
        put32(data, ext_inode_offset(data, victim) + 20, victim)
    variant(output, "ext4-plain.img", "ext4-orphan-ring.img", orphan_ring)
    expect("ext4-orphan-ring.img", "clean", "the orphan list comes back to its first inode")

    def orphan_journal(data):
        # Without names, as an orphan to be freed: settling it would free
        # the journal.
        put32(data, SUPERBLOCK + 0xE8, journal_inode)
        put16(data, ext_inode_offset(data, journal_inode) + 26, 0)
    variant(output, "ext4-plain.img", "ext4-orphan-journal.img", orphan_journal)
    expect("ext4-orphan-journal.img", "clean", "the orphan list names the journal inode, without links")

    def superblock_field(offset, value, width=4):
        def change(data):
            if width == 4:
                put32(data, SUPERBLOCK + offset, value)
            else:
                put16(data, SUPERBLOCK + offset, value)
        return change

    for name, offset, value, description in (
            ("blocks-per-group", 0x20, 1024 * 8 * 2, "more blocks per group than a bitmap block holds"),
            ("inodes-per-group-zero", 0x28, 0, "no inodes per group"),
            ("inodes-per-group-big", 0x28, 1024 * 8 + 8, "more inodes per group than a bitmap block holds"),
            ("log-block-size", 0x18, 30, "a block size of 2^40 bytes"),
            ("first-inode", 0x54, 2, "the first ordinary inode is the root"),
            ("inodes-count", 0x00, 0xFFFFFFFF, "more inodes than the groups have"),
            ("blocks-count", 0x04, 0xFFFFFFFF, "more blocks than the device")):
        image_name = f"ext4-{name}.img"
        variant(output, "ext4-plain.img", image_name, superblock_field(offset, value))
        expect(image_name, "refuse", description)


# --- FAT ------------------------------------------------------------------

def fat_geometry(data):
    bytes_per_sector = get16(data, 11)
    sectors_per_cluster = data[13]
    reserved = get16(data, 14)
    fats = data[16]
    root_entries = get16(data, 17)
    fat_size = get16(data, 22) or get32(data, 36)
    root_offset = (reserved + fats * fat_size) * bytes_per_sector
    data_offset = root_offset + root_entries * 32
    return dict(bytes_per_sector=bytes_per_sector, cluster=bytes_per_sector * sectors_per_cluster,
                fat_offset=reserved * bytes_per_sector, fat_size=fat_size * bytes_per_sector, fats=fats,
                root_offset=root_offset, root_entries=root_entries, data_offset=data_offset)


def make_fat(output, staging, name, bits, size_kib, label):
    image = os.path.join(output, name)
    if os.path.exists(image):
        os.remove(image)
    run("mkfs.fat", "-C", "-F", str(bits), "-n", label, image, str(size_kib))
    environment = dict(os.environ, MTOOLS_SKIP_CHECK="1")
    for entry in sorted(os.listdir(staging)):
        source = os.path.join(staging, entry)
        if os.path.islink(source):
            continue
        subprocess.run(["mcopy", "-s", "-i", image, source, "::/" + entry], check=True, env=environment)
    subprocess.run(["mmd", "-i", image, "::/A Long Folder Name"], check=True, env=environment)
    return image


def short_name_checksum(name):
    checksum = 0
    for byte in name:
        checksum = (((checksum & 1) << 7) + (checksum >> 1) + byte) & 0xFF
    return checksum


def long_name_part(ordinal_byte, checksum, text):
    units = [ord(character) for character in text] + [0]
    units += [0xFFFF] * (13 - len(units))
    record = bytearray(32)
    record[0] = ordinal_byte
    for index in range(5):
        put16(record, 1 + 2 * index, units[index])
    record[11] = 0x0F
    record[13] = checksum
    for index in range(6):
        put16(record, 14 + 2 * index, units[5 + index])
    for index in range(2):
        put16(record, 28 + 2 * index, units[11 + index])
    return record


def free_root_slot(data, geometry, count):
    for index in range(geometry["root_entries"] - count):
        offset = geometry["root_offset"] + index * 32
        if data[offset] == 0:
            return offset
    raise RuntimeError("no room in the root directory")


def fat_entry_offset(geometry, bits, cluster):
    if bits == 12:
        return geometry["fat_offset"] + cluster + cluster // 2
    return geometry["fat_offset"] + cluster * (bits // 8)


def set_fat_entry(data, geometry, bits, cluster, value):
    for copy in range(geometry["fats"]):
        offset = fat_entry_offset(geometry, bits, cluster) + copy * geometry["fat_size"]
        if bits == 12:
            pair = get16(data, offset)
            if cluster & 1:
                pair = (pair & 0x000F) | ((value & 0xFFF) << 4)
            else:
                pair = (pair & 0xF000) | (value & 0xFFF)
            put16(data, offset, pair)
        elif bits == 16:
            put16(data, offset, value)
        else:
            put32(data, offset, value)


def find_root_record(data, geometry, short_name):
    for index in range(geometry["root_entries"]):
        offset = geometry["root_offset"] + index * 32
        if bytes(data[offset:offset + 11]) == short_name:
            return offset
    raise RuntimeError(f"no record {short_name!r}")


def fat_images(output, staging):
    make_fat(output, staging, "fat12.img", 12, 1440, "FAT12")
    expect("fat12.img", "clean", "FAT12, undamaged")
    make_fat(output, staging, "fat16.img", 16, 16 * 1024, "FAT16")
    expect("fat16.img", "clean", "FAT16, undamaged")
    make_fat(output, staging, "fat32.img", 32, 40 * 1024, "FAT32")
    expect("fat32.img", "clean", "FAT32, undamaged")

    def ordinal_zero(data):
        # A complete long name followed by one more part numbered 0 with
        # the same checksum, then the short record.
        geometry = fat_geometry(data)
        short_name = b"ZERO    TXT"
        checksum = short_name_checksum(short_name)
        offset = free_root_slot(data, geometry, 3)
        data[offset:offset + 32] = long_name_part(0x41, checksum, "zero.txt")
        data[offset + 32:offset + 64] = long_name_part(0x80, checksum, "overflow")
        short = bytearray(32)
        short[0:11] = short_name
        short[11] = 0x20
        data[offset + 64:offset + 96] = short
    variant(output, "fat12.img", "fat12-ordinal-zero.img", ordinal_zero)
    expect("fat12-ordinal-zero.img", "clean", "a long name part numbered 0 after a complete long name")

    def directory_ring(data):
        # The cluster chain of a folder comes back to itself and holds no
        # end marker.
        geometry = fat_geometry(data)
        record = find_root_record(data, geometry, b"DOCS       ")
        cluster = get16(data, record + 26)
        set_fat_entry(data, geometry, 12, cluster, cluster)
        start = geometry["data_offset"] + (cluster - 2) * geometry["cluster"]
        for offset in range(start + 64, start + geometry["cluster"], 32):
            data[offset] = 0xE5
            data[offset + 11] = 0x20
    variant(output, "fat12.img", "fat12-directory-ring.img", directory_ring)
    expect("fat12-directory-ring.img", "corrupted", "a folder's cluster chain loops with no end marker")

    def file_ring(data):
        geometry = fat_geometry(data)
        record = find_root_record(data, geometry, b"BIG     BIN")
        cluster = get16(data, record + 26)
        set_fat_entry(data, geometry, 12, cluster, cluster)
    variant(output, "fat12.img", "fat12-file-ring.img", file_ring)
    expect("fat12-file-ring.img", "survives", "a file's cluster chain loops")

    def small_fat(data):
        put16(data, 22, 1)
    variant(output, "fat16.img", "fat16-small-fat.img", small_fat)
    expect("fat16-small-fat.img", "refuse", "the FAT is too small for the clusters")

    def active_fat(data):
        put16(data, 40, 0x85)
    variant(output, "fat32.img", "fat32-active-fat.img", active_fat)
    expect("fat32-active-fat.img", "refuse", "the active FAT is number 5 of 2")

    def many_clusters(data):
        put32(data, 32, 0xFFFFFFFF)
    variant(output, "fat32.img", "fat32-many-clusters.img", many_clusters)
    expect("fat32-many-clusters.img", "refuse", "more clusters than FAT32 entries can name")


# --- exFAT ----------------------------------------------------------------

def exfat_geometry(data):
    sector = 1 << data[108]
    cluster = sector << data[109]
    return dict(sector=sector, cluster=cluster, fat_offset=get32(data, 80) * sector,
                heap_offset=get32(data, 88) * sector, cluster_count=get32(data, 92), root=get32(data, 96))


def exfat_cluster_offset(geometry, cluster):
    return geometry["heap_offset"] + (cluster - 2) * geometry["cluster"]


def exfat_set_checksum(entries):
    checksum = 0
    for index, byte in enumerate(entries):
        if index in (2, 3):
            continue
        checksum = (((checksum & 1) << 15) + (checksum >> 1) + byte) & 0xFFFF
    return checksum


def exfat_name_hash(name):
    hash_value = 0
    for character in name.upper():
        unit = ord(character)
        for byte in (unit & 0xFF, unit >> 8):
            hash_value = (((hash_value & 1) << 15) + (hash_value >> 1) + byte) & 0xFFFF
    return hash_value


def exfat_entry_set(name, attributes, first_cluster, length, contiguous=True):
    file_entry = bytearray(32)
    file_entry[0] = 0x85
    name_entries = (len(name) + 14) // 15
    file_entry[1] = 1 + name_entries
    put16(file_entry, 4, attributes)
    stream = bytearray(32)
    stream[0] = 0xC0
    stream[1] = 0x01 | (0x02 if contiguous else 0)
    stream[3] = len(name)
    put16(stream, 4, exfat_name_hash(name))
    struct.pack_into("<Q", stream, 8, length)
    put32(stream, 20, first_cluster)
    struct.pack_into("<Q", stream, 24, length)
    entries = file_entry + stream
    for part in range(name_entries):
        entry = bytearray(32)
        entry[0] = 0xC1
        for index, character in enumerate(name[part * 15:part * 15 + 15]):
            put16(entry, 2 + 2 * index, ord(character))
        entries += entry
    put16(entries, 2, exfat_set_checksum(entries))
    return entries


class ExFatBuilder:
    """Adds files and folders to a freshly made exFAT image."""

    def __init__(self, data):
        self.data = data
        self.geometry = exfat_geometry(data)
        root = exfat_cluster_offset(self.geometry, self.geometry["root"])
        self.bitmap = None
        for offset in range(root, root + self.geometry["cluster"], 32):
            if data[offset] == 0x81:
                self.bitmap = exfat_cluster_offset(self.geometry, get32(data, offset + 20))
        assert self.bitmap is not None

    def take_clusters(self, count):
        """Marks COUNT free clusters in a row allocated; the first one."""
        run_start, run_length = None, 0
        for index in range(self.geometry["cluster_count"]):
            if self.data[self.bitmap + index // 8] & (1 << (index % 8)):
                run_start, run_length = None, 0
                continue
            if run_start is None:
                run_start = index
            run_length += 1
            if run_length == count:
                for taken in range(run_start, run_start + count):
                    self.data[self.bitmap + taken // 8] |= 1 << (taken % 8)
                return run_start + 2
        raise RuntimeError("the exFAT image is full")

    def place(self, directory_cluster, entries):
        start = exfat_cluster_offset(self.geometry, directory_cluster)
        for offset in range(start, start + self.geometry["cluster"] - len(entries), 32):
            if self.data[offset] == 0:
                self.data[offset:offset + len(entries)] = entries
                return offset
        raise RuntimeError("the exFAT folder is full")

    def add_file(self, directory_cluster, name, contents, chained=False):
        count = max(1, (len(contents) + self.geometry["cluster"] - 1) // self.geometry["cluster"])
        first = self.take_clusters(count)
        offset = exfat_cluster_offset(self.geometry, first)
        self.data[offset:offset + len(contents)] = contents
        if chained:
            for cluster in range(first, first + count):
                following = cluster + 1 if cluster + 1 < first + count else 0xFFFFFFFF
                put32(self.data, self.geometry["fat_offset"] + cluster * 4, following)
        return self.place(directory_cluster, exfat_entry_set(name, 0x20, first, len(contents),
                                                             contiguous=not chained))

    def add_folder(self, directory_cluster, name):
        first = self.take_clusters(1)
        offset = exfat_cluster_offset(self.geometry, first)
        self.data[offset:offset + self.geometry["cluster"]] = bytes(self.geometry["cluster"])
        self.place(directory_cluster, exfat_entry_set(name, 0x10, first, self.geometry["cluster"]))
        return first


def exfat_images(output):
    image = os.path.join(output, "exfat.img")
    write(image, bytes(8 * 1024 * 1024))
    run("mkfs.exfat", "-q", "-L", "EXFAT", image)
    data = read(image)
    builder = ExFatBuilder(data)
    root = builder.geometry["root"]
    builder.add_file(root, "readme.txt", b"hello from exFAT\n")
    builder.add_file(root, "chained.bin", bytes(40000), chained=True)
    folder = builder.add_folder(root, "A Long Folder Name")
    builder.add_file(folder, "inside.txt", b"inside\n" * 50)
    write(image, data)
    expect("exfat.img", "clean", "exFAT, undamaged")

    def root_ring(data):
        geometry = exfat_geometry(data)
        root_offset = exfat_cluster_offset(geometry, geometry["root"])
        for offset in range(root_offset, root_offset + geometry["cluster"], 32):
            if data[offset] == 0:
                data[offset] = 0x05
        put32(data, geometry["fat_offset"] + geometry["root"] * 4, geometry["root"])
    variant(output, "exfat.img", "exfat-root-ring.img", root_ring)
    expect("exfat-root-ring.img", "corrupted", "the root folder's chain loops with no end marker")

    def file_ring(data):
        geometry = exfat_geometry(data)
        first = None
        root_offset = exfat_cluster_offset(geometry, geometry["root"])
        for offset in range(root_offset, root_offset + geometry["cluster"], 32):
            if data[offset] == 0xC0 and not data[offset + 1] & 0x02:
                first = get32(data, offset + 20)
        put32(data, geometry["fat_offset"] + first * 4, first)
    variant(output, "exfat.img", "exfat-file-ring.img", file_ring)
    expect("exfat-file-ring.img", "survives", "a file's cluster chain loops")

    def wrapping_file(data):
        geometry = exfat_geometry(data)
        root_offset = exfat_cluster_offset(geometry, geometry["root"])
        for offset in range(root_offset, root_offset + geometry["cluster"], 32):
            if data[offset] == 0xC0 and data[offset + 1] & 0x02:
                put32(data, offset + 20, 0xFFFFFFF0)
                break
        # The set checksum no longer matches: fix it.
        for offset in range(root_offset, root_offset + geometry["cluster"], 32):
            if data[offset] == 0x85:
                count = data[offset + 1] + 1
                entries = data[offset:offset + 32 * count]
                put16(data, offset + 2, exfat_set_checksum(entries))
    variant(output, "exfat.img", "exfat-wrapping-file.img", wrapping_file)
    expect("exfat-wrapping-file.img", "corrupted", "a contiguous file starting at cluster 0xFFFFFFF0")

    def many_clusters(data):
        put32(data, 92, 0xFFFFFFF0)
    variant(output, "exfat.img", "exfat-many-clusters.img", many_clusters)
    expect("exfat-many-clusters.img", "refuse", "more clusters than the device holds")

    def short_bitmap(data):
        geometry = exfat_geometry(data)
        root_offset = exfat_cluster_offset(geometry, geometry["root"])
        for offset in range(root_offset, root_offset + geometry["cluster"], 32):
            if data[offset] == 0x81:
                struct.pack_into("<Q", data, offset + 24, 1)
    variant(output, "exfat.img", "exfat-short-bitmap.img", short_bitmap)
    expect("exfat-short-bitmap.img", "refuse", "an allocation bitmap with fewer bits than clusters")


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    output = sys.argv[1]
    os.makedirs(output, exist_ok=True)
    staging = tempfile.mkdtemp(prefix="fs-image-staging-")
    try:
        make_staging(staging)
        ext_images(output, staging)
        fat_images(output, staging)
        exfat_images(output)
    finally:
        shutil.rmtree(staging)
    with open(os.path.join(output, "MANIFEST"), "w") as file:
        file.write("# Made by tools/FileSystemImageTest/make-images.py\n")
        file.write("\n".join(MANIFEST) + "\n")


if __name__ == "__main__":
    main()
