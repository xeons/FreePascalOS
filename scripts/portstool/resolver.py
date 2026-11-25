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

"""The dependency graph between ports: the order to build them in (every
port after what it needs), cycles found and named, versions checked,
and the graph printed as text or in Graphviz's dot language."""

from .portfile import PortError


class DependencyError(PortError):
    pass


class Resolver:
    """kinds says which edges count: "build", "run" or both. Run
    dependencies of build dependencies count too (a library's own
    libraries must be in the sysroot)."""

    def __init__(self, tree, kinds=("build", "run")):
        self.tree = tree
        self.kinds = kinds

    def dependencies_of(self, port):
        found = []
        if "build" in self.kinds:
            found += [("build", dependency) for dependency in port.build_dependencies]
        if "run" in self.kinds:
            found += [("run", dependency) for dependency in port.run_dependencies]
        return found

    def _provider(self, port, dependency):
        provider = self.tree.provider(dependency.name)
        if provider is None:
            raise DependencyError(f"{port.name} needs {dependency}, which no port provides")
        if provider.name == dependency.name and not dependency.satisfied_by(provider.full_version):
            raise DependencyError(
                f"{port.name} needs {dependency}, but the port is at {provider.full_version}")
        return provider

    def order(self, ports):
        """Every port the given ones need, then the given ones: each after
        all it depends on. Raises DependencyError on a cycle."""
        ordered = []
        state = {}   # name -> "visiting" | "done"
        stack = []

        def visit(port):
            mark = state.get(port.name)
            if mark == "done":
                return
            if mark == "visiting":
                cycle = stack[stack.index(port.name):] + [port.name]
                raise DependencyError("dependency cycle: " + " -> ".join(cycle))
            state[port.name] = "visiting"
            stack.append(port.name)
            for _, dependency in self.dependencies_of(port):
                visit(self._provider(port, dependency))
            stack.pop()
            state[port.name] = "done"
            ordered.append(port)

        for port in ports:
            visit(port)
        return ordered

    def edges(self, ports):
        """(from, kind, to, dependency text) for every port in order()."""
        result = []
        for port in self.order(ports):
            for kind, dependency in self.dependencies_of(port):
                result.append((port.name, kind, self._provider(port, dependency).name, str(dependency)))
        return result

    def text_graph(self, ports):
        lines = []
        for port in self.order(ports):
            lines.append(f"{port.name} {port.full_version}")
            for kind, dependency in self.dependencies_of(port):
                provider = self._provider(port, dependency)
                via = "" if provider.name == dependency.name else f" (from {provider.name})"
                lines.append(f"  {kind}: {dependency}{via}")
        return "\n".join(lines)

    def dot_graph(self, ports):
        lines = ["digraph ports {", "  rankdir=LR;"]
        for port in self.order(ports):
            lines.append(f'  "{port.name}" [label="{port.name}\\n{port.full_version}"];')
        for source, kind, target, text in self.edges(ports):
            style = "solid" if kind == "run" else "dashed"
            lines.append(f'  "{source}" -> "{target}" [style={style}, label="{kind}"];')
        lines.append("}")
        return "\n".join(lines)
