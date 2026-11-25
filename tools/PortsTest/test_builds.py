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

"""Whole builds through scripts/ports.py, in a ports tree and build tree
of the test's own: phases and cookies, a port rebuilt when it changes,
reproducible packages, the skip while the C toolchain is missing, cross
builds with a stand-in C toolchain (the build machine's gcc behind
x86_64-freepascalos-* names) for autotools and meson with the build
dependencies unpacked into the sysroot, install-to-image, repo and lint."""

import hashlib
import io
import os
import shutil
import subprocess
import sys
import tarfile
import unittest

import support
from portstool import database, ed25519, repository
from portstool.package import PackageReader

TOOL = os.path.join(support.SOURCE_ROOT, "scripts", "ports.py")
HAVE_GCC = shutil.which("gcc") is not None and shutil.which("make") is not None

CONFIGURE_SCRIPT = r"""#!/bin/sh
# A small configure that writes the Makefile, as autoconf's would.
prefix=/usr/local
host=
for argument; do
    case "$argument" in
        --prefix=*) prefix=${argument#--prefix=} ;;
        --host=*) host=${argument#--host=} ;;
        --build=*|--disable-dependency-tracking|--enable-*|--disable-*) ;;
        *) echo "unknown option $argument" >&2; exit 1 ;;
    esac
done
test -n "$host" || { echo "no --host" >&2; exit 1; }
srcdir=$(dirname "$0")
printf 'prefix = %s\nsrcdir = %s\nHOST = %s\n' "$prefix" "$srcdir" "$host" > Makefile
cat "$srcdir/Makefile.in" >> Makefile
"""

MAKEFILE_IN = """all: greet
greet: $(srcdir)/greet.c
\t$(CC) $(CFLAGS) $(CPPFLAGS) -o greet $(srcdir)/greet.c $(LDFLAGS)
install: greet
\tmkdir -p $(DESTDIR)$(prefix)/bin $(DESTDIR)$(prefix)/share/greet
\tcp greet $(DESTDIR)$(prefix)/bin/greet
\techo $(HOST) > $(DESTDIR)$(prefix)/share/greet/host
check: greet
\t./greet | grep -q hello
"""

GREET_C = '#include <stdio.h>\n#include "greeting.h"\nint main(void) { puts(GREETING); return 0; }\n'

MESON_BUILD = """project('mgreet', 'c')
executable('mgreet', 'mgreet.c', install: true)
"""

WRAPPER = """#!/bin/sh
# Stands in for a cross tool: the build machine's, without --sysroot
# (the test's sysroot has no C library), but with its include folders.
tool={tool}
arguments=
for argument; do
    case "$argument" in
        --sysroot=*) sysroot=${{argument#--sysroot=}} ;;
        *) set -- "$@" "$argument" ;;
    esac
    shift
done
if [ "$tool" = gcc ] && [ -n "$sysroot" ]; then
    set -- -I"$sysroot/usr/local/include" "$@"
fi
exec $tool "$@"
"""


