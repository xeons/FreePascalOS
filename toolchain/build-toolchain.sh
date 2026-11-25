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

# Builds the C and C++ cross toolchain for FreePascalOS:
#
#   toolchain/build-toolchain.sh [amd64|arm64] [STEP...]
#
# Fetches the official source releases (into $FPOS_SOURCES, by default
# ~/Downloads/sources), checks them against the checksums below, applies
# the patches in toolchain/patches/ and builds, for the triplet
# x86_64-freepascalos or aarch64-freepascalos:
#
#   build/toolchain/<triplet>/bin/<triplet>-gcc, -g++, -as, -ld, ...
#   build/sysroot/<arch>/usr/include    mlibc's headers
#   build/sysroot/<arch>/usr/lib        crt1.o crti.o crtn.o, libc.so,
#                                       libc.a, ld.so, libm, libpthread...,
#                                       libgcc_s.so, libstdc++.so/.a
#
# The steps, in order (each remembered by a stamp, so a second run
# continues where the first stopped; name steps to run only those):
#
#   fetch          download and verify the archives
#   unpack         unpack and patch them under build/toolchain/src
#   binutils       as, ld, ar, objdump, ...
#   mlibc-headers  mlibc's headers into the sysroot
#   gcc            the compilers alone (stage 1: no C library yet)
#   libgcc-static  libgcc.a alone, which mlibc links with
#   mlibc          mlibc (ld.so, libc.so, libc.a, crt files)
#   libgcc         all of libgcc: libgcc_eh.a, libgcc_s.so, crtbegin/crtend
#   libstdcxx      libstdc++ (stage 2: C++ against mlibc)
#
# Nothing is installed outside build/. The sources are never committed.

set -euo pipefail

ARCH="${1:-amd64}"
shift || true

case "$ARCH" in
  amd64) CPU=x86_64 ;;
  arm64) CPU=aarch64 ;;
  *) echo "build-toolchain: unknown architecture '$ARCH' (amd64 or arm64)" >&2; exit 2 ;;
esac

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TRIPLET="$CPU-freepascalos"
SOURCES="${FPOS_SOURCES:-$HOME/Downloads/sources}"
BUILD="$ROOT/build"
PREFIX="$BUILD/toolchain/$TRIPLET"
SYSROOT="$BUILD/sysroot/$ARCH"
SRC="$BUILD/toolchain/src"
WORK="$BUILD/toolchain/work/$TRIPLET"
STAMPS="$WORK/stamps"
JOBS="${JOBS:-$(nproc)}"

BINUTILS=binutils-2.47
GCC=gcc-16.2.0
GMP=gmp-6.3.0
MPFR=mpfr-4.2.2
MPC=mpc-1.3.1
MLIBC=mlibc-7.0.0
FRIGG=frigg-b0dbea66bc19f7c5546f0039a3be842feb02678c
LIBSMARTER=libsmarter-f7d061bc37d485418344452c7ceb28d5df3ba85d
FREESTND_CXX=freestnd-cxx-hdrs-a6b351e0ab3e74e5789b01fa1447e4cd62373da7

GNU_MIRROR="${GNU_MIRROR:-https://ftp.gnu.org/gnu}"
CODE_HOST="https://github.com"

# archive file, URL, SHA-256. The GNU archives were checked against
# their maintainers' signatures (gnu-keyring.gpg) when these sums were
# taken; the others are tagged releases or pinned commits of mlibc and
# of the subprojects its meson files pin.
ARCHIVES=(
  "$BINUTILS.tar.xz|$GNU_MIRROR/binutils/$BINUTILS.tar.xz|154ab23b60070e8f27013c22977f1129425d67d1e8acd6e13010e617811e4cff"
  "$GCC.tar.xz|$GNU_MIRROR/gcc/$GCC/$GCC.tar.xz|e6738e29597f733270731aa90600f37ffdc045079dfc27ec7e8192cc81085c3e"
  "$GMP.tar.xz|$GNU_MIRROR/gmp/$GMP.tar.xz|a3c2b80201b89e68616f4ad30bc66aee4927c3ce50e33929ca819d5c43538898"
  "$MPFR.tar.xz|$GNU_MIRROR/mpfr/$MPFR.tar.xz|b67ba0383ef7e8a8563734e2e889ef5ec3c3b898a01d00fa0a6869ad81c6ce01"
  "$MPC.tar.gz|$GNU_MIRROR/mpc/$MPC.tar.gz|ab642492f5cf882b74aa0cb730cd410a81edcdbec895183ce930e706c1c759b8"
  "$MLIBC.tar.gz|$CODE_HOST/managarm/mlibc/archive/refs/tags/v7.0.0.tar.gz|56d62366a6a15bc3fd8741bebcb311ca543553f7b734b1e780aeae33691bd621"
  "$FRIGG.tar.gz|$CODE_HOST/managarm/frigg/archive/${FRIGG#frigg-}.tar.gz|10cbee1dab6e7b0a1ca8d6d59d9eeffab1ed3cf6b0031551fd63a6861cc07a41"
  "$LIBSMARTER.tar.gz|$CODE_HOST/managarm/libsmarter/archive/${LIBSMARTER#libsmarter-}.tar.gz|1426e24f3c3c2a08983fad71d461faa415f0ccc1ca432dd80bebe1dac9cc7bce"
  "$FREESTND_CXX.tar.gz|$CODE_HOST/osdev0/freestnd-cxx-hdrs/archive/${FREESTND_CXX#freestnd-cxx-hdrs-}.tar.gz|dc4a44daef5d50a6f9aea0cb7bd2164c208f159d273c51f3ff8334b5bd65ef95"
)

