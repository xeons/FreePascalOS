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

# Builds Clang and lld with the FreePascalOS targets (make clang-toolchain):
#
#   toolchain/build-clang.sh [STEP...]
#
# Fetches the official llvm-project source release (into $FPOS_SOURCES,
# by default ~/Downloads/sources), checks it against the checksum below,
# applies toolchain/patches/llvm-<version> (the freepascalos OS in LLVM's
# target triple, Clang's target information and its driver) and builds,
# for both x86_64-freepascalos and aarch64-freepascalos:
#
#   build/toolchain/llvm/bin/clang, clang++, ld.lld, llvm-ar, ...
#   build/toolchain/llvm/bin/<triple>.cfg    --sysroot and --gcc-toolchain
#                                            for that target
#   build/toolchain/llvm/bin/<triple>-clang, <triple>-clang++
#
# so that `clang --target=x86_64-freepascalos` (or x86_64-freepascalos-clang)
# compiles and links against the system root of make c-toolchain
# (build/sysroot/<arch>: mlibc) with libgcc and libstdc++ from the GCC
# cross compiler (build/toolchain/<triple>), linking with that toolchain's
# GNU ld; -fuse-ld=lld links with ld.lld instead. One build serves both
# architectures.
#
# The steps (each remembered by a stamp; name steps to run only those):
#
#   fetch      download and verify the archive
#   unpack     unpack and patch it under build/toolchain/src
#   configure  CMake (Ninja, release build, X86 and AArch64 back ends)
#   build      build and install clang, lld and the binary utilities
#   targets    the configuration files and triple-prefixed names
#
# Needs CMake, Ninja, Python 3 and a host C++ compiler. Nothing is
# installed outside build/. The sources are never committed.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCES="${FPOS_SOURCES:-$HOME/Downloads/sources}"
BUILD="$ROOT/build"
PREFIX="$BUILD/toolchain/llvm"
SRC="$BUILD/toolchain/src"
WORK="$BUILD/toolchain/work/llvm"
STAMPS="$WORK/stamps"
JOBS="${JOBS:-$(nproc)}"
# Linking clang takes a few GiB per job.
LINK_JOBS="${LINK_JOBS:-2}"

LLVM_VERSION=23.1.6
LLVM=llvm-project-$LLVM_VERSION.src
LLVM_ARCHIVE="$LLVM.tar.xz"
LLVM_URL="https://github.com/llvm/llvm-project/releases/download/llvmorg-$LLVM_VERSION/$LLVM_ARCHIVE"
LLVM_SHA256=d3b86ab29cfb4445a6652e5c2642ccc75e04e38084dde3701d323320f35a31da
PATCHES="llvm-$LLVM_VERSION"

# The programs installed into build/toolchain/llvm/bin.
INSTALL_TARGETS=(install-clang install-clang-resource-headers install-lld
  install-llvm-ar install-llvm-ranlib install-llvm-nm install-llvm-objdump
  install-llvm-objcopy install-llvm-strip install-llvm-readobj
  install-llvm-readelf install-llvm-size)

ALL_STEPS=(fetch unpack configure build targets)

log() { echo "build-clang: $*"; }
done_step() { [ -f "$STAMPS/$1" ]; }
mark_step() { mkdir -p "$STAMPS"; touch "$STAMPS/$1"; }

require_tool() {
  command -v "$1" > /dev/null ||
    { echo "build-clang: $1 is needed to build Clang (not found)" >&2; exit 1; }
}

step_fetch() {
  mkdir -p "$SOURCES"
  if [ ! -f "$SOURCES/$LLVM_ARCHIVE" ]; then
    log "downloading $LLVM_ARCHIVE"
    curl -fL --retry 3 -o "$SOURCES/$LLVM_ARCHIVE.part" "$LLVM_URL"
    mv "$SOURCES/$LLVM_ARCHIVE.part" "$SOURCES/$LLVM_ARCHIVE"
  fi
  echo "$LLVM_SHA256  $SOURCES/$LLVM_ARCHIVE" | sha256sum --check --quiet - ||
    { echo "build-clang: $LLVM_ARCHIVE does not match its checksum" >&2; exit 1; }
}

