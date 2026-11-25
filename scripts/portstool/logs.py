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

"""A build log per port: every phase's commands and their output go to
build/ARCH/ports/logs/NAME.log; the terminal gets one line per phase
(everything with --verbose)."""

import os
import subprocess
import sys
import time


class CommandFailed(Exception):
    pass


class BuildLog:
    def __init__(self, path, verbose=False, append=True):
        self.path = path
        self.verbose = verbose
        os.makedirs(os.path.dirname(path), exist_ok=True)
        self.stream = open(path, "a" if append else "w", encoding="utf-8", errors="replace")

    def close(self):
        self.stream.close()

    def restart(self):
        """Empties the log: a build from the start gets a log of its own."""
        self.stream.close()
        self.stream = open(self.path, "w", encoding="utf-8", errors="replace")

    def __enter__(self):
        return self

    def __exit__(self, *exception):
        self.close()

    def write(self, text):
        self.stream.write(text)
        self.stream.flush()
        if self.verbose:
            sys.stdout.write(text)
            sys.stdout.flush()

    def phase(self, port_name, phase):
        stamp = time.strftime("%Y-%m-%d %H:%M:%S")
        self.stream.write(f"\n===> {port_name}: {phase} ({stamp})\n")
        self.stream.flush()
        print(f"===> {port_name}: {phase}", flush=True)

    def note(self, text):
        self.write(text.rstrip("\n") + "\n")

    def run(self, command, cwd, environment, shell=False):
        """Runs a command with its output into the log; raises
        CommandFailed (naming the log) when it fails."""
        shown = command if isinstance(command, str) else " ".join(_quote(part) for part in command)
        self.write(f"$ cd {cwd} && {shown}\n")
        process = subprocess.Popen(
            command, cwd=cwd, env=environment, shell=shell, stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        tail = []
        for raw in process.stdout:
            line = raw.decode("utf-8", errors="replace")
            self.write(line)
            tail.append(line)
            if len(tail) > 25:
                tail.pop(0)
        status = process.wait()
        if status != 0:
            if not self.verbose:
                sys.stdout.write("".join(tail))
            raise CommandFailed(f"command failed with status {status}: {shown} (log: {self.path})")


def _quote(part):
    if part and all(character.isalnum() or character in "-_./=:+,@%" for character in part):
        return part
    return "'" + part.replace("'", "'\\''") + "'"