ALL_STEPS=(fetch unpack binutils mlibc-headers gcc libgcc-static mlibc libgcc libstdcxx)

log() { echo "build-toolchain [$TRIPLET]: $*"; }
done_step() { [ -f "$STAMPS/$1" ]; }
mark_step() { mkdir -p "$STAMPS"; touch "$STAMPS/$1"; }

export PATH="$PREFIX/bin:$PATH"

step_fetch() {
  mkdir -p "$SOURCES"
  local entry file url sum
  for entry in "${ARCHIVES[@]}"; do
    IFS='|' read -r file url sum <<< "$entry"
    if [ ! -f "$SOURCES/$file" ]; then
      log "downloading $file"
      curl -fL --retry 3 -o "$SOURCES/$file.part" "$url"
      mv "$SOURCES/$file.part" "$SOURCES/$file"
    fi
    echo "$sum  $SOURCES/$file" | sha256sum --check --quiet - ||
      { echo "build-toolchain: $file does not match its checksum" >&2; exit 1; }
  done
}

# Unpacks an archive into $SRC once; prints nothing.
unpack_archive() {
  local file="$1" directory="$2"
  if [ ! -d "$SRC/$directory" ]; then
    log "unpacking $file"
    tar -xf "$SOURCES/$file" -C "$SRC"
  fi
}

