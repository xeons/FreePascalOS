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

"""Licences: SPDX expressions checked against the allowlist.

A port's licence is an SPDX licence expression: identifiers joined by
AND and OR, an exception added by WITH, parentheses. Every identifier
(and exception) must be on the allowlist, ports/licenses.txt: the
licences that let the system carry and hand out the software, in source
and binary form, as packages and on the system disk.
"""

import os
import re

from . import paths

_TOKEN = re.compile(r"\s*(\(|\)|[A-Za-z0-9.+-]+)")


class LicenseError(ValueError):
    pass


def load_allowlist(path=None):
    """{"licenses": set, "exceptions": set} from the allowlist file: one
    identifier a line, "exception ID" for licence exceptions, # comments."""
    path = path or os.path.join(paths.PORTS_ROOT, "licenses.txt")
    licenses = set()
    exceptions = set()
    with open(path, encoding="utf-8") as stream:
        for line in stream:
            line = line.split("#", 1)[0].strip()
            if not line:
                continue
            words = line.split()
            if words[0] == "exception" and len(words) == 2:
                exceptions.add(words[1])
            elif len(words) == 1:
                licenses.add(words[0])
            else:
                raise LicenseError(f"{path}: cannot read {line!r}")
    return {"licenses": licenses, "exceptions": exceptions}


def _tokens(expression):
    tokens = []
    position = 0
    while position < len(expression):
        if expression[position:].strip() == "":
            break
        match = _TOKEN.match(expression, position)
        if not match:
            raise LicenseError(f"cannot read the licence expression {expression!r}")
        tokens.append(match.group(1))
        position = match.end()
    return tokens


class _Parser:
    """expression := term (OR term)*; term := factor (AND factor)*;
    factor := ID [WITH EXCEPTION] | ( expression )"""

    def __init__(self, tokens):
        self.tokens = tokens
        self.position = 0
        self.identifiers = []
        self.exceptions = []

    def peek(self):
        return self.tokens[self.position] if self.position < len(self.tokens) else None

    def take(self):
        token = self.peek()
        if token is None:
            raise LicenseError("the licence expression ends too soon")
        self.position += 1
        return token

    def expression(self):
        self.term()
        while self.peek() == "OR":
            self.take()
            self.term()

    def term(self):
        self.factor()
        while self.peek() == "AND":
            self.take()
            self.factor()

    def factor(self):
        token = self.take()
        if token == "(":
            self.expression()
            if self.take() != ")":
                raise LicenseError("a parenthesis is not closed")
            return
        if token in ("AND", "OR", "WITH", ")"):
            raise LicenseError(f"{token} where a licence identifier belongs")
        self.identifiers.append(token)
        if self.peek() == "WITH":
            self.take()
            self.exceptions.append(self.take())


def parse_expression(expression):
    """The licence and exception identifiers of an SPDX expression."""
    parser = _Parser(_tokens(expression))
    parser.expression()
    if parser.peek() is not None:
        raise LicenseError(f"unexpected {parser.peek()!r} in the licence expression")
    return parser.identifiers, parser.exceptions


def check_expression(expression, allowlist):
    """The problems with a licence expression (empty when it is allowed)."""
    try:
        identifiers, exceptions = parse_expression(expression)
    except LicenseError as error:
        return [str(error)]
    problems = []
    for identifier in identifiers:
        if identifier not in allowlist["licenses"]:
            problems.append(f"licence {identifier} is not on the allowlist (ports/licenses.txt)")
    for exception in exceptions:
        if exception not in allowlist["exceptions"]:
            problems.append(f"licence exception {exception} is not on the allowlist (ports/licenses.txt)")
    return problems
