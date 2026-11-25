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

"""A plain Makefile: no configure step; make with CC and friends from
the environment (and PREFIX), make DESTDIR=STAGE PREFIX=PREFIX install."""

from .base import Builder


class MakeBuilder(Builder):
    name = "make"
    host_tools = ("make",)

    def common_arguments(self):
        context = self.context
        arguments = [f"PREFIX={self.port.prefix}"]
        if self.port.toolchain == "c":
            environment = context.c_toolchain.environment(context.sysroot)
            for variable in ("CC", "AR", "RANLIB", "STRIP"):
                arguments.append(f"{variable}={environment[variable]}")
        return arguments + context.expand_all(self.port.make_args)

    def build(self):
        self.context.run(self.make_command(*self.common_arguments()))

    def install(self):
        context = self.context
        command = ["make", f"DESTDIR={context.stage}"] + self.common_arguments()
        command += [self.port.install_target] + context.expand_all(self.port.install_args)
        context.run(command)
