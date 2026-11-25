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

"""A port: its port.toml read, checked against the schema and given its
defaults, with the options and the flavour chosen for this build."""

import os
import tomllib
from dataclasses import dataclass, field

from . import paths, schema, versions

DEFAULT_TOOLCHAINS = {
    "autotools": "c", "meson": "c", "cmake": "c", "make": "c",
    "fpc": "fpc", "custom": "none", "none": "none",
}
PACKAGE_SUFFIX = ".pkg.tar.zst"
SCRIPT_NAMES = ("pre_install", "post_install", "pre_remove", "post_remove")


class PortError(Exception):
    pass


@dataclass
class Signature:
    url: str
    type: str
    key: str


@dataclass
class Source:
    url: str
    sha256: str
    mirrors: list = field(default_factory=list)
    filename: str = ""
    size: int = -1
    extract: bool = True
    extract_dir: str = ""
    signature: Signature = None

    @property
    def urls(self):
        return [self.url] + list(self.mirrors)


def split_flavor(text):
    """"name@flavor" -> (name, flavor); "name" -> (name, None)."""
    if "@" in text:
        name, _, flavor = text.partition("@")
        return name, flavor or None
    return text, None


def parse_option_settings(settings):
    """["docs=off", "nls=on"] -> {"docs": False, "nls": True}."""
    result = {}
    for setting in settings or []:
        name, separator, value = setting.partition("=")
        if not separator or value.lower() not in ("on", "off", "yes", "no", "true", "false", "1", "0"):
            raise PortError(f"an option is NAME=on or NAME=off, not {setting!r}")
        result[name] = value.lower() in ("on", "yes", "true", "1")
    return result


def package_file_name(name, full_version, processor):
    return f"{name}-{full_version}-{processor}{PACKAGE_SUFFIX}"


def parse_package_file_name(file_name):
    """(name, full version, processor) of a package file's name, or None."""
    base = os.path.basename(file_name)
    if not base.endswith(PACKAGE_SUFFIX):
        return None
    stem = base[: -len(PACKAGE_SUFFIX)]
    parts = stem.rsplit("-", 2)
    if len(parts) != 3:
        return None
    return parts[0], parts[1], parts[2]


