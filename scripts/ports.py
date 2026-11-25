#!/usr/bin/env python3
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

"""The ports tool: builds the software in ports/ into packages for the
system (fetch, verify, extract, patch, configure, build, stage, package),
puts packages on the system disk, makes repositories, and checks ports.
See ports/README.md; the code is in scripts/portstool/."""

import os
import sys

# Run with python3 -I as well: the package is found next to this file.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from portstool.cli import main  # noqa: E402

if __name__ == "__main__":
    sys.exit(main())
