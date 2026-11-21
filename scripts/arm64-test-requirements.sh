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
# Whether the AArch64 tests can run here (make test runs them only
# then): qemu-system-aarch64, the edk2 AArch64 firmware (the paths
# run-qemu-arm64.sh looks in), the cross compiler (make toolchain
# ARCH=arm64) and GNU binutils for AArch64. Exit status 0 if all are
# there; otherwise says what is missing and exits with 1.
#
#   arm64-test-requirements.sh [cross-compiler] [binutils-prefix]

cross_compiler="${1:-build/toolchain/ppcrossa64}"
binutils_prefix="${2:-aarch64-linux-gnu-}"
missing=()

command -v qemu-system-aarch64 > /dev/null || missing+=("qemu-system-aarch64")
firmware_found=""
for candidate in /usr/share/edk2/aarch64/QEMU_EFI.fd /usr/share/AAVMF/AAVMF_CODE.fd \
    /usr/share/qemu-efi-aarch64/QEMU_EFI.fd; do
    [[ -f "$candidate" ]] && firmware_found=yes
done
[[ -n "$firmware_found" ]] || missing+=("the edk2 AArch64 firmware (edk2-aarch64)")
[[ -x "$cross_compiler" ]] || missing+=("the AArch64 cross compiler ($cross_compiler: make toolchain ARCH=arm64)")
command -v "${binutils_prefix}as" > /dev/null || missing+=("${binutils_prefix}as")
command -v "${binutils_prefix}ld" > /dev/null || missing+=("${binutils_prefix}ld")

if [[ ${#missing[@]} -gt 0 ]]; then
    echo "ARM64 TESTS SKIPPED: missing $(IFS=,; echo "${missing[*]}" | sed 's/,/, /g')"
    exit 1
fi
exit 0
