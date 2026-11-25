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

"""GNU autotools: ./configure --host=TRIPLET --prefix=PREFIX, make,
make DESTDIR=STAGE install. A tree without a configure script but with
configure.ac is bootstrapped with autoreconf first."""

import os

from .base import Builder
from ..toolchain import build_triplet
from ..autotools_target import prepare_tree


class AutotoolsBuilder(Builder):
    name = "autotools"
    host_tools = ("make",)

    def configure(self):
        context = self.context
        port = self.port
        script = os.path.join(context.configure_directory, port.configure_script)
        if not os.path.exists(script):
            if os.path.exists(os.path.join(context.configure_directory, "configure.ac")):
                context.run(["autoreconf", "-fi"], cwd=context.configure_directory)
            else:
                raise FileNotFoundError(f"{script} is missing (and there is no configure.ac)")
        # The package's config.sub and libtool learn the target.
        prepare_tree(context.configure_directory)
        self.ensure_build_tree()
        command = [
            script,
            f"--prefix={port.prefix}",
            f"--host={context.c_toolchain.triplet}",
            f"--build={build_triplet()}",
        ]
        # Autoconf's own option; other configure scripts (autosetup's)
        # refuse options they do not know.
        with open(script, encoding="utf-8", errors="replace") as stream:
            if "dependency-tracking" in stream.read():
                command.append("--disable-dependency-tracking")
        command += context.expand_all(port.configure_args)
        context.run(command, cwd=context.build_tree)

    def build(self):
        self.context.run(self.make_command(*self.context.expand_all(self.port.make_args)))

    def install(self):
        context = self.context
        command = ["make", f"DESTDIR={context.stage}", self.port.install_target]
        command += context.expand_all(self.port.make_args + self.port.install_args)
        context.run(command)
