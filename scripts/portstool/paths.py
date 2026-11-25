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

"""Where things are: the source tree, the ports tree, the build tree and
the cache of downloaded sources, and the names of the architectures."""

import os

SOURCE_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
PORTS_ROOT = os.path.join(SOURCE_ROOT, "ports")

# The build's names (ARCH=amd64|arm64) and the processor names packages,
# triplets and port.toml use.
ARCHITECTURES = {"amd64": "x86_64", "arm64": "aarch64"}
PROCESSORS = {processor: arch for arch, processor in ARCHITECTURES.items()}

# Ported software goes under /usr/local (see ports/README.md, "Prefix").
DEFAULT_PREFIX = "/usr/local"

# The installed packages' database on the system, as pkg keeps it.
PACKAGE_DATABASE = "var/db/pkg"


def processor_of(arch):
    """x86_64 for amd64, aarch64 for arm64 (either name accepted)."""
    if arch in ARCHITECTURES:
        return ARCHITECTURES[arch]
    if arch in PROCESSORS:
        return arch
    raise ValueError(f"unknown architecture {arch!r} (amd64 or arm64)")


def build_arch_of(arch):
    """amd64 for x86_64, arm64 for aarch64 (either name accepted)."""
    return PROCESSORS[processor_of(arch)]


def distfile_directory():
    """Downloaded sources are kept outside the tree and never committed."""
    return os.environ.get("DISTDIR") or os.path.join(os.path.expanduser("~"), "Downloads", "sources")


class BuildLayout:
    """The build tree of one architecture:

        build/ARCH/ports/NAME/      a port's work: source, build, stage
        build/ARCH/ports/packages/  the packages made
        build/ARCH/ports/logs/      a build log per port
        build/ARCH/ports/image-root the ports the system disk carries
    """

    def __init__(self, arch, build_root=None):
        self.arch = build_arch_of(arch)
        self.processor = processor_of(arch)
        self.build_root = build_root or os.path.join(SOURCE_ROOT, "build")
        self.root = os.path.join(self.build_root, self.arch, "ports")
        self.packages = os.path.join(self.root, "packages")
        self.logs = os.path.join(self.root, "logs")
        self.image_root = os.path.join(self.root, "image-root")
        self.user_build = os.path.join(self.build_root, self.arch, "user")
        self.toolchain_root = os.path.join(self.build_root, "toolchain")

    def work(self, port_name):
        return os.path.join(self.root, port_name)

    def log(self, port_name):
        return os.path.join(self.logs, port_name + ".log")
