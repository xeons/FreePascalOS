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

"""Manifests, packages, the installed database on a system disk root,
repositories and their signatures, Ed25519 against RFC 8032."""

import hashlib
import io
import os
import shutil
import subprocess
import tarfile
import unittest

import support
from portstool import zstdcodec as zstd
from portstool import database, ed25519, image, repository, stage
from portstool.manifest import ManifestError, format_manifest, parse_manifest
from portstool.package import PackageError, PackageReader, write_package


def sample_manifest(stage_root, name="sample", version="1.0", revision=0, depends=(), scripts=()):
    directories, files, links = stage.collect_entries(stage_root)
    return support.Manifest(
        name=name, version=version, revision=revision, origin=f"misc/{name}", architecture="x86_64",
        summary="A sample package", license="MIT", maintainer="tests", homepage="https://example.invalid/",
        depends=list(depends), provides=["sample-provided"], scripts=list(scripts),
        tests=["true"], directories=directories, files=files, links=links)


class ManifestTests(unittest.TestCase):
    def test_round_trip(self):
        manifest = support.Manifest(
            name="m", version="2.1", revision=1, origin="misc/m", flavor="lite", architecture="aarch64",
            summary="Summary with spaces", license="MIT OR Zlib", maintainer="Some One", homepage="https://x.invalid/",
            depends=["zlib >= 1.3", "hello"], provides=["libm"], conflicts=["other"],
            scripts=["post-install"], tests=["m --version | grep -q 2.1"],
            license_files=["usr/local/share/licenses/m/LICENSE"],
            directories=[support.DirectoryEntry("usr/local/share/m", 0o755)],
            files=[support.FileEntry("usr/local/bin/m", 0o755, 3, "a" * 64)],
            links=[support.LinkEntry("usr/local/bin/mm", "m")])
        text = format_manifest(manifest)
        again = parse_manifest(text)
        self.assertEqual(again, manifest)
        self.assertEqual(again.full_version, "2.1_1")
        self.assertEqual(format_manifest(again), text)
        self.assertTrue(text.startswith("format 1\nname m\n"))

    def test_refusals(self):
        good = "format 1\nname x\nversion 1\narchitecture x86_64\n"
        parse_manifest(good)
        for broken in ("name x\nversion 1\narchitecture x86_64\n", good.replace("format 1", "format 2"),
                       good + "file 0644 3 abc usr/x\n", good + "bogus line\n", good + "revision x\n",
                       good + "script sometimes\n", good.replace("name x\n", "")):
            with self.assertRaises(ManifestError, msg=broken):
                parse_manifest(broken)
        manifest = parse_manifest(good)
        for path in ("/abs", "a/../b", "with space", ""):
            manifest.files = [support.FileEntry(path, 0o644, 0, "0" * 64)]
            with self.assertRaises(ManifestError, msg=path):
                format_manifest(manifest)


