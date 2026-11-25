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

"""What every build system does: configure, build, install into the
stage (DESTDIR), with the port's pre_configure and post_install steps
around them. Each build system is a class in this package."""

import os
import shutil

from ..toolchain import ToolchainMissing


class Builder:
    name = "none"
    host_tools = ()

    def __init__(self, context):
        self.context = context
        self.port = context.port

    def require(self):
        """Raises ToolchainMissing when this machine cannot build the port."""
        missing = [tool for tool in list(self.host_tools) + self.port.host_tools if shutil.which(tool) is None]
        if missing:
            raise ToolchainMissing(f"needs {', '.join(missing)} on the build machine, which is not installed")
        if self.port.toolchain == "c":
            self.context.c_toolchain.require()
        elif self.port.toolchain == "fpc":
            self.context.fpc_settings.require_built()

    def configure(self):
        pass

    def build(self):
        pass

    def install(self):
        pass

    def make_command(self, *arguments):
        jobs = self.context.jobs if self.port.parallel else 1
        return ["make", f"-j{jobs}"] + list(arguments)

    def ensure_build_tree(self):
        os.makedirs(self.context.build_tree, exist_ok=True)
