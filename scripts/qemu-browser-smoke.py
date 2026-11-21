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

"""The browser in the real system, driven like a user (not part of make
test: it needs the network): boots the system under QEMU (KVM when
ACCEL=kvm) with root's shell on the serial port, starts the display
server, and for each page opens /app/browser/browser on it, waits for
it to load, scrolls down with the wheel and back up, moves the pointer
over a grid of points (hovering), drags a selection, clicks a few
points (links, most likely) and goes back with Alt+Left, then checks
that the browser is still running, no content process (/bin/webcontent,
where the pages run) crashed or hung, and the kernel did not panic. A
screen dump of each page is kept.

    qemu-browser-smoke.py ESP-DIRECTORY SYSTEM-DISK OUT-DIRECTORY [NAME ...]

The pages are scripts/compare-sites.list's (the names given, or a
handful). Exits with 1 when the browser died or the system panicked on
any page.
"""

import json
import os
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import time

REPOSITORY = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_PAGES = ['hackernews', 'wikipedia-article', 'cnn-lite', 'python', 'mdn-reference', 'old-reddit']
SCREEN_WIDTH, SCREEN_HEIGHT = 1280, 800
LOAD_SECONDS = 25


def read_sites():
    sites = {}
    with open(os.path.join(REPOSITORY, 'scripts', 'compare-sites.list')) as source:
        for line in source:
            parts = line.split()
            if len(parts) >= 2 and not parts[0].startswith('#'):
                sites[parts[0]] = parts[1]
    return sites


def firmware():
    code = '/usr/share/edk2/x64/OVMF_CODE.4m.fd'
    variables = '/usr/share/edk2/x64/OVMF_VARS.4m.fd'
    for candidate in ('/usr/share/OVMF/x64/OVMF_CODE.4m.fd', '/usr/share/OVMF/OVMF_CODE.fd'):
        if not os.path.exists(code):
            code = candidate
    for candidate in ('/usr/share/OVMF/x64/OVMF_VARS.4m.fd', '/usr/share/OVMF/OVMF_VARS.fd'):
        if not os.path.exists(variables):
            variables = candidate
    return code, variables


