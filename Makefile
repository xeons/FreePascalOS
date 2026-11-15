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
#                   the emulated keyboard and serial port; report pass/fail
#   make aml-test   Run the kernel's AML interpreter on the host against captured
#                   QEMU DSDTs and compare what it finds with the expected output
#   make userland   Build the user mode libraries and programs
#   make system-disk  Build the ext4 system volume with /bin and /lib
#   make image      Build a GPT disk image that can be written to a USB stick
#   make font       Regenerate the console font include from a PSF font
#   make clean      Remove all build output

ARCH ?= amd64

FPC ?= fpc
LD ?= ld
OBJCOPY ?= objcopy
OBJDUMP ?= objdump

BUILD_DIRECTORY := build/$(ARCH)
ESP_DIRECTORY := $(BUILD_DIRECTORY)/esp

ifeq ($(ARCH),amd64)
  LOADER_TARGET := -Twin64
  KERNEL_TARGET := -Tlinux
  EFI_BOOT_FILE := BOOTX64.EFI
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
	kernel/processes \
	kernel/firmware \
	kernel/io \
	kernel/drivers/storage \
	kernel/drivers/virtio \
	kernel/drivers/usb \
	kernel/drivers/sound \
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

.PHONY: all loader kernel esp run debug test test-disk image font clean check-kernel aml-test

all: esp

# --- Runtime library -------------------------------------------------------

# rtl/freestanding holds the System unit of the loader and the kernel,
# rtl/common the units both need. User programs get the Free Pascal RTL
# (rtl/fpc, built by userland/userland.mk).
# Arguments: output directory, System unit directory, compiler flags.
define build-rtl
	@mkdir -p $(1)
	$(FPC) $(COMMON_FLAGS) $(3) -Firtl/common -Us -FU$(1) $(2)/system.pas
	$(FPC) $(COMMON_FLAGS) $(3) -Fu$(1) -FU$(1) rtl/common/objpas.pas
	$(FPC) $(COMMON_FLAGS) $(3) -Fu$(1) -FU$(1) rtl/common/sysinit.pas
	$(FPC) $(COMMON_FLAGS) $(3) -Fu$(1) -FU$(1) rtl/common/fpintres.pas
endef

RTL_SOURCES := $(wildcard rtl/common/*) $(wildcard rtl/freestanding/*.pas)

$(RTL_LOADER_DIRECTORY)/system.ppu: $(RTL_SOURCES)
	$(call build-rtl,$(RTL_LOADER_DIRECTORY),rtl/freestanding,$(LOADER_TARGET))

$(RTL_KERNEL_DIRECTORY)/system.ppu: $(RTL_SOURCES)
	$(call build-rtl,$(RTL_KERNEL_DIRECTORY),rtl/freestanding,$(KERNEL_TARGET))

# --- Loader ----------------------------------------------------------------

loader: $(LOADER_EFI)

$(LOADER_EFI): $(RTL_LOADER_DIRECTORY)/system.ppu FORCE
	@mkdir -p $(LOADER_OBJECT_DIRECTORY)
	$(FPC) $(LOADER_FLAGS) boot/uefi/OsLoader.pas
	$(OBJCOPY) --subsystem efi-app $(BUILD_DIRECTORY)/OsLoader.exe $@

# --- Kernel ----------------------------------------------------------------

kernel: $(KERNEL_ELF)

# Code that cannot be written in Pascal (16-bit start-up code for the
# secondary processors).
KERNEL_ASSEMBLY_OBJECTS := $(KERNEL_OBJECT_DIRECTORY)/ProcessorTrampoline.o

$(KERNEL_OBJECT_DIRECTORY)/%.o: kernel/core/$(ARCH)/%.s
	@mkdir -p $(KERNEL_OBJECT_DIRECTORY)
	$(AS) --64 -o $@ $<

$(KERNEL_ELF): $(RTL_KERNEL_DIRECTORY)/system.ppu $(KERNEL_ASSEMBLY_OBJECTS) FORCE
	@mkdir -p $(KERNEL_OBJECT_DIRECTORY)
	$(FPC) $(KERNEL_FLAGS) kernel/Kernel.Startup.pas
	$(LD) -nostdlib -static --gc-sections -z max-page-size=4096 \
		-T $(KERNEL_LINKER_SCRIPT) -o $@ \
		$(KERNEL_OBJECT_DIRECTORY)/*.o $(RTL_KERNEL_DIRECTORY)/system.o
	@$(MAKE) --no-print-directory check-kernel

# The kernel does not save floating point / SIMD registers on interrupts or
# context switches, so the compiler must never have used them.
check-kernel:
	@if $(OBJDUMP) -d $(KERNEL_ELF) | grep -qE '%(x|y|z)mm[0-9]'; then \
		echo "error: kernel code uses SSE registers, which the kernel does not preserve"; \
		$(OBJDUMP) -d $(KERNEL_ELF) | grep -E '%(x|y|z)mm[0-9]' | head; \
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

run: esp $(TEST_DISK) $(SYSTEM_DISK)
	scripts/run-qemu.sh $(ARCH) $(ESP_DIRECTORY) --copy $(TEST_DISK) $(SYSTEM_DISK)

debug: esp $(TEST_DISK) $(SYSTEM_DISK)
	scripts/run-qemu.sh $(ARCH) $(ESP_DIRECTORY) --debug --copy $(TEST_DISK) $(SYSTEM_DISK)

$(TEST_DISK): scripts/make-test-disk.sh scripts/exfat-tool.py
	scripts/make-test-disk.sh $@

test-disk: $(TEST_DISK)

test: aml-test esp $(TEST_DISK) $(SYSTEM_DISK)
	scripts/test-qemu.sh $(ARCH) $(ESP_DIRECTORY) $(TEST_DISK) $(SYSTEM_DISK)
	scripts/test-input.py $(ESP_DIRECTORY) $(SYSTEM_DISK)

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

font: $(FONT_TOOL)
	zcat -f $(FONT_SOURCE) > $(FONT_UNPACKED)
	$(FONT_TOOL) $(FONT_UNPACKED) kernel/debug/Debug.ConsoleFont.inc

clean:
	rm -rf build

FORCE:
