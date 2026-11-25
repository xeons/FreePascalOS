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

"""A small JSON Schema checker: the subset ports/port.schema.json uses
(type, required, properties, additionalProperties, enum, pattern, items,
minItems, minimum), so the schema file is both the specification and
what lint checks against, without a module the build machine may lack."""

import json
import os
import re

from . import paths

_TYPES = {
    "object": dict,
    "array": list,
    "string": str,
    "boolean": bool,
    "number": (int, float),
}


def _is_type(value, name):
    if name == "integer":
        return isinstance(value, int) and not isinstance(value, bool)
    if name in ("number",) and isinstance(value, bool):
        return False
    return isinstance(value, _TYPES[name])


def validate(value, schema, where="", problems=None):
    """The problems of value against schema, as "where: what" texts."""
    if problems is None:
        problems = []
    label = where or "(top)"
    if "enum" in schema and value not in schema["enum"]:
        allowed = ", ".join(json.dumps(item) for item in schema["enum"])
        problems.append(f"{label}: {json.dumps(value)} is not one of {allowed}")
        return problems
    expected = schema.get("type")
    if expected and not _is_type(value, expected):
        problems.append(f"{label}: should be {'an' if expected[0] in 'aeio' else 'a'} {expected}")
        return problems
    if isinstance(value, str) and "pattern" in schema and not re.search(schema["pattern"], value):
        problems.append(f"{label}: {value!r} does not match {schema['pattern']}")
    if isinstance(value, (int, float)) and not isinstance(value, bool) and "minimum" in schema:
        if value < schema["minimum"]:
            problems.append(f"{label}: {value} is below {schema['minimum']}")
    if isinstance(value, list):
        if len(value) < schema.get("minItems", 0):
            problems.append(f"{label}: needs at least {schema['minItems']} item(s)")
        if "items" in schema:
            for index, item in enumerate(value):
                validate(item, schema["items"], f"{where}[{index}]", problems)
    if isinstance(value, dict):
        for key in schema.get("required", []):
            if key not in value:
                problems.append(f"{label}: {key} is missing")
        properties = schema.get("properties", {})
        extra = schema.get("additionalProperties", True)
        for key, item in value.items():
            child = f"{where}.{key}" if where else key
            if key in properties:
                validate(item, properties[key], child, problems)
            elif extra is False:
                problems.append(f"{label}: unknown key {key}")
            elif isinstance(extra, dict):
                validate(item, extra, child, problems)
    return problems


_port_schema = None


def port_schema():
    global _port_schema
    if _port_schema is None:
        with open(os.path.join(paths.PORTS_ROOT, "port.schema.json"), encoding="utf-8") as stream:
            _port_schema = json.load(stream)
    return _port_schema
