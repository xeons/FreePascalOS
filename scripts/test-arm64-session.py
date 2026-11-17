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
Session test of the AArch64 build: boots the system the way it normally
boots - the service manager in the graphical mode, with the kernel
option autologin=user - in QEMU's virt machine (Cortex-A72, GICv2, the
edk2 firmware at EL2 as on the Raspberry Pi 4) with a ramfb framebuffer
and a USB keyboard and tablet on xHCI. On the serial console it logs in
as root and runs a few commands (uname -m, the processor's name, the
services, a pipeline, a program that threads and keeps thread-local
storage, the runtime library's tests), and checks that the display
server and the user's desktop came up (the session log, the desktop's
processes, a screen that is not blank: the dump is kept as session.png)
and that the USB keyboard and tablet work: a double click on the
desktop's Terminal icon opens a terminal, and a command typed into it
on the keyboard runs.

    test-arm64-session.py <esp-directory> <system-disk-image>

Exits with 0 when every check passed. Not part of make test.
"""
import os
import re
import shutil
import socket
import subprocess
import sys
import time

esp_directory, system_disk = sys.argv[1], sys.argv[2]
build_directory = os.path.dirname(esp_directory)
script_directory = os.path.dirname(os.path.abspath(__file__))
work = os.path.join(build_directory, 'session-test-arm64')
shutil.rmtree(work, ignore_errors=True)
os.makedirs(work)
shutil.copytree(esp_directory, os.path.join(work, 'esp'))
with open(os.path.join(work, 'esp', 'FreePascalOS', 'options.txt'), 'w') as options:
    options.write('autologin=user heapchecks\n')
shutil.copy(system_disk, os.path.join(work, 'system.img'))

monitor_path = os.path.relpath(os.path.join(work, 'monitor.sock'))
control_path = os.path.relpath(os.path.join(work, 'control.sock'))
serial_log = os.path.join(work, 'serial.log')
for suffix in ('.in', '.out'):
    os.mkfifo(os.path.join(work, 'serial' + suffix))

environment = dict(os.environ, VIRTUALIZATION='1', PROCESSORS=os.environ.get('PROCESSORS', '4'),
                   SERIAL='pipe:' + os.path.join(work, 'serial'))
qemu = subprocess.Popen([
    os.path.join(script_directory, 'run-qemu-arm64.sh'), os.path.join(work, 'esp'), '--headless',
    os.path.join(work, 'system.img'), '--',
    '-monitor', 'unix:' + monitor_path + ',server,nowait',
    '-qmp', 'unix:' + control_path + ',server,nowait'],
    env=environment, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
    stderr=open(os.path.join(work, 'qemu-errors.log'), 'wb'))

serial_out = os.open(os.path.join(work, 'serial.out'), os.O_RDONLY | os.O_NONBLOCK)


def open_serial_input():
    deadline = time.time() + 60
    while time.time() < deadline and qemu.poll() is None:
        try:
            descriptor = os.open(os.path.join(work, 'serial.in'), os.O_WRONLY | os.O_NONBLOCK)
            os.set_blocking(descriptor, True)
            return os.fdopen(descriptor, 'wb', buffering=0)
        except OSError:
            time.sleep(0.1)
    print('ARM64 SESSION TEST FAILED: QEMU did not start (errors in ' +
          os.path.join(work, 'qemu-errors.log') + ')')
    qemu.kill()
    sys.exit(1)


serial_in = open_serial_input()
received = bytearray()


def collect(seconds):
    deadline = time.time() + seconds
    while time.time() < deadline:
        try:
            chunk = os.read(serial_out, 4096)
            if chunk:
                received.extend(chunk)
                continue
        except BlockingIOError:
            pass
        time.sleep(0.05)


def wait_for(text, seconds, start=0):
    deadline = time.time() + seconds
    while time.time() < deadline:
        collect(0.2)
        if text.encode() in received[start:]:
            return True
    return False


def type_on_serial(data):
    for byte in data:
        serial_in.write(bytes([byte]))
        time.sleep(0.01)


marker_count = 0


def run_and_read(command, seconds=30):
    """What a command prints in the root shell on the serial console."""
    global marker_count
    marker_count += 1
    marker = 'OUT' + str(marker_count)
    start = len(received)
    type_on_serial(command.encode() + b'; m=DONE; echo ' + marker.encode() + b' $m\r')
    wait_for(marker + ' DONE', seconds, start)
    output = bytes(received[start:])
    output = output[output.find(b'\n') + 1:]
    end = output.find((marker + ' DONE').encode())
    return output[:end if end >= 0 else len(output)].replace(b'\r', b'')


def finish(checks):
    with open(serial_log, 'wb') as log:
        log.write(received)
    try:
        qemu.kill()
        qemu.wait(timeout=10)
    except (OSError, subprocess.TimeoutExpired):
        pass
    failed = [name for name, passed in checks if not passed]
    for name, passed in checks:
        print(('  pass: ' if passed else '  FAIL: ') + name)
    print('ARM64 SESSION TEST: ' + ('passed' if not failed else 'failed') +
          ', %d of %d checks (serial log in %s)' % (len(checks) - len(failed), len(checks), serial_log))
    sys.exit(1 if failed else 0)


checks = []
started = wait_for('servicemanager: started session', 240) and wait_for('fpos login: ', 60)
checks.append(('the service manager started the display server, then the session',
               started and re.search(rb'started displayserver.*displayserver is ready.*started session',
                                     bytes(received), re.S) is not None))
if not started:
    finish(checks)

type_on_serial(b'root\r')
wait_for('Password: ', 20)
type_on_serial(b'root\r')
checks.append(('serial console: root logs in', wait_for('fpos:/$ ', 30)))

# (The kernel's messages may come between the lines a command prints,
# so the checks look for what they expect in the output.)
output = run_and_read('uname -m; arch')
checks.append(('uname -m and arch say aarch64', b'aarch64\naarch64\n' in output))
output = run_and_read('sysinfo -l | grep -e "^CPU:" -e "^OS:"')
checks.append(('sysinfo names the processor (MIDR) and the architecture',
               b'OS: FreePascalOS aarch64' in output and re.search(rb'CPU: \S+.*r\dp\d', output) is not None))
output = run_and_read('seq 1 1000 | sort -rn | head -n 3 | tr "\\n" " "; echo $((6 * 7))')
checks.append(('a pipeline and arithmetic in the shell', b'1000 999 998 42\n' in output))
output = run_and_read('threadtest > /tmp/threadtest.log 2>&1; echo status $?; grep -c "^ok " /tmp/threadtest.log', 180)
checks.append(('threads, thread-local storage of a library (TLS descriptors, initial exec), initializers '
               '(threadtest)', re.search(rb'status 0\n[1-9]', output) is not None))
output = run_and_read('rtltest > /tmp/rtltest.log 2>&1; echo status $?; tail -n 1 /tmp/rtltest.log', 300)
checks.append(('the runtime library: exceptions, a filter continuing at a changed context, stack overflows '
               '(rtltest)', re.search(rb'status 0\nrtltest: \d+ passed, 0 failed', output) is not None))

session = b''
deadline = time.time() + 120
while time.time() < deadline:
    session = run_and_read('cat /var/log/session.log')
    if b'desktop: ready' in session:
        break
    time.sleep(2)
checks.append(('the desktop started by itself for the automatic user',
               b'session: user logged in' in session and b'desktop: ready' in session))
output = run_and_read('ps -e -o user= -o comm= | grep -e desktop -e displayserver | sort')
checks.append(('the display server runs as root, the desktop as the user',
               re.search(rb'root\s+displayserver', output) is not None and
               re.search(rb'user\s+desktop', output) is not None))

monitor = socket.socket(socket.AF_UNIX)
monitor.connect(monitor_path)
screen_path = os.path.abspath(os.path.join(work, 'screen.ppm'))
monitor.sendall(('screendump ' + screen_path + '\n').encode())
deadline = time.time() + 10
while time.time() < deadline and not os.path.exists(screen_path):
    time.sleep(0.2)
time.sleep(1)
colours = set()
try:
    data = open(screen_path, 'rb').read()
    header = re.match(rb'P6\s+(\d+)\s+(\d+)\s+255\s', data)
    pixels = data[header.end():]
    for offset in range(0, len(pixels) - 3, 3 * 997):
        colours.add(pixels[offset:offset + 3])
    try:
        from PIL import Image
        Image.open(screen_path).save(os.path.join(work, 'session.png'))
    except ImportError:
        pass
except (OSError, AttributeError):
    pass
checks.append(('the screen shows the desktop (many colours, not a blank framebuffer)', len(colours) > 8))
output = run_and_read('test -c /dev/usbkeyboard0 && echo keyboard')
checks.append(('the USB keyboard and tablet were found',
               b'keyboard\n' in output and b'USB keyboard' in received and b'USB tablet' in received))

# The tablet: a double click on the Terminal icon (the desktop's first
# column, second row, on the 800x600 ramfb screen). The keyboard: a
# command typed into the terminal.
control = socket.socket(socket.AF_UNIX)
control.connect(control_path)
control.recv(65536)
control.sendall(b'{"execute": "qmp_capabilities"}\n')
control.recv(65536)


def place_tablet(x, y):
    command = ('{"execute": "input-send-event", "arguments": {"events": ['
               '{"type": "abs", "data": {"axis": "x", "value": %d}}, '
               '{"type": "abs", "data": {"axis": "y", "value": %d}}]}}\n') % (
                   x * 32767 // 799, y * 32767 // 599)
    control.sendall(command.encode())
    control.recv(65536)
    time.sleep(0.3)


def click():
    monitor.sendall(b'mouse_button 1\n')
    time.sleep(0.1)
    monitor.sendall(b'mouse_button 0\n')
    time.sleep(0.1)


place_tablet(59, 112)
click()
click()
deadline = time.time() + 60
output = b''
while time.time() < deadline:
    output = run_and_read('ps -e -o comm= | grep -c -x terminal')
    if b'1\n' in output:
        break
    time.sleep(2)
checks.append(('a double click on the Terminal icon (USB tablet) opens a terminal', b'1\n' in output))
time.sleep(5)
for key in list('echo typed>/tmp/typed') + ['ret']:
    name = {' ': 'spc', '>': 'shift-dot', '/': 'slash'}.get(key, key)
    monitor.sendall(('sendkey ' + name + '\n').encode())
    time.sleep(0.15)
deadline = time.time() + 30
while time.time() < deadline:
    output = run_and_read('cat /tmp/typed 2>/dev/null')
    if b'typed\n' in output:
        break
    time.sleep(2)
checks.append(('a command typed on the USB keyboard runs in the terminal', b'typed\n' in output))

finish(checks)
