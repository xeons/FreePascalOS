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

"""The compilers a port is built with.

C: the cross toolchain `make c-toolchain ARCH=...` builds (binutils and
GCC for TRIPLET = x86_64-freepascalos or aarch64-freepascalos, with
mlibc): build/toolchain/TRIPLET/bin/TRIPLET-gcc and the sysroot
build/sysroot/ARCH. A port that needs it is skipped while it is missing.

Pascal: the build machine's Free Pascal compiler (the AArch64 cross
compiler for arm64) with this system's runtime library, as
userland/userland.mk builds the system's own programs. The flags come
from the build itself (build/ARCH/user/ports-fpc.settings, written by
`make ports-fpc-settings`), so a port is compiled exactly as a /bin
program is.
"""

import os
import platform
import shlex
import shutil
import subprocess

from . import paths
from .portfile import PortError


class ToolchainMissing(PortError):
    """The port cannot be built on this machine yet (skipped, not failed)."""


C_TOOLS = {
    "CC": "gcc", "CXX": "g++", "CPP": "cpp", "AR": "ar", "AS": "as", "LD": "ld", "NM": "nm",
    "RANLIB": "ranlib", "STRIP": "strip", "OBJCOPY": "objcopy", "OBJDUMP": "objdump", "READELF": "readelf",
}


def triplet(processor):
    return f"{processor}-freepascalos"


def build_triplet():
    """The build machine's GNU triplet, for autotools' --build."""
    for compiler in ("cc", "gcc"):
        if shutil.which(compiler):
            result = subprocess.run([compiler, "-dumpmachine"], stdout=subprocess.PIPE, text=True)
            if result.returncode == 0 and result.stdout.strip():
                return result.stdout.strip()
    return f"{platform.machine()}-pc-linux-gnu"


class CToolchain:
    def __init__(self, layout):
        self.layout = layout
        self.processor = layout.processor
        self.triplet = triplet(self.processor)
        self.bin_directory = os.path.join(layout.toolchain_root, self.triplet, "bin")
        sysroot_base = os.path.join(layout.build_root, "sysroot")
        candidates = [os.path.join(sysroot_base, layout.arch), os.path.join(sysroot_base, self.processor)]
        self.base_sysroot = next((path for path in candidates if os.path.isdir(path)), candidates[0])

    def tool(self, name):
        return os.path.join(self.bin_directory, f"{self.triplet}-{name}")

    @property
    def available(self):
        return os.access(self.tool("gcc"), os.X_OK) and os.path.isdir(self.base_sysroot)

    def require(self):
        if not self.available:
            raise ToolchainMissing(
                f"the C toolchain for {self.triplet} is not built yet "
                f"({self.tool('gcc')}, sysroot {self.base_sysroot}; make c-toolchain ARCH={self.layout.arch})")

    def environment(self, sysroot):
        """CC, CFLAGS, PKG_CONFIG_* and the rest for a cross build against sysroot."""
        environment = {}
        for variable, name in C_TOOLS.items():
            environment[variable] = self.tool(name)
        flags = f"--sysroot={sysroot} -O2"
        environment["CFLAGS"] = flags
        environment["CXXFLAGS"] = flags
        environment["LDFLAGS"] = f"--sysroot={sysroot}"
        environment["PKG_CONFIG"] = shutil.which("pkg-config") or "pkg-config"
        environment["PKG_CONFIG_SYSROOT_DIR"] = sysroot
        environment["PKG_CONFIG_LIBDIR"] = ":".join(pkg_config_directories(sysroot))
        environment["PKG_CONFIG_PATH"] = ""
        return environment


def pkg_config_directories(sysroot):
    return [os.path.join(sysroot, part) for part in
            ("usr/local/lib/pkgconfig", "usr/local/share/pkgconfig", "usr/lib/pkgconfig", "usr/share/pkgconfig")]


