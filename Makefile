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

# FreePascalOS build
#
#   make            Build the loader and kernel into an EFI system partition tree
#   make run        Boot it in QEMU with OVMF firmware and the test disk (log on stdio)
#   make debug      Like run, but wait for GDB on localhost:1234
#   make test       Boot headless with the test and system disks, run all self tests
#                   and the user mode tests (coretest), then type into the shell on
#                   the emulated keyboard and serial port, then boot the graphical
#                   session as it normally starts; report pass/fail
#   make aml-test   Run the kernel's AML interpreter on the host against captured
#                   QEMU DSDTs and compare what it finds with the expected output
#   make file-system-image-test  The ext, FAT and exFAT drivers on the host against
#                   disk images damaged on purpose and at random
#   make device-tree-test  Read a device tree laid out like the Raspberry Pi 5's (host)
#   make gem-descriptor-test  The Pi 5 Ethernet's (Cadence GEM) DMA descriptors (host)
#   make nvme-queue-test      NVMe queue pairs: identifiers, phases, late completions (host)
#   make acpi-table-test      ACPI table lengths and checksums checked before use (host)
#   make virtio-used-ring-test  Virtio used ring ids, lengths and queue sizes checked (host)
#   make hdmi-audio-test   The Pi 5 HDMI audio's N/CTS, IEC 60958 frames and DMA blocks (host)
#   make acpi-device-test  Walk a DSDT laid out like the Raspberry Pi 4's (made by
#                   Python) for platform devices on the host: ids, resources,
#                   _CCA, _DMA, _DSD properties
#   make drawing-test  Check libdrawing and libfont on the host, pixel by pixel
#   make font-test  Check libfont's TrueType reading, rendering, hinting and glyph
#                   cache on the host against FreeType (fixtures made by Python)
#   make text-test  Check the multi-line edit box's plain logic on the host (undo,
#                   word wrap, search)
#   make apps-test  Check the calculator's, image viewer's and volume control's
#                   plain logic on the host
#   make controls-test  Check libcontrols' layout arithmetic on the host (anchors,
#                   docking, flow and table panels, split containers)
#   make navigation-controls-test  Check the plain logic of libcontrols' tab
#                   strip, breadcrumb bar, command bar and transfer rates on the host
#   make settings-test  Check the settings library on the host (files, escaping,
#                   layering, two writers, damaged files, the network's
#                   settings and state files)
#   make crypto-test  Check libcryptography's TLS algorithms on the host against
#                   published known answers
#   make compression-test  Check libcompression on the host against zlib's
#                   output (made by Python), and have Python's zlib
#                   decompress what it compresses
#   make archive-test  Check libarchive on the host: zip and tar files made by
#                   Python read, and the zips it writes checked by Python's zipfile
#   make ports-test Check the ports tool (scripts/ports.py) on the host: port.toml and
#                   its schema, licences, dependencies, patches, packages, repositories,
#                   whole builds in a tree of its own (Python unittest)
#   make pkg-test   Check pkg's units on the host: install, upgrade, verify, remove and
#                   repositories over packages the ports tool made
#   make ports PORTS="NAME ..."  Build ports into packages (ports/README.md)
#   make ssh-test   Check libssh on the host: packet framing, the ciphers, the key
#                   exchange hash and keys, host keys and signatures against Python's
#                   and OpenSSL's answers, and the server against a client in memory
#   make web-ipc-test  Check libwebipc (the browser's process protocol) on the host:
#                   the wire format, messages in pieces, every typed payload
#   make web-script-test  Check libweb's script bindings on the host: scripts using
#                   the DOM, events, selectors, reflection, parsing with scripts,
#                   MutationObserver, encodings, URLs, the window, and wrapper
#                   lifetime with both collectors (bytes per wrapper)
#   make javascript-test  Run libjavascript on the host: scripts with their expected
#                   output, the embedding API, and a benchmark (time and peak bytes)
#   make tls-test   Check libtls on the host: certificates, chains, the RFC 8448
#                   handshake, and whole connections to OpenSSL's s_server
#   make wget-test  Check wget's URL, header and chunked decoding logic on the host
#   make quic-test  Check libquic on the host: RFC 9001 and RFC 9204 vectors, frames,
#                   whole QUIC and HTTP/3 connections over loopback UDP, libhttp's
#                   client finding the test server by Alt-Svc and falling back to
#                   TCP, and curl's HTTP/3 against the test server when it has it
#   make http-test  Check libhttp on the host: URLs, HPACK, HTTP/2, HTTP/1.1, the client
#   make network-protocol-test  Check the resolver's EDNS(0) and cache and the DHCP
#                   and DHCPv6 messages on the host
#   make netstat-test  Check the ports list parser and ss's filters on the host
#   make css-test   Check libcss on the host: tokenizer, parsing and serialization,
#                   selectors, the cascade, computed values, media queries, colors
#                   (against Python's conversions), memory and style sharing
#   make svg-test   Check libsvg on the host: SVG documents drawn and probed pixel by
#                   pixel (shapes, strokes, paints, clips, masks, text, use, images)
#   make image-test  Check libimage on the host against Pillow's decoding of fixtures
#                   made at build time (BMP, DIB, ICO, CUR, GIF, JPEG)
#   make decompression-test  Check the RAM disk's xz and gzip decoders on the host
#   make served-system-image  The system image compressed for network boot
#                   (SYSTEM_IMAGE_COMPRESSION=xz, gzip or none)
#   make userland   Build the user mode libraries and programs
#   make system-disk  Build the ext4 system volume with /bin and /lib
#   make c-toolchain  Build the C/C++ cross toolchain and mlibc for ARCH
#                   (build/toolchain/<triplet>, sysroot build/sysroot/<arch>)
#   make c-test     Boot with the C test suite (/usr/bin/ctest) as the first
#                   program: stdio, threads, fork/exec, signals, sockets, C++
#   make image      Build a GPT disk image that can be written to a USB stick
#   make font       Regenerate the console font include from a PSF font
#   make update-fonts  Refresh the outline fonts in userland/fonts from the
#                   build machine's font packages (scripts/fonts.list)
#   make clean      Remove all build output
#
#   make toolchain ARCH=arm64  Build the AArch64 cross compiler from the Free
#                   Pascal sources (build/toolchain/ppcrossa64)
#   make ARCH=arm64 Build the AArch64 loader and kernel (build/arm64/esp)
#   make run ARCH=arm64  Boot it in QEMU's virt machine (GICv2, Cortex-A72)
#   make arm64-test Tests of the AArch64 build: boot, coretest, the session
#                   (not in make test)
#   make pi-netboot-serve  Serve the AArch64 build to a network booted Pi 4
#   make pi-sd-image       An SD card image for the Pi 4 (flashed once)
#   make arm64-netboot-test  Network boot of the AArch64 build in QEMU
#   make ARCH=arm64 native  The native (device tree) boot image, build/arm64/native/fpos.img
#   make arm64-native-test  Native boot of fpos.img in QEMU (EL1 and EL2)
#   make pi5-sd-image      An SD card image for the Raspberry Pi 5 (native boot)
#   make pi5-eeprom-image  A Pi 5 bootloader recovery card: network boot (once)
#   make pi5-netboot-serve Serve the native build to a network booted Pi 5
#   (the RAM disk is served as build/arm64/system-disk.img.xz;
#   SYSTEM_IMAGE_COMPRESSION=gzip or none for the others)

ARCH ?= amd64

FPC ?= fpc
LD ?= ld
OBJCOPY ?= objcopy
OBJDUMP ?= objdump
NM ?= nm

BUILD_DIRECTORY := build/$(ARCH)
ESP_DIRECTORY := $(BUILD_DIRECTORY)/esp

ifeq ($(ARCH),amd64)
  # Free Pascal with the FreePascalOS target (toolchain/fpc), built from
  # the compiler sources into the build tree (make toolchain); it
  # compiles the loader and the kernel for win64 and linux as the
  # installed compiler would, and the userland for x86_64-freepascalos.
  CROSS_COMPILER := build/toolchain/ppcx64
  CROSS_COMPILER_CPU := x86_64
  TARGET_FPC := $(CROSS_COMPILER)
  TARGET_AS := $(AS) --64
  LOADER_TARGET := -Twin64
  KERNEL_TARGET := -Tlinux
  EFI_BOOT_FILE := BOOTX64.EFI
else ifeq ($(ARCH),arm64)
  # Free Pascal's AArch64 cross compiler, built from the compiler sources
  # into the build tree (make toolchain ARCH=arm64), and GNU binutils for
  # AArch64 (aarch64-linux-gnu-*), which the compiler runs to assemble.
  CROSS_COMPILER := build/toolchain/ppcrossa64
  CROSS_COMPILER_CPU := aarch64
  CROSS_PREFIX ?= aarch64-linux-gnu-
  TARGET_FPC := $(CROSS_COMPILER) -XP$(CROSS_PREFIX)
  TARGET_AS := $(CROSS_PREFIX)as
  LD := $(CROSS_PREFIX)ld
  OBJCOPY := $(CROSS_PREFIX)objcopy
  OBJDUMP := $(CROSS_PREFIX)objdump
  NM := $(CROSS_PREFIX)nm
  # Both are compiled for linux (AAPCS64, which is also the UEFI calling
  # convention on AArch64); the loader is linked as a position
  # independent ELF and converted to a PE image (see boot/uefi/arm64).
  LOADER_TARGET := -Tlinux
  KERNEL_TARGET := -Tlinux
  EFI_BOOT_FILE := BOOTAA64.EFI
else
  $(error Architecture '$(ARCH)' is not supported yet)
endif

# -n      ignore the system wide fpc.cfg (it points at the hosted RTL)
# -O2     optimize
# -Si     support inline
# -vewn   show errors, warnings and notes
COMMON_FLAGS := -n -O2 -Si -vewn

RTL_LOADER_DIRECTORY := $(BUILD_DIRECTORY)/rtl-loader
RTL_KERNEL_DIRECTORY := $(BUILD_DIRECTORY)/rtl-kernel
LOADER_OBJECT_DIRECTORY := $(BUILD_DIRECTORY)/loader
KERNEL_OBJECT_DIRECTORY := $(BUILD_DIRECTORY)/kernel

LOADER_UNIT_DIRECTORIES := \
	shared shared/$(ARCH) \
	boot/uefi boot/uefi/$(ARCH)

KERNEL_UNIT_DIRECTORIES := \
	shared shared/$(ARCH) \
	kernel \
	kernel/core kernel/core/$(ARCH) \
	kernel/memory kernel/memory/$(ARCH) \
	kernel/objects \
	kernel/processes kernel/processes/$(ARCH) \
	kernel/firmware \
	kernel/io \
	kernel/power \
	kernel/network \
	kernel/drivers/storage \
	kernel/drivers/virtio \
	kernel/drivers/usb \
	kernel/drivers/sound \
	kernel/drivers/network \
	kernel/drivers/input \
	kernel/drivers/devices \
	kernel/drivers/bus \
	kernel/filesystems \
	kernel/runtime kernel/runtime/$(ARCH) \
	kernel/debug \
	hal/$(ARCH) \
	userland/lib/compression

# -WR     emit base relocations so the firmware can load the image anywhere
# -Xs     strip symbols
LOADER_FLAGS := $(COMMON_FLAGS) $(LOADER_TARGET) -WR -Xs \
	-Fu$(RTL_LOADER_DIRECTORY) $(addprefix -Fu,$(LOADER_UNIT_DIRECTORIES)) \
	-FU$(LOADER_OBJECT_DIRECTORY) -FE$(BUILD_DIRECTORY)

# -g      debug information (for GDB through QEMU)
# -Cg-    no position independent code
# -Cn     compile only, the kernel is linked with ld below
# -OoNOSTACKFRAME  every routine keeps its frame pointer (RBP, X29), so
#         a panic can walk the frames for its back trace
KERNEL_FLAGS := $(COMMON_FLAGS) $(KERNEL_TARGET) -g -Cg- -Cn -OoNOSTACKFRAME \
	-Fu$(RTL_KERNEL_DIRECTORY) $(addprefix -Fu,$(KERNEL_UNIT_DIRECTORIES)) \
	-FU$(KERNEL_OBJECT_DIRECTORY)

KERNEL_LINKER_SCRIPT := kernel/link/$(ARCH).ld

LOADER_EFI := $(BUILD_DIRECTORY)/$(EFI_BOOT_FILE)
KERNEL_ELF := $(BUILD_DIRECTORY)/kernel.elf

.PHONY: unicode-test call-frame-info-test all loader kernel esp run debug test test-disk image font clean check-kernel imaging-controls-test icon-test apps-test paint-test aml-test region-tree-test mount-test scheduler-policy-test acpi-power-test sntp-test aslr-test acpi-device-test device-tree-test gem-descriptor-test hdmi-audio-test usb-descriptor-test nvme-queue-test acpi-table-test virtio-used-ring-test tcp-test drawing-test font-test text-test chart-test settings-test files-test browser-test controls-test date-controls-test suspend-stress \
	crypto-test tls-test wget-test http-test ipv6-test network-protocol-test image-test compression-test archive-test decompression-test ssh-test netstat-test \
	ports-test pkg-test quic-test css-test svg-test web-test javascript-test web-layout-test webrender web-load-test web-script-test webbrowse web-ipc-test navigation-controls-test update-fonts

all: esp

# --- Runtime library -------------------------------------------------------

# rtl/freestanding holds the System unit of the loader and the kernel,
# rtl/common the units both need. User programs get the Free Pascal RTL
# (rtl/fpc, built by userland/userland.mk).
# Arguments: output directory, System unit directory, compiler flags.
define build-rtl
	@mkdir -p $(1)
	$(TARGET_FPC) $(COMMON_FLAGS) $(3) -Firtl/common -Us -FU$(1) $(2)/system.pas
	$(TARGET_FPC) $(COMMON_FLAGS) $(3) -Fu$(1) -FU$(1) rtl/common/objpas.pas
	$(TARGET_FPC) $(COMMON_FLAGS) $(3) -Fu$(1) -FU$(1) rtl/common/sysinit.pas
	$(TARGET_FPC) $(COMMON_FLAGS) $(3) -Fu$(1) -FU$(1) rtl/common/fpintres.pas
endef

