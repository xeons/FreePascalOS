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
Virtio GPU test: boots the system in text mode with root logged in on the
serial port, the standard VGA as the console's display and a virtio GPU
(QEMU's virtio-gpu-pci, 1024x768) as the second, and checks that the
driver binds (its scanout in the kernel's log, a display that needs
flushing and has a hardware cursor), that a program's picture shows once
flushed, the benchmark, and the display server on it: damage flushed,
the desktop and a window in a screen dump of the device, a mode set, and
the hardware cursor shown and moved when the pointer goes there (QEMU's
screen dump leaves the host's cursor out: the driver's log says where it
is, and the dump has no pointer drawn by the server there), hidden when
the pointer goes back to the first display, where the server draws it;
a mode set, and suspend to RAM with the cursor shown (picture and cursor
back after waking).

    test-virtio-gpu.py <esp-directory> <system-disk-image>

Exits with 0 when every check passed, or when this QEMU has no
virtio-gpu-pci device (its display module not installed): then the test
is skipped, saying so.
"""
import json
import os
import re
import shutil
import socket
import subprocess
import sys
import time

esp_directory, system_disk = sys.argv[1], sys.argv[2]

devices = subprocess.run(['qemu-system-x86_64', '-device', 'help'], stdout=subprocess.PIPE,
                         stderr=subprocess.STDOUT).stdout.decode(errors='replace')
if '"virtio-gpu-pci"' not in devices:
    print('VIRTIO GPU TEST SKIPPED: this QEMU has no virtio-gpu-pci device (its virtio-gpu display modules are '
          'not installed)')
    sys.exit(0)

build_directory = os.path.dirname(esp_directory)
work = os.path.join(build_directory, 'virtio-gpu-test')
shutil.rmtree(work, ignore_errors=True)
os.makedirs(work)
shutil.copytree(esp_directory, os.path.join(work, 'esp'))
with open(os.path.join(work, 'esp', 'FreePascalOS', 'options.txt'), 'w') as options:
    options.write('test-exit mode=text autologin=root\n')
shutil.copy(system_disk, os.path.join(work, 'system.img'))

firmware_code = '/usr/share/edk2/x64/OVMF_CODE.4m.fd'
firmware_variables = '/usr/share/edk2/x64/OVMF_VARS.4m.fd'
for candidate in ('/usr/share/OVMF/x64/OVMF_CODE.4m.fd', '/usr/share/OVMF/OVMF_CODE.fd'):
    if not os.path.exists(firmware_code):
        firmware_code = candidate
for candidate in ('/usr/share/OVMF/x64/OVMF_VARS.4m.fd', '/usr/share/OVMF/OVMF_VARS.fd'):
    if not os.path.exists(firmware_variables):
        firmware_variables = candidate
shutil.copy(firmware_variables, os.path.join(work, 'vars.fd'))

monitor_path = os.path.relpath(os.path.join(work, 'monitor.sock'))
control_path = os.path.relpath(os.path.join(work, 'control.sock'))
screen_path = os.path.abspath(os.path.join(work, 'screen.ppm'))
serial_log = os.path.join(work, 'serial.log')
for suffix in ('.in', '.out'):
    os.mkfifo(os.path.join(work, 'serial' + suffix))

qemu = subprocess.Popen([
    'qemu-system-x86_64', '-machine', 'q35',
    *(['-accel', 'kvm', '-cpu', 'host'] if os.environ.get('ACCEL') == 'kvm' else ['-cpu', 'max']),
    '-m', '512M', '-smp', os.environ.get('PROCESSORS', '2'),
    '-drive', 'if=pflash,format=raw,readonly=on,file=' + firmware_code,
    '-drive', 'if=pflash,format=raw,file=' + os.path.join(work, 'vars.fd'),
    '-drive', 'format=raw,file=fat:rw:' + os.path.join(work, 'esp'),
    '-drive', 'format=raw,file=' + os.path.join(work, 'system.img'),
    '-device', 'isa-debug-exit,iobase=0xf4,iosize=0x04',
    '-device', 'qemu-xhci,id=xhci', '-device', 'usb-kbd,bus=xhci.0', '-device', 'usb-tablet,bus=xhci.0',
    # The console stays on the standard VGA (the firmware's picture); the
    # virtio GPU is the second display.
    '-device', 'virtio-gpu-pci,id=video1,xres=1024,yres=768',
    '-serial', 'pipe:' + os.path.join(work, 'serial'),
    '-display', 'none', '-no-reboot',
    '-monitor', 'unix:' + monitor_path + ',server,nowait',
    '-qmp', 'unix:' + control_path + ',server,nowait'],
    stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
    stderr=open(os.path.join(work, 'qemu-errors.log'), 'wb'))

serial_out = os.open(os.path.join(work, 'serial.out'), os.O_RDONLY | os.O_NONBLOCK)


def open_serial_input():
    deadline = time.time() + 60
    while time.time() < deadline:
        if qemu.poll() is not None:
            break
        try:
            descriptor = os.open(os.path.join(work, 'serial.in'), os.O_WRONLY | os.O_NONBLOCK)
            os.set_blocking(descriptor, True)
            return os.fdopen(descriptor, 'wb', buffering=0)
        except OSError:
            time.sleep(0.1)
    print('VIRTIO GPU TEST FAILED: QEMU did not start (errors in ' + os.path.join(work, 'qemu-errors.log') + ')')
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


def wait_for(text, seconds):
    deadline = time.time() + seconds
    while time.time() < deadline:
        collect(0.2)
        if text.encode() in received:
            return True
    return False


def wait_for_pattern(pattern, seconds):
    deadline = time.time() + seconds
    while time.time() < deadline:
        collect(0.2)
        found = re.search(pattern.encode(), bytes(received))
        if found:
            return found
    return None


def wait_for_count(text, count, seconds):
    deadline = time.time() + seconds
    while time.time() < deadline:
        collect(0.2)
        if received.count(text.encode()) >= count:
            return True
    return False


def type_on_serial(data):
    try:
        for byte in data:
            serial_in.write(bytes([byte]))
            time.sleep(0.02)
    except BrokenPipeError:
        pass


def finish(checks):
    try:
        qemu.kill()
        qemu.wait(timeout=10)
    except (OSError, subprocess.TimeoutExpired):
        pass
    collect(0.2)
    with open(serial_log, 'wb') as log:
        log.write(received)
    failed = False
    for name, passed in checks:
        print(('[virtio-gpu] pass: ' if passed else '[virtio-gpu] FAIL: ') + name)
        failed = failed or not passed
    if failed:
        print('VIRTIO GPU TEST FAILED (serial log in ' + serial_log + ')')
        sys.exit(1)
    print('VIRTIO GPU TEST PASSED')
    sys.exit(0)


checks = []
if not wait_for('fpos:/$ ', 120):
    checks.append(('the shell started', False))
    finish(checks)

monitor = socket.socket(socket.AF_UNIX)
for attempt in range(50):
    try:
        monitor.connect(monitor_path)
        break
    except OSError:
        time.sleep(0.1)


def send_to_monitor(command):
    try:
        monitor.sendall(command.encode())
    except OSError:
        pass


def ask_monitor(command):
    answer = b''
    try:
        monitor.settimeout(0.2)
        while True:
            if not monitor.recv(65536):
                break
    except OSError:
        pass
    try:
        monitor.sendall(command.encode())
        time.sleep(0.5)
        monitor.settimeout(1)
        while True:
            chunk = monitor.recv(65536)
            if not chunk:
                break
            answer += chunk
    except OSError:
        pass
    return answer.decode(errors='replace')


mice = {}
for match in re.finditer(r'Mouse #(\d+): ([^\r\n(]*)', ask_monitor('info mice\n')):
    mice[match.group(2).strip()] = match.group(1)

control = None
try:
    control = socket.socket(socket.AF_UNIX)
    control.connect(control_path)
    control.settimeout(1)
    control.recv(65536)
    control.sendall(b'{"execute": "qmp_capabilities"}\n')
    control.recv(65536)
except OSError:
    pass


def take_screen(device=''):
    try:
        os.remove(screen_path)
    except OSError:
        pass
    send_to_monitor('screendump ' + screen_path + ((' ' + device) if device else '') + '\n')
    time.sleep(1)
    try:
        data = open(screen_path, 'rb').read()
        header = re.match(rb'P6\s+(\d+)\s+(\d+)\s+255\s', data)
        width, height = int(header.group(1)), int(header.group(2))
        start = header.end()
    except (OSError, AttributeError):
        missing = lambda x, y: ''
        missing.size = (0, 0)
        return missing

    def pixel(x, y):
        if not (0 <= x < width and 0 <= y < height):
            return ''
        offset = start + (y * width + x) * 3
        return data[offset:offset + 3].hex()
    pixel.size = (width, height)
    return pixel


# The display server's desktop: the standard VGA (1280x800) and the
# virtio GPU (1024x768) to its right; the tablet spans both.
desktop = {'width': 2304, 'height': 800}


def place_tablet(x, y):
    send_to_monitor('mouse_set ' + mice.get('QEMU HID Tablet', '0') + '\n')
    time.sleep(0.2)
    try:
        control.sendall(json.dumps({'execute': 'input-send-event', 'arguments': {'events': [
            {'type': 'abs', 'data': {'axis': 'x', 'value': x}},
            {'type': 'abs', 'data': {'axis': 'y', 'value': y}}]}}).encode() + b'\n')
        control.recv(65536)
    except (OSError, AttributeError):
        pass
    time.sleep(0.2)


def point_tablet_at(x, y):
    width, height = desktop['width'], desktop['height']
    place_tablet((x * 32767 + (width - 1) // 2) // (width - 1), (y * 32767 + (height - 1) // 2) // (height - 1))


# The driver bound: the scanout at the size QEMU gives it, with the
# host's cursor, registered as the second display.
checks.append(('the driver found the scanout, with its EDID and hardware cursor',
               re.search(rb'scanout 0: 1024x768, up to \d+x\d+, EDID, hardware cursor', bytes(received)) is not None))
checks.append(('the scanout is the second display', b'display1 1024x768' in received))

# The display as a program sees it.
type_on_serial(b'display -d 1; m=DONE; echo SECOND $m\r')
second_described = wait_for('SECOND DONE', 15)
checks.append(('display -d 1: a framebuffer flushed by rectangles, a hardware cursor',
               second_described and b'1024x768 pixels, 4096 bytes a line' in received and
               b'framebuffer flushed to the device by rectangles' in received and
               re.search(rb'^hardware cursor\r?$', bytes(received), re.MULTILINE) is not None))

# A program's picture shows once flushed (display flushes what it fills).
type_on_serial(b'display -d 1 -f 336699 -s 3; m=DONE; echo FILLED $m\r')
time.sleep(2)
filled = take_screen('video1')
checks.append(('a program fills the display: the picture is flushed to the host',
               filled.size == (1024, 768) and filled(512, 384) == '336699' and wait_for('FILLED DONE', 15)))

# The benchmark (its numbers are printed for whoever reads the log).
type_on_serial(b'displaybench -d 1 -s 1; m=DONE; echo BENCH $m\r')
bench_done = wait_for('BENCH DONE', 60)
bench_lines = re.findall(rb'(?:full screen|partial \(256x256\)|cursor): [^\r\n]*', bytes(received))
for line in bench_lines:
    print('[virtio-gpu] ' + line.decode(errors='replace'))
checks.append(('displaybench: full-screen, partial and cursor rates',
               bench_done and len(bench_lines) == 3 and b'displaybench: display 1, 1024x768, framebuffer flushed'
               in received))

# The display server: the classic theme's plain desktop colour, a window
# on the virtio display.
type_on_serial(b'settings set -s Appearance/Theme classic; m=DONE; echo CLASSIC $m\r')
wait_for('CLASSIC DONE', 10)
type_on_serial(b'displayserver &\r')
presented = wait_for('displayserver: display 1 presents damaged rectangles copied and flushed to the device, '
                     'hardware pointer', 30)
placed = wait_for_pattern(r'displayserver: display 1: 1024x768 at 1280,0, (\d+) DPI, scale (\d+)%', 5)
checks.append(('the display server flushes the virtio display and uses its cursor', presented and placed is not None))
scale = int(placed.group(2)) if placed else 100
time.sleep(1)
type_on_serial(b'wintest -t Virtio -x 1400 -y 100 -c 80C0F0 > /tmp/virtio.log &\r')
time.sleep(3)
second = take_screen('video1')
# The client area is 300x200 logical units from 1400,100 (display 1
# starts at logical 1280): its middle in the display's pixels.
window_x = (1400 + 150 - 1280) * scale // 100
window_y = (100 + 100) * scale // 100
checks.append(('a screen dump of the virtio display: the desktop and a window',
               second.size == (1024, 768) and second(1000, 740) == '2f5f7a' and
               second(window_x, window_y) == '80c0f0'))

# The pointer onto the virtio display: the host's cursor is shown there
# and moved (the driver logs where it comes to rest); the screen dump has
# no pointer drawn by the server where it is.
point_tablet_at(1280 + 500, 400)
shown = wait_for('scanout 0 cursor shown at 500,400', 10)
point_tablet_at(1280 + 600, 300)
moved = wait_for('scanout 0 cursor moved at 600,300', 10)
under_pointer = take_screen('video1')
checks.append(('the hardware cursor shown and moved with the pointer', shown and moved))
checks.append(('no pointer drawn by the server on the virtio display',
               all(under_pointer(600 + dx, 300 + dy) == '2f5f7a' for dx in range(0, 8) for dy in range(0, 12))))

# Back on the first display: the host's cursor is hidden and the server
# draws the arrow (its left edge below the tip is black).
point_tablet_at(480, 330)
hidden = wait_for('scanout 0 cursor hidden at 600,300', 10)
first = take_screen()
checks.append(('the pointer back on the first display: the hardware cursor hidden, the server draws it',
               hidden and first(480, 331) == '000000'))

# A mode set on the virtio display: a new resource of that size.
type_on_serial(b'displaymode -d 1 800x600\r')
mode_set = wait_for('display 1: 800x600, at 1280,0', 15)
time.sleep(1.5)
resized = take_screen('video1')
checks.append(('display modes: the virtio display set to 800x600', mode_set and resized.size == (800, 600) and
               resized(780, 580) == '2f5f7a'))
type_on_serial(b'displaymode -d 1 1024x768\r')
mode_back = wait_for('display 1: 1024x768, at 1280,0', 15)
time.sleep(1.5)
checks.append(('display modes: the virtio display back at 1024x768',
               mode_back and take_screen('video1').size == (1024, 768)))

# Suspend to RAM with the pointer on the virtio display: waking resets
# the device, and the driver makes its resources again on the memory
# that kept the picture (the window is in the screen dump without the
# server drawing anything) and shows the cursor again where it was.
point_tablet_at(1280 + 500, 400)
shown_before = wait_for_count('scanout 0 cursor shown at 500,400', 2, 10)
type_on_serial(b'suspend; echo RESUMED $?\r')
asleep = wait_for('suspending to RAM', 20)
time.sleep(2)
status = ask_monitor('info status\n')
send_to_monitor('system_wakeup\n')
woke = wait_for('RESUMED 0', 90)
cursor_back = wait_for_count('scanout 0 cursor shown at 500,400', 3, 10)
time.sleep(1)
after_waking = take_screen('video1')
checks.append(('suspend to RAM: the virtio display\'s picture and cursor back after waking',
               shown_before and asleep and 'suspended' in status and woke and cursor_back and
               after_waking.size == (1024, 768) and after_waking(window_x, window_y) == '80c0f0'))
point_tablet_at(1280 + 300, 500)
checks.append(('suspend to RAM: the hardware cursor moves after waking',
               wait_for('scanout 0 cursor moved at 300,500', 10)))

type_on_serial(b'kill %2; kill %1; wait; m=DONE; echo ENDED $m\r')
checks.append(('the display server ended', wait_for('ENDED DONE', 15)))
finish(checks)
