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

"""What the ports tool's tests share: the tool's package on the path,
scratch folders, and small ports trees written on the fly."""

import os
import shutil
import sys
import tempfile
import textwrap
import unittest

SOURCE_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(SOURCE_ROOT, "scripts"))

from portstool import manifest as manifest_module  # noqa: E402
from portstool.manifest import FileEntry, LinkEntry, DirectoryEntry, Manifest  # noqa: E402,F401

LICENSES = "MIT\nGPL-3.0-or-later\nZlib\nexception GCC-exception-3.1\n"


def port_toml(name, version="1.0", category="misc", extra="", build='[build]\nsystem = "none"\n', revision=0):
    """A port.toml with the required keys and whatever extra says."""
    head = textwrap.dedent(f"""\
        [port]
        name = "{name}"
        version = "{version}"
        revision = {revision}
        summary = "The {name} test port"
        description = "A port written by the ports tool's tests."
        homepage = "https://example.invalid/{name}"
        license = "MIT"
        maintainer = "tests"
        categories = ["{category}"]
        status = "tested"
        """)
    return head + "\n" + build + "\n" + textwrap.dedent(extra)


class ScratchTestCase(unittest.TestCase):
    """Each test gets a folder of its own, removed afterwards."""

    def setUp(self):
        self.scratch = tempfile.mkdtemp(prefix="ports-test-")
        self.addCleanup(shutil.rmtree, self.scratch, True)

    def path(self, *parts):
        return os.path.join(self.scratch, *parts)

    def write(self, relative, text, mode=None):
        path = self.path(relative)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8") as stream:
            stream.write(text)
        if mode is not None:
            os.chmod(path, mode)
        return path

    def make_tree(self, ports):
        """ports: {"category/name": port.toml text}; returns the tree's root."""
        root = self.path("ports")
        os.makedirs(root, exist_ok=True)
        self.write("ports/licenses.txt", LICENSES)
        for origin, text in ports.items():
            self.write(f"ports/{origin}/port.toml", text)
        return root

    def make_stage(self, files, links=(), directories=()):
        """A stage folder: files {relative path: (text, mode)}."""
        stage = self.path("stage")
        for relative in directories:
            os.makedirs(os.path.join(stage, relative), exist_ok=True)
        for relative, (text, mode) in files.items():
            path = os.path.join(stage, relative)
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, "w", encoding="utf-8") as stream:
                stream.write(text)
            os.chmod(path, mode)
        for relative, target in links:
            path = os.path.join(stage, relative)
            os.makedirs(os.path.dirname(path), exist_ok=True)
            os.symlink(target, path)
        return stage
