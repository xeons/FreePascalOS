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
# Builds the system volume: an ext4 file system labelled FPOSROOT that the
# kernel uses as "/" for user programs.
#
#   make-system-disk.sh <user-build-directory> <output-image>
#
# Layout:
#   /bin   programs (from <user-build-directory>/bin)
#   /lib   shared libraries (from <user-build-directory>/lib)
#   /etc   configuration (from userland/etc), with the service
#          definitions in /etc/services and the system's settings in
#          /etc/settings (empty: programs keep what root changes there)
#   /var/log  the services' logs (the service manager writes them)
#   /lib/fonts, /lib/pointers   the fonts and the pointer's shapes
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
mkdir -p "$staging_directory"/{bin,lib,etc,etc/settings,tmp,dev,home/user,var/log}
cp "$user_build_directory"/bin/* "$staging_directory/bin/"
cp "$user_build_directory"/lib/*.so "$staging_directory/lib/"
# The fonts graphical programs draw with (libfont).
if [[ -d "$user_build_directory/fonts" ]]; then
    mkdir -p "$staging_directory/lib/fonts"
    cp -r "$user_build_directory"/fonts/* "$staging_directory/lib/fonts/"
fi
# The pointer's shapes, which the display server reads (it has built-in
# ones for any that are missing).
if compgen -G "$source_directory/userland/pointers/*.pointer" > /dev/null; then
    mkdir -p "$staging_directory/lib/pointers"
    cp "$source_directory"/userland/pointers/*.pointer "$staging_directory/lib/pointers/"
fi
if compgen -G "$source_directory/userland/etc/*" > /dev/null; then
    cp -r "$source_directory"/userland/etc/* "$staging_directory/etc/"
fi
# Programs that behave differently by the name they are started as:
# "[" is test, chgrp is chown, dir and vdir are ls, unexpand is expand,
# egrep and fgrep are grep, more is less.
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
copy_program grep egrep
copy_program grep fgrep
copy_program less more
copy_program pgrep pkill

partition_size_mib=$((image_size_mib - 2))
rm -f "$partition_image"
mke2fs -q -t ext4 -L FPOSROOT -d "$staging_directory" -E root_owner=0:0 \
    "$partition_image" "${partition_size_mib}M"

# mke2fs -d copies the building user's ids: everything belongs to root,
# except the home of "user". /tmp is world writable (sticky), the
# password file readable by root only, and su and passwd run as root.
ownership_script="$partition_image.debugfs"
{
    (cd "$staging_directory" && find . -mindepth 1) | while read -r path; do
        echo "set_inode_field \"${path#.}\" uid 0"
        echo "set_inode_field \"${path#.}\" gid 0"
    done
    echo 'set_inode_field /home/user uid 1000'
    echo 'set_inode_field /home/user gid 1000'
    echo 'set_inode_field /home/user mode 040755'
    echo 'set_inode_field /tmp mode 041777'
    echo 'set_inode_field /etc/settings mode 040755'
    echo 'set_inode_field /etc/shadow mode 0100600'
    echo 'set_inode_field /bin/su mode 0104755'
    echo 'set_inode_field /bin/passwd mode 0104755'
} > "$ownership_script"
debugfs -w -f "$ownership_script" "$partition_image" > /dev/null 2>&1
rm -f "$ownership_script"

rm -f "$output_image"
truncate -s "${image_size_mib}M" "$output_image"
printf 'label: gpt\nstart=%d, size=%dMiB, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, name=FPOSROOT\n' \
    "$partition_start_sector" "$partition_size_mib" | sfdisk --quiet "$output_image"
dd if="$partition_image" of="$output_image" bs=512 seek=$partition_start_sector \
    conv=notrunc status=none
rm -f "$partition_image"
echo "System disk: $output_image"
