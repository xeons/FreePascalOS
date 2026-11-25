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

"""What a port's build needs at hand: its folders, the toolchain, a
clean environment and the ${VARIABLES} port.toml may use.

The environment is made from nothing but PATH: LC_ALL=C, TZ=UTC, umask
022, HOME and TMPDIR inside the work folder and SOURCE_DATE_EPOCH (the
time of the port's last commit, else 1), so two builds of the same port
give the same files. Variables: ${PREFIX} ${STAGE} (the DESTDIR)
${SOURCE} ${BUILD} ${WORK} ${SYSROOT} ${TRIPLET} ${ARCH} ${JOBS} ${PORT}
${FILES} ${NAME} ${VERSION}.
"""

import os
import re
import subprocess

from . import paths
from .portfile import PortError
from .toolchain import CToolchain, FpcSettings

_VARIABLE = re.compile(r"\$\{([A-Z_]+)\}")


def source_date_epoch(port):
    """The time of the last commit that touched the port, else 1."""
    try:
        result = subprocess.run(["git", "-C", port.directory, "log", "-1", "--format=%ct", "--", "."],
                                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
        if result.returncode == 0 and result.stdout.strip().isdigit():
            return int(result.stdout.strip())
    except OSError:
        pass
    return 1


class BuildContext:
    def __init__(self, port, layout, log, jobs=None):
        self.port = port
        self.layout = layout
        self.log = log
        self.jobs = jobs or os.cpu_count() or 1
        self.work = layout.work(port.name)
        self.cookies = os.path.join(self.work, ".cookies")
        self.extract_directory = os.path.join(self.work, "work")
        self.stage = os.path.join(self.work, "stage")
        self.sysroot = os.path.join(self.work, "sysroot")
        self.home = os.path.join(self.work, "home")
        self.temporary = os.path.join(self.work, "tmp")
        self.epoch = source_date_epoch(port)
        self.c_toolchain = CToolchain(layout)
        self._fpc_settings = None

    # The source tree is wherever extract put it; remembered in a file
    # so the later phases (run separately) find it.
    @property
    def source_tree(self):
        marker = os.path.join(self.cookies, "source-tree")
        if os.path.exists(marker):
            with open(marker, encoding="utf-8") as stream:
                return stream.read().strip()
        raise PortError(f"{self.port.name}: not extracted yet")

    def remember_source_tree(self, path):
        os.makedirs(self.cookies, exist_ok=True)
        with open(os.path.join(self.cookies, "source-tree"), "w", encoding="utf-8") as stream:
            stream.write(path + "\n")

    @property
    def configure_directory(self):
        """Where the build system's input is: the source tree's [build] directory."""
        return os.path.normpath(os.path.join(self.source_tree, self.port.build_directory))

    @property
    def build_tree(self):
        """Where it builds: a folder of its own when out of tree."""
        if self.port.out_of_tree:
            return os.path.join(self.work, "build")
        return self.configure_directory

    @property
    def fpc_settings(self):
        if self._fpc_settings is None:
            self._fpc_settings = FpcSettings.load(self.layout)
        return self._fpc_settings

    def variables(self):
        values = {
            "PREFIX": self.port.prefix,
            "STAGE": self.stage,
            "WORK": self.work,
            "SYSROOT": self.sysroot,
            "TRIPLET": self.c_toolchain.triplet,
            "ARCH": self.layout.processor,
            "JOBS": str(self.jobs if self.port.parallel else 1),
            "PORT": self.port.directory,
            "FILES": self.port.files_directory,
            "NAME": self.port.name,
            "VERSION": self.port.version,
        }
        try:
            values["SOURCE"] = self.source_tree
            values["BUILD"] = self.build_tree
        except PortError:
            pass
        return values

    def expand(self, text):
        values = self.variables()

        def replace(match):
            name = match.group(1)
            if name not in values:
                raise PortError(f"{self.port.origin}: unknown variable ${{{name}}} in {text!r}")
            return values[name]

        return _VARIABLE.sub(replace, text)

    def expand_all(self, items):
        return [self.expand(item) for item in items]

    def environment(self):
        os.makedirs(self.home, exist_ok=True)
        os.makedirs(self.temporary, exist_ok=True)
        search_path = os.environ.get("PATH", "/usr/bin:/bin")
        if self.port.toolchain == "c":
            search_path = self.c_toolchain.bin_directory + os.pathsep + search_path
        environment = {
            "PATH": search_path,
            "HOME": self.home,
            "TMPDIR": self.temporary,
            "LC_ALL": "C",
            "LANG": "C",
            "TZ": "UTC",
            "SOURCE_DATE_EPOCH": str(self.epoch),
            "SHELL": "/bin/sh",
        }
        if self.port.toolchain == "c":
            environment.update(self.c_toolchain.environment(self.sysroot))
        for key, value in self.port.environment.items():
            environment[key] = self.expand(value)
        return environment

    def run(self, command, cwd=None, shell=False):
        os.umask(0o022)
        self.log.run(command, cwd or self.build_tree, self.environment(), shell=shell)

    def run_steps(self, steps, cwd=None):
        """Shell commands from port.toml, ${VARIABLES} expanded, run by /bin/sh."""
        for step in steps:
            self.run(["/bin/sh", "-ec", self.expand(step)], cwd=cwd)

    def prefix_in_stage(self):
        return os.path.join(self.stage, self.port.prefix.lstrip("/"))

    @property
    def packages_directory(self):
        return self.layout.packages

    @property
    def source_root(self):
        return paths.SOURCE_ROOT
