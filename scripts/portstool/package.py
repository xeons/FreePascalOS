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

"""Packages: NAME-VERSION[_REVISION]-ARCH.pkg.tar.zst, a tar archive
(POSIX pax) compressed with Zstandard, holding in this order

    +MANIFEST          what the package is and every path (manifest.py)
    +DESC              the long description
    +pre-install ...   scripts the manifest names (run by /bin/sh)
    usr/local/...      the files, folders and links, sorted by path

Made reproducibly: members sorted, owner root:root (0:0), every time
SOURCE_DATE_EPOCH, the same compression level, so building a port twice
gives the same bytes. pkg reads them with libarchive (tar.zst).
"""

import hashlib
import io
import os
import stat
import tarfile

from . import manifest as manifest_module
from . import zstdcodec
from .portfile import PortError

COMPRESSION_LEVEL = 19
METADATA_PREFIX = "+"


class PackageError(PortError):
    pass


def _info(name, epoch, mode, kind=tarfile.REGTYPE, size=0):
    info = tarfile.TarInfo(name)
    info.mtime = epoch
    info.mode = mode
    info.uid = 0
    info.gid = 0
    info.uname = "root"
    info.gname = "root"
    info.type = kind
    info.size = size
    return info


def write_package(path, manifest, description, scripts, stage_root, epoch):
    """Writes the package file: manifest (a Manifest), description text,
    scripts {kind: script text}, the stage's contents."""
    manifest_text = manifest_module.format_manifest(manifest).encode("utf-8")
    temporary = path + ".partial"
    raw = io.BytesIO()
    with tarfile.open(fileobj=raw, mode="w", format=tarfile.PAX_FORMAT) as archive:
        def add_bytes(name, data, mode=0o644):
            archive.addfile(_info(name, epoch, mode, size=len(data)), io.BytesIO(data))

        add_bytes("+MANIFEST", manifest_text)
        add_bytes("+DESC", (description.rstrip("\n") + "\n").encode("utf-8"))
        for kind in sorted(scripts):
            add_bytes("+" + kind, scripts[kind].encode("utf-8"), 0o755)
        for entry in sorted(manifest.directories, key=lambda item: item.path):
            archive.addfile(_info(entry.path + "/", epoch, entry.mode, tarfile.DIRTYPE))
        entries = [(item.path, item) for item in manifest.files] + [(item.path, item) for item in manifest.links]
        for name, entry in sorted(entries, key=lambda pair: pair[0]):
            if isinstance(entry, manifest_module.LinkEntry):
                info = _info(name, epoch, 0o777, tarfile.SYMTYPE)
                info.linkname = entry.target
                archive.addfile(info)
            else:
                with open(os.path.join(stage_root, name), "rb") as stream:
                    archive.addfile(_info(name, epoch, entry.mode, size=entry.size), stream)
    data = zstdcodec.compress(raw.getvalue(), COMPRESSION_LEVEL)
    with open(temporary, "wb") as stream:
        stream.write(data)
    os.replace(temporary, path)
    return path


class PackageReader:
    """A package file opened: its manifest, description, scripts and the
    files' data."""

    def __init__(self, path):
        self.path = path
        try:
            with open(path, "rb") as stream:
                raw = zstdcodec.decompress(stream.read())
        except (OSError, zstdcodec.ZstdError) as error:
            raise PackageError(f"{path}: not a package ({error})") from None
        self.archive = tarfile.open(fileobj=io.BytesIO(raw), mode="r:")
        members = self.archive.getmembers()
        if not members or members[0].name != "+MANIFEST":
            raise PackageError(f"{path}: +MANIFEST is not the first member")
        self.members = {member.name.rstrip("/"): member for member in members}
        try:
            self.manifest = manifest_module.parse_manifest(self.read("+MANIFEST").decode("utf-8"))
        except manifest_module.ManifestError as error:
            raise PackageError(f"{path}: {error}") from None
        self.description = self.read("+DESC").decode("utf-8") if "+DESC" in self.members else ""
        self.scripts = {kind: self.read("+" + kind).decode("utf-8")
                        for kind in self.manifest.scripts if "+" + kind in self.members}

    def read(self, name):
        member = self.members.get(name)
        if member is None or not member.isfile():
            raise PackageError(f"{self.path}: no member {name}")
        return self.archive.extractfile(member).read()

    def payload_members(self):
        return [member for name, member in self.members.items() if not name.startswith(METADATA_PREFIX)]

    def verify(self):
        """The problems found comparing the payload with the manifest."""
        problems = []
        listed = {entry.path: entry for entry in self.manifest.files}
        links = {entry.path: entry for entry in self.manifest.links}
        directories = {entry.path for entry in self.manifest.directories}
        for member in self.payload_members():
            name = member.name.rstrip("/")
            if member.isfile():
                entry = listed.pop(name, None)
                if entry is None:
                    problems.append(f"{name}: in the archive but not in the manifest")
                    continue
                data = self.archive.extractfile(member).read()
                if len(data) != entry.size or hashlib.sha256(data).hexdigest() != entry.sha256:
                    problems.append(f"{name}: does not match its manifest checksum")
            elif member.issym():
                entry = links.pop(name, None)
                if entry is None or entry.target != member.linkname:
                    problems.append(f"{name}: link not as the manifest says")
            elif member.isdir():
                if name not in directories:
                    problems.append(f"{name}/: folder not in the manifest")
            else:
                problems.append(f"{name}: not a file, folder or link")
        problems += [f"{name}: in the manifest but not in the archive" for name in listed]
        problems += [f"{name}: link in the manifest but not in the archive" for name in links]
        return problems

    def extract_payload(self, root):
        """Writes the files, folders and links under root."""
        for member in self.payload_members():
            name = member.name.rstrip("/")
            manifest_module.check_path(name)
            target = os.path.join(root, name)
            if member.isdir():
                os.makedirs(target, exist_ok=True)
                os.chmod(target, member.mode)
            elif member.issym():
                os.makedirs(os.path.dirname(target), exist_ok=True)
                if os.path.lexists(target):
                    os.unlink(target)
                os.symlink(member.linkname, target)
            elif member.isfile():
                os.makedirs(os.path.dirname(target), exist_ok=True)
                with open(target, "wb") as stream:
                    stream.write(self.archive.extractfile(member).read())
                os.chmod(target, stat.S_IMODE(member.mode))

    def close(self):
        self.archive.close()
