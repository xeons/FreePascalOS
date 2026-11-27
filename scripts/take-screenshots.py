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
Takes screenshots of the desktop: boots the built system in QEMU (KVM,
1280x800, the graphical session logged in as user), follows a plan of
steps and saves each screen dump as a PNG.

    scripts/take-screenshots.py PLAN.json [OUTPUT_DIRECTORY]

Run after `make && make userland && make esp system-disk`. The default
output directory is docs/screenshots. A plan is a JSON list of steps:

    ["sh", COMMAND]        run COMMAND on the serial shell (as user); a
                           command ending in & runs in the background
    ["serial", TEXT]       type TEXT and Enter on the serial console,
                           without waiting (answering su's password
                           prompt, say)
    ["keys", TEXT]         type TEXT into the focused window
    ["key", NAME]          press one QEMU key (e.g. "ctrl-c", "ret")
    ["drag", X1, Y1, X2, Y2]  drag with the left button (screen pixels)
    ["move", X, Y]         move the pointer
    ["click", X, Y]        click the left button there
    ["rclick", X, Y]       click the right button there
    ["sleep", SECONDS]
    ["shot", NAME]         save the screen as NAME.png

The plans for the README's screenshots are in docs/screenshots/plans.
A sample picture (a drawn landscape, sample.png) is put on the EFI
partition, which the system mounts at /volumes/disk0p1, for plans that
open a picture; so are the pages of docs/screenshots/pages, under
/volumes/disk0p1/pages, for plans that open one in Tuxcat. The machine
has 4 GiB, enough for the browser on real sites.
"""

import json
import math
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import time

from PIL import Image, ImageDraw

SCREEN_WIDTH = 1280
SCREEN_HEIGHT = 800
FIRMWARE_CODE = '/usr/share/edk2/x64/OVMF_CODE.4m.fd'
FIRMWARE_VARIABLES = '/usr/share/edk2/x64/OVMF_VARS.4m.fd'

# QEMU key names for characters that are not their own name.
KEY_NAMES = {' ': 'spc', '-': 'minus', '.': 'dot', '/': 'slash', '\n': 'ret', '=': 'equal', ',': 'comma',
             '*': 'shift-8', '(': 'shift-9', ')': 'shift-0', '+': 'shift-equal', '_': 'shift-minus',
             '|': 'shift-backslash', '~': 'shift-grave_accent', '&': 'shift-7',
             "'": 'apostrophe', '"': 'shift-apostrophe', ';': 'semicolon', ':': 'shift-semicolon',
             '^': 'shift-6', '%': 'shift-5', '$': 'shift-4', '#': 'shift-3', '@': 'shift-2', '!': 'shift-1',
             '[': 'bracket_left', ']': 'bracket_right', '{': 'shift-bracket_left', '}': 'shift-bracket_right',
             '<': 'shift-comma', '>': 'shift-dot', '?': 'shift-slash', '\\': 'backslash', '`': 'grave_accent',
             '\t': 'tab'}


def draw_sample_picture(path):
    """A landscape at dusk: a sky gradient, a sun and layered hills."""
    width, height = 960, 600
    picture = Image.new('RGB', (width, height))
    pen = ImageDraw.Draw(picture)
    for y in range(height):
        share = y / height
        pen.line([(0, y), (width, y)],
                 fill=(int(255 - 90 * share), int(170 + 40 * share), int(90 + 140 * share)))
    pen.ellipse([620, 90, 760, 230], fill=(255, 236, 170))
    hills = ((330, 40, 0.008, 1.0, (120, 110, 170)), (390, 35, 0.011, 2.2, (80, 90, 150)),
             (460, 30, 0.014, 0.4, (50, 70, 110)), (530, 20, 0.02, 3.1, (30, 45, 70)))
    for base, height_of_wave, frequency, phase, colour in hills:
        outline = [(0, height)]
        for x in range(0, width + 1, 8):
            outline.append((x, base + height_of_wave * math.sin(x * frequency + phase) +
                            height_of_wave * 0.4 * math.sin(x * frequency * 2.7 + phase * 2)))
        outline.append((width, height))
        pen.polygon(outline, fill=colour)
    picture.save(path)


class Machine:
    """QEMU running the system, with its serial console, monitor and QMP.
    The sockets are named relative to the work folder: Unix socket paths
    are limited to about 108 bytes."""

    def __init__(self, root, work):
        self.work = work
        esp = os.path.join(work, 'esp')
        shutil.copytree(os.path.join(root, 'build/amd64/esp'), esp)
        with open(os.path.join(esp, 'FreePascalOS', 'options.txt'), 'w') as options:
            options.write('autologin=user\n')
        draw_sample_picture(os.path.join(esp, 'sample.png'))
        pages = os.path.join(root, 'docs/screenshots/pages')
        if os.path.isdir(pages):
            shutil.copytree(pages, os.path.join(esp, 'pages'))
        shutil.copy(os.path.join(root, 'build/amd64/system-disk.img'), os.path.join(work, 'system.img'))
        shutil.copy(FIRMWARE_VARIABLES, os.path.join(work, 'vars.fd'))
        for suffix in ('.in', '.out'):
            os.mkfifo(os.path.join(work, 'serial' + suffix))
        self.process = subprocess.Popen(
            ['qemu-system-x86_64', '-machine', 'q35', '-accel', 'kvm', '-cpu', 'host', '-m', '4G', '-smp', '4',
             '-drive', 'if=pflash,format=raw,readonly=on,file=' + FIRMWARE_CODE,
             '-drive', 'if=pflash,format=raw,file=vars.fd',
             '-drive', 'format=raw,file=fat:rw:esp',
             '-drive', 'format=raw,file=system.img',
             '-netdev', 'user,id=net0', '-device', 'virtio-net-pci,netdev=net0',
             '-device', 'qemu-xhci,id=xhci', '-device', 'usb-tablet,bus=xhci.0',
             '-serial', 'pipe:serial', '-display', 'none', '-no-reboot',
             '-monitor', 'unix:monitor.sock,server,nowait', '-qmp', 'unix:control.sock,server,nowait'],
            cwd=work, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
            stderr=open(os.path.join(work, 'qemu.log'), 'wb'))
        self.serial_out = os.open(os.path.join(work, 'serial.out'), os.O_RDONLY | os.O_NONBLOCK)
        time.sleep(1)
        self.serial_in = os.fdopen(os.open(os.path.join(work, 'serial.in'), os.O_WRONLY), 'wb', buffering=0)
        self.received = bytearray()
        self.monitor = None
        self.control = None

    def wait_for(self, text, seconds, start=0):
        deadline = time.time() + seconds
        while time.time() < deadline:
            try:
                chunk = os.read(self.serial_out, 4096)
                if chunk:
                    self.received.extend(chunk)
                    continue
            except BlockingIOError:
                pass
            if text.encode() in self.received[start:]:
                return True
            time.sleep(0.05)
        return False

    def type_on_serial(self, data):
        for byte in data:
            self.serial_in.write(bytes([byte]))
            time.sleep(0.01)

    def connect(self, name):
        connection = socket.socket(socket.AF_UNIX)
        previous = os.getcwd()
        os.chdir(self.work)
        try:
            connection.connect(name)
        finally:
            os.chdir(previous)
        return connection

    def monitor_command(self, command):
        if self.monitor is None:
            self.monitor = self.connect('monitor.sock')
            time.sleep(0.3)
        self.monitor.sendall((command + '\n').encode())
        time.sleep(0.05)

    def control_command(self, command, arguments=None):
        if self.control is None:
            self.control = self.connect('control.sock')
            self.control.recv(4096)
            self.control.sendall(b'{"execute": "qmp_capabilities"}')
            time.sleep(0.2)
            self.control.recv(4096)
        message = {'execute': command}
        if arguments is not None:
            message['arguments'] = arguments
        self.control.sendall(json.dumps(message).encode())
        time.sleep(0.05)
        self.control.recv(65536)

    def log_in(self):
        if not self.wait_for('fpos login: ', 120):
            raise RuntimeError('no login prompt on the serial console')
        self.type_on_serial(b'user\r')
        self.wait_for('Password: ', 10)
        self.type_on_serial(b'user\r')
        time.sleep(6)

    def run(self, command):
        start = len(self.received)
        joiner = b' ' if command.rstrip().endswith('&') else b'; '
        self.type_on_serial(command.encode() + joiner + b'm=DONE; echo STEP $m\r')
        self.wait_for('STEP DONE', 30, start)

    def type_keys(self, text):
        for character in text:
            if character in KEY_NAMES:
                name = KEY_NAMES[character]
            elif character.isupper():
                name = 'shift-' + character.lower()
            else:
                name = character
            self.monitor_command('sendkey ' + name)
            time.sleep(0.06)

    def pointer_to(self, x, y):
        events = [{'type': 'abs', 'data': {'axis': 'x', 'value': int(x * 32767 / (SCREEN_WIDTH - 1))}},
                  {'type': 'abs', 'data': {'axis': 'y', 'value': int(y * 32767 / (SCREEN_HEIGHT - 1))}}]
        self.control_command('input-send-event', {'events': events})

    def press_button(self, down, button='left'):
        self.control_command('input-send-event',
                             {'events': [{'type': 'btn', 'data': {'down': down, 'button': button}}]})

    def click(self, x, y, button='left'):
        self.pointer_to(x, y)
        time.sleep(0.2)
        self.press_button(True, button)
        time.sleep(0.2)
        self.press_button(False, button)
        time.sleep(0.4)

    def drag(self, x1, y1, x2, y2):
        self.pointer_to(x1, y1)
        time.sleep(0.2)
        self.press_button(True)
        time.sleep(0.2)
        steps = 12
        for step in range(1, steps + 1):
            self.pointer_to(x1 + (x2 - x1) * step / steps, y1 + (y2 - y1) * step / steps)
            time.sleep(0.04)
        time.sleep(0.2)
        self.press_button(False)
        time.sleep(0.4)

    def screenshot(self, path):
        dump = os.path.join(self.work, 'screen.ppm')
        self.monitor_command('screendump screen.ppm')
        time.sleep(2)
        Image.open(dump).save(path)

    def stop(self):
        self.process.kill()


def main():
    if len(sys.argv) not in (2, 3):
        print(__doc__)
        sys.exit(2)
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    plan = json.load(open(sys.argv[1]))
    output = os.path.abspath(sys.argv[2] if len(sys.argv) == 3 else os.path.join(root, 'docs/screenshots'))
    os.makedirs(output, exist_ok=True)
    work = tempfile.mkdtemp(prefix='fpos-shots-')
    machine = Machine(root, work)
    try:
        machine.log_in()
        for step in plan:
            kind = step[0]
            if kind == 'sh':
                machine.run(step[1])
            elif kind == 'serial':
                machine.type_on_serial(step[1].encode() + b'\r')
            elif kind == 'keys':
                machine.type_keys(step[1])
            elif kind == 'key':
                machine.monitor_command('sendkey ' + step[1])
            elif kind == 'drag':
                machine.drag(*step[1:5])
            elif kind == 'move':
                machine.pointer_to(step[1], step[2])
            elif kind == 'click':
                machine.click(step[1], step[2])
            elif kind == 'rclick':
                machine.click(step[1], step[2], 'right')
            elif kind == 'sleep':
                time.sleep(step[1])
            elif kind == 'shot':
                path = os.path.join(output, step[1] + '.png')
                machine.screenshot(path)
                print('saved', path)
            else:
                raise ValueError('unknown step ' + repr(step))
    finally:
        machine.stop()
        shutil.rmtree(work, ignore_errors=True)


if __name__ == '__main__':
    main()
