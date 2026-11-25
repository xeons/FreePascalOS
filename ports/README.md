# The ports tree

Software from elsewhere, built for FreePascalOS the way FreeBSD's ports
build it for FreeBSD: each port is a folder with a description of where
the sources come from and how to build them (`port.toml`), the patches
that make them work here (`patches/`) and any files of its own
(`files/`). `scripts/ports.py` fetches, checks, unpacks, patches,
configures, builds and stages a port, and makes a package of it; `pkg`
installs packages on the system.

```
ports/
  README.md            this file
  port.schema.json     port.toml's format as a JSON Schema (lint checks it)
  licenses.txt         the licences a port may have (SPDX identifiers)
  image.list           the ports the system disk carries installed
  ports.mk             make ports, make port-NAME, ... (included by the Makefile)
  CATEGORY/NAME/
    port.toml          the port
    patches/*.patch    applied in order (see "Patches")
    files/             files of the port's own (port:files/...)
    *.gpg, *.pub       keys its sources' signatures are checked with
```

The ports so far:

| Port | Version | Build | Status |
|------|---------|-------|--------|
| misc/hello | 1.0 | fpc, from `files/` | tested; on the system disk |
| misc/pkg-selftest | 1.0 | none | tested; the package coretest installs |
| devel/ptop | 3.2.2 | fpc, from the Free Pascal source release, one patch | tested (x86-64) |
| archivers/zlib | 1.4 | custom (zlib's own configure), signed source | untested |
| lang/lua | 5.4.9 | custom (Lua's Makefile) | untested |
| databases/sqlite3 | 3.54.1 | autotools (autosetup), options and a flavour | untested |
| shells/bash | 5.3 | autotools, signed source | untested |

"untested" ports are committed but have not been built and run on the
system yet: the C ports wait for the C toolchain (below) and are skipped
until it exists.

## The prefix: /usr/local

Ported software installs under **/usr/local** (`bin`, `lib`, `include`,
`share`, `etc`, ...), as on FreeBSD, and never outside it (staging
refuses a port that tries). The reasons:

- The base system owns `/bin`, `/lib`, `/app` and `/etc`, and is built
  and replaced as a whole (the system disk image). Keeping packages out
  of those folders means no package can overwrite or break a base
  program or library, and replacing the base never touches packages.
- Removing all ported software is removing `/usr/local` and
  `/var/db/pkg`; what is ported and what is the system's own is visible
  from the path.
- It is every build system's default prefix (autoconf, meson, cmake,
  most Makefiles), so ports need fewer configure arguments and patches.
- `/opt/NAME` per package would need a PATH entry per package, `/usr`
  would mix packages with whatever the system grows there later.

`/usr/local/bin` is on every default PATH (the kernel's first process,
the shell, logins, services), and the program loader looks for shared
libraries in `/usr/local/lib` after `/lib` (a library a program needs,
and LoadLibrary of a bare name).

## port.toml

TOML, checked against `port.schema.json` (`scripts/ports.py lint`).
Required: `[port]` (name, version, summary, description, homepage,
license, maintainer, categories) and `[build]` (system).

```toml
[port]
name = "sqlite3"                 # the package's name: a-z 0-9 + . _ -
version = "3.54.1"               # upstream's; no '-' or '_'
revision = 0                     # the port's own changes to that version
summary = "One line"
description = """Paragraphs."""
homepage = "https://www.sqlite.org/"
license = "blessing"             # an SPDX expression: MIT OR (GPL-2.0-or-later WITH GCC-exception-3.1)
license_files = ["LICENSE"]      # in the source tree, or port:files/...; installed as share/licenses/NAME/
maintainer = "FreePascalOS ports"
categories = ["databases"]       # the first is the folder the port is in
status = "untested"              # tested | untested | broken
architectures = ["x86_64", "aarch64"]
conflicts = []                   # packages that cannot be installed with it
notes = "anything worth knowing"

[[sources]]                      # none, one or several
url = "https://www.sqlite.org/2026/sqlite-autoconf-3540100.tar.gz"
mirrors = ["https://..."]        # tried in order when the URL fails
filename = "..."                 # default: the URL's last part
sha256 = "926ef8d3..."           # required; the file is never used otherwise
size = 3332984                   # optional, checked too
extract = true                   # false: copied, not unpacked
extract_dir = "sqlite-autoconf-3540100"   # first source: the folder it unpacks to (the
                                 # source tree); later ones: where to unpack them
signature = { url = "https://.../x.tar.gz.sig", type = "gpg", key = "upstream.gpg" }
                                 # gpg: a keyring in the port's folder (gpgv checks);
                                 # ed25519: a "ed25519 HEX" key file, the signature file in hex

[dependencies]
build = ["zlib>=1.3"]            # ports whose packages are unpacked into the build's sysroot
run = ["hello"]                  # recorded in the package; pkg needs them installed
host = ["make", "bison"]         # programs the build machine must have
provides = ["libsqlite3"]        # other names this port answers to in dependencies

[build]
system = "autotools"             # autotools | meson | cmake | make | fpc | custom | none
toolchain = "c"                  # c | fpc | none (default from the system)
directory = "."                  # where the build system's input is, in the source tree
out_of_tree = false              # build in a folder of its own (default for meson and cmake)
parallel = true                  # make -jN
configure_script = "configure"
configure_args = ["--disable-shared"]
make_args = []
install_args = []
install_target = "install"
environment = { CFLAGS = "-O2 -g" }

[build.fpc]                      # system = "fpc"
programs = [{ source = "utils/ptop.pp", name = "ptop" }]
search_paths = ["utils"]         # -Fu, relative to the source tree (or port:files/...)
include_paths = []               # -Fi
fpc_source_paths = []            # folders of the build machine's Free Pascal sources
libraries = ["http", "tls"]      # system libraries beyond system, cryptography, coreutils
flags = []
defines = []

[build.steps]                    # shell commands (/bin/sh -e), ${VARIABLES} expanded
pre_configure = []               # before any build system's configure
configure = []                   # custom only
build = []                       # custom only
install = []                     # custom (required): into ${STAGE}${PREFIX}
post_install = []                # after any build system's install

[install]
prefix = "/usr/local"
files = [{ from = "port:files/x.conf", to = "etc/x.conf", mode = "0644" }]
                                 # from: the build folder, or port:...; to: under the prefix
                                 # (or absolute; still inside the prefix)
docs = ["README"]                # into share/doc/NAME/
remove = ["share/info/*"]        # patterns under the prefix deleted from the stage
strip = true                     # strip ELF programs and libraries
scripts = { post_install = "files/post-install.sh" }
                                 # pre_install, post_install, pre_remove, post_remove:
                                 # /bin/sh scripts pkg runs (PKG_NAME, PKG_VERSION,
                                 # PKG_ROOT, PKG_PREFIX set)

[options.fts5]                   # build-time choices, on or off
description = "FTS5 full-text search"
default = true
configure_on = ["--fts5"]        # also configure_off, make_on, make_off,
                                 # build_dependencies, run_dependencies

[flavors.minimal]                # the same port built differently, as another package
summary = "..."
suffix = "-minimal"              # default "-" + the flavour's name: sqlite3-minimal
options = { fts5 = false }

[patches]
strip = 1                        # patch -pN
order = ["first.patch"]          # these first; the rest of patches/*.patch by name

[test]
commands = ["make check"]        # on the build machine, in the build folder (ports.py test)
system = ["sqlite3 --version"]   # on the system: recorded in the package (pkg test NAME)
```

Variables in arguments, environments and steps: `${PREFIX}` `${STAGE}`
(the DESTDIR) `${SOURCE}` `${BUILD}` `${WORK}` `${SYSROOT}` `${TRIPLET}`
`${ARCH}` (x86_64, aarch64) `${JOBS}` `${PORT}` `${FILES}` `${NAME}`
`${VERSION}`. A port's name with a flavour is `NAME@FLAVOUR` on the
command line (`scripts/ports.py package sqlite3@minimal`); options are
set with `-o NAME=on|off`.

## Building

Each port goes through FreeBSD's phases; asking for one runs every
phase before it that has not run (cookies in the work folder), and a
port whose files changed starts again from extract:

| Phase | What happens |
|-------|--------------|
| fetch | each distfile into the cache (`DISTDIR`, default `~/Downloads/sources`), from its URL or mirrors |
| verify | SHA-256 (and size) against port.toml; the signature if there is one |
| extract | a clean work folder; archives unpacked (tar, .gz, .bz2, .xz, .zst, zip; nothing outside the target) |
| patch | `patches/*.patch` in order with `patch -pSTRIP`; a reject fails |
| configure | the sysroot made; pre_configure; the build system's configure |
| build | make, meson compile, ... |
| stage | install into the stage (DESTDIR), then [install] files, docs and licences, removals, strip, checks |
| package | the package (below) into `build/ARCH/ports/packages/` |

Building a port builds the packages of its build dependencies first.

**C (autotools, meson, cmake, make).** With the cross toolchain `make
c-toolchain ARCH=...` builds: `build/toolchain/TRIPLET/bin/TRIPLET-gcc`
(TRIPLET = x86_64-freepascalos or aarch64-freepascalos) and the sysroot
`build/sysroot/ARCH` (mlibc). Each port gets a sysroot of its own: the
toolchain's (hard links), with the packages of its build dependencies
unpacked into it. The environment has CC, CXX, AR, RANLIB, STRIP and
the rest, `CFLAGS=--sysroot=... -O2`, and pkg-config pointed at the
sysroot (`PKG_CONFIG_SYSROOT_DIR`, `PKG_CONFIG_LIBDIR` of its
`usr/local/lib/pkgconfig` and `usr/lib/pkgconfig`). autotools runs
`configure --prefix=/usr/local --host=TRIPLET --build=...`
(`--disable-dependency-tracking` when the script is autoconf's), then
`make` and `make DESTDIR=STAGE install`; a tree with only configure.ac
is bootstrapped with autoreconf. meson gets a cross file
(`WORK/meson-cross.ini`: the compilers, `--sysroot`, pkg-config's
folders, `host_machine` system freepascalos) and `--wrap-mode=nodownload
-Ddefault_library=static`. cmake gets a toolchain file
(`CMAKE_SYSTEM_NAME FreePascalOS`, `CMAKE_SYSROOT`, find modes); on a
build machine without cmake, cmake ports are skipped. make gets
CC, AR, RANLIB, STRIP and PREFIX on its command line.

**While the C toolchain is missing** every port that needs it is
skipped: `SKIP NAME: the C toolchain for TRIPLET is not built yet`, exit
status 0 (2 with `--strict`); fetch, verify, extract and patch still
work, so ports and patches can be written before the toolchain lands.

**Pascal (fpc).** The build machine's Free Pascal compiler (the AArch64
cross compiler for arm64) with this system's runtime library, exactly as
userland/userland.mk builds a /bin program: USER_FLAGS, the RTL, the
units of libsystem, libcryptography, libcoreutils and the port's
`libraries`, then `ld -pie` with `si_prc.o` against those libraries.
The flags come from the build (`build/ARCH/user/ports-fpc.settings`,
written by `make ports-fpc-settings`), so `make userland` comes first.
Units the port needs from the Free Pascal sources (`search_paths` into
its own source tree, or `fpc_source_paths` into the build machine's)
are compiled into the program; each program goes to PREFIX/bin.

**Reproducible.** The environment holds only PATH and what the build
sets (`LC_ALL=C`, `TZ=UTC`, HOME and TMPDIR in the work folder, umask
022, `SOURCE_DATE_EPOCH` = the time of the port's last commit); the
stage is made afresh, permissions normalized (no group or other write,
no set-id bits) and every time set to `SOURCE_DATE_EPOCH`; the package's
members are sorted, owned by 0:0 and compressed at a fixed level. The
same port at the same commit gives the same package, byte for byte.
Each port's build log is `build/ARCH/ports/logs/NAME.log` (the terminal
shows one line a phase; `-v` shows everything).

## Patches and makepatch

`patches/*.patch` are unified diffs applied in order: `[patches] order`
first, then the rest by name, with `patch -pSTRIP` (default 1).

The FreeBSD `make makepatch` workflow:

```sh
scripts/ports.py patch lua                    # unpacked and patched, in build/amd64/ports/lua/work/
$EDITOR build/amd64/ports/lua/work/lua-5.4.9/src/loslib.c
scripts/ports.py makepatch lua                # writes ports/lang/lua/patches/patch-src_loslib.c.patch
scripts/ports.py makepatch lua --add src/new.c    # a new file too
scripts/ports.py build lua                    # the port changed: built again from extract
```

makepatch unpacks the sources again (without patches) beside the work
tree and writes one `-p1` patch per file that differs, named after its
path (`patch-src_loslib.c.patch`). Files the build made are not
compared (only files of the original sources, and new files named with
`--add`). The patches it replaces are kept in
`build/ARCH/ports/NAME/patches-before-makepatch/`. Binary changes are
refused.

## Commands

```
scripts/ports.py [--arch amd64|arm64] [-v] [-j N] [--offline] [-o NAME=on|off] COMMAND ...

  fetch | verify | extract | patch | configure | build | stage | package  PORT...
                     run up to that phase (-r: also package run dependencies,
                     -k: keep going, --strict: a skip fails, --reuse-packages)
  test PORT...       [test] commands after building
  clean PORT... | --all
  install-to-image --root DIR [--list FILE] [PORT...]
                     packages (and their run dependencies) installed under DIR,
                     recorded in DIR/var/db/pkg
  info PORT...       everything about a port
  deps PORT... [--build|--run] [--dot|--order]
                     the dependency graph (Graphviz with --dot) and build order
  list [--category C] [--status S]
  search WORD...
  outdated [--root DIR]
                     packages built (or installed under DIR) older than their ports
  makepatch PORT [--add PATH]...
  makesum PORT       the SHA-256 and size of a port's distfiles, for port.toml
  lint [PORT...]     schema, licence, files, patches, dependencies
  repo DIR [--name N] [--key SECRET]
                     INDEX (and INDEX.sig) for a folder of packages
  keygen SECRET PUBLIC
                     an Ed25519 key pair for signing repositories
```

PORT is a name, `NAME@FLAVOUR`, `CATEGORY/NAME` or a folder.

Make targets (ports/ports.mk): `make ports PORTS="ptop zlib"`, `make
port-ptop`, `make ports-lint`, `make ports-repo` (`PORTS_SIGNING_KEY=`
signs it), `make ports-image`, `make ports-test` and `make pkg-test`.
All of them take `ARCH=arm64`.

**Why Python.** The tool runs on the build machine and drives the build
machine's tools (patch, make, meson, gpgv, the compilers), as the other
build scripts in scripts/ do; Python's standard library has what it
needs (TOML, tar with gzip, bzip2, xz and Zstandard, zip, HTTP,
SHA-256), so it needs nothing installed. What runs on the system - pkg -
is Pascal.

## Packages

`NAME-VERSION[_REVISION]-ARCH.pkg.tar.zst`: a POSIX tar archive
compressed with Zstandard, holding in this order

```
+MANIFEST          what the package is, and every path it installs
+DESC              the description
+pre-install ...   the scripts the manifest names
usr/local/...      folders first, then files and links, sorted
```

The manifest (`scripts/portstool/manifest.py`, read on the system by
`userland/pkg/Pkg.Manifests.pas`) is a line each:

```
format 1
name ptop
version 3.2.2
revision 0
origin devel/ptop
architecture x86_64
prefix /usr/local
summary Pascal source code formatter from Free Pascal
license LGPL-2.1-or-later
maintainer FreePascalOS ports
homepage https://www.freepascal.org/
depend NAME [OP VERSION]        each run dependency
provide NAME                    conflict NAME
script post-install             test COMMAND
license-file usr/local/share/licenses/ptop/COPYING.FPC
dir 0755 usr/local/share/licenses/ptop
file 0755 105184 9f2c...e1 usr/local/bin/ptop
link usr/local/lib/libz.so libz.so.1
```

Paths are relative to the root and hold no spaces. Licence texts are
part of the payload (`share/licenses/NAME/`), so they stay on the
system with the software. Versions compare part by part (numbers as
numbers, alpha/beta/pre/rc before the release, the revision last) the
same way in Python and Pascal.

## Repositories

A repository is a folder of packages with an `INDEX` (a block per
package: name, version, revision, architecture, dependencies, file
name, size, SHA-256) and `INDEX.sig` (`ed25519 HEX`, the signature of
INDEX's bytes), served over HTTP or HTTPS:

```sh
scripts/ports.py keygen repo.key repo.pub          # once; keep repo.key private
make ports PORTS="ptop sqlite3"
make ports-repo PORTS_SIGNING_KEY=repo.key         # build/amd64/ports/packages/INDEX{,.sig}
```

On the system, `/etc/pkg/keys/NAME.pub` holds repo.pub and
`/etc/pkg/repositories` a line `NAME URL`; `pkg update` fetches and
checks the index, `pkg install NAME` fetches packages (each checked
against the index's size and SHA-256) with what they need.

## The system disk

`ports/image.list` names the ports the system disk carries installed.
`make system-disk` builds their packages (and their run dependencies),
installs them into `build/ARCH/ports/image-root` with `install-to-image`
(recorded in its `/var/db/pkg`, so pkg lists, verifies and removes them
like any other package; their install scripts are not run), adds the
package coretest installs (`/var/cache/pkg/pkg-selftest-*.pkg.tar.zst`),
and `scripts/make-system-disk.sh` copies the folder onto the disk.

## pkg

```
pkg [-r ROOT] install [-f] [-A] FILE|NAME...   remove [-f] NAME...
              info [-l] [NAME|FILE]...  list [-q]  which FILE...  verify [NAME]...
              search WORD...  update  upgrade [NAME]...  test NAME...
```

docs/Architecture.md ("Ports and packages") describes how it installs:
every check before anything is touched, files staged beside their
places and renamed in, everything undone on failure.

## Adding a port

1. `ports/CATEGORY/NAME/port.toml` with the required keys; the licence
   must be on `licenses.txt` (add one only after reading it).
2. A source URL and `scripts/ports.py makesum NAME` for its SHA-256 and
   size; check the file against upstream's published checksum or
   signature (and add the signature with its key when there is one).
3. `scripts/ports.py patch NAME`, edit the work tree, `makepatch NAME`;
   `scripts/ports.py package NAME`, read `build/ARCH/ports/logs/NAME.log`.
4. `[test] system` lines that show it works; try it on the system
   (`pkg install /path/to/NAME-...pkg.tar.zst`, `pkg test NAME`); set
   `status = "tested"` only then.
5. `scripts/ports.py lint NAME`.

## Tests

`make ports-test` runs `tools/PortsTest/` (Python unittest): port.toml
and the schema, licences, versions and dependencies, the resolver,
extraction, patches and makepatch, manifests, packages (layout,
reproducibility, damage found), install-to-image, repositories,
Ed25519 against RFC 8032 and OpenSSL, and whole builds through
`scripts/ports.py` in a ports tree and build tree of their own
(including autotools, meson and cmake cross builds with a stand-in toolchain,
the build machine's gcc behind x86_64-freepascalos names). `make
pkg-test` runs pkg's units on the host over packages and an index the
ports tool made (`tools/PkgTest`). coretest installs pkg-selftest on
the system, checks it, verifies it and removes it.
