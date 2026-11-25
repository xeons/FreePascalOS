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

"""Meson: a cross file made for the target (compilers, sysroot,
pkg-config's directories, host_machine), meson setup, meson compile,
meson install --destdir STAGE. Subprojects are never downloaded."""

import os

from .base import Builder
from ..toolchain import meson_cross_file


class MesonBuilder(Builder):
    name = "meson"
    host_tools = ("meson", "ninja")

    def configure(self):
        context = self.context
        os.makedirs(context.work, exist_ok=True)
        cross_file = meson_cross_file(context.c_toolchain, context.sysroot,
                                      os.path.join(context.work, "meson-cross.ini"))
        command = [
            "meson", "setup", "--cross-file", cross_file, f"--prefix={self.port.prefix}",
            "--buildtype=release", "--wrap-mode=nodownload", "-Ddefault_library=static",
            context.build_tree, context.configure_directory,
        ] + context.expand_all(self.port.configure_args)
        context.run(command, cwd=context.work)

    def build(self):
        jobs = self.context.jobs if self.port.parallel else 1
        self.context.run(["meson", "compile", "-C", self.context.build_tree, f"-j{jobs}"]
                         + self.context.expand_all(self.port.make_args))

    def install(self):
        context = self.context
        context.run(["meson", "install", "-C", context.build_tree, "--destdir", context.stage, "--no-rebuild"]
                    + context.expand_all(self.port.install_args))
