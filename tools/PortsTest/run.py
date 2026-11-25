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

"""Runs the ports tool's host tests (tools/PortsTest/test_*.py) and
prints "N tests passed" (or the failures) last; make ports-test runs it.

    run.py [PATTERN]     only the test modules matching test_PATTERN*.py
"""

import os
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)


def main():
    pattern = f"test_{sys.argv[1]}*.py" if len(sys.argv) > 1 else "test_*.py"
    suite = unittest.defaultTestLoader.discover(HERE, pattern=pattern, top_level_dir=HERE)
    result = unittest.TextTestRunner(verbosity=1, stream=sys.stdout).run(suite)
    total = result.testsRun
    failed = len(result.failures) + len(result.errors)
    skipped = len(result.skipped)
    if failed:
        print(f"{failed} of {total} tests FAILED")
        return 1
    print(f"{total - skipped} tests passed, {skipped} skipped")
    return 0


if __name__ == "__main__":
    sys.exit(main())
