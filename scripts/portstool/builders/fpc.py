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

"""Free Pascal programs, compiled and linked as userland/userland.mk
builds the system's own: the build's compiler and USER_FLAGS, the
system's runtime library and the units of libsystem, libcryptography,
libcoreutils and the libraries the port names, then ld -pie with the
program start (si_prc.o) against those libraries. Units the port needs
from the Free Pascal sources (fpc_source_paths, e.g. fcl-base's CustApp)
are compiled into the program. Each program goes to PREFIX/bin unless
[install] files says otherwise."""

import glob
import os
import shutil

from .base import Builder

BASE_LIBRARIES = ("coreutils", "cryptography", "system")


class FpcBuilder(Builder):
    name = "fpc"

    def program_name(self, program):
        return program.get("name") or os.path.splitext(os.path.basename(program["source"]))[0]

    def object_directory(self, name):
        return os.path.join(self.context.work, "objects", name)

    def build(self):
        context = self.context
        settings = context.fpc_settings
        port_fpc = self.port.fpc
        libraries = list(port_fpc.get("libraries", []))
        source = context.configure_directory
        self.ensure_build_tree()
        for program in port_fpc["programs"]:
            name = self.program_name(program)
            objects = self.object_directory(name)
            shutil.rmtree(objects, ignore_errors=True)
            os.makedirs(objects)
            command = list(settings.compiler) + list(settings.flags)
            command.append("-Fu" + settings.absolute(settings.rtl))
            for library in ("system", "cryptography", "coreutils") + tuple(libraries):
                command.append("-Fu" + os.path.join(settings.absolute(settings.units), library))
            for path in port_fpc.get("search_paths", []):
                command.append("-Fu" + self.port.resolve_port_path(context.expand(path), source))
            for path in port_fpc.get("fpc_source_paths", []):
                command.append("-Fu" + os.path.join(settings.fpc_source, path))
                command.append("-Fi" + os.path.join(settings.fpc_source, path))
            for path in port_fpc.get("include_paths", []):
                command.append("-Fi" + self.port.resolve_port_path(context.expand(path), source))
            command += ["-d" + define for define in port_fpc.get("defines", [])]
            command += context.expand_all(port_fpc.get("flags", []))
            command += ["-FU" + objects, "-FE" + objects, self.port.resolve_port_path(program["source"], source)]
            context.run(command, cwd=context.source_root)

            output = os.path.join(context.build_tree, name)
            link = list(settings.linker) + ["-pie", "--no-dynamic-linker"] + list(settings.link_flags)
            link += ["-e", "_start", "-o", output]
            link += sorted(glob.glob(os.path.join(objects, "*.o")))
            link.append(settings.absolute(settings.startup))
            link.append("-L" + settings.absolute(settings.libraries))
            link += ["-l" + library for library in libraries + list(BASE_LIBRARIES)]
            context.run(link, cwd=context.source_root)

    def install(self):
        if self.port.install_files:
            return
        context = self.context
        target = os.path.join(context.prefix_in_stage(), "bin")
        os.makedirs(target, exist_ok=True)
        for program in self.port.fpc["programs"]:
            name = self.program_name(program)
            shutil.copy2(os.path.join(context.build_tree, name), os.path.join(target, name))
            os.chmod(os.path.join(target, name), 0o755)
