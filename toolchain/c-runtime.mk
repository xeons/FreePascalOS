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

# The C and C++ toolchain and the C runtime on the system disk (included
# by the Makefile after userland/userland.mk).
#
#   make c-toolchain   Build binutils, GCC, mlibc and libstdc++ for ARCH
#                      (toolchain/build-toolchain.sh: build/toolchain/<triplet>,
#                      sysroot build/sysroot/<arch>)
#   make c-runtime     Put the C runtime (/usr/lib: ld.so, libc.so, libm.so,
#                      libgcc_s, libstdc++ ...) and the C test programs
#                      (/usr/bin: hello, hello-static, ctest, cxxtest) into
#                      the userland build, for the system disk; nothing
#                      without the toolchain
#   make c-test        Boot with /usr/bin/ctest as the first program and
#                      check that every C and C++ test passed
#   make clang-toolchain  Build Clang and lld with the freepascalos targets
#                      (toolchain/build-clang.sh: build/toolchain/llvm, one
#                      build for both architectures; optional and long). With
#                      it, make c-runtime also builds ctest-clang,
#                      cxxtest-clang and hello-clang-static, which ctest runs
#   make clang-driver-test  Check the command lines of Clang's freepascalos
#                      driver (clang -###) for both architectures

ifeq ($(ARCH),arm64)
C_TRIPLET := aarch64-freepascalos
else
C_TRIPLET := x86_64-freepascalos
endif
C_TOOLCHAIN := build/toolchain/$(C_TRIPLET)
C_SYSROOT := build/sysroot/$(ARCH)
C_CC := $(C_TOOLCHAIN)/bin/$(C_TRIPLET)-gcc
C_CXX := $(C_TOOLCHAIN)/bin/$(C_TRIPLET)-g++
C_STRIP := $(C_TOOLCHAIN)/bin/$(C_TRIPLET)-strip
C_RUNTIME_OUTPUT := $(USER_BUILD_DIRECTORY)/usr
C_RUNTIME_STAMP := $(USER_BUILD_DIRECTORY)/c-runtime.stamp
C_TEST_SOURCES := $(wildcard toolchain/ctest/*.c toolchain/ctest/*.cpp toolchain/ctest/*.h)
# The sysroot of this tree, also for compilers copied from another one.
C_FLAGS := -O2 -Wall -Wextra --sysroot=$(C_SYSROOT)
# Clang (make clang-toolchain): <triple>.cfg beside it gives the system
# root and the GCC installation for --target.
C_CLANG := build/toolchain/llvm/bin/clang
C_CLANG_TARGET := --target=$(C_TRIPLET)

# The C runtime's libraries as the system disk has them (stripped).
C_RUNTIME_LIBRARIES := ld.so libc.so libm.so libpthread.so libdl.so librt.so libutil.so libresolv.so
C_RUNTIME_GCC_LIBRARIES := libgcc_s.so.1 libstdc++.so.6

.PHONY: c-toolchain c-runtime c-test clang-toolchain clang-driver-test

c-toolchain:
	toolchain/build-toolchain.sh $(ARCH)

clang-toolchain:
	toolchain/build-clang.sh

clang-driver-test:
	scripts/test-clang-driver.sh $(C_CLANG)

c-runtime: $(C_RUNTIME_STAMP)

# Rebuilt when the toolchain's libc or a test changes; without the
# toolchain the system disk simply has no C runtime.
$(C_RUNTIME_STAMP): $(C_TEST_SOURCES) toolchain/c-runtime.mk $(wildcard $(C_SYSROOT)/usr/lib/libc.so) $(wildcard $(C_CLANG))
	@mkdir -p $(USER_BUILD_DIRECTORY)
	@if [ ! -x "$(C_CC)" ] || [ ! -f "$(C_SYSROOT)/usr/lib/libc.so" ]; then \
		echo "c-runtime: no C toolchain for $(ARCH) (make c-toolchain); the system disk has no C runtime"; \
		rm -rf $(C_RUNTIME_OUTPUT); \
	else \
		$(MAKE) --no-print-directory c-runtime-files; \
	fi
	@touch $@

.PHONY: c-runtime-files
c-runtime-files:
	@rm -rf $(C_RUNTIME_OUTPUT)
	@mkdir -p $(C_RUNTIME_OUTPUT)/lib $(C_RUNTIME_OUTPUT)/bin
	for library in $(C_RUNTIME_LIBRARIES); do \
		$(C_STRIP) --strip-unneeded -o $(C_RUNTIME_OUTPUT)/lib/$$library $(C_SYSROOT)/usr/lib/$$library; \
	done
	for library in $(C_RUNTIME_GCC_LIBRARIES); do \
		if [ -f $(C_SYSROOT)/usr/lib/$$library ]; then \
			$(C_STRIP) --strip-unneeded -o $(C_RUNTIME_OUTPUT)/lib/$$library $(C_SYSROOT)/usr/lib/$$library; \
		fi; \
	done
	$(C_CC) $(C_FLAGS) -fPIC -shared -o $(C_RUNTIME_OUTPUT)/lib/libctestplugin.so toolchain/ctest/plugin.c
	$(C_CC) $(C_FLAGS) -o $(C_RUNTIME_OUTPUT)/bin/hello toolchain/ctest/hello.c
	$(C_CC) $(C_FLAGS) -static -o $(C_RUNTIME_OUTPUT)/bin/hello-static toolchain/ctest/hello.c
	$(C_CC) $(C_FLAGS) -pthread -o $(C_RUNTIME_OUTPUT)/bin/ctest toolchain/ctest/ctest*.c -lm -ldl
	$(C_CC) $(C_FLAGS) -o $(C_RUNTIME_OUTPUT)/bin/ctest-suid toolchain/ctest/suidhelper.c -ldl
	@if [ -f $(C_SYSROOT)/usr/lib/libstdc++.so.6 ]; then \
		echo "$(C_CXX) $(C_FLAGS) -pthread -o $(C_RUNTIME_OUTPUT)/bin/cxxtest toolchain/ctest/cxxtest.cpp"; \
		$(C_CXX) $(C_FLAGS) -pthread -o $(C_RUNTIME_OUTPUT)/bin/cxxtest toolchain/ctest/cxxtest.cpp; \
	fi
	@if [ -x $(C_CLANG) ]; then $(MAKE) --no-print-directory c-runtime-clang-files; fi
	$(C_STRIP) --strip-unneeded $(C_RUNTIME_OUTPUT)/bin/* $(C_RUNTIME_OUTPUT)/lib/libctestplugin.so

# The test programs built with Clang: the C suite linked by GNU ld, the
# C++ test with libstdc++, and a static program linked by ld.lld.
.PHONY: c-runtime-clang-files
c-runtime-clang-files:
	$(C_CLANG) $(C_CLANG_TARGET) $(C_FLAGS) -pthread -o $(C_RUNTIME_OUTPUT)/bin/ctest-clang toolchain/ctest/ctest*.c -lm -ldl
	@if [ -f $(C_SYSROOT)/usr/lib/libstdc++.so.6 ]; then \
		echo "$(C_CLANG)++ $(C_CLANG_TARGET) $(C_FLAGS) -pthread -o $(C_RUNTIME_OUTPUT)/bin/cxxtest-clang toolchain/ctest/cxxtest.cpp"; \
		$(C_CLANG)++ $(C_CLANG_TARGET) $(C_FLAGS) -pthread -o $(C_RUNTIME_OUTPUT)/bin/cxxtest-clang toolchain/ctest/cxxtest.cpp; \
	fi
	$(C_CLANG) $(C_CLANG_TARGET) $(C_FLAGS) -static -fuse-ld=lld -o $(C_RUNTIME_OUTPUT)/bin/hello-clang-static toolchain/ctest/hello.c

$(SYSTEM_DISK): $(C_RUNTIME_STAMP)

c-test: esp $(SYSTEM_DISK)
	scripts/test-c-runtime.sh $(ARCH) $(ESP_DIRECTORY) $(SYSTEM_DISK)
