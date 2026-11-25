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

"""Custom steps: the port's [build.steps] configure, build and install
shell commands (install puts files under ${STAGE}${PREFIX}). "none"
builds nothing: [install] files places what the port ships."""

from .base import Builder


class CustomBuilder(Builder):
    name = "custom"

    def configure(self):
        self.ensure_build_tree()
        self.context.run_steps(self.port.steps.get("configure", []))

    def build(self):
        self.context.run_steps(self.port.steps.get("build", []))

    def install(self):
        self.context.run_steps(self.port.steps.get("install", []))


class NoBuilder(Builder):
    name = "none"

    def configure(self):
        self.ensure_build_tree()
