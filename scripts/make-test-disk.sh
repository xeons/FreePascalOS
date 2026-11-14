#!/usr/bin/env bash
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
    python3 -I "$script_directory/exfat-add-files.py" "$image" "$content" --fragment big.bin
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
done

make_fat   "$work_directory/fat12.img" 8  12 FAT12TEST "$work_directory/content-fat12"
make_fat   "$work_directory/fat16.img" 32 16 FAT16TEST "$work_directory/content-fat16"
make_fat   "$work_directory/fat32.img" 64 32 FAT32TEST "$work_directory/content-fat32"
make_exfat "$work_directory/exfat.img" 32 "$work_directory/content-exfat"
# 1 KiB blocks make big.bin need double indirect blocks on ext2 and ext3.
make_ext   "$work_directory/ext2.img"  16 ext2 EXT2TEST "$work_directory/content-ext2" -b 1024
make_ext   "$work_directory/ext3.img"  16 ext3 EXT3TEST "$work_directory/content-ext3" -b 1024
make_ext   "$work_directory/ext4.img"  32 ext4 EXT4TEST "$work_directory/content-ext4"

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
