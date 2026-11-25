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

"""scripts/ports.py: the commands (ports/README.md describes them)."""

import argparse
import os
import shutil
import sys

from . import fetch, image, lint as lint_module, patching, repository
from . import ed25519
from .paths import BuildLayout
from .phases import PHASES, PortBuild
from .portfile import PortError, parse_option_settings, parse_package_file_name
from .resolver import Resolver
from .toolchain import CToolchain, ToolchainMissing
from .tree import PortsTree
from .versions import compare_versions

BUILD_PHASES = ("configure", "build", "stage", "package")


class Session:
    def __init__(self, arguments):
        self.arguments = arguments
        self.tree = PortsTree()
        self.layout = BuildLayout(arguments.arch)
        self.options = parse_option_settings(getattr(arguments, "option", None))

    def find(self, text):
        return self.tree.find(text, self.options or None)

    def build(self, port):
        return PortBuild(port, self.layout, verbose=self.arguments.verbose, jobs=self.arguments.jobs,
                         offline=self.arguments.offline)


def _ports_from(session, names):
    if not names:
        raise PortError("name at least one port")
    return [session.find(name) for name in names]


def run_phase(session, phase, names, with_run_dependencies=False, strict=False, keep_going=False):
    """Runs phase on the ports (and, for the phases that need them, the
    packages of their build dependencies first). Skips (no toolchain)
    are reported and are not failures unless strict."""
    requested = _ports_from(session, names)
    if phase in BUILD_PHASES:
        kinds = ("build", "run") if with_run_dependencies else ("build",)
        ordered = Resolver(session.tree, kinds=kinds).order(requested)
    else:
        ordered = requested
    requested_names = {port.name for port in requested}
    skipped, failed = [], []
    blocked = set()
    for port in ordered:
        target = phase if port.name in requested_names else "package"
        if port.name not in requested_names and session.arguments.reuse_packages:
            existing = os.path.join(session.layout.packages, port.package_file_name(session.layout.processor))
            if os.path.exists(existing):
                continue
        needs = [dependency.name for dependency in port.build_dependencies]
        if any(name in blocked for name in needs):
            print(f"SKIP {port.name}: a build dependency was not built")
            skipped.append(port.name)
            blocked.add(port.name)
            continue
        build = session.build(port)
        try:
            build.run_to(target)
        except ToolchainMissing as reason:
            print(f"SKIP {port.name}: {reason}")
            skipped.append(port.name)
            blocked.add(port.name)
        except (PortError, OSError) as error:
            print(f"FAIL {port.name}: {error}")
            failed.append(port.name)
            blocked.add(port.name)
            if not keep_going:
                break
        finally:
            build.close()
    if failed:
        return 1
    if skipped and strict:
        return 2
    return 0


def command_phase(session, arguments):
    return run_phase(session, arguments.command, arguments.ports, arguments.with_run_dependencies,
                     arguments.strict, arguments.keep_going)


def command_test(session, arguments):
    status = 0
    for port in _ports_from(session, arguments.ports):
        build = session.build(port)
        try:
            build.run_tests()
        except ToolchainMissing as reason:
            print(f"SKIP {port.name}: {reason}")
        except PortError as error:
            print(f"FAIL {port.name}: {error}")
            status = 1
        finally:
            build.close()
    return status


def command_clean(session, arguments):
    if arguments.all:
        if os.path.isdir(session.layout.root):
            shutil.rmtree(session.layout.root)
        return 0
    for port in _ports_from(session, arguments.ports):
        build = session.build(port)
        build.clean()
        build.close()
        print(f"===> {port.name}: cleaned")
    return 0


def command_info(session, arguments):
    for port in _ports_from(session, arguments.ports):
        print(f"Name:          {port.name}")
        print(f"Version:       {port.full_version}")
        print(f"Origin:        {port.origin}")
        print(f"Summary:       {port.summary}")
        print(f"Homepage:      {port.homepage}")
        print(f"Licence:       {port.license}")
        print(f"Maintainer:    {port.maintainer}")
        print(f"Categories:    {' '.join(port.categories)}")
        print(f"Status:        {port.status}")
        print(f"Architectures: {' '.join(port.architectures)}")
        print(f"Build system:  {port.build_system} (toolchain: {port.toolchain})")
        print(f"Prefix:        {port.prefix}")
        for label, items in (("Build needs", port.build_dependencies), ("Run needs", port.run_dependencies)):
            if items:
                print(f"{label + ':':15}{', '.join(str(item) for item in items)}")
        if port.host_tools:
            print(f"Host tools:    {', '.join(port.host_tools)}")
        if port.provides:
            print(f"Provides:      {', '.join(port.provides)}")
        for name, definition in port.option_definitions.items():
            state = "on" if port.options[name] else "off"
            print(f"Option:        {name}={state}  {definition['description']}")
        for name in port.flavors:
            print(f"Flavour:       {port.base_name}@{name}")
        for source in port.sources:
            print(f"Source:        {source.url}")
        patches = [os.path.basename(path) for path in port.patch_files()]
        if patches:
            print(f"Patches:       {', '.join(patches)} (-p{port.patch_strip})")
        print(f"Package:       {port.package_file_name(session.layout.processor)}")
        print()
        print(port.description)
        print()
    return 0


