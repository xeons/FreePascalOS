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

"""Putting packages on the system disk: install-to-image unpacks
packages under a root folder (build/ARCH/ports/image-root, which
scripts/make-system-disk.sh copies onto the disk) and records them in
its /var/db/pkg, so pkg on the system knows them as installed. Run
dependencies are checked against what is installed under that root;
conflicting files are refused. Install scripts are not run (they are
the system's shell scripts); a package with a post-install script says
so.

ports/image.list names the ports the system disk carries: one port a
line (name, name@flavor or category/name), # comments.
"""

import os

from . import database, versions
from .package import PackageReader
from .portfile import PortError


class ImageError(PortError):
    pass


def read_list(path):
    names = []
    with open(path, encoding="utf-8") as stream:
        for line in stream:
            line = line.split("#", 1)[0].strip()
            if line:
                names.append(line)
    return names


def owners(root):
    """{path: package name} of everything installed under root."""
    result = {}
    for name, manifest in database.installed_manifests(root).items():
        for path in manifest.paths():
            result[path] = name
    return result


def install_package_file(path, root, epoch, log=print):
    reader = PackageReader(path)
    try:
        problems = reader.verify()
        if problems:
            raise ImageError(f"{os.path.basename(path)}: " + "; ".join(problems))
        manifest = reader.manifest
        installed = database.installed_manifests(root)
        for text in manifest.depends:
            dependency = versions.parse_dependency(text)
            provider = installed.get(dependency.name)
            if provider is None:
                provider = next((item for item in installed.values() if dependency.name in item.provides), None)
            if provider is None or not dependency.satisfied_by(provider.full_version):
                raise ImageError(f"{manifest.name} needs {dependency}, which is not installed in the image")
        taken = owners(root)
        for item in manifest.paths():
            owner = taken.get(item)
            if owner and owner != manifest.name:
                raise ImageError(f"{manifest.name}: /{item} belongs to {owner}")
        reader.extract_payload(root)
        database.record_package(root, reader, epoch)
        if "post-install" in manifest.scripts:
            log(f"{manifest.name}: its post-install script is not run in an image")
        log(f"installed {manifest.name} {manifest.full_version} into {root}")
        return manifest
    finally:
        reader.close()
