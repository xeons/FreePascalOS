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

# Userland build, included by the top level Makefile.
#
# Everything is position independent (-Cg) and linked with GNU ld:
#
#   lib<name>.so   ld -shared over the object files of a library's units:
#                  libsystem <- libcryptography <- libcoreutils <- programs
#                  libsystem <- libaudio (for the sound programs)
#                  libsystem <- libdrawing <- libfont (for graphical programs)
#                  libsystem <- libdrawing, libcompression <- libimage (image files)
#                  libsystem <- libconfiguration (settings, per user and system)
#                  libsystem <- libdrawing <- libfont, libconfiguration <- libwindowing
#                  (programs with windows)
#                  libsystem <- libcryptography <- libtls (TLS 1.3 client; wget)
#                  libsystem <- libcompression (deflate, zlib, gzip)
#                  libwindowing <- libcontrols (controls and dialogs)
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

# The compiler targets Linux for its ELF output and calling convention;
# UNIX and LINUX are undefined so no code takes Linux specific paths.
# -OoNOSTACKFRAME: every procedure keeps a frame (the RBP chain), which
# -O2 would leave out, so that the runtime can find the calling code:
# the addresses after a runtime error, and where a block was freed in a
# heap check report.
USER_FRAME_FLAGS := -OoNOSTACKFRAME
USER_FLAGS := $(COMMON_FLAGS) $(USER_FRAME_FLAGS) -Tlinux -Cg -Cn -uUNIX -uLINUX -Fishared

# The user runtime library is the Free Pascal RTL: the FreePascalOS parts
# in rtl/fpc, everything generic from the compiler's source tree.
FPC_SOURCE ?= /usr/lib/fpc/src
FPC_RTL_SOURCE := $(FPC_SOURCE)/rtl
FPC_PACKAGE_SOURCE := $(FPC_SOURCE)/packages
# Upstream sources warn a lot; only errors are shown for them.
USER_RTL_FLAGS := -n -O2 $(USER_FRAME_FLAGS) -Si -ve -Tlinux -Cg -Cn -uUNIX -uLINUX \
	-Firtl/fpc -Fishared -Fi$(FPC_RTL_SOURCE) -Fi$(FPC_RTL_SOURCE)/inc -Fi$(FPC_RTL_SOURCE)/x86_64 \
	-Fi$(FPC_RTL_SOURCE)/objpas -Fi$(FPC_RTL_SOURCE)/objpas/sysutils -Fi$(FPC_RTL_SOURCE)/objpas/classes \
	-Fi$(FPC_PACKAGE_SOURCE)/rtl-objpas/src/inc -Fi$(FPC_PACKAGE_SOURCE)/rtl-objpas/src/common \
	-Furtl/fpc -Fu$(FPC_RTL_SOURCE)/objpas -Fu$(FPC_RTL_SOURCE)/inc \
	-Fu$(FPC_PACKAGE_SOURCE)/rtl-objpas/src/inc -Fu$(FPC_PACKAGE_SOURCE)/rtl-objpas/src/common \
	-Fu$(FPC_PACKAGE_SOURCE)/fcl-base/src -Fu$(FPC_PACKAGE_SOURCE)/rtl-unicode/src/inc
USER_LINK_FLAGS := --hash-style=sysv -z max-page-size=4096 -z noexecstack
# Libraries bind references to their own symbols when they are linked.
USER_LIBRARY_LINK_FLAGS := $(USER_LINK_FLAGS) -Bsymbolic

SYSTEM_LIBRARY_OBJECTS := $(USER_BUILD_DIRECTORY)/system
CRYPTO_LIBRARY_OBJECTS := $(USER_BUILD_DIRECTORY)/cryptography
CORE_LIBRARY_OBJECTS := $(USER_BUILD_DIRECTORY)/coreutils
AUDIO_LIBRARY_OBJECTS := $(USER_BUILD_DIRECTORY)/audio
DRAWING_LIBRARY_OBJECTS := $(USER_BUILD_DIRECTORY)/drawing
FONT_LIBRARY_OBJECTS := $(USER_BUILD_DIRECTORY)/font
WINDOWING_LIBRARY_OBJECTS := $(USER_BUILD_DIRECTORY)/windowing
CONTROLS_LIBRARY_OBJECTS := $(USER_BUILD_DIRECTORY)/controls
CONFIGURATION_LIBRARY_OBJECTS := $(USER_BUILD_DIRECTORY)/configuration
TLS_LIBRARY_OBJECTS := $(USER_BUILD_DIRECTORY)/tls
IMAGE_LIBRARY_OBJECTS := $(USER_BUILD_DIRECTORY)/image
COMPRESSION_LIBRARY_OBJECTS := $(USER_BUILD_DIRECTORY)/compression