def command_deps(session, arguments):
    kinds = tuple(kind for kind, chosen in (("build", arguments.build), ("run", arguments.run)) if chosen) or ("build", "run")
    resolver = Resolver(session.tree, kinds=kinds)
    ports = _ports_from(session, arguments.ports)
    if arguments.dot:
        print(resolver.dot_graph(ports))
    elif arguments.order:
        print(" ".join(port.name for port in resolver.order(ports)))
    else:
        print(resolver.text_graph(ports))
        print("order: " + " ".join(port.name for port in resolver.order(ports)))
    return 0


def _print_port_line(port):
    print(f"{port.name:20} {port.full_version:12} {port.origin:26} {port.status:9} {port.summary}")


def command_list(session, arguments):
    for port in session.tree.ports():
        if arguments.category and arguments.category not in port.categories:
            continue
        if arguments.status and port.status != arguments.status:
            continue
        _print_port_line(port)
    for directory, why in session.tree.failures().items():
        print(f"(unreadable) {os.path.relpath(directory, session.tree.root)}: {why}", file=sys.stderr)
    return 0


def command_search(session, arguments):
    found = session.tree.search(arguments.words)
    for port in found:
        _print_port_line(port)
    return 0 if found else 1


def command_outdated(session, arguments):
    """Packages (built, or installed under --root) older than their port."""
    seen = {}
    if arguments.root:
        from . import database
        for name, manifest in database.installed_manifests(arguments.root).items():
            seen[name] = manifest.full_version
    elif os.path.isdir(session.layout.packages):
        for file_name in os.listdir(session.layout.packages):
            parsed = parse_package_file_name(file_name)
            if parsed and parsed[2] == session.layout.processor:
                name, version, _ = parsed
                if name not in seen or compare_versions(version, seen[name]) > 0:
                    seen[name] = version
    outdated = 0
    for name, version in sorted(seen.items()):
        port = session.tree.provider(name)
        if port is None:
            print(f"{name:20} {version:12} (no port)")
            continue
        if compare_versions(port.full_version, version) > 0:
            print(f"{name:20} {version:12} < {port.full_version}")
            outdated += 1
    return 1 if outdated else 0


def command_makepatch(session, arguments):
    port = session.find(arguments.port)
    build = session.build(port)
    try:
        tree = build.context.source_tree
        written = patching.make_patches(port, build.distfiles(), tree, build.context.work, arguments.add)
    finally:
        build.close()
    for name in written:
        print(f"wrote patches/{name}")
    if port.patch_order:
        print("note: [patches] order names patches makepatch replaced; update it")
    print(f"{len(written)} patch(es) in {os.path.relpath(port.patches_directory)}")
    return 0


def command_makesum(session, arguments):
    port = session.find(arguments.port)
    for source in port.sources:
        path = fetch.distfile_path(source)
        if not os.path.exists(path):
            fetch.download(source.url, path)
        print(f'{source.filename}: sha256 = "{fetch.sha256_of(path)}", size = {os.path.getsize(path)}')
    return 0


def command_lint(session, arguments):
    ports = [session.find(name) for name in arguments.ports] if arguments.ports else None
    available = CToolchain(session.layout).available
    errors = lint_module.lint(session.tree, ports, toolchain_available=available)
    print(f"lint: {errors} error(s)")
    return 1 if errors else 0


def command_install_to_image(session, arguments):
    names = list(arguments.ports)
    if arguments.list:
        names += image.read_list(arguments.list)
    os.makedirs(arguments.root, exist_ok=True)
    if not names:
        return 0
    status = run_phase(session, "package", names, with_run_dependencies=True,
                       strict=False, keep_going=False)
    if status:
        return status
    requested = _ports_from(session, names)
    epoch = max(1, int(os.environ.get("SOURCE_DATE_EPOCH", "1")))
    for port in Resolver(session.tree, kinds=("run",)).order(requested):
        path = os.path.join(session.layout.packages, port.package_file_name(session.layout.processor))
        if not os.path.exists(path):
            print(f"SKIP {port.name}: no package (not buildable here)")
            continue
        image.install_package_file(path, arguments.root, epoch)
    return 0


def command_repo(session, arguments):
    count = repository.write_repository(arguments.directory, arguments.name, arguments.key)
    signed = " (signed)" if arguments.key else ""
    print(f"{arguments.directory}/INDEX: {count} package(s){signed}")
    return 0