class Machine:
    """QEMU with the serial port on pipes, the monitor and QMP on sockets."""

    def __init__(self, esp, disk, work):
        self.work = work
        shutil.rmtree(work, ignore_errors=True)
        os.makedirs(work)
        shutil.copytree(esp, os.path.join(work, 'esp'))
        with open(os.path.join(work, 'esp', 'FreePascalOS', 'options.txt'), 'w') as options:
            options.write('mode=text autologin=root\n')
        shutil.copy(disk, os.path.join(work, 'system.img'))
        code, variables = firmware()
        shutil.copy(variables, os.path.join(work, 'vars.fd'))
        for suffix in ('.in', '.out'):
            os.mkfifo(os.path.join(work, 'serial' + suffix))
        # Socket paths must be short (108 bytes): a folder of their own.
        self.socket_directory = tempfile.mkdtemp(prefix='fpos-smoke-')
        self.monitor_path = os.path.join(self.socket_directory, 'monitor.sock')
        self.control_path = os.path.join(self.socket_directory, 'control.sock')
        kvm = os.environ.get('ACCEL') == 'kvm'
        self.qemu = subprocess.Popen([
            'qemu-system-x86_64', '-machine', 'q35',
            *(['-accel', 'kvm', '-cpu', 'host'] if kvm else ['-cpu', 'max']),
            '-m', '2G', '-smp', os.environ.get('PROCESSORS', '4'),
            '-drive', 'if=pflash,format=raw,readonly=on,file=' + code,
            '-drive', 'if=pflash,format=raw,file=' + os.path.join(work, 'vars.fd'),
            '-drive', 'format=raw,file=fat:rw:' + os.path.join(work, 'esp'),
            '-drive', 'format=raw,file=' + os.path.join(work, 'system.img'),
            '-device', 'qemu-xhci,id=xhci', '-device', 'usb-kbd,bus=xhci.0', '-device', 'usb-tablet,bus=xhci.0',
            '-netdev', 'user,id=net0', '-device', 'virtio-net-pci,netdev=net0',
            '-serial', 'pipe:' + os.path.join(work, 'serial'),
            '-display', 'none', '-no-reboot',
            '-monitor', 'unix:' + self.monitor_path + ',server,nowait',
            '-qmp', 'unix:' + self.control_path + ',server,nowait'],
            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
            stderr=open(os.path.join(work, 'qemu-errors.log'), 'wb'))
        self.serial_out = os.open(os.path.join(work, 'serial.out'), os.O_RDONLY | os.O_NONBLOCK)
        self.serial_in = self.open_serial_input()
        self.received = bytearray()
        self.monitor = None
        self.control = None

    def open_serial_input(self):
        deadline = time.time() + 60
        while time.time() < deadline and self.qemu.poll() is None:
            try:
                descriptor = os.open(os.path.join(self.work, 'serial.in'), os.O_WRONLY | os.O_NONBLOCK)
                os.set_blocking(descriptor, True)
                return os.fdopen(descriptor, 'wb', buffering=0)
            except OSError:
                time.sleep(0.1)
        sys.exit('qemu-browser-smoke: QEMU did not start (see ' + os.path.join(self.work, 'qemu-errors.log') + ')')

    def collect(self, seconds):
        deadline = time.time() + seconds
        while time.time() < deadline:
            try:
                chunk = os.read(self.serial_out, 65536)
                if chunk:
                    self.received.extend(chunk)
                    continue
            except BlockingIOError:
                pass
            time.sleep(0.05)

    def wait_for(self, text, seconds, start=0):
        deadline = time.time() + seconds
        while time.time() < deadline:
            self.collect(0.2)
            if text.encode() in self.received[start:]:
                return True
            if self.qemu.poll() is not None:
                return False
        return False

    def type(self, text):
        for byte in text.encode():
            self.serial_in.write(bytes([byte]))
            time.sleep(0.01)

    def connect(self):
        for _ in range(50):
            try:
                self.monitor = socket.socket(socket.AF_UNIX)
                self.monitor.connect(self.monitor_path)
                break
            except OSError:
                time.sleep(0.1)
        self.control = socket.socket(socket.AF_UNIX)
        self.control.connect(self.control_path)
        self.control.settimeout(2)
        self.control.recv(65536)
        self.qmp('qmp_capabilities')

    def qmp(self, command, arguments=None):
        message = {'execute': command}
        if arguments is not None:
            message['arguments'] = arguments
        try:
            self.control.sendall(json.dumps(message).encode() + b'\n')
            self.control.recv(65536)
        except OSError:
            pass

    def send_events(self, events):
        self.qmp('input-send-event', {'events': events})
        time.sleep(0.05)

    def point(self, x, y):
        self.send_events([{'type': 'abs', 'data': {'axis': 'x', 'value': x * 32767 // SCREEN_WIDTH}},
                          {'type': 'abs', 'data': {'axis': 'y', 'value': y * 32767 // SCREEN_HEIGHT}}])

    def button(self, name, down):
        self.send_events([{'type': 'btn', 'data': {'down': down, 'button': name}}])

    def click(self, x, y):
        self.point(x, y)
        self.button('left', True)
        self.button('left', False)

    def wheel(self, down, times):
        for _ in range(times):
            name = 'wheel-down' if down else 'wheel-up'
            self.button(name, True)
            self.button(name, False)
            time.sleep(0.1)

    def drag(self, from_x, from_y, to_x, to_y):
        self.point(from_x, from_y)
        self.button('left', True)
        for step in range(1, 9):
            self.point(from_x + (to_x - from_x) * step // 8, from_y + (to_y - from_y) * step // 8)
            time.sleep(0.05)
        self.button('left', False)

    def key(self, name):
        try:
            self.monitor.sendall(('sendkey ' + name + '\n').encode())
        except OSError:
            pass
        time.sleep(0.1)

    def screendump(self, path):
        try:
            os.remove(path)
        except OSError:
            pass
        try:
            self.monitor.sendall(('screendump ' + path + '\n').encode())
        except OSError:
            pass
        time.sleep(1)

    def stop(self):
        try:
            self.qemu.kill()
            self.qemu.wait(timeout=10)
        except (OSError, subprocess.TimeoutExpired):
            pass
        shutil.rmtree(self.socket_directory, ignore_errors=True)


def save_png(ppm, png):
    try:
        from PIL import Image
        Image.open(ppm).save(png)
        os.remove(ppm)
    except (ImportError, OSError):
        pass


def drive_page(machine, name, url, out):
    """One page: opened, scrolled, hovered, a selection dragged, clicks
    and Back; True when the browser lived through it."""
    start = len(machine.received)
    machine.type('/app/browser/browser ' + url + ' > /tmp/b.log 2>&1 & m=STARTED; echo BROWSER-$m\r')
    machine.wait_for('BROWSER-STARTED', 10, start)
    time.sleep(LOAD_SECONDS)
    machine.screendump(os.path.join(out, name + '-loaded.ppm'))
    machine.click(SCREEN_WIDTH // 2, SCREEN_HEIGHT // 2 + 100)
    machine.wheel(True, 25)
    machine.wheel(False, 25)
    for row in range(1, 4):
        for column in range(1, 6):
            machine.point(SCREEN_WIDTH * column // 6, SCREEN_HEIGHT * row // 4)
            time.sleep(0.3)
    machine.drag(200, 300, 900, 500)
    time.sleep(1)
    for x, y in ((300, 260), (640, 400), (500, 520)):
        machine.click(x, y)
        time.sleep(6)
        machine.wheel(True, 5)
        machine.key('alt-left')
        time.sleep(5)
    machine.screendump(os.path.join(out, name + '-after.ppm'))
    probe = len(machine.received)
    machine.type('if kill -0 $! 2>/dev/null; then m=ALIVE; else m=GONE; fi; echo BROWSER-$m; '
                 'kill $!; wait $!; cat /tmp/b.log; m=END; echo LOG-$m\r')
    alive = machine.wait_for('BROWSER-ALIVE', 15, probe)
    machine.wait_for('LOG-END', 20, probe)
    log = bytes(machine.received[probe:]).decode('utf-8', 'replace')
    with open(os.path.join(out, name + '.log'), 'w') as saved:
        saved.write(log)
    for suffix in ('-loaded', '-after'):
        save_png(os.path.join(out, name + suffix + '.ppm'), os.path.join(out, name + suffix + '.png'))
    panicked = re.search(r'panic|PANIC|Unhandled exception|page fault', log) is not None
    # Pages run in content processes: the browser says when one crashed
    # or stopped answering ("process crashed STATUS tab I").
    content_failed = re.search(r'process (crashed|hung) ', log) is not None
    return alive and not panicked and not content_failed, log


def main():
    if len(sys.argv) < 4:
        sys.exit(__doc__)
    esp, disk, out = sys.argv[1], sys.argv[2], os.path.abspath(sys.argv[3])
    if out.startswith(REPOSITORY + os.sep):
        sys.exit('qemu-browser-smoke: put the output outside the repository')
    os.makedirs(out, exist_ok=True)
    sites = read_sites()
    names = sys.argv[4:] or DEFAULT_PAGES
    machine = Machine(esp, disk, os.path.join(out, 'machine'))
    results = []
    try:
        if not machine.wait_for('fpos:/$ ', 120):
            sys.exit('qemu-browser-smoke: the shell did not start')
        machine.connect()
        # Pages need the network (and its name server) first.
        if not machine.wait_for('eth0: configured', 90):
            print('qemu-browser-smoke: the network was not configured; going on')
        time.sleep(3)
        machine.type('displayserver & m=READY; echo SERVER-$m\r')
        machine.wait_for('displayserver: ready', 30)
        for name in names:
            ok, log = drive_page(machine, name, sites.get(name, name), out)
            results.append((name, ok))
            print('%-20s %s' % (name, 'ok' if ok else 'FAILED (see %s.log)' % os.path.join(out, name)), flush=True)
            if machine.qemu.poll() is not None:
                print('qemu-browser-smoke: QEMU ended')
                break
    finally:
        with open(os.path.join(out, 'serial.log'), 'wb') as log:
            log.write(machine.received)
        machine.stop()
    failed = [name for name, ok in results if not ok]
    if failed or len(results) < len(names):
        print('qemu-browser-smoke: failed: ' + ', '.join(failed or ['(stopped early)']))
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
