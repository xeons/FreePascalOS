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

# Checks Clang's freepascalos driver on the host (make clang-driver-test,
# part of make test):
#
#   test-clang-driver.sh <clang>
#
# For x86_64-freepascalos and aarch64-freepascalos: the predefined macros,
# the compiler's command line (triple, position independence, the system
# root's headers, libstdc++'s headers) and the linker's for dynamically
# linked programs, -no-pie, -static, -static-pie, -shared, C++, -pthread and
# -fuse-ld=lld (all with clang -###), the triple-prefixed name
# (<triple>-clang), and, where make c-toolchain built that architecture's
# system root, a real build of a program whose interpreter must be
# /usr/lib/ld.so. Without Clang (make clang-toolchain) it is skipped.

set -uo pipefail

clang="$1"
if [[ ! -x "$clang" ]]; then
    echo "clang-driver-test: no Clang (make clang-toolchain), skipped"
    exit 0
fi
clang_directory=$(cd "$(dirname "$clang")" && pwd)
clang="$clang_directory/clang"
build_directory=$(cd "$clang_directory/../../.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0
checks=0

fail() {
    echo "clang-driver-test: FAILED: $*"
    failures=$((failures + 1))
}

# expect_has <description> <text> <fixed string...>: every string occurs.
expect_has() {
    local description="$1" text="$2" needle
    shift 2
    for needle in "$@"; do
        checks=$((checks + 1))
        grep -qF -- "$needle" <<< "$text" || fail "$description: no '$needle'"
    done
}

# expect_lacks <description> <text> <fixed string...>: none occurs.
expect_lacks() {
    local description="$1" text="$2" needle
    shift 2
    for needle in "$@"; do
        checks=$((checks + 1))
        if grep -qF -- "$needle" <<< "$text"; then
            fail "$description: unexpected '$needle'"
        fi
    done
}

# The command lines clang -### prints (stderr), one job per line, with
# "directory/.." collapsed (the configuration files name the system root
# and the GCC relative to the binary).
jobs_of() {
    "$@" -### 2>&1 | perl -pe '1 while s{/(?!\.\./)[^/"]+/\.\./}{/}'
}

# The linker's line of a link job.
link_line() {
    jobs_of "$@" | grep -E '/(ld|ld\.lld|ld\.bfd)"' | tail -n 1
}

printf 'int main(void) { return 0; }\n' > "$work/program.c"
printf '#include <vector>\nint main() { std::vector<int> v(3); return v.size() - 3; }\n' > "$work/program.cpp"
: > "$work/object.o"

check_architecture() {
    local arch="$1" cpu="$2" emulation="$3"
    local triple="$cpu-freepascalos"
    local target="--target=$triple"
    local sysroot="$build_directory/sysroot/$arch"
    local gcc_prefix="$build_directory/toolchain/$triple"
    local line macros

    # The predefined macros.
    macros=$("$clang" "$target" -E -dM -x c /dev/null 2>&1)
    expect_has "$triple macros" "$macros" "#define __freepascalos__ 1" \
        "#define __unix__ 1" "#define __ELF__ 1" "#define __pie__ 2"
    expect_lacks "$triple macros" "$macros" "__linux__" "_GNU_SOURCE"
    macros=$("$clang" "$target" -E -dM -x c++ /dev/null 2>&1)
    expect_has "$triple C++ macros" "$macros" "#define _GNU_SOURCE 1"
    macros=$("$clang" "$target" -pthread -E -dM -x c /dev/null 2>&1)
    expect_has "$triple -pthread macros" "$macros" "#define _REENTRANT 1"

    # The compiler.
    line=$(jobs_of "$clang" "$target" -c "$work/program.c" -o "$work/program.o")
    expect_has "$triple compile" "$line" "\"-triple\" \"$cpu-unknown-freepascalos\"" \
        "\"-pic-level\" \"2\"" "\"-pic-is-pie\"" \
        "\"-isysroot\" \"$sysroot\"" "\"-internal-externc-isystem\" \"$sysroot/usr/include\""
    if [[ -d "$gcc_prefix/$triple/include/c++" ]]; then
        line=$(jobs_of "$clang" "$target" -c "$work/program.cpp" -o "$work/program.o")
        local version
        version=$(ls "$gcc_prefix/$triple/include/c++" | head -n 1)
        expect_has "$triple C++ compile" "$line" \
            "$triple/$triple/include/c++/$version\"" \
            "$triple/$triple/include/c++/$version/$triple\""
    fi

    # A dynamically linked, position independent program (the default).
    line=$(link_line "$clang" "$target" "$work/object.o" -o "$work/program")
    expect_has "$triple link" "$line" "\"--sysroot=$sysroot\"" "\"-m\" \"$emulation\"" \
        "\"max-page-size=4096\"" "\"--hash-style=both\"" "\"-pie\"" \
        "\"-dynamic-linker\" \"/usr/lib/ld.so\"" "\"--eh-frame-hdr\"" \
        "\"$sysroot/usr/lib/crt1.o\"" "\"$sysroot/usr/lib/crti.o\"" \
        "crtbeginS.o\"" "\"-lgcc\"" "\"-lgcc_s\"" "\"-lc\"" "crtendS.o\"" \
        "\"$sysroot/usr/lib/crtn.o\"" "\"-L$sysroot/usr/lib\""
    expect_lacks "$triple link" "$line" "Scrt1.o" "-lstdc++" "-lpthread" "\"-static\""
    if [[ -d "$gcc_prefix" ]]; then
        expect_has "$triple link" "$line" "\"$gcc_prefix/$triple/bin/ld\"" \
            "$gcc_prefix/lib/gcc/$triple/"
    fi

    line=$(link_line "$clang" "$target" -no-pie "$work/object.o" -o "$work/program")
    expect_has "$triple -no-pie" "$line" "crtbegin.o\"" "crtend.o\"" "\"-dynamic-linker\""
    expect_lacks "$triple -no-pie" "$line" "\"-pie\"" "crtbeginS.o"

    line=$(link_line "$clang" "$target" -static "$work/object.o" -o "$work/program")
    expect_has "$triple -static" "$line" "\"-static\"" "crtbeginT.o\"" "crtend.o\"" \
        "\"--start-group\" \"-lgcc\" \"-lgcc_eh\" \"-lc\" \"--end-group\""
    expect_lacks "$triple -static" "$line" "-dynamic-linker" "-lgcc_s" "\"-pie\""

    line=$(link_line "$clang" "$target" -static-pie "$work/object.o" -o "$work/program")
    expect_has "$triple -static-pie" "$line" "\"-static\" \"-pie\" \"--no-dynamic-linker\"" \
        "crt1.o\"" "crtbeginS.o\"" "crtendS.o\""
    expect_lacks "$triple -static-pie" "$line" "rcrt1.o" "\"-dynamic-linker\""

    line=$(link_line "$clang" "$target" -shared "$work/object.o" -o "$work/library.so")
    expect_has "$triple -shared" "$line" "\"-shared\"" "crtbeginS.o\"" "crtendS.o\""
    expect_lacks "$triple -shared" "$line" "crt1.o" "-dynamic-linker" "\"-pie\""

    line=$(link_line "$clang_directory/clang++" "$target" -pthread "$work/object.o" -o "$work/program")
    expect_has "$triple C++ link" "$line" "\"-lstdc++\" \"-lm\"" "\"-lpthread\" \"-lc\""

    line=$(link_line "$clang" "$target" -fuse-ld=lld "$work/object.o" -o "$work/program")
    expect_has "$triple -fuse-ld=lld" "$line" "ld.lld\"" "\"-dynamic-linker\" \"/usr/lib/ld.so\""

    line=$(link_line "$clang_directory/$triple-clang" "$work/object.o" -o "$work/program")
    expect_has "$triple-clang" "$line" "\"--sysroot=$sysroot\"" "\"-dynamic-linker\" \"/usr/lib/ld.so\""

    # A real program, where the system root and the GCC toolchain exist.
    if [[ -f "$sysroot/usr/lib/libc.so" && -d "$gcc_prefix" ]]; then
        local readelf="$clang_directory/llvm-readelf" header
        for linker in bfd lld; do
            checks=$((checks + 1))
            if ! "$clang" "$target" -fuse-ld=$linker -O2 -o "$work/program-$linker" "$work/program.c" 2> "$work/errors"; then
                fail "$triple: building a program with ld.$linker: $(head -n 5 "$work/errors")"
                continue
            fi
            header=$("$readelf" -lh "$work/program-$linker" 2>&1)
            expect_has "$triple program (ld.$linker)" "$header" "DYN (" \
                "[Requesting program interpreter: /usr/lib/ld.so]"
        done
        if [[ -f "$sysroot/usr/lib/libstdc++.so" ]]; then
            checks=$((checks + 1))
            "$clang_directory/clang++" "$target" -O2 -o "$work/program-cxx" "$work/program.cpp" 2> "$work/errors" ||
                fail "$triple: building a C++ program: $(head -n 5 "$work/errors")"
        fi
    else
        echo "clang-driver-test: no system root for $arch (make c-toolchain ARCH=$arch), only command lines checked"
    fi
}

check_architecture amd64 x86_64 elf_x86_64
check_architecture arm64 aarch64 aarch64linux

if [[ "$failures" -eq 0 ]]; then
    echo "clang-driver-test: all $checks checks passed"
    exit 0
fi
echo "clang-driver-test: $failures of $checks checks FAILED"
exit 1