SYSTEM_LIBRARY := $(USER_LIBRARY_OUTPUT)/libsystem.so
CRYPTO_LIBRARY := $(USER_LIBRARY_OUTPUT)/libcryptography.so
CORE_LIBRARY := $(USER_LIBRARY_OUTPUT)/libcoreutils.so
AUDIO_LIBRARY := $(USER_LIBRARY_OUTPUT)/libaudio.so
DRAWING_LIBRARY := $(USER_LIBRARY_OUTPUT)/libdrawing.so
FONT_LIBRARY := $(USER_LIBRARY_OUTPUT)/libfont.so
WINDOWING_LIBRARY := $(USER_LIBRARY_OUTPUT)/libwindowing.so
CONTROLS_LIBRARY := $(USER_LIBRARY_OUTPUT)/libcontrols.so
CONFIGURATION_LIBRARY := $(USER_LIBRARY_OUTPUT)/libconfiguration.so
TLS_LIBRARY := $(USER_LIBRARY_OUTPUT)/libtls.so
IMAGE_LIBRARY := $(USER_LIBRARY_OUTPUT)/libimage.so
COMPRESSION_LIBRARY := $(USER_LIBRARY_OUTPUT)/libcompression.so
PLUGIN_LIBRARY := $(USER_LIBRARY_OUTPUT)/libplugin.so
TLSTEST_LIBRARY := $(USER_LIBRARY_OUTPUT)/libtlstest.so

