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

"""Teaching an autotools tree the freepascalos target before it is
configured.

A package's own config.sub (autosetup's autosetup-config.sub) predates the OS and refuses
--host=x86_64-freepascalos: every config.sub in the tree is replaced by
the toolchain's (toolchain/config.sub, from the patched binutils). Its
libtool knows nothing of the OS either and would build no shared
libraries: the freepascalos* case is added wherever libtool's Linux
case is (configure, libtool.m4, ltmain.sh), so shared libraries are named
and versioned as on Linux (mlibc's ld.so loads them the same way).
"""

import os
import shutil

from . import paths

CONFIG_SUB = os.path.join(paths.SOURCE_ROOT, "toolchain", "config.sub")
LINUX_CASE = "linux* | k*bsd*-gnu | kopensolaris*-gnu"
TARGET_CASE = LINUX_CASE + " | freepascalos*"
LIBTOOL_FILES = ("configure", "libtool.m4", "ltmain.sh", "aclocal.m4")


def teach_libtool(path):
    """Adds the freepascalos* case to a libtool-generated file; True if
    it changed."""
    with open(path, encoding="utf-8", errors="surrogateescape") as stream:
        text = stream.read()
    if LINUX_CASE not in text or TARGET_CASE in text:
        return False
    with open(path, "w", encoding="utf-8", errors="surrogateescape") as stream:
        stream.write(text.replace(LINUX_CASE, TARGET_CASE))
    return True


def prepare_tree(tree):
    """Replaces the config.sub files and teaches libtool, under tree."""
    for directory, _, files in os.walk(tree):
        for name in files:
            path = os.path.join(directory, name)
            if name in ("config.sub", "autosetup-config.sub"):
                shutil.copyfile(CONFIG_SUB, path)
                os.chmod(path, 0o755)
            elif name in LIBTOOL_FILES:
                teach_libtool(path)
