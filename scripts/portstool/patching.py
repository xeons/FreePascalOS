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

"""Patches: applying the port's patches/*.patch to the source tree in
order (GNU patch, -pSTRIP, no fuzz beyond patch's default, a reject
fails the build), and makepatch, which writes the changes made by hand
in a work tree back into patches/ (FreeBSD's "make makepatch").

makepatch compares the work tree with a pristine copy of the sources
(the distfiles unpacked again, without patches) and writes one patch per
changed file, named patch-PATH with '/' as '_' (patch-src_main.c.patch),
in the -p1 form ("a/src/main.c", "b/src/main.c"). Files the build makes
are left out: only files that are in the pristine copy are compared,
plus new files named with --add. What patches/ held before is kept in
the work folder (patches-before-makepatch/) and replaced.
"""

import difflib
import os
import shutil
import subprocess
import tempfile

from . import extract
from .portfile import PortError


class PatchError(PortError):
    pass


def apply_patch(patch_path, source_tree, strip, log=None, check_only=False):
    command = ["patch", "--batch", "--forward", "--no-backup-if-mismatch", f"-p{strip}",
               "-d", source_tree, "-i", os.path.abspath(patch_path)]
    if check_only:
        command.insert(1, "--dry-run")
    result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    if log:
        log.note(f"applying {os.path.basename(patch_path)} (-p{strip})")
        log.note(result.stdout)
    if result.returncode != 0:
        raise PatchError(f"{os.path.basename(patch_path)} does not apply:\n{result.stdout}")


def apply_patches(port, source_tree, log=None):
    applied = []
    for patch_path in port.patch_files():
        apply_patch(patch_path, source_tree, port.patch_strip, log)
        applied.append(os.path.basename(patch_path))
    return applied


def patch_name_for(relative_path):
    return "patch-" + relative_path.replace("/", "_") + ".patch"


def _read_lines(path):
    with open(path, "rb") as stream:
        data = stream.read()
    if b"\0" in data:
        return None
    return data.decode("utf-8", errors="surrogateescape").splitlines(keepends=True)


def diff_file(relative_path, before_path, after_path):
    """A unified diff (-p1 form) of one file, or "" when unchanged.
    before_path is None for a new file."""
    if before_path and after_path and os.path.exists(after_path) and not os.path.islink(after_path):
        if os.path.getsize(before_path) == os.path.getsize(after_path):
            with open(before_path, "rb") as first, open(after_path, "rb") as second:
                if first.read() == second.read():
                    return ""
    before = _read_lines(before_path) if before_path else []
    after = _read_lines(after_path) if after_path and os.path.exists(after_path) else []
    if before is None or after is None:
        raise PatchError(f"{relative_path} is a binary file and cannot go in a patch")
    if before == after:
        return ""
    old_name = f"a/{relative_path}" if before_path else "/dev/null"
    new_name = f"b/{relative_path}" if after_path and os.path.exists(after_path) else "/dev/null"
    lines = []
    for line in difflib.unified_diff(before, after, old_name, new_name, n=3):
        if not line.endswith("\n"):
            line += "\n\\ No newline at end of file\n"
        lines.append(line)
    return "".join(lines)


def changed_files(pristine_tree, work_tree, added=()):
    """[(relative path, diff)] of every file of the pristine tree that
    differs in the work tree (or is gone), and of the added files."""
    found = []
    for directory, folders, files in os.walk(pristine_tree):
        folders.sort()
        for name in sorted(files):
            before = os.path.join(directory, name)
            if os.path.islink(before):
                continue
            relative = os.path.relpath(before, pristine_tree)
            after = os.path.join(work_tree, relative)
            text = diff_file(relative, before, after)
            if text:
                found.append((relative, text))
    for relative in added:
        if os.path.exists(os.path.join(pristine_tree, relative)):
            continue
        text = diff_file(relative, None, os.path.join(work_tree, relative))
        if text:
            found.append((relative, text))
    return found


def make_patches(port, distfiles, work_tree, work_directory, added=()):
    """Writes patches/ from the differences between a pristine copy of
    the sources and work_tree; returns the names written."""
    scratch = tempfile.mkdtemp(prefix="pristine-", dir=work_directory)
    try:
        pristine_tree = extract.extract_sources(port, distfiles, scratch)
        changes = changed_files(pristine_tree, work_tree, added)
    finally:
        shutil.rmtree(scratch, ignore_errors=True)
    if port.patch_strip != 1:
        raise PatchError(f"{port.origin}: makepatch writes -p1 patches; [patches] strip is {port.patch_strip}")
    directory = port.patches_directory
    if os.path.isdir(directory):
        backup = os.path.join(work_directory, "patches-before-makepatch")
        shutil.rmtree(backup, ignore_errors=True)
        shutil.copytree(directory, backup)
        for name in os.listdir(directory):
            if name.endswith(".patch"):
                os.unlink(os.path.join(directory, name))
    written = []
    if changes:
        os.makedirs(directory, exist_ok=True)
    for relative, text in changes:
        name = patch_name_for(relative)
        with open(os.path.join(directory, name), "w", encoding="utf-8", errors="surrogateescape") as stream:
            stream.write(text)
        written.append(name)
    return written
