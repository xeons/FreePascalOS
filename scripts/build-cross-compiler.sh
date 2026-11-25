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
# Builds the Free Pascal compiler that compiles for FreePascalOS, from the
# compiler sources with the FreePascalOS patches (toolchain/fpc), with the
# installed (native x86-64) fpc, into the build tree. Nothing is installed.
#
#   build-cross-compiler.sh <target-cpu> <output-file>
#
#   target-cpu   x86_64 or aarch64 (the compiler's name for arm64)
#   output-file  e.g. build/toolchain/ppcx64, build/toolchain/ppcrossa64
#
# The compiler knows every target release 3.2.2 knows (the loader and
# the kernel are still compiled for win64 and linux) and the new
# x86_64-freepascalos and aarch64-freepascalos, which the userland is
# compiled for. The compiler sources are taken from $FPC_SOURCE/compiler
# (default /usr/lib/fpc/src, the fpc-src package). Building takes about
# a minute. The AArch64 compiler of release 3.2.2 has no internal
# assembler: it writes GNU assembly and runs aarch64-linux-gnu-as
# (binutils) on it.

set -euo pipefail

if [ $# -ne 2 ]; then
    echo "usage: $0 <target-cpu> <output-file>" >&2
    exit 2
fi

target_cpu=$1
output_file=$2
host_fpc=${HOST_FPC:-fpc}
script_directory=$(cd "$(dirname "$0")" && pwd)

case $target_cpu in
    x86_64) cpu_family_directory=x86 ;;
    aarch64) cpu_family_directory=aarch64 ;;
    *) echo "$0: target '$target_cpu' is not supported" >&2; exit 2 ;;
esac

output_directory=$(dirname "$output_file")
source_directory=$output_directory/fpc-source-$target_cpu
unit_directory=$output_directory/units-$target_cpu
"$script_directory/../toolchain/fpc/prepare-source.sh" "$source_directory"
compiler_source=$source_directory/compiler
rm -rf "$unit_directory"
mkdir -p "$unit_directory"

# The same switches the compiler's own Makefile uses for a release
# build: -d<cpu> selects the code generator, -dGDB and -dBROWSERLOG the
# debug information writers. The host's fpc.cfg supplies its runtime
# library.
"$host_fpc" -O2 -Xs \
    -Fu"$compiler_source" -Fu"$compiler_source/$target_cpu" -Fu"$compiler_source/$cpu_family_directory" \
    -Fu"$compiler_source/systems" \
    -Fi"$compiler_source" -Fi"$compiler_source/$target_cpu" -Fi"$compiler_source/$cpu_family_directory" \
    -d"$target_cpu" -dGDB -dBROWSERLOG -dRELEASE \
    -FU"$unit_directory" -o"$output_file" \
    "$compiler_source/pp.pas"

echo "built $output_file: Free Pascal $("$output_file" -iV) for $("$output_file" -iTP)"
