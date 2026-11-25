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

"""The stage: what `make install DESTDIR=...` (or the build system's
equivalent) put in the port's stage folder, completed and tidied into
exactly what the package holds.

Completed: [install] files copied in, docs into PREFIX/share/doc/NAME,
licence texts into PREFIX/share/licenses/NAME. Tidied: libtool archives
(*.la), info's dir file and [install] remove's patterns deleted; ELF
files stripped (unless [install] strip = false); group and other write
permission and set-id bits dropped; every time set to SOURCE_DATE_EPOCH.
Refused: anything outside the prefix, paths with spaces, devices and
pipes, links that leave the root.
"""

import fnmatch
import hashlib
import os
import shutil
import stat
import subprocess

from .manifest import DirectoryEntry, FileEntry, LinkEntry, check_path
from .portfile import PortError

ALWAYS_REMOVED = ("lib/*.la", "share/info/dir")
# The prefix's hierarchy is the system's: packages never list (or
# remove) these folders.
STANDARD_DIRECTORIES = {
    "usr", "usr/local", "usr/local/bin", "usr/local/sbin", "usr/local/lib", "usr/local/libexec",
    "usr/local/include", "usr/local/etc", "usr/local/share", "usr/local/share/doc",
    "usr/local/share/licenses", "usr/local/share/man", "usr/local/man", "usr/local/lib/pkgconfig",
}


class StageError(PortError):
    pass


def _copy_into(source, target, mode=None):
    os.makedirs(os.path.dirname(target), exist_ok=True)
    if os.path.isdir(source):
        shutil.copytree(source, target, symlinks=True, dirs_exist_ok=True)
    else:
        shutil.copy2(source, target)
        if mode is not None:
            os.chmod(target, mode)


def place_extra_files(context):
    """[install] files, docs and licence texts, into the stage."""
    port = context.port
    prefix_root = context.prefix_in_stage()
    for item in port.install_files:
        source = port.resolve_port_path(context.expand(item["from"]), context.build_tree)
        destination = context.expand(item["to"])
        if destination.startswith("/"):
            target = os.path.join(context.stage, destination.lstrip("/"))
        else:
            target = os.path.join(prefix_root, destination)
        if destination.endswith("/"):
            target = os.path.join(target, os.path.basename(source))
        if not os.path.exists(source):
            raise StageError(f"[install] files: {item['from']} was not built ({source})")
        mode = int(item["mode"], 8) if "mode" in item else None
        _copy_into(source, target, mode)
    for document in port.docs:
        source = port.resolve_port_path(document, context.source_tree)
        if not os.path.exists(source):
            raise StageError(f"[install] docs: {document} is missing")
        _copy_into(source, os.path.join(prefix_root, "share", "doc", port.name, os.path.basename(source)), 0o644)
    for license_file in port.license_files:
        source = port.resolve_port_path(license_file, context.source_tree)
        if not os.path.exists(source):
            raise StageError(f"license_files: {license_file} is missing")
        _copy_into(source, os.path.join(prefix_root, "share", "licenses", port.name, os.path.basename(source)), 0o644)


def remove_unwanted(context):
    prefix_root = context.prefix_in_stage()
    patterns = list(ALWAYS_REMOVED) + list(context.port.remove_patterns)
    for directory, folders, files in os.walk(prefix_root, topdown=False):
        for name in files + folders:
            path = os.path.join(directory, name)
            relative = os.path.relpath(path, prefix_root)
            if any(fnmatch.fnmatch(relative, pattern) for pattern in patterns):
                if os.path.isdir(path) and not os.path.islink(path):
                    shutil.rmtree(path)
                else:
                    os.unlink(path)


def is_elf(path):
    with open(path, "rb") as stream:
        return stream.read(4) == b"\x7fELF"


def strip_binaries(context, strip_command, log):
    if not context.port.strip or not strip_command or shutil.which(strip_command[0]) is None:
        return
    for directory, _, files in os.walk(context.stage):
        for name in files:
            path = os.path.join(directory, name)
            if os.path.islink(path) or not is_elf(path):
                continue
            # Static archives and objects keep their symbols.
            if name.endswith((".o", ".a")):
                continue
            result = subprocess.run(list(strip_command) + ["--strip-unneeded", path],
                                    stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
            if log and result.stdout:
                log.note(result.stdout)


def normalize_tree(root, epoch):
    """Permissions without group/other write or set-id bits (folders
    open to all), every time the same; checks what may not go in a
    package."""
    for directory, folders, files in os.walk(root, topdown=False):
        for name in files + folders:
            path = os.path.join(directory, name)
            relative = os.path.relpath(path, root)
            check_path(relative)
            info = os.lstat(path)
            if stat.S_ISLNK(info.st_mode):
                target = os.readlink(path)
                resolved = os.path.normpath(os.path.join(os.path.dirname(relative), target))
                if target.startswith("/") or resolved.startswith(".."):
                    if not target.startswith("/"):
                        raise StageError(f"{relative}: the link leaves the root ({target})")
                os.utime(path, (epoch, epoch), follow_symlinks=False)
                continue
            if not (stat.S_ISREG(info.st_mode) or stat.S_ISDIR(info.st_mode)):
                raise StageError(f"{relative}: only files, folders and links go in a package")
            mode = stat.S_IMODE(info.st_mode) & ~0o7022
            if stat.S_ISDIR(info.st_mode):
                mode |= 0o755
            os.chmod(path, mode)
            os.utime(path, (epoch, epoch))
    os.utime(root, (epoch, epoch))


def check_inside_prefix(stage_root, prefix):
    prefix_relative = prefix.strip("/")
    for directory, folders, files in os.walk(stage_root):
        for name in files + folders:
            relative = os.path.relpath(os.path.join(directory, name), stage_root)
            inside = relative == prefix_relative or relative.startswith(prefix_relative + "/")
            leading = (prefix_relative + "/").startswith(relative + "/")
            if not inside and not leading:
                raise StageError(f"/{relative} is outside the prefix {prefix}")


def sha256_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as stream:
        for block in iter(lambda: stream.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def collect_entries(stage_root):
    """(directories, files, links) for the manifest, sorted by path."""
    directories, files, links = [], [], []
    for directory, folders, names in os.walk(stage_root):
        folders.sort()
        for name in sorted(folders):
            path = os.path.join(directory, name)
            relative = os.path.relpath(path, stage_root)
            if os.path.islink(path):
                links.append(LinkEntry(relative, os.readlink(path)))
            elif relative not in STANDARD_DIRECTORIES:
                directories.append(DirectoryEntry(relative, stat.S_IMODE(os.lstat(path).st_mode)))
        for name in sorted(names):
            path = os.path.join(directory, name)
            relative = os.path.relpath(path, stage_root)
            if os.path.islink(path):
                links.append(LinkEntry(relative, os.readlink(path)))
            else:
                info = os.lstat(path)
                files.append(FileEntry(relative, stat.S_IMODE(info.st_mode), info.st_size, sha256_file(path)))

    def by_path(entry):
        return entry.path

    return sorted(directories, key=by_path), sorted(files, key=by_path), sorted(links, key=by_path)


def license_paths(port):
    prefix = port.prefix.strip("/")
    return [f"{prefix}/share/licenses/{port.name}/{os.path.basename(path)}" for path in port.license_files]
