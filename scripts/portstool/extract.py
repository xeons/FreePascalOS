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

"""Unpacking distfiles into a port's work folder: tar (plain, gzip,
bzip2, xz, zstd) and zip, with nothing written outside the target (tar's
"data" filter: no absolute names, no '..', no links out, no devices)."""

import io
import os
import shutil
import tarfile
import zipfile

from . import zstdcodec
from .portfile import PortError

ZSTD_MAGIC = b"\x28\xb5\x2f\xfd"

ARCHIVE_SUFFIXES = (".tar", ".tar.gz", ".tgz", ".tar.bz2", ".tbz2", ".tar.xz", ".txz", ".tar.zst", ".tzst", ".zip")


class ExtractError(PortError):
    pass


def is_archive(path):
    return path.lower().endswith(ARCHIVE_SUFFIXES) or tarfile.is_tarfile(path) or zipfile.is_zipfile(path)


def _safe_zip_member(name):
    parts = name.replace("\\", "/").split("/")
    return not (name.startswith("/") or ".." in parts or (len(name) > 1 and name[1] == ":"))


def extract_archive(path, target):
    """Unpacks the archive at path into target (made if missing)."""
    os.makedirs(target, exist_ok=True)
    if zipfile.is_zipfile(path) and not tarfile.is_tarfile(path):
        with zipfile.ZipFile(path) as archive:
            for member in archive.infolist():
                if not _safe_zip_member(member.filename):
                    raise ExtractError(f"{os.path.basename(path)}: unsafe member {member.filename!r}")
                archive.extract(member, target)
                mode = (member.external_attr >> 16) & 0o777
                if mode and not member.is_dir():
                    os.chmod(os.path.join(target, member.filename), mode)
        return
    try:
        with open(path, "rb") as stream:
            zstandard = stream.read(4) == ZSTD_MAGIC
        if zstandard:
            # tarfile reads .tar.zst only from Python 3.14 on.
            with open(path, "rb") as stream:
                data = zstdcodec.decompress(stream.read())
            archive = tarfile.open(fileobj=io.BytesIO(data), mode="r:")
        else:
            archive = tarfile.open(path, "r:*")
        with archive:
            archive.extractall(target, filter="data")
    except (tarfile.TarError, OSError, zstdcodec.ZstdError) as error:
        raise ExtractError(f"{os.path.basename(path)}: {error}") from None


def extract_sources(port, distfiles, work_directory):
    """Unpacks every distfile that is an archive into the work folder
    (into its extract_dir when it has one); copies the others in. The
    source tree's path: the first source's extract_dir, or the only
    folder the first archive made."""
    os.makedirs(work_directory, exist_ok=True)
    source_tree = None
    for index, (source, path) in enumerate(zip(port.sources, distfiles)):
        before = set(os.listdir(work_directory))
        if source.extract and is_archive(path):
            if source.extract_dir and index > 0:
                extract_archive(path, os.path.join(work_directory, source.extract_dir))
            else:
                extract_archive(path, work_directory)
        else:
            target = os.path.join(work_directory, source.extract_dir or "")
            os.makedirs(target, exist_ok=True)
            shutil.copy2(path, os.path.join(target, source.filename))
        if index == 0:
            if source.extract_dir:
                source_tree = os.path.join(work_directory, source.extract_dir)
            else:
                made = sorted(set(os.listdir(work_directory)) - before)
                folders = [name for name in made if os.path.isdir(os.path.join(work_directory, name))]
                source_tree = os.path.join(work_directory, folders[0]) if len(folders) == 1 else work_directory
    if source_tree is None:
        # No sources: the tree is a folder of its own, filled from files/.
        source_tree = os.path.join(work_directory, "source")
        os.makedirs(source_tree, exist_ok=True)
    if not os.path.isdir(source_tree):
        raise ExtractError(f"{port.origin}: extract_dir {os.path.relpath(source_tree, work_directory)} was not made")
    return source_tree
