#!/usr/bin/env python3
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

"""Makes what tools/PkgTest (pkg's units on the host) reads, with the
ports tool's own code, so pkg is checked against what the ports tool
really writes:

    versions.txt          LEFT RIGHT ORDER, ordered by portstool.versions
    packages/*.pkg.tar.zst
        alpha-1.0         files, a folder, a link, both kinds of scripts
        alpha-1.1         one file changed, one gone, one new
        beta-1.0          needs alpha >= 1.0
        needy-1.0         needs alpha >= 2.0 (refused)
        clash-1.0         a file that belongs to alpha
        corrupt-1.0       a file that does not match its manifest checksum
        failing-1.0       a pre-install script (the test's runner fails it)
        rival-1.0         conflicts with alpha
        arm-1.0           for aarch64
    repository/           alpha-1.1, beta-1.0, INDEX, INDEX.sig
    bad-repository/       the same, INDEX changed after signing
    keys/test.pub         the key both are signed with
    image-root/           alpha-1.0 installed by install-to-image

    make-fixtures.py OUTPUT-DIRECTORY
"""

import io
import os
import shutil
import sys
import tarfile

HERE = os.path.dirname(os.path.abspath(__file__))
SOURCE_ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(SOURCE_ROOT, "scripts"))
sys.path.insert(0, os.path.join(SOURCE_ROOT, "tools", "PortsTest"))

from portstool import ed25519, image, repository, stage  # noqa: E402
from portstool import zstdcodec as zstd  # noqa: E402
from portstool.manifest import Manifest  # noqa: E402
from portstool.package import write_package  # noqa: E402
from portstool.versions import compare_versions  # noqa: E402
from test_dependencies import EQUAL_PAIRS, VERSION_PAIRS  # noqa: E402

EPOCH = 1700000000
# A fixed key, so the fixtures are the same every time.
SEED = bytes(range(32))


def make_package(output, scratch, name, version, files, links=(), depends=(), conflicts=(), scripts=None,
                 architecture="x86_64"):
    stage_root = os.path.join(scratch, f"stage-{name}-{version}")
    shutil.rmtree(stage_root, ignore_errors=True)
    for relative, (text, mode) in files.items():
        path = os.path.join(stage_root, relative)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8") as stream:
            stream.write(text)
        os.chmod(path, mode)
    for relative, target in links:
        path = os.path.join(stage_root, relative)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        os.symlink(target, path)
    stage.normalize_tree(stage_root, EPOCH)
    directories, file_entries, link_entries = stage.collect_entries(stage_root)
    scripts = scripts or {}
    manifest = Manifest(
        name=name, version=version, revision=0, origin=f"misc/{name}", architecture=architecture,
        summary=f"The {name} test package", license="MIT", maintainer="tests",
        homepage="https://example.invalid/", depends=list(depends), conflicts=list(conflicts),
        provides=[f"{name}-provided"], scripts=sorted(scripts), tests=[f"echo {name}"],
        directories=directories, files=file_entries, links=link_entries)
    path = os.path.join(output, f"{name}-{version}-{architecture}.pkg.tar.zst")
    write_package(path, manifest, f"The {name} package, for the tests.\n", scripts, stage_root, EPOCH)
    return path


def corrupt(path, member_name):
    """Changes one file's data after the manifest was written."""
    with open(path, "rb") as stream:
        raw = zstd.decompress(stream.read())
    source = tarfile.open(fileobj=io.BytesIO(raw))
    output = io.BytesIO()
    with tarfile.open(fileobj=output, mode="w", format=tarfile.PAX_FORMAT) as target:
        for member in source.getmembers():
            data = source.extractfile(member).read() if member.isfile() else None
            if member.name == member_name:
                data = data.upper()
            if data is not None:
                target.addfile(member, io.BytesIO(data))
            else:
                target.addfile(member)
    with open(path, "wb") as stream:
        stream.write(zstd.compress(output.getvalue()))


