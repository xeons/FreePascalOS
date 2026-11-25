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
#                  libsystem <- libcryptography <- libtls (TLS 1.3 and 1.2 client; wget)
#                  libsystem <- libcompression (deflate, zlib, gzip; brotli, zstd)
#                  libcompression <- libarchive (zip, tar, tar.gz; the file manager)
#                  libsystem <- libcryptography <- libssh (SSH; sshd, ssh)
#                  libtls, libcompression <- libhttp (URLs, HTTP/1.1 and HTTP/2; wget)
#                  libtls, libhttp <- libquic (QUIC, QPACK, HTTP/3, and libhttp's
#                  HTTP/3 connections; h3get, wget)
#                  libjavascript, libhttp, libcss, libfont, libdrawing, libimage, libsvg <- libweb (the browser
#                  engine; htmldump, webrender)
#                  libsystem <- libjavascript (the ECMAScript engine; js)
#                  libwindowing, libimage <- libcontrols (controls and dialogs)
#                  libsystem <- libcss (the style engine; cssdump, libweb)
#                  libcss, libfont, libimage <- libsvg (SVG documents and images;
#                  libweb)
#                  libweb, libcontrols <- libwebview (the web view control; browser)
#   programs       ld -pie against the libraries, with si_prc providing
#                  the entry point; symbols are bound by the kernel's
#                  loader when the program starts
#
# --hash-style=sysv: the kernel loader looks symbols up through DT_HASH.
#
# With ARCH=arm64 the same rules build for AArch64: the cross compiler
# (TARGET_FPC), GNU ld for AArch64 (LD) and the generic RTL's
# rtl/aarch64; libtlstest.so comes from TlsTest.arm64.s.

USER_BUILD_DIRECTORY := $(BUILD_DIRECTORY)/user
RTL_USER_DIRECTORY := $(BUILD_DIRECTORY)/rtl-user
USER_LIBRARY_OUTPUT := $(USER_BUILD_DIRECTORY)/lib
USER_PROGRAM_OUTPUT := $(USER_BUILD_DIRECTORY)/bin
USER_ROOT_DIRECTORY := $(USER_BUILD_DIRECTORY)/root

# The userland is compiled for FreePascalOS (-Tfreepascalos, the target
# toolchain/fpc adds to the compiler): System V calling convention, ELF,
# FREEPASCALOS defined and neither UNIX nor LINUX.
# -OoNOSTACKFRAME: every procedure keeps a frame (the RBP chain), which
# -O2 would leave out, so that the runtime can find the calling code:
# the addresses after a runtime error, and where a block was freed in a
# heap check report.
USER_FRAME_FLAGS := -OoNOSTACKFRAME
# AArch64 processors set FPSR's flags instead of trapping floating point
# exceptions: -CE (CHECKFPUEXCEPTIONS) makes the compiler check FPSR
# after each floating point operation in the libraries and programs and
# call the runtime's FPC_THROWFPUEXCEPTION (rtl/aarch64), which raises
# the unmasked ones, as the x86-64 processor's traps do
# (SetExceptionMask masks them). The compiler expects the call to keep
# every floating point register, which the RTL's Pascal routine does not
# promise: it is renamed in system.o, and rtl/fpc/FloatCheck.aarch64.s
# keeps the registers around it. The runtime library itself is built
# without -CE (its own floating point code expects no such calls).
USER_FLOAT_CHECK_FLAGS :=
ifeq ($(ARCH),arm64)
  USER_FLOAT_CHECK_FLAGS := -CE
endif
USER_FLAGS := $(COMMON_FLAGS) $(USER_FRAME_FLAGS) $(USER_FLOAT_CHECK_FLAGS) -Tfreepascalos -Cg -Cn -Fishared

# The user runtime library is the Free Pascal RTL: the FreePascalOS parts
# in rtl/fpc, everything generic from the compiler's source tree.
FPC_SOURCE ?= /usr/lib/fpc/src
FPC_RTL_SOURCE := $(FPC_SOURCE)/rtl
FPC_PACKAGE_SOURCE := $(FPC_SOURCE)/packages
# The processor specific part of the generic RTL (rtl/x86_64, rtl/aarch64).
ifeq ($(ARCH),arm64)
  FPC_RTL_CPU := aarch64
else
  FPC_RTL_CPU := x86_64
endif
# Upstream sources warn a lot; only errors are shown for them.
USER_RTL_FLAGS := -n -O2 $(USER_FRAME_FLAGS) -Si -ve -Tfreepascalos -Cg -Cn \
	-Firtl/fpc -Fishared -Fi$(FPC_RTL_SOURCE) -Fi$(FPC_RTL_SOURCE)/inc -Fi$(FPC_RTL_SOURCE)/$(FPC_RTL_CPU) \
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
ARCHIVE_LIBRARY_OBJECTS := $(USER_BUILD_DIRECTORY)/archive
SSH_LIBRARY_OBJECTS := $(USER_BUILD_DIRECTORY)/ssh
QUIC_LIBRARY_OBJECTS := $(USER_BUILD_DIRECTORY)/quic
HTTP_LIBRARY_OBJECTS := $(USER_BUILD_DIRECTORY)/http
CSS_LIBRARY_OBJECTS := $(USER_BUILD_DIRECTORY)/css
SVG_LIBRARY_OBJECTS := $(USER_BUILD_DIRECTORY)/svg
WEB_LIBRARY_OBJECTS := $(USER_BUILD_DIRECTORY)/web
JAVASCRIPT_LIBRARY_OBJECTS := $(USER_BUILD_DIRECTORY)/javascript
WEBVIEW_LIBRARY_OBJECTS := $(USER_BUILD_DIRECTORY)/webview
WEBIPC_LIBRARY_OBJECTS := $(USER_BUILD_DIRECTORY)/webipc

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
ARCHIVE_LIBRARY := $(USER_LIBRARY_OUTPUT)/libarchive.so
SSH_LIBRARY := $(USER_LIBRARY_OUTPUT)/libssh.so
QUIC_LIBRARY := $(USER_LIBRARY_OUTPUT)/libquic.so
HTTP_LIBRARY := $(USER_LIBRARY_OUTPUT)/libhttp.so
CSS_LIBRARY := $(USER_LIBRARY_OUTPUT)/libcss.so
SVG_LIBRARY := $(USER_LIBRARY_OUTPUT)/libsvg.so
WEB_LIBRARY := $(USER_LIBRARY_OUTPUT)/libweb.so
JAVASCRIPT_LIBRARY := $(USER_LIBRARY_OUTPUT)/libjavascript.so
WEBVIEW_LIBRARY := $(USER_LIBRARY_OUTPUT)/libwebview.so
WEBIPC_LIBRARY := $(USER_LIBRARY_OUTPUT)/libwebipc.so
PLUGIN_LIBRARY := $(USER_LIBRARY_OUTPUT)/libplugin.so
TLSTEST_LIBRARY := $(USER_LIBRARY_OUTPUT)/libtlstest.so
DYNTLS_LIBRARY := $(USER_LIBRARY_OUTPUT)/libdyntls.so
DYNPASCAL_LIBRARY := $(USER_LIBRARY_OUTPUT)/libdynpascal.so

# Every userland/bin/<name>.pas becomes /bin/<name>. A program made of
# several units keeps the others in userland/<name>/.
USER_PROGRAM_SOURCES := $(wildcard userland/bin/*.pas)
USER_PROGRAMS := $(patsubst userland/bin/%.pas,$(USER_PROGRAM_OUTPUT)/%,$(USER_PROGRAM_SOURCES))

# Graphical programs live in folders of their own: every userland/<name>/
# with a program.info (its description: Configuration.ProgramInfo) is
# built from userland/<name>/<name>.pas and installed as /app/<name>/,
# the executable, program.info and the folder's own icons (icons/*.ico).
APP_PROGRAM_OUTPUT := $(USER_BUILD_DIRECTORY)/app-programs
APP_OUTPUT := $(USER_BUILD_DIRECTORY)/app
APP_NAMES := $(patsubst userland/%/program.info,%,$(wildcard userland/*/program.info))
APP_PROGRAMS := $(addprefix $(APP_PROGRAM_OUTPUT)/,$(APP_NAMES))
APP_FOLDERS := $(addsuffix /.installed,$(addprefix $(APP_OUTPUT)/,$(APP_NAMES)))

