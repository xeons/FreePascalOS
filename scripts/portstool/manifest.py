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

"""The package manifest (+MANIFEST): what a package is and every path it
installs, one line each, as pkg reads it (userland/commands/pkg/Pkg.Manifests.pas).

    format 1
    name NAME                  version VERSION        revision N
    origin CATEGORY/NAME       flavor FLAVOR (when built as one)
    architecture x86_64        prefix /usr/local
    summary TEXT               license SPDX-EXPRESSION
    maintainer TEXT            homepage URL
    depend NAME [OP VERSION]   (each run dependency)
    provide NAME               conflict NAME
    script KIND                (pre-install, post-install, pre-remove,
                                post-remove: the member +KIND)
    test COMMAND               (pkg test runs each with /bin/sh)
    license-file PATH          (an installed licence text)
    dir MODE PATH
    file MODE SIZE SHA256 PATH
    link PATH TARGET

Paths are relative to the root ("usr/local/bin/ptop") and hold no
spaces or control characters; modes are octal. Words are separated by
one space; summary, maintainer, test and license take the rest of the
line. Lines in that order: the header, then dir, file and link lines
sorted by path.
"""

from dataclasses import dataclass, field

FORMAT_VERSION = 1
SCRIPT_KINDS = ("pre-install", "post-install", "pre-remove", "post-remove")
REST_OF_LINE_KEYS = ("summary", "maintainer", "test", "license", "homepage")


class ManifestError(ValueError):
    pass


@dataclass
class FileEntry:
    path: str
    mode: int
    size: int
    sha256: str


@dataclass
class LinkEntry:
    path: str
    target: str


@dataclass
class DirectoryEntry:
    path: str
    mode: int


@dataclass
class Manifest:
    name: str = ""
    version: str = ""
    revision: int = 0
    origin: str = ""
    flavor: str = ""
    architecture: str = ""
    prefix: str = "/usr/local"
    summary: str = ""
    license: str = ""
    maintainer: str = ""
    homepage: str = ""
    depends: list = field(default_factory=list)       # dependency texts
    provides: list = field(default_factory=list)
    conflicts: list = field(default_factory=list)
    scripts: list = field(default_factory=list)       # kinds
    tests: list = field(default_factory=list)
    license_files: list = field(default_factory=list)
    directories: list = field(default_factory=list)
    files: list = field(default_factory=list)
    links: list = field(default_factory=list)

    @property
    def full_version(self):
        return f"{self.version}_{self.revision}" if self.revision else self.version

    def paths(self):
        return [entry.path for entry in self.files] + [entry.path for entry in self.links]


def check_path(path):
    if not path or path.startswith("/") or any(character.isspace() or ord(character) < 32 for character in path):
        raise ManifestError(f"a package path must be relative and hold no spaces: {path!r}")
    if ".." in path.split("/"):
        raise ManifestError(f"a package path may not hold '..': {path!r}")


def format_manifest(manifest):
    lines = [f"format {FORMAT_VERSION}",
             f"name {manifest.name}",
             f"version {manifest.version}",
             f"revision {manifest.revision}"]
    if manifest.origin:
        lines.append(f"origin {manifest.origin}")
    if manifest.flavor:
        lines.append(f"flavor {manifest.flavor}")
    lines += [f"architecture {manifest.architecture}",
              f"prefix {manifest.prefix}",
              f"summary {manifest.summary}",
              f"license {manifest.license}"]
    if manifest.maintainer:
        lines.append(f"maintainer {manifest.maintainer}")
    if manifest.homepage:
        lines.append(f"homepage {manifest.homepage}")
    lines += [f"depend {text}" for text in manifest.depends]
    lines += [f"provide {name}" for name in manifest.provides]
    lines += [f"conflict {name}" for name in manifest.conflicts]
    lines += [f"script {kind}" for kind in manifest.scripts]
    lines += [f"test {command}" for command in manifest.tests]
    lines += [f"license-file {path}" for path in manifest.license_files]
    for entry in sorted(manifest.directories, key=lambda item: item.path):
        check_path(entry.path)
        lines.append(f"dir {entry.mode:04o} {entry.path}")
    for entry in sorted(manifest.files, key=lambda item: item.path):
        check_path(entry.path)
        lines.append(f"file {entry.mode:04o} {entry.size} {entry.sha256} {entry.path}")
    for entry in sorted(manifest.links, key=lambda item: item.path):
        check_path(entry.path)
        if not entry.target or any(character.isspace() for character in entry.target):
            raise ManifestError(f"a link target may not be empty or hold spaces: {entry.target!r}")
        lines.append(f"link {entry.path} {entry.target}")
    return "\n".join(lines) + "\n"


def parse_manifest(text):
    manifest = Manifest()
    seen_format = False
    for number, line in enumerate(text.splitlines(), 1):
        if not line or line.startswith("#"):
            continue
        key, _, rest = line.partition(" ")
        words = rest.split(" ")

        def need(count):
            if len(words) != count or not all(words):
                raise ManifestError(f"line {number}: {key} takes {count} word(s)")

        if key == "format":
            need(1)
            if words[0] != str(FORMAT_VERSION):
                raise ManifestError(f"line {number}: manifest format {words[0]} is not {FORMAT_VERSION}")
            seen_format = True
        elif key in ("name", "version", "origin", "flavor", "architecture", "prefix"):
            need(1)
            setattr(manifest, key, words[0])
        elif key == "revision":
            need(1)
            if not words[0].isdigit():
                raise ManifestError(f"line {number}: revision is a number")
            manifest.revision = int(words[0])
        elif key in REST_OF_LINE_KEYS and key != "test":
            setattr(manifest, key, rest)
        elif key == "test":
            manifest.tests.append(rest)
        elif key == "depend":
            manifest.depends.append(rest)
        elif key == "provide":
            need(1)
            manifest.provides.append(words[0])
        elif key == "conflict":
            need(1)
            manifest.conflicts.append(words[0])
        elif key == "script":
            need(1)
            if words[0] not in SCRIPT_KINDS:
                raise ManifestError(f"line {number}: unknown script {words[0]}")
            manifest.scripts.append(words[0])
        elif key == "license-file":
            need(1)
            manifest.license_files.append(words[0])
        elif key == "dir":
            need(2)
            manifest.directories.append(DirectoryEntry(words[1], int(words[0], 8)))
        elif key == "file":
            need(4)
            if len(words[2]) != 64:
                raise ManifestError(f"line {number}: a SHA-256 is 64 hex digits")
            manifest.files.append(FileEntry(words[3], int(words[0], 8), int(words[1]), words[2]))
        elif key == "link":
            need(2)
            manifest.links.append(LinkEntry(words[0], words[1]))
        else:
            raise ManifestError(f"line {number}: unknown key {key!r}")
    if not seen_format:
        raise ManifestError("no format line")
    for required in ("name", "version", "architecture"):
        if not getattr(manifest, required):
            raise ManifestError(f"no {required} line")
    return manifest