def main():
    output = os.path.abspath(sys.argv[1])
    shutil.rmtree(output, ignore_errors=True)
    packages = os.path.join(output, "packages")
    scratch = os.path.join(output, "scratch")
    os.makedirs(packages)
    os.makedirs(scratch)

    with open(os.path.join(output, "versions.txt"), "w") as stream:
        for left, right in VERSION_PAIRS + EQUAL_PAIRS:
            stream.write(f"{left} {right} {compare_versions(left, right)}\n")
            stream.write(f"{right} {left} {compare_versions(right, left)}\n")

    alpha_files = {
        "usr/local/bin/alpha": ("#!/bin/sh\necho alpha\n", 0o755),
        "usr/local/share/alpha/data.txt": ("alpha data\n", 0o644),
        "usr/local/share/alpha/old.txt": ("only in 1.0\n", 0o644),
        "usr/local/share/licenses/alpha/LICENSE": ("MIT\n", 0o644),
    }
    alpha_scripts = {"post-install": "echo installed\n", "pre-remove": "echo removing\n",
                     "post-remove": "echo removed\n"}
    make_package(packages, scratch, "alpha", "1.0", alpha_files,
                 links=[("usr/local/share/alpha/current", "data.txt")], scripts=alpha_scripts)
    newer = dict(alpha_files)
    del newer["usr/local/share/alpha/old.txt"]
    newer["usr/local/share/alpha/data.txt"] = ("alpha data, version 1.1\n", 0o644)
    newer["usr/local/share/alpha/new.txt"] = ("only in 1.1\n", 0o600)
    make_package(packages, scratch, "alpha", "1.1", newer,
                 links=[("usr/local/share/alpha/current", "data.txt")], scripts=alpha_scripts)
    make_package(packages, scratch, "beta", "1.0", {"usr/local/bin/beta": ("beta\n", 0o755)},
                 depends=["alpha >= 1.0"])
    make_package(packages, scratch, "needy", "1.0", {"usr/local/bin/needy": ("needy\n", 0o755)},
                 depends=["alpha >= 2.0"])
    make_package(packages, scratch, "clash", "1.0", {"usr/local/share/alpha/data.txt": ("clash\n", 0o644),
                                                      "usr/local/bin/clash": ("clash\n", 0o755)})
    corrupt_path = make_package(packages, scratch, "corrupt", "1.0",
                                {"usr/local/share/corrupt/a.txt": ("first\n", 0o644),
                                 "usr/local/share/corrupt/b.txt": ("second\n", 0o644)})
    corrupt(corrupt_path, "usr/local/share/corrupt/b.txt")
    make_package(packages, scratch, "failing", "1.0", {"usr/local/bin/failing": ("failing\n", 0o755)},
                 scripts={"pre-install": "exit 1\n"})
    make_package(packages, scratch, "rival", "1.0", {"usr/local/bin/rival": ("rival\n", 0o755)}, conflicts=["alpha"])
    make_package(packages, scratch, "arm", "1.0", {"usr/local/bin/arm": ("arm\n", 0o755)}, architecture="aarch64")

    keys = os.path.join(output, "keys")
    os.makedirs(keys)
    secret = os.path.join(scratch, "test.key")
    ed25519.write_key_pair(secret, os.path.join(keys, "test.pub"), SEED)
    for folder in ("repository", "bad-repository"):
        target = os.path.join(output, folder)
        os.makedirs(target)
        for name in ("alpha-1.1-x86_64.pkg.tar.zst", "beta-1.0-x86_64.pkg.tar.zst"):
            shutil.copy(os.path.join(packages, name), target)
        repository.write_repository(target, "test", secret)
    with open(os.path.join(output, "bad-repository", "INDEX"), "a") as stream:
        stream.write("package evil\nversion 1\nfile evil.pkg.tar.zst\nsize 1\nsha256 " + "0" * 64 + "\nend\n")

    image_root = os.path.join(output, "image-root")
    image.install_package_file(os.path.join(packages, "alpha-1.0-x86_64.pkg.tar.zst"), image_root, EPOCH,
                               log=lambda text: None)

    shutil.rmtree(scratch)
    with open(os.path.join(output, "manifest.txt"), "w") as stream:
        stream.write("pkg test fixtures\n")


if __name__ == "__main__":
    main()
