#!/usr/bin/env bash
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
# Builds a GPT disk image with one partition per supported file system,
# all holding the same test files, for the kernel's file system self test.
#
#   make-test-disk.sh <output-image>
#
# Partitions:   1 fat12   2 fat16   3 fat32   4 exfat   5 ext2   6 ext3   7 ext4
#
# Every partition contains:
#   fstype.txt                          the expected file system type name
#   hello.txt                           a short known text
#   A long file name with spaces.txt    tests long names
#   docs/nested/deep.txt                tests nested directories
#   big.bin                             300 KiB, byte N = N mod 251
#
# The ext partitions also contain:
#   sparse.bin                          1 MiB with holes, data blocks of 'D'
#   link-to-hello                       relative symbolic link
#   docs/up-link                        symbolic link using ".."
#   absolute-link                       absolute symbolic link (volume relative)
#
# The ext3 and ext4 partitions are left needing journal recovery: their
# journals hold committed transactions (written with debugfs; plain on
# ext3, with v3 checksums and 64-bit block numbers on ext4) that the
# kernel must replay when it mounts them:
#   journal-replay.txt                  "journal: not replayed", replayed to
#                                       "journal: was replayed"
#   journal-revoked.txt                 "revoked: untouched"; its block is logged
#                                       with garbage, then revoked
#   journal-escaped.txt                 replayed with a block that starts with
#                                       the journal's magic number (escaped in
#                                       the log)
# They also come with an orphan (a file removed while open when the system
# went down): an inode without names on the superblock's orphan list,
# which the kernel frees when it mounts them.
#
# Needs: sfdisk, mkfs.fat, mtools, mkfs.exfat, mke2fs, python3.

set -euo pipefail

output_image="$1"
script_directory=$(cd "$(dirname "$0")" && pwd)
work_directory=$(dirname "$output_image")/test-disk-work
rm -rf "$work_directory"
mkdir -p "$work_directory"

# Size of each partition in MiB, in partition order.
partition_names=(fat12 fat16 fat32 exfat ext2 ext3 ext4)
partition_sizes=(8 32 64 32 16 16 32)

create_common_content() {
    local directory="$1"
    mkdir -p "$directory/docs/nested"
    printf 'Hello from FreePascalOS!\n' > "$directory/hello.txt"
    printf 'Long file names work.\n' > "$directory/A long file name with spaces.txt"
    printf 'Found the deep file.\n' > "$directory/docs/nested/deep.txt"
    python3 -c 'import sys; sys.stdout.buffer.write(bytes(i % 251 for i in range(300 * 1024)))' \
        > "$directory/big.bin"
}

create_ext_extras() {
    local directory="$1"
    # 1 MiB file with 4 KiB of data every 64 KiB and holes in between.
    python3 - "$directory/sparse.bin" <<'EOF'
import sys
with open(sys.argv[1], "wb") as sparse:
    for region in range(16):
        sparse.seek(region * 65536)
        sparse.write(b"D" * 4096)
    sparse.truncate(1024 * 1024)
EOF
    ln -s hello.txt "$directory/link-to-hello"
    ln -s ../hello.txt "$directory/docs/up-link"
    ln -s /docs/nested/deep.txt "$directory/absolute-link"
}

create_journal_files() {
    local directory="$1"
    printf 'journal: not replayed\n' > "$directory/journal-replay.txt"
    printf 'revoked: untouched\n' > "$directory/journal-revoked.txt"
    printf 'not escaped yet\n' > "$directory/journal-escaped.txt"
    head -c 40000 /dev/zero | tr '\0' 'o' > "$directory/orphan.bin"
}

# Turns orphan.bin into an orphan: no name, no links, first on the list.
make_orphan() {
    local image="$1" inode
    inode=$(debugfs -R "stat /orphan.bin" "$image" 2>/dev/null | sed -n 's/^Inode: \([0-9]*\).*/\1/p')
    debugfs -w -f - "$image" > /dev/null 2>&1 <<COMMANDS
unlink /orphan.bin
sif <$inode> links_count 0
sif <$inode> dtime 0
ssv last_orphan $inode
COMMANDS
}