RTL_SOURCES := $(wildcard rtl/common/*) $(wildcard rtl/freestanding/*.pas)

$(RTL_LOADER_DIRECTORY)/system.ppu: $(RTL_SOURCES) | $(CROSS_COMPILER)
	$(call build-rtl,$(RTL_LOADER_DIRECTORY),rtl/freestanding,$(LOADER_TARGET))

$(RTL_KERNEL_DIRECTORY)/system.ppu: $(RTL_SOURCES) | $(CROSS_COMPILER)
	$(call build-rtl,$(RTL_KERNEL_DIRECTORY),rtl/freestanding,$(KERNEL_TARGET) -OoNOSTACKFRAME)

# --- Cross compiler ----------------------------------------------------------

# Built from the Free Pascal compiler sources and the FreePascalOS
# patches (toolchain/fpc) with the installed compiler; nothing is
# installed.
.PHONY: toolchain
toolchain: $(CROSS_COMPILER)

CROSS_COMPILER_SOURCES := scripts/build-cross-compiler.sh toolchain/fpc/prepare-source.sh \
	$(wildcard toolchain/fpc/patches/*.patch) $(shell find toolchain/fpc/compiler -type f 2>/dev/null)

$(CROSS_COMPILER): $(CROSS_COMPILER_SOURCES)
	scripts/build-cross-compiler.sh $(CROSS_COMPILER_CPU) $@

# --- Loader ----------------------------------------------------------------

loader: $(LOADER_EFI)

ifeq ($(ARCH),arm64)
# Free Pascal 3.2.2 cannot write AArch64 PE images: the loader is compiled
# for linux, linked as a position independent ELF that relocates itself
# (LoaderEntry.s), and converted to a PE image by objcopy.
LOADER_ELF := $(BUILD_DIRECTORY)/OsLoader.elf
LOADER_ASSEMBLY_OBJECTS := $(patsubst boot/uefi/$(ARCH)/%.s,$(LOADER_OBJECT_DIRECTORY)/%.o,\
	$(wildcard boot/uefi/$(ARCH)/*.s))

$(LOADER_OBJECT_DIRECTORY)/%.o: boot/uefi/$(ARCH)/%.s
	@mkdir -p $(LOADER_OBJECT_DIRECTORY)
	$(TARGET_AS) -o $@ $<

$(LOADER_EFI): $(RTL_LOADER_DIRECTORY)/system.ppu $(LOADER_ASSEMBLY_OBJECTS) FORCE
	@mkdir -p $(LOADER_OBJECT_DIRECTORY)
	$(TARGET_FPC) $(COMMON_FLAGS) $(LOADER_TARGET) -Cn -Cg- \
		-Fu$(RTL_LOADER_DIRECTORY) $(addprefix -Fu,$(LOADER_UNIT_DIRECTORIES)) \
		-FU$(LOADER_OBJECT_DIRECTORY) -FE$(LOADER_OBJECT_DIRECTORY) boot/uefi/OsLoader.pas
	$(LD) -nostdlib -pie --no-dynamic-linker -z nocombreloc -z max-page-size=4096 \
		-T boot/uefi/$(ARCH)/loader.ld -o $(LOADER_ELF) \
		$(LOADER_OBJECT_DIRECTORY)/*.o $(RTL_LOADER_DIRECTORY)/system.o
	$(OBJCOPY) -j .text -j .data -j .dynamic -j .rela -j .reloc \
		-O pei-aarch64-little --subsystem efi-app $(LOADER_ELF) $@
else
$(LOADER_EFI): $(RTL_LOADER_DIRECTORY)/system.ppu FORCE
	@mkdir -p $(LOADER_OBJECT_DIRECTORY)
	$(TARGET_FPC) $(LOADER_FLAGS) boot/uefi/OsLoader.pas
	$(OBJCOPY) --subsystem efi-app $(BUILD_DIRECTORY)/OsLoader.exe $@
endif

# --- Kernel ----------------------------------------------------------------

kernel: $(KERNEL_ELF)

# Code that cannot be written in Pascal: on x86-64 the 16-bit start-up
# code of the secondary processors, on AArch64 the exception vectors,
# the entry points and the system register accesses.
KERNEL_ASSEMBLY_OBJECTS := $(patsubst kernel/core/$(ARCH)/%.s,$(KERNEL_OBJECT_DIRECTORY)/%.o,\
	$(wildcard kernel/core/$(ARCH)/*.s))

$(KERNEL_OBJECT_DIRECTORY)/%.o: kernel/core/$(ARCH)/%.s
	@mkdir -p $(KERNEL_OBJECT_DIRECTORY)
	$(TARGET_AS) -o $@ $<

# The kernel's symbol table (scripts/make-kernel-symbols.py) for its back
# traces: the kernel is linked with an empty table, the table is made
# from that image's symbols, and the kernel is linked again with it. The
# table goes after the code, which does not move (the script checks).
KERNEL_SYMBOLS_DIRECTORY := $(BUILD_DIRECTORY)/kernel-symbols
KERNEL_UNSYMBOLIZED_ELF := $(KERNEL_SYMBOLS_DIRECTORY)/kernel-unsymbolized.elf
KERNEL_SYMBOL_SOURCES := $(KERNEL_UNIT_DIRECTORIES) rtl/freestanding rtl/common
# Compiler options are not part of what Free Pascal checks to decide
# whether a unit is up to date: when they change, every unit is compiled
# again.
KERNEL_FLAGS_STAMP := $(KERNEL_OBJECT_DIRECTORY)/flags.stamp

define link-kernel
	$(LD) -nostdlib -static --gc-sections -z max-page-size=4096 \
		-T $(KERNEL_LINKER_SCRIPT) -o $(1) \
		$(KERNEL_OBJECT_DIRECTORY)/*.o $(RTL_KERNEL_DIRECTORY)/system.o $(2)
endef

$(KERNEL_ELF): $(RTL_KERNEL_DIRECTORY)/system.ppu $(KERNEL_ASSEMBLY_OBJECTS) FORCE
	@mkdir -p $(KERNEL_OBJECT_DIRECTORY) $(KERNEL_SYMBOLS_DIRECTORY)
	@if [ "$$(cat $(KERNEL_FLAGS_STAMP) 2> /dev/null)" != "$(KERNEL_FLAGS)" ]; then \
		rm -f $(KERNEL_OBJECT_DIRECTORY)/*.ppu; echo "$(KERNEL_FLAGS)" > $(KERNEL_FLAGS_STAMP); fi
	$(TARGET_FPC) $(KERNEL_FLAGS) kernel/Kernel.Startup.pas
	python3 scripts/make-kernel-symbols.py --empty $(KERNEL_SYMBOLS_DIRECTORY)/empty.s
	$(TARGET_AS) -o $(KERNEL_SYMBOLS_DIRECTORY)/empty.o $(KERNEL_SYMBOLS_DIRECTORY)/empty.s
	$(call link-kernel,$(KERNEL_UNSYMBOLIZED_ELF),$(KERNEL_SYMBOLS_DIRECTORY)/empty.o)
	python3 scripts/make-kernel-symbols.py --nm $(NM) $(addprefix --source ,$(KERNEL_SYMBOL_SOURCES)) \
		$(KERNEL_UNSYMBOLIZED_ELF) $(KERNEL_SYMBOLS_DIRECTORY)/symbols.s
	$(TARGET_AS) -o $(KERNEL_SYMBOLS_DIRECTORY)/symbols.o $(KERNEL_SYMBOLS_DIRECTORY)/symbols.s
	$(call link-kernel,$@,$(KERNEL_SYMBOLS_DIRECTORY)/symbols.o)
	python3 scripts/make-kernel-symbols.py --nm $(NM) --verify $(KERNEL_UNSYMBOLIZED_ELF) $@
	@$(MAKE) --no-print-directory check-kernel

# The kernel does not save floating point / SIMD registers on interrupts or
# context switches, so the compiler must never have used them (only the
# routines that save and restore a thread's registers at a switch may).
ifeq ($(ARCH),arm64)
KERNEL_SIMD_PATTERN := [[:space:],][qdsvbh][0-9]+([].,[:space:]]|$$)
KERNEL_FPU_ROUTINES := ArchSaveFpuState|ArchRestoreFpuState|ArchSuspendTestHoldFpuValues
else
KERNEL_SIMD_PATTERN := %(x|y|z)mm[0-9]
KERNEL_FPU_ROUTINES := ArchSaveFpuState|ArchRestoreFpuState|ArchInitializeFpuState
endif
KERNEL_DISASSEMBLY = $(OBJDUMP) -d $(KERNEL_ELF) | \
	awk '/^[0-9a-f]+ <($(KERNEL_FPU_ROUTINES))>:/ { skip = 1; next } /^[0-9a-f]+ <.*>:/ { skip = 0 } !skip' | cut -f3-

check-kernel:
	@if $(KERNEL_DISASSEMBLY) | grep -qE '$(KERNEL_SIMD_PATTERN)'; then \
		echo "error: kernel code uses floating point / SIMD registers, which the kernel does not preserve"; \
		$(KERNEL_DISASSEMBLY) | grep -E '$(KERNEL_SIMD_PATTERN)' | head; \
		exit 1; \
	fi

# --- Native boot image (AArch64) ---------------------------------------------

# build/arm64/native/fpos.img: what firmware that loads a Linux kernel
# directly and passes a device tree (a Raspberry Pi 5, QEMU -kernel)
# boots. A stub (boot/native/arm64) with the Linux arm64 Image header,
# linked as a self-relocating position independent ELF like the UEFI
# loader, carrying kernel.elf (without debug information) after it;
# objcopy makes it a flat binary.
NATIVE_DIRECTORY := build/arm64/native
NATIVE_OBJECT_DIRECTORY := build/arm64/native-objects
NATIVE_IMAGE := $(NATIVE_DIRECTORY)/fpos.img
NATIVE_ELF := $(NATIVE_OBJECT_DIRECTORY)/fpos.elf
NATIVE_STRIPPED_KERNEL := $(NATIVE_OBJECT_DIRECTORY)/kernel-stripped.elf
NATIVE_UNIT_DIRECTORIES := shared shared/arm64 boot/native/arm64

.PHONY: native
ifeq ($(ARCH),arm64)
native: $(NATIVE_IMAGE)

$(NATIVE_IMAGE): $(RTL_LOADER_DIRECTORY)/system.ppu $(KERNEL_ELF) FORCE
	@mkdir -p $(NATIVE_DIRECTORY) $(NATIVE_OBJECT_DIRECTORY)
	$(CROSS_PREFIX)strip --strip-all -o $(NATIVE_STRIPPED_KERNEL) $(KERNEL_ELF)
	$(TARGET_AS) -o $(NATIVE_OBJECT_DIRECTORY)/NativeEntry.o boot/native/arm64/NativeEntry.s
	$(TARGET_AS) -o $(NATIVE_OBJECT_DIRECTORY)/LoaderHandoff.o boot/uefi/arm64/LoaderHandoff.s
	$(TARGET_AS) -I $(NATIVE_OBJECT_DIRECTORY) -o $(NATIVE_OBJECT_DIRECTORY)/KernelPayload.o \
		boot/native/arm64/KernelPayload.s
	$(TARGET_FPC) $(COMMON_FLAGS) $(LOADER_TARGET) -Cn -Cg- \
		-Fu$(RTL_LOADER_DIRECTORY) $(addprefix -Fu,$(NATIVE_UNIT_DIRECTORIES)) \
		-FU$(NATIVE_OBJECT_DIRECTORY) -FE$(NATIVE_OBJECT_DIRECTORY) boot/native/arm64/NativeBoot.pas
	$(LD) -nostdlib -pie --no-dynamic-linker -z nocombreloc -z max-page-size=4096 \
		-T boot/native/arm64/native.ld -o $(NATIVE_ELF) \
		$(NATIVE_OBJECT_DIRECTORY)/*.o $(RTL_LOADER_DIRECTORY)/system.o
	$(OBJCOPY) -O binary $(NATIVE_ELF) $@
else
native:
	@$(MAKE) --no-print-directory ARCH=arm64 native
endif

# --- EFI system partition --------------------------------------------------

esp: $(LOADER_EFI) $(KERNEL_ELF)
	@mkdir -p $(ESP_DIRECTORY)/EFI/BOOT $(ESP_DIRECTORY)/FreePascalOS
	cp $(LOADER_EFI) $(ESP_DIRECTORY)/EFI/BOOT/$(EFI_BOOT_FILE)
	cp $(KERNEL_ELF) $(ESP_DIRECTORY)/FreePascalOS/kernel.elf

image: esp
	scripts/make-disk-image.sh $(ESP_DIRECTORY) $(BUILD_DIRECTORY)/FreePascalOS.img

TEST_DISK := $(BUILD_DIRECTORY)/test-disk.img
SYSTEM_DISK := $(BUILD_DIRECTORY)/system-disk.img

# The system image as a network boot or the Raspberry Pi 5 is served it,
# the RAM disk: compressed (the Pi's firmware fetches it over TFTP at a
# few hundred KiB/s and gives up on a file after 60 s), which the kernel
# unpacks (Drivers.RamDiskDecompression). SYSTEM_IMAGE_COMPRESSION=xz
# (the default, the smallest), gzip, or none for the plain image.
SYSTEM_IMAGE_COMPRESSION ?= xz
XZ_SYSTEM_IMAGE_FLAGS := -6 -T0 --check=crc32
ifeq ($(SYSTEM_IMAGE_COMPRESSION),none)
SYSTEM_IMAGE_SUFFIX :=
else ifeq ($(SYSTEM_IMAGE_COMPRESSION),gzip)
SYSTEM_IMAGE_SUFFIX := .gz
else ifeq ($(SYSTEM_IMAGE_COMPRESSION),xz)
SYSTEM_IMAGE_SUFFIX := .xz
else
$(error SYSTEM_IMAGE_COMPRESSION must be xz, gzip or none)
endif
SERVED_SYSTEM_IMAGE := $(SYSTEM_DISK)$(SYSTEM_IMAGE_SUFFIX)
ARM64_SERVED_SYSTEM_IMAGE := build/arm64/system-disk.img$(SYSTEM_IMAGE_SUFFIX)

$(SYSTEM_DISK).xz: $(SYSTEM_DISK)
	xz $(XZ_SYSTEM_IMAGE_FLAGS) -c $< > $@.tmp
	@mv $@.tmp $@

$(SYSTEM_DISK).gz: $(SYSTEM_DISK)
	gzip -9 -n -c $< > $@.tmp
	@mv $@.tmp $@

.PHONY: served-system-image
served-system-image: $(SERVED_SYSTEM_IMAGE)

# make run and make debug boot a system disk of their own, so what is
# done there (files, passwords, logs in /var/log) stays from one run to
# the next but never reaches the built image the tests copy. It is made
# again from the built image whenever that is rebuilt.
RUN_SYSTEM_DISK := $(BUILD_DIRECTORY)/system-disk-interactive.img

$(RUN_SYSTEM_DISK): $(SYSTEM_DISK)
	cp $(SYSTEM_DISK) $@

ifeq ($(ARCH),arm64)
run: esp $(RUN_SYSTEM_DISK)
	scripts/run-qemu-arm64.sh $(ESP_DIRECTORY) $(RUN_SYSTEM_DISK)

debug: esp $(RUN_SYSTEM_DISK)
	scripts/run-qemu-arm64.sh $(ESP_DIRECTORY) --debug $(RUN_SYSTEM_DISK)
else
run: esp $(TEST_DISK) $(RUN_SYSTEM_DISK)
	scripts/run-qemu.sh $(ARCH) $(ESP_DIRECTORY) --copy $(TEST_DISK) $(RUN_SYSTEM_DISK)

debug: esp $(TEST_DISK) $(RUN_SYSTEM_DISK)
	scripts/run-qemu.sh $(ARCH) $(ESP_DIRECTORY) --debug --copy $(TEST_DISK) $(RUN_SYSTEM_DISK)
endif

# Tests of the AArch64 build in QEMU's virt machine: the kernel must
# reach the end of its start-up with every self test passed, with the
# firmware at EL1 and at EL2, on GICv2 and GICv3, and run the file system
# tests on an SD card (SDHCI); coretest must pass on GICv2 and GICv3
# (scripts/test-qemu-arm64-user.sh); a deliberate panic must show its
# back trace; and the graphical session must come up with a shell on the
# serial console (scripts/test-arm64-session.py). make test runs all but
# the GICv3 coretest and the session (arm64-test-if-available), when
# scripts/arm64-test-requirements.sh finds the tools.
.PHONY: arm64-test arm64-test-if-available
arm64-test:
	@$(MAKE) --no-print-directory ARCH=arm64 esp test-disk system-disk
	scripts/test-qemu-arm64.sh build/arm64/esp build/arm64/test-disk-sdsc.img
	scripts/test-qemu-arm64-user.sh build/arm64/esp build/arm64/test-disk.img build/arm64/system-disk.img
	GIC=3 scripts/test-qemu-arm64-user.sh build/arm64/esp build/arm64/test-disk.img build/arm64/system-disk.img
	scripts/test-panic-trace.sh arm64 build/arm64/esp
	scripts/test-arm64-session.py build/arm64/esp build/arm64/system-disk.img

arm64-test-if-available:
	@if scripts/arm64-test-requirements.sh; then \
		$(MAKE) --no-print-directory ARCH=arm64 esp test-disk system-disk && \
		scripts/test-qemu-arm64.sh build/arm64/esp build/arm64/test-disk-sdsc.img && \
		scripts/test-qemu-arm64-user.sh build/arm64/esp build/arm64/test-disk.img build/arm64/system-disk.img && \
		scripts/test-panic-trace.sh arm64 build/arm64/esp; \
	fi

# Network boot of the AArch64 build (docs/Architecture.md, "Trying it on
# a Raspberry Pi 4"). pi-netboot-serve builds, then serves the boot files
# and the system image over HTTP (TFTP=1: TFTP too, port 69 needs root;
# NETBOOT_PORT, NETBOOT_OPTIONS=file for the served options.txt).
# arm64-netboot-test boots QEMU from the network, over HTTP and TFTP.
# The system image is served compressed (SYSTEM_IMAGE_COMPRESSION, xz
# by default; none serves build/arm64/system-disk.img as it is).
# pi-sd-image writes build/arm64/pi-sd.img(.xz) to flash once: the Pi 4
# UEFI firmware (PI_FIRMWARE=zip, default the newest
# ~/Downloads/RPi4_UEFI_Firmware_v*.zip), the loader and an options.txt
# with netboot= and netlog= for SERVER (default this machine);
# PI_IMAGE=standalone adds the system volume instead of netboot=.
.PHONY: pi-netboot-serve arm64-netboot-test pi-sd-image arm64-native-test
# arm64-native-test boots build/arm64/native/fpos.img in QEMU without
# firmware (-kernel, -initrd, a device tree), at EL1 and at EL2, and
# checks netlog and the TCP debug shell over virtio-net
# (scripts/test-arm64-native.py).
arm64-native-test:
	@$(MAKE) --no-print-directory ARCH=arm64 native served-system-image
	scripts/test-arm64-native.py $(NATIVE_IMAGE) $(ARM64_SERVED_SYSTEM_IMAGE)

pi-netboot-serve:
	@$(MAKE) --no-print-directory ARCH=arm64 esp served-system-image
	scripts/netboot-serve.py --esp build/arm64/esp --system-image $(ARM64_SERVED_SYSTEM_IMAGE) \
		$(if $(NETBOOT_PORT),--port $(NETBOOT_PORT)) $(if $(NETBOOT_OPTIONS),--options-file $(NETBOOT_OPTIONS)) \
		$(if $(TFTP),--tftp)

arm64-netboot-test:
	@$(MAKE) --no-print-directory ARCH=arm64 esp served-system-image
	scripts/test-arm64-netboot.sh build/arm64/esp $(ARM64_SERVED_SYSTEM_IMAGE)

pi-sd-image:
	@$(MAKE) --no-print-directory ARCH=arm64 esp $(if $(filter standalone,$(PI_IMAGE)),system-disk)
	scripts/make-pi-sd-image.py --esp build/arm64/esp --output build/arm64/pi-sd.img \
		$(if $(PI_FIRMWARE),--firmware $(PI_FIRMWARE)) $(if $(SERVER),--server $(SERVER)) \
		$(if $(NETBOOT_PORT),--port $(NETBOOT_PORT)) $(if $(NETLOG),--netlog $(NETLOG)) \
		$(if $(filter standalone,$(PI_IMAGE)),--standalone --system-image build/arm64/system-disk.img)

# The Raspberry Pi 5, booted natively by its EEPROM bootloader with a
# device tree (docs/Architecture.md, "Trying it on a Raspberry Pi 5").
# pi5-sd-image writes build/arm64/pi5-sd.img(.xz): config.txt,
# cmdline.txt (netlog=SERVER, default this machine; PI5_OPTIONS=more),
# the device trees from PI5_FIRMWARE (default ~/Downloads/pi5/boot),
# build/arm64/native/fpos.img and the system image as system.img
# (compressed as SYSTEM_IMAGE_COMPRESSION says, xz by default: the
# firmware's TFTP is slow and gives up after 60 s). pi5-eeprom-image
# writes build/arm64/pi5-eeprom.img(.xz), a recovery card setting the
# EEPROM to boot from TFTP at SERVER first, then the SD card (the files
# from PI5_EEPROM, default ~/Downloads/pi5/eeprom). pi5-netboot-serve
# serves build/arm64/pi5-boot over TFTP (port 69: root, or
# net.ipv4.ip_unprivileged_port_start=69) and HTTP.
PI5_SD_IMAGE_ARGUMENTS = --system-image $(ARM64_SERVED_SYSTEM_IMAGE) \
	$(if $(PI5_FIRMWARE),--firmware-files $(PI5_FIRMWARE)) \
	$(if $(SERVER),--server $(SERVER)) $(if $(NETLOG),--netlog $(NETLOG)) \
	$(if $(PI5_OPTIONS),--options "$(PI5_OPTIONS)")
.PHONY: pi5-sd-image pi5-eeprom-image pi5-netboot-serve pi5-eeprom-test
pi5-sd-image:
	@$(MAKE) --no-print-directory ARCH=arm64 native served-system-image
	scripts/make-pi5-sd-image.py $(PI5_SD_IMAGE_ARGUMENTS)

pi5-eeprom-image:
	scripts/make-pi5-eeprom-image.py $(if $(PI5_EEPROM),--eeprom-files $(PI5_EEPROM)) \
		$(if $(SERVER),--server $(SERVER))

pi5-netboot-serve:
	@$(MAKE) --no-print-directory ARCH=arm64 native served-system-image
	scripts/make-pi5-sd-image.py --boot-files-only $(PI5_SD_IMAGE_ARGUMENTS)
	scripts/netboot-serve.py --pi5 build/arm64/pi5-boot $(if $(TFTP_PORT),--tftp-port $(TFTP_PORT)) \
		$(if $(NETBOOT_PORT),--port $(NETBOOT_PORT))

# The EEPROM configuration embedding, on a made-up image (no download).
pi5-eeprom-test:
	scripts/test-pi5-eeprom-image.py

$(TEST_DISK): scripts/make-test-disk.sh scripts/exfat-tool.py
	scripts/make-test-disk.sh $@

test-disk: $(TEST_DISK)

test: unicode-test call-frame-info-test native-fpc-test aml-test region-tree-test mount-test file-system-image-test scheduler-policy-test aslr-test acpi-device-test acpi-power-test sntp-test device-tree-test gem-descriptor-test hdmi-audio-test usb-descriptor-test nvme-queue-test acpi-table-test virtio-used-ring-test tcp-test pi5-eeprom-test drawing-test font-test text-test chart-test settings-test files-test browser-test controls-test date-controls-test apps-test paint-test crypto-test tls-test wget-test http-test ipv6-test network-protocol-test image-test compression-test archive-test decompression-test ssh-test netstat-test \
		quic-test css-test svg-test web-test javascript-test web-layout-test web-load-test web-script-test web-ipc-test navigation-controls-test imaging-controls-test icon-test cache-policy-test ports-test pkg-test esp $(TEST_DISK) \
		$(SYSTEM_DISK)
	scripts/test-qemu.sh $(ARCH) $(ESP_DIRECTORY) $(TEST_DISK) $(SYSTEM_DISK)
	scripts/test-panic-trace.sh $(ARCH) $(ESP_DIRECTORY)
	scripts/test-memory-pressure.sh $(ARCH) $(ESP_DIRECTORY) $(SYSTEM_DISK)
	scripts/test-input.py $(ESP_DIRECTORY) $(SYSTEM_DISK)
	scripts/test-session.py $(ESP_DIRECTORY) $(SYSTEM_DISK)
	scripts/test-virtio-gpu.py $(ESP_DIRECTORY) $(SYSTEM_DISK)
	scripts/test-ssh.py $(ESP_DIRECTORY) $(SYSTEM_DISK)
	@$(MAKE) --no-print-directory arm64-test-if-available

# Running out of memory (a process ended with 137, the system alive) and
# discards reaching the disks (image files shrink) in a 256 MiB guest;
# also run by make test.
.PHONY: memory-pressure-test
memory-pressure-test: esp $(SYSTEM_DISK)
	scripts/test-memory-pressure.sh $(ARCH) $(ESP_DIRECTORY) $(SYSTEM_DISK)

# Panics on purpose (the testpanic kernel option) and checks the back
# trace; also run by make test. Works for ARCH=arm64 too.
.PHONY: panic-trace-test
panic-trace-test: esp
	scripts/test-panic-trace.sh $(ARCH) $(ESP_DIRECTORY)

# Not part of make test (it takes a minute a round under TCG): suspends
# and wakes the input test's machine ROUNDS times (ACCEL=kvm for KVM,
# POINTERS=1 to check the mouse and tablet after each wake, LOAD=1 to keep
# programs starting and ending across each suspend).
ROUNDS ?= 30
suspend-stress: esp $(TEST_DISK) $(SYSTEM_DISK)
	scripts/stress-suspend.py $(ESP_DIRECTORY) $(SYSTEM_DISK) $(ROUNDS)

include userland/userland.mk
include ports/ports.mk
# The C toolchain and runtime (make c-toolchain, c-runtime, c-test).
include toolchain/c-runtime.mk

# --- Tools -----------------------------------------------------------------

FONT_SOURCE ?= /usr/share/kbd/consolefonts/ter-116n.psf.gz
FONT_TOOL := build/tools/PsfToPascal

$(FONT_TOOL): tools/PsfToPascal/PsfToPascal.pas
	@mkdir -p build/tools
	$(FPC) -O2 -FEbuild/tools -FUbuild/tools $<

FONT_UNPACKED := build/tools/$(basename $(notdir $(FONT_SOURCE)))

# The AML interpreter (kernel/firmware) is plain Pascal: it builds for the
# host too, and runs there against tables captured from QEMU's machines.
AML_TEST := build/tools/AmlTest
AML_TEST_SOURCES := tools/AmlTest/AmlTest.pas $(wildcard kernel/firmware/Firmware.Aml*.pas) \
	$(wildcard kernel/firmware/Firmware.Acpi*.pas) shared/Runtime.Memory.pas
AML_TEST_MACHINES := q35 pc

$(AML_TEST): $(AML_TEST_SOURCES)
	@mkdir -p build/tools/aml-units
	$(FPC) -O2 -Fukernel/firmware -Fushared -FEbuild/tools -FUbuild/tools/aml-units $<

# Malformed tables (make-malformed.py): each must fail cleanly, none may
# crash, hang or write outside its blocks.
AML_MALFORMED := build/tools/aml-malformed

$(AML_MALFORMED)/CASES: tools/AmlTest/make-malformed.py
	python3 -I $< $(AML_MALFORMED)

aml-test: $(AML_TEST) $(AML_MALFORMED)/CASES
	@for machine in $(AML_TEST_MACHINES); do \
		$(AML_TEST) tools/AmlTest/qemu-$$machine-dsdt.aml > build/tools/aml-$$machine.out && \
		diff -u tools/AmlTest/qemu-$$machine.expected build/tools/aml-$$machine.out > /dev/null || \
		{ echo "AML TEST FAILED: $$machine (diff tools/AmlTest/qemu-$$machine.expected build/tools/aml-$$machine.out)"; exit 1; }; \
	done; echo "AML TEST PASSED: $(AML_TEST_MACHINES)"
	timeout 300 $(AML_TEST) --malformed $(AML_MALFORMED)

# The region tree of user address spaces (Processes.RegionTree) on the
# host, against a plain list doing the same the slow way.
REGION_TREE_TEST := build/tools/RegionTreeTest

$(REGION_TREE_TEST): tools/RegionTreeTest/RegionTreeTest.pas kernel/processes/Processes.RegionTree.pas \
		kernel/processes/Processes.UserRegions.pas kernel/processes/Processes.RegionEditing.pas
	@mkdir -p build/tools/region-tree-units
	$(FPC) -O2 -Cr -Co -Fukernel/processes -FEbuild/tools -FUbuild/tools/region-tree-units $<

region-tree-test: $(REGION_TREE_TEST)
	$(REGION_TREE_TEST)

# The block cache's sizing, the batched discard ranges and the
# out-of-memory scores on the host.
CACHE_POLICY_TEST := build/tools/CachePolicyTest

$(CACHE_POLICY_TEST): tools/CachePolicyTest/CachePolicyTest.pas kernel/io/Io.BlockCacheSizing.pas \
		kernel/filesystems/FileSystem.DiscardRanges.pas kernel/processes/Processes.OutOfMemoryScores.pas
	@mkdir -p build/tools/cache-policy-units
	$(FPC) -O2 -Cr -Co -Fukernel/io -Fukernel/filesystems -Fukernel/processes -FEbuild/tools \
		-FUbuild/tools/cache-policy-units $<

.PHONY: cache-policy-test
cache-policy-test: $(CACHE_POLICY_TEST)
	$(CACHE_POLICY_TEST)

# The priority boost rules of the scheduler (Kernel.PriorityBoosts) on
# the host.
SCHEDULER_POLICY_TEST := build/tools/SchedulerPolicyTest

$(SCHEDULER_POLICY_TEST): tools/SchedulerPolicyTest/SchedulerPolicyTest.pas kernel/core/Kernel.PriorityBoosts.pas
	@mkdir -p build/tools/scheduler-policy-units
	$(FPC) -O2 -Cr -Co -Fukernel/core -FEbuild/tools -FUbuild/tools/scheduler-policy-units $<

scheduler-policy-test: $(SCHEDULER_POLICY_TEST)
	$(SCHEDULER_POLICY_TEST)

# The kernel's UTF-8 / UTF-16 conversions for file names (Runtime.Unicode)
# on the host: malformed UTF-8 (overlongs, surrogates, past U+10FFFF).
UNICODE_TEST := build/tools/UnicodeTest

$(UNICODE_TEST): tools/UnicodeTest/UnicodeTest.pas kernel/runtime/Runtime.Unicode.pas shared/Runtime.Text.pas
	@mkdir -p build/tools/unicode-test-units
	$(FPC) -O2 -Cr -Co -Fukernel/runtime -Fushared -FEbuild/tools -FUbuild/tools/unicode-test-units $<

unicode-test: $(UNICODE_TEST)
	$(UNICODE_TEST)

# The unwinder of the kernel's user back traces (Processes.CallFrame-
# Entries, .CallFrameRules) on the host, over .eh_frame, .eh_frame_hdr
# and .debug_frame fixtures tools/CallFrameInfoTest/make-cfi-fixtures.py
# writes (x86-64 and AArch64, Free Pascal's and the standard layout).
CALL_FRAME_INFO_TEST := build/tools/CallFrameInfoTest
CALL_FRAME_INFO_FIXTURES := build/tools/cfi-fixtures/memory.bin

$(CALL_FRAME_INFO_TEST): tools/CallFrameInfoTest/CallFrameInfoTest.pas \
		kernel/processes/Processes.CallFrameEntries.pas kernel/processes/Processes.CallFrameRules.pas \
		kernel/processes/Processes.SymbolNames.pas
	@mkdir -p build/tools/call-frame-info-units
	$(FPC) -O2 -Cr -Co -Fukernel/processes -Fushared -FEbuild/tools -FUbuild/tools/call-frame-info-units $<

$(CALL_FRAME_INFO_FIXTURES): tools/CallFrameInfoTest/make-cfi-fixtures.py
	python3 -I $< $(dir $@)

call-frame-info-test: $(CALL_FRAME_INFO_TEST) $(CALL_FRAME_INFO_FIXTURES)
	$(CALL_FRAME_INFO_TEST) $(dir $(CALL_FRAME_INFO_FIXTURES))

# Mount options, owners of FAT and exFAT, the mount table and /etc/fstab
# (FileSystem.MountOptions, .OwnerMapping, .MountTable, Sys.MountTable)
# on the host.
MOUNT_TEST := build/tools/MountTest

$(MOUNT_TEST): tools/MountTest/MountTest.pas kernel/filesystems/FileSystem.MountOptions.pas \
		kernel/filesystems/FileSystem.OwnerMapping.pas kernel/filesystems/FileSystem.MountTable.pas \
		userland/lib/system/Sys.MountTable.pas
	@mkdir -p build/tools/mount-test-units
	$(FPC) -O2 -Cr -Co -Fukernel/filesystems -Fuuserland/lib/system -FEbuild/tools \
		-FUbuild/tools/mount-test-units $<

mount-test: $(MOUNT_TEST)
	$(MOUNT_TEST)

# The kernel's ext2/3/4, FAT and exFAT drivers on the host, against disk
# images damaged on purpose (made by make-images.py with mke2fs, mkfs.fat,
# mtools and mkfs.exfat) and copies damaged at random: they may refuse,
# mount read-only or report corruption, never crash, hang, leak or write
# outside their buffers. The kernel's block cache, heap, clock and mutexes
# are stood in for (tools/FileSystemImageTest/stubs).
FILE_SYSTEM_IMAGE_TEST := build/tools/FileSystemImageTest
FILE_SYSTEM_IMAGES := build/tools/fs-images
FILE_SYSTEM_FUZZ_ITERATIONS ?= 400

$(FILE_SYSTEM_IMAGE_TEST): tools/FileSystemImageTest/FileSystemImageTest.pas tools/FileSystemImageTest/ImageHarness.pas \
		tools/FileSystemImageTest/ImageMutations.pas $(wildcard tools/FileSystemImageTest/stubs/*.pas) \
		$(wildcard kernel/filesystems/FileSystem.Ext*.pas) $(wildcard kernel/filesystems/FileSystem.Fat*.pas) \
		$(wildcard kernel/filesystems/FileSystem.ExFat*.pas) kernel/filesystems/FileSystem.Types.pas
	@mkdir -p build/tools/fs-image-units
	$(FPC) -O1 -gl -Cr -Futools/FileSystemImageTest/stubs -Futools/FileSystemImageTest -Fukernel/filesystems \
		-Fukernel/runtime -Fushared -FEbuild/tools -FUbuild/tools/fs-image-units $<

$(FILE_SYSTEM_IMAGES)/MANIFEST: tools/FileSystemImageTest/make-images.py
	python3 -I $< $(FILE_SYSTEM_IMAGES)

.PHONY: file-system-image-test
file-system-image-test: $(FILE_SYSTEM_IMAGE_TEST) $(FILE_SYSTEM_IMAGES)/MANIFEST
	$(FILE_SYSTEM_IMAGE_TEST) $(FILE_SYSTEM_IMAGES)/MANIFEST
	@for image in ext2 ext4 ext4-plain fat12 fat16 exfat; do \
		$(FILE_SYSTEM_IMAGE_TEST) --fuzz $(FILE_SYSTEM_IMAGES)/$$image.img $(FILE_SYSTEM_FUZZ_ITERATIONS) 1 || exit 1; \
	done

# The kernel's random number core (ChaCha20, against RFC 8439) and the
# randomized address space layouts (Processes.AddressLayout) on the host.
ASLR_TEST := build/tools/AslrTest

$(ASLR_TEST): tools/AslrTest/AslrTest.pas kernel/core/Kernel.ChaCha20.pas kernel/processes/Processes.AddressLayout.pas
	@mkdir -p build/tools/aslr-units
	$(FPC) -O2 -Cr -Co -Fukernel/core -Fukernel/processes -FEbuild/tools -FUbuild/tools/aslr-units $<

aslr-test: $(ASLR_TEST)
	$(ASLR_TEST)

# The platform device walk (kernel/firmware) on the host, over a table
# tools/AcpiDeviceTest/make-table.py assembles.
ACPI_DEVICE_TEST := build/tools/AcpiDeviceTest
ACPI_DEVICE_TABLE := build/tools/acpi-device-test.aml

$(ACPI_DEVICE_TEST): tools/AcpiDeviceTest/AcpiDeviceTest.pas $(AML_TEST_SOURCES)
	@mkdir -p build/tools/acpi-device-units
	$(FPC) -O2 -Fukernel/firmware -Fushared -FEbuild/tools -FUbuild/tools/acpi-device-units $<

$(ACPI_DEVICE_TABLE): tools/AcpiDeviceTest/make-table.py
	@mkdir -p build/tools
	python3 -I $< $@

acpi-device-test: $(ACPI_DEVICE_TEST) $(ACPI_DEVICE_TABLE)
	$(ACPI_DEVICE_TEST) $(ACPI_DEVICE_TABLE)

# Thermal zones, batteries and _CST (kernel/firmware) on the host, over a
# table tools/AcpiPowerTest/make-table.py assembles (with --ssdt, the
# same zones and batteries as an SSDT for QEMU's -acpitable).
ACPI_POWER_TEST := build/tools/AcpiPowerTest
ACPI_POWER_TABLE := build/tools/acpi-power-test.aml

$(ACPI_POWER_TEST): tools/AcpiPowerTest/AcpiPowerTest.pas $(AML_TEST_SOURCES)
	@mkdir -p build/tools/acpi-power-units
	$(FPC) -O2 -Fukernel/firmware -Fushared -FEbuild/tools -FUbuild/tools/acpi-power-units $<

$(ACPI_POWER_TABLE): tools/AcpiPowerTest/make-table.py
	@mkdir -p build/tools
	python3 -I $< $@

acpi-power-test: $(ACPI_POWER_TEST) $(ACPI_POWER_TABLE)
	$(ACPI_POWER_TEST) $(ACPI_POWER_TABLE)

# The timesync service's SNTP code (userland/timesync) on the host:
# packets, corrections, and requests over UDP to tools/SntpTest's small
# server on 127.0.0.1 (its clock 1234.5 s ahead, and a kiss of death).
SNTP_TEST := build/tools/SntpTest
SNTP_PORT_FILE := build/tools/sntp-test-ports

$(SNTP_TEST): tools/SntpTest/SntpTest.pas userland/timesync/TimeSync.Packets.pas userland/timesync/TimeSync.Corrections.pas
	@mkdir -p build/tools/sntp-units
	$(FPC) -O2 -Cr -Fuuserland/timesync -FEbuild/tools -FUbuild/tools/sntp-units $<

sntp-test: $(SNTP_TEST)
	@: > $(SNTP_PORT_FILE); \
	python3 -I tools/SntpTest/sntp-server.py $(SNTP_PORT_FILE) & server=$$!; \
	for attempt in $$(seq 50); do [ -s $(SNTP_PORT_FILE) ] && break; sleep 0.1; done; \
	$(SNTP_TEST) $(SNTP_PORT_FILE); status=$$?; kill $$server 2> /dev/null; exit $$status

# The device tree reading (shared/DeviceTree.*, kernel/firmware) on the
# host, over a tree in the Raspberry Pi 5's layout that
# tools/DeviceTreeTest/make-tree.py encodes.
DEVICE_TREE_TEST := build/tools/DeviceTreeTest
DEVICE_TREE_BLOB := build/tools/device-tree-test.dtb
DEVICE_TREE_TEST_SOURCES := tools/DeviceTreeTest/DeviceTreeTest.pas $(wildcard shared/DeviceTree.*.pas) \
	$(wildcard kernel/firmware/Firmware.DeviceTree*.pas)

$(DEVICE_TREE_TEST): $(DEVICE_TREE_TEST_SOURCES)
	@mkdir -p build/tools/device-tree-units
	$(FPC) -O2 -Fukernel/firmware -Fushared -FEbuild/tools -FUbuild/tools/device-tree-units $<

$(DEVICE_TREE_BLOB): tools/DeviceTreeTest/make-tree.py
	@mkdir -p build/tools
	python3 -I $< $@

device-tree-test: $(DEVICE_TREE_TEST) $(DEVICE_TREE_BLOB)
	$(DEVICE_TREE_TEST) $(DEVICE_TREE_BLOB)

# The Raspberry Pi 5 Ethernet's descriptors (Drivers.CadenceGem.Descriptors).
GEM_DESCRIPTOR_TEST := build/tools/GemDescriptorTest

$(GEM_DESCRIPTOR_TEST): tools/GemDescriptorTest/GemDescriptorTest.pas kernel/drivers/network/Drivers.CadenceGem.Descriptors.pas
	@mkdir -p build/tools/gem-descriptor-units
	$(FPC) -O2 -Cr -Fukernel/drivers/network -FEbuild/tools -FUbuild/tools/gem-descriptor-units $<

gem-descriptor-test: $(GEM_DESCRIPTOR_TEST)
	$(GEM_DESCRIPTOR_TEST)

# What a virtio device writes into a used ring, checked (Drivers.VirtioUsedRing).
VIRTIO_USED_RING_TEST := build/tools/VirtioUsedRingTest

$(VIRTIO_USED_RING_TEST): tools/VirtioUsedRingTest/VirtioUsedRingTest.pas kernel/drivers/virtio/Drivers.VirtioUsedRing.pas
	@mkdir -p build/tools/virtio-used-ring-units
	$(FPC) -O2 -Cr -Fukernel/drivers/virtio -FEbuild/tools -FUbuild/tools/virtio-used-ring-units $<

virtio-used-ring-test: $(VIRTIO_USED_RING_TEST)
	$(VIRTIO_USED_RING_TEST)

# The Raspberry Pi 5's HDMI audio without the hardware: N/CTS against the
# HDMI table, the MAI's sample clock, IEC 60958 subframes, the audio
# InfoFrame (Drivers.HdmiAudio.Format) and the BCM2712 DMA's control
# blocks (Drivers.Bcm2712Dma.Blocks).
HDMI_AUDIO_TEST := build/tools/HdmiAudioTest

$(HDMI_AUDIO_TEST): tools/HdmiAudioTest/HdmiAudioTest.pas kernel/drivers/sound/Drivers.HdmiAudio.Format.pas \
		kernel/drivers/bus/Drivers.Bcm2712Dma.Blocks.pas
	@mkdir -p build/tools/hdmi-audio-units
	$(FPC) -O2 -Cr -Fukernel/drivers/sound -Fukernel/drivers/bus -FEbuild/tools -FUbuild/tools/hdmi-audio-units $<

hdmi-audio-test: $(HDMI_AUDIO_TEST)
	$(HDMI_AUDIO_TEST)

# USB configuration descriptors walked into interfaces, and HID report
# descriptors and reports routed by id (Drivers.UsbDescriptors,
# Drivers.HidReports), over a keyboard and mouse receiver's descriptors;
# hostile and fuzzed descriptors read from guarded buffers; the xHCI
# ring and transfer bookkeeping (Drivers.XhciTrbs, Drivers.XhciTransfers).
USB_DESCRIPTOR_TEST := build/tools/UsbDescriptorTest
# The host's runtime units (Runtime.Atomic: barriers) for host tests of
# kernel code that uses them.
HOST_RUNTIME_ARCH := $(if $(filter aarch64 arm64,$(shell uname -m)),arm64,amd64)

$(USB_DESCRIPTOR_TEST): tools/UsbDescriptorTest/UsbDescriptorTest.pas kernel/drivers/usb/Drivers.UsbDescriptors.pas \
		kernel/drivers/usb/Drivers.HidReports.pas kernel/drivers/usb/Drivers.XhciTrbs.pas \
		kernel/drivers/usb/Drivers.XhciTransfers.pas shared/Runtime.Memory.pas \
		$(wildcard tools/UsbDescriptorTest/*.pas)
	@mkdir -p build/tools/usb-descriptor-units
	$(FPC) -O2 -Cr -Fukernel/drivers/usb -Fushared -Fukernel/runtime/$(HOST_RUNTIME_ARCH) \
		-Futools/UsbDescriptorTest -FEbuild/tools -FUbuild/tools/usb-descriptor-units $<

usb-descriptor-test: $(USB_DESCRIPTOR_TEST)
	$(USB_DESCRIPTOR_TEST)

# NVMe queue pairs with the controller played in memory: identifiers,
# phase wraps, and a late completion of a command given up dropped
# instead of taken for the next one's (Drivers.NvmeQueues).
NVME_QUEUE_TEST := build/tools/NvmeQueueTest

$(NVME_QUEUE_TEST): tools/NvmeQueueTest/NvmeQueueTest.pas kernel/drivers/storage/Drivers.NvmeQueues.pas \
		shared/Runtime.Memory.pas
	@mkdir -p build/tools/nvme-queue-units
	$(FPC) -O2 -Cr -Fukernel/drivers/storage -Fushared -Fukernel/runtime/$(HOST_RUNTIME_ARCH) \
		-FEbuild/tools -FUbuild/tools/nvme-queue-units $<

nvme-queue-test: $(NVME_QUEUE_TEST)
	$(NVME_QUEUE_TEST)

# ACPI tables refused before use when their length does not cover their
# header or their checksum fails; root table entry counts that cannot
# underflow (Firmware.AcpiTableChecks).
ACPI_TABLE_TEST := build/tools/AcpiTableTest

$(ACPI_TABLE_TEST): tools/AcpiTableTest/AcpiTableTest.pas kernel/firmware/Firmware.AcpiTableChecks.pas
	@mkdir -p build/tools/acpi-table-units
	$(FPC) -O2 -Cr -Fukernel/firmware -FEbuild/tools -FUbuild/tools/acpi-table-units $<

acpi-table-test: $(ACPI_TABLE_TEST)
	$(ACPI_TABLE_TEST)

# The kernel TCP's pure parts: options (MSS, window scale, SACK,
# timestamps) written and read, window scaling and buffer growth, the
# SACK scoreboard of RFC 6675 and the receiver's SACK blocks; SipHash and
# the keyed numbers (ISNs, ports, identifications), RFC 5961's checks and
# the token buckets.
TCP_TEST := build/tools/TcpTest
TCP_TEST_SOURCES := tools/TcpTest/TcpTest.pas kernel/network/Network.TcpSequences.pas \
	kernel/network/Network.TcpOptions.pas kernel/network/Network.TcpWindows.pas \
	kernel/network/Network.TcpScoreboard.pas kernel/network/Network.TcpReceivedBlocks.pas \
	kernel/network/Network.ByteOrder.pas shared/Runtime.Memory.pas kernel/network/Network.SipHash.pas \
	kernel/network/Network.KeyedNumbers.pas kernel/network/Network.TcpAcceptance.pas \
	kernel/network/Network.TokenBuckets.pas

$(TCP_TEST): $(TCP_TEST_SOURCES)
	@mkdir -p build/tools/tcp-test-units
	$(FPC) -O2 -Cr -Fukernel/network -Fushared -FEbuild/tools -FUbuild/tools/tcp-test-units $<

tcp-test: $(TCP_TEST)
	$(TCP_TEST)

font: $(FONT_TOOL)
	zcat -f $(FONT_SOURCE) > $(FONT_UNPACKED)
	$(FONT_TOOL) $(FONT_UNPACKED) kernel/debug/Debug.ConsoleFont.inc

# The fonts the host tests lay pages out with (their expected layouts
# were made with these): the base set of userland/fonts, DejaVu Sans and
# Sans Mono regular and bold.
BASE_FONTS_DIRECTORY := build/tools/base-fonts
BASE_FONTS_STAMP := $(BASE_FONTS_DIRECTORY)/.installed
$(BASE_FONTS_STAMP): $(OUTLINE_FONT_FILES) $(FONT_SCRIPTS)
	python3 -B scripts/install-fonts.py scripts/fonts.list $(OUTLINE_FONT_SOURCE) $(BASE_FONTS_DIRECTORY) --set base
	@touch $@

# The outline fonts in userland/fonts refreshed from the build machine's
# font packages, with their licences checked (scripts/update-fonts.py);
# run by hand, then look at what changed before committing it.
update-fonts:
	python3 -B scripts/update-fonts.py scripts/fonts.list $(OUTLINE_FONT_SOURCE)

# libdrawing and libfont are plain Pascal: they build for the host too,
# and are checked there pixel by pixel (with the system's fonts, Terminus
# and DejaVu Sans).
DRAWING_TEST := build/tools/DrawingTest
DRAWING_TEST_SOURCES := $(wildcard tools/DrawingTest/*.pas) $(wildcard userland/lib/drawing/*.pas) \
	$(filter-out %/Font.Files.pas,$(wildcard userland/lib/font/*.pas))

$(DRAWING_TEST): $(DRAWING_TEST_SOURCES)
	@mkdir -p build/tools/drawing-test-units
	fpc -Mobjfpc -O2 -vew -Futools/DrawingTest -Fuuserland/lib/drawing -Fuuserland/lib/font \
		-FUbuild/tools/drawing-test-units \
		-o$@ tools/DrawingTest/DrawingTest.pas

drawing-test: $(DRAWING_TEST) $(SYSTEM_FONTS_STAMP)
	@$(DRAWING_TEST) $(SYSTEM_FONT_DIRECTORY) $(DEJAVU_SANS_DIRECTORY) build/tools/drawing-sample.ppm \
		> build/tools/drawing-test.out || \
		{ grep FAIL build/tools/drawing-test.out; echo "DRAWING TEST FAILED (build/tools/drawing-test.out)"; exit 1; }
	@echo "DRAWING TEST PASSED: $$(tail -n 1 build/tools/drawing-test.out | cut -d ' ' -f 2-)"

# libfont's TrueType fonts on the host (with range checks), against
# FreeType: fixtures made at build time by tools/FontTest/make-font-fixtures.py
# (fonts put together byte by byte, broken copies, and what FreeType and
# HarfBuzz make of those and of DejaVu Sans; freetype-py, else the
# FreeType library through ctypes, and Pillow).
FONT_TEST := build/tools/FontTest
FONT_FIXTURES := build/tools/font-fixtures
FONT_FIXTURES_STAMP := $(FONT_FIXTURES)/.made
FONT_FIXTURE_SCRIPTS := tools/FontTest/make-font-fixtures.py tools/FontTest/freetypereference.py
FONT_TEST_SOURCES := $(wildcard tools/FontTest/*.pas) $(wildcard userland/lib/drawing/*.pas) \
	$(filter-out %/Font.Files.pas,$(wildcard userland/lib/font/*.pas)) userland/lib/web/Web.Text.Woff2.pas \
	$(wildcard userland/lib/image/*.pas) $(wildcard userland/lib/compression/*.pas)

$(FONT_TEST): $(FONT_TEST_SOURCES)
	@mkdir -p build/tools/font-test-units
	fpc -Mobjfpc -O2 -Cr -vew -Futools/FontTest -Fuuserland/lib/drawing -Fuuserland/lib/font -Fuuserland/lib/image \
		-Fuuserland/lib/compression -Fuuserland/lib/web -FUbuild/tools/font-test-units -o$@ tools/FontTest/FontTest.pas

$(FONT_FIXTURES_STAMP): $(FONT_FIXTURE_SCRIPTS) $(OUTLINE_FONT_FILES)
	@python3 -c 'import PIL' 2>/dev/null || { echo "Python 3 with Pillow (PIL) is needed for the font test's references (python-pillow)"; exit 1; }
	@rm -rf $(FONT_FIXTURES)
	python3 -B tools/FontTest/make-font-fixtures.py $(FONT_FIXTURES) userland/fonts
	@touch $@

font-test: $(FONT_TEST) $(FONT_FIXTURES_STAMP)
	@$(FONT_TEST) $(FONT_FIXTURES) > build/tools/font-test.out || \
		{ grep FAIL build/tools/font-test.out; echo "FONT TEST FAILED (build/tools/font-test.out)"; exit 1; }
	@echo "FONT TEST PASSED: $$(tail -n 1 build/tools/font-test.out | cut -d ' ' -f 2-)"

# The plain logic behind the multi-line edit box (positions, the undo
# history, word wrap, search) builds for the host too, and is checked
# there.
TEXT_TEST := build/tools/TextTest
TEXT_TEST_SOURCES := tools/TextTest/TextTest.pas userland/lib/controls/Controls.TextPositions.pas \
	userland/lib/controls/Controls.TextUndo.pas userland/lib/controls/Controls.TextWrap.pas \
	userland/lib/controls/Controls.TextSearch.pas userland/lib/font/Font.Utf8.pas

$(TEXT_TEST): $(TEXT_TEST_SOURCES)
	@mkdir -p build/tools/text-test-units
	fpc -Mobjfpc -O2 -vew -Futools/TextTest -Fuuserland/lib/controls -Fuuserland/lib/font \
		-FUbuild/tools/text-test-units -o$@ tools/TextTest/TextTest.pas

text-test: $(TEXT_TEST)
	@$(TEXT_TEST) > build/tools/text-test.out || \
		{ grep FAIL build/tools/text-test.out; echo "TEXT TEST FAILED (build/tools/text-test.out)"; exit 1; }
	@echo "TEXT TEST PASSED: $$(tail -n 1 build/tools/text-test.out | cut -d ' ' -f 2-)"

# The chart control's plain logic (nice ticks, ranges, formats, stacking,
# pie angles, what is under the pointer) and its drawing, which needs
# only libdrawing and libfont, build for the host too: checked there,
# charts drawn on surfaces and looked at pixel by pixel; a sample picture
# with DejaVu Sans is written to build/tools/chart-sample.ppm.
CHART_TEST := build/tools/ChartTest
CHART_TEST_SOURCES := $(wildcard tools/ChartTest/*.pas) $(wildcard userland/lib/controls/Controls.Chart?*.pas) \
	$(wildcard userland/lib/drawing/*.pas) $(filter-out %/Font.Files.pas,$(wildcard userland/lib/font/*.pas))

$(CHART_TEST): $(CHART_TEST_SOURCES)
	@mkdir -p build/tools/chart-test-units
	fpc -Mobjfpc -O2 -Cr -vew -Futools/ChartTest -Fuuserland/lib/controls -Fuuserland/lib/drawing \
		-Fuuserland/lib/font -FUbuild/tools/chart-test-units -o$@ tools/ChartTest/ChartTest.pas

chart-test: $(CHART_TEST)
	@$(CHART_TEST) $(DEJAVU_SANS_DIRECTORY) build/tools/chart-sample.ppm > build/tools/chart-test.out || \
		{ grep FAIL build/tools/chart-test.out; echo "CHART TEST FAILED (build/tools/chart-test.out)"; exit 1; }
	@echo "CHART TEST PASSED: $$(tail -n 1 build/tools/chart-test.out)"

# Paint's plain logic (zoom mapping, the geometry of dragging, file
# formats, the undo history) and its work on pixels (flood fill with a
# tolerance, shapes and strokes and their extents, the selection, the
# Image menu's transforms, the zoomed view) need only libimage and
# libdrawing, so they build for the host too and are checked there.
PAINT_TEST := build/tools/PaintTest
PAINT_TEST_SOURCES := $(wildcard tools/PaintTest/*.pas) $(wildcard userland/paint/*.pas) \
	$(wildcard userland/lib/drawing/*.pas) $(wildcard userland/lib/image/*.pas) \
	$(wildcard userland/lib/compression/*.pas)

$(PAINT_TEST): $(PAINT_TEST_SOURCES)
	@mkdir -p build/tools/paint-test-units
	fpc -Mobjfpc -O2 -Cr -vew -Futools/PaintTest -Fuuserland/paint -Fuuserland/lib/image -Fuuserland/lib/drawing \
		-Fuuserland/lib/compression -FUbuild/tools/paint-test-units -o$@ tools/PaintTest/PaintTest.pas

paint-test: $(PAINT_TEST)
	@$(PAINT_TEST) > build/tools/paint-test.out || \
		{ grep FAIL build/tools/paint-test.out; echo "PAINT TEST FAILED (build/tools/paint-test.out)"; exit 1; }
	@echo "PAINT TEST PASSED: $$(tail -n 1 build/tools/paint-test.out)"

# The file manager's plain logic (paths, numbered names, the history,
# the order and types of items, permissions, what a drop does, natural
# order, the search syntax, batch names, undo, conflicts, type
# associations, the trash's info files, grouping, WAV headers) and the
# libraries' file lists and typing to find a name build for the host
# too, and are checked there.
FILES_TEST := build/tools/FilesTest
FILES_TEST_SOURCES := tools/FilesTest/FilesTest.pas userland/lib/controls/Controls.DragData.pas \
	userland/lib/controls/Controls.FileLists.pas userland/lib/controls/Controls.Clipboard.pas \
	userland/lib/controls/Controls.TypeAhead.pas userland/lib/controls/Controls.TextPositions.pas \
	userland/lib/controls/Controls.FileNames.pas userland/files/FileManager.Items.pas \
	userland/files/FileManager.Paths.pas userland/files/FileManager.ConflictNames.pas \
	userland/files/FileManager.History.pas userland/files/FileManager.FileTypes.pas \
	userland/files/FileManager.ItemOrder.pas userland/files/FileManager.Permissions.pas \
	userland/files/FileManager.DropRules.pas userland/lib/font/Font.Utf8.pas tools/FilesTest/FilesTest.Explorer.pas \
	userland/lib/controls/Controls.NaturalOrder.pas userland/lib/coreutils/Util.TrashInfo.pas \
	userland/files/FileManager.FileKinds.pas userland/files/FileManager.CivilDates.pas \
	userland/files/FileManager.SearchQuery.pas userland/files/FileManager.BatchNames.pas \
	userland/files/FileManager.UndoHistory.pas userland/files/FileManager.ConflictPolicy.pas \
	userland/files/FileManager.TypeAssociations.pas userland/lib/configuration/Configuration.ProgramInfo.pas \
	userland/files/FileManager.Grouping.pas userland/files/FileManager.AudioInfo.pas \
	userland/files/FileManager.ArchiveSearch.pas tools/FilesTest/FilesTest.ArchiveSearch.pas \
	$(wildcard userland/lib/archive/*.pas)

$(FILES_TEST): $(FILES_TEST_SOURCES)
	@mkdir -p build/tools/files-test-units
	fpc -Mobjfpc -O2 -vew -Futools/FilesTest -Fuuserland/lib/controls -Fuuserland/lib/font -Fuuserland/files \
		-Fuuserland/lib/configuration -Fiuserland/lib/configuration -Fuuserland/lib/coreutils \
		-Fuuserland/lib/archive -Fuuserland/lib/compression \
		-FUbuild/tools/files-test-units -o$@ tools/FilesTest/FilesTest.pas

files-test: $(FILES_TEST)
	@$(FILES_TEST) > build/tools/files-test.out || \
		{ grep FAIL build/tools/files-test.out; echo "FILES TEST FAILED (build/tools/files-test.out)"; exit 1; }
	@echo "FILES TEST PASSED: $$(tail -n 1 build/tools/files-test.out | cut -d ' ' -f 2-)"

# The browser's plain logic (addresses and keywords, the history's
# queries, bookmark folders and tags, the location bar's suggestions,
# the session file, the search engines) builds for the host too.
BROWSER_TEST := build/tools/BrowserTest
BROWSER_TEST_SOURCES := tools/BrowserTest/BrowserTest.pas userland/browser/Browser.TextFiles.pas \
	userland/browser/Browser.Addresses.pas userland/browser/Browser.History.pas \
	userland/browser/Browser.Bookmarks.pas userland/browser/Browser.AwesomeBar.pas \
	userland/browser/Browser.SessionStore.pas userland/browser/Browser.SearchEngines.pas \
	userland/browser/Browser.Keywords.pas userland/browser/Browser.ConsoleLog.pas \
	userland/browser/Browser.SourceColoring.pas userland/browser/Browser.Passwords.pas

$(BROWSER_TEST): $(BROWSER_TEST_SOURCES)
	@mkdir -p build/tools/browser-test-units
	fpc -Mobjfpc -O2 -Cr -vew -Futools/BrowserTest -Fuuserland/browser -FUbuild/tools/browser-test-units -o$@ \
		tools/BrowserTest/BrowserTest.pas

browser-test: $(BROWSER_TEST)
	@$(BROWSER_TEST) > build/tools/browser-test.out || \
		{ grep FAIL build/tools/browser-test.out; echo "BROWSER TEST FAILED (build/tools/browser-test.out)"; exit 1; }
	@echo "BROWSER TEST PASSED: $$(tail -n 1 build/tools/browser-test.out | cut -d ' ' -f 2-)"

# libcontrols' layout arithmetic (anchors, docking, constraints, flow and
# table arrangement, split containers, scrolling) builds for the host
# too, and is checked there.
CONTROLS_TEST := build/tools/ControlsTest
CONTROLS_TEST_SOURCES := tools/ControlsTest/ControlsTest.pas userland/lib/controls/Controls.LayoutRules.pas \
	userland/lib/controls/Controls.FlowArrangement.pas userland/lib/controls/Controls.TableArrangement.pas \
	userland/lib/controls/Controls.SplitRules.pas userland/lib/drawing/Drawing.Rectangles.pas

$(CONTROLS_TEST): $(CONTROLS_TEST_SOURCES)
	@mkdir -p build/tools/controls-test-units
	fpc -Mobjfpc -O2 -Cr -vew -Futools/ControlsTest -Fuuserland/lib/controls -Fuuserland/lib/drawing \
		-FUbuild/tools/controls-test-units -o$@ tools/ControlsTest/ControlsTest.pas

controls-test: $(CONTROLS_TEST)
	@$(CONTROLS_TEST) > build/tools/controls-test.out || \
		{ grep FAIL build/tools/controls-test.out; echo "CONTROLS TEST FAILED (build/tools/controls-test.out)"; exit 1; }
	@echo "CONTROLS TEST PASSED: $$(tail -n 1 build/tools/controls-test.out | cut -d ' ' -f 2-)"

# The plain logic of the calculator (numbers, arithmetic, expressions,
# keys), the image viewer (zoom and pan, turning, the folder's images)
# and the volume control (peak levels) builds for the host too, and is
# checked there.
APPS_TEST := build/tools/AppsTest
APPS_TEST_SOURCES := $(wildcard tools/AppsTest/*.pas) $(wildcard userland/calculator/Calculator.*.pas) \
	$(wildcard userland/imageviewer/ImageViewer.*.pas) $(wildcard userland/volumecontrol/VolumeControl.*.pas)

$(APPS_TEST): $(APPS_TEST_SOURCES)
	@mkdir -p build/tools/apps-test-units
	fpc -Mobjfpc -O2 -Cr -vew -Futools/AppsTest -Fuuserland/calculator -Fuuserland/imageviewer \
		-Fuuserland/volumecontrol -FUbuild/tools/apps-test-units -o$@ tools/AppsTest/AppsTest.pas

apps-test: $(APPS_TEST)
	@$(APPS_TEST) > build/tools/apps-test.out || \
		{ grep FAIL build/tools/apps-test.out; echo "APPS TEST FAILED (build/tools/apps-test.out)"; exit 1; }
	@echo "APPS TEST PASSED: $$(tail -n 1 build/tools/apps-test.out | cut -d ' ' -f 2-)"

# The date and number logic behind libcontrols' calendar, date and time
# picker and numeric up/down box (and where the calendar's parts go)
# builds for the host too, and is checked there.
DATE_CONTROLS_TEST := build/tools/DateControlsTest
DATE_CONTROLS_TEST_SOURCES := tools/DateControlsTest/DateControlsTest.pas \
	userland/lib/controls/Controls.CalendarDates.pas userland/lib/controls/Controls.CalendarLayout.pas \
	userland/lib/controls/Controls.DateFormats.pas userland/lib/controls/Controls.NumericValues.pas \
	userland/lib/drawing/Drawing.Rectangles.pas

$(DATE_CONTROLS_TEST): $(DATE_CONTROLS_TEST_SOURCES)
	@mkdir -p build/tools/date-controls-test-units
	fpc -Mobjfpc -O2 -vew -Futools/DateControlsTest -Fuuserland/lib/controls -Fuuserland/lib/drawing \
		-FUbuild/tools/date-controls-test-units -o$@ tools/DateControlsTest/DateControlsTest.pas

date-controls-test: $(DATE_CONTROLS_TEST)
	@$(DATE_CONTROLS_TEST) > build/tools/date-controls-test.out || \
		{ grep FAIL build/tools/date-controls-test.out; echo "DATE CONTROLS TEST FAILED (build/tools/date-controls-test.out)"; exit 1; }
	@echo "DATE CONTROLS TEST PASSED: $$(tail -n 1 build/tools/date-controls-test.out | cut -d ' ' -f 2-)"

# The plain logic behind libcontrols' tab strip, breadcrumb bar, command
# bar and progress dialog (where their parts go, transfer rates and
# their texts) builds for the host too, and is checked there.
NAVIGATION_CONTROLS_TEST := build/tools/NavigationControlsTest
NAVIGATION_CONTROLS_TEST_SOURCES := tools/NavigationControlsTest/NavigationControlsTest.pas \
	userland/lib/controls/Controls.TransferRates.pas userland/lib/controls/Controls.TabStripLayout.pas \
	userland/lib/controls/Controls.BreadcrumbLayout.pas userland/lib/controls/Controls.CommandLayout.pas

$(NAVIGATION_CONTROLS_TEST): $(NAVIGATION_CONTROLS_TEST_SOURCES)
	@mkdir -p build/tools/navigation-controls-test-units
	fpc -Mobjfpc -O2 -Cr -vew -Futools/NavigationControlsTest -Fuuserland/lib/controls \
		-FUbuild/tools/navigation-controls-test-units -o$@ tools/NavigationControlsTest/NavigationControlsTest.pas

navigation-controls-test: $(NAVIGATION_CONTROLS_TEST)
	@$(NAVIGATION_CONTROLS_TEST) > build/tools/navigation-controls-test.out || \
		{ grep FAIL build/tools/navigation-controls-test.out; echo "NAVIGATION CONTROLS TEST FAILED (build/tools/navigation-controls-test.out)"; exit 1; }
	@echo "NAVIGATION CONTROLS TEST PASSED: $$(tail -n 1 build/tools/navigation-controls-test.out | cut -d ' ' -f 2-)"

# The settings library (libconfiguration) but for its files builds for
# the host too, and is checked there over a storage in memory.
SETTINGS_TEST := build/tools/SettingsTest
SETTINGS_TEST_SOURCES := $(wildcard tools/SettingsTest/*.pas) shared/Abi.SystemCalls.pas shared/Abi.SystemCalls.inc \
	shared/Abi.Networking.inc shared/Runtime.Memory.pas shared/Runtime.Text.pas \
	userland/lib/system/Sys.InternetAddresses.pas \
	$(filter-out %/Configuration.FileStorage.pas %/Configuration.Locations.pas %/Configuration.Contents.pas \
		%/Configuration.NetworkStatus.pas, $(wildcard userland/lib/configuration/*.pas))

$(SETTINGS_TEST): $(SETTINGS_TEST_SOURCES)
	@mkdir -p build/tools/settings-test-units
	fpc -Mobjfpc -O2 -vew -Futools/SettingsTest -Fuuserland/lib/configuration -Fuuserland/lib/system \
		-Fushared -Fishared -FUbuild/tools/settings-test-units -o$@ tools/SettingsTest/SettingsTest.pas

settings-test: $(SETTINGS_TEST)
	@$(SETTINGS_TEST) > build/tools/settings-test.out || \
		{ grep -A2 FAIL build/tools/settings-test.out; echo "SETTINGS TEST FAILED (build/tools/settings-test.out)"; exit 1; }
	@echo "SETTINGS TEST PASSED: $$(tail -n 1 build/tools/settings-test.out | cut -d ' ' -f 2-)"

# libcryptography's algorithms for TLS (all but Crypto.Random, which needs
# the kernel) build for the host too, and are checked there against
# published known answers.
CRYPTO_TEST := build/tools/CryptoTest
CRYPTO_TEST_SOURCES := $(wildcard tools/CryptoTest/*.pas) tools/CryptoTest/CryptoTest.RsaVectors.inc \
	$(filter-out %/Crypto.Random.pas %/Crypto.Contents.pas %/Crypto.MlKemRandom.pas,$(wildcard userland/lib/cryptography/*.pas))
# ECDH and P-521 answers from Python's cryptography (OpenSSL).
CRYPTO_CURVE_VECTORS := build/tools/crypto-test-units/CryptoTest.CurveVectors.inc

$(CRYPTO_CURVE_VECTORS): tools/CryptoTest/make-curve-vectors.py
	@mkdir -p build/tools/crypto-test-units
	python3 -I tools/CryptoTest/make-curve-vectors.py > $@.tmp
	@mv $@.tmp $@

# SHA-3 and ML-KEM-768 answers from Python's hashlib and cryptography.
CRYPTO_POST_QUANTUM_VECTORS := build/tools/crypto-test-units/CryptoTest.PostQuantumVectors.inc

$(CRYPTO_POST_QUANTUM_VECTORS): tools/CryptoTest/make-post-quantum-vectors.py
	@mkdir -p build/tools/crypto-test-units
	@python3 -I -c 'from cryptography.hazmat.primitives.asymmetric import mlkem' 2>/dev/null || { echo "Python 3 with the cryptography package (with ML-KEM) is needed for the crypto test's vectors"; exit 1; }
	python3 -I tools/CryptoTest/make-post-quantum-vectors.py > $@.tmp
	@mv $@.tmp $@

$(CRYPTO_TEST): $(CRYPTO_TEST_SOURCES) $(CRYPTO_POST_QUANTUM_VECTORS) $(CRYPTO_CURVE_VECTORS)
	@mkdir -p build/tools/crypto-test-units
	fpc -Mobjfpc -O2 -vew -Futools/CryptoTest -Fuuserland/lib/cryptography -Fushared -Fishared \
		-Fibuild/tools/crypto-test-units -FUbuild/tools/crypto-test-units -o$@ tools/CryptoTest/CryptoTest.pas

crypto-test: $(CRYPTO_TEST)
	@$(CRYPTO_TEST) > build/tools/crypto-test.out || \
		{ grep -A2 FAIL build/tools/crypto-test.out; echo "CRYPTO TEST FAILED (build/tools/crypto-test.out)"; exit 1; }
	@echo "CRYPTO TEST PASSED: $$(tail -n 1 build/tools/crypto-test.out | cut -d ' ' -f 3-)"

# libcss builds for the host too and is checked there: tokenizer cases,
# round trips, selector matching through a test adapter, the cascade,
# computed values, media queries, shorthands, colors (the answers made by
# Python), and memory and sharing on a synthetic page.
CSS_TEST := build/tools/CssTest
CSS_TEST_UNITS := build/tools/css-test-units
CSS_COLOR_VECTORS := $(CSS_TEST_UNITS)/CssTest.ColorVectors.inc
CSS_TEST_SOURCES := $(wildcard tools/CssTest/*.pas) tools/CryptoTest/TestChecks.pas \
	$(filter-out %/Css.Contents.pas,$(wildcard userland/lib/css/*.pas))

$(CSS_COLOR_VECTORS): tools/CssTest/make-color-vectors.py
	@mkdir -p $(CSS_TEST_UNITS)
	python3 -I tools/CssTest/make-color-vectors.py > $@.tmp
	@mv $@.tmp $@

$(CSS_TEST): $(CSS_TEST_SOURCES) $(CSS_COLOR_VECTORS)
	@mkdir -p $(CSS_TEST_UNITS)
	fpc -Mobjfpc -O2 -Cr -vew -Futools/CssTest -Futools/CryptoTest -Fuuserland/lib/css \
		-Fi$(CSS_TEST_UNITS) -FU$(CSS_TEST_UNITS) -o$@ tools/CssTest/CssTest.pas

css-test: $(CSS_TEST)
	@$(CSS_TEST) > build/tools/css-test.out || \
		{ grep -A2 FAIL build/tools/css-test.out; echo "CSS TEST FAILED (build/tools/css-test.out)"; exit 1; }
	@grep -a '^info' build/tools/css-test.out | sed 's/^info /  /'
	@echo "CSS TEST PASSED: $$(tail -n 1 build/tools/css-test.out | cut -d ' ' -f 3-)"

# libsvg on the host (with libcss, libdrawing, libfont and libimage): small
# SVG documents drawn and their pixels probed where each feature decides
# the colour, with DejaVu Sans from userland/fonts for text. SvgTest FONTS
# IN.svg OUT.png W H draws a file, for looking at.
SVG_TEST := build/tools/SvgTest
SVG_TEST_UNITS := build/tools/svg-test-units
SVG_TEST_SOURCES := tools/SvgTest/SvgTest.pas tools/CryptoTest/TestChecks.pas \
	$(filter-out %/Svg.Contents.pas,$(wildcard userland/lib/svg/*.pas)) $(wildcard userland/lib/css/*.pas) \
	$(wildcard userland/lib/drawing/*.pas) $(wildcard userland/lib/font/*.pas) $(wildcard userland/lib/image/*.pas) \
	$(wildcard userland/lib/compression/*.pas)

$(SVG_TEST): $(SVG_TEST_SOURCES)
	@mkdir -p $(SVG_TEST_UNITS)
	fpc -Mobjfpc -O2 -Cr -vew -Futools/SvgTest -Futools/CryptoTest -Fuuserland/lib/svg -Fuuserland/lib/css \
		-Fuuserland/lib/font -Fuuserland/lib/drawing -Fuuserland/lib/image -Fuuserland/lib/compression \
		-FU$(SVG_TEST_UNITS) -o$@ tools/SvgTest/SvgTest.pas

svg-test: $(SVG_TEST)
	@$(SVG_TEST) userland/fonts > build/tools/svg-test.out || \
		{ grep FAIL build/tools/svg-test.out; echo "SVG TEST FAILED (build/tools/svg-test.out)"; exit 1; }
	@echo "SVG TEST PASSED: $$(tail -n 1 build/tools/svg-test.out | cut -d ' ' -f 3-)"

# libcompression builds for the host too, and is checked there against
# zlib's own output (made by Python's zlib when the test is built); what
# it compresses is then decompressed by Python's zlib and gzip. Its brotli
# and zstd decoders are checked over fixtures make-fixtures.py makes with
# the host's brotli and zstd programs.
COMPRESSION_TEST := build/tools/CompressionTest
COMPRESSION_TEST_UNITS := build/tools/compression-test-units
COMPRESSION_VECTORS := $(COMPRESSION_TEST_UNITS)/CompressionTest.Vectors.inc
COMPRESSION_SAMPLES := build/tools/compression-samples
COMPRESSION_FIXTURES := build/tools/compression-fixtures
COMPRESSION_TEST_SOURCES := $(wildcard tools/CompressionTest/*.pas) tools/CryptoTest/TestChecks.pas \
	$(filter-out %/Compression.Contents.pas,$(wildcard userland/lib/compression/*.pas)) \
	$(wildcard userland/lib/compression/*.inc)

$(COMPRESSION_FIXTURES)/manifest.txt: tools/CompressionTest/make-fixtures.py
	python3 -I $< $(COMPRESSION_FIXTURES)

$(COMPRESSION_VECTORS): tools/CompressionTest/make-vectors.py
	@mkdir -p $(COMPRESSION_TEST_UNITS)
	python3 tools/CompressionTest/make-vectors.py > $@.tmp
	@mv $@.tmp $@

$(COMPRESSION_TEST): $(COMPRESSION_TEST_SOURCES) $(COMPRESSION_VECTORS)
	@mkdir -p $(COMPRESSION_TEST_UNITS)
	fpc -Mobjfpc -O2 -Cr -vew -Futools/CompressionTest -Futools/CryptoTest -Fuuserland/lib/compression \
		-Fi$(COMPRESSION_TEST_UNITS) -FU$(COMPRESSION_TEST_UNITS) -o$@ tools/CompressionTest/CompressionTest.pas

compression-test: $(COMPRESSION_TEST) $(COMPRESSION_FIXTURES)/manifest.txt
	@mkdir -p $(COMPRESSION_SAMPLES)
	@$(COMPRESSION_TEST) $(COMPRESSION_SAMPLES) $(COMPRESSION_FIXTURES) > build/tools/compression-test.out || \
		{ grep -A2 FAIL build/tools/compression-test.out; echo "COMPRESSION TEST FAILED (build/tools/compression-test.out)"; exit 1; }
	@python3 tools/CompressionTest/check-with-zlib.py $(COMPRESSION_SAMPLES) > build/tools/compression-zlib.out || \
		{ cat build/tools/compression-zlib.out; echo "COMPRESSION TEST FAILED (zlib refuses what it compressed)"; exit 1; }
	@echo "COMPRESSION TEST PASSED: $$(tail -n 1 build/tools/compression-test.out | cut -d ' ' -f 3-)"

# libarchive builds for the host too (over libcompression): it reads the
# zip and tar files make-fixtures.py makes with Python's zipfile and
# tarfile, and the zips it writes are checked by check-written.py with
# Python's zipfile.
ARCHIVE_TEST := build/tools/ArchiveTest
ARCHIVE_TEST_UNITS := build/tools/archive-test-units
ARCHIVE_FIXTURES := build/tools/archive-fixtures
ARCHIVE_SAMPLES := build/tools/archive-samples
ARCHIVE_TEST_SOURCES := $(wildcard tools/ArchiveTest/*.pas) tools/CryptoTest/TestChecks.pas \
	$(filter-out %/Archive.Contents.pas,$(wildcard userland/lib/archive/*.pas)) \
	$(filter-out %/Compression.Contents.pas,$(wildcard userland/lib/compression/*.pas)) \
	$(wildcard userland/lib/compression/*.inc)

$(ARCHIVE_FIXTURES)/manifest.txt: tools/ArchiveTest/make-fixtures.py
	python3 -I $< $(ARCHIVE_FIXTURES)

$(ARCHIVE_TEST): $(ARCHIVE_TEST_SOURCES)
	@mkdir -p $(ARCHIVE_TEST_UNITS)
	fpc -Mobjfpc -O2 -Cr -vew -Futools/ArchiveTest -Futools/CryptoTest -Fuuserland/lib/archive \
		-Fuuserland/lib/compression -FU$(ARCHIVE_TEST_UNITS) -o$@ tools/ArchiveTest/ArchiveTest.pas

archive-test: $(ARCHIVE_TEST) $(ARCHIVE_FIXTURES)/manifest.txt
	@$(ARCHIVE_TEST) $(ARCHIVE_FIXTURES) $(ARCHIVE_SAMPLES) build/tools/archive-work > build/tools/archive-test.out || \
		{ grep FAIL build/tools/archive-test.out; echo "ARCHIVE TEST FAILED (build/tools/archive-test.out)"; exit 1; }
	@python3 -I tools/ArchiveTest/check-written.py $(ARCHIVE_SAMPLES) > build/tools/archive-written.out || \
		{ cat build/tools/archive-written.out; echo "ARCHIVE TEST FAILED (Python's zipfile disagrees with what was written)"; exit 1; }
	@echo "ARCHIVE TEST PASSED: $$(tail -n 1 build/tools/archive-test.out | cut -d ' ' -f 3-); $$(tail -n 1 build/tools/archive-written.out)"

# The whole-buffer decoders the kernel unpacks a compressed RAM disk
# with (xz/LZMA2 and gzip, userland/lib/compression), on the host, over
# fixtures Python's lzma and gzip make at build time.
DECOMPRESSION_TEST := build/tools/DecompressionTest
DECOMPRESSION_TEST_UNITS := build/tools/decompression-test-units
DECOMPRESSION_FIXTURES := build/tools/decompression-fixtures
DECOMPRESSION_TEST_SOURCES := tools/DecompressionTest/DecompressionTest.pas tools/CryptoTest/TestChecks.pas \
	$(filter-out %/Compression.Contents.pas,$(wildcard userland/lib/compression/*.pas))

$(DECOMPRESSION_FIXTURES)/manifest.txt: tools/DecompressionTest/make-fixtures.py
	python3 -I $< $(DECOMPRESSION_FIXTURES)

$(DECOMPRESSION_TEST): $(DECOMPRESSION_TEST_SOURCES)
	@mkdir -p $(DECOMPRESSION_TEST_UNITS)
	fpc -Mobjfpc -O2 -Cr -vew -Futools/DecompressionTest -Futools/CryptoTest -Fuuserland/lib/compression \
		-FU$(DECOMPRESSION_TEST_UNITS) -o$@ tools/DecompressionTest/DecompressionTest.pas

decompression-test: $(DECOMPRESSION_TEST) $(DECOMPRESSION_FIXTURES)/manifest.txt
	@$(DECOMPRESSION_TEST) $(DECOMPRESSION_FIXTURES) > build/tools/decompression-test.out || \
		{ grep FAIL build/tools/decompression-test.out; echo "DECOMPRESSION TEST FAILED (build/tools/decompression-test.out)"; exit 1; }
	@echo "DECOMPRESSION TEST PASSED: $$(tail -n 1 build/tools/decompression-test.out | cut -d ' ' -f 3-)"

# libtls but for its socket, file and clock units builds for the host too
# (with a Crypto.Random of the host's), and is checked there; then its
# client connects to OpenSSL's s_server (skipped without openssl).
TLS_TEST := build/tools/TlsTest
TLS_TEST_SOURCES := $(wildcard tools/TlsTest/*.pas) $(wildcard tools/TlsTest/*.inc) \
	tools/CryptoTest/TestChecks.pas $(filter-out %/Crypto.Random.pas,$(wildcard userland/lib/cryptography/*.pas)) \
	$(filter-out %/Tls.SocketTransport.pas %/Tls.SystemTrust.pas %/Tls.Sessions.pas %/Tls.Contents.pas, \
		$(wildcard userland/lib/tls/*.pas))

# Certificate chains, OCSP responses and PRF outputs made by Python's
# cryptography package each time the test runs (the OCSP responses are
# current only for days).
TLS_FIXTURES := build/tools/tls-fixtures

$(TLS_TEST): $(TLS_TEST_SOURCES)
	@mkdir -p build/tools/tls-test-units
	fpc -Mobjfpc -O2 -vew -Futools/TlsTest -Futools/CryptoTest -Fuuserland/lib/tls -Fuuserland/lib/cryptography \
		-Fushared -Fishared -FUbuild/tools/tls-test-units -o$@ tools/TlsTest/TlsTest.pas

tls-test: $(TLS_TEST)
	@python3 -I -c 'from cryptography import x509' 2>/dev/null || { echo "Python 3 with the cryptography package is needed for the TLS test's fixtures"; exit 1; }
	@python3 -I tools/TlsTest/make-fixtures.py tools/TlsTest/certificates $(TLS_FIXTURES)
	@$(TLS_TEST) tools/TlsTest/certificates userland/etc/ssl/certs/ca-certificates.crt $(TLS_FIXTURES) > build/tools/tls-test.out || \
		{ grep -A2 FAIL build/tools/tls-test.out; echo "TLS TEST FAILED (build/tools/tls-test.out)"; exit 1; }
	@echo "TLS TEST PASSED: $$(tail -n 1 build/tools/tls-test.out | cut -d ' ' -f 3-)"
	@tools/TlsTest/run-interop.sh $(TLS_TEST) $(TLS_FIXTURES) > build/tools/tls-interop.out 2>&1 || \
		{ grep FAIL build/tools/tls-interop.out; echo "TLS INTEROP TEST FAILED (build/tools/tls-interop.out)"; exit 1; }
	@tail -n 1 build/tools/tls-interop.out

# libssh builds for the host too (with TlsTest's Crypto.Random) and is
# checked there against known answers that Python and OpenSSL work out
# when the test is built, and against a small client in memory.
SSH_TEST := build/tools/SshTest
SSH_TEST_UNITS := build/tools/ssh-test-units
SSH_VECTORS := $(SSH_TEST_UNITS)/SshTest.Vectors.inc
SSH_CLIENT_VECTORS := $(SSH_TEST_UNITS)/SshTest.ClientVectors.inc
SSH_TEST_SOURCES := $(wildcard tools/SshTest/*.pas) tools/CryptoTest/TestChecks.pas tools/TlsTest/Crypto.Random.pas \
	$(filter-out %/Crypto.Random.pas %/Crypto.Contents.pas,$(wildcard userland/lib/cryptography/*.pas)) \
	$(filter-out %/Ssh.Contents.pas,$(wildcard userland/lib/ssh/*.pas)) userland/sshd/Sshd.Configuration.pas

$(SSH_VECTORS): tools/SshTest/make-vectors.py
	@mkdir -p $(SSH_TEST_UNITS)
	@python3 -c 'import cryptography' 2>/dev/null || { echo "Python 3 with the cryptography package is needed for the SSH test's vectors (python-cryptography)"; exit 1; }
	python3 tools/SshTest/make-vectors.py > $@.tmp
	@mv $@.tmp $@

# Certificates made with the host's ssh-keygen -s; the hybrid exchange
# with OpenSSL's ML-KEM.
$(SSH_CLIENT_VECTORS): tools/SshTest/make-client-vectors.py
	@mkdir -p $(SSH_TEST_UNITS)
	@command -v ssh-keygen >/dev/null || { echo "OpenSSH's ssh-keygen is needed for the SSH test's certificates"; exit 1; }
	python3 tools/SshTest/make-client-vectors.py $(SSH_TEST_UNITS)/keys > $@.tmp
	@mv $@.tmp $@

$(SSH_TEST): $(SSH_TEST_SOURCES) $(SSH_VECTORS) $(SSH_CLIENT_VECTORS)
	@mkdir -p $(SSH_TEST_UNITS)
	fpc -Mobjfpc -O2 -vew -Futools/SshTest -Futools/CryptoTest -Futools/TlsTest -Fuuserland/lib/ssh -Fuuserland/sshd \
		-Fuuserland/lib/cryptography -Fushared -Fishared -Fi$(SSH_TEST_UNITS) -FU$(SSH_TEST_UNITS) -o$@ tools/SshTest/SshTest.pas

ssh-test: $(SSH_TEST)
	@$(SSH_TEST) > build/tools/ssh-test.out || \
		{ grep -A2 FAIL build/tools/ssh-test.out; echo "SSH TEST FAILED (build/tools/ssh-test.out)"; exit 1; }
	@echo "SSH HOST TEST PASSED: $$(tail -n 1 build/tools/ssh-test.out | cut -d ' ' -f 3-)"

# libquic but for its socket and session units builds for the host too
# (with libtls and TlsTest's Crypto.Random) and is checked there: RFC
# 9001's packet protection vectors, frames, transport parameters, QPACK
# (RFC 9204 appendix B), HTTP/3 frames, and whole QUIC and HTTP/3
# connections over UDP on 127.0.0.1 and ::1 against a small server made
# for the test (threads: cthreads), and libhttp's client (built in, with
# libcompression and HttpTest's pipes) reaching it by Alt-Svc after an
# HTTP/1.1 response and falling back to TCP; then curl, when it has
# HTTP/3, fetches from that server. make-vectors.py works out the known answers
# with Python's cryptography and makes the server's certificate.
QUIC_TEST := build/tools/QuicTest
QUIC_TEST_UNITS := build/tools/quic-test-units
QUIC_VECTORS := $(QUIC_TEST_UNITS)/QuicTest.Generated.inc
QUIC_TEST_SOURCES := $(wildcard tools/QuicTest/*.pas) tools/CryptoTest/TestChecks.pas tools/TlsTest/Crypto.Random.pas \
	$(filter-out %/Crypto.Random.pas %/Crypto.Contents.pas,$(wildcard userland/lib/cryptography/*.pas)) \
	$(filter-out %/Tls.SocketTransport.pas %/Tls.SystemTrust.pas %/Tls.Sessions.pas %/Tls.Contents.pas, \
		$(wildcard userland/lib/tls/*.pas)) \
	$(filter-out %/Quic.UdpSockets.pas %/Quic.Sessions.pas %/Quic.Contents.pas %/Http3.SystemConnections.pas, \
		$(wildcard userland/lib/quic/*.pas)) \
	$(filter-out %/Http.SocketTransports.pas %/Http.SocketConnector.pas %/Http.Contents.pas, \
		$(wildcard userland/lib/http/*.pas)) \
	$(filter-out %/Compression.Contents.pas,$(wildcard userland/lib/compression/*.pas)) \
	tools/HttpTest/HttpTest.Pipes.pas

$(QUIC_VECTORS): tools/QuicTest/make-vectors.py
	@mkdir -p $(QUIC_TEST_UNITS)
	@python3 -I -c 'from cryptography import x509' 2>/dev/null || { echo "Python 3 with the cryptography package is needed for the QUIC test's vectors"; exit 1; }
	python3 -I tools/QuicTest/make-vectors.py $@.tmp
	@mv $@.tmp $@

$(QUIC_TEST): $(QUIC_TEST_SOURCES) $(QUIC_VECTORS)
	@mkdir -p $(QUIC_TEST_UNITS)
	fpc -Mobjfpc -O2 -vew -Futools/QuicTest -Futools/CryptoTest -Futools/TlsTest -Futools/HttpTest -Fuuserland/lib/quic \
		-Fuuserland/lib/http -Fuuserland/lib/compression -Fuuserland/lib/tls -Fuuserland/lib/cryptography -Fushared \
		-Fishared -Fi$(QUIC_TEST_UNITS) -FU$(QUIC_TEST_UNITS) -o$@ tools/QuicTest/QuicTest.pas

quic-test: $(QUIC_TEST)
	@$(QUIC_TEST) > build/tools/quic-test.out || \
		{ grep -A2 FAIL build/tools/quic-test.out; echo "QUIC TEST FAILED (build/tools/quic-test.out)"; exit 1; }
	@echo "QUIC TEST PASSED: $$(tail -n 1 build/tools/quic-test.out | cut -d ' ' -f 3-)"
	@tools/QuicTest/run-curl-interop.sh $(QUIC_TEST) build/tools/quic-interop > build/tools/quic-interop.out 2>&1 || \
		{ grep FAIL build/tools/quic-interop.out; echo "QUIC CURL INTEROP FAILED (build/tools/quic-interop.out)"; exit 1; }
	@tail -n 1 build/tools/quic-interop.out

# libweb on the host: the HTML parser against tree construction cases in
# the html5lib format (tools/WebTest/tree-construction/*.dat, written from
# the standard's algorithm), each also fed one byte at a time; encodings;
# DOM mutations, collections and lifetime; event dispatch; serialization
# round trips; and the parser's speed and bytes per node.
WEB_TEST := build/tools/WebTest
WEB_TEST_UNITS := build/tools/web-test-units
WEB_TEST_SOURCES := $(wildcard tools/WebTest/*.pas) tools/CryptoTest/TestChecks.pas \
	$(filter-out %/Web.Contents.pas,$(wildcard userland/lib/web/*.pas)) $(wildcard userland/lib/web/*.inc)

$(WEB_TEST_UNITS)/.generated: userland/lib/web/make-tables.py $(wildcard userland/lib/web/data/*.txt)
	@mkdir -p $(WEB_TEST_UNITS)
	python3 -B userland/lib/web/make-tables.py $(WEB_TEST_UNITS)
	@touch $@

$(WEB_TEST): $(WEB_TEST_SOURCES) $(WEB_TEST_UNITS)/.generated
	@mkdir -p $(WEB_TEST_UNITS)
	fpc -Mobjfpc -O2 -Cr -vew -Futools/WebTest -Futools/CryptoTest -Fuuserland/lib/web -Fi$(WEB_TEST_UNITS) \
		-FU$(WEB_TEST_UNITS) -o$@ tools/WebTest/WebTest.pas

web-test: $(WEB_TEST)
	@$(WEB_TEST) tools/WebTest/tree-construction > build/tools/web-test.out || \
		{ grep -A14 FAIL build/tools/web-test.out | head -150; echo "WEB TEST FAILED (build/tools/web-test.out)"; exit 1; }
	@grep '^perf' build/tools/web-test.out || true
	@echo "WEB TEST PASSED: $$(tail -n 1 build/tools/web-test.out | cut -d ' ' -f 3-)"

# libwebipc, the browser's protocol between its processes: plain logic
# (the wire format, pieces, payloads), on the host.
WEB_IPC_TEST := build/tools/WebIpcTest
WEB_IPC_TEST_UNITS := build/tools/web-ipc-test-units
WEB_IPC_TEST_SOURCES := $(wildcard tools/WebIpcTest/*.pas) tools/CryptoTest/TestChecks.pas \
	userland/lib/webipc/WebIpc.Wire.pas userland/lib/webipc/WebIpc.Messages.pas userland/lib/webipc/WebIpc.Fragments.pas \
	userland/lib/webipc/WebIpc.ViewMessages.pas userland/lib/webipc/WebIpc.NetworkMessages.pas \
	userland/lib/webview/WebView.RemoteFrames.pas $(wildcard userland/lib/drawing/*.pas)

$(WEB_IPC_TEST): $(WEB_IPC_TEST_SOURCES)
	@mkdir -p $(WEB_IPC_TEST_UNITS)
	fpc -Mobjfpc -O2 -Cr -vew -Futools/WebIpcTest -Futools/CryptoTest -Fuuserland/lib/webipc \
		-Fuuserland/lib/drawing -Fuuserland/lib/webview -FU$(WEB_IPC_TEST_UNITS) -o$@ tools/WebIpcTest/WebIpcTest.pas

web-ipc-test: $(WEB_IPC_TEST)
	@$(WEB_IPC_TEST) > build/tools/web-ipc-test.out || \
		{ grep FAIL build/tools/web-ipc-test.out; echo "WEB IPC TEST FAILED (build/tools/web-ipc-test.out)"; exit 1; }
	@echo "WEB IPC TEST PASSED: $$(tail -n 1 build/tools/web-ipc-test.out | cut -d ' ' -f 4-)"

# libweb's script bindings on the host, with libjavascript, libcss and
# libhttp's URL units: tools/WebScriptTest/scripts/*.js run in windows
# over their .html pages, then wrapper lifetime and bytes per wrapper.
WEB_SCRIPT_TEST := build/tools/WebScriptTest
WEB_SCRIPT_TEST_UNITS := build/tools/web-script-test-units
WEB_BINDING_SOURCES := userland/lib/web/make-bindings.py $(wildcard userland/lib/web/bindings/*.webidl) \
	$(wildcard userland/lib/web/platform/*.js)
WEB_SCRIPT_TEST_SOURCES := $(wildcard tools/WebScriptTest/*.pas) tools/CryptoTest/TestChecks.pas \
	$(filter-out %/Web.Contents.pas,$(wildcard userland/lib/web/*.pas)) $(wildcard userland/lib/web/*.inc) \
	$(filter-out %/Js.Contents.pas %/Js.SystemClock.pas,$(wildcard userland/lib/javascript/*.pas)) \
	$(filter-out %/Css.Contents.pas,$(wildcard userland/lib/css/*.pas)) $(wildcard userland/lib/http/Url.*.pas) \
	tools/TlsTest/Crypto.Random.pas userland/lib/cryptography/Crypto.Digests.pas

$(WEB_SCRIPT_TEST_UNITS)/.generated: userland/lib/web/make-tables.py $(wildcard userland/lib/web/data/*.txt) \
		$(WEB_BINDING_SOURCES)
	@mkdir -p $(WEB_SCRIPT_TEST_UNITS)
	python3 -B userland/lib/web/make-tables.py $(WEB_SCRIPT_TEST_UNITS)
	python3 -B userland/lib/web/make-bindings.py $(WEB_SCRIPT_TEST_UNITS)
	@touch $@

$(WEB_SCRIPT_TEST): $(WEB_SCRIPT_TEST_SOURCES) $(WEB_SCRIPT_TEST_UNITS)/.generated
	@mkdir -p $(WEB_SCRIPT_TEST_UNITS)
	fpc -Mobjfpc -O2 -vew -Futools/WebScriptTest -Futools/CryptoTest -Futools/TlsTest -Fuuserland/lib/cryptography -Fushared -Fishared \
		-Fuuserland/lib/web -Fuuserland/lib/javascript \
		-Fuuserland/lib/css -Fuuserland/lib/http -Fi$(WEB_SCRIPT_TEST_UNITS) -FU$(WEB_SCRIPT_TEST_UNITS) -o$@ \
		tools/WebScriptTest/WebScriptTest.pas

web-script-test: $(WEB_SCRIPT_TEST)
	@$(WEB_SCRIPT_TEST) tools/WebScriptTest/scripts > build/tools/web-script-test.out || \
		{ grep -A3 FAIL build/tools/web-script-test.out | head -150; echo "WEB SCRIPT TEST FAILED (build/tools/web-script-test.out)"; exit 1; }
	@grep '^perf' build/tools/web-script-test.out || true
	@echo "WEB SCRIPT TEST PASSED: $$(tail -n 1 build/tools/web-script-test.out | cut -d ' ' -f 4-)"

# libjavascript builds for the host too (but for its FreePascalOS clock)
# and runs every tools/JavaScriptTest/scripts/*.js against the output
# written at its end, checks the embedding API, then times the
# benchmarks and reports their peak bytes. JS_GC_STRESS=1 collects every
# 16 KiB.
JAVASCRIPT_TEST := build/tools/JavaScriptTest
JAVASCRIPT_TEST_UNITS := build/tools/javascript-test-units
JAVASCRIPT_TEST_SOURCES := tools/JavaScriptTest/JavaScriptTest.pas \
	$(filter-out %/Js.Contents.pas %/Js.SystemClock.pas,$(wildcard userland/lib/javascript/*.pas))

$(JAVASCRIPT_TEST): $(JAVASCRIPT_TEST_SOURCES)
	@mkdir -p $(JAVASCRIPT_TEST_UNITS)
	fpc -Mobjfpc -O2 -vew -Futools/JavaScriptTest -Fuuserland/lib/javascript \
		-FU$(JAVASCRIPT_TEST_UNITS) -o$@ tools/JavaScriptTest/JavaScriptTest.pas

javascript-test: $(JAVASCRIPT_TEST)
	@$(JAVASCRIPT_TEST) tools/JavaScriptTest/scripts tools/JavaScriptTest/benchmarks > build/tools/javascript-test.out || \
		{ grep -A3 FAIL build/tools/javascript-test.out; echo "JAVASCRIPT TEST FAILED (build/tools/javascript-test.out)"; exit 1; }
	@grep BENCH build/tools/javascript-test.out
	@echo "JAVASCRIPT TEST PASSED: $$(tail -n 1 build/tools/javascript-test.out | cut -d ' ' -f 2-)"

# libweb's style, layout and painting on the host (with libcss, libfont,
# libdrawing and libimage): the reference pages of tools/WebTest/render
# laid out and their layout tree dumps compared with the .txt files
# beside them (with DejaVu Sans and Sans Mono, the base set of
# userland/fonts, in build/tools/base-fonts; the system font matching
# with all of userland/fonts and userland/etc/fonts.conf), incremental
# relayout after DOM changes against fresh layouts, hit testing,
# painting (known pixels, damaged rectangles), and the speed and memory
# of a large page ("perf" lines). make web-layout-update rewrites the
# expected dumps (look at what changed before committing them).
WEB_LAYOUT_TEST := build/tools/WebLayoutTest
WEB_LAYOUT_TEST_UNITS := build/tools/web-layout-test-units
WEB_RENDER_LIBRARY_SOURCES := $(wildcard userland/lib/web/*.pas) $(wildcard userland/lib/web/*.inc) \
	$(wildcard userland/lib/css/*.pas) $(wildcard userland/lib/font/*.pas) $(wildcard userland/lib/drawing/*.pas) \
	$(wildcard userland/lib/image/*.pas) $(wildcard userland/lib/compression/*.pas) $(wildcard userland/lib/svg/*.pas)
WEB_RENDER_UNIT_PATHS := -Fuuserland/lib/web -Fuuserland/lib/css -Fuuserland/lib/font -Fuuserland/lib/drawing \
	-Fuuserland/lib/image -Fuuserland/lib/compression -Fuuserland/lib/svg
WEB_LAYOUT_TEST_SOURCES := $(wildcard tools/WebLayoutTest/*.pas) tools/CryptoTest/TestChecks.pas \
	$(WEB_RENDER_LIBRARY_SOURCES)

$(WEB_LAYOUT_TEST_UNITS)/.generated: userland/lib/web/make-tables.py $(wildcard userland/lib/web/data/*.txt)
	@mkdir -p $(WEB_LAYOUT_TEST_UNITS)
	python3 -B userland/lib/web/make-tables.py $(WEB_LAYOUT_TEST_UNITS)
	@touch $@

$(WEB_LAYOUT_TEST): $(WEB_LAYOUT_TEST_SOURCES) $(WEB_LAYOUT_TEST_UNITS)/.generated
	@mkdir -p $(WEB_LAYOUT_TEST_UNITS)
	fpc -Mobjfpc -O2 -Cr -vew -Futools/WebLayoutTest -Futools/CryptoTest $(WEB_RENDER_UNIT_PATHS) \
		-Fi$(WEB_LAYOUT_TEST_UNITS) -FU$(WEB_LAYOUT_TEST_UNITS) -o$@ tools/WebLayoutTest/WebLayoutTest.pas

web-layout-test: $(WEB_LAYOUT_TEST) $(BASE_FONTS_STAMP)
	@WEB_HOST_FONTS=userland/fonts $(WEB_LAYOUT_TEST) tools/WebTest/render $(BASE_FONTS_DIRECTORY) \
		> build/tools/web-layout-test.out || \
		{ grep -B3 -A3 FAIL build/tools/web-layout-test.out | head -80; echo "WEB LAYOUT TEST FAILED (build/tools/web-layout-test.out)"; exit 1; }
	@grep '^perf' build/tools/web-layout-test.out || true
	@echo "WEB LAYOUT TEST PASSED: $$(tail -n 1 build/tools/web-layout-test.out | cut -d ' ' -f 4-)"

web-layout-update: $(WEB_LAYOUT_TEST) $(BASE_FONTS_STAMP)
	$(WEB_LAYOUT_TEST) tools/WebTest/render $(BASE_FONTS_DIRECTORY) --update | tail -n 1

# webrender on the host: renders an HTML file to a PNG or prints its
# layout tree (build/tools/webrender -f userland/fonts [-l] PAGE.html [OUT.png]).
WEB_RENDER := build/tools/webrender
WEB_RENDER_UNITS := build/tools/webrender-units

$(WEB_RENDER): userland/bin/webrender.pas $(wildcard userland/webrender/*.pas) $(WEB_RENDER_LIBRARY_SOURCES) \
		$(WEB_LAYOUT_TEST_UNITS)/.generated
	@mkdir -p $(WEB_RENDER_UNITS)
	fpc -Mobjfpc -O2 -vew -Fuuserland/webrender $(WEB_RENDER_UNIT_PATHS) -Fi$(WEB_LAYOUT_TEST_UNITS) \
		-FU$(WEB_RENDER_UNITS) -o$@ userland/bin/webrender.pas

webrender: $(WEB_RENDER)

# The IPv6 stack's pure parts on the host: SHA-256, RFC 7217 identifiers,
# RFC 6724 address selection, the destination cache, fragments; martian
# addresses on crafted headers and reassembly's overlap checks.
IPV6_TEST := build/tools/Ipv6Test
IPV6_TEST_SOURCES := tools/Ipv6Test/Ipv6Test.pas tools/CryptoTest/TestChecks.pas shared/AddressSelection.pas \
	kernel/network/Network.Sha256.pas kernel/network/Network.InterfaceIdentifiers.pas \
	kernel/network/Network.DestinationTable.pas kernel/network/Network.FragmentBuilder.pas \
	kernel/network/Network.InputFilter.pas kernel/network/Network.ReassemblyBlocks.pas \
	kernel/network/Network.Ipv6Headers.pas

$(IPV6_TEST): $(IPV6_TEST_SOURCES)
	@mkdir -p build/tools/ipv6-test-units
	fpc -Mobjfpc -O2 -Cr -vew -Futools/Ipv6Test -Futools/CryptoTest -Fukernel/network -Fushared \
		-FUbuild/tools/ipv6-test-units -o$@ tools/Ipv6Test/Ipv6Test.pas

ipv6-test: $(IPV6_TEST)
	@$(IPV6_TEST) > build/tools/ipv6-test.out || \
		{ grep FAIL build/tools/ipv6-test.out; echo "IPV6 TEST FAILED (build/tools/ipv6-test.out)"; exit 1; }
	@echo "IPV6 TEST PASSED: $$(tail -n 1 build/tools/ipv6-test.out | cut -d ' ' -f 3-)"

# wget's URLs, response heads, chunked decoding, cookies, authentication
# and recursion's pieces build for the host too (the HTTP ones from
# libhttp).
WGET_TEST := build/tools/WgetTest
WGET_TEST_SOURCES := $(wildcard tools/WgetTest/*.pas) tools/CryptoTest/TestChecks.pas $(wildcard userland/wget/*.pas) \
	$(filter-out %/Crypto.Random.pas %/Crypto.Contents.pas,$(wildcard userland/lib/cryptography/*.pas)) \
	$(wildcard userland/lib/http/*.pas)

$(WGET_TEST): $(WGET_TEST_SOURCES)
	@mkdir -p build/tools/wget-test-units
	fpc -Mobjfpc -O2 -vew -Futools/WgetTest -Futools/CryptoTest -Fuuserland/wget -Fuuserland/lib/http \
		-Fuuserland/lib/cryptography -Fushared -Fishared -FUbuild/tools/wget-test-units -o$@ tools/WgetTest/WgetTest.pas

wget-test: $(WGET_TEST)
	@$(WGET_TEST) > build/tools/wget-test.out || \
		{ grep FAIL build/tools/wget-test.out; echo "WGET TEST FAILED (build/tools/wget-test.out)"; exit 1; }
	@echo "WGET TEST PASSED: $$(tail -n 1 build/tools/wget-test.out | cut -d ' ' -f 3-)"

# libhttp but for its socket units builds for the host too (with
# TlsTest's Crypto.Random): the URL Standard, HPACK against RFC 7541's
# appendix C, HTTP/2 frames, HTTP/1.1 and HTTP/2 exchanges and the
# client against small servers over in-memory pipes; then HPACK and
# Huffman coding against libnghttp2 and an HTTPS + HTTP/2 exchange with
# scripts/test-web-server.py (each skipped when the host lacks it).
HTTP_TEST := build/tools/HttpTest
HTTP_TEST_UNITS := build/tools/http-test-units
HTTP_TEST_SOURCES := $(wildcard tools/HttpTest/*.pas) tools/CryptoTest/TestChecks.pas tools/TlsTest/Crypto.Random.pas \
	$(filter-out %/Http.SocketTransports.pas %/Http.SocketConnector.pas %/Http.Contents.pas, \
		$(wildcard userland/lib/http/*.pas)) \
	$(filter-out %/Compression.Contents.pas,$(wildcard userland/lib/compression/*.pas)) \
	$(filter-out %/Crypto.Random.pas %/Crypto.Contents.pas,$(wildcard userland/lib/cryptography/*.pas)) \
	$(filter-out %/Tls.SocketTransport.pas %/Tls.SystemTrust.pas %/Tls.Sessions.pas %/Tls.Contents.pas, \
		$(wildcard userland/lib/tls/*.pas))

$(HTTP_TEST): $(HTTP_TEST_SOURCES)
	@mkdir -p $(HTTP_TEST_UNITS)
	fpc -Mobjfpc -O2 -vew -Futools/HttpTest -Futools/CryptoTest -Futools/TlsTest -Fuuserland/lib/http \
		-Fuuserland/lib/compression -Fuuserland/lib/cryptography -Fuuserland/lib/tls -Fushared -Fishared \
		-FU$(HTTP_TEST_UNITS) -o$@ tools/HttpTest/HttpTest.pas

http-test: $(HTTP_TEST)
	@$(HTTP_TEST) > build/tools/http-test.out || \
		{ grep -A2 FAIL build/tools/http-test.out; echo "HTTP TEST FAILED (build/tools/http-test.out)"; exit 1; }
	@echo "HTTP TEST PASSED: $$(tail -n 1 build/tools/http-test.out | cut -d ' ' -f 3-)"
	@tools/HttpTest/run-interop.sh $(HTTP_TEST) build/tools/http-interop > build/tools/http-interop.out 2>&1 || \
		{ grep -B2 -A6 "FAIL\|exception" build/tools/http-interop.out; echo "HTTP INTEROP TEST FAILED (build/tools/http-interop.out)"; exit 1; }
	@tail -n 1 build/tools/http-interop.out

# libweb's loading side on the host (with libhttp, libcss, libimage and
# what they need): the event loop and timers, the fetch layer's rules
# (MIME types, data: URLs, sniffing, referrer policy, HSTS, CSP, mixed
# content, CORS), the fetcher, document loading, subresources and
# navigation against an in-process HTTP server over in-memory pipes.
WEB_LOAD_TEST := build/tools/WebLoadTest
WEB_LOAD_TEST_UNITS := build/tools/web-load-test-units
WEB_LOAD_TEST_SOURCES := $(wildcard tools/WebLoadTest/*.pas) tools/CryptoTest/TestChecks.pas tools/TlsTest/Crypto.Random.pas \
	tools/HttpTest/HttpTest.Pipes.pas $(wildcard userland/lib/web/*.pas) $(wildcard userland/lib/web/*.inc) \
	$(wildcard userland/lib/http/*.pas) $(wildcard userland/lib/css/*.pas) $(wildcard userland/lib/image/*.pas) \
	$(wildcard userland/lib/drawing/*.pas) $(wildcard userland/lib/compression/*.pas) $(wildcard userland/lib/svg/*.pas) \
	$(wildcard userland/lib/cryptography/*.pas) $(wildcard userland/lib/tls/*.pas) $(wildcard userland/lib/font/*.pas) \
	$(filter-out %/Js.Contents.pas %/Js.SystemClock.pas,$(wildcard userland/lib/javascript/*.pas)) \
	tools/WebLoadTest/editing-fuzz.html tools/WebLoadTest/pointer-fuzz.html tools/WebBrowse/WebBrowse.Input.pas tools/WebBrowse/WebBrowse.Pointer.pas $(wildcard userland/lib/webview/WebView.*.pas)

$(WEB_LOAD_TEST_UNITS)/.generated: userland/lib/web/make-tables.py $(wildcard userland/lib/web/data/*.txt) \
		$(WEB_BINDING_SOURCES)
	@mkdir -p $(WEB_LOAD_TEST_UNITS)
	python3 -B userland/lib/web/make-tables.py $(WEB_LOAD_TEST_UNITS)
	python3 -B userland/lib/web/make-bindings.py $(WEB_LOAD_TEST_UNITS)
	@touch $@

$(WEB_LOAD_TEST): $(WEB_LOAD_TEST_SOURCES) $(WEB_LOAD_TEST_UNITS)/.generated
	fpc -Mobjfpc -O2 -Cr -gl -vew -Futools/WebLoadTest -Futools/CryptoTest -Futools/TlsTest -Futools/HttpTest \
		-Futools/WebBrowse -Fuuserland/lib/webview -Fuuserland/lib/windowing \
		-Fuuserland/lib/web -Fuuserland/lib/http -Fuuserland/lib/css -Fuuserland/lib/image -Fuuserland/lib/drawing \
		-Fuuserland/lib/compression -Fuuserland/lib/cryptography -Fuuserland/lib/tls -Fuuserland/lib/font \
		-Fuuserland/lib/javascript -Fuuserland/lib/svg -Fushared -Fishared \
		-Fi$(WEB_LOAD_TEST_UNITS) -FU$(WEB_LOAD_TEST_UNITS) -o$@ tools/WebLoadTest/WebLoadTest.pas

web-load-test: $(WEB_LOAD_TEST) $(BASE_FONTS_STAMP)
	@$(WEB_LOAD_TEST) > build/tools/web-load-test.out || \
		{ grep -A2 FAIL build/tools/web-load-test.out | head -100; echo "WEB LOAD TEST FAILED (build/tools/web-load-test.out)"; exit 1; }
	@echo "WEB LOAD TEST PASSED: $$(tail -n 1 build/tools/web-load-test.out | cut -d ' ' -f 4-)"

# webbrowse on the host (not part of make test): the real pipeline -
# TWebPage over libhttp and libtls on host sockets with the host's roots,
# the layout sink, page scripting, the event loop driven like the web
# view - loads a URL and writes a PNG, the layout tree, the DOM, console
# messages, the network log, phase times and peak memory, with a
# watchdog that says where a hung page thread is
# (build/tools/webbrowse -o page.png -n -p https://example.com/).
WEB_BROWSE := build/tools/webbrowse
WEB_BROWSE_UNITS := build/tools/webbrowse-units
WEB_BROWSE_SOURCES := $(wildcard tools/WebBrowse/*.pas) tools/TlsTest/Crypto.Random.pas $(WEB_LOAD_TEST_SOURCES) \
	$(wildcard userland/lib/webview/WebView.*.pas)

$(WEB_BROWSE_UNITS)/.generated: userland/lib/web/make-tables.py $(wildcard userland/lib/web/data/*.txt) \
		$(WEB_BINDING_SOURCES)
	@mkdir -p $(WEB_BROWSE_UNITS)
	python3 -B userland/lib/web/make-tables.py $(WEB_BROWSE_UNITS)
	python3 -B userland/lib/web/make-bindings.py $(WEB_BROWSE_UNITS)
	@touch $@

$(WEB_BROWSE): $(WEB_BROWSE_SOURCES) $(WEB_BROWSE_UNITS)/.generated
	fpc -Mobjfpc -O2 -OoNOSTACKFRAME -gl $(WEB_BROWSE_FLAGS) -vew -Futools/WebBrowse -Futools/TlsTest \
		-Fuuserland/lib/web -Fuuserland/lib/http -Fuuserland/lib/css -Fuuserland/lib/image -Fuuserland/lib/drawing \
		-Fuuserland/lib/compression -Fuuserland/lib/cryptography -Fuuserland/lib/tls -Fuuserland/lib/font \
		-Fuuserland/lib/javascript -Fuuserland/lib/svg -Fuuserland/lib/webview -Fuuserland/lib/windowing -Fushared -Fishared \
		-Fi$(WEB_BROWSE_UNITS) -FU$(WEB_BROWSE_UNITS) -o$@ tools/WebBrowse/WebBrowse.pas

webbrowse: $(WEB_BROWSE)

# The resolver's EDNS(0) and cache of answers (libsystem) and the network
# service's DHCP and DHCPv6 messages build for the host too, with range
# checks, and are checked there (RFC examples among the fixtures).
NETWORK_PROTOCOL_TEST := build/tools/NetworkProtocolTest
NETWORK_PROTOCOL_TEST_SOURCES := $(wildcard tools/NetworkProtocolTest/*.pas) tools/CryptoTest/TestChecks.pas \
	userland/lib/system/Sys.DnsMessages.pas userland/lib/system/Sys.DnsNames.pas \
	userland/lib/system/Sys.DnsCache.pas userland/lib/system/Sys.InternetAddresses.pas \
	$(wildcard userland/network/NetworkService.Dhcp*Messages.pas) userland/network/NetworkService.DhcpOffers.pas

$(NETWORK_PROTOCOL_TEST): $(NETWORK_PROTOCOL_TEST_SOURCES)
	@mkdir -p build/tools/network-protocol-test-units
	fpc -Mobjfpc -O2 -Cr -vew -Futools/NetworkProtocolTest -Futools/CryptoTest -Fuuserland/lib/system \
		-Fuuserland/network -Fushared -Fishared -FUbuild/tools/network-protocol-test-units -o$@ \
		tools/NetworkProtocolTest/NetworkProtocolTest.pas

network-protocol-test: $(NETWORK_PROTOCOL_TEST)
	@$(NETWORK_PROTOCOL_TEST) > build/tools/network-protocol-test.out || \
		{ grep -A2 FAIL build/tools/network-protocol-test.out; echo "NETWORK PROTOCOL TEST FAILED (build/tools/network-protocol-test.out)"; exit 1; }
	@echo "NETWORK PROTOCOL TEST PASSED: $$(tail -n 1 build/tools/network-protocol-test.out | cut -d ' ' -f 4-)"
# netstat's ports list and ss's filters build for the host too.
NETSTAT_TEST := build/tools/NetstatTest
NETSTAT_TEST_SOURCES := tools/NetstatTest/NetstatTest.pas tools/CryptoTest/TestChecks.pas \
	userland/netstat/Netstat.Services.pas userland/ss/Ss.Filters.pas userland/lib/system/Sys.InternetAddresses.pas

$(NETSTAT_TEST): $(NETSTAT_TEST_SOURCES)
	@mkdir -p build/tools/netstat-test-units
	fpc -Mobjfpc -O2 -Cr -vew -Futools/NetstatTest -Futools/CryptoTest -Fuuserland/netstat -Fuuserland/ss \
		-Fuuserland/lib/system -Fushared -Fishared -FUbuild/tools/netstat-test-units -o$@ tools/NetstatTest/NetstatTest.pas

netstat-test: $(NETSTAT_TEST)
	@$(NETSTAT_TEST) userland/etc/ports > build/tools/netstat-test.out || \
		{ grep FAIL build/tools/netstat-test.out; echo "NETSTAT TEST FAILED (build/tools/netstat-test.out)"; exit 1; }
	@echo "NETSTAT TEST PASSED: $$(tail -n 1 build/tools/netstat-test.out | cut -d ' ' -f 2-)"

# libimage builds for the host too (with libdrawing), with range checks,
# and is checked there against fixtures made at build time with Pillow:
# files put together byte by byte for every BMP, ICO and GIF variant,
# JPEGs, PNGs and TIFFs of every kind, with Pillow's decoding as the
# reference. What the test writes (PNG, TIFF) is then read by Pillow
# (check-with-pillow.py) and must give the pixels it was written from.
IMAGE_TEST := build/tools/ImageTest
IMAGE_FIXTURES := build/tools/image-fixtures
IMAGE_FIXTURES_STAMP := $(IMAGE_FIXTURES)/.made
IMAGE_WRITTEN := build/tools/image-written
IMAGE_FIXTURE_SCRIPTS := tools/ImageTest/make-fixtures.py tools/ImageTest/make-jpeg-fixtures.py \
	tools/ImageTest/make-png-fixtures.py tools/ImageTest/make-tiff-fixtures.py tools/ImageTest/fixturecommon.py \
	tools/ImageTest/make-color-fixtures.py tools/ImageTest/make-webp-fixtures.py \
	tools/ImageTest/make-jxl-fixtures.py
IMAGE_TEST_SOURCES := $(wildcard tools/ImageTest/*.pas) $(filter-out %/Image.Contents.pas,$(wildcard userland/lib/image/*.pas)) \
	$(wildcard userland/lib/drawing/*.pas) $(filter-out %/Compression.Contents.pas,$(wildcard userland/lib/compression/*.pas))

$(IMAGE_TEST): $(IMAGE_TEST_SOURCES)
	@mkdir -p build/tools/image-test-units
	fpc -Mobjfpc -O2 -Cr -vew -Futools/ImageTest -Fuuserland/lib/image -Fuuserland/lib/drawing \
		-Fuuserland/lib/compression -FUbuild/tools/image-test-units -o$@ tools/ImageTest/ImageTest.pas

$(IMAGE_FIXTURES_STAMP): $(IMAGE_FIXTURE_SCRIPTS)
	@python3 -c 'import PIL' 2>/dev/null || { echo "Python 3 with Pillow (PIL) is needed for the image test's fixtures (python-pillow)"; exit 1; }
	@rm -rf $(IMAGE_FIXTURES)
	python3 -B tools/ImageTest/make-fixtures.py $(IMAGE_FIXTURES)
	python3 -B tools/ImageTest/make-jpeg-fixtures.py $(IMAGE_FIXTURES)
	python3 -B tools/ImageTest/make-png-fixtures.py $(IMAGE_FIXTURES)
	python3 -B tools/ImageTest/make-tiff-fixtures.py $(IMAGE_FIXTURES)
	python3 -B tools/ImageTest/make-color-fixtures.py $(IMAGE_FIXTURES)
	python3 -B tools/ImageTest/make-webp-fixtures.py $(IMAGE_FIXTURES)
	python3 -B tools/ImageTest/make-jxl-fixtures.py $(IMAGE_FIXTURES)
	@touch $@

image-test: $(IMAGE_TEST) $(IMAGE_FIXTURES_STAMP)
	@rm -rf $(IMAGE_WRITTEN)
	@mkdir -p $(IMAGE_WRITTEN)
	@$(IMAGE_TEST) $(IMAGE_FIXTURES) $(IMAGE_WRITTEN) > build/tools/image-test.out || \
		{ grep -A2 FAIL build/tools/image-test.out; echo "IMAGE TEST FAILED (build/tools/image-test.out)"; exit 1; }
	@python3 -B tools/ImageTest/check-with-pillow.py $(IMAGE_WRITTEN) > build/tools/image-pillow.out || \
		{ cat build/tools/image-pillow.out; echo "IMAGE TEST FAILED (Pillow reads what was written differently)"; exit 1; }
	@echo "IMAGE TEST PASSED: $$(tail -n 1 build/tools/image-test.out | cut -d ' ' -f 2-)"

# libcontrols' picture and timing logic builds for the host too (with
# libdrawing and libimage): an image list's choice of pixel size, a
# picture box's placement, the disabled and selected looks, the
# tooltips' timing against a clock of the test's own, the timers' queue.
IMAGING_CONTROLS_TEST := build/tools/ImagingControlsTest
IMAGING_CONTROLS_TEST_SOURCES := $(wildcard tools/ImagingControlsTest/*.pas) \
	userland/lib/controls/Controls.ImageSizes.pas userland/lib/controls/Controls.PictureGeometry.pas \
	userland/lib/controls/Controls.ImageEffects.pas userland/lib/controls/Controls.HintTiming.pas \
	userland/lib/controls/Controls.TimerQueue.pas $(wildcard userland/lib/drawing/*.pas) \
	$(filter-out %/Image.Contents.pas,$(wildcard userland/lib/image/*.pas))

$(IMAGING_CONTROLS_TEST): $(IMAGING_CONTROLS_TEST_SOURCES)
	@mkdir -p build/tools/imaging-controls-test-units
	fpc -Mobjfpc -O2 -Cr -vew -Futools/ImagingControlsTest -Fuuserland/lib/controls -Fuuserland/lib/image \
		-Fuuserland/lib/drawing -Fuuserland/lib/compression -FUbuild/tools/imaging-controls-test-units -o$@ \
		tools/ImagingControlsTest/ImagingControlsTest.pas

imaging-controls-test: $(IMAGING_CONTROLS_TEST)
	@$(IMAGING_CONTROLS_TEST) > build/tools/imaging-controls-test.out || \
		{ grep -A1 FAIL build/tools/imaging-controls-test.out; echo "IMAGING CONTROLS TEST FAILED (build/tools/imaging-controls-test.out)"; exit 1; }
	@tail -n 1 build/tools/imaging-controls-test.out

# The icon theme and the pointer's pictures as the build draws them
# (userland/icons): every file at every size, decoding with alpha, and
# libcontrols' lookup of the size for a logical size and scale
# (Controls.IconFiles), on the host with libimage.
ICON_TEST := build/tools/IconTest
ICON_TEST_SOURCES := $(wildcard tools/IconTest/*.pas) userland/lib/controls/Controls.IconFiles.pas \
	$(wildcard userland/lib/drawing/*.pas) $(filter-out %/Image.Contents.pas,$(wildcard userland/lib/image/*.pas))

$(ICON_TEST): $(ICON_TEST_SOURCES)
	@mkdir -p build/tools/icon-test-units
	fpc -Mobjfpc -O2 -Cr -vew -Futools/IconTest -Fuuserland/lib/controls -Fuuserland/lib/image \
		-Fuuserland/lib/drawing -Fuuserland/lib/compression -FUbuild/tools/icon-test-units -o$@ \
		tools/IconTest/IconTest.pas

icon-test: $(ICON_TEST) $(ICONS_STAMP)
	@$(ICON_TEST) $(ICON_OUTPUT) $(POINTER_PICTURE_OUTPUT) > build/tools/icon-test.out || \
		{ grep -A3 FAIL build/tools/icon-test.out; echo "ICON TEST FAILED (build/tools/icon-test.out)"; exit 1; }
	@tail -n 1 build/tools/icon-test.out

clean:
	rm -rf build

FORCE:
