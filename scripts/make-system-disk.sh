#!/usr/bin/env bash
#
# Builds the system volume: an ext4 file system labelled FPOSROOT that the
# kernel uses as "/" for user programs.
#
#   make-system-disk.sh <user-build-directory> <output-image>
#
# Layout:
#   /bin   programs (from <user-build-directory>/bin)
#   /lib   shared libraries (from <user-build-directory>/lib)
#   /etc   configuration (from userland/etc)
#   /tmp, /home
#
# The image is a whole disk with a GPT partition table and one partition,
# populated with mke2fs -d, so no root privileges are needed.

set -euo pipefail

user_build_directory="$1"
output_image="$2"
image_size_mib=64
partition_start_sector=2048

script_directory=$(dirname "$0")
source_directory=$(cd "$script_directory/.." && pwd)
staging_directory="$user_build_directory/root"
partition_image="$output_image.partition"

rm -rf "$staging_directory"
mkdir -p "$staging_directory"/{bin,lib,etc,tmp,home}
cp "$user_build_directory"/bin/* "$staging_directory/bin/"
cp "$user_build_directory"/lib/*.so "$staging_directory/lib/"
if compgen -G "$source_directory/userland/etc/*" > /dev/null; then
    cp -r "$source_directory"/userland/etc/* "$staging_directory/etc/"
fi
# Programs that behave differently by the name they are started as:
# "[" is test, chgrp is chown, dir and vdir are ls, unexpand is expand.
copy_program() {
    if [[ -f "$staging_directory/bin/$1" ]]; then
        cp "$staging_directory/bin/$1" "$staging_directory/bin/$2"
    fi
}
copy_program test "["
copy_program chown chgrp
copy_program ls dir
copy_program ls vdir
copy_program expand unexpand

partition_size_mib=$((image_size_mib - 2))
rm -f "$partition_image"
mke2fs -q -t ext4 -L FPOSROOT -d "$staging_directory" -E root_owner=0:0 \
    "$partition_image" "${partition_size_mib}M"

rm -f "$output_image"
truncate -s "${image_size_mib}M" "$output_image"
printf 'label: gpt\nstart=%d, size=%dMiB, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, name=FPOSROOT\n' \
    "$partition_start_sector" "$partition_size_mib" | sfdisk --quiet "$output_image"
dd if="$partition_image" of="$output_image" bs=512 seek=$partition_start_sector \
    conv=notrunc status=none
rm -f "$partition_image"
echo "System disk: $output_image"
