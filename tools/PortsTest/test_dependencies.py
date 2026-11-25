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

"""Versions, dependency specifications and the dependency resolver:
build order, cycles, missing ports, version requirements, provides,
the graph outputs, search."""

import unittest

import support
from portstool.resolver import DependencyError, Resolver
from portstool.tree import PortsTree
from portstool.versions import compare_versions, parse_dependency

# (older, newer): each must compare -1 one way and 1 the other. The
# Pascal side (PkgTest) checks the same pairs (make-fixtures.py writes them).
VERSION_PAIRS = [
    ("1.0", "1.1"), ("1.9", "1.10"), ("1.2", "1.2.1"), ("1.0rc1", "1.0"), ("1.0alpha", "1.0beta"),
    ("1.0beta2", "1.0rc1"), ("1.0", "1.0a"), ("1.1.1v", "1.1.1w"), ("1.0", "1.0_1"), ("1.0_1", "1.0_2"),
    ("1.0_9", "1.1"), ("2.0.0", "10.0"), ("0.9.9", "1"), ("3.54.0", "3.54.1"), ("1.0pre1", "1.0"),
    ("5.4.9", "5.5.0"), ("1.00001", "1.2"), ("1.0.0", "1.0.0.1"), ("1.0rc1", "1.0.0"),
]
EQUAL_PAIRS = [("1.0", "1.0"), ("1.01", "1.1"), ("1.0_0", "1.0"), ("1-0", "1.0"), ("1.0A", "1.0a")]


class VersionTests(unittest.TestCase):
    def test_order(self):
        for older, newer in VERSION_PAIRS:
            self.assertEqual(compare_versions(older, newer), -1, (older, newer))
            self.assertEqual(compare_versions(newer, older), 1, (newer, older))

    def test_equal(self):
        for left, right in EQUAL_PAIRS:
            self.assertEqual(compare_versions(left, right), 0, (left, right))

    def test_dependencies(self):
        dependency = parse_dependency("zlib>=1.3")
        self.assertEqual((dependency.name, dependency.operator, dependency.version), ("zlib", ">=", "1.3"))
        self.assertEqual(str(parse_dependency(" lua = 5.4.9 ")), "lua = 5.4.9")
        self.assertEqual(str(parse_dependency("hello")), "hello")
        self.assertTrue(parse_dependency("zlib>=1.3").satisfied_by("1.4"))
        self.assertFalse(parse_dependency("zlib>=1.3").satisfied_by("1.2.13"))
        self.assertTrue(parse_dependency("zlib<2").satisfied_by("1.9"))
        self.assertTrue(parse_dependency("zlib=1.3_1").satisfied_by("1.3_1"))
        self.assertFalse(parse_dependency("zlib>1.3").satisfied_by("1.3"))
        for broken in ("", ">=1", "zlib >=", "zlib ~ 1", "Zlib", "zlib >= 1 2"):
            with self.assertRaises(ValueError, msg=broken):
                parse_dependency(broken)


class ResolverTests(support.ScratchTestCase):
    def tree(self, dependencies, versions=None, provides=None):
        """dependencies: {name: (build list, run list)}."""
        ports = {}
        for name, (build, run) in dependencies.items():
            lines = ["[dependencies]", f"build = {build!r}".replace("'", '"'), f"run = {run!r}".replace("'", '"')]
            if provides and name in provides:
                lines.append(f"provides = {provides[name]!r}".replace("'", '"'))
            version = (versions or {}).get(name, "1.0")
            ports[f"misc/{name}"] = support.port_toml(name, version=version, extra="\n".join(lines) + "\n")
        return PortsTree(self.make_tree(ports))

    def test_order(self):
        tree = self.tree({
            "app": (["libb", "liba"], ["runtime"]),
            "liba": ([], []),
            "libb": (["liba"], []),
            "runtime": ([], ["liba"]),
        })
        order = [port.name for port in Resolver(tree).order([tree.find("app")])]
        self.assertEqual(order[-1], "app")
        self.assertLess(order.index("liba"), order.index("libb"))
        self.assertLess(order.index("liba"), order.index("runtime"))
        self.assertEqual(len(order), 4)
        build_only = [port.name for port in Resolver(tree, kinds=("build",)).order([tree.find("app")])]
        self.assertEqual(build_only, ["liba", "libb", "app"])

    def test_cycle(self):
        tree = self.tree({"a": (["b"], []), "b": ([], ["c"]), "c": (["a"], [])})
        with self.assertRaises(DependencyError) as caught:
            Resolver(tree).order([tree.find("a")])
        self.assertIn("a -> b -> c -> a", str(caught.exception))

    def test_missing_and_versions(self):
        tree = self.tree({"a": (["nosuch"], [])})
        with self.assertRaises(DependencyError):
            Resolver(tree).order([tree.find("a")])
        tree = self.tree({"a": (["b>=2.0"], []), "b": ([], [])}, versions={"b": "1.5"})
        with self.assertRaises(DependencyError) as caught:
            Resolver(tree).order([tree.find("a")])
        self.assertIn("1.5", str(caught.exception))
        tree = self.tree({"a": (["b>=1.2"], []), "b": ([], [])}, versions={"b": "1.10"})
        self.assertEqual(len(Resolver(tree).order([tree.find("a")])), 2)

    def test_provides(self):
        tree = self.tree({"app": ([], ["libz"]), "zlib": ([], [])}, provides={"zlib": ["libz"]})
        order = [port.name for port in Resolver(tree).order([tree.find("app")])]
        self.assertEqual(order, ["zlib", "app"])
        self.assertEqual(tree.find("libz").name, "zlib")
        self.assertIn("(from zlib)", Resolver(tree).text_graph([tree.find("app")]))

    def test_graph_outputs(self):
        tree = self.tree({"app": (["lib"], []), "lib": ([], [])})
        dot = Resolver(tree).dot_graph([tree.find("app")])
        self.assertTrue(dot.startswith("digraph ports {"))
        self.assertIn('"app" -> "lib" [style=dashed, label="build"];', dot)
        edges = Resolver(tree).edges([tree.find("app")])
        self.assertEqual(edges, [("app", "build", "lib", "lib")])

    def test_search_and_find(self):
        tree = self.tree({"alpha": ([], []), "beta": ([], [])})
        self.assertEqual([port.name for port in tree.search(["ALPHA", "test"])], ["alpha"])
        self.assertEqual(tree.find("misc/beta").name, "beta")
        self.assertEqual(len(tree.search(["port"])), 2)

    def test_unreadable_port_reported(self):
        root = self.make_tree({"misc/good": support.port_toml("good")})
        self.write("ports/misc/bad/port.toml", "[port]\nname = 1\n")
        tree = PortsTree(root)
        self.assertEqual([port.name for port in tree.ports()], ["good"])
        self.assertEqual(len(tree.failures()), 1)


if __name__ == "__main__":
    unittest.main()
