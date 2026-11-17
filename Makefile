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
#   make settings-test  Check the settings library on the host (files, escaping,
#                   layering, two writers, damaged files, the network's
#                   settings and state files)
#   make crypto-test  Check libcryptography's TLS algorithms on the host against
#                   published known answers
#   make compression-test  Check libcompression on the host against zlib's
#                   output (made by Python), and have Python's zlib
#                   decompress what it compresses
#   make tls-test   Check libtls on the host: certificates, chains, the RFC 8448
#                   handshake, and whole connections to OpenSSL's s_server
#   make wget-test  Check wget's URL, header and chunked decoding logic on the host
#   make image-test  Check libimage on the host against Pillow's decoding of fixtures
#                   made at build time (BMP, DIB, ICO, CUR, GIF, JPEG)
#   make userland   Build the user mode libraries and programs
#   make system-disk  Build the ext4 system volume with /bin and /lib
#   make image      Build a GPT disk image that can be written to a USB stick
#   make font       Regenerate the console font include from a PSF font
#   make clean      Remove all build output
#
#   make toolchain ARCH=arm64  Build the AArch64 cross compiler from the Free
#                   Pascal sources (build/toolchain/ppcrossa64)
#   make ARCH=arm64 Build the AArch64 loader and kernel (build/arm64/esp)
#   make run ARCH=arm64  Boot it in QEMU's virt machine (GICv2, Cortex-A72)
#   make arm64-test Boot smoke test of the AArch64 build (not in make test)

ARCH ?= amd64

FPC ?= fpc
LD ?= ld
OBJCOPY ?= objcopy
OBJDUMP ?= objdump

BUILD_DIRECTORY := build/$(ARCH)
ESP_DIRECTORY := $(BUILD_DIRECTORY)/esp

ifeq ($(ARCH),amd64)
  TARGET_FPC := $(FPC)
  TARGET_AS := $(AS) --64
  LOADER_TARGET := -Twin64
  KERNEL_TARGET := -Tlinux
  EFI_BOOT_FILE := BOOTX64.EFI
else ifeq ($(ARCH),arm64)
  # Free Pascal's AArch64 cross compiler, built from the compiler sources
  # into the build tree (make toolchain ARCH=arm64), and GNU binutils for
  # AArch64 (aarch64-linux-gnu-*), which the compiler runs to assemble.
  CROSS_COMPILER := build/toolchain/ppcrossa64
  CROSS_PREFIX ?= aarch64-linux-gnu-
  TARGET_FPC := $(CROSS_COMPILER) -XP$(CROSS_PREFIX)
  TARGET_AS := $(CROSS_PREFIX)as
  LD := $(CROSS_PREFIX)ld
  OBJCOPY := $(CROSS_PREFIX)objcopy
  OBJDUMP := $(CROSS_PREFIX)objdump
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
	kernel/network \
	kernel/drivers/storage \
	kernel/drivers/virtio \
	kernel/drivers/usb \
	kernel/drivers/sound \
	kernel/drivers/network \
	kernel/drivers/input \
	kernel/drivers/devices \
	kernel/filesystems \
	kernel/runtime kernel/runtime/$(ARCH) \
	kernel/debug \
	hal/$(ARCH)

# -WR     emit base relocations so the firmware can load the image anywhere
# -Xs     strip symbols
LOADER_FLAGS := $(COMMON_FLAGS) $(LOADER_TARGET) -WR -Xs \
	-Fu$(RTL_LOADER_DIRECTORY) $(addprefix -Fu,$(LOADER_UNIT_DIRECTORIES)) \
	-FU$(LOADER_OBJECT_DIRECTORY) -FE$(BUILD_DIRECTORY)

# -g      debug information (for GDB through QEMU)
# -Cg-    no position independent code
# -Cn     compile only, the kernel is linked with ld below
KERNEL_FLAGS := $(COMMON_FLAGS) $(KERNEL_TARGET) -g -Cg- -Cn \
	-Fu$(RTL_KERNEL_DIRECTORY) $(addprefix -Fu,$(KERNEL_UNIT_DIRECTORIES)) \
	-FU$(KERNEL_OBJECT_DIRECTORY)