class Port:
    def __init__(self, directory, data, flavor=None, option_settings=None):
        self.directory = os.path.abspath(directory)
        self.data = data
        problems = schema.validate(data, schema.port_schema())
        if problems:
            raise PortError(f"{self.origin}: " + "; ".join(problems))
        port = data["port"]
        self.base_name = port["name"]
        self.version = port["version"]
        self.revision = port.get("revision", 0)
        self.summary = port["summary"]
        self.description = port["description"].strip()
        self.homepage = port["homepage"]
        self.license = port["license"]
        self.license_files = list(port.get("license_files", []))
        self.maintainer = port["maintainer"]
        self.categories = list(port["categories"])
        self.status = port.get("status", "untested")
        self.architectures = list(port.get("architectures", ["x86_64", "aarch64"]))
        self.conflicts = list(port.get("conflicts", []))
        self.sources = [self._source(item) for item in data.get("sources", [])]

        self.flavor = flavor
        self.flavors = data.get("flavors", {})
        flavor_options = {}
        self.name = self.base_name
        if flavor:
            if flavor not in self.flavors:
                raise PortError(f"{self.origin}: no flavour {flavor!r} (has: {', '.join(self.flavors) or 'none'})")
            definition = self.flavors[flavor]
            self.name = self.base_name + definition.get("suffix", "-" + flavor)
            self.summary = definition.get("summary", self.summary)
            flavor_options = definition.get("options", {})

        self.option_definitions = data.get("options", {})
        self.options = {name: item["default"] for name, item in self.option_definitions.items()}
        for name, enabled in list(flavor_options.items()) + list((option_settings or {}).items()):
            if name not in self.option_definitions:
                raise PortError(f"{self.origin}: no option {name!r}")
            self.options[name] = enabled

        dependencies = data.get("dependencies", {})
        build_texts = list(dependencies.get("build", []))
        run_texts = list(dependencies.get("run", []))
        for name, enabled in self.options.items():
            if enabled:
                build_texts += self.option_definitions[name].get("build_dependencies", [])
                run_texts += self.option_definitions[name].get("run_dependencies", [])
        try:
            self.build_dependencies = [versions.parse_dependency(text) for text in build_texts]
            self.run_dependencies = [versions.parse_dependency(text) for text in run_texts]
        except ValueError as error:
            raise PortError(f"{self.origin}: {error}") from None
        self.host_tools = list(dependencies.get("host", []))
        self.provides = list(dependencies.get("provides", []))

        build = data["build"]
        self.build_system = build["system"]
        self.toolchain = build.get("toolchain", DEFAULT_TOOLCHAINS[self.build_system])
        self.build_directory = build.get("directory", ".")
        self.out_of_tree = build.get("out_of_tree", self.build_system in ("meson", "cmake"))
        self.parallel = build.get("parallel", True)
        self.configure_script = build.get("configure_script", "configure")
        self.configure_args = list(build.get("configure_args", []))
        self.make_args = list(build.get("make_args", []))
        for name, enabled in self.options.items():
            definition = self.option_definitions[name]
            self.configure_args += definition.get("configure_on" if enabled else "configure_off", [])
            self.make_args += definition.get("make_on" if enabled else "make_off", [])
        self.install_args = list(build.get("install_args", []))
        self.install_target = build.get("install_target", "install")
        self.environment = dict(build.get("environment", {}))
        self.fpc = dict(build.get("fpc", {}))
        self.steps = dict(build.get("steps", {}))
        if self.build_system == "fpc" and not self.fpc.get("programs"):
            raise PortError(f"{self.origin}: an fpc build needs [build.fpc] programs")
        if self.build_system == "custom" and not self.steps.get("install"):
            raise PortError(f"{self.origin}: a custom build needs [build.steps] install")

        install = data.get("install", {})
        self.prefix = install.get("prefix", paths.DEFAULT_PREFIX)
        self.install_files = list(install.get("files", []))
        self.docs = list(install.get("docs", []))
        self.remove_patterns = list(install.get("remove", []))
        self.strip = install.get("strip", True)
        self.scripts = dict(install.get("scripts", {}))

        patches = data.get("patches", {})
        self.patch_strip = patches.get("strip", 1)
        self.patch_order = list(patches.get("order", []))

        tests = data.get("test", {})
        self.test_commands = list(tests.get("commands", []))
        self.system_tests = list(tests.get("system", []))

    @classmethod
    def load(cls, directory, flavor=None, option_settings=None):
        path = os.path.join(directory, "port.toml")
        try:
            with open(path, "rb") as stream:
                data = tomllib.load(stream)
        except FileNotFoundError:
            raise PortError(f"{directory}: no port.toml") from None
        except tomllib.TOMLDecodeError as error:
            raise PortError(f"{path}: {error}") from None
        return cls(directory, data, flavor, option_settings)

    @staticmethod
    def _source(item):
        signature = item.get("signature")
        url = item["url"]
        return Source(
            url=url,
            sha256=item["sha256"],
            mirrors=list(item.get("mirrors", [])),
            filename=item.get("filename") or os.path.basename(url.split("?", 1)[0].rstrip("/")),
            size=item.get("size", -1),
            extract=item.get("extract", True),
            extract_dir=item.get("extract_dir", ""),
            signature=Signature(**signature) if signature else None,
        )

    @property
    def category(self):
        return os.path.basename(os.path.dirname(self.directory))

    @property
    def origin(self):
        """category/name, the port's place in the tree."""
        return f"{self.category}/{os.path.basename(self.directory)}"

    @property
    def full_version(self):
        return versions.full_version(self.version, self.revision)

    @property
    def files_directory(self):
        return os.path.join(self.directory, "files")

    @property
    def patches_directory(self):
        return os.path.join(self.directory, "patches")

    def patch_files(self):
        """The patches in the order they are applied: [patches] order
        first, then the rest of patches/*.patch by name."""
        directory = self.patches_directory
        if not os.path.isdir(directory):
            return []
        present = sorted(name for name in os.listdir(directory) if name.endswith(".patch"))
        ordered = []
        for name in self.patch_order:
            if name not in present:
                raise PortError(f"{self.origin}: [patches] order names {name}, which is not in patches/")
            ordered.append(name)
        ordered += [name for name in present if name not in ordered]
        return [os.path.join(directory, name) for name in ordered]

    def supports(self, processor):
        return processor in self.architectures

    def package_file_name(self, processor):
        return package_file_name(self.name, self.full_version, processor)

    def resolve_port_path(self, text, base):
        """A path in port.toml: "port:files/x" is in the port's folder,
        anything else relative to base (the source or build folder)."""
        if text.startswith("port:"):
            return os.path.join(self.directory, text[len("port:"):])
        return os.path.join(base, text)
