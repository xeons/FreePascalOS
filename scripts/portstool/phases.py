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

"""A port's build, phase by phase, as FreeBSD's ports do it:

    fetch -> verify -> extract -> patch -> configure -> build -> stage -> package

Asking for a phase runs every phase before it that has not run yet (a
cookie file in the work folder marks each one done), so `build` after
`patch` goes on where it stopped and `package` alone does everything.
extract starts again from nothing: the work folder is emptied first.
"""

import hashlib
import os
import shutil

from . import extract, fetch, patching, stage
from .builders import builder_for
from .context import BuildContext
from .logs import BuildLog
from .manifest import Manifest
from .package import PackageReader, write_package
from .portfile import PortError

PHASES = ("fetch", "verify", "extract", "patch", "configure", "build", "stage", "package")


class PortBuild:
    def __init__(self, port, layout, verbose=False, jobs=None, offline=False):
        self.port = port
        self.layout = layout
        self.offline = offline
        self.log = BuildLog(layout.log(port.name), verbose=verbose)
        self.context = BuildContext(port, layout, self.log, jobs)
        self.builder = builder_for(self.context)

    def close(self):
        self.log.close()

    # --- cookies --------------------------------------------------------

    def cookie(self, phase):
        return os.path.join(self.context.cookies, phase)

    def done(self, phase):
        return os.path.exists(self.cookie(phase))

    def mark(self, phase):
        os.makedirs(self.context.cookies, exist_ok=True)
        with open(self.cookie(phase), "w", encoding="utf-8"):
            pass

    def forget_after(self, phase):
        for later in PHASES[PHASES.index(phase):]:
            if os.path.exists(self.cookie(later)):
                os.unlink(self.cookie(later))

    # --- running --------------------------------------------------------

    def check_buildable(self):
        """Raises ToolchainMissing (a skip) when this machine cannot build it."""
        if not self.port.supports(self.layout.processor):
            from .toolchain import ToolchainMissing
            raise ToolchainMissing(f"not for {self.layout.processor} (architectures: {', '.join(self.port.architectures)})")
        self.builder.require()

    def fingerprint(self):
        """What the build depends on besides the distfiles: every file of
        the port's folder, the options and flavour, and (for Pascal
        ports) the system's runtime and libraries."""
        digest = hashlib.sha256()
        for directory, folders, files in os.walk(self.port.directory):
            folders.sort()
            for name in sorted(files):
                path = os.path.join(directory, name)
                digest.update(os.path.relpath(path, self.port.directory).encode() + b"\0")
                with open(path, "rb") as stream:
                    digest.update(hashlib.sha256(stream.read()).digest())
        digest.update(repr((self.port.flavor, sorted(self.port.options.items()))).encode())
        settings = None
        if self.port.toolchain == "fpc":
            try:
                settings = self.context.fpc_settings
            except PortError:
                settings = None
        if settings is not None:
            for path in (settings.absolute(settings.startup),
                         os.path.join(settings.absolute(settings.libraries), "libsystem.so")):
                if os.path.exists(path):
                    info = os.stat(path)
                    digest.update(f"{path}:{info.st_size}:{info.st_mtime_ns}".encode())
        return digest.hexdigest()

    def forget_if_changed(self):
        """Starts again from extract when the port changed since its
        cookies were made."""
        marker = os.path.join(self.context.cookies, "fingerprint")
        current = self.fingerprint()
        if os.path.exists(marker):
            with open(marker, encoding="ascii") as stream:
                if stream.read().strip() == current:
                    return
            self.log.note("the port changed: building again from extract")
            self.forget_after("extract")
        os.makedirs(self.context.cookies, exist_ok=True)
        with open(marker, "w", encoding="ascii") as stream:
            stream.write(current + "\n")

    def run_to(self, target):
        if target not in PHASES:
            raise PortError(f"no phase {target}")
        if PHASES.index(target) >= PHASES.index("configure"):
            self.check_buildable()
        if PHASES.index(target) >= PHASES.index("extract"):
            self.forget_if_changed()
        for phase in PHASES[: PHASES.index(target) + 1]:
            # fetch and verify are cheap to check again; the rest run once.
            if phase not in ("fetch", "verify") and self.done(phase):
                continue
            if phase == "extract":
                self.log.restart()
            self.log.phase(self.port.name, phase)
            getattr(self, "do_" + phase)()
            self.mark(phase)

    def distfiles(self):
        return [fetch.distfile_path(source) for source in self.port.sources]

    def do_fetch(self):
        fetch.fetch_port(self.port, self.log, self.offline)

    def do_verify(self):
        for source, path in zip(self.port.sources, self.distfiles()):
            problem = fetch.check_distfile(source, path)
            if problem:
                raise fetch.FetchError(problem)
            fetch.verify_signature(self.port, source, path, self.log, self.offline)
            self.log.note(f"{source.filename}: SHA-256 good")

    def do_extract(self):
        context = self.context
        for name in ("work", "build", "stage", "sysroot", "objects", "tmp", "home", ".cookies"):
            path = os.path.join(context.work, name)
            if os.path.isdir(path):
                shutil.rmtree(path)
        self.mark("fetch")
        self.mark("verify")
        self.forget_if_changed()
        tree = extract.extract_sources(self.port, self.distfiles(), context.extract_directory)
        context.remember_source_tree(tree)
        self.log.note(f"source tree: {tree}")

    def do_patch(self):
        applied = patching.apply_patches(self.port, self.context.source_tree, self.log)
        self.log.note(f"{len(applied)} patch(es) applied")

    def do_configure(self):
        context = self.context
        self.prepare_sysroot()
        if context.port.steps.get("pre_configure"):
            context.run_steps(context.port.steps["pre_configure"], cwd=context.configure_directory)
        self.builder.configure()

    def do_build(self):
        self.builder.build()

    def do_stage(self):
        context = self.context
        if os.path.isdir(context.stage):
            shutil.rmtree(context.stage)
        os.makedirs(context.prefix_in_stage(), exist_ok=True)
        self.builder.install()
        stage.place_extra_files(context)
        if context.port.steps.get("post_install"):
            context.run_steps(context.port.steps["post_install"])
        stage.remove_unwanted(context)
        stage.strip_binaries(context, self.strip_command(), self.log)
        stage.check_inside_prefix(context.stage, context.port.prefix)
        stage.normalize_tree(context.stage, context.epoch)

    def do_package(self):
        path = self.write_package()
        self.log.note(f"package: {path}")
        print(f"===> {self.port.name}: {path}")

    def strip_command(self):
        if self.port.toolchain == "c" and self.context.c_toolchain.available:
            return [self.context.c_toolchain.tool("strip")]
        if self.port.toolchain == "fpc":
            return self.context.fpc_settings.strip
        return None

    def prepare_sysroot(self):
        """A sysroot of the port's own for C builds: the toolchain's,
        with the packages of the build dependencies unpacked into it."""
        context = self.context
        if self.port.toolchain != "c":
            return
        if os.path.isdir(context.sysroot):
            shutil.rmtree(context.sysroot)
        base = context.c_toolchain.base_sysroot
        try:
            shutil.copytree(base, context.sysroot, symlinks=True, copy_function=os.link)
        except OSError:
            shutil.rmtree(context.sysroot, ignore_errors=True)
            shutil.copytree(base, context.sysroot, symlinks=True)
        for package_path in self.build_dependency_packages():
            reader = PackageReader(package_path)
            try:
                reader.extract_payload(context.sysroot)
                self.log.note(f"sysroot: {os.path.basename(package_path)}")
            finally:
                reader.close()

    def build_dependency_packages(self):
        """The packages of every build dependency (and theirs), which the
        caller has built first (cli.py builds in dependency order)."""
        from .resolver import Resolver
        from .tree import PortsTree
        tree = PortsTree()
        found = []
        for dependency_port in Resolver(tree, kinds=("build",)).order([self.port])[:-1]:
            path = os.path.join(self.layout.packages, dependency_port.package_file_name(self.layout.processor))
            if not os.path.exists(path):
                raise PortError(f"{self.port.name} needs the package of {dependency_port.name}: {path} is not built")
            found.append(path)
        return found

    def make_manifest(self):
        port = self.port
        directories, files, links = stage.collect_entries(self.context.stage)
        scripts = sorted(kind.replace("_", "-") for kind in port.scripts)
        return Manifest(
            name=port.name, version=port.version, revision=port.revision, origin=port.origin,
            flavor=port.flavor or "", architecture=self.layout.processor, prefix=port.prefix,
            summary=port.summary, license=port.license, maintainer=port.maintainer, homepage=port.homepage,
            depends=[str(item) for item in port.run_dependencies], provides=list(port.provides),
            conflicts=list(port.conflicts), scripts=scripts, tests=list(port.system_tests),
            license_files=stage.license_paths(port),
            directories=directories, files=files, links=links)

    def write_package(self):
        port = self.port
        os.makedirs(self.layout.packages, exist_ok=True)
        scripts = {}
        for kind, relative in port.scripts.items():
            with open(port.resolve_port_path(relative, port.directory), encoding="utf-8") as stream:
                scripts[kind.replace("_", "-")] = stream.read()
        path = os.path.join(self.layout.packages, port.package_file_name(self.layout.processor))
        return write_package(path, self.make_manifest(), port.description, scripts,
                             self.context.stage, self.context.epoch)

    def run_tests(self):
        """[test] commands, in the build folder, after build."""
        self.run_to("build")
        if not self.port.test_commands:
            self.log.note("no [test] commands")
            return
        self.log.phase(self.port.name, "test")
        self.context.run_steps(self.port.test_commands)

    def clean(self):
        if os.path.isdir(self.context.work):
            shutil.rmtree(self.context.work)
