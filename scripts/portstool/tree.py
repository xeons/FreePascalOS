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

"""The ports tree: every ports/CATEGORY/NAME/port.toml, found by name,
by origin, by what it provides, or by searching."""

import os

from . import paths
from .portfile import Port, PortError, split_flavor


class PortsTree:
    def __init__(self, root=None):
        self.root = root or paths.PORTS_ROOT
        self._ports = None
        self._failures = None

    def port_directories(self):
        directories = []
        for category in sorted(os.listdir(self.root)):
            category_path = os.path.join(self.root, category)
            if not os.path.isdir(category_path) or category.startswith("."):
                continue
            for name in sorted(os.listdir(category_path)):
                if os.path.isfile(os.path.join(category_path, name, "port.toml")):
                    directories.append(os.path.join(category_path, name))
        return directories

    def _load(self):
        if self._ports is not None:
            return
        self._ports = {}
        self._failures = {}
        for directory in self.port_directories():
            try:
                port = Port.load(directory)
            except PortError as error:
                self._failures[directory] = str(error)
                continue
            self._ports[port.name] = port

    def ports(self):
        """Every port that reads, by name."""
        self._load()
        return [self._ports[name] for name in sorted(self._ports)]

    def failures(self):
        """{directory: why} for the ports that do not read."""
        self._load()
        return dict(self._failures)

    def find(self, text, option_settings=None):
        """A port by name, name@flavor, category/name or folder; with
        options or a flavour it is read again with them."""
        name, flavor = split_flavor(text)
        directory = None
        if os.path.isfile(os.path.join(name, "port.toml")):
            directory = name
        elif "/" in name and os.path.isfile(os.path.join(self.root, name, "port.toml")):
            directory = os.path.join(self.root, name)
        else:
            self._load()
            port = self._ports.get(name)
            if port is None:
                port = self.provider(name)
            if port is None:
                for failed_directory, why in self._failures.items():
                    if os.path.basename(failed_directory) == name:
                        raise PortError(why)
                raise PortError(f"no port named {name}")
            directory = port.directory
        return Port.load(directory, flavor, option_settings)

    def provider(self, name):
        """The port called name, else the first that provides it."""
        self._load()
        if name in self._ports:
            return self._ports[name]
        for port in self.ports():
            if name in port.provides:
                return port
        return None

    def search(self, words):
        """Ports whose name, summary, description or categories hold
        every word (in any case)."""
        lowered = [word.lower() for word in words]
        found = []
        for port in self.ports():
            text = " ".join([port.name, port.summary, port.description] + port.categories).lower()
            if all(word in text for word in lowered):
                found.append(port)
        return found