KERNEL_LINKER_SCRIPT := kernel/link/$(ARCH).ld

LOADER_EFI := $(BUILD_DIRECTORY)/$(EFI_BOOT_FILE)
KERNEL_ELF := $(BUILD_DIRECTORY)/kernel.elf

.PHONY: all loader kernel esp run debug test test-disk image font clean check-kernel imaging-controls-test icon-test apps-test paint-test aml-test acpi-device-test drawing-test font-test text-test chart-test settings-test files-test controls-test date-controls-test suspend-stress \
	crypto-test tls-test wget-test image-test compression-test

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
	$(call build-rtl,$(RTL_KERNEL_DIRECTORY),rtl/freestanding,$(KERNEL_TARGET))

# --- Cross compiler ----------------------------------------------------------

# Built from the Free Pascal compiler sources with the installed compiler;
# nothing is installed (only for ARCH=arm64).
.PHONY: toolchain
toolchain: $(CROSS_COMPILER)

ifneq ($(CROSS_COMPILER),)
$(CROSS_COMPILER): scripts/build-cross-compiler.sh
	scripts/build-cross-compiler.sh aarch64 $@
endif

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

$(KERNEL_ELF): $(RTL_KERNEL_DIRECTORY)/system.ppu $(KERNEL_ASSEMBLY_OBJECTS) FORCE
	@mkdir -p $(KERNEL_OBJECT_DIRECTORY)
	$(TARGET_FPC) $(KERNEL_FLAGS) kernel/Kernel.Startup.pas
	$(LD) -nostdlib -static --gc-sections -z max-page-size=4096 \
		-T $(KERNEL_LINKER_SCRIPT) -o $@ \
		$(KERNEL_OBJECT_DIRECTORY)/*.o $(RTL_KERNEL_DIRECTORY)/system.o
	@$(MAKE) --no-print-directory check-kernel

# The kernel does not save floating point / SIMD registers on interrupts or
# context switches, so the compiler must never have used them (only the
# routines that save and restore a thread's registers at a switch may).
ifeq ($(ARCH),arm64)
KERNEL_SIMD_PATTERN := [[:space:],][qdsvbh][0-9]+([].,[:space:]]|$$)
KERNEL_FPU_ROUTINES := ArchSaveFpuState|ArchRestoreFpuState
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

# --- EFI system partition --------------------------------------------------

esp: $(LOADER_EFI) $(KERNEL_ELF)
	@mkdir -p $(ESP_DIRECTORY)/EFI/BOOT $(ESP_DIRECTORY)/FreePascalOS
	cp $(LOADER_EFI) $(ESP_DIRECTORY)/EFI/BOOT/$(EFI_BOOT_FILE)
	cp $(KERNEL_ELF) $(ESP_DIRECTORY)/FreePascalOS/kernel.elf

image: esp
	scripts/make-disk-image.sh $(ESP_DIRECTORY) $(BUILD_DIRECTORY)/FreePascalOS.img

TEST_DISK := $(BUILD_DIRECTORY)/test-disk.img
SYSTEM_DISK := $(BUILD_DIRECTORY)/system-disk.img

# make run and make debug boot a system disk of their own, so what is
# done there (files, passwords, logs in /var/log) stays from one run to
# the next but never reaches the built image the tests copy. It is made
# again from the built image whenever that is rebuilt.
RUN_SYSTEM_DISK := $(BUILD_DIRECTORY)/system-disk-interactive.img

$(RUN_SYSTEM_DISK): $(SYSTEM_DISK)
	cp $(SYSTEM_DISK) $@

ifeq ($(ARCH),arm64)
# The AArch64 build boots without the disks for now (user mode on AArch64
# is the next step of the port).
run: esp
	scripts/run-qemu-arm64.sh $(ESP_DIRECTORY)

debug: esp
	scripts/run-qemu-arm64.sh $(ESP_DIRECTORY) --debug
else
run: esp $(TEST_DISK) $(RUN_SYSTEM_DISK)
	scripts/run-qemu.sh $(ARCH) $(ESP_DIRECTORY) --copy $(TEST_DISK) $(RUN_SYSTEM_DISK)

debug: esp $(TEST_DISK) $(RUN_SYSTEM_DISK)
	scripts/run-qemu.sh $(ARCH) $(ESP_DIRECTORY) --debug --copy $(TEST_DISK) $(RUN_SYSTEM_DISK)
endif

# Boot smoke test of the AArch64 build in QEMU's virt machine (not part of
# make test until qemu-system-aarch64 and the edk2 AArch64 firmware are
# standard requirements): the kernel must reach the end of its start-up
# with every self test passed, with the firmware at EL1 and at EL2, and
# run the file system tests on an SD card (SDHCI).
.PHONY: arm64-test
arm64-test:
	@$(MAKE) --no-print-directory ARCH=arm64 esp test-disk
	scripts/test-qemu-arm64.sh build/arm64/esp build/arm64/test-disk-sdsc.img

$(TEST_DISK): scripts/make-test-disk.sh scripts/exfat-tool.py
	scripts/make-test-disk.sh $@

test-disk: $(TEST_DISK)

test: aml-test acpi-device-test drawing-test font-test text-test chart-test settings-test files-test controls-test date-controls-test apps-test paint-test crypto-test tls-test wget-test image-test compression-test \
		imaging-controls-test icon-test esp $(TEST_DISK) \
		$(SYSTEM_DISK)
	scripts/test-qemu.sh $(ARCH) $(ESP_DIRECTORY) $(TEST_DISK) $(SYSTEM_DISK)
	scripts/test-input.py $(ESP_DIRECTORY) $(SYSTEM_DISK)
	scripts/test-session.py $(ESP_DIRECTORY) $(SYSTEM_DISK)
	scripts/test-virtio-gpu.py $(ESP_DIRECTORY) $(SYSTEM_DISK)

# Not part of make test (it takes a minute a round under TCG): suspends
# and wakes the input test's machine ROUNDS times (ACCEL=kvm for KVM,
# POINTERS=1 to check the mouse and tablet after each wake, LOAD=1 to keep
# programs starting and ending across each suspend).
ROUNDS ?= 30
suspend-stress: esp $(TEST_DISK) $(SYSTEM_DISK)
	scripts/stress-suspend.py $(ESP_DIRECTORY) $(SYSTEM_DISK) $(ROUNDS)

include userland/userland.mk

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

aml-test: $(AML_TEST)
	@for machine in $(AML_TEST_MACHINES); do \
		$(AML_TEST) tools/AmlTest/qemu-$$machine-dsdt.aml > build/tools/aml-$$machine.out && \
		diff -u tools/AmlTest/qemu-$$machine.expected build/tools/aml-$$machine.out > /dev/null || \
		{ echo "AML TEST FAILED: $$machine (diff tools/AmlTest/qemu-$$machine.expected build/tools/aml-$$machine.out)"; exit 1; }; \
	done; echo "AML TEST PASSED: $(AML_TEST_MACHINES)"

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

font: $(FONT_TOOL)
	zcat -f $(FONT_SOURCE) > $(FONT_UNPACKED)
	$(FONT_TOOL) $(FONT_UNPACKED) kernel/debug/Debug.ConsoleFont.inc

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

drawing-test: $(DRAWING_TEST) $(SYSTEM_FONTS_STAMP) $(DEJAVU_SANS_STAMP)
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
	$(filter-out %/Font.Files.pas,$(wildcard userland/lib/font/*.pas))

$(FONT_TEST): $(FONT_TEST_SOURCES)
	@mkdir -p build/tools/font-test-units
	fpc -Mobjfpc -O2 -Cr -vew -Futools/FontTest -Fuuserland/lib/drawing -Fuuserland/lib/font \
		-FUbuild/tools/font-test-units -o$@ tools/FontTest/FontTest.pas

$(FONT_FIXTURES_STAMP): $(FONT_FIXTURE_SCRIPTS) $(wildcard userland/fonts/*/*.ttf)
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

