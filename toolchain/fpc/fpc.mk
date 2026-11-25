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

# Native Free Pascal: the compiler as a FreePascalOS program, with its
# units and configuration, laid out as they go on the system disk.
# Included by userland/userland.mk.
#
#   /bin/fpc                    the driver (runs ppcx64 or ppca64)
#   /bin/ppcx64, /bin/ppca64    the compiler, for x86_64- or
#                               aarch64-freepascalos
#   /etc/fpc.cfg                its configuration (toolchain/fpc/fpc.cfg)
#   /usr/lib/fpc/3.2.2/units/<cpu>-freepascalos/
#       rtl/                    the runtime library's units (in
#                               libsystem.so) and si_prc, si_dll
#       system/ cryptography/ coreutils/ ...
#                               the units of /lib/lib<name>.so
#
# The units of the libraries are the ones the userland was built with,
# marked by ppumove as living in their library (see "Native Free Pascal"
# in docs/Architecture.md), so a program compiled with -XD links against
# the library instead of copying the units in.
#
# NATIVE_FPC=no leaves the compiler off the system disk.
# NATIVE_FPC_LIBRARIES names the libraries whose units are installed
# (by default the ones command line programs use; "all" for every one).

NATIVE_FPC ?= yes
FPC_VERSION := 3.2.2
ifeq ($(ARCH),arm64)
  FPC_TARGET_CPU := aarch64
  NATIVE_COMPILER_NAME := ppca64
  NATIVE_COMPILER_CPU_DIRECTORIES := aarch64
else
  FPC_TARGET_CPU := x86_64
  NATIVE_COMPILER_NAME := ppcx64
  NATIVE_COMPILER_CPU_DIRECTORIES := x86_64 x86
endif
FPC_TARGET_DIRECTORY_NAME := $(FPC_TARGET_CPU)-freepascalos

# The patched sources build-cross-compiler.sh made for the cross compiler.
PATCHED_FPC_SOURCE := build/toolchain/fpc-source-$(FPC_TARGET_CPU)
PATCHED_COMPILER_SOURCE := $(PATCHED_FPC_SOURCE)/compiler
# ppumove, a host tool built from the same sources.
PPUMOVE := build/toolchain/ppumove

NATIVE_FPC_BUILD_DIRECTORY := $(BUILD_DIRECTORY)/fpc
NATIVE_FPC_ROOT := $(USER_BUILD_DIRECTORY)/fpc-root
NATIVE_FPC_UNIT_ROOT := $(NATIVE_FPC_ROOT)/usr/lib/fpc/$(FPC_VERSION)/units/$(FPC_TARGET_DIRECTORY_NAME)
NATIVE_COMPILER := $(NATIVE_FPC_ROOT)/bin/$(NATIVE_COMPILER_NAME)
NATIVE_FPC_DRIVER := $(NATIVE_FPC_ROOT)/bin/fpc
NATIVE_FPC_CONFIGURATION := $(NATIVE_FPC_ROOT)/etc/fpc.cfg
NATIVE_FPC_UNITS_STAMP := $(NATIVE_FPC_UNIT_ROOT)/.staged

# Library name and the folder its units were compiled into.
NATIVE_FPC_DEFAULT_LIBRARIES := system cryptography coreutils
NATIVE_FPC_ALL_LIBRARIES := system cryptography coreutils audio drawing font configuration windowing controls \
	tls image compression archive ssh http quic css svg javascript web webipc webview
NATIVE_FPC_LIBRARIES ?= $(NATIVE_FPC_DEFAULT_LIBRARIES)
ifeq ($(NATIVE_FPC_LIBRARIES),all)
  override NATIVE_FPC_LIBRARIES := $(NATIVE_FPC_ALL_LIBRARIES)
endif
NATIVE_FPC_LIBRARY_FILES := $(addprefix $(USER_LIBRARY_OUTPUT)/lib,$(addsuffix .so,$(NATIVE_FPC_LIBRARIES)))

