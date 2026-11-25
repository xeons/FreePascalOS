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

"""Extracting sources, applying patches in order with their strip
level, refusing ones that do not apply, and makepatch writing a work
tree's changes back into patches/ so that they apply again."""

import hashlib
import io
import os
import shutil
import tarfile
import unittest

import support
from portstool import extract, patching
from portstool.portfile import Port

ORIGINAL = "line one\nline two\nline three\n"


class PatchTests(support.ScratchTestCase):
    def make_distfile(self, files, name="sample-1.0.tar.gz", top="sample-1.0"):
        buffer = io.BytesIO()
        with tarfile.open(fileobj=buffer, mode="w:gz") as archive:
            for relative, text in files.items():
                data = text.encode()
                info = tarfile.TarInfo(f"{top}/{relative}")
                info.size = len(data)
                info.mode = 0o644
                archive.addfile(info, io.BytesIO(data))
        path = self.path("distfiles", name)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "wb") as stream:
            stream.write(buffer.getvalue())
        return path

    def make_port(self, distfile, strip=1, order=None):
        digest = hashlib.sha256(open(distfile, "rb").read()).hexdigest()
        extra = f"""
            [[sources]]
            url = "https://example.invalid/{os.path.basename(distfile)}"
            sha256 = "{digest}"
            extract_dir = "sample-1.0"

            [patches]
            strip = {strip}
            """
        if order:
            extra += f"order = {order!r}\n".replace("'", '"')
        self.write("ports/misc/sample/port.toml", support.port_toml("sample", extra=extra))
        return Port.load(self.path("ports/misc/sample"))

    def test_extract_and_apply_in_order(self):
        distfile = self.make_distfile({"a.txt": ORIGINAL, "src/b.txt": "b\n"})
        port = self.make_port(distfile, order=["second.patch"])
        # second.patch goes first (order), then first.patch, which needs it.
        self.write("ports/misc/sample/patches/second.patch",
                   "--- a/a.txt\n+++ b/a.txt\n@@ -1,3 +1,3 @@\n line one\n-line two\n+line 2\n line three\n")
        self.write("ports/misc/sample/patches/first.patch",
                   "--- a/a.txt\n+++ b/a.txt\n@@ -1,3 +1,3 @@\n line one\n-line 2\n+line II\n line three\n")
        tree = extract.extract_sources(port, [distfile], self.path("work"))
        self.assertEqual(tree, self.path("work", "sample-1.0"))
        applied = patching.apply_patches(port, tree)
        self.assertEqual(applied, ["second.patch", "first.patch"])
        with open(os.path.join(tree, "a.txt")) as stream:
            self.assertEqual(stream.read(), "line one\nline II\nline three\n")

    def test_strip_level(self):
        distfile = self.make_distfile({"src/b.txt": "b\n"})
        port = self.make_port(distfile, strip=0)
        self.write("ports/misc/sample/patches/p0.patch", "--- src/b.txt\n+++ src/b.txt\n@@ -1 +1 @@\n-b\n+B\n")
        tree = extract.extract_sources(port, [distfile], self.path("work"))
        patching.apply_patches(port, tree)
        with open(os.path.join(tree, "src/b.txt")) as stream:
            self.assertEqual(stream.read(), "B\n")

    def test_reject_fails(self):
        distfile = self.make_distfile({"a.txt": ORIGINAL})
        port = self.make_port(distfile)
        self.write("ports/misc/sample/patches/bad.patch",
                   "--- a/a.txt\n+++ b/a.txt\n@@ -1,3 +1,3 @@\n line one\n-not there\n+x\n line three\n")
        tree = extract.extract_sources(port, [distfile], self.path("work"))
        with self.assertRaises(patching.PatchError):
            patching.apply_patches(port, tree)

    def test_makepatch_round_trip(self):
        distfile = self.make_distfile({"a.txt": ORIGINAL, "src/b.txt": "b\n", "src/c.bin": "\0\1binary"})
        port = self.make_port(distfile)
        self.write("ports/misc/sample/patches/old.patch", "stale\n")
        work = self.path("work")
        tree = extract.extract_sources(port, [distfile], work)
        with open(os.path.join(tree, "a.txt"), "w") as stream:
            stream.write("line one\nline two, edited\nline three\n")
        with open(os.path.join(tree, "src/new.txt"), "w") as stream:
            stream.write("added\n")
        with open(os.path.join(tree, "built.o"), "w") as stream:
            stream.write("made by a build\n")
        os.unlink(os.path.join(tree, "src/b.txt"))
        written = patching.make_patches(port, [distfile], tree, work, added=["src/new.txt"])
        self.assertEqual(sorted(written), ["patch-a.txt.patch", "patch-src_b.txt.patch", "patch-src_new.txt.patch"])
        self.assertFalse(os.path.exists(self.path("ports/misc/sample/patches/old.patch")))
        self.assertTrue(os.path.exists(os.path.join(work, "patches-before-makepatch", "old.patch")))
        # The patches bring a fresh copy to the edited tree.
        fresh = extract.extract_sources(port, [distfile], self.path("fresh"))
        patching.apply_patches(Port.load(port.directory), fresh)
        with open(os.path.join(fresh, "a.txt")) as stream:
            self.assertEqual(stream.read(), "line one\nline two, edited\nline three\n")
        with open(os.path.join(fresh, "src/new.txt")) as stream:
            self.assertEqual(stream.read(), "added\n")
        self.assertFalse(os.path.exists(os.path.join(fresh, "src/b.txt")))
        self.assertFalse(os.path.exists(os.path.join(fresh, "built.o")))

    def test_binary_change_refused(self):
        distfile = self.make_distfile({"c.bin": "\0\1binary"})
        port = self.make_port(distfile)
        work = self.path("work")
        tree = extract.extract_sources(port, [distfile], work)
        with open(os.path.join(tree, "c.bin"), "wb") as stream:
            stream.write(b"\0\2changed")
        with self.assertRaises(patching.PatchError):
            patching.make_patches(port, [distfile], tree, work)

    def test_unsafe_archive_refused(self):
        buffer = io.BytesIO()
        with tarfile.open(fileobj=buffer, mode="w") as archive:
            info = tarfile.TarInfo("../escape.txt")
            info.size = 1
            archive.addfile(info, io.BytesIO(b"x"))
        path = self.path("evil.tar")
        with open(path, "wb") as stream:
            stream.write(buffer.getvalue())
        with self.assertRaises(extract.ExtractError):
            extract.extract_archive(path, self.path("out"))
        self.assertFalse(os.path.exists(self.path("escape.txt")))

    def test_formats(self):
        import lzma
        from compression import zstd
        raw = io.BytesIO()
        with tarfile.open(fileobj=raw, mode="w") as archive:
            info = tarfile.TarInfo("pkg-2/file")
            info.size = 2
            archive.addfile(info, io.BytesIO(b"ok"))
        for suffix, data in ((".tar.xz", lzma.compress(raw.getvalue())), (".tar.zst", zstd.compress(raw.getvalue())),
                             (".tar", raw.getvalue())):
            path = self.path("archive" + suffix)
            with open(path, "wb") as stream:
                stream.write(data)
            target = self.path("out" + suffix)
            extract.extract_archive(path, target)
            with open(os.path.join(target, "pkg-2/file")) as stream:
                self.assertEqual(stream.read(), "ok")
            shutil.rmtree(target)


if __name__ == "__main__":
    unittest.main()