# The system's fonts (/lib/fonts/terminus): Terminus in the sizes it comes
# in, regular and bold, unpacked; with its licence (SIL Open Font
# License), which has to go with it.
TERMINUS_DIRECTORY ?= $(dir $(FONT_SOURCE))
TERMINUS_LICENSE ?= /usr/share/licenses/terminus-font/LICENSE
TERMINUS_SIZES := 12 14 16 18 20 22 24 28 32
SYSTEM_FONT_DIRECTORY := $(USER_BUILD_DIRECTORY)/fonts/terminus
SYSTEM_FONTS_STAMP := $(SYSTEM_FONT_DIRECTORY)/.unpacked

# The outline fonts (/lib/fonts/<family>): DejaVu Sans (the
# interface's) and DejaVu Sans Mono, Liberation, Noto with CJK and colour
# emoji, Source Sans, Cantarell, Roboto, Open Sans, Hack, Inconsolata,
# the URW base 35 and Droid Sans Fallback, all freely licensed and kept
# in userland/fonts with their licences (which have to go with them).
# scripts/install-fonts.py puts in the set FONT_SET names, as
# scripts/fonts.list says: full (the system disk, about 80 MB), core
# (DejaVu Sans and Sans Mono, Liberation, Droid Sans Fallback for CJK
# and Noto Sans Symbols 2: the default for arm64, whose system image is
# the Raspberry Pi's RAM disk, served over TFTP) or base (DejaVu Sans
# and Sans Mono regular and bold only). make update-fonts refreshes
# userland/fonts from the build machine's font packages.
OUTLINE_FONT_SOURCE := userland/fonts
OUTLINE_FONT_FILES := $(wildcard $(OUTLINE_FONT_SOURCE)/*/*) $(OUTLINE_FONT_SOURCE)/MANIFEST
FONT_SCRIPTS := scripts/install-fonts.py scripts/fontlist.py scripts/fonts.list
DEJAVU_SANS_DIRECTORY := $(OUTLINE_FONT_SOURCE)/dejavu-sans
ifeq ($(ARCH),arm64)
FONT_SET ?= core
else
FONT_SET ?= full
endif
OUTLINE_FONTS_STAMP := $(USER_BUILD_DIRECTORY)/fonts/.outline-fonts-$(FONT_SET)

# The icon theme (/usr/share/icons/NAME.ico, 16 to 96 pixels) and the
# pointer's pictures (/lib/pointers/NAME.cur, several sizes): drawn
# with vector shapes by userland/icons/make-icons.py (pycairo) when
# the system is built; the drawings are the project's own.
ICON_SOURCES := userland/icons/make-icons.py $(wildcard userland/icons/iconkit/*.py)
ICON_OUTPUT := $(USER_BUILD_DIRECTORY)/icons
POINTER_PICTURE_OUTPUT := $(USER_BUILD_DIRECTORY)/pointers
ICONS_STAMP := $(ICON_OUTPUT)/.drawn



.PHONY: userland system-disk

.SECONDEXPANSION:

userland: $(SYSTEM_LIBRARY) $(CRYPTO_LIBRARY) $(CORE_LIBRARY) $(AUDIO_LIBRARY) $(DRAWING_LIBRARY) $(FONT_LIBRARY) $(WINDOWING_LIBRARY) $(CONTROLS_LIBRARY) \
	$(CONFIGURATION_LIBRARY) $(TLS_LIBRARY) $(SSH_LIBRARY) $(QUIC_LIBRARY) $(HTTP_LIBRARY) $(CSS_LIBRARY) $(SVG_LIBRARY) $(WEB_LIBRARY) $(WEBIPC_LIBRARY) $(WEBVIEW_LIBRARY) $(JAVASCRIPT_LIBRARY) $(IMAGE_LIBRARY) $(COMPRESSION_LIBRARY) $(ARCHIVE_LIBRARY) $(PLUGIN_LIBRARY) $(TLSTEST_LIBRARY) $(DYNTLS_LIBRARY) $(DYNPASCAL_LIBRARY) $(USER_PROGRAMS) $(SYSTEM_FONTS_STAMP) \
	$(OUTLINE_FONTS_STAMP) $(ICONS_STAMP) $(APP_FOLDERS)

$(RTL_USER_DIRECTORY)/si_prc.ppu: $(wildcard rtl/fpc/*) shared/Abi.SystemCalls.inc shared/Abi.Networking.inc \
		shared/Abi.ErrorMessages.inc | $(CROSS_COMPILER)
	@test -f $(FPC_RTL_SOURCE)/inc/system.inc || \
		{ echo "The Free Pascal sources are needed in $(FPC_SOURCE) (set FPC_SOURCE)"; exit 1; }
	@rm -rf $(RTL_USER_DIRECTORY)
	@mkdir -p $(RTL_USER_DIRECTORY)
	$(TARGET_FPC) $(USER_RTL_FLAGS) -Us -FU$(RTL_USER_DIRECTORY) rtl/fpc/system.pp
	$(TARGET_FPC) $(USER_RTL_FLAGS) -Fu$(RTL_USER_DIRECTORY) -FU$(RTL_USER_DIRECTORY) rtl/fpc/buildrtl.pp
	$(TARGET_FPC) $(USER_RTL_FLAGS) -Fu$(RTL_USER_DIRECTORY) -FU$(RTL_USER_DIRECTORY) rtl/fpc/si_prc.pas
	$(TARGET_FPC) $(USER_RTL_FLAGS) -Fu$(RTL_USER_DIRECTORY) -FU$(RTL_USER_DIRECTORY) rtl/fpc/si_dll.pas
	@rm -f $(RTL_USER_DIRECTORY)/buildrtl.o
ifeq ($(ARCH),arm64)
	$(OBJCOPY) --redefine-sym FPC_THROWFPUEXCEPTION=FPC_THROWFPUEXCEPTION_RAISE $(RTL_USER_DIRECTORY)/system.o
	$(TARGET_AS) -o $(RTL_USER_DIRECTORY)/FloatCheck.o rtl/fpc/FloatCheck.aarch64.s
endif

# libsystem: the runtime library (System, SysUtils, Classes, ...), the
# shared runtime units and Sys.*.
$(SYSTEM_LIBRARY): $(RTL_USER_DIRECTORY)/si_prc.ppu $(wildcard userland/lib/system/*.pas) \
		shared/Runtime.Memory.pas shared/Runtime.Text.pas shared/Runtime.Time.pas shared/Abi.SystemCalls.pas \
		shared/AddressSelection.pas
	@rm -rf $(SYSTEM_LIBRARY_OBJECTS)
	@mkdir -p $(SYSTEM_LIBRARY_OBJECTS) $(USER_LIBRARY_OUTPUT)
	$(TARGET_FPC) $(USER_FLAGS) -Fu$(RTL_USER_DIRECTORY) -Fushared -Fuuserland/lib/system \
		-FU$(SYSTEM_LIBRARY_OBJECTS) userland/lib/system/Sys.Contents.pas
	$(LD) -shared $(USER_LIBRARY_LINK_FLAGS) -soname libsystem.so -o $@ \
		$(SYSTEM_LIBRARY_OBJECTS)/*.o $(filter-out %/si_prc.o %/si_dll.o,$(wildcard $(RTL_USER_DIRECTORY)/*.o))

# libcryptography: hashes, checksums, ciphers and random numbers.
$(CRYPTO_LIBRARY): $(SYSTEM_LIBRARY) $(wildcard userland/lib/cryptography/*.pas)
	@rm -rf $(CRYPTO_LIBRARY_OBJECTS)
	@mkdir -p $(CRYPTO_LIBRARY_OBJECTS)
	$(TARGET_FPC) $(USER_FLAGS) -Fu$(RTL_USER_DIRECTORY) -Fu$(SYSTEM_LIBRARY_OBJECTS) -Fuuserland/lib/cryptography \
		-FU$(CRYPTO_LIBRARY_OBJECTS) userland/lib/cryptography/Crypto.Contents.pas
	$(LD) -shared $(USER_LIBRARY_LINK_FLAGS) -soname libcryptography.so -o $@ \
		$(CRYPTO_LIBRARY_OBJECTS)/*.o -L$(USER_LIBRARY_OUTPUT) -lsystem

# libcoreutils: helpers shared by the command line tools.
$(CORE_LIBRARY): $(CRYPTO_LIBRARY) $(wildcard userland/lib/coreutils/*.pas)
	@rm -rf $(CORE_LIBRARY_OBJECTS)
	@mkdir -p $(CORE_LIBRARY_OBJECTS)
	$(TARGET_FPC) $(USER_FLAGS) -Fu$(RTL_USER_DIRECTORY) -Fu$(SYSTEM_LIBRARY_OBJECTS) -Fu$(CRYPTO_LIBRARY_OBJECTS) \
		-Fuuserland/lib/coreutils -FU$(CORE_LIBRARY_OBJECTS) userland/lib/coreutils/Util.Contents.pas
	$(LD) -shared $(USER_LIBRARY_LINK_FLAGS) -soname libcoreutils.so -o $@ \
		$(CORE_LIBRARY_OBJECTS)/*.o -L$(USER_LIBRARY_OUTPUT) -lcryptography -lsystem

# libaudio: the sound device, WAV files and tone synthesis.
$(AUDIO_LIBRARY): $(SYSTEM_LIBRARY) $(wildcard userland/lib/audio/*.pas)
	@rm -rf $(AUDIO_LIBRARY_OBJECTS)
	@mkdir -p $(AUDIO_LIBRARY_OBJECTS)
	$(TARGET_FPC) $(USER_FLAGS) -Fu$(RTL_USER_DIRECTORY) -Fu$(SYSTEM_LIBRARY_OBJECTS) -Fuuserland/lib/audio \
		-FU$(AUDIO_LIBRARY_OBJECTS) userland/lib/audio/Audio.Contents.pas
	$(LD) -shared $(USER_LIBRARY_LINK_FLAGS) -soname libaudio.so -o $@ \
		$(AUDIO_LIBRARY_OBJECTS)/*.o -L$(USER_LIBRARY_OUTPUT) -lsystem

# libdrawing: surfaces, clipping regions and drawing on them.
$(DRAWING_LIBRARY): $(SYSTEM_LIBRARY) $(wildcard userland/lib/drawing/*.pas)
	@rm -rf $(DRAWING_LIBRARY_OBJECTS)
	@mkdir -p $(DRAWING_LIBRARY_OBJECTS)
	$(TARGET_FPC) $(USER_FLAGS) -Fu$(RTL_USER_DIRECTORY) -Fuuserland/lib/drawing \
		-FU$(DRAWING_LIBRARY_OBJECTS) userland/lib/drawing/Drawing.Contents.pas
	$(LD) -shared $(USER_LIBRARY_LINK_FLAGS) -soname libdrawing.so -o $@ \
		$(DRAWING_LIBRARY_OBJECTS)/*.o -L$(USER_LIBRARY_OUTPUT) -lsystem

# libimage: images (pixels, frames, colour profile, metadata) and the
# formats they are read from and written to.
$(IMAGE_LIBRARY): $(DRAWING_LIBRARY) $(COMPRESSION_LIBRARY) $(wildcard userland/lib/image/*.pas)
	@rm -rf $(IMAGE_LIBRARY_OBJECTS)
	@mkdir -p $(IMAGE_LIBRARY_OBJECTS)
	$(TARGET_FPC) $(USER_FLAGS) -Fu$(RTL_USER_DIRECTORY) -Fu$(SYSTEM_LIBRARY_OBJECTS) -Fu$(DRAWING_LIBRARY_OBJECTS) \
		-Fu$(COMPRESSION_LIBRARY_OBJECTS) -Fuuserland/lib/image -FU$(IMAGE_LIBRARY_OBJECTS) \
		userland/lib/image/Image.Contents.pas
	$(LD) -shared $(USER_LIBRARY_LINK_FLAGS) -soname libimage.so -o $@ \
		$(IMAGE_LIBRARY_OBJECTS)/*.o -L$(USER_LIBRARY_OUTPUT) -lcompression -ldrawing -lsystem

# libfont: bitmap and TrueType fonts, picked by point size and DPI;
# measuring and drawing UTF-8 text.
$(FONT_LIBRARY): $(DRAWING_LIBRARY) $(wildcard userland/lib/font/*.pas)
	@rm -rf $(FONT_LIBRARY_OBJECTS)
	@mkdir -p $(FONT_LIBRARY_OBJECTS)
	$(TARGET_FPC) $(USER_FLAGS) -Fu$(RTL_USER_DIRECTORY) -Fu$(SYSTEM_LIBRARY_OBJECTS) -Fu$(DRAWING_LIBRARY_OBJECTS) \
		-Fuuserland/lib/font -FU$(FONT_LIBRARY_OBJECTS) userland/lib/font/Font.Contents.pas
	$(LD) -shared $(USER_LIBRARY_LINK_FLAGS) -soname libfont.so -o $@ \
		$(FONT_LIBRARY_OBJECTS)/*.o -L$(USER_LIBRARY_OUTPUT) -ldrawing -lsystem

# libconfiguration: settings, the user's over the system's, in files.
$(CONFIGURATION_LIBRARY): $(SYSTEM_LIBRARY) $(wildcard userland/lib/configuration/*.pas)
	@rm -rf $(CONFIGURATION_LIBRARY_OBJECTS)
	@mkdir -p $(CONFIGURATION_LIBRARY_OBJECTS)
	$(TARGET_FPC) $(USER_FLAGS) -Fu$(RTL_USER_DIRECTORY) -Fu$(SYSTEM_LIBRARY_OBJECTS) -Fuuserland/lib/configuration \
		-FU$(CONFIGURATION_LIBRARY_OBJECTS) userland/lib/configuration/Configuration.Contents.pas
	$(LD) -shared $(USER_LIBRARY_LINK_FLAGS) -soname libconfiguration.so -o $@ \
		$(CONFIGURATION_LIBRARY_OBJECTS)/*.o -L$(USER_LIBRARY_OUTPUT) -lsystem

# libtls: a TLS 1.3 and 1.2 client with X.509 certificate checking.
$(TLS_LIBRARY): $(CRYPTO_LIBRARY) $(wildcard userland/lib/tls/*.pas)
	@rm -rf $(TLS_LIBRARY_OBJECTS)
	@mkdir -p $(TLS_LIBRARY_OBJECTS)
	$(TARGET_FPC) $(USER_FLAGS) -Fu$(RTL_USER_DIRECTORY) -Fu$(SYSTEM_LIBRARY_OBJECTS) -Fu$(CRYPTO_LIBRARY_OBJECTS) \
		-Fuuserland/lib/tls -FU$(TLS_LIBRARY_OBJECTS) userland/lib/tls/Tls.Contents.pas
	$(LD) -shared $(USER_LIBRARY_LINK_FLAGS) -soname libtls.so -o $@ \
		$(TLS_LIBRARY_OBJECTS)/*.o -L$(USER_LIBRARY_OUTPUT) -lcryptography -lsystem

# libquic: QUIC (RFC 9000-9002), QPACK and HTTP/3, over libtls's QUIC mode;
# on libhttp for HPACK's Huffman code, header fields and the connection
# class its HTTP/3 connections plug into.
$(QUIC_LIBRARY): $(TLS_LIBRARY) $(HTTP_LIBRARY) $(wildcard userland/lib/quic/*.pas)
	@rm -rf $(QUIC_LIBRARY_OBJECTS)
	@mkdir -p $(QUIC_LIBRARY_OBJECTS)
	$(TARGET_FPC) $(USER_FLAGS) -Fu$(RTL_USER_DIRECTORY) -Fu$(SYSTEM_LIBRARY_OBJECTS) -Fu$(CRYPTO_LIBRARY_OBJECTS) \
		-Fu$(TLS_LIBRARY_OBJECTS) -Fu$(COMPRESSION_LIBRARY_OBJECTS) -Fu$(HTTP_LIBRARY_OBJECTS) -Fuuserland/lib/quic \
		-FU$(QUIC_LIBRARY_OBJECTS) userland/lib/quic/Quic.Contents.pas
	$(LD) -shared $(USER_LIBRARY_LINK_FLAGS) -soname libquic.so -o $@ \
		$(QUIC_LIBRARY_OBJECTS)/*.o -L$(USER_LIBRARY_OUTPUT) -lhttp -ltls -lcompression -lcryptography -lsystem
# libhttp: the URL Standard and an HTTP/1.1 and HTTP/2 client (cookies,
# cache, authentication, content decoding) over libtls and libcompression.
$(HTTP_LIBRARY): $(TLS_LIBRARY) $(COMPRESSION_LIBRARY) $(wildcard userland/lib/http/*.pas)
	@rm -rf $(HTTP_LIBRARY_OBJECTS)
	@mkdir -p $(HTTP_LIBRARY_OBJECTS)
	$(TARGET_FPC) $(USER_FLAGS) -Fu$(RTL_USER_DIRECTORY) -Fu$(SYSTEM_LIBRARY_OBJECTS) -Fu$(CRYPTO_LIBRARY_OBJECTS) \
		-Fu$(TLS_LIBRARY_OBJECTS) -Fu$(COMPRESSION_LIBRARY_OBJECTS) -Fuuserland/lib/http -FU$(HTTP_LIBRARY_OBJECTS) \
		userland/lib/http/Http.Contents.pas
	$(LD) -shared $(USER_LIBRARY_LINK_FLAGS) -soname libhttp.so -o $@ \
		$(HTTP_LIBRARY_OBJECTS)/*.o -L$(USER_LIBRARY_OUTPUT) -ltls -lcompression -lcryptography -lsystem

# libssh: the SSH protocol, the server's side (transport, key exchange,
# host keys, user authentication, channels).
$(SSH_LIBRARY): $(CRYPTO_LIBRARY) $(wildcard userland/lib/ssh/*.pas)
	@rm -rf $(SSH_LIBRARY_OBJECTS)
	@mkdir -p $(SSH_LIBRARY_OBJECTS)
	$(TARGET_FPC) $(USER_FLAGS) -Fu$(RTL_USER_DIRECTORY) -Fu$(SYSTEM_LIBRARY_OBJECTS) -Fu$(CRYPTO_LIBRARY_OBJECTS) \
		-Fuuserland/lib/ssh -FU$(SSH_LIBRARY_OBJECTS) userland/lib/ssh/Ssh.Contents.pas
	$(LD) -shared $(USER_LIBRARY_LINK_FLAGS) -soname libssh.so -o $@ \
		$(SSH_LIBRARY_OBJECTS)/*.o -L$(USER_LIBRARY_OUTPUT) -lcryptography -lsystem

# libcss: the style engine (CSS syntax, selectors, values, the cascade,
# computed styles); it knows no document model (an element adapter).
$(CSS_LIBRARY): $(SYSTEM_LIBRARY) $(wildcard userland/lib/css/*.pas)
	@rm -rf $(CSS_LIBRARY_OBJECTS)
	@mkdir -p $(CSS_LIBRARY_OBJECTS)
	$(TARGET_FPC) $(USER_FLAGS) -Fu$(RTL_USER_DIRECTORY) -Fu$(SYSTEM_LIBRARY_OBJECTS) -Fuuserland/lib/css \
		-FU$(CSS_LIBRARY_OBJECTS) userland/lib/css/Css.Contents.pas
	$(LD) -shared $(USER_LIBRARY_LINK_FLAGS) -soname libcss.so -o $@ \
		$(CSS_LIBRARY_OBJECTS)/*.o -L$(USER_LIBRARY_OUTPUT) -lsystem

# libsvg: SVG documents (XML, styling with libcss), their rendering with
# libdrawing (text with libfont, images with libimage) and SVG as a
# scalable image in libimage's codec registry.
$(SVG_LIBRARY): $(CSS_LIBRARY) $(FONT_LIBRARY) $(IMAGE_LIBRARY) $(wildcard userland/lib/svg/*.pas)
	@rm -rf $(SVG_LIBRARY_OBJECTS)
	@mkdir -p $(SVG_LIBRARY_OBJECTS)
	$(TARGET_FPC) $(USER_FLAGS) -Fu$(RTL_USER_DIRECTORY) -Fu$(SYSTEM_LIBRARY_OBJECTS) -Fu$(CSS_LIBRARY_OBJECTS) \
		-Fu$(FONT_LIBRARY_OBJECTS) -Fu$(DRAWING_LIBRARY_OBJECTS) -Fu$(IMAGE_LIBRARY_OBJECTS) \
		-Fu$(COMPRESSION_LIBRARY_OBJECTS) -Fuuserland/lib/svg -FU$(SVG_LIBRARY_OBJECTS) userland/lib/svg/Svg.Contents.pas
	$(LD) -shared $(USER_LIBRARY_LINK_FLAGS) -soname libsvg.so -o $@ \
		$(SVG_LIBRARY_OBJECTS)/*.o -L$(USER_LIBRARY_OUTPUT) -lcss -lfont -limage -lcompression -ldrawing -lsystem

# libweb: the browser engine (encodings, the HTML parser, the DOM, the event
# loop, fetching through libhttp, loading and navigation, styling, layout,
# painting and the script bindings). Its tables (atoms, encodings, named
# character references) are generated from userland/lib/web/data by
# make-tables.py, the binding tables from userland/lib/web/bindings/*.webidl
# by make-bindings.py.
WEB_GENERATED := $(USER_BUILD_DIRECTORY)/web-generated
WEB_TABLE_SOURCES := userland/lib/web/make-tables.py $(wildcard userland/lib/web/data/*.txt) \
	userland/lib/web/make-bindings.py $(wildcard userland/lib/web/bindings/*.webidl) \
	$(wildcard userland/lib/web/platform/*.js)

$(WEB_GENERATED)/.generated: $(WEB_TABLE_SOURCES)
	@rm -rf $(WEB_GENERATED)
	@mkdir -p $(WEB_GENERATED)
	python3 -B userland/lib/web/make-tables.py $(WEB_GENERATED)
	python3 -B userland/lib/web/make-bindings.py $(WEB_GENERATED)
	@touch $@

$(WEB_LIBRARY): $(SYSTEM_LIBRARY) $(JAVASCRIPT_LIBRARY) $(HTTP_LIBRARY) $(CSS_LIBRARY) $(FONT_LIBRARY) $(DRAWING_LIBRARY) $(IMAGE_LIBRARY) \
		$(SVG_LIBRARY) \
		$(WEB_GENERATED)/.generated $(wildcard userland/lib/web/*.pas) $(wildcard userland/lib/web/*.inc)
	@rm -rf $(WEB_LIBRARY_OBJECTS)
	@mkdir -p $(WEB_LIBRARY_OBJECTS)
	$(TARGET_FPC) $(USER_FLAGS) -Fu$(RTL_USER_DIRECTORY) -Fu$(SYSTEM_LIBRARY_OBJECTS) -Fu$(JAVASCRIPT_LIBRARY_OBJECTS) -Fu$(HTTP_LIBRARY_OBJECTS) \
		-Fu$(TLS_LIBRARY_OBJECTS) -Fu$(CRYPTO_LIBRARY_OBJECTS) -Fu$(COMPRESSION_LIBRARY_OBJECTS) \
		-Fu$(CSS_LIBRARY_OBJECTS) -Fu$(FONT_LIBRARY_OBJECTS) -Fu$(IMAGE_LIBRARY_OBJECTS) -Fu$(DRAWING_LIBRARY_OBJECTS) \
		-Fu$(SVG_LIBRARY_OBJECTS) \
		-Fuuserland/lib/web -Fi$(WEB_GENERATED) -FU$(WEB_LIBRARY_OBJECTS) userland/lib/web/Web.Contents.pas
	@# The bindings' units use each other in a cycle: compiled again from
	@# the script units' entry, the ones built against an earlier state of
	@# another are rebuilt, so programs using them find them consistent.
	$(TARGET_FPC) $(USER_FLAGS) -Fu$(RTL_USER_DIRECTORY) -Fu$(SYSTEM_LIBRARY_OBJECTS) -Fu$(JAVASCRIPT_LIBRARY_OBJECTS) -Fu$(HTTP_LIBRARY_OBJECTS) \
		-Fu$(TLS_LIBRARY_OBJECTS) -Fu$(CRYPTO_LIBRARY_OBJECTS) -Fu$(COMPRESSION_LIBRARY_OBJECTS) \
		-Fu$(CSS_LIBRARY_OBJECTS) -Fu$(FONT_LIBRARY_OBJECTS) -Fu$(IMAGE_LIBRARY_OBJECTS) -Fu$(DRAWING_LIBRARY_OBJECTS) \
		-Fu$(SVG_LIBRARY_OBJECTS) \
		-Fuuserland/lib/web -Fi$(WEB_GENERATED) -FU$(WEB_LIBRARY_OBJECTS) userland/lib/web/Web.Script.PageScripting.pas
	$(LD) -shared $(USER_LIBRARY_LINK_FLAGS) -soname libweb.so -o $@ \
		$(WEB_LIBRARY_OBJECTS)/*.o -L$(USER_LIBRARY_OUTPUT) -ljavascript -lhttp -lsvg -lcss -lfont -limage -ldrawing -ltls -lcompression \
		-lcryptography -lsystem

# libwebipc: the browser's protocol between its process and its content
# processes (messages, pieces, channel endpoints, shared surfaces).
$(WEBIPC_LIBRARY): $(SYSTEM_LIBRARY) $(DRAWING_LIBRARY) $(wildcard userland/lib/webipc/*.pas)
	@rm -rf $(WEBIPC_LIBRARY_OBJECTS)
	@mkdir -p $(WEBIPC_LIBRARY_OBJECTS)
	$(TARGET_FPC) $(USER_FLAGS) -Fu$(RTL_USER_DIRECTORY) -Fu$(SYSTEM_LIBRARY_OBJECTS) -Fu$(DRAWING_LIBRARY_OBJECTS) \
		-Fuuserland/lib/webipc -FU$(WEBIPC_LIBRARY_OBJECTS) userland/lib/webipc/WebIpc.Contents.pas
	$(LD) -shared $(USER_LIBRARY_LINK_FLAGS) -soname libwebipc.so -o $@ \
		$(WEBIPC_LIBRARY_OBJECTS)/*.o -L$(USER_LIBRARY_OUTPUT) -ldrawing -lsystem

# libwebview: TWebView, the control that shows web pages (libweb in a
# libcontrols control), for the browser and any program.
$(WEBVIEW_LIBRARY): $(WEB_LIBRARY) $(CONTROLS_LIBRARY) $(WEBIPC_LIBRARY) $(wildcard userland/lib/webview/*.pas) \
		$(wildcard userland/lib/webview/*.inc)
	@rm -rf $(WEBVIEW_LIBRARY_OBJECTS)
	@mkdir -p $(WEBVIEW_LIBRARY_OBJECTS)
	$(TARGET_FPC) $(USER_FLAGS) -Fu$(RTL_USER_DIRECTORY) -Fu$(SYSTEM_LIBRARY_OBJECTS) -Fu$(JAVASCRIPT_LIBRARY_OBJECTS) -Fu$(HTTP_LIBRARY_OBJECTS) \
		-Fu$(TLS_LIBRARY_OBJECTS) -Fu$(CRYPTO_LIBRARY_OBJECTS) -Fu$(COMPRESSION_LIBRARY_OBJECTS) \
		-Fu$(CSS_LIBRARY_OBJECTS) -Fu$(FONT_LIBRARY_OBJECTS) -Fu$(IMAGE_LIBRARY_OBJECTS) -Fu$(DRAWING_LIBRARY_OBJECTS) \
		-Fu$(SVG_LIBRARY_OBJECTS) \
		-Fu$(WEB_LIBRARY_OBJECTS) -Fu$(CONFIGURATION_LIBRARY_OBJECTS) -Fu$(WINDOWING_LIBRARY_OBJECTS) \
		-Fu$(CONTROLS_LIBRARY_OBJECTS) -Fu$(WEBIPC_LIBRARY_OBJECTS) -Fi$(WEB_GENERATED) -Fuuserland/lib/webview \
		-FU$(WEBVIEW_LIBRARY_OBJECTS) userland/lib/webview/WebView.Contents.pas
	$(LD) -shared $(USER_LIBRARY_LINK_FLAGS) -soname libwebview.so -o $@ \
		$(WEBVIEW_LIBRARY_OBJECTS)/*.o -L$(USER_LIBRARY_OUTPUT) -lweb -lwebipc -lsvg -ljavascript -lcontrols -lwindowing -lconfiguration -lhttp \
		-lcss -lfont -limage -ldrawing -ltls -lcompression -lcryptography -lsystem

# libjavascript: the ECMAScript engine (Js.*) and its embedding API.
$(JAVASCRIPT_LIBRARY): $(SYSTEM_LIBRARY) $(wildcard userland/lib/javascript/*.pas)
	@rm -rf $(JAVASCRIPT_LIBRARY_OBJECTS)
	@mkdir -p $(JAVASCRIPT_LIBRARY_OBJECTS)
	$(TARGET_FPC) $(USER_FLAGS) -Fu$(RTL_USER_DIRECTORY) -Fu$(SYSTEM_LIBRARY_OBJECTS) -Fuuserland/lib/javascript \
		-FU$(JAVASCRIPT_LIBRARY_OBJECTS) userland/lib/javascript/Js.Contents.pas
	$(LD) -shared $(USER_LIBRARY_LINK_FLAGS) -soname libjavascript.so -o $@ \
		$(JAVASCRIPT_LIBRARY_OBJECTS)/*.o -L$(USER_LIBRARY_OUTPUT) -lsystem

# libcompression: deflate compression and decompression, the zlib and
# gzip wrappers and their checksums, brotli and Zstandard decompression.
$(COMPRESSION_LIBRARY): $(SYSTEM_LIBRARY) $(wildcard userland/lib/compression/*.pas) \
		$(wildcard userland/lib/compression/*.inc)
	@rm -rf $(COMPRESSION_LIBRARY_OBJECTS)
	@mkdir -p $(COMPRESSION_LIBRARY_OBJECTS)
	$(TARGET_FPC) $(USER_FLAGS) -Fu$(RTL_USER_DIRECTORY) -Fu$(SYSTEM_LIBRARY_OBJECTS) -Fuuserland/lib/compression \
		-FU$(COMPRESSION_LIBRARY_OBJECTS) userland/lib/compression/Compression.Contents.pas
	$(LD) -shared $(USER_LIBRARY_LINK_FLAGS) -soname libcompression.so -o $@ \
		$(COMPRESSION_LIBRARY_OBJECTS)/*.o -L$(USER_LIBRARY_OUTPUT) -lsystem

# libarchive: reading zip, tar and tar.gz files, writing zip files,
# extracting and browsing them (over libcompression).
$(ARCHIVE_LIBRARY): $(COMPRESSION_LIBRARY) $(wildcard userland/lib/archive/*.pas)
	@rm -rf $(ARCHIVE_LIBRARY_OBJECTS)
	@mkdir -p $(ARCHIVE_LIBRARY_OBJECTS)
	$(TARGET_FPC) $(USER_FLAGS) -Fu$(RTL_USER_DIRECTORY) -Fu$(SYSTEM_LIBRARY_OBJECTS) -Fu$(COMPRESSION_LIBRARY_OBJECTS) \
		-Fuuserland/lib/archive -FU$(ARCHIVE_LIBRARY_OBJECTS) userland/lib/archive/Archive.Contents.pas
	$(LD) -shared $(USER_LIBRARY_LINK_FLAGS) -soname libarchive.so -o $@ \
		$(ARCHIVE_LIBRARY_OBJECTS)/*.o -L$(USER_LIBRARY_OUTPUT) -lcompression -lsystem

# libwindowing: the display server's protocol and windows for programs.
$(WINDOWING_LIBRARY): $(FONT_LIBRARY) $(CONFIGURATION_LIBRARY) $(wildcard userland/lib/windowing/*.pas)
	@rm -rf $(WINDOWING_LIBRARY_OBJECTS)
	@mkdir -p $(WINDOWING_LIBRARY_OBJECTS)
	$(TARGET_FPC) $(USER_FLAGS) -Fu$(RTL_USER_DIRECTORY) -Fu$(SYSTEM_LIBRARY_OBJECTS) -Fu$(DRAWING_LIBRARY_OBJECTS) \
		-Fu$(FONT_LIBRARY_OBJECTS) -Fu$(CONFIGURATION_LIBRARY_OBJECTS) -Fuuserland/lib/windowing \
		-FU$(WINDOWING_LIBRARY_OBJECTS) userland/lib/windowing/Windowing.Contents.pas
	$(LD) -shared $(USER_LIBRARY_LINK_FLAGS) -soname libwindowing.so -o $@ \
		$(WINDOWING_LIBRARY_OBJECTS)/*.o -L$(USER_LIBRARY_OUTPUT) -lconfiguration -lfont -ldrawing -lsystem

# libcontrols: controls, control windows and dialogs.
# Pictures (picture boxes, image lists) come from libimage.
$(CONTROLS_LIBRARY): $(WINDOWING_LIBRARY) $(IMAGE_LIBRARY) $(wildcard userland/lib/controls/*.pas)
	@rm -rf $(CONTROLS_LIBRARY_OBJECTS)
	@mkdir -p $(CONTROLS_LIBRARY_OBJECTS)
	$(TARGET_FPC) $(USER_FLAGS) -Fu$(RTL_USER_DIRECTORY) -Fu$(SYSTEM_LIBRARY_OBJECTS) -Fu$(DRAWING_LIBRARY_OBJECTS) \
		-Fu$(FONT_LIBRARY_OBJECTS) -Fu$(CONFIGURATION_LIBRARY_OBJECTS) -Fu$(WINDOWING_LIBRARY_OBJECTS) \
		-Fu$(COMPRESSION_LIBRARY_OBJECTS) -Fu$(IMAGE_LIBRARY_OBJECTS) \
		-Fuuserland/lib/controls -FU$(CONTROLS_LIBRARY_OBJECTS) userland/lib/controls/Controls.Contents.pas
	$(LD) -shared $(USER_LIBRARY_LINK_FLAGS) -soname libcontrols.so -o $@ \
		$(CONTROLS_LIBRARY_OBJECTS)/*.o -L$(USER_LIBRARY_OUTPUT) -lwindowing -lconfiguration -lfont -limage \
		-lcompression -ldrawing -lsystem

$(SYSTEM_FONTS_STAMP):
	@test -f $(TERMINUS_LICENSE) || { echo "The Terminus licence is needed in $(TERMINUS_LICENSE) (set TERMINUS_LICENSE)"; exit 1; }
	@mkdir -p $(SYSTEM_FONT_DIRECTORY)
	@for size in $(TERMINUS_SIZES); do for weight in n b; do \
		source=$(TERMINUS_DIRECTORY)ter-v$$size$$weight.psf.gz; \
		if [ -f $$source ]; then zcat $$source > $(SYSTEM_FONT_DIRECTORY)/ter-v$$size$$weight.psf; fi; \
	done; done
	cp $(TERMINUS_LICENSE) $(SYSTEM_FONT_DIRECTORY)/LICENSE
	@touch $@

$(OUTLINE_FONTS_STAMP): $(OUTLINE_FONT_FILES) $(FONT_SCRIPTS)
	@rm -f $(USER_BUILD_DIRECTORY)/fonts/.outline-fonts* $(USER_BUILD_DIRECTORY)/fonts/.host-fonts-*
	python3 -B scripts/install-fonts.py scripts/fonts.list $(OUTLINE_FONT_SOURCE) $(USER_BUILD_DIRECTORY)/fonts --set $(FONT_SET)
	@touch $@

$(ICONS_STAMP): $(ICON_SOURCES)
	@python3 -c 'import cairo' 2>/dev/null || { echo "Python 3 with pycairo is needed to draw the icons (python-cairo)"; exit 1; }
	@rm -rf $(ICON_OUTPUT) $(POINTER_PICTURE_OUTPUT)
	python3 -B userland/icons/make-icons.py $(ICON_OUTPUT) $(POINTER_PICTURE_OUTPUT)
	@touch $@

# A library loaded at run time by the tests.
$(PLUGIN_LIBRARY): $(SYSTEM_LIBRARY) userland/lib/plugin/Plugin.pas
	@rm -rf $(USER_BUILD_DIRECTORY)/plugin
	@mkdir -p $(USER_BUILD_DIRECTORY)/plugin
	$(TARGET_FPC) $(USER_FLAGS) -Fu$(RTL_USER_DIRECTORY) -Fu$(SYSTEM_LIBRARY_OBJECTS) \
		-FU$(USER_BUILD_DIRECTORY)/plugin userland/lib/plugin/Plugin.pas
	$(LD) -shared $(USER_LIBRARY_LINK_FLAGS) -soname libplugin.so -o $@ \
		$(USER_BUILD_DIRECTORY)/plugin/*.o -L$(USER_LIBRARY_OUTPUT) -lsystem

# A library in assembly with thread-local storage and initializers, which
# Free Pascal does not produce; used by threadtest.
# One source per architecture (TlsTest.s for x86-64, TlsTest.arm64.s).
TLSTEST_SOURCE := $(firstword $(wildcard userland/lib/tlstest/TlsTest.$(ARCH).s) userland/lib/tlstest/TlsTest.s)
$(TLSTEST_LIBRARY): $(SYSTEM_LIBRARY) $(TLSTEST_SOURCE)
	@mkdir -p $(USER_BUILD_DIRECTORY)/tlstest
	$(TARGET_AS) -o $(USER_BUILD_DIRECTORY)/tlstest/TlsTest.o $(TLSTEST_SOURCE)
	$(LD) -shared $(USER_LIBRARY_LINK_FLAGS) -soname libtlstest.so -o $@ \
		$(USER_BUILD_DIRECTORY)/tlstest/TlsTest.o -L$(USER_LIBRARY_OUTPUT) -lsystem

# Libraries dynlibtest loads with LoadLibrary after it started threads:
# libdyntls.so in assembly (ELF thread-local storage, initializer and
# finalizer arrays; one source per architecture) and libdynpascal.so, a
# Free Pascal "library" with threadvars and a unit initialization of its
# own, started by si_dll (its DT_INIT and DT_FINI).
DYNTLS_SOURCE := $(firstword $(wildcard userland/lib/dyntls/DynTls.$(ARCH).s) userland/lib/dyntls/DynTls.s)
$(DYNTLS_LIBRARY): $(SYSTEM_LIBRARY) $(DYNTLS_SOURCE)
	@mkdir -p $(USER_BUILD_DIRECTORY)/dyntls
	$(TARGET_AS) -o $(USER_BUILD_DIRECTORY)/dyntls/DynTls.o $(DYNTLS_SOURCE)
	$(LD) -shared $(USER_LIBRARY_LINK_FLAGS) -soname libdyntls.so -o $@ \
		$(USER_BUILD_DIRECTORY)/dyntls/DynTls.o -L$(USER_LIBRARY_OUTPUT) -lsystem

$(DYNPASCAL_LIBRARY): $(SYSTEM_LIBRARY) $(wildcard userland/lib/dynpascal/*.pas)
	@rm -rf $(USER_BUILD_DIRECTORY)/dynpascal
	@mkdir -p $(USER_BUILD_DIRECTORY)/dynpascal
	$(TARGET_FPC) $(USER_FLAGS) -Fu$(RTL_USER_DIRECTORY) -Fu$(SYSTEM_LIBRARY_OBJECTS) -Fuuserland/lib/dynpascal \
		-FU$(USER_BUILD_DIRECTORY)/dynpascal -FE$(USER_BUILD_DIRECTORY)/dynpascal userland/lib/dynpascal/DynPascal.pas
	$(LD) -shared $(USER_LIBRARY_LINK_FLAGS) -soname libdynpascal.so -init FPC_SHARED_LIB_START -fini FPC_LIB_EXIT \
		-o $@ $(USER_BUILD_DIRECTORY)/dynpascal/*.o $(RTL_USER_DIRECTORY)/si_dll.o -L$(USER_LIBRARY_OUTPUT) -lsystem

$(USER_PROGRAM_OUTPUT)/dynlibtest: $(DYNTLS_LIBRARY) $(DYNPASCAL_LIBRARY)

# Programs that need more libraries than the usual three.
$(USER_PROGRAM_OUTPUT)/threadtest: EXTRA_PROGRAM_LIBRARIES := -ltlstest
$(USER_PROGRAM_OUTPUT)/threadtest: $(TLSTEST_LIBRARY)
GRAPHICAL_PROGRAMS := $(addprefix $(USER_PROGRAM_OUTPUT)/,drawtest displayserver displayscale displaymode mousesettings keyboardsettings wintest ownertest sessionmanager sysinfo hangtest) \
	$(addprefix $(APP_PROGRAM_OUTPUT)/,controlsdemo controlstour dialogtour notepad terminal taskmanager calculator imageviewer paint)
$(GRAPHICAL_PROGRAMS): EXTRA_PROGRAM_LIBRARIES := -lcontrols -lwindowing -lconfiguration -lfont -limage -lcompression \
	-ldrawing
$(GRAPHICAL_PROGRAMS): EXTRA_PROGRAM_UNITS := -Fu$(DRAWING_LIBRARY_OBJECTS) -Fu$(FONT_LIBRARY_OBJECTS) \
	-Fu$(CONFIGURATION_LIBRARY_OBJECTS) -Fu$(WINDOWING_LIBRARY_OBJECTS) -Fu$(CONTROLS_LIBRARY_OBJECTS) \
	-Fu$(COMPRESSION_LIBRARY_OBJECTS) -Fu$(IMAGE_LIBRARY_OBJECTS)
$(GRAPHICAL_PROGRAMS): $(CONTROLS_LIBRARY)
# Graphical programs that set the sound outputs too.
GRAPHICAL_SOUND_PROGRAMS := $(addprefix $(USER_PROGRAM_OUTPUT)/,desktop) $(addprefix $(APP_PROGRAM_OUTPUT)/,controlpanel volumecontrol)
$(GRAPHICAL_SOUND_PROGRAMS): EXTRA_PROGRAM_LIBRARIES := -lcontrols -lwindowing -lconfiguration -lfont -limage \
	-lcompression -ldrawing -laudio
$(GRAPHICAL_SOUND_PROGRAMS): EXTRA_PROGRAM_UNITS := -Fu$(DRAWING_LIBRARY_OBJECTS) -Fu$(FONT_LIBRARY_OBJECTS) \
	-Fu$(CONFIGURATION_LIBRARY_OBJECTS) -Fu$(WINDOWING_LIBRARY_OBJECTS) -Fu$(CONTROLS_LIBRARY_OBJECTS) \
	-Fu$(COMPRESSION_LIBRARY_OBJECTS) -Fu$(IMAGE_LIBRARY_OBJECTS) -Fu$(AUDIO_LIBRARY_OBJECTS)
$(GRAPHICAL_SOUND_PROGRAMS): $(CONTROLS_LIBRARY) $(AUDIO_LIBRARY)
# The network service reads its configuration from the settings.
SETTINGS_PROGRAMS := $(addprefix $(USER_PROGRAM_OUTPUT)/,settings settingstest network networktest timesync)
$(SETTINGS_PROGRAMS): EXTRA_PROGRAM_LIBRARIES := -lconfiguration
$(SETTINGS_PROGRAMS): EXTRA_PROGRAM_UNITS := -Fu$(CONFIGURATION_LIBRARY_OBJECTS)
$(SETTINGS_PROGRAMS): $(CONFIGURATION_LIBRARY)
# h3get speaks HTTP/3 through libquic; wget fetches through libhttp, with
# HTTP/3 from libquic (both over libtls and libcompression).
QUIC_PROGRAMS := $(addprefix $(USER_PROGRAM_OUTPUT)/,h3get wget)
$(QUIC_PROGRAMS): EXTRA_PROGRAM_LIBRARIES := -lquic -lhttp -ltls -lcompression
$(QUIC_PROGRAMS): EXTRA_PROGRAM_UNITS := -Fu$(QUIC_LIBRARY_OBJECTS) -Fu$(HTTP_LIBRARY_OBJECTS) -Fu$(TLS_LIBRARY_OBJECTS) \
	-Fu$(COMPRESSION_LIBRARY_OBJECTS)
$(QUIC_PROGRAMS): $(QUIC_LIBRARY)
# ss is built on netstat's units (userland/netstat).
NETSTAT_UNIT_PROGRAMS := $(addprefix $(USER_PROGRAM_OUTPUT)/,ss)
$(NETSTAT_UNIT_PROGRAMS): EXTRA_PROGRAM_UNITS := -Fuuserland/netstat
$(NETSTAT_UNIT_PROGRAMS): $(wildcard userland/netstat/*.pas)
# The SSH server, its SFTP subsystem and the client programs speak SSH
# through libssh.
# htmldump parses HTML through libweb.
# webrender renders a page to a PNG (or prints its layout) through libweb.
WEB_PROGRAMS := $(addprefix $(USER_PROGRAM_OUTPUT)/,htmldump webrender)
$(WEB_PROGRAMS): EXTRA_PROGRAM_LIBRARIES := -lweb -lsvg -ljavascript -lhttp -lcss -limage -lfont -ldrawing -ltls -lcompression -lcryptography
$(WEB_PROGRAMS): EXTRA_PROGRAM_UNITS := -Fu$(WEB_LIBRARY_OBJECTS) -Fu$(SVG_LIBRARY_OBJECTS) -Fu$(JAVASCRIPT_LIBRARY_OBJECTS) -Fu$(HTTP_LIBRARY_OBJECTS) -Fu$(CSS_LIBRARY_OBJECTS) -Fu$(IMAGE_LIBRARY_OBJECTS) \
	-Fu$(COMPRESSION_LIBRARY_OBJECTS) -Fu$(FONT_LIBRARY_OBJECTS) -Fu$(DRAWING_LIBRARY_OBJECTS) -Fuuserland/webrender
$(WEB_PROGRAMS): $(WEB_LIBRARY) $(wildcard userland/webrender/*.pas)
# The browser: web views (libwebview over libweb and libjavascript), with
# HTTP/3 from libquic.
BROWSER_PROGRAMS := $(addprefix $(APP_PROGRAM_OUTPUT)/,browser)
$(BROWSER_PROGRAMS): EXTRA_PROGRAM_LIBRARIES := -lwebview -lwebipc -lweb -lsvg -ljavascript -lquic -lhttp -lcss -lcontrols -lwindowing \
	-lconfiguration -lfont -limage -lcompression -ldrawing -ltls
$(BROWSER_PROGRAMS): EXTRA_PROGRAM_UNITS := -Fu$(WEBVIEW_LIBRARY_OBJECTS) -Fu$(WEBIPC_LIBRARY_OBJECTS) -Fu$(WEB_LIBRARY_OBJECTS) -Fu$(SVG_LIBRARY_OBJECTS) \
	-Fu$(JAVASCRIPT_LIBRARY_OBJECTS) -Fu$(QUIC_LIBRARY_OBJECTS) -Fu$(HTTP_LIBRARY_OBJECTS) -Fu$(TLS_LIBRARY_OBJECTS) \
	-Fu$(CSS_LIBRARY_OBJECTS) -Fu$(DRAWING_LIBRARY_OBJECTS) -Fu$(FONT_LIBRARY_OBJECTS) -Fu$(CONFIGURATION_LIBRARY_OBJECTS) \
	-Fu$(WINDOWING_LIBRARY_OBJECTS) -Fu$(CONTROLS_LIBRARY_OBJECTS) -Fu$(COMPRESSION_LIBRARY_OBJECTS) \
	-Fu$(IMAGE_LIBRARY_OBJECTS) -Fi$(WEB_GENERATED)
$(BROWSER_PROGRAMS): $(WEBVIEW_LIBRARY) $(QUIC_LIBRARY) $(wildcard userland/browser/*.inc)
# The browser's content process: the page engine (libwebview) in a
# sandboxed process of its own, talking to the browser over libwebipc.
WEBCONTENT_PROGRAMS := $(addprefix $(USER_PROGRAM_OUTPUT)/,webcontent)
$(WEBCONTENT_PROGRAMS): EXTRA_PROGRAM_LIBRARIES := -lwebview -lwebipc -lweb -lsvg -ljavascript -lhttp -lcss -lcontrols \
	-lwindowing -lconfiguration -lfont -limage -lcompression -ldrawing -ltls
$(WEBCONTENT_PROGRAMS): EXTRA_PROGRAM_UNITS := -Fu$(WEBVIEW_LIBRARY_OBJECTS) -Fu$(WEBIPC_LIBRARY_OBJECTS) \
	-Fu$(WEB_LIBRARY_OBJECTS) -Fu$(SVG_LIBRARY_OBJECTS) -Fu$(JAVASCRIPT_LIBRARY_OBJECTS) -Fu$(HTTP_LIBRARY_OBJECTS) \
	-Fu$(TLS_LIBRARY_OBJECTS) -Fu$(CSS_LIBRARY_OBJECTS) -Fu$(DRAWING_LIBRARY_OBJECTS) -Fu$(FONT_LIBRARY_OBJECTS) \
	-Fu$(CONFIGURATION_LIBRARY_OBJECTS) -Fu$(WINDOWING_LIBRARY_OBJECTS) -Fu$(CONTROLS_LIBRARY_OBJECTS) \
	-Fu$(COMPRESSION_LIBRARY_OBJECTS) -Fu$(IMAGE_LIBRARY_OBJECTS) -Fi$(WEB_GENERATED)
$(WEBCONTENT_PROGRAMS): $(WEBVIEW_LIBRARY) $(WEBIPC_LIBRARY)

# The file manager: previews web pages in a web view (libwebview) and
# browses, makes and extracts archives (libarchive).
FILES_PROGRAMS := $(addprefix $(APP_PROGRAM_OUTPUT)/,files)
$(FILES_PROGRAMS): EXTRA_PROGRAM_LIBRARIES := -lwebview -lwebipc -lweb -lsvg -ljavascript -lquic -lhttp -lcss -lcontrols -lwindowing \
	-lconfiguration -lfont -larchive -limage -lcompression -ldrawing -ltls
$(FILES_PROGRAMS): EXTRA_PROGRAM_UNITS := -Fu$(WEBVIEW_LIBRARY_OBJECTS) -Fu$(WEBIPC_LIBRARY_OBJECTS) -Fu$(WEB_LIBRARY_OBJECTS) -Fu$(SVG_LIBRARY_OBJECTS) \
	-Fu$(JAVASCRIPT_LIBRARY_OBJECTS) -Fu$(QUIC_LIBRARY_OBJECTS) -Fu$(HTTP_LIBRARY_OBJECTS) -Fu$(TLS_LIBRARY_OBJECTS) \
	-Fu$(CSS_LIBRARY_OBJECTS) -Fu$(DRAWING_LIBRARY_OBJECTS) -Fu$(FONT_LIBRARY_OBJECTS) -Fu$(CONFIGURATION_LIBRARY_OBJECTS) \
	-Fu$(WINDOWING_LIBRARY_OBJECTS) -Fu$(CONTROLS_LIBRARY_OBJECTS) -Fu$(ARCHIVE_LIBRARY_OBJECTS) \
	-Fu$(COMPRESSION_LIBRARY_OBJECTS) -Fu$(IMAGE_LIBRARY_OBJECTS) -Fi$(WEB_GENERATED)
$(FILES_PROGRAMS): $(WEBVIEW_LIBRARY) $(WEBIPC_LIBRARY) $(QUIC_LIBRARY) $(ARCHIVE_LIBRARY)
SSH_PROGRAMS := $(addprefix $(USER_PROGRAM_OUTPUT)/,sshd sftp-server ssh ssh-keygen ssh-add)
$(SSH_PROGRAMS): EXTRA_PROGRAM_LIBRARIES := -lssh
$(SSH_PROGRAMS): EXTRA_PROGRAM_UNITS := -Fu$(SSH_LIBRARY_OBJECTS)
$(SSH_PROGRAMS): $(SSH_LIBRARY)
# cssdump parses style sheets through libcss.
CSS_PROGRAMS := $(addprefix $(USER_PROGRAM_OUTPUT)/,cssdump)
$(CSS_PROGRAMS): EXTRA_PROGRAM_LIBRARIES := -lcss
$(CSS_PROGRAMS): EXTRA_PROGRAM_UNITS := -Fu$(CSS_LIBRARY_OBJECTS)
$(CSS_PROGRAMS): $(CSS_LIBRARY)

# The JavaScript shell runs scripts with libjavascript.
JAVASCRIPT_PROGRAMS := $(addprefix $(USER_PROGRAM_OUTPUT)/,js)
$(JAVASCRIPT_PROGRAMS): EXTRA_PROGRAM_LIBRARIES := -ljavascript
$(JAVASCRIPT_PROGRAMS): EXTRA_PROGRAM_UNITS := -Fu$(JAVASCRIPT_LIBRARY_OBJECTS)
$(JAVASCRIPT_PROGRAMS): $(JAVASCRIPT_LIBRARY)
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
# The clipboard tool: the clipboard (libwindowing, libcontrols' file
# lists) and images (libimage).
CLIPBOARD_PROGRAMS := $(addprefix $(USER_PROGRAM_OUTPUT)/,clipboard)
$(CLIPBOARD_PROGRAMS): EXTRA_PROGRAM_LIBRARIES := -lcontrols -lwindowing -lconfiguration -lfont -limage -lcompression \
	-ldrawing
$(CLIPBOARD_PROGRAMS): EXTRA_PROGRAM_UNITS := -Fu$(DRAWING_LIBRARY_OBJECTS) -Fu$(FONT_LIBRARY_OBJECTS) \
	-Fu$(CONFIGURATION_LIBRARY_OBJECTS) -Fu$(WINDOWING_LIBRARY_OBJECTS) -Fu$(CONTROLS_LIBRARY_OBJECTS) \
	-Fu$(COMPRESSION_LIBRARY_OBJECTS) -Fu$(IMAGE_LIBRARY_OBJECTS)
$(CLIPBOARD_PROGRAMS): $(CONTROLS_LIBRARY) $(IMAGE_LIBRARY)
# The system settings service keeps what it changes in the settings and
# sets the sound outputs.
SYSTEM_SETTINGS_PROGRAMS := $(addprefix $(USER_PROGRAM_OUTPUT)/,systemsettings)
$(SYSTEM_SETTINGS_PROGRAMS): EXTRA_PROGRAM_LIBRARIES := -laudio -lconfiguration
$(SYSTEM_SETTINGS_PROGRAMS): EXTRA_PROGRAM_UNITS := -Fu$(AUDIO_LIBRARY_OBJECTS) -Fu$(CONFIGURATION_LIBRARY_OBJECTS)
$(SYSTEM_SETTINGS_PROGRAMS): $(AUDIO_LIBRARY) $(CONFIGURATION_LIBRARY)
$(SOUND_PROGRAMS): EXTRA_PROGRAM_LIBRARIES := -laudio
$(SOUND_PROGRAMS): EXTRA_PROGRAM_UNITS := -Fu$(AUDIO_LIBRARY_OBJECTS)
$(SOUND_PROGRAMS): $(AUDIO_LIBRARY)

# Compiles program $* from $< (its other units in userland/$*) and links
# it as $@: a /bin program or a program folder's executable.
define BUILD_USER_PROGRAM
	@rm -rf $(USER_BUILD_DIRECTORY)/programs/$*
	@mkdir -p $(USER_BUILD_DIRECTORY)/programs/$* $(dir $@)
	$(TARGET_FPC) $(USER_FLAGS) -Fu$(RTL_USER_DIRECTORY) -Fu$(SYSTEM_LIBRARY_OBJECTS) -Fu$(CRYPTO_LIBRARY_OBJECTS) \
		-Fu$(CORE_LIBRARY_OBJECTS) $(EXTRA_PROGRAM_UNITS) -Fuuserland/$* \
		-FU$(USER_BUILD_DIRECTORY)/programs/$* -FE$(USER_BUILD_DIRECTORY)/programs/$* $<
	$(LD) -pie --no-dynamic-linker $(USER_LINK_FLAGS) -e _start -o $@ \
		$(USER_BUILD_DIRECTORY)/programs/$*/*.o $(RTL_USER_DIRECTORY)/si_prc.o \
		-L$(USER_LIBRARY_OUTPUT) $(EXTRA_PROGRAM_LIBRARIES) -lcoreutils -lcryptography -lsystem
endef

$(USER_PROGRAM_OUTPUT)/%: userland/bin/%.pas $(CORE_LIBRARY) $$(wildcard userland/$$*/*.pas)
	$(BUILD_USER_PROGRAM)

$(APP_PROGRAM_OUTPUT)/%: userland/$$*/$$*.pas $(CORE_LIBRARY) $$(wildcard userland/$$*/*.pas)
	$(BUILD_USER_PROGRAM)

# A program's folder as installed (/app/<name>). A copy of the program
# an older build left in /bin, before it had a folder, goes.
$(APP_OUTPUT)/%/.installed: $(APP_PROGRAM_OUTPUT)/% userland/%/program.info $$(wildcard userland/$$*/icons/*.ico)
	@rm -rf $(APP_OUTPUT)/$*
	@rm -f $(USER_PROGRAM_OUTPUT)/$*
	@mkdir -p $(APP_OUTPUT)/$*
	cp $(APP_PROGRAM_OUTPUT)/$* userland/$*/program.info $(APP_OUTPUT)/$*/
	@if [ -d userland/$*/icons ]; then mkdir -p $(APP_OUTPUT)/$*/icons; cp userland/$*/icons/*.ico $(APP_OUTPUT)/$*/icons/; fi
	@touch $@

# The native Free Pascal compiler, its units and configuration.
include toolchain/fpc/fpc.mk

# The system volume: an ext4 image labelled FPOSROOT.
system-disk: $(SYSTEM_DISK)

$(SYSTEM_DISK): userland $(NATIVE_FPC_SYSTEM_DISK_FILES) scripts/make-system-disk.sh $(wildcard userland/etc/*) $(wildcard userland/etc/*/*) \
		$(wildcard userland/etc/*/*/*) \
		$(wildcard userland/pointers/*) $(AUTHORIZED_KEYS)
	AUTHORIZED_KEYS="$(AUTHORIZED_KEYS)" NATIVE_FPC=$(NATIVE_FPC) scripts/make-system-disk.sh $(USER_BUILD_DIRECTORY) $@