# What the system disk gets (nothing with NATIVE_FPC=no).
ifeq ($(NATIVE_FPC),yes)
  NATIVE_FPC_SYSTEM_DISK_FILES := $(NATIVE_COMPILER) $(NATIVE_FPC_DRIVER) $(NATIVE_FPC_CONFIGURATION) $(NATIVE_FPC_UNITS_STAMP)
else
  NATIVE_FPC_SYSTEM_DISK_FILES :=
endif

# The compiler's own flags for compiling itself and its tools as
# FreePascalOS programs (as its Makefile does for a release, with the
# code page maps of rtl/charmaps compiled in).
NATIVE_COMPILER_FLAGS := $(USER_FLAGS) -Fu$(RTL_USER_DIRECTORY) -Fu$(SYSTEM_LIBRARY_OBJECTS) \
	-Fu$(FPC_RTL_SOURCE)/charmaps \
	-Fu$(PATCHED_COMPILER_SOURCE) $(addprefix -Fu$(PATCHED_COMPILER_SOURCE)/,$(NATIVE_COMPILER_CPU_DIRECTORIES)) \
	-Fu$(PATCHED_COMPILER_SOURCE)/systems \
	-Fi$(PATCHED_COMPILER_SOURCE) $(addprefix -Fi$(PATCHED_COMPILER_SOURCE)/,$(NATIVE_COMPILER_CPU_DIRECTORIES)) \
	-d$(FPC_TARGET_CPU) -dGDB -dBROWSERLOG -dRELEASE -vw-n-

.PHONY: native-fpc
native-fpc: $(NATIVE_COMPILER) $(NATIVE_FPC_DRIVER) $(NATIVE_FPC_CONFIGURATION) $(NATIVE_FPC_UNITS_STAMP)

$(PPUMOVE): $(CROSS_COMPILER)
	@rm -rf build/toolchain/ppumove-units
	@mkdir -p build/toolchain/ppumove-units
	$(FPC) -O1 -Xs -vw-n- -Fu$(PATCHED_COMPILER_SOURCE) -Fu$(PATCHED_COMPILER_SOURCE)/generic \
		-Fu$(PATCHED_COMPILER_SOURCE)/systems -Fi$(PATCHED_COMPILER_SOURCE) -dGENERIC_CPU \
		-FUbuild/toolchain/ppumove-units -o$@ $(PATCHED_COMPILER_SOURCE)/utils/ppumove.pp