def command_keygen(session, arguments):
    ed25519.write_key_pair(arguments.secret, arguments.public)
    print(f"secret key: {arguments.secret}\npublic key: {arguments.public} (copy to /etc/pkg/keys/)")
    return 0


def make_parser():
    parser = argparse.ArgumentParser(prog="ports.py", description="Build ported software into packages.")
    parser.add_argument("--arch", default=os.environ.get("ARCH", "amd64"), help="amd64 or arm64 (default: $ARCH or amd64)")
    parser.add_argument("-v", "--verbose", action="store_true", help="show build output")
    parser.add_argument("-j", "--jobs", type=int, default=None, help="parallel jobs (default: processors)")
    parser.add_argument("--offline", action="store_true", help="never download; use the distfile cache")
    parser.add_argument("-o", "--option", action="append", metavar="NAME=on|off", help="set a port option")
    commands = parser.add_subparsers(dest="command", required=True)

    for phase in PHASES:
        sub = commands.add_parser(phase, help=f"run the port(s) up to {phase}")
        sub.add_argument("ports", nargs="+")
        sub.add_argument("-r", "--with-run-dependencies", action="store_true",
                         help="also package the run dependencies")
        sub.add_argument("--strict", action="store_true", help="a skipped port fails (status 2)")
        sub.add_argument("-k", "--keep-going", action="store_true", help="go on after a failure")
        sub.add_argument("--reuse-packages", action="store_true", help="do not rebuild dependencies already packaged")
        sub.set_defaults(handler=command_phase)

    sub = commands.add_parser("test", help="run the port's [test] commands after building")
    sub.add_argument("ports", nargs="+")
    sub.set_defaults(handler=command_test)

    sub = commands.add_parser("clean", help="remove the port's work folder")
    sub.add_argument("ports", nargs="*")
    sub.add_argument("--all", action="store_true", help="remove all ports' work, packages and logs")
    sub.set_defaults(handler=command_clean)

    sub = commands.add_parser("install-to-image", help="install packages into a system disk root")
    sub.add_argument("--root", required=True)
    sub.add_argument("--list", help="a list file (ports/image.list)")
    sub.add_argument("ports", nargs="*")
    sub.set_defaults(handler=command_install_to_image)

    sub = commands.add_parser("info", help="describe ports")
    sub.add_argument("ports", nargs="+")
    sub.set_defaults(handler=command_info)

    sub = commands.add_parser("deps", help="dependency graph and build order")
    sub.add_argument("ports", nargs="+")
    sub.add_argument("--build", action="store_true", help="build dependencies only")
    sub.add_argument("--run", action="store_true", help="run dependencies only")
    sub.add_argument("--dot", action="store_true", help="Graphviz output")
    sub.add_argument("--order", action="store_true", help="only the order, one line")
    sub.set_defaults(handler=command_deps)

    sub = commands.add_parser("list", help="list the ports")
    sub.add_argument("--category")
    sub.add_argument("--status", choices=("tested", "untested", "broken"))
    sub.set_defaults(handler=command_list)

    sub = commands.add_parser("search", help="find ports by words")
    sub.add_argument("words", nargs="+")
    sub.set_defaults(handler=command_search)

    sub = commands.add_parser("outdated", help="packages older than their ports")
    sub.add_argument("--root", help="compare the packages installed under this root instead")
    sub.set_defaults(handler=command_outdated)

    sub = commands.add_parser("makepatch", help="write the work tree's changes into patches/")
    sub.add_argument("port")
    sub.add_argument("--add", action="append", default=[], metavar="PATH", help="a new file to include")
    sub.set_defaults(handler=command_makepatch)

    sub = commands.add_parser("makesum", help="print the SHA-256 and size of the port's distfiles")
    sub.add_argument("port")
    sub.set_defaults(handler=command_makesum)

    sub = commands.add_parser("lint", help="check ports without building them")
    sub.add_argument("ports", nargs="*")
    sub.set_defaults(handler=command_lint)

    sub = commands.add_parser("repo", help="write a repository index for a folder of packages")
    sub.add_argument("directory")
    sub.add_argument("--name", default="ports", help="the repository's name")
    sub.add_argument("--key", help="an Ed25519 secret key file to sign the index with")
    sub.set_defaults(handler=command_repo)

    sub = commands.add_parser("keygen", help="make an Ed25519 key pair for signing repositories")
    sub.add_argument("secret")
    sub.add_argument("public")
    sub.set_defaults(handler=command_keygen)
    return parser


def main(argv=None):
    arguments = make_parser().parse_args(argv)
    try:
        session = Session(arguments)
        return arguments.handler(session, arguments)
    except PortError as error:
        print(f"ports.py: {error}", file=sys.stderr)
        return 1
