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
# Builds a Free Pascal cross compiler from the compiler sources with the
# installed (native x86-64) fpc, into the build tree. Nothing is installed.
#
#   build-cross-compiler.sh <target-cpu> <output-file>
#
#   target-cpu   aarch64 (the compiler's name for arm64)
#   output-file  e.g. build/toolchain/ppcrossa64
#
# The compiler sources are taken from $FPC_SOURCE/compiler (default
# /usr/lib/fpc/src, the fpc-src package). Building takes about a minute.
# The AArch64 compiler of release 3.2.2 has no internal assembler: it
# writes GNU assembly and runs aarch64-linux-gnu-as (binutils) on it.

set -euo pipefail

if [ $# -ne 2 ]; then
    echo "usage: $0 <target-cpu> <output-file>" >&2
    exit 2
fi

target_cpu=$1
output_file=$2
fpc_source=${FPC_SOURCE:-/usr/lib/fpc/src}
compiler_source=$fpc_source/compiler
host_fpc=${HOST_FPC:-fpc}

case $target_cpu in
    aarch64) ;;
    *) echo "$0: target '$target_cpu' is not supported" >&2; exit 2 ;;
esac

if [ ! -f "$compiler_source/pp.pas" ]; then
    echo "$0: no compiler sources in $compiler_source (install fpc-src or set FPC_SOURCE)" >&2
    exit 1
fi

output_directory=$(dirname "$output_file")
unit_directory=$output_directory/units-$target_cpu
mkdir -p "$unit_directory"

# The same switches the compiler's own Makefile uses for a release
# build: -d<cpu> selects the code generator, -dGDB and -dBROWSERLOG the
# debug information writers. The host's fpc.cfg supplies its runtime
# library.
"$host_fpc" -O2 -Xs \
    -Fu"$compiler_source" -Fu"$compiler_source/$target_cpu" -Fu"$compiler_source/systems" \
    -Fi"$compiler_source" -Fi"$compiler_source/$target_cpu" \
    -d"$target_cpu" -dGDB -dBROWSERLOG -dRELEASE \
    -FU"$unit_directory" -o"$output_file" \
    "$compiler_source/pp.pas"

echo "built $output_file: Free Pascal $("$output_file" -iV) for $("$output_file" -iTP)"
