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
# Builds a GPT disk image containing a single EFI system partition with the
# contents of an ESP directory. The image can be booted in QEMU or written
# to a USB stick (for example with dd) to boot real UEFI hardware.
#
#   make-disk-image.sh <esp-directory> <output-image>
#
# Needs sfdisk (util-linux) and mtools; no root privileges required.

set -euo pipefail

esp_directory="$1"
output_image="$2"

image_size_mebibytes=64
partition_start_sector=2048          # 1 MiB, the usual alignment
sector_size=512
partition_offset_bytes=$((partition_start_sector * sector_size))
efi_system_partition_type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B

rm -f "$output_image"
truncate -s "${image_size_mebibytes}M" "$output_image"

sfdisk --quiet "$output_image" <<EOF
label: gpt
start=${partition_start_sector}, type=${efi_system_partition_type}, name="EFI System"
EOF

# mtools addresses the partition through the "@@offset" image suffix.
partition="${output_image}@@${partition_offset_bytes}"
mformat -i "$partition" -F -v FPOS ::

# Recreate the directory tree, then copy every file.
(cd "$esp_directory" && find . -mindepth 1 -type d | sort) | while read -r directory; do
    mmd -i "$partition" "::/${directory#./}"
done
(cd "$esp_directory" && find . -type f | sort) | while read -r file; do
    mcopy -i "$partition" "$esp_directory/${file#./}" "::/${file#./}"
done

echo "Wrote $output_image (${image_size_mebibytes} MiB, GPT with one EFI system partition)"