class PackageTests(support.ScratchTestCase):
    def build(self, name="package.pkg.tar.zst", epoch=1700000000, scripts=None):
        stage_root = self.make_stage(
            {"usr/local/bin/tool": ("#!/bin/sh\necho tool\n", 0o755),
             "usr/local/share/sample/data.txt": ("data\n", 0o644),
             "usr/local/share/licenses/sample/LICENSE": ("MIT\n", 0o644)},
            links=[("usr/local/share/sample/latest", "data.txt")])
        stage.normalize_tree(stage_root, epoch)
        manifest = sample_manifest(stage_root, scripts=sorted(scripts or {}))
        path = self.path(name)
        write_package(path, manifest, "A description.\n", scripts or {}, stage_root, epoch)
        return path, manifest, stage_root

    def test_layout(self):
        path, manifest, _ = self.build(scripts={"post-install": "echo hi\n"})
        with open(path, "rb") as stream:
            raw = zstd.decompress(stream.read())
        with tarfile.open(fileobj=io.BytesIO(raw)) as archive:
            members = archive.getmembers()
            names = [member.name for member in members]
            first = members[0]
            self.assertEqual(names[:3], ["+MANIFEST", "+DESC", "+post-install"])
            self.assertEqual((first.uid, first.gid, first.mtime), (0, 0, 1700000000))
            for member in members:
                self.assertEqual(member.mtime, 1700000000)
                self.assertEqual(member.uname, "root")
        payload = [member for member in members if not member.name.startswith("+")]
        folders_first = [not member.isdir() for member in payload]
        self.assertEqual(folders_first, sorted(folders_first))
        others = [member.name for member in payload if not member.isdir()]
        self.assertEqual(others, sorted(others))
        directories = [entry.path for entry in manifest.directories]
        self.assertIn("usr/local/share/sample", directories)
        self.assertNotIn("usr/local/share", directories)
        self.assertNotIn("usr/local/bin", directories)

    def test_reproducible(self):
        first, _, _ = self.build("one.pkg.tar.zst")
        shutil.rmtree(self.path("stage"))
        second, _, _ = self.build("two.pkg.tar.zst")
        with open(first, "rb") as one, open(second, "rb") as two:
            self.assertEqual(one.read(), two.read())

    def test_reader_and_verify(self):
        path, manifest, _ = self.build(scripts={"pre-remove": "echo bye\n"})
        reader = PackageReader(path)
        self.assertEqual(reader.manifest, manifest)
        self.assertEqual(reader.description, "A description.\n")
        self.assertEqual(reader.scripts, {"pre-remove": "echo bye\n"})
        self.assertEqual(reader.verify(), [])
        root = self.path("root")
        reader.extract_payload(root)
        self.assertEqual(os.readlink(os.path.join(root, "usr/local/share/sample/latest")), "data.txt")
        self.assertEqual(os.stat(os.path.join(root, "usr/local/bin/tool")).st_mode & 0o777, 0o755)
        reader.close()

    def tamper(self, path, change):
        with open(path, "rb") as stream:
            raw = zstd.decompress(stream.read())
        source = tarfile.open(fileobj=io.BytesIO(raw))
        output = io.BytesIO()
        with tarfile.open(fileobj=output, mode="w", format=tarfile.PAX_FORMAT) as target:
            for member in source.getmembers():
                data = source.extractfile(member).read() if member.isfile() else None
                member, data = change(member, data)
                if member is None:
                    continue
                if data is not None:
                    member.size = len(data)
                    target.addfile(member, io.BytesIO(data))
                else:
                    target.addfile(member)
        with open(path, "wb") as stream:
            stream.write(zstd.compress(output.getvalue()))

    def test_tampered_payload_found(self):
        path, _, _ = self.build()

        def change(member, data):
            if member.name == "usr/local/share/sample/data.txt":
                return member, b"changed\n"
            return member, data

        self.tamper(path, change)
        reader = PackageReader(path)
        self.assertEqual(reader.verify(), ["usr/local/share/sample/data.txt: does not match its manifest checksum"])
        reader.close()

    def test_missing_and_extra_members_found(self):
        path, _, _ = self.build()

        def change(member, data):
            if member.name == "usr/local/bin/tool":
                return None, None
            return member, data

        self.tamper(path, change)
        reader = PackageReader(path)
        self.assertIn("usr/local/bin/tool: in the manifest but not in the archive", reader.verify())
        reader.close()

    def test_not_a_package(self):
        bad = self.write("bad.pkg.tar.zst", "nonsense")
        with self.assertRaises(PackageError):
            PackageReader(bad)
        output = io.BytesIO()
        with tarfile.open(fileobj=output, mode="w") as archive:
            info = tarfile.TarInfo("README")
            archive.addfile(info, io.BytesIO(b""))
        with open(bad, "wb") as stream:
            stream.write(zstd.compress(output.getvalue()))
        with self.assertRaises(PackageError):
            PackageReader(bad)


class PackageMaker(support.ScratchTestCase):
    def package(self, name, files, depends=(), version="1.0"):
        stage_root = os.path.join(self.scratch, "stage-" + name)
        for relative, text in files.items():
            path = os.path.join(stage_root, relative)
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, "w") as stream:
                stream.write(text)
        stage.normalize_tree(stage_root, 1)
        manifest = sample_manifest(stage_root, name=name, version=version, depends=depends)
        manifest.provides = []
        path = self.path(f"{name}-{version}-x86_64.pkg.tar.zst")
        write_package(path, manifest, f"{name}\n", {}, stage_root, 1)
        return path


class ImageTests(PackageMaker):
    def test_install_record_and_refuse(self):
        root = self.path("root")
        base = self.package("base", {"usr/local/lib/base.txt": "base\n"})
        app = self.package("app", {"usr/local/bin/app": "app\n"}, depends=["base>=1.0"])
        clash = self.package("clash", {"usr/local/lib/base.txt": "clash\n"})
        with self.assertRaises(image.ImageError):
            image.install_package_file(app, root, 5, log=lambda text: None)
        image.install_package_file(base, root, 5, log=lambda text: None)
        image.install_package_file(app, root, 5, log=lambda text: None)
        installed = database.installed_manifests(root)
        self.assertEqual(sorted(installed), ["app", "base"])
        entry = os.path.join(root, "var/db/pkg/app")
        self.assertEqual(sorted(os.listdir(entry)), ["+DESC", "+INSTALLED", "+MANIFEST"])
        with open(os.path.join(entry, "+INSTALLED")) as stream:
            self.assertEqual(stream.read(), "installed 5\nautomatic no\n")
        self.assertEqual(image.owners(root)["usr/local/lib/base.txt"], "base")
        with self.assertRaises(image.ImageError):
            image.install_package_file(clash, root, 5, log=lambda text: None)

    def test_list_file(self):
        path = self.write("image.list", "# comment\nhello\n\n  ptop  # trailing\n")
        self.assertEqual(image.read_list(path), ["hello", "ptop"])


