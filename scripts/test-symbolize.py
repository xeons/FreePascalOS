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

"""
Checks scripts/symbolize.py against a real crash report: the kernel's
report of "coretest --crash-without-dispatcher" in a test run's serial
log (coretest runs it; the kernel ends the program and writes its fault
address and modules, Processes.LoadedModules).

    test-symbolize.py SERIAL_LOG USER_BUILD_DIRECTORY

The report must name coretest's CrashOnPurpose. Then the same report is
moved, as if its modules had been loaded elsewhere (each by its own
page-aligned distance, as load address randomization would), and
written once more in the runtime's form (rtl/fpc/syscrash.inc): both
must still name CrashOnPurpose, which only works if symbolize.py takes
the bases from the report.
"""

import os
import random
import re
import subprocess
import sys

SYMBOLIZE = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'symbolize.py')
FAULT_LINE = re.compile(r'\[process\] coretest \((\d+)\): page fault at 0x([0-9A-Fa-f]+) \(coretest\+0x[0-9A-Fa-f]+\)')
MODULE_LINE = re.compile(r'\[process\]   module (\S+) at 0x([0-9A-Fa-f]+)-0x([0-9A-Fa-f]+)')
EXPECTED = 'CORETEST.CRASHONPURPOSE'
PAGE_SIZE = 4096


def find_report(log_text):
    """The fault address and the modules of the last coretest report."""
    lines = re.sub(r'\x1b\[[0-9;]*[a-zA-Z]', '', log_text).replace('\r', '').splitlines()
    report = None
    for index, line in enumerate(lines):
        match = FAULT_LINE.search(line)
        if match:
            modules = []
            for following in lines[index + 1:]:
                module = MODULE_LINE.search(following)
                if module:
                    modules.append((module.group(1), int(module.group(2), 16), int(module.group(3), 16)))
                elif modules:
                    break
            report = (int(match.group(2), 16), modules)
    return report


def symbolize(report_text, user_directory):
    result = subprocess.run([SYMBOLIZE, '--report', '-', user_directory], input=report_text,
                            capture_output=True, text=True)
    return result.stdout


def kernel_form(address, modules):
    lines = ['[process] coretest (7): page fault at 0x%016X accessing 0x0000000000000000, terminated' % address]
    for name, base, limit in modules:
        lines.append('[process]   module %s at 0x%016X-0x%016X' % (name, base, limit))
    return '\n'.join(lines) + '\n'


def runtime_form(address, modules):
    lines = ['An unhandled exception occurred at $%016X:' % address,
             'EAccessViolation: Access violation',
             '  $%016X' % address, '', 'Modules:']
    for name, base, limit in modules:
        lines.append('  $%016X-$%016X %s' % (base, limit, name))
    return '\n'.join(lines) + '\n'


def moved(address, modules):
    """The report as if each module had been loaded elsewhere."""
    generator = random.Random(address)
    shifted = []
    new_address = None
    for name, base, limit in modules:
        distance = generator.randrange(1, 1 << 20) * PAGE_SIZE
        shifted.append((name, base + distance, limit + distance))
        if base <= address < limit:
            new_address = address + distance
    return new_address, shifted


def check(what, output):
    first = [line for line in output.splitlines() if re.match(r'^[0-9a-f]+ ', line)]
    if not first or EXPECTED not in first[0]:
        print('SYMBOLIZE TEST FAILED (%s): expected %s, got:' % (what, EXPECTED))
        print(output)
        return False
    return True


def main():
    if len(sys.argv) != 3:
        print(__doc__)
        sys.exit(2)
    log_path, user_directory = sys.argv[1], sys.argv[2]
    with open(log_path, 'rb') as log:
        report = find_report(log.read().decode('utf-8', 'replace'))
    if report is None or not report[1]:
        print('SYMBOLIZE TEST FAILED: no report of coretest --crash-without-dispatcher with modules in %s'
              % log_path)
        sys.exit(1)
    address, modules = report
    passed = check('the report as written', symbolize(kernel_form(address, modules), user_directory))
    new_address, new_modules = moved(address, modules)
    passed = check('moved modules, kernel form',
                   symbolize(kernel_form(new_address, new_modules), user_directory)) and passed
    passed = check('moved modules, runtime form',
                   symbolize(runtime_form(new_address, new_modules), user_directory)) and passed
    if not passed:
        sys.exit(1)
    print('symbolize test: passed (coretest crash at 0x%x named %s)' % (address, EXPECTED))


if __name__ == '__main__':
    main()