apply_patches() {
  local tree="$1" patches="$2" patch_file
  for patch_file in "$ROOT/toolchain/patches/$patches"/*.patch; do
    [ -e "$patch_file" ] || continue
    log "patching $(basename "$tree") with $(basename "$patch_file")"
    patch -d "$tree" -p1 --forward --silent < "$patch_file"
  done
}

step_unpack() {
  mkdir -p "$SRC"
  if [ ! -f "$SRC/.patched-$BINUTILS" ]; then
    rm -rf "$SRC/$BINUTILS"
    unpack_archive "$BINUTILS.tar.xz" "$BINUTILS"
    apply_patches "$SRC/$BINUTILS" binutils
    touch "$SRC/.patched-$BINUTILS"
  fi
  if [ ! -f "$SRC/.patched-$GCC" ]; then
    rm -rf "$SRC/$GCC"
    unpack_archive "$GCC.tar.xz" "$GCC"
    unpack_archive "$GMP.tar.xz" "$GMP"
    unpack_archive "$MPFR.tar.xz" "$MPFR"
    unpack_archive "$MPC.tar.gz" "$MPC"
    ln -sfn "../$GMP" "$SRC/$GCC/gmp"
    ln -sfn "../$MPFR" "$SRC/$GCC/mpfr"
    ln -sfn "../$MPC" "$SRC/$GCC/mpc"
    apply_patches "$SRC/$GCC" gcc
    touch "$SRC/.patched-$GCC"
  fi
  # mlibc is unpacked fresh whenever the sysdeps or patches change, so
  # the tree always matches the repository.
  rm -rf "$SRC/$MLIBC"
  unpack_archive "$MLIBC.tar.gz" "$MLIBC"
  apply_patches "$SRC/$MLIBC" mlibc
  cp -r "$ROOT/toolchain/mlibc/sysdeps/freepascalos" "$SRC/$MLIBC/sysdeps/"
  local subproject archive name
  # GCC brings its own freestanding C headers (stddef.h, immintrin.h,
  # ...), newer than freestnd-c-hdrs' copies, so only the C++ ones are
  # given to mlibc (there is no libstdc++ yet when it is first built).
  for subproject in "$FRIGG:frigg" "$LIBSMARTER:libsmarter" \
                    "$FREESTND_CXX:freestnd-cxx-hdrs"; do
    archive="${subproject%%:*}"
    name="${subproject##*:}"
    mkdir -p "$SRC/$MLIBC/subprojects/$name"
    tar -xf "$SOURCES/$archive.tar.gz" -C "$SRC/$MLIBC/subprojects/$name" --strip-components=1
    # What meson's wrap would lay over the checkout.
    if [ -d "$SRC/$MLIBC/subprojects/packagefiles/$name" ]; then
      cp -r "$SRC/$MLIBC/subprojects/packagefiles/$name/." "$SRC/$MLIBC/subprojects/$name/"
    fi
  done
}

step_binutils() {
  local dir="$WORK/build-binutils"
  rm -rf "$dir"; mkdir -p "$dir"
  (cd "$dir" &&
    "$SRC/$BINUTILS/configure" --target="$TRIPLET" --prefix="$PREFIX" \
      --with-sysroot="$SYSROOT" --disable-nls --disable-werror \
      --disable-gdb --disable-gdbserver --disable-sim --disable-gprofng \
      --enable-deterministic-archives &&
    make -j"$JOBS" && make install)
}

write_meson_cross_file() {
  cat > "$WORK/meson-cross.txt" <<EOF
[binaries]
c = '$PREFIX/bin/$TRIPLET-gcc'
cpp = '$PREFIX/bin/$TRIPLET-g++'
ar = '$PREFIX/bin/$TRIPLET-ar'
strip = '$PREFIX/bin/$TRIPLET-strip'

[host_machine]
system = 'freepascalos'
cpu_family = '$CPU'
cpu = '$CPU'
endian = 'little'
EOF
}

step_mlibc_headers() {
  write_meson_cross_file
  local dir="$WORK/build-mlibc-headers"
  rm -rf "$dir"
  meson setup "$dir" "$SRC/$MLIBC" --cross-file "$WORK/meson-cross.txt" \
    --prefix=/usr --wrap-mode=nodownload -Dheaders_only=true
  DESTDIR="$SYSROOT" meson install -C "$dir" --quiet
}

configure_gcc() {
  local dir="$WORK/build-gcc"
  rm -rf "$dir"; mkdir -p "$dir"
  (cd "$dir" &&
    "$SRC/$GCC/configure" --target="$TRIPLET" --prefix="$PREFIX" \
      --with-sysroot="$SYSROOT" --enable-languages=c,c++ \
      --disable-multilib --enable-default-pie --enable-shared \
      --enable-threads=posix --enable-tls --enable-initfini-array \
      --enable-__cxa_atexit --disable-nls --disable-werror \
      --disable-libsanitizer --disable-libssp --disable-libgomp \
      --disable-libitm --disable-libvtv --disable-libquadmath \
      --disable-libatomic --disable-bootstrap --without-isl --without-zstd \
      --with-gnu-as --with-gnu-ld)
}

step_gcc() {
  configure_gcc
  (cd "$WORK/build-gcc" && make -j"$JOBS" all-gcc && make install-gcc)
  # mlibc includes <unwind.h> (backtrace), which libgcc installs only
  # later: the same file, put in place now.
  local version
  version="$("$PREFIX/bin/$TRIPLET-gcc" -dumpversion)"
  cp "$SRC/$GCC/libgcc/unwind-generic.h" "$PREFIX/lib/gcc/$TRIPLET/$version/include/unwind.h"
}

step_mlibc() {
  write_meson_cross_file
  local dir="$WORK/build-mlibc"
  rm -rf "$dir"
  meson setup "$dir" "$SRC/$MLIBC" --cross-file "$WORK/meson-cross.txt" \
    --prefix=/usr --libdir=lib --buildtype=debugoptimized --wrap-mode=nodownload \
    -Ddefault_library=both \
    -Ddefault_library_paths=/usr/lib,/usr/local/lib
  ninja -C "$dir"
  DESTDIR="$SYSROOT" meson install -C "$dir" --quiet
}

# libgcc.a alone: the static part needs no C library, and mlibc links
# with it (128-bit arithmetic, complex multiplication).
step_libgcc_static() {
  local version libgcc_dir
  version="$("$PREFIX/bin/$TRIPLET-gcc" -dumpversion)"
  (cd "$WORK/build-gcc" && make configure-target-libgcc)
  libgcc_dir="$WORK/build-gcc/$TRIPLET/libgcc"
  make -C "$libgcc_dir" -j"$JOBS" libgcc.a
  cp "$libgcc_dir/libgcc.a" "$PREFIX/lib/gcc/$TRIPLET/$version/libgcc.a"
}

step_libgcc() {
  (cd "$WORK/build-gcc" && make -j"$JOBS" all-target-libgcc && make install-target-libgcc)
  # The runtime goes where programs find it on the system disk.
  cp -a "$PREFIX/$TRIPLET/lib/libgcc_s.so"* "$SYSROOT/usr/lib/"
}

step_libstdcxx() {
  (cd "$WORK/build-gcc" && make -j"$JOBS" all-target-libstdc++-v3 &&
    make install-target-libstdc++-v3)
  cp -a "$PREFIX/$TRIPLET/lib/libstdc++.so"* "$SYSROOT/usr/lib/"
}

run_step() {
  local step="$1" function="step_${1//-/_}"
  log "step $step"
  "$function"
  mark_step "$step"
}

mkdir -p "$WORK" "$SYSROOT/usr/include" "$SYSROOT/usr/lib"
if [ "$#" -gt 0 ]; then
  for step in "$@"; do run_step "$step"; done
else
  for step in "${ALL_STEPS[@]}"; do
    # unpack refreshes mlibc every time; the rest run once.
    if [ "$step" = fetch ] || [ "$step" = unpack ] || ! done_step "$step"; then
      run_step "$step"
    fi
  done
fi
log "done: $PREFIX/bin/$TRIPLET-gcc, sysroot $SYSROOT"