class Ed25519Tests(unittest.TestCase):
    # RFC 8032, section 7.1, tests 1 to 3.
    VECTORS = [
        ("9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60",
         "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a", "",
         "e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b"),
        ("4ccd089b28ff96da9db6c346ec114e0f5b8a319f35aba624da8cf6ed4fb8a6fb",
         "3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c", "72",
         "92a009a9f0d4cab8720e820b5f642540a2b27b5416503f8fb3762223ebdb69da085ac1e43e15996e458f3613d0f11d8c387b2eaeb4302aeeb00d291612bb0c00"),
        ("c5aa8df43f9f837bedb7442f31dcb7b166d38535076f094b85ce3a2e0b4458f7",
         "fc51cd8e6218a1a38da47ed00230f0580816ed13ba3303ac5deb911548908025", "af82",
         "6291d657deec24024827e69c3abe01a30ce548a284743a445e3680d7db5ac3ac18ff9b538d16f290ae67f760984dc6594a7c15e9716ed28dc027beceea1ec40a"),
    ]

    def test_vectors(self):
        for seed, public, message, signature in self.VECTORS:
            seed_bytes = bytes.fromhex(seed)
            self.assertEqual(ed25519.public_key(seed_bytes).hex(), public)
            self.assertEqual(ed25519.sign(seed_bytes, bytes.fromhex(message)).hex(), signature)
            self.assertTrue(ed25519.verify(bytes.fromhex(public), bytes.fromhex(message), bytes.fromhex(signature)))
            changed = bytearray(bytes.fromhex(signature))
            changed[5] ^= 1
            self.assertFalse(ed25519.verify(bytes.fromhex(public), bytes.fromhex(message), bytes(changed)))
            self.assertFalse(ed25519.verify(bytes.fromhex(public), b"other", bytes.fromhex(signature)))

    @unittest.skipIf(shutil.which("openssl") is None, "openssl is not installed")
    def test_openssl_agrees(self):
        import tempfile
        with tempfile.TemporaryDirectory() as folder:
            key = os.path.join(folder, "key.pem")
            subprocess.run(["openssl", "genpkey", "-algorithm", "ed25519", "-out", key], check=True,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            der = subprocess.run(["openssl", "pkey", "-in", key, "-outform", "DER"], check=True,
                                 stdout=subprocess.PIPE).stdout
            seed = der[-32:]
            message = os.path.join(folder, "message")
            with open(message, "wb") as stream:
                stream.write(b"the index")
            signature = subprocess.run(["openssl", "pkeyutl", "-sign", "-rawin", "-inkey", key, "-in", message],
                                       check=True, stdout=subprocess.PIPE).stdout
            self.assertEqual(ed25519.sign(seed, b"the index"), signature)

    def test_key_files(self):
        import tempfile
        with tempfile.TemporaryDirectory() as folder:
            secret = os.path.join(folder, "repo.key")
            public = os.path.join(folder, "repo.pub")
            seed = ed25519.write_key_pair(secret, public)
            self.assertEqual(os.stat(secret).st_mode & 0o077, 0)
            self.assertEqual(ed25519.read_secret_seed(secret), seed)
            self.assertEqual(ed25519.read_public_key(public), ed25519.public_key(seed))
            with self.assertRaises(ValueError):
                ed25519.read_public_key(secret)


class RepositoryTests(PackageMaker):
    def test_index_and_signature(self):
        folder = self.path("repo")
        os.makedirs(folder)
        for name, version in (("base", "1.0"), ("base", "1.10"), ("base", "1.9"), ("app", "2.0")):
            path = self.package(name, {f"usr/local/share/{name}": version}, version=version)
            shutil.move(path, folder)
        secret = self.path("repo.key")
        public = self.path("repo.pub")
        ed25519.write_key_pair(secret, public)
        self.assertEqual(repository.write_repository(folder, "test", secret), 4)
        with open(os.path.join(folder, "INDEX")) as stream:
            text = stream.read()
        self.assertTrue(text.startswith("format 1\nrepository test\npackage app\n"))
        entries = repository.parse_index(text)
        self.assertEqual([(item["package"], item["version"]) for item in entries],
                         [("app", "2.0"), ("base", "1.0"), ("base", "1.9"), ("base", "1.10")])
        for item in entries:
            with open(os.path.join(folder, item["file"]), "rb") as stream:
                data = stream.read()
            self.assertEqual(item["sha256"], hashlib.sha256(data).hexdigest())
            self.assertEqual(int(item["size"]), len(data))
        self.assertTrue(repository.verify_index(folder, public))
        with open(os.path.join(folder, "INDEX"), "a") as stream:
            stream.write("package evil\n")
        self.assertFalse(repository.verify_index(folder, public))
        repository.write_repository(folder, "test")
        self.assertFalse(os.path.exists(os.path.join(folder, "INDEX.sig")))


if __name__ == "__main__":
    unittest.main()