# Every userland/bin/<name>.pas becomes /bin/<name>. A program made of
# several units keeps the others in userland/<name>/.
USER_PROGRAM_SOURCES := $(wildcard userland/bin/*.pas)
USER_PROGRAMS := $(patsubst userland/bin/%.pas,$(USER_PROGRAM_OUTPUT)/%,$(USER_PROGRAM_SOURCES))

# The system's fonts (/lib/fonts/terminus): Terminus in the sizes it comes
# in, regular and bold, unpacked; with its licence (SIL Open Font
# License), which has to go with it.
TERMINUS_DIRECTORY ?= $(dir $(FONT_SOURCE))
TERMINUS_LICENSE ?= /usr/share/licenses/terminus-font/LICENSE
TERMINUS_SIZES := 12 14 16 18 20 22 24 28 32
SYSTEM_FONT_DIRECTORY := $(USER_BUILD_DIRECTORY)/fonts/terminus
SYSTEM_FONTS_STAMP := $(SYSTEM_FONT_DIRECTORY)/.unpacked

# The interface's proportional font (/lib/fonts/dejavu-sans): DejaVu Sans,
# regular and bold, rendered on the host into coverage fonts at every
# pixel size from 9 to 40 (tools/RenderFont, with Python's Pillow); with
# its licence (Bitstream Vera and DejaVu's changes), which has to go with
# it.
DEJAVU_SANS_FONT ?= /usr/share/fonts/TTF/DejaVuSans.ttf
DEJAVU_SANS_BOLD_FONT ?= /usr/share/fonts/TTF/DejaVuSans-Bold.ttf
DEJAVU_LICENSE ?= /usr/share/licenses/ttf-dejavu/LICENSE
DEJAVU_SANS_SIZES := 9-40
DEJAVU_SANS_DIRECTORY := $(USER_BUILD_DIRECTORY)/fonts/dejavu-sans
DEJAVU_SANS_STAMP := $(DEJAVU_SANS_DIRECTORY)/.rendered
FONT_RENDERER := tools/RenderFont/render-font.py



.PHONY: userland system-disk

.SECONDEXPANSION:

userland: $(SYSTEM_LIBRARY) $(CRYPTO_LIBRARY) $(CORE_LIBRARY) $(AUDIO_LIBRARY) $(DRAWING_LIBRARY) $(FONT_LIBRARY) $(WINDOWING_LIBRARY) $(CONTROLS_LIBRARY) \
	$(CONFIGURATION_LIBRARY) $(TLS_LIBRARY) $(IMAGE_LIBRARY) $(COMPRESSION_LIBRARY) $(PLUGIN_LIBRARY) $(TLSTEST_LIBRARY) $(USER_PROGRAMS) $(SYSTEM_FONTS_STAMP) \
	$(DEJAVU_SANS_STAMP)

$(RTL_USER_DIRECTORY)/si_prc.ppu: $(wildcard rtl/fpc/*) shared/Abi.SystemCalls.inc shared/Abi.Networking.inc \
		shared/Abi.ErrorMessages.inc
	@test -f $(FPC_RTL_SOURCE)/inc/system.inc || \
		{ echo "The Free Pascal sources are needed in $(FPC_SOURCE) (set FPC_SOURCE)"; exit 1; }
	@rm -rf $(RTL_USER_DIRECTORY)
	@mkdir -p $(RTL_USER_DIRECTORY)
	$(FPC) $(USER_RTL_FLAGS) -Us -FU$(RTL_USER_DIRECTORY) rtl/fpc/system.pp
	$(FPC) $(USER_RTL_FLAGS) -Fu$(RTL_USER_DIRECTORY) -FU$(RTL_USER_DIRECTORY) rtl/fpc/buildrtl.pp
	$(FPC) $(USER_RTL_FLAGS) -Fu$(RTL_USER_DIRECTORY) -FU$(RTL_USER_DIRECTORY) rtl/fpc/si_prc.pas
	@rm -f $(RTL_USER_DIRECTORY)/buildrtl.o

# libsystem: the runtime library (System, SysUtils, Classes, ...), the
# shared runtime units and Sys.*.
$(SYSTEM_LIBRARY): $(RTL_USER_DIRECTORY)/si_prc.ppu $(wildcard userland/lib/system/*.pas) \
		shared/Runtime.Memory.pas shared/Runtime.Text.pas shared/Runtime.Time.pas shared/Abi.SystemCalls.pas
	@rm -rf $(SYSTEM_LIBRARY_OBJECTS)
	@mkdir -p $(SYSTEM_LIBRARY_OBJECTS) $(USER_LIBRARY_OUTPUT)
	$(FPC) $(USER_FLAGS) -Fu$(RTL_USER_DIRECTORY) -Fushared -Fuuserland/lib/system \
		-FU$(SYSTEM_LIBRARY_OBJECTS) userland/lib/system/Sys.Contents.pas
	$(LD) -shared $(USER_LIBRARY_LINK_FLAGS) -soname libsystem.so -o $@ \
		$(SYSTEM_LIBRARY_OBJECTS)/*.o $(filter-out %/si_prc.o,$(wildcard $(RTL_USER_DIRECTORY)/*.o))

# libcryptography: hashes, checksums, ciphers and random numbers.
$(CRYPTO_LIBRARY): $(SYSTEM_LIBRARY) $(wildcard userland/lib/cryptography/*.pas)
	@rm -rf $(CRYPTO_LIBRARY_OBJECTS)
	@mkdir -p $(CRYPTO_LIBRARY_OBJECTS)
	$(FPC) $(USER_FLAGS) -Fu$(RTL_USER_DIRECTORY) -Fu$(SYSTEM_LIBRARY_OBJECTS) -Fuuserland/lib/cryptography \
		-FU$(CRYPTO_LIBRARY_OBJECTS) userland/lib/cryptography/Crypto.Contents.pas
	$(LD) -shared $(USER_LIBRARY_LINK_FLAGS) -soname libcryptography.so -o $@ \
		$(CRYPTO_LIBRARY_OBJECTS)/*.o -L$(USER_LIBRARY_OUTPUT) -lsystem

# libcoreutils: helpers shared by the command line tools.
$(CORE_LIBRARY): $(CRYPTO_LIBRARY) $(wildcard userland/lib/coreutils/*.pas)
	@rm -rf $(CORE_LIBRARY_OBJECTS)
	@mkdir -p $(CORE_LIBRARY_OBJECTS)
	$(FPC) $(USER_FLAGS) -Fu$(RTL_USER_DIRECTORY) -Fu$(SYSTEM_LIBRARY_OBJECTS) -Fu$(CRYPTO_LIBRARY_OBJECTS) \
		-Fuuserland/lib/coreutils -FU$(CORE_LIBRARY_OBJECTS) userland/lib/coreutils/Util.Contents.pas
	$(LD) -shared $(USER_LIBRARY_LINK_FLAGS) -soname libcoreutils.so -o $@ \
		$(CORE_LIBRARY_OBJECTS)/*.o -L$(USER_LIBRARY_OUTPUT) -lcryptography -lsystem

# libaudio: the sound device, WAV files and tone synthesis.
$(AUDIO_LIBRARY): $(SYSTEM_LIBRARY) $(wildcard userland/lib/audio/*.pas)
	@rm -rf $(AUDIO_LIBRARY_OBJECTS)
	@mkdir -p $(AUDIO_LIBRARY_OBJECTS)
	$(FPC) $(USER_FLAGS) -Fu$(RTL_USER_DIRECTORY) -Fu$(SYSTEM_LIBRARY_OBJECTS) -Fuuserland/lib/audio \
		-FU$(AUDIO_LIBRARY_OBJECTS) userland/lib/audio/Audio.Contents.pas
	$(LD) -shared $(USER_LIBRARY_LINK_FLAGS) -soname libaudio.so -o $@ \
		$(AUDIO_LIBRARY_OBJECTS)/*.o -L$(USER_LIBRARY_OUTPUT) -lsystem

# libdrawing: surfaces, clipping regions and drawing on them.
$(DRAWING_LIBRARY): $(SYSTEM_LIBRARY) $(wildcard userland/lib/drawing/*.pas)
	@rm -rf $(DRAWING_LIBRARY_OBJECTS)
	@mkdir -p $(DRAWING_LIBRARY_OBJECTS)
	$(FPC) $(USER_FLAGS) -Fu$(RTL_USER_DIRECTORY) -Fuuserland/lib/drawing \
		-FU$(DRAWING_LIBRARY_OBJECTS) userland/lib/drawing/Drawing.Contents.pas
	$(LD) -shared $(USER_LIBRARY_LINK_FLAGS) -soname libdrawing.so -o $@ \
		$(DRAWING_LIBRARY_OBJECTS)/*.o -L$(USER_LIBRARY_OUTPUT) -lsystem

# libimage: images (pixels, frames, colour profile, metadata) and the
# formats they are read from and written to.
$(IMAGE_LIBRARY): $(DRAWING_LIBRARY) $(COMPRESSION_LIBRARY) $(wildcard userland/lib/image/*.pas)
	@rm -rf $(IMAGE_LIBRARY_OBJECTS)
	@mkdir -p $(IMAGE_LIBRARY_OBJECTS)
	$(FPC) $(USER_FLAGS) -Fu$(RTL_USER_DIRECTORY) -Fu$(SYSTEM_LIBRARY_OBJECTS) -Fu$(DRAWING_LIBRARY_OBJECTS) \
		-Fu$(COMPRESSION_LIBRARY_OBJECTS) -Fuuserland/lib/image -FU$(IMAGE_LIBRARY_OBJECTS) \
		userland/lib/image/Image.Contents.pas
	$(LD) -shared $(USER_LIBRARY_LINK_FLAGS) -soname libimage.so -o $@ \
		$(IMAGE_LIBRARY_OBJECTS)/*.o -L$(USER_LIBRARY_OUTPUT) -lcompression -ldrawing -lsystem

# libfont: bitmap fonts, picked by point size and DPI; measuring and
# drawing UTF-8 text.
$(FONT_LIBRARY): $(DRAWING_LIBRARY) $(wildcard userland/lib/font/*.pas)
	@rm -rf $(FONT_LIBRARY_OBJECTS)
	@mkdir -p $(FONT_LIBRARY_OBJECTS)
	$(FPC) $(USER_FLAGS) -Fu$(RTL_USER_DIRECTORY) -Fu$(SYSTEM_LIBRARY_OBJECTS) -Fu$(DRAWING_LIBRARY_OBJECTS) \
		-Fuuserland/lib/font -FU$(FONT_LIBRARY_OBJECTS) userland/lib/font/Font.Contents.pas
	$(LD) -shared $(USER_LIBRARY_LINK_FLAGS) -soname libfont.so -o $@ \
		$(FONT_LIBRARY_OBJECTS)/*.o -L$(USER_LIBRARY_OUTPUT) -ldrawing -lsystem

# libconfiguration: settings, the user's over the system's, in files.
$(CONFIGURATION_LIBRARY): $(SYSTEM_LIBRARY) $(wildcard userland/lib/configuration/*.pas)
	@rm -rf $(CONFIGURATION_LIBRARY_OBJECTS)
	@mkdir -p $(CONFIGURATION_LIBRARY_OBJECTS)
	$(FPC) $(USER_FLAGS) -Fu$(RTL_USER_DIRECTORY) -Fu$(SYSTEM_LIBRARY_OBJECTS) -Fuuserland/lib/configuration \
		-FU$(CONFIGURATION_LIBRARY_OBJECTS) userland/lib/configuration/Configuration.Contents.pas
	$(LD) -shared $(USER_LIBRARY_LINK_FLAGS) -soname libconfiguration.so -o $@ \
		$(CONFIGURATION_LIBRARY_OBJECTS)/*.o -L$(USER_LIBRARY_OUTPUT) -lsystem

# libtls: a TLS 1.3 client with X.509 certificate checking.
$(TLS_LIBRARY): $(CRYPTO_LIBRARY) $(wildcard userland/lib/tls/*.pas)
	@rm -rf $(TLS_LIBRARY_OBJECTS)
	@mkdir -p $(TLS_LIBRARY_OBJECTS)
	$(FPC) $(USER_FLAGS) -Fu$(RTL_USER_DIRECTORY) -Fu$(SYSTEM_LIBRARY_OBJECTS) -Fu$(CRYPTO_LIBRARY_OBJECTS) \
		-Fuuserland/lib/tls -FU$(TLS_LIBRARY_OBJECTS) userland/lib/tls/Tls.Contents.pas
	$(LD) -shared $(USER_LIBRARY_LINK_FLAGS) -soname libtls.so -o $@ \
		$(TLS_LIBRARY_OBJECTS)/*.o -L$(USER_LIBRARY_OUTPUT) -lcryptography -lsystem

# libcompression: deflate compression and decompression, the zlib and
# gzip wrappers and their checksums.
$(COMPRESSION_LIBRARY): $(SYSTEM_LIBRARY) $(wildcard userland/lib/compression/*.pas)
	@rm -rf $(COMPRESSION_LIBRARY_OBJECTS)
	@mkdir -p $(COMPRESSION_LIBRARY_OBJECTS)
	$(FPC) $(USER_FLAGS) -Fu$(RTL_USER_DIRECTORY) -Fu$(SYSTEM_LIBRARY_OBJECTS) -Fuuserland/lib/compression \
		-FU$(COMPRESSION_LIBRARY_OBJECTS) userland/lib/compression/Compression.Contents.pas
	$(LD) -shared $(USER_LIBRARY_LINK_FLAGS) -soname libcompression.so -o $@ \
		$(COMPRESSION_LIBRARY_OBJECTS)/*.o -L$(USER_LIBRARY_OUTPUT) -lsystem

# libwindowing: the display server's protocol and windows for programs.
$(WINDOWING_LIBRARY): $(FONT_LIBRARY) $(CONFIGURATION_LIBRARY) $(wildcard userland/lib/windowing/*.pas)
	@rm -rf $(WINDOWING_LIBRARY_OBJECTS)
	@mkdir -p $(WINDOWING_LIBRARY_OBJECTS)
	$(FPC) $(USER_FLAGS) -Fu$(RTL_USER_DIRECTORY) -Fu$(SYSTEM_LIBRARY_OBJECTS) -Fu$(DRAWING_LIBRARY_OBJECTS) \
		-Fu$(FONT_LIBRARY_OBJECTS) -Fu$(CONFIGURATION_LIBRARY_OBJECTS) -Fuuserland/lib/windowing \
		-FU$(WINDOWING_LIBRARY_OBJECTS) userland/lib/windowing/Windowing.Contents.pas
	$(LD) -shared $(USER_LIBRARY_LINK_FLAGS) -soname libwindowing.so -o $@ \
		$(WINDOWING_LIBRARY_OBJECTS)/*.o -L$(USER_LIBRARY_OUTPUT) -lconfiguration -lfont -ldrawing -lsystem

# libcontrols: controls, control windows and dialogs.
$(CONTROLS_LIBRARY): $(WINDOWING_LIBRARY) $(wildcard userland/lib/controls/*.pas)
	@rm -rf $(CONTROLS_LIBRARY_OBJECTS)
	@mkdir -p $(CONTROLS_LIBRARY_OBJECTS)
	$(FPC) $(USER_FLAGS) -Fu$(RTL_USER_DIRECTORY) -Fu$(SYSTEM_LIBRARY_OBJECTS) -Fu$(DRAWING_LIBRARY_OBJECTS) \
		-Fu$(FONT_LIBRARY_OBJECTS) -Fu$(CONFIGURATION_LIBRARY_OBJECTS) -Fu$(WINDOWING_LIBRARY_OBJECTS) \
		-Fuuserland/lib/controls -FU$(CONTROLS_LIBRARY_OBJECTS) userland/lib/controls/Controls.Contents.pas
	$(LD) -shared $(USER_LIBRARY_LINK_FLAGS) -soname libcontrols.so -o $@ \
		$(CONTROLS_LIBRARY_OBJECTS)/*.o -L$(USER_LIBRARY_OUTPUT) -lwindowing -lconfiguration -lfont -ldrawing -lsystem

$(SYSTEM_FONTS_STAMP):
	@test -f $(TERMINUS_LICENSE) || { echo "The Terminus licence is needed in $(TERMINUS_LICENSE) (set TERMINUS_LICENSE)"; exit 1; }
	@mkdir -p $(SYSTEM_FONT_DIRECTORY)
	@for size in $(TERMINUS_SIZES); do for weight in n b; do \
		source=$(TERMINUS_DIRECTORY)ter-v$$size$$weight.psf.gz; \
		if [ -f $$source ]; then zcat $$source > $(SYSTEM_FONT_DIRECTORY)/ter-v$$size$$weight.psf; fi; \
	done; done
	cp $(TERMINUS_LICENSE) $(SYSTEM_FONT_DIRECTORY)/LICENSE
	@touch $@

$(DEJAVU_SANS_STAMP): $(FONT_RENDERER)
	@python3 -c 'import PIL' 2>/dev/null || { echo "Python 3 with Pillow (PIL) is needed to render the interface font (python-pillow)"; exit 1; }
	@for font in $(DEJAVU_SANS_FONT) $(DEJAVU_SANS_BOLD_FONT) $(DEJAVU_LICENSE); do \
		test -f $$font || { echo "DejaVu Sans is needed in $$font (set DEJAVU_SANS_FONT, DEJAVU_SANS_BOLD_FONT, DEJAVU_LICENSE)"; exit 1; }; \
	done
	@rm -rf $(DEJAVU_SANS_DIRECTORY)
	python3 $(FONT_RENDERER) --font $(DEJAVU_SANS_FONT) --sizes $(DEJAVU_SANS_SIZES) --name dejavu-sans \
		--output $(DEJAVU_SANS_DIRECTORY)
	python3 $(FONT_RENDERER) --font $(DEJAVU_SANS_BOLD_FONT) --bold --sizes $(DEJAVU_SANS_SIZES) --name dejavu-sans-bold \
		--output $(DEJAVU_SANS_DIRECTORY)
	cp $(DEJAVU_LICENSE) $(DEJAVU_SANS_DIRECTORY)/LICENSE
	@touch $@

# A library loaded at run time by the tests.
$(PLUGIN_LIBRARY): $(SYSTEM_LIBRARY) userland/lib/plugin/Plugin.pas
	@rm -rf $(USER_BUILD_DIRECTORY)/plugin
	@mkdir -p $(USER_BUILD_DIRECTORY)/plugin
	$(FPC) $(USER_FLAGS) -Fu$(RTL_USER_DIRECTORY) -Fu$(SYSTEM_LIBRARY_OBJECTS) \
		-FU$(USER_BUILD_DIRECTORY)/plugin userland/lib/plugin/Plugin.pas
	$(LD) -shared $(USER_LIBRARY_LINK_FLAGS) -soname libplugin.so -o $@ \
		$(USER_BUILD_DIRECTORY)/plugin/*.o -L$(USER_LIBRARY_OUTPUT) -lsystem

# A library in assembly with thread-local storage and initializers, which
# Free Pascal does not produce; used by threadtest.
$(TLSTEST_LIBRARY): $(SYSTEM_LIBRARY) userland/lib/tlstest/TlsTest.s
	@mkdir -p $(USER_BUILD_DIRECTORY)/tlstest
	as --64 -o $(USER_BUILD_DIRECTORY)/tlstest/TlsTest.o userland/lib/tlstest/TlsTest.s
	$(LD) -shared $(USER_LIBRARY_LINK_FLAGS) -soname libtlstest.so -o $@ \
		$(USER_BUILD_DIRECTORY)/tlstest/TlsTest.o -L$(USER_LIBRARY_OUTPUT) -lsystem

# Programs that need more libraries than the usual three.
$(USER_PROGRAM_OUTPUT)/threadtest: EXTRA_PROGRAM_LIBRARIES := -ltlstest
$(USER_PROGRAM_OUTPUT)/threadtest: $(TLSTEST_LIBRARY)
GRAPHICAL_PROGRAMS := $(addprefix $(USER_PROGRAM_OUTPUT)/,drawtest displayserver displayscale displaymode mousesettings keyboardsettings wintest ownertest controlsdemo controlstour dialogtour notepad files terminal sessionmanager taskmanager sysinfo)
$(GRAPHICAL_PROGRAMS): EXTRA_PROGRAM_LIBRARIES := -lcontrols -lwindowing -lconfiguration -lfont -ldrawing
$(GRAPHICAL_PROGRAMS): EXTRA_PROGRAM_UNITS := -Fu$(DRAWING_LIBRARY_OBJECTS) -Fu$(FONT_LIBRARY_OBJECTS) \
	-Fu$(CONFIGURATION_LIBRARY_OBJECTS) -Fu$(WINDOWING_LIBRARY_OBJECTS) -Fu$(CONTROLS_LIBRARY_OBJECTS)
$(GRAPHICAL_PROGRAMS): $(CONTROLS_LIBRARY)
# Graphical programs that set the sound outputs too.
GRAPHICAL_SOUND_PROGRAMS := $(addprefix $(USER_PROGRAM_OUTPUT)/,controlpanel desktop)
$(GRAPHICAL_SOUND_PROGRAMS): EXTRA_PROGRAM_LIBRARIES := -lcontrols -lwindowing -lconfiguration -lfont -ldrawing -laudio
$(GRAPHICAL_SOUND_PROGRAMS): EXTRA_PROGRAM_UNITS := -Fu$(DRAWING_LIBRARY_OBJECTS) -Fu$(FONT_LIBRARY_OBJECTS) \
	-Fu$(CONFIGURATION_LIBRARY_OBJECTS) -Fu$(WINDOWING_LIBRARY_OBJECTS) -Fu$(CONTROLS_LIBRARY_OBJECTS) \
	-Fu$(AUDIO_LIBRARY_OBJECTS)
$(GRAPHICAL_SOUND_PROGRAMS): $(CONTROLS_LIBRARY) $(AUDIO_LIBRARY)
# The network service reads its configuration from the settings.
SETTINGS_PROGRAMS := $(addprefix $(USER_PROGRAM_OUTPUT)/,settings settingstest network networktest)
$(SETTINGS_PROGRAMS): EXTRA_PROGRAM_LIBRARIES := -lconfiguration
$(SETTINGS_PROGRAMS): EXTRA_PROGRAM_UNITS := -Fu$(CONFIGURATION_LIBRARY_OBJECTS)
$(SETTINGS_PROGRAMS): $(CONFIGURATION_LIBRARY)
# wget speaks TLS through libtls.
TLS_PROGRAMS := $(addprefix $(USER_PROGRAM_OUTPUT)/,wget)
$(TLS_PROGRAMS): EXTRA_PROGRAM_LIBRARIES := -ltls
$(TLS_PROGRAMS): EXTRA_PROGRAM_UNITS := -Fu$(TLS_LIBRARY_OBJECTS)
$(TLS_PROGRAMS): $(TLS_LIBRARY)
# gzip compresses through libcompression.
COMPRESSION_PROGRAMS := $(addprefix $(USER_PROGRAM_OUTPUT)/,gzip)
$(COMPRESSION_PROGRAMS): EXTRA_PROGRAM_LIBRARIES := -lcompression
$(COMPRESSION_PROGRAMS): EXTRA_PROGRAM_UNITS := -Fu$(COMPRESSION_LIBRARY_OBJECTS)
$(COMPRESSION_PROGRAMS): $(COMPRESSION_LIBRARY)
SOUND_PROGRAMS := $(addprefix $(USER_PROGRAM_OUTPUT)/,tone play mixer voicetest effecttest record soundinfo)
# Programs that read image files.
IMAGE_PROGRAMS := $(addprefix $(USER_PROGRAM_OUTPUT)/,imageinfo)
$(IMAGE_PROGRAMS): EXTRA_PROGRAM_LIBRARIES := -limage -lcompression -ldrawing
$(IMAGE_PROGRAMS): EXTRA_PROGRAM_UNITS := -Fu$(DRAWING_LIBRARY_OBJECTS) -Fu$(COMPRESSION_LIBRARY_OBJECTS) \
	-Fu$(IMAGE_LIBRARY_OBJECTS)
$(IMAGE_PROGRAMS): $(IMAGE_LIBRARY)
# The system settings service keeps what it changes in the settings and
# sets the sound outputs.
SYSTEM_SETTINGS_PROGRAMS := $(addprefix $(USER_PROGRAM_OUTPUT)/,systemsettings)
$(SYSTEM_SETTINGS_PROGRAMS): EXTRA_PROGRAM_LIBRARIES := -laudio -lconfiguration
$(SYSTEM_SETTINGS_PROGRAMS): EXTRA_PROGRAM_UNITS := -Fu$(AUDIO_LIBRARY_OBJECTS) -Fu$(CONFIGURATION_LIBRARY_OBJECTS)
$(SYSTEM_SETTINGS_PROGRAMS): $(AUDIO_LIBRARY) $(CONFIGURATION_LIBRARY)
$(SOUND_PROGRAMS): EXTRA_PROGRAM_LIBRARIES := -laudio
$(SOUND_PROGRAMS): EXTRA_PROGRAM_UNITS := -Fu$(AUDIO_LIBRARY_OBJECTS)
$(SOUND_PROGRAMS): $(AUDIO_LIBRARY)

$(USER_PROGRAM_OUTPUT)/%: userland/bin/%.pas $(CORE_LIBRARY) $$(wildcard userland/$$*/*.pas)
	@rm -rf $(USER_BUILD_DIRECTORY)/programs/$*
	@mkdir -p $(USER_BUILD_DIRECTORY)/programs/$* $(USER_PROGRAM_OUTPUT)
	$(FPC) $(USER_FLAGS) -Fu$(RTL_USER_DIRECTORY) -Fu$(SYSTEM_LIBRARY_OBJECTS) -Fu$(CRYPTO_LIBRARY_OBJECTS) \
		-Fu$(CORE_LIBRARY_OBJECTS) $(EXTRA_PROGRAM_UNITS) -Fuuserland/$* \
		-FU$(USER_BUILD_DIRECTORY)/programs/$* -FE$(USER_BUILD_DIRECTORY)/programs/$* $<
	$(LD) -pie --no-dynamic-linker $(USER_LINK_FLAGS) -e _start -o $@ \
		$(USER_BUILD_DIRECTORY)/programs/$*/*.o $(RTL_USER_DIRECTORY)/si_prc.o \
		-L$(USER_LIBRARY_OUTPUT) $(EXTRA_PROGRAM_LIBRARIES) -lcoreutils -lcryptography -lsystem

# The system volume: an ext4 image labelled FPOSROOT.
system-disk: $(SYSTEM_DISK)

$(SYSTEM_DISK): userland scripts/make-system-disk.sh $(wildcard userland/etc/*) $(wildcard userland/etc/*/*) \
		$(wildcard userland/etc/*/*/*) \
		$(wildcard userland/pointers/*)
	scripts/make-system-disk.sh $(USER_BUILD_DIRECTORY) $@
