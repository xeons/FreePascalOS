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

"""The installed packages' database, as pkg keeps it on the system:

    /var/db/pkg/NAME/+MANIFEST     the package's manifest, as installed
    /var/db/pkg/NAME/+DESC         its description
    /var/db/pkg/NAME/+pre-remove   its removal scripts, if any
    /var/db/pkg/NAME/+post-remove
    /var/db/pkg/NAME/+INSTALLED    "installed EPOCH" and "automatic yes|no"
                                   (installed only as a dependency)

The host writes it when it installs packages into the system disk
(install-to-image); pkg (userland/pkg) reads and writes the same files.
"""

import os
import shutil

from . import manifest as manifest_module
from .paths import PACKAGE_DATABASE


def database_directory(root):
    return os.path.join(root, PACKAGE_DATABASE)


def installed_manifests(root):
    """{name: Manifest} of every package installed under root."""
    directory = database_directory(root)
    found = {}
    if not os.path.isdir(directory):
        return found
    for name in sorted(os.listdir(directory)):
        path = os.path.join(directory, name, "+MANIFEST")
        if os.path.isfile(path):
            with open(path, encoding="utf-8") as stream:
                found[name] = manifest_module.parse_manifest(stream.read())
    return found


def record_package(root, reader, epoch, automatic=False):
    """Writes the database entry of a package installed under root."""
    directory = database_directory(root)
    entry = os.path.join(directory, reader.manifest.name)
    temporary = entry + ".new"
    shutil.rmtree(temporary, ignore_errors=True)
    os.makedirs(temporary)
    with open(os.path.join(temporary, "+MANIFEST"), "w", encoding="utf-8") as stream:
        stream.write(manifest_module.format_manifest(reader.manifest))
    with open(os.path.join(temporary, "+DESC"), "w", encoding="utf-8") as stream:
        stream.write(reader.description)
    for kind in ("pre-remove", "post-remove"):
        if kind in reader.scripts:
            path = os.path.join(temporary, "+" + kind)
            with open(path, "w", encoding="utf-8") as stream:
                stream.write(reader.scripts[kind])
            os.chmod(path, 0o755)
    with open(os.path.join(temporary, "+INSTALLED"), "w", encoding="utf-8") as stream:
        stream.write(f"installed {epoch}\nautomatic {'yes' if automatic else 'no'}\n")
    shutil.rmtree(entry, ignore_errors=True)
    os.rename(temporary, entry)
    for directory_path, folders, files in os.walk(entry):
        for name in folders + files:
            os.utime(os.path.join(directory_path, name), (epoch, epoch))