chart-test: $(CHART_TEST) $(DEJAVU_SANS_STAMP)
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
# the order and types of items, permissions, what a drop does) and the
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
	userland/files/FileManager.DropRules.pas userland/lib/font/Font.Utf8.pas

$(FILES_TEST): $(FILES_TEST_SOURCES)
	@mkdir -p build/tools/files-test-units
	fpc -Mobjfpc -O2 -vew -Futools/FilesTest -Fuuserland/lib/controls -Fuuserland/lib/font -Fuuserland/files \
		-FUbuild/tools/files-test-units -o$@ tools/FilesTest/FilesTest.pas

files-test: $(FILES_TEST)
	@$(FILES_TEST) > build/tools/files-test.out || \
		{ grep FAIL build/tools/files-test.out; echo "FILES TEST FAILED (build/tools/files-test.out)"; exit 1; }
	@echo "FILES TEST PASSED: $$(tail -n 1 build/tools/files-test.out | cut -d ' ' -f 2-)"

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
	$(filter-out %/Crypto.Random.pas %/Crypto.Contents.pas,$(wildcard userland/lib/cryptography/*.pas))

$(CRYPTO_TEST): $(CRYPTO_TEST_SOURCES)
	@mkdir -p build/tools/crypto-test-units
	fpc -Mobjfpc -O2 -vew -Futools/CryptoTest -Fuuserland/lib/cryptography -Fushared -Fishared \
		-FUbuild/tools/crypto-test-units -o$@ tools/CryptoTest/CryptoTest.pas

crypto-test: $(CRYPTO_TEST)
	@$(CRYPTO_TEST) > build/tools/crypto-test.out || \
		{ grep -A2 FAIL build/tools/crypto-test.out; echo "CRYPTO TEST FAILED (build/tools/crypto-test.out)"; exit 1; }
	@echo "CRYPTO TEST PASSED: $$(tail -n 1 build/tools/crypto-test.out | cut -d ' ' -f 3-)"

# libcompression builds for the host too, and is checked there against
# zlib's own output (made by Python's zlib when the test is built); what
# it compresses is then decompressed by Python's zlib and gzip.
COMPRESSION_TEST := build/tools/CompressionTest
COMPRESSION_TEST_UNITS := build/tools/compression-test-units
COMPRESSION_VECTORS := $(COMPRESSION_TEST_UNITS)/CompressionTest.Vectors.inc
COMPRESSION_SAMPLES := build/tools/compression-samples
COMPRESSION_TEST_SOURCES := $(wildcard tools/CompressionTest/*.pas) tools/CryptoTest/TestChecks.pas \
	$(filter-out %/Compression.Contents.pas,$(wildcard userland/lib/compression/*.pas))

$(COMPRESSION_VECTORS): tools/CompressionTest/make-vectors.py
	@mkdir -p $(COMPRESSION_TEST_UNITS)
	python3 tools/CompressionTest/make-vectors.py > $@.tmp
	@mv $@.tmp $@

$(COMPRESSION_TEST): $(COMPRESSION_TEST_SOURCES) $(COMPRESSION_VECTORS)
	@mkdir -p $(COMPRESSION_TEST_UNITS)
	fpc -Mobjfpc -O2 -Cr -vew -Futools/CompressionTest -Futools/CryptoTest -Fuuserland/lib/compression \
		-Fi$(COMPRESSION_TEST_UNITS) -FU$(COMPRESSION_TEST_UNITS) -o$@ tools/CompressionTest/CompressionTest.pas

compression-test: $(COMPRESSION_TEST)
	@mkdir -p $(COMPRESSION_SAMPLES)
	@$(COMPRESSION_TEST) $(COMPRESSION_SAMPLES) > build/tools/compression-test.out || \
		{ grep -A2 FAIL build/tools/compression-test.out; echo "COMPRESSION TEST FAILED (build/tools/compression-test.out)"; exit 1; }
	@python3 tools/CompressionTest/check-with-zlib.py $(COMPRESSION_SAMPLES) > build/tools/compression-zlib.out || \
		{ cat build/tools/compression-zlib.out; echo "COMPRESSION TEST FAILED (zlib refuses what it compressed)"; exit 1; }
	@echo "COMPRESSION TEST PASSED: $$(tail -n 1 build/tools/compression-test.out | cut -d ' ' -f 3-)"

# libtls but for its socket, file and clock units builds for the host too
# (with a Crypto.Random of the host's), and is checked there; then its
# client connects to OpenSSL's s_server (skipped without openssl).
TLS_TEST := build/tools/TlsTest
TLS_TEST_SOURCES := $(wildcard tools/TlsTest/*.pas) $(wildcard tools/TlsTest/*.inc) \
	tools/CryptoTest/TestChecks.pas $(filter-out %/Crypto.Random.pas,$(wildcard userland/lib/cryptography/*.pas)) \
	$(filter-out %/Tls.SocketTransport.pas %/Tls.SystemTrust.pas %/Tls.Sessions.pas %/Tls.Contents.pas, \
		$(wildcard userland/lib/tls/*.pas))

$(TLS_TEST): $(TLS_TEST_SOURCES)
	@mkdir -p build/tools/tls-test-units
	fpc -Mobjfpc -O2 -vew -Futools/TlsTest -Futools/CryptoTest -Fuuserland/lib/tls -Fuuserland/lib/cryptography \
		-Fushared -Fishared -FUbuild/tools/tls-test-units -o$@ tools/TlsTest/TlsTest.pas

tls-test: $(TLS_TEST)
	@$(TLS_TEST) tools/TlsTest/certificates userland/etc/ssl/certs/ca-certificates.crt > build/tools/tls-test.out || \
		{ grep -A2 FAIL build/tools/tls-test.out; echo "TLS TEST FAILED (build/tools/tls-test.out)"; exit 1; }
	@echo "TLS TEST PASSED: $$(tail -n 1 build/tools/tls-test.out | cut -d ' ' -f 3-)"
	@tools/TlsTest/run-interop.sh $(TLS_TEST) > build/tools/tls-interop.out 2>&1 || \
		{ grep FAIL build/tools/tls-interop.out; echo "TLS INTEROP TEST FAILED (build/tools/tls-interop.out)"; exit 1; }
	@tail -n 1 build/tools/tls-interop.out

# wget's URLs, response heads and chunked decoding build for the host too.
WGET_TEST := build/tools/WgetTest
WGET_TEST_SOURCES := tools/WgetTest/WgetTest.pas tools/CryptoTest/TestChecks.pas userland/wget/Wget.Urls.pas \
	userland/wget/Wget.Headers.pas userland/wget/Wget.Chunks.pas

$(WGET_TEST): $(WGET_TEST_SOURCES)
	@mkdir -p build/tools/wget-test-units
	fpc -Mobjfpc -O2 -vew -Futools/WgetTest -Futools/CryptoTest -Fuuserland/wget \
		-FUbuild/tools/wget-test-units -o$@ tools/WgetTest/WgetTest.pas

wget-test: $(WGET_TEST)
	@$(WGET_TEST) > build/tools/wget-test.out || \
		{ grep FAIL build/tools/wget-test.out; echo "WGET TEST FAILED (build/tools/wget-test.out)"; exit 1; }
	@echo "WGET TEST PASSED: $$(tail -n 1 build/tools/wget-test.out | cut -d ' ' -f 3-)"

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
