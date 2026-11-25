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

"""CMake: a toolchain file made for the target, cmake -S -B, cmake
--build, cmake --install with DESTDIR. On a build machine without cmake
such ports are skipped (require() names what is missing)."""

import os

from .base import Builder
from ..toolchain import cmake_toolchain_file


class CmakeBuilder(Builder):
    name = "cmake"
    host_tools = ("cmake",)

    def configure(self):
        context = self.context
        os.makedirs(context.work, exist_ok=True)
        toolchain_file = cmake_toolchain_file(context.c_toolchain, context.sysroot,
                                              os.path.join(context.work, "cmake-toolchain.cmake"))
        command = [
            "cmake", "-S", context.configure_directory, "-B", context.build_tree,
            f"-DCMAKE_TOOLCHAIN_FILE={toolchain_file}", f"-DCMAKE_INSTALL_PREFIX={self.port.prefix}",
            "-DCMAKE_BUILD_TYPE=Release", "-DBUILD_SHARED_LIBS=OFF",
        ] + context.expand_all(self.port.configure_args)
        context.run(command, cwd=context.work)

    def build(self):
        jobs = self.context.jobs if self.port.parallel else 1
        self.context.run(["cmake", "--build", self.context.build_tree, "-j", str(jobs)]
                         + self.context.expand_all(self.port.make_args))

    def install(self):
        context = self.context
        environment_command = ["env", f"DESTDIR={context.stage}", "cmake", "--install", context.build_tree]
        context.run(environment_command + context.expand_all(self.port.install_args))