class BuildTests(support.ScratchTestCase):
    def setUp(self):
        super().setUp()
        self.build_root = self.path("build")
        self.distdir = self.path("distfiles")
        os.makedirs(self.distdir)

    def ports(self, *arguments, expect=0):
        environment = dict(os.environ, DISTDIR=self.distdir)
        command = [sys.executable, "-I", TOOL, "--arch", "amd64", "--ports-root", self.path("ports"),
                   "--build-root", self.build_root, "--offline"] + list(arguments)
        result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, env=environment)
        if expect is not None:
            self.assertEqual(result.returncode, expect, result.stdout)
        return result.stdout

    def package_path(self, name, version="1.0"):
        return os.path.join(self.build_root, "amd64", "ports", "packages", f"{name}-{version}-x86_64.pkg.tar.zst")

    def distfile(self, name, files, top):
        buffer = io.BytesIO()
        with tarfile.open(fileobj=buffer, mode="w:gz") as archive:
            for relative, (text, mode) in sorted(files.items()):
                data = text.encode()
                info = tarfile.TarInfo(f"{top}/{relative}")
                info.size = len(data)
                info.mode = mode
                archive.addfile(info, io.BytesIO(data))
        data = buffer.getvalue()
        with open(os.path.join(self.distdir, name), "wb") as stream:
            stream.write(data)
        return hashlib.sha256(data).hexdigest()

    def fake_toolchain(self):
        bin_directory = os.path.join(self.build_root, "toolchain", "x86_64-freepascalos", "bin")
        os.makedirs(bin_directory)
        for name in ("gcc", "g++", "cpp", "ar", "as", "ld", "nm", "ranlib", "strip", "objcopy", "objdump", "readelf"):
            path = os.path.join(bin_directory, f"x86_64-freepascalos-{name}")
            with open(path, "w") as stream:
                stream.write(WRAPPER.format(tool=name))
            os.chmod(path, 0o755)
        sysroot = os.path.join(self.build_root, "sysroot", "amd64", "usr", "include")
        os.makedirs(sysroot)

    # --- ports without a compiler ------------------------------------

    def none_port(self, name="data", text="hello\n", extra=""):
        self.write(f"ports/misc/{name}/files/data.txt", text)
        self.write(f"ports/misc/{name}/files/LICENSE", "MIT\n")
        return support.port_toml(name, extra=f"""
            [port.dummy]
            """.replace("[port.dummy]", "") + f"""
            [install]
            files = [{{ from = "port:files/data.txt", to = "share/{name}/data.txt", mode = "0644" }}]
            """ + extra).replace('maintainer = "tests"', 'maintainer = "tests"\nlicense_files = ["port:files/LICENSE"]')

    def test_phases_cookies_and_rebuild(self):
        self.make_tree({"misc/data": self.none_port()})
        output = self.ports("patch", "data")
        self.assertIn("===> data: extract", output)
        self.assertNotIn("configure", output)
        output = self.ports("package", "data")
        self.assertNotIn("extract", output)
        self.assertIn("===> data: configure", output)
        reader = PackageReader(self.package_path("data"))
        self.assertEqual([entry.path for entry in reader.manifest.files],
                         ["usr/local/share/data/data.txt", "usr/local/share/licenses/data/LICENSE"])
        self.assertEqual(reader.manifest.license_files, ["usr/local/share/licenses/data/LICENSE"])
        reader.close()
        output = self.ports("package", "data")
        self.assertNotIn("stage", output)
        self.write("ports/misc/data/files/data.txt", "changed\n")
        output = self.ports("package", "data")
        self.assertIn("===> data: extract", output)
        reader = PackageReader(self.package_path("data"))
        self.assertEqual(reader.read("usr/local/share/data/data.txt"), b"changed\n")
        reader.close()
        log = os.path.join(self.build_root, "amd64", "ports", "logs", "data.log")
        self.assertTrue(os.path.exists(log))
        self.ports("clean", "data")
        self.assertFalse(os.path.exists(os.path.join(self.build_root, "amd64", "ports", "data")))

    def test_reproducible_and_custom_steps(self):
        extra = """
            [build.steps]
            post_install = ["ln -s data.txt ${STAGE}${PREFIX}/share/data/current", "echo ${NAME}-${VERSION}-${ARCH} > ${STAGE}${PREFIX}/share/data/id"]
            """
        self.make_tree({"misc/data": self.none_port(extra=extra)})
        self.ports("package", "data")
        with open(self.package_path("data"), "rb") as stream:
            first = stream.read()
        self.ports("clean", "data")
        self.ports("package", "data")
        with open(self.package_path("data"), "rb") as stream:
            self.assertEqual(stream.read(), first)
        reader = PackageReader(self.package_path("data"))
        self.assertEqual(reader.read("usr/local/share/data/id"), b"data-1.0-x86_64\n")
        self.assertEqual([(link.path, link.target) for link in reader.manifest.links],
                         [("usr/local/share/data/current", "data.txt")])
        reader.close()

    def test_outside_prefix_refused(self):
        extra = """
            [build.steps]
            post_install = ["mkdir -p ${STAGE}/etc && echo x > ${STAGE}/etc/evil"]
            """
        self.make_tree({"misc/data": self.none_port(extra=extra)})
        output = self.ports("package", "data", expect=1)
        self.assertIn("outside the prefix", output)

    def test_checksum_mismatch_refused(self):
        self.distfile("src-1.0.tar.gz", {"x": ("x", 0o644)}, "src-1.0")
        extra = f"""
            [[sources]]
            url = "https://example.invalid/src-1.0.tar.gz"
            sha256 = "{'0' * 64}"
            """
        self.make_tree({"misc/data": self.none_port(extra=extra)})
        output = self.ports("package", "data", expect=1)
        self.assertIn("SHA-256", output)

    def test_signature_checked(self):
        sha = self.distfile("src-1.0.tar.gz", {"x": ("x", 0o644)}, "src-1.0")
        secret = self.path("key")
        public = self.path("ports/misc/data/release.pub")
        os.makedirs(os.path.dirname(public), exist_ok=True)
        seed = ed25519.write_key_pair(secret, public)
        with open(os.path.join(self.distdir, "src-1.0.tar.gz"), "rb") as stream:
            data = stream.read()
        with open(os.path.join(self.distdir, "src-1.0.tar.gz.ed25519"), "w") as stream:
            stream.write(ed25519.sign(seed, data).hex() + "\n")
        extra = f"""
            [[sources]]
            url = "https://example.invalid/src-1.0.tar.gz"
            sha256 = "{sha}"
            extract_dir = "src-1.0"
            signature = {{ url = "https://example.invalid/src-1.0.tar.gz.ed25519", type = "ed25519", key = "release.pub" }}
            """
        self.make_tree({"misc/data": self.none_port(extra=extra)})
        self.assertIn("===> data: verify", self.ports("verify", "data"))
        with open(os.path.join(self.distdir, "src-1.0.tar.gz.ed25519"), "w") as stream:
            stream.write(ed25519.sign(seed, b"other").hex() + "\n")
        self.assertIn("bad Ed25519 signature", self.ports("verify", "data", expect=1))

    def test_c_port_skipped_without_toolchain(self):
        sha = self.distfile("greet-1.0.tar.gz", {"configure": (CONFIGURE_SCRIPT, 0o755)}, "greet-1.0")
        extra = f"""
            [[sources]]
            url = "https://example.invalid/greet-1.0.tar.gz"
            sha256 = "{sha}"
            extract_dir = "greet-1.0"
            """
        self.make_tree({"misc/greet": support.port_toml("greet", extra=extra, build='[build]\nsystem = "autotools"\n')})
        output = self.ports("package", "greet")
        self.assertIn("SKIP greet: the C toolchain for x86_64-freepascalos is not built yet", output)
        self.ports("package", "--strict", "greet", expect=2)
        self.assertIn("===> greet: patch", self.ports("patch", "greet"))

    def test_lint_and_listing(self):
        bad = support.port_toml("odd").replace('license = "MIT"', 'license = "Proprietary"')
        self.make_tree({"misc/data": self.none_port(), "misc/odd": bad})
        output = self.ports("lint", expect=1)
        self.assertIn("ERROR misc/odd: licence Proprietary is not on the allowlist", output)
        self.assertIn("lint: 1 error(s)", output)
        self.assertIn("data", self.ports("list"))
        self.assertIn("odd", self.ports("search", "odd"))
        self.ports("search", "nothing-like-it", expect=1)
        self.assertIn("Licence:       MIT", self.ports("info", "data"))

    # --- cross builds with a stand-in toolchain -----------------------

    def library_and_program(self, system):
        library_sha = self.distfile("greeting-1.0.tar.gz", {"greeting.h": ('#define GREETING "hello"\n', 0o644)},
                                    "greeting-1.0")
        library = support.port_toml("greeting", extra=f"""
            [[sources]]
            url = "https://example.invalid/greeting-1.0.tar.gz"
            sha256 = "{library_sha}"
            extract_dir = "greeting-1.0"

            [build.steps]
            install = ["mkdir -p ${{STAGE}}${{PREFIX}}/include", "cp greeting.h ${{STAGE}}${{PREFIX}}/include/"]
            """, build='[build]\nsystem = "custom"\ntoolchain = "c"\n')
        if system == "autotools":
            files = {"configure": (CONFIGURE_SCRIPT, 0o755), "Makefile.in": (MAKEFILE_IN, 0o644),
                     "greet.c": (GREET_C, 0o644)}
            name = "greet"
        else:
            files = {"meson.build": (MESON_BUILD, 0o644), "mgreet.c": (GREET_C, 0o644)}
            name = "mgreet"
        program_sha = self.distfile(f"{name}-1.0.tar.gz", files, f"{name}-1.0")
        program = support.port_toml(name, extra=f"""
            [[sources]]
            url = "https://example.invalid/{name}-1.0.tar.gz"
            sha256 = "{program_sha}"
            extract_dir = "{name}-1.0"

            [dependencies]
            build = ["greeting"]
            """, build=f'[build]\nsystem = "{system}"\n')
        self.make_tree({"devel/greeting": library.replace('"misc"', '"devel"'), f"misc/{name}": program})
        self.fake_toolchain()
        return name

    @unittest.skipUnless(HAVE_GCC, "gcc and make are needed")
    def test_autotools_cross_build(self):
        name = self.library_and_program("autotools")
        output = self.ports("package", name)
        self.assertIn("===> greeting: package", output)
        reader = PackageReader(self.package_path(name))
        self.assertEqual(reader.read("usr/local/share/greet/host"), b"x86_64-freepascalos\n")
        self.assertIn("usr/local/bin/greet", [entry.path for entry in reader.manifest.files])
        reader.close()
        work = os.path.join(self.build_root, "amd64", "ports", name)
        self.assertTrue(os.path.exists(os.path.join(work, "sysroot", "usr", "local", "include", "greeting.h")))
        with open(os.path.join(self.build_root, "amd64", "ports", "logs", f"{name}.log")) as stream:
            log = stream.read()
        self.assertIn("--host=x86_64-freepascalos", log)
        self.assertIn("--prefix=/usr/local", log)

    @unittest.skipUnless(HAVE_GCC and shutil.which("meson") and shutil.which("ninja"), "meson, ninja and gcc are needed")
    def test_meson_cross_build(self):
        name = self.library_and_program("meson")
        self.ports("package", name)
        reader = PackageReader(self.package_path(name))
        self.assertIn("usr/local/bin/mgreet", [entry.path for entry in reader.manifest.files])
        reader.close()
        cross_file = os.path.join(self.build_root, "amd64", "ports", name, "meson-cross.ini")
        with open(cross_file) as stream:
            text = stream.read()
        self.assertIn("system = 'freepascalos'", text)
        self.assertIn("x86_64-freepascalos-gcc", text)

    def test_cmake_missing_is_a_skip(self):
        if shutil.which("cmake"):
            self.skipTest("cmake is installed here")
        sha = self.distfile("c-1.0.tar.gz", {"CMakeLists.txt": ("project(c)\n", 0o644)}, "c-1.0")
        extra = f'[[sources]]\nurl = "https://example.invalid/c-1.0.tar.gz"\nsha256 = "{sha}"\n'
        self.make_tree({"misc/cm": support.port_toml("cm", extra=extra, build='[build]\nsystem = "cmake"\n')})
        self.fake_toolchain()
        self.assertIn("SKIP cm: needs cmake on the build machine", self.ports("package", "cm"))

    # --- images and repositories --------------------------------------

    def test_install_to_image_and_repo(self):
        app = self.none_port("app").replace("[install]", '[dependencies]\nrun = ["data>=1.0"]\n\n[install]')
        self.make_tree({"misc/data": self.none_port(), "misc/app": app})
        self.write("ports/image.list", "app\n")
        root = self.path("image-root")
        self.ports("install-to-image", "--root", root, "--list", self.path("ports/image.list"))
        self.assertEqual(sorted(database.installed_manifests(root)), ["app", "data"])
        self.assertTrue(os.path.exists(os.path.join(root, "usr/local/share/app/data.txt")))
        packages = os.path.join(self.build_root, "amd64", "ports", "packages")
        secret = self.path("repo.key")
        ed25519.write_key_pair(secret, self.path("repo.pub"))
        self.assertIn("2 package(s) (signed)", self.ports("repo", packages, "--key", secret))
        self.assertTrue(repository.verify_index(packages, self.path("repo.pub")))
        self.assertIn("data", self.ports("deps", "--order", "app"))
        self.write("ports/misc/data/port.toml",
                   open(self.path("ports/misc/data/port.toml")).read().replace('version = "1.0"', 'version = "1.1"'))
        self.assertIn("data                 1.0          < 1.1", self.ports("outdated", expect=1))
        self.assertIn("< 1.1", self.ports("outdated", "--root", root, expect=1))


if __name__ == "__main__":
    unittest.main()