def meson_cross_file(toolchain, sysroot, path):
    """Writes a meson cross file for the target and returns its path."""
    def quoted(value):
        return "'" + value.replace("\\", "\\\\").replace("'", "\\'") + "'"

    sysroot_flag = quoted(f"--sysroot={sysroot}")
    lines = [
        "[binaries]",
        f"c = {quoted(toolchain.tool('gcc'))}",
        f"cpp = {quoted(toolchain.tool('g++'))}",
        f"ar = {quoted(toolchain.tool('ar'))}",
        f"strip = {quoted(toolchain.tool('strip'))}",
        f"pkg-config = {quoted(shutil.which('pkg-config') or 'pkg-config')}",
        "",
        "[built-in options]",
        f"c_args = [{sysroot_flag}]",
        f"c_link_args = [{sysroot_flag}]",
        f"cpp_args = [{sysroot_flag}]",
        f"cpp_link_args = [{sysroot_flag}]",
        "",
        "[properties]",
        f"sys_root = {quoted(sysroot)}",
        f"pkg_config_libdir = [{', '.join(quoted(item) for item in pkg_config_directories(sysroot))}]",
        "",
        "[host_machine]",
        "system = 'freepascalos'",
        f"cpu_family = {quoted(toolchain.processor)}",
        f"cpu = {quoted(toolchain.processor)}",
        "endian = 'little'",
        "",
    ]
    with open(path, "w", encoding="utf-8") as stream:
        stream.write("\n".join(lines))
    return path


def cmake_toolchain_file(toolchain, sysroot, path):
    lines = [
        "set(CMAKE_SYSTEM_NAME FreePascalOS)",
        f"set(CMAKE_SYSTEM_PROCESSOR {toolchain.processor})",
        f'set(CMAKE_SYSROOT "{sysroot}")',
        f'set(CMAKE_C_COMPILER "{toolchain.tool("gcc")}")',
        f'set(CMAKE_CXX_COMPILER "{toolchain.tool("g++")}")',
        f'set(CMAKE_AR "{toolchain.tool("ar")}")',
        f'set(CMAKE_RANLIB "{toolchain.tool("ranlib")}")',
        f'set(CMAKE_STRIP "{toolchain.tool("strip")}")',
        f'set(CMAKE_FIND_ROOT_PATH "{sysroot}")',
        "set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)",
        "set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)",
        "set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)",
        "set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)",
        "",
    ]
    with open(path, "w", encoding="utf-8") as stream:
        stream.write("\n".join(lines))
    return path


class FpcSettings:
    """How the build compiles and links user programs, read from the
    settings file the Makefile writes (KEY=VALUE lines)."""

    KEYS = ("compiler", "flags", "rtl", "units", "libraries", "linker", "link_flags", "startup",
            "fpc_source", "strip")

    def __init__(self, values):
        self.values = values
        self.compiler = shlex.split(values["compiler"])
        self.flags = shlex.split(values["flags"])
        self.rtl = values["rtl"]
        self.units = values["units"]
        self.libraries = values["libraries"]
        self.linker = shlex.split(values["linker"])
        self.link_flags = shlex.split(values["link_flags"])
        self.startup = values["startup"]
        self.fpc_source = values["fpc_source"]
        self.strip = shlex.split(values.get("strip", "strip"))

    @staticmethod
    def path(layout):
        return os.path.join(layout.user_build, "ports-fpc.settings")

    @classmethod
    def load(cls, layout, make_if_missing=True):
        path = cls.path(layout)
        if not os.path.exists(path) and make_if_missing:
            subprocess.run(["make", "--no-print-directory", "-C", paths.SOURCE_ROOT, f"ARCH={layout.arch}",
                            "ports-fpc-settings"], check=False, stdout=subprocess.DEVNULL)
        if not os.path.exists(path):
            raise ToolchainMissing(f"{path} is missing: build the userland first (make userland ARCH={layout.arch})")
        values = {}
        with open(path, encoding="utf-8") as stream:
            for line in stream:
                key, separator, value = line.rstrip("\n").partition("=")
                if separator:
                    values[key] = value
        missing = [key for key in cls.KEYS if key not in values]
        if missing:
            raise PortError(f"{path}: missing {', '.join(missing)}")
        settings = cls(values)
        settings.require_built()
        return settings

    def require_built(self):
        startup = self.absolute(self.startup)
        if not os.path.exists(startup):
            raise ToolchainMissing(f"{startup} is missing: build the userland first (make userland)")

    @staticmethod
    def absolute(path):
        return path if os.path.isabs(path) else os.path.join(paths.SOURCE_ROOT, path)