# Leaves committed transactions in the journal of an ext image: the
# replayed, revoked and escaped blocks described above.
write_dirty_journal() {
    local image="$1" open_options="$2" block_size replay_block revoked_block escaped_block
    block_size=$(dumpe2fs -h "$image" 2>/dev/null | sed -n 's/^Block size: *//p')
    replay_block=$(debugfs -R "bmap /journal-replay.txt 0" "$image" 2>/dev/null)
    revoked_block=$(debugfs -R "bmap /journal-revoked.txt 0" "$image" 2>/dev/null)
    escaped_block=$(debugfs -R "bmap /journal-escaped.txt 0" "$image" 2>/dev/null)
    python3 - "$work_directory" "$block_size" <<'EOF'
import sys
directory, size = sys.argv[1], int(sys.argv[2])
def block(data):
    return data + bytes(size - len(data))
open(f"{directory}/replayed.blk", "wb").write(block(b"journal: was replayed\n"))
open(f"{directory}/garbage.blk", "wb").write(bytes([0x47]) * size)
open(f"{directory}/escaped.blk", "wb").write(block(bytes([0xC0, 0x3B, 0x39, 0x98]) + b"journal esc\n"))
EOF
    debugfs -w -f - "$image" > /dev/null 2>&1 <<COMMANDS
jo $open_options
jw -b $replay_block $work_directory/replayed.blk
jw -b $revoked_block $work_directory/garbage.blk
jw -b $escaped_block $work_directory/escaped.blk
jw -r $revoked_block
jc
COMMANDS
    if ! dumpe2fs -h "$image" 2>/dev/null | grep -q needs_recovery; then
        echo "could not leave a dirty journal in $image" >&2
        exit 1
    fi
}

make_fat() {
    local image="$1" size="$2" fat_bits="$3" label="$4" content="$5"
    rm -f "$image"
    mkfs.fat -C -F "$fat_bits" -n "$label" "$image" $((size * 1024)) > /dev/null
    mcopy -i "$image" -s "$content"/* ::/
}

make_exfat() {
    local image="$1" size="$2" content="$3"
    rm -f "$image"
    truncate -s "${size}M" "$image"
    mkfs.exfat -q -L EXFATTEST "$image" > /dev/null
    python3 -I "$script_directory/exfat-tool.py" add "$image" "$content" --fragment big.bin
}

make_ext() {
    local image="$1" size="$2" type="$3" label="$4" content="$5"
    shift 5
    rm -f "$image"
    mke2fs -q -F -t "$type" -L "$label" -d "$content" "$@" "$image" "${size}M"
}

for index in "${!partition_names[@]}"; do
    name=${partition_names[$index]}
    content="$work_directory/content-$name"
    create_common_content "$content"
    printf '%s\n' "$name" > "$content/fstype.txt"
    case "$name" in
        ext*) create_ext_extras "$content" ;;
    esac
    case "$name" in
        ext3|ext4) create_journal_files "$content" ;;
    esac
done

make_fat   "$work_directory/fat12.img" 8  12 FAT12TEST "$work_directory/content-fat12"
make_fat   "$work_directory/fat16.img" 32 16 FAT16TEST "$work_directory/content-fat16"
make_fat   "$work_directory/fat32.img" 64 32 FAT32TEST "$work_directory/content-fat32"
make_exfat "$work_directory/exfat.img" 32 "$work_directory/content-exfat"
# 1 KiB blocks make big.bin need double indirect blocks on ext2 and ext3.
make_ext   "$work_directory/ext2.img"  16 ext2 EXT2TEST "$work_directory/content-ext2" -b 1024
make_ext   "$work_directory/ext3.img"  16 ext3 EXT3TEST "$work_directory/content-ext3" -b 1024
make_ext   "$work_directory/ext4.img"  32 ext4 EXT4TEST "$work_directory/content-ext4"
make_orphan "$work_directory/ext3.img"
make_orphan "$work_directory/ext4.img"
write_dirty_journal "$work_directory/ext3.img" ""
write_dirty_journal "$work_directory/ext4.img" "-c"

fsck.exfat -n "$work_directory/exfat.img" > /dev/null

# Lay the partitions out back to back, starting at 1 MiB.
total_mebibytes=2
for size in "${partition_sizes[@]}"; do
    total_mebibytes=$((total_mebibytes + size))
done
rm -f "$output_image"
truncate -s "${total_mebibytes}M" "$output_image"

{
    echo "label: gpt"
    for index in "${!partition_names[@]}"; do
        echo "size=${partition_sizes[$index]}MiB, type=EBD0A0A2-B9E5-4433-87C0-68B6B72699C7, name=\"${partition_names[$index]}\""
    done
} | sfdisk --quiet "$output_image"

offset_mebibytes=1
for index in "${!partition_names[@]}"; do
    dd if="$work_directory/${partition_names[$index]}.img" of="$output_image" \
        bs=1M seek="$offset_mebibytes" conv=notrunc status=none
    offset_mebibytes=$((offset_mebibytes + partition_sizes[index]))
done

echo "Wrote $output_image (${total_mebibytes} MiB, partitions: ${partition_names[*]})"

# A second disk for the virtio block driver: one partition holding a copy
# of the ext4 partition (dirty journal and orphan included).
virtio_image="${output_image%.img}-virtio.img"
rm -f "$virtio_image"
truncate -s 34M "$virtio_image"
echo 'label: gpt
size=32MiB, type=EBD0A0A2-B9E5-4433-87C0-68B6B72699C7, name="ext4"' | sfdisk --quiet "$virtio_image"
dd if="$work_directory/ext4.img" of="$virtio_image" bs=1M seek=1 conv=notrunc status=none
echo "Wrote $virtio_image (34 MiB, partition: ext4)"
