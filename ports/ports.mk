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

# The ports tree's part of the build (included by the top level
# Makefile after userland/userland.mk; ports/README.md describes it):
#
#   make ports PORTS="ptop zlib"   build the ports' packages
#                                  (build/ARCH/ports/packages)
#   make port-NAME                 build one port's package
#   make ports-lint                check every port without building
#   make ports-test                the ports tool's host tests
#   make pkg-test                  pkg's units on the host
#   make ports-repo                a repository of the packages built
#                                  (INDEX, signed with PORTS_SIGNING_KEY)
#
# The system disk carries the ports in ports/image.list installed, and
# the package coretest installs (pkg-selftest) as a file in
# /var/cache/pkg: both come from build/ARCH/ports/image-root, which
# scripts/make-system-disk.sh copies onto the disk.

PORTS_TOOL := python3 -I scripts/ports.py --arch $(ARCH)
PORTS_PROCESSOR := $(if $(filter arm64,$(ARCH)),aarch64,x86_64)
PORTS_BUILD_DIRECTORY := $(BUILD_DIRECTORY)/ports
PORTS_PACKAGE_DIRECTORY := $(PORTS_BUILD_DIRECTORY)/packages
PORTS_IMAGE_ROOT := $(PORTS_BUILD_DIRECTORY)/image-root
PORTS_IMAGE_STAMP := $(PORTS_BUILD_DIRECTORY)/image-root.done
PORTS_SOURCES := $(wildcard ports/*/*/port.toml ports/*/*/files/* ports/*/*/patches/*) ports/image.list \
	ports/licenses.txt ports/port.schema.json $(wildcard scripts/portstool/*.py scripts/portstool/builders/*.py)
PORTS_SELFTEST_PACKAGE := pkg-selftest-1.0-$(PORTS_PROCESSOR).pkg.tar.zst

# How Pascal ports are compiled and linked: exactly as userland.mk
# builds a /bin program (scripts/portstool/toolchain.py reads it).
PORTS_FPC_SETTINGS := $(USER_BUILD_DIRECTORY)/ports-fpc.settings
PORTS_STRIP := $(patsubst %ld,%strip,$(LD))

.PHONY: ports ports-fpc-settings ports-lint ports-test ports-repo ports-image

ports-fpc-settings: $(PORTS_FPC_SETTINGS)

$(PORTS_FPC_SETTINGS): Makefile userland/userland.mk ports/ports.mk
	@mkdir -p $(dir $@)
	@printf '%s\n' "compiler=$(TARGET_FPC)" "flags=$(USER_FLAGS)" "rtl=$(RTL_USER_DIRECTORY)" \
		"units=$(USER_BUILD_DIRECTORY)" "libraries=$(USER_LIBRARY_OUTPUT)" "linker=$(LD)" \
		"link_flags=$(USER_LINK_FLAGS)" "startup=$(RTL_USER_DIRECTORY)/si_prc.o" \
		"fpc_source=$(FPC_SOURCE)" "strip=$(PORTS_STRIP)" > $@

ports: userland $(PORTS_FPC_SETTINGS)
	@test -n "$(PORTS)" || { echo 'make ports PORTS="NAME ..." (scripts/ports.py list shows them)'; exit 1; }
	$(PORTS_TOOL) package $(PORTS)

port-%: userland $(PORTS_FPC_SETTINGS)
	$(PORTS_TOOL) package $*

ports-lint:
	$(PORTS_TOOL) lint

ports-repo:
	$(PORTS_TOOL) repo $(PORTS_PACKAGE_DIRECTORY) $(if $(PORTS_SIGNING_KEY),--key $(PORTS_SIGNING_KEY))

ports-image: $(PORTS_IMAGE_STAMP)

# The userland comes first (order only: the stamp is made again when the
# ports or the libraries Pascal ports link against change).
$(PORTS_IMAGE_STAMP): $(PORTS_FPC_SETTINGS) $(PORTS_SOURCES) $(SYSTEM_LIBRARY) $(CORE_LIBRARY) | userland
	@rm -rf $(PORTS_IMAGE_ROOT)
	$(PORTS_TOOL) install-to-image --root $(PORTS_IMAGE_ROOT) --list ports/image.list
	$(PORTS_TOOL) package pkg-selftest
	@mkdir -p $(PORTS_IMAGE_ROOT)/var/cache/pkg
	cp $(PORTS_PACKAGE_DIRECTORY)/$(PORTS_SELFTEST_PACKAGE) $(PORTS_IMAGE_ROOT)/var/cache/pkg/
	@touch $@

$(SYSTEM_DISK): $(PORTS_IMAGE_STAMP)

# pkg's units on the host (all but /bin/sh and HTTP, which Pkg.System
# gives on the system): versions against the ports tool's order,
# manifests, indexes, the database install-to-image writes, and whole
# install, upgrade, verify and remove runs and repository updates under
# a root of the test's own, over packages make-fixtures.py makes with
# the ports tool. Built without range checks, as CryptoTest builds
# libcryptography.
PKG_TEST := build/tools/PkgTest
PKG_TEST_UNITS := build/tools/pkg-test-units
PKG_TEST_FIXTURES := build/tools/pkg-fixtures
PKG_TEST_SOURCES := $(wildcard tools/PkgTest/*.pas) tools/CryptoTest/TestChecks.pas \
	$(filter-out %/Pkg.System.pas,$(wildcard userland/commands/pkg/*.pas)) \
	$(filter-out %/Archive.Contents.pas,$(wildcard userland/lib/archive/*.pas)) \
	$(filter-out %/Compression.Contents.pas,$(wildcard userland/lib/compression/*.pas)) \
	$(filter-out %/Crypto.Contents.pas,$(wildcard userland/lib/cryptography/*.pas))

.PHONY: pkg-test

$(PKG_TEST_FIXTURES)/manifest.txt: tools/PkgTest/make-fixtures.py tools/PortsTest/test_dependencies.py \
		$(wildcard scripts/portstool/*.py)
	python3 -I $< $(PKG_TEST_FIXTURES)

$(PKG_TEST): $(PKG_TEST_SOURCES)
	@mkdir -p $(PKG_TEST_UNITS)
	fpc -Mobjfpc -O2 -vew -Futools/PkgTest -Futools/CryptoTest -Fuuserland/commands/pkg -Fuuserland/lib/archive \
		-Fuuserland/lib/compression -Fuuserland/lib/cryptography -Fushared -Fishared -FU$(PKG_TEST_UNITS) \
		-o$@ tools/PkgTest/PkgTest.pas

pkg-test: $(PKG_TEST) $(PKG_TEST_FIXTURES)/manifest.txt
	@$(PKG_TEST) $(PKG_TEST_FIXTURES) build/tools/pkg-work > build/tools/pkg-test.out || \
		{ grep FAIL build/tools/pkg-test.out; echo "PKG TEST FAILED (build/tools/pkg-test.out)"; exit 1; }
	@echo "PKG TEST PASSED: $$(tail -n 1 build/tools/pkg-test.out | cut -d ' ' -f 3-)"

# The ports tool's host tests (Python unittest: TOML and the schema,
# licences, versions, dependencies, patches, packages, manifests,
# repositories and signatures) and pkg's (tools/PkgTest, the package
# manager's plain units on the host, reading what the Python side wrote).
ports-test:
	@mkdir -p build/tools
	@python3 -I tools/PortsTest/run.py > build/tools/ports-test.out 2>&1 || \
		{ cat build/tools/ports-test.out; echo "PORTS TEST FAILED (build/tools/ports-test.out)"; exit 1; }
	@echo "PORTS TEST PASSED: $$(tail -n 1 build/tools/ports-test.out)"
