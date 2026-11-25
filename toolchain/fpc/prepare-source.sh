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
# Makes the FreePascalOS version of the Free Pascal 3.2.2 sources: a copy
# of the parts of the source tree that are changed or built here, with
# the project's new files laid over it and its patches applied.
#
#   prepare-source.sh <output-directory>
#
# The sources are taken from $FPC_SOURCE (default /usr/lib/fpc/src, the
# fpc-src package, or the official fpc-3.2.2.source tarball unpacked).
#
#   toolchain/fpc/compiler/...   new files (the FreePascalOS target units)
#   toolchain/fpc/patches/*.patch  changes to existing files, applied in
#                                  order with patch -p1 at the root
#
# The output is made again from scratch each time.

set -euo pipefail

if [ $# -ne 1 ]; then
    echo "usage: $0 <output-directory>" >&2
    exit 2
fi

output_directory=$1
toolchain_directory=$(cd "$(dirname "$0")" && pwd)
fpc_source=${FPC_SOURCE:-/usr/lib/fpc/src}

# The parts of the source tree that are copied. The runtime library and
# the packages are compiled straight from $FPC_SOURCE (with the files
# in rtl/fpc in front of them), so only these are needed.
source_parts="compiler packages/fcl-process"

if [ ! -f "$fpc_source/compiler/pp.pas" ]; then
    echo "$0: no compiler sources in $fpc_source (install fpc-src or set FPC_SOURCE)" >&2
    exit 1
fi

rm -rf "$output_directory"
mkdir -p "$output_directory"
for part in $source_parts; do
    mkdir -p "$output_directory/$(dirname "$part")"
    cp -r "$fpc_source/$part" "$output_directory/$part"
done

# New files: every file below toolchain/fpc/<part>.
for part in $source_parts; do
    if [ -d "$toolchain_directory/$part" ]; then
        cp -r "$toolchain_directory/$part/." "$output_directory/$part/"
    fi
done

for patch_file in "$toolchain_directory"/patches/*.patch; do
    patch --quiet --forward -p1 -d "$output_directory" < "$patch_file"
done
