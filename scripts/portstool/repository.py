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

"""Package repositories: a folder of packages served over HTTP(S) with
an index of them, optionally signed.

    INDEX       what the folder holds (below); pkg update fetches it
    INDEX.sig   "ed25519 HEX": the Ed25519 signature of INDEX's bytes
    *.pkg.tar.zst

INDEX is lines, a block per package (sorted by name, then version):

    format 1
    repository NAME
    package NAME
    version VERSION
    revision N
    architecture x86_64
    origin CATEGORY/NAME
    summary TEXT
    license SPDX-EXPRESSION
    depend NAME [OP VERSION]       (each)
    provide NAME                   (each)
    conflict NAME                  (each)
    file NAME-VERSION-ARCH.pkg.tar.zst
    size BYTES
    sha256 HEX
    end

pkg checks the signature with a key in /etc/pkg/keys and each package
it downloads against the size and SHA-256 here.
"""

import os

from . import ed25519
from .package import PackageReader
from .portfile import PACKAGE_SUFFIX
from .stage import sha256_file
from .versions import compare_versions
import functools

INDEX_FORMAT = 1


def index_entries(directory):
    entries = []
    for name in sorted(os.listdir(directory)):
        if not name.endswith(PACKAGE_SUFFIX):
            continue
        path = os.path.join(directory, name)
        reader = PackageReader(path)
        try:
            entries.append((reader.manifest, name, os.path.getsize(path), sha256_file(path)))
        finally:
            reader.close()

    def order(first, second):
        if first[0].name != second[0].name:
            return -1 if first[0].name < second[0].name else 1
        return compare_versions(first[0].full_version, second[0].full_version)

    return sorted(entries, key=functools.cmp_to_key(order))


def format_index(repository_name, entries):
    lines = [f"format {INDEX_FORMAT}", f"repository {repository_name}"]
    for manifest, file_name, size, digest in entries:
        lines += [f"package {manifest.name}",
                  f"version {manifest.version}",
                  f"revision {manifest.revision}",
                  f"architecture {manifest.architecture}"]
        if manifest.origin:
            lines.append(f"origin {manifest.origin}")
        lines += [f"summary {manifest.summary}", f"license {manifest.license}"]
        lines += [f"depend {text}" for text in manifest.depends]
        lines += [f"provide {name}" for name in manifest.provides]
        lines += [f"conflict {name}" for name in manifest.conflicts]
        lines += [f"file {file_name}", f"size {size}", f"sha256 {digest}", "end"]
    return "\n".join(lines) + "\n"


def parse_index(text):
    """[{key: value or [values]}] of an index (for tests and tools)."""
    packages = []
    current = None
    repeated = ("depend", "provide", "conflict")
    for line in text.splitlines():
        key, _, value = line.partition(" ")
        if key == "package":
            current = {"package": value, "depend": [], "provide": [], "conflict": []}
        elif key == "end":
            packages.append(current)
            current = None
        elif current is not None:
            if key in repeated:
                current[key].append(value)
            else:
                current[key] = value
    return packages


def write_repository(directory, repository_name="ports", secret_key=None):
    """Writes INDEX (and INDEX.sig with the secret key file); returns
    the number of packages."""
    entries = index_entries(directory)
    text = format_index(repository_name, entries).encode("utf-8")
    with open(os.path.join(directory, "INDEX"), "wb") as stream:
        stream.write(text)
    signature_path = os.path.join(directory, "INDEX.sig")
    if secret_key:
        seed = ed25519.read_secret_seed(secret_key)
        with open(signature_path, "w", encoding="ascii") as stream:
            stream.write(f"ed25519 {ed25519.sign(seed, text).hex()}\n")
    elif os.path.exists(signature_path):
        os.unlink(signature_path)
    return len(entries)


def verify_index(directory, public_key_path):
    with open(os.path.join(directory, "INDEX"), "rb") as stream:
        text = stream.read()
    with open(os.path.join(directory, "INDEX.sig"), encoding="ascii") as stream:
        words = stream.read().split()
    if len(words) != 2 or words[0] != "ed25519":
        return False
    return ed25519.verify(ed25519.read_public_key(public_key_path), text, bytes.fromhex(words[1]))
