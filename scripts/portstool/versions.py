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

"""Versions and dependency specifications.

A version is compared part by part: runs of digits as numbers, runs of
letters as text, anything else separating them, so 1.10 > 1.9 and
1.2.3 > 1.2. A run of letters right after a number is a pre-release
when it is alpha, beta, pre or rc (1.0rc1 < 1.0) and otherwise comes
after the number (1.0a > 1.0, as OpenSSL's 1.1.1w). The package's
revision (the port's own changes) comes after: 1.0_2 > 1.0_1 > 1.0.
pkg (userland/commands/pkg/Pkg.Versions.pas) compares the same way; the host
tests check both on the same pairs.

A dependency is NAME, or NAME OP VERSION with OP one of >= <= > < =,
spaces optional: "zlib", "zlib>=1.3", "lua = 5.4.7".
"""

import re
from dataclasses import dataclass

PRE_RELEASE_WORDS = ("alpha", "beta", "pre", "rc")
OPERATORS = (">=", "<=", "=", ">", "<")
NAME_PATTERN = r"[a-z0-9][a-z0-9+._-]*"
_DEPENDENCY = re.compile(r"^\s*(" + NAME_PATTERN + r")\s*(?:(>=|<=|=|>|<)\s*([^\s<>=]+))?\s*$")


def _parts(version):
    """The parts of a version: (kind, value) with kind 0 for a
    pre-release word, 1 for a number, 2 for other text."""
    parts = []
    for match in re.finditer(r"\d+|[A-Za-z]+", version):
        token = match.group(0)
        if token.isdigit():
            parts.append((1, int(token), ""))
        else:
            lower = token.lower()
            if lower.startswith(PRE_RELEASE_WORDS):
                parts.append((0, 0, lower))
            else:
                parts.append((2, 0, lower))
    return parts


def _split_revision(version):
    if "_" in version:
        base, _, revision = version.rpartition("_")
        if revision.isdigit():
            return base, int(revision)
    return version, 0


def compare_versions(left, right):
    """-1, 0 or 1 as left is older than, the same as or newer than right."""
    left_base, left_revision = _split_revision(left)
    right_base, right_revision = _split_revision(right)
    left_parts = _parts(left_base)
    right_parts = _parts(right_base)
    index = 0
    while index < len(left_parts) or index < len(right_parts):
        # A missing part counts as less than a number or text, more than
        # a pre-release: 1.0 < 1.0.1, 1.0rc1 < 1.0.
        left_part = left_parts[index] if index < len(left_parts) else (0.5, 0, "")
        right_part = right_parts[index] if index < len(right_parts) else (0.5, 0, "")
        if left_part != right_part:
            return -1 if left_part < right_part else 1
        index += 1
    if left_revision != right_revision:
        return -1 if left_revision < right_revision else 1
    return 0


def full_version(version, revision):
    """1.3.1 with revision 0, 1.3.1_2 with revision 2."""
    return f"{version}_{revision}" if revision else version


@dataclass(frozen=True)
class Dependency:
    name: str
    operator: str = ""
    version: str = ""

    def satisfied_by(self, version):
        if not self.operator:
            return True
        order = compare_versions(version, self.version)
        return {
            ">=": order >= 0, "<=": order <= 0, ">": order > 0, "<": order < 0, "=": order == 0,
        }[self.operator]

    def __str__(self):
        if self.operator:
            return f"{self.name} {self.operator} {self.version}"
        return self.name


def parse_dependency(text):
    match = _DEPENDENCY.match(text)
    if not match:
        raise ValueError(f"not a dependency: {text!r} (NAME or NAME>=VERSION)")
    return Dependency(match.group(1), match.group(2) or "", match.group(3) or "")