# Links a FreePascalOS program $(1) from the objects in $(2), as the
# userland's programs are.
define link-native-fpc-program
	@mkdir -p $(dir $(1))
	$(LD) -pie --no-dynamic-linker $(USER_LINK_FLAGS) -s -e _start -o $(1) \
		$(2)/*.o $(RTL_USER_DIRECTORY)/si_prc.o -L$(USER_LIBRARY_OUTPUT) -lsystem
endef

$(NATIVE_COMPILER): $(SYSTEM_LIBRARY) $(CROSS_COMPILER)
	@rm -rf $(NATIVE_FPC_BUILD_DIRECTORY)/compiler
	@mkdir -p $(NATIVE_FPC_BUILD_DIRECTORY)/compiler
	$(TARGET_FPC) $(NATIVE_COMPILER_FLAGS) -FU$(NATIVE_FPC_BUILD_DIRECTORY)/compiler \
		-FE$(NATIVE_FPC_BUILD_DIRECTORY)/compiler $(PATCHED_COMPILER_SOURCE)/pp.pas
	$(call link-native-fpc-program,$@,$(NATIVE_FPC_BUILD_DIRECTORY)/compiler)

$(NATIVE_FPC_DRIVER): $(SYSTEM_LIBRARY) $(CROSS_COMPILER)
	@rm -rf $(NATIVE_FPC_BUILD_DIRECTORY)/driver
	@mkdir -p $(NATIVE_FPC_BUILD_DIRECTORY)/driver
	$(TARGET_FPC) $(NATIVE_COMPILER_FLAGS) -FU$(NATIVE_FPC_BUILD_DIRECTORY)/driver \
		-FE$(NATIVE_FPC_BUILD_DIRECTORY)/driver $(PATCHED_COMPILER_SOURCE)/utils/fpc.pp
	$(call link-native-fpc-program,$@,$(NATIVE_FPC_BUILD_DIRECTORY)/driver)

$(NATIVE_FPC_CONFIGURATION): toolchain/fpc/fpc.cfg
	@mkdir -p $(dir $@)
	cp toolchain/fpc/fpc.cfg $@

# The units: copies of the userland's, marked by ppumove as living in
# their library (ppumove rewrites the copies in place; -b writes the
# commands for making the library into pmove.sh instead of running
# them, since the library is already made). si_prc and si_dll are linked
# into every program and library, so they stay as they are, with their
# objects.
define stage-library-units
	@mkdir -p $(NATIVE_FPC_UNIT_ROOT)/$(1)
	@cp $(filter-out %/buildrtl.ppu %/si_prc.ppu %/si_dll.ppu,$(wildcard $(2)/*.ppu)) $(NATIVE_FPC_UNIT_ROOT)/$(1)/
	cd $(NATIVE_FPC_BUILD_DIRECTORY)/ppumove && $(abspath $(PPUMOVE)) -q -b -o $(3) \
		-i $(abspath $(NATIVE_FPC_UNIT_ROOT)/$(1)) $$(cd $(abspath $(NATIVE_FPC_UNIT_ROOT)/$(1)) && ls *.ppu)

endef

$(NATIVE_FPC_UNITS_STAMP): $(PPUMOVE) $(NATIVE_FPC_LIBRARY_FILES)
	@rm -rf $(NATIVE_FPC_UNIT_ROOT) $(NATIVE_FPC_BUILD_DIRECTORY)/ppumove
	@mkdir -p $(NATIVE_FPC_BUILD_DIRECTORY)/ppumove
	$(call stage-library-units,rtl,$(RTL_USER_DIRECTORY),system)
	cp $(RTL_USER_DIRECTORY)/si_prc.ppu $(RTL_USER_DIRECTORY)/si_prc.o \
		$(RTL_USER_DIRECTORY)/si_dll.ppu $(RTL_USER_DIRECTORY)/si_dll.o $(NATIVE_FPC_UNIT_ROOT)/rtl/
	$(foreach library,$(NATIVE_FPC_LIBRARIES),$(call stage-library-units,$(library),$(USER_BUILD_DIRECTORY)/$(library),$(library)))
	@touch $@

# The host check (make native-fpc-test, part of make test): the staged
# compiler, driver, configuration and units, and on x86-64 a program the
# cross compiler linked with its internal ELF linker against them.
NATIVE_FPC_TEST := build/tools/NativeFpcTest
ifeq ($(ARCH),amd64)
  INTERNAL_LINK_SAMPLE := $(NATIVE_FPC_BUILD_DIRECTORY)/sample/InternalLinkSample
else
  INTERNAL_LINK_SAMPLE :=
endif

$(NATIVE_FPC_TEST): tools/NativeFpcTest/NativeFpcTest.pas
	@mkdir -p build/tools/native-fpc-test-units
	$(FPC) -O2 -Cr -Co -FEbuild/tools -FUbuild/tools/native-fpc-test-units $<

$(NATIVE_FPC_BUILD_DIRECTORY)/sample/InternalLinkSample: tools/NativeFpcTest/InternalLinkSample.pas $(NATIVE_FPC_UNITS_STAMP)
	@rm -rf $(dir $@)
	@mkdir -p $(dir $@)
	$(TARGET_FPC) -n -Tfreepascalos -XD -OoNOSTACKFRAME -Fu$(NATIVE_FPC_UNIT_ROOT)/rtl -Fl$(USER_LIBRARY_OUTPUT) \
		-FU$(dir $@) -FE$(dir $@) $<

.PHONY: native-fpc-test
native-fpc-test: $(NATIVE_FPC_TEST) native-fpc $(INTERNAL_LINK_SAMPLE)
	$(NATIVE_FPC_TEST) $(FPC_TARGET_CPU) $(NATIVE_FPC_ROOT) $(INTERNAL_LINK_SAMPLE)
