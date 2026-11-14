# Userland build, included by the top level Makefile.
#
# Everything is position independent (-Cg) and linked with GNU ld:
#
#   lib<name>.so   ld -shared over the object files of a library's units
#   programs       ld -pie against the libraries, with si_prc providing
#                  the entry point; symbols are bound by the kernel's
#                  loader when the program starts
#
# --hash-style=sysv: the kernel loader looks symbols up through DT_HASH.

USER_BUILD_DIRECTORY := $(BUILD_DIRECTORY)/user
RTL_USER_DIRECTORY := $(BUILD_DIRECTORY)/rtl-user
USER_LIBRARY_OUTPUT := $(USER_BUILD_DIRECTORY)/lib
USER_PROGRAM_OUTPUT := $(USER_BUILD_DIRECTORY)/bin
USER_ROOT_DIRECTORY := $(USER_BUILD_DIRECTORY)/root

USER_FLAGS := $(COMMON_FLAGS) -Tlinux -Cg -Cn
USER_LINK_FLAGS := --hash-style=sysv -z max-page-size=4096 -z noexecstack

SYSTEM_LIBRARY_OBJECTS := $(USER_BUILD_DIRECTORY)/system
CORE_LIBRARY_OBJECTS := $(USER_BUILD_DIRECTORY)/coreutils

SYSTEM_LIBRARY := $(USER_LIBRARY_OUTPUT)/libsystem.so
CORE_LIBRARY := $(USER_LIBRARY_OUTPUT)/libcoreutils.so
PLUGIN_LIBRARY := $(USER_LIBRARY_OUTPUT)/libplugin.so

# Every userland/bin/<name>.pas becomes /bin/<name>. A program made of
# several units keeps the others in userland/<name>/.
USER_PROGRAM_SOURCES := $(wildcard userland/bin/*.pas)
USER_PROGRAMS := $(patsubst userland/bin/%.pas,$(USER_PROGRAM_OUTPUT)/%,$(USER_PROGRAM_SOURCES))



.PHONY: userland system-disk

.SECONDEXPANSION:

userland: $(SYSTEM_LIBRARY) $(CORE_LIBRARY) $(PLUGIN_LIBRARY) $(USER_PROGRAMS)

$(RTL_USER_DIRECTORY)/si_prc.ppu: $(wildcard rtl/common/*) rtl/user/system.pas rtl/user/startup/si_prc.pas
	$(call build-rtl,$(RTL_USER_DIRECTORY),rtl/user,-Tlinux -Cg -Cn)
	$(FPC) $(USER_FLAGS) -Fu$(RTL_USER_DIRECTORY) -FU$(RTL_USER_DIRECTORY) rtl/user/startup/si_prc.pas

# libsystem: the user System unit, the shared runtime units and Sys.*.
$(SYSTEM_LIBRARY): $(RTL_USER_DIRECTORY)/si_prc.ppu $(wildcard userland/lib/system/*.pas) \
		shared/Runtime.Memory.pas shared/Runtime.Text.pas shared/Runtime.Time.pas shared/Abi.SystemCalls.pas
	@rm -rf $(SYSTEM_LIBRARY_OBJECTS)
	@mkdir -p $(SYSTEM_LIBRARY_OBJECTS) $(USER_LIBRARY_OUTPUT)
	$(FPC) $(USER_FLAGS) -Fu$(RTL_USER_DIRECTORY) -Fushared -Fuuserland/lib/system \
		-FU$(SYSTEM_LIBRARY_OBJECTS) userland/lib/system/Sys.Contents.pas
	$(LD) -shared $(USER_LINK_FLAGS) -soname libsystem.so -o $@ \
		$(SYSTEM_LIBRARY_OBJECTS)/*.o $(RTL_USER_DIRECTORY)/system.o

# libcoreutils: helpers shared by the command line tools.
$(CORE_LIBRARY): $(SYSTEM_LIBRARY) $(wildcard userland/lib/coreutils/*.pas)
	@rm -rf $(CORE_LIBRARY_OBJECTS)
	@mkdir -p $(CORE_LIBRARY_OBJECTS)
	$(FPC) $(USER_FLAGS) -Fu$(RTL_USER_DIRECTORY) -Fu$(SYSTEM_LIBRARY_OBJECTS) -Fuuserland/lib/coreutils \
		-FU$(CORE_LIBRARY_OBJECTS) userland/lib/coreutils/Util.Contents.pas
	$(LD) -shared $(USER_LINK_FLAGS) -soname libcoreutils.so -o $@ \
		$(CORE_LIBRARY_OBJECTS)/*.o -L$(USER_LIBRARY_OUTPUT) -lsystem

# A library loaded at run time by the tests.
$(PLUGIN_LIBRARY): $(SYSTEM_LIBRARY) userland/lib/plugin/Plugin.pas
	@rm -rf $(USER_BUILD_DIRECTORY)/plugin
	@mkdir -p $(USER_BUILD_DIRECTORY)/plugin
	$(FPC) $(USER_FLAGS) -Fu$(RTL_USER_DIRECTORY) -Fu$(SYSTEM_LIBRARY_OBJECTS) \
		-FU$(USER_BUILD_DIRECTORY)/plugin userland/lib/plugin/Plugin.pas
	$(LD) -shared $(USER_LINK_FLAGS) -soname libplugin.so -o $@ \
		$(USER_BUILD_DIRECTORY)/plugin/*.o -L$(USER_LIBRARY_OUTPUT) -lsystem

$(USER_PROGRAM_OUTPUT)/%: userland/bin/%.pas $(CORE_LIBRARY) $$(wildcard userland/$$*/*.pas)
	@rm -rf $(USER_BUILD_DIRECTORY)/programs/$*
	@mkdir -p $(USER_BUILD_DIRECTORY)/programs/$* $(USER_PROGRAM_OUTPUT)
	$(FPC) $(USER_FLAGS) -Fu$(RTL_USER_DIRECTORY) -Fu$(SYSTEM_LIBRARY_OBJECTS) -Fu$(CORE_LIBRARY_OBJECTS) \
		-Fuuserland/$* \
		-FU$(USER_BUILD_DIRECTORY)/programs/$* -FE$(USER_BUILD_DIRECTORY)/programs/$* $<
	$(LD) -pie --no-dynamic-linker $(USER_LINK_FLAGS) -e _start -o $@ \
		$(USER_BUILD_DIRECTORY)/programs/$*/*.o $(RTL_USER_DIRECTORY)/si_prc.o \
		-L$(USER_LIBRARY_OUTPUT) -lcoreutils -lsystem

# The system volume: an ext4 image labelled FPOSROOT.
system-disk: $(SYSTEM_DISK)

$(SYSTEM_DISK): userland scripts/make-system-disk.sh $(wildcard userland/etc/*)
	scripts/make-system-disk.sh $(USER_BUILD_DIRECTORY) $@
