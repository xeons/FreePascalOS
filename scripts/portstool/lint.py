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

"""lint: what can be checked about a port without building it.

Errors: port.toml against the schema, the licence against the
allowlist, the folder against the name and first category, files the
port names (licence texts and scripts under port:, signature keys,
[patches] order), patches that are not unified diffs, dependencies no
port provides, dependency cycles, ports whose version dependencies are
not met. Warnings: a prefix other than /usr/local, a summary ending in a
full stop or starting with the name, a plain http homepage, a status of
"tested" for a C port while the C toolchain is missing.
"""

import os

from . import licenses
from .portfile import Port, PortError
from .resolver import DependencyError, Resolver
from .paths import DEFAULT_PREFIX


def _is_unified_diff(path):
    with open(path, encoding="utf-8", errors="replace") as stream:
        text = stream.read()
    return "\n--- " in "\n" + text and "\n+++ " in text and "\n@@ " in text


def lint_port(port, tree, allowlist):
    errors = []
    warnings = []
    folder = os.path.basename(port.directory)
    if folder != port.base_name:
        errors.append(f"the folder is {folder} but the name is {port.base_name}")
    if port.categories[0] != port.category:
        errors.append(f"the first category is {port.categories[0]} but the port is in {port.category}/")
    errors += licenses.check_expression(port.license, allowlist)
    if port.sources and not port.license_files:
        warnings.append("no license_files: the package carries no licence text")
    for path in port.license_files:
        if path.startswith("port:") and not os.path.exists(port.resolve_port_path(path, port.directory)):
            errors.append(f"license_files: {path} is missing")
    for kind, path in port.scripts.items():
        if not os.path.exists(port.resolve_port_path(path, port.directory)):
            errors.append(f"[install] scripts {kind}: {path} is missing")
    for item in port.install_files:
        if item["from"].startswith("port:") and not os.path.exists(port.resolve_port_path(item["from"], port.directory)):
            errors.append(f"[install] files: {item['from']} is missing")
    for source in port.sources:
        if source.signature and not os.path.exists(os.path.join(port.directory, source.signature.key)):
            errors.append(f"{source.filename}: signature key {source.signature.key} is missing")
    try:
        for patch in port.patch_files():
            if not _is_unified_diff(patch):
                errors.append(f"{os.path.basename(patch)} is not a unified diff")
    except PortError as error:
        errors.append(str(error))
    try:
        Resolver(tree).order([port])
    except DependencyError as error:
        errors.append(str(error))
    if port.prefix != DEFAULT_PREFIX:
        warnings.append(f"prefix {port.prefix}: ported software goes under {DEFAULT_PREFIX}")
    if port.summary.endswith("."):
        warnings.append("the summary ends with a full stop")
    if port.summary.lower().startswith(port.base_name.lower() + " "):
        warnings.append("the summary starts with the port's name")
    if port.homepage.startswith("http://"):
        warnings.append("the homepage is plain http")
    if not port.sources and port.build_system not in ("none", "custom", "fpc"):
        warnings.append("no sources")
    return errors, warnings


def lint(tree, ports=None, toolchain_available=None):
    """Prints the findings; the number of errors."""
    allowlist = licenses.load_allowlist()
    total_errors = 0
    for directory, why in sorted(tree.failures().items()):
        print(f"ERROR {os.path.relpath(directory, tree.root)}: {why}")
        total_errors += 1
    for port in ports if ports is not None else tree.ports():
        errors, warnings = lint_port(port, tree, allowlist)
        if toolchain_available is False and port.toolchain == "c" and port.status == "tested":
            warnings.append("status is tested but the C toolchain is not built here")
        for message in errors:
            print(f"ERROR {port.origin}: {message}")
        for message in warnings:
            print(f"WARNING {port.origin}: {message}")
        total_errors += len(errors)
    return total_errors


def lint_directory(directory, tree):
    try:
        port = Port.load(directory)
    except PortError as error:
        print(f"ERROR {directory}: {error}")
        return 1
    return lint(tree, [port])
