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

"""port.toml: reading, the schema, defaults, options, flavours, patch
order, package names; and every port of the real tree."""

import os
import unittest

import support
from portstool import licenses, lint, schema
from portstool.portfile import (Port, PortError, package_file_name, parse_option_settings,
                                parse_package_file_name, split_flavor)
from portstool.tree import PortsTree


class PortFileTests(support.ScratchTestCase):
    def load(self, text, flavor=None, options=None):
        self.write("ports/misc/sample/port.toml", text)
        return Port.load(self.path("ports/misc/sample"), flavor, options)

    def test_defaults(self):
        port = self.load(support.port_toml("sample"))
        self.assertEqual(port.name, "sample")
        self.assertEqual(port.origin, "misc/sample")
        self.assertEqual(port.revision, 0)
        self.assertEqual(port.prefix, "/usr/local")
        self.assertEqual(port.toolchain, "none")
        self.assertEqual(port.architectures, ["x86_64", "aarch64"])
        self.assertEqual(port.patch_strip, 1)
        self.assertEqual(port.full_version, "1.0")
        self.assertEqual(port.sources, [])

    def test_revision_in_version(self):
        port = self.load(support.port_toml("sample", revision=3))
        self.assertEqual(port.full_version, "1.0_3")
        self.assertEqual(port.package_file_name("x86_64"), "sample-1.0_3-x86_64.pkg.tar.zst")

    def test_toolchain_follows_build_system(self):
        for system, toolchain in (("autotools", "c"), ("meson", "c"), ("cmake", "c"), ("make", "c"), ("none", "none")):
            port = self.load(support.port_toml("sample", build=f'[build]\nsystem = "{system}"\n'))
            self.assertEqual(port.toolchain, toolchain, system)
        port = self.load(support.port_toml("sample", build='[build]\nsystem = "meson"\n'))
        self.assertTrue(port.out_of_tree)

    def test_schema_errors_are_named(self):
        text = support.port_toml("sample").replace('license = "MIT"\n', "") + '\n[bogus]\nx = 1\n'
        with self.assertRaises(PortError) as caught:
            self.load(text)
        message = str(caught.exception)
        self.assertIn("license is missing", message)
        self.assertIn("unknown key bogus", message)

    def test_bad_values(self):
        for broken in ('name = "Has Space"', 'version = "1.0-2"', 'homepage = "ftp://x"'):
            key = broken.split(" ")[0]
            text = "\n".join(line if not line.startswith(key + " ") else broken
                             for line in support.port_toml("sample").splitlines())
            with self.assertRaises(PortError, msg=broken):
                self.load(text)

    def test_bad_toml(self):
        with self.assertRaises(PortError):
            self.load("[port\nname=")

    def test_sources(self):
        extra = """
            [[sources]]
            url = "https://example.invalid/dl/sample-1.0.tar.gz?x=1"
            sha256 = "%s"
            mirrors = ["https://mirror.invalid/sample-1.0.tar.gz"]
            extract_dir = "sample-1.0"
            signature = { url = "https://example.invalid/sample.sig", type = "gpg", key = "keys.gpg" }
            """ % ("ab" * 32)
        port = self.load(support.port_toml("sample", extra=extra))
        source = port.sources[0]
        self.assertEqual(source.filename, "sample-1.0.tar.gz")
        self.assertEqual(len(source.urls), 2)
        self.assertEqual(source.signature.type, "gpg")

    def test_bad_checksum_refused(self):
        extra = '[[sources]]\nurl = "https://example.invalid/a.tar.gz"\nsha256 = "ABC"\n'
        with self.assertRaises(PortError):
            self.load(support.port_toml("sample", extra=extra))

    def test_options_and_flavors(self):
        extra = """
            [dependencies]
            run = ["base"]

            [options.docs]
            description = "Documentation"
            default = true
            configure_on = ["--enable-docs"]
            configure_off = ["--disable-docs"]
            run_dependencies = ["docviewer"]

            [options.fast]
            description = "Speed"
            default = false
            make_on = ["FAST=1"]

            [flavors.lite]
            summary = "Small sample"
            options = { docs = false }
            """
        text = support.port_toml("sample", extra=extra, build='[build]\nsystem = "autotools"\n')
        port = self.load(text)
        self.assertEqual(port.options, {"docs": True, "fast": False})
        self.assertIn("--enable-docs", port.configure_args)
        self.assertEqual([str(item) for item in port.run_dependencies], ["base", "docviewer"])
        port = self.load(text, options={"fast": True})
        self.assertIn("FAST=1", port.make_args)
        port = self.load(text, flavor="lite")
        self.assertEqual(port.name, "sample-lite")
        self.assertEqual(port.summary, "Small sample")
        self.assertIn("--disable-docs", port.configure_args)
        self.assertEqual([str(item) for item in port.run_dependencies], ["base"])
        with self.assertRaises(PortError):
            self.load(text, flavor="nosuch")
        with self.assertRaises(PortError):
            self.load(text, options={"nosuch": True})

    def test_patch_order(self):
        port_text = support.port_toml("sample", extra='[patches]\nstrip = 0\norder = ["b.patch"]\n')
        self.write("ports/misc/sample/patches/a.patch", "")
        self.write("ports/misc/sample/patches/b.patch", "")
        self.write("ports/misc/sample/patches/c.patch", "")
        self.write("ports/misc/sample/patches/notes.txt", "")
        port = self.load(port_text)
        self.assertEqual([os.path.basename(path) for path in port.patch_files()], ["b.patch", "a.patch", "c.patch"])
        self.assertEqual(port.patch_strip, 0)
        port = self.load(support.port_toml("sample", extra='[patches]\norder = ["gone.patch"]\n'))
        with self.assertRaises(PortError):
            port.patch_files()

    def test_custom_and_fpc_need_their_tables(self):
        with self.assertRaises(PortError):
            self.load(support.port_toml("sample", build='[build]\nsystem = "custom"\n'))
        with self.assertRaises(PortError):
            self.load(support.port_toml("sample", build='[build]\nsystem = "fpc"\n'))

    def test_helpers(self):
        self.assertEqual(split_flavor("sqlite3@minimal"), ("sqlite3", "minimal"))
        self.assertEqual(split_flavor("zlib"), ("zlib", None))
        self.assertEqual(parse_option_settings(["a=on", "b=off"]), {"a": True, "b": False})
        with self.assertRaises(PortError):
            parse_option_settings(["a"])
        name = package_file_name("pkg-selftest", "1.0_2", "aarch64")
        self.assertEqual(parse_package_file_name(name), ("pkg-selftest", "1.0_2", "aarch64"))
        self.assertIsNone(parse_package_file_name("readme.txt"))