patches_checksum() {
  cat "$ROOT/toolchain/patches/$PATCHES"/*.patch | sha256sum | cut -d ' ' -f 1
}

# The tree is unpacked again whenever the patches change, so it always
# matches the repository (the build directory then rebuilds what changed).
step_unpack() {
  mkdir -p "$SRC"
  if [ -f "$SRC/.patched-$LLVM" ] && [ "$(cat "$SRC/.patched-$LLVM")" = "$(patches_checksum)" ]; then
    return
  fi
  rm -rf "$SRC/$LLVM"
  log "unpacking $LLVM_ARCHIVE"
  tar -xf "$SOURCES/$LLVM_ARCHIVE" -C "$SRC"
  local patch_file
  for patch_file in "$ROOT/toolchain/patches/$PATCHES"/*.patch; do
    log "patching $LLVM with $(basename "$patch_file")"
    patch -d "$SRC/$LLVM" -p1 --forward --silent < "$patch_file"
  done
  patches_checksum > "$SRC/.patched-$LLVM"
}

step_configure() {
  require_tool cmake
  require_tool ninja
  require_tool python3
  local linker_options=()
  # gold (or lld) links LLVM faster and with less memory than ld.bfd.
  if command -v ld.lld > /dev/null; then
    linker_options=(-DLLVM_USE_LINKER=lld)
  elif command -v ld.gold > /dev/null; then
    linker_options=(-DLLVM_USE_LINKER=gold)
  fi
  cmake -G Ninja -S "$SRC/$LLVM/llvm" -B "$WORK/build" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$PREFIX" \
    -DLLVM_ENABLE_PROJECTS="clang;lld" \
    -DLLVM_TARGETS_TO_BUILD="X86;AArch64" \
    -DLLVM_ENABLE_ASSERTIONS=OFF \
    -DLLVM_INCLUDE_TESTS=OFF -DLLVM_INCLUDE_EXAMPLES=OFF \
    -DLLVM_INCLUDE_BENCHMARKS=OFF -DLLVM_INCLUDE_DOCS=OFF \
    -DCLANG_INCLUDE_TESTS=OFF -DCLANG_INCLUDE_DOCS=OFF \
    -DCLANG_ENABLE_STATIC_ANALYZER=OFF -DCLANG_ENABLE_ARCMT=OFF \
    -DLLVM_ENABLE_BINDINGS=OFF -DLLVM_ENABLE_LIBXML2=OFF \
    -DLLVM_ENABLE_ZSTD=OFF -DLLVM_ENABLE_TERMINFO=OFF \
    -DLLVM_PARALLEL_LINK_JOBS="$LINK_JOBS" \
    -DLLVM_APPEND_VC_REV=OFF \
    "${linker_options[@]}"
}

step_build() {
  ninja -C "$WORK/build" -j "$JOBS" "${INSTALL_TARGETS[@]}"
  # install-clang installs clang alone on some configurations.
  ln -sfn clang "$PREFIX/bin/clang++"
}

# <triple>.cfg is read by `clang --target=<triple>` (the normalized
# triple, x86_64-unknown-freepascalos) and by <triple>-clang (the triple as
# written); both name the same file. Paths are relative to the file
# (<CFGDIR>), so the build tree can move.
write_target_files() {
  local arch="$1" cpu="$2" triple="$2-freepascalos"
  cat > "$PREFIX/bin/$triple.cfg" <<EOF
# FreePascalOS $arch: mlibc's system root (make c-toolchain) and the GCC
# cross compiler beside it (libgcc, libstdc++, crtbegin/crtend, GNU ld).
--sysroot=<CFGDIR>/../../../sysroot/$arch
--gcc-toolchain=<CFGDIR>/../../$triple
EOF
  ln -sfn "$triple.cfg" "$PREFIX/bin/$cpu-unknown-freepascalos.cfg"
  ln -sfn clang "$PREFIX/bin/$triple-clang"
  ln -sfn clang "$PREFIX/bin/$triple-clang++"
}

step_targets() {
  write_target_files amd64 x86_64
  write_target_files arm64 aarch64
}

run_step() {
  local step="$1" function="step_${1//-/_}"
  log "step $step"
  "$function"
  mark_step "$step"
}

mkdir -p "$WORK"
if [ "$#" -gt 0 ]; then
  for step in "$@"; do run_step "$step"; done
else
  for step in "${ALL_STEPS[@]}"; do
    # fetch and unpack check the archive and the patches every time; the
    # build runs again when the patches changed.
    if [ "$step" = fetch ] || [ "$step" = unpack ] || ! done_step "$step" ||
       [ "$SRC/.patched-$LLVM" -nt "$STAMPS/$step" ]; then
      run_step "$step"
    fi
  done
fi
log "done: $PREFIX/bin/clang --target=x86_64-freepascalos | aarch64-freepascalos"