class SchemaTests(unittest.TestCase):
    def test_validator(self):
        rules = {"type": "object", "required": ["a"], "additionalProperties": False,
                 "properties": {"a": {"type": "integer", "minimum": 1},
                                "b": {"type": "array", "minItems": 1, "items": {"enum": ["x", "y"]}},
                                "c": {"type": "string", "pattern": "^z"}}}
        self.assertEqual(schema.validate({"a": 2, "b": ["x"], "c": "zz"}, rules), [])
        problems = schema.validate({"a": 0, "b": ["q"], "c": "no", "d": 1}, rules)
        self.assertEqual(len(problems), 4, problems)
        self.assertEqual(schema.validate({"a": True}, rules), ["a: should be an integer"])


class LicenseTests(unittest.TestCase):
    allowlist = {"licenses": {"MIT", "GPL-2.0-or-later", "LGPL-2.1-only"}, "exceptions": {"GCC-exception-3.1"}}

    def test_expressions(self):
        self.assertEqual(licenses.parse_expression("MIT OR (GPL-2.0-or-later AND LGPL-2.1-only)"),
                         (["MIT", "GPL-2.0-or-later", "LGPL-2.1-only"], []))
        self.assertEqual(licenses.parse_expression("GPL-2.0-or-later WITH GCC-exception-3.1"),
                         (["GPL-2.0-or-later"], ["GCC-exception-3.1"]))
        for broken in ("", "MIT OR", "(MIT", "AND MIT", "MIT MIT"):
            with self.assertRaises(licenses.LicenseError, msg=broken):
                licenses.parse_expression(broken)

    def test_allowlist(self):
        self.assertEqual(licenses.check_expression("MIT", self.allowlist), [])
        self.assertEqual(licenses.check_expression("GPL-2.0-or-later WITH GCC-exception-3.1", self.allowlist), [])
        self.assertEqual(len(licenses.check_expression("MIT AND Proprietary-1", self.allowlist)), 1)
        self.assertEqual(len(licenses.check_expression("MIT WITH Odd-exception", self.allowlist)), 1)

    def test_real_allowlist_reads(self):
        allowlist = licenses.load_allowlist()
        self.assertIn("MIT", allowlist["licenses"])
        self.assertIn("blessing", allowlist["licenses"])
        self.assertIn("GCC-exception-3.1", allowlist["exceptions"])


class RealTreeTests(unittest.TestCase):
    def test_every_port_reads_and_lints(self):
        tree = PortsTree()
        self.assertEqual(tree.failures(), {})
        names = [port.name for port in tree.ports()]
        for expected in ("hello", "pkg-selftest", "ptop", "zlib", "lua", "sqlite3", "bash"):
            self.assertIn(expected, names)
        allowlist = licenses.load_allowlist()
        for port in tree.ports():
            errors, _ = lint.lint_port(port, tree, allowlist)
            self.assertEqual(errors, [], port.origin)


if __name__ == "__main__":
    unittest.main()
