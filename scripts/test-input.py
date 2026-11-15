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
Input test: boots the system with /bin/sh as the first program and types
into it, on a USB keyboard and the emulated PS/2 keyboard (QEMU monitor
"sendkey": keys go to the USB keyboard until it is unplugged, then to
the PS/2 one) and on the serial port, then checks
what the shell printed. It also takes a screen dump to check that the
framebuffer console draws UTF-8 text and colours correctly after
scrolling. Covers both input
drivers, the shell's line editing and history (also of a line longer
than the screen), Ctrl-C (also of a loop of shell builtins), and job
control (Ctrl-Z, jobs, fg, bg, a background program reading the console).

    test-input.py <esp-directory> <system-disk-image>

Exits with 0 when every check passed.
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
build_directory = os.path.dirname(esp_directory)
work = os.path.join(build_directory, 'input-test')
shutil.rmtree(work, ignore_errors=True)
os.makedirs(work)
shutil.copytree(esp_directory, os.path.join(work, 'esp'))
with open(os.path.join(work, 'esp', 'FreePascalOS', 'options.txt'), 'w') as options:
    options.write('test-exit kshell\n')
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

# Unix socket paths are short; keep it relative to the build directory.
monitor_path = os.path.relpath(os.path.join(work, 'monitor.sock'))
screen_path = os.path.abspath(os.path.join(work, 'screen.ppm'))
serial_log = os.path.join(work, 'serial.log')

# A FIFO pair carries the serial port: QEMU writes serial.out, reads serial.in.
for suffix in ('.in', '.out'):
    os.mkfifo(os.path.join(work, 'serial' + suffix))
qemu = subprocess.Popen([
    'qemu-system-x86_64', '-machine', 'q35',
    *(['-accel', 'kvm', '-cpu', 'host'] if os.environ.get('ACCEL') == 'kvm' else ['-cpu', 'max']),
    '-m', '512M', '-smp', os.environ.get('PROCESSORS', '4'),
    '-drive', 'if=pflash,format=raw,readonly=on,file=' + firmware_code,
    '-drive', 'if=pflash,format=raw,file=' + os.path.join(work, 'vars.fd'),
    '-drive', 'format=raw,file=fat:rw:' + os.path.join(work, 'esp'),
    '-drive', 'format=raw,file=' + os.path.join(work, 'system.img'),
    '-device', 'isa-debug-exit,iobase=0xf4,iosize=0x04',
    '-device', 'qemu-xhci,id=xhci', '-device', 'usb-kbd,bus=xhci.0,id=usbkbd',
    '-serial', 'pipe:' + os.path.join(work, 'serial'),
    '-display', 'none', '-no-reboot',
    '-monitor', 'unix:' + monitor_path + ',server,nowait'],
    stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
    stderr=open(os.path.join(work, 'qemu-errors.log'), 'wb'))

serial_out = os.open(os.path.join(work, 'serial.out'), os.O_RDONLY | os.O_NONBLOCK)
serial_in = open(os.path.join(work, 'serial.in'), 'wb', buffering=0)
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


def type_on_serial(data):
    for byte in data:
        serial_in.write(bytes([byte]))
        time.sleep(0.02)


checks = []

# The kernel debug shell runs first (kernel option kshell).
kernel_shell_ok = wait_for('kshell> ', 90)
if kernel_shell_ok:
    type_on_serial(b'volumes\r')
    kernel_shell_ok = wait_for('disk1p1  ext4  "FPOSROOT"', 10)
    type_on_serial(b'cat /disk1p1/etc/passwd\r')
    kernel_shell_ok = kernel_shell_ok and wait_for('root:x:0:0:', 10)
    type_on_serial(b'ls /disk1p1/bin\r')
    kernel_shell_ok = kernel_shell_ok and wait_for('coretest', 10)
    type_on_serial(b'frobnicate\r')
    kernel_shell_ok = kernel_shell_ok and wait_for('frobnicate: unknown command', 10)
    type_on_serial(b'exit\r')
checks.append(('kernel debug shell', kernel_shell_ok))

if not wait_for('fpos:/$ ', 90):
    print('INPUT TEST FAILED: the shell did not start (serial log in ' + serial_log + ')')
    with open(serial_log, 'wb') as log:
        log.write(received)
    qemu.kill()
    sys.exit(1)

monitor = None
for attempt in range(50):
    try:
        monitor = socket.socket(socket.AF_UNIX)
        monitor.connect(monitor_path)
        break
    except OSError:
        time.sleep(0.1)

KEY_NAMES = {' ': 'spc', '-': 'minus', '|': 'shift-backslash', '.': 'dot', '=': 'equal'}


def press(name):
    monitor.sendall(('sendkey ' + name + '\n').encode())
    time.sleep(0.06)


def type_on_keyboard(text):
    for character in text:
        if character in KEY_NAMES:
            press(KEY_NAMES[character])
        elif character.isupper():
            press('shift-' + character.lower())
        else:
            press(character)


# USB keyboard (QEMU's most recently started keyboard): letters, Shift,
# Enter; then it is unplugged and the keys go to the PS/2 keyboard.
type_on_keyboard('echo Usb-Keyboard')
press('ret')
checks.append(('usb keyboard', wait_for('\nUsb-Keyboard', 10)))
monitor.sendall(b'device_del usbkbd\n')
time.sleep(1)

# Keyboard: Shift, Enter.
type_on_keyboard('echo Keyboard-Works')
press('ret')
checks.append(('keyboard with shift', wait_for('\nKeyboard-Works', 10)))

# Keyboard: Ctrl-C throws the line away.
type_on_keyboard('echo discarded')
press('ctrl-c')
type_on_keyboard('echo kept')
press('ret')
collect(1)
checks.append(('keyboard ctrl-c', b'\nkept' in received and b'\ndiscarded' not in received))

# Keyboard: Caps Lock (inverts Shift); the left arrow moves the cursor.
press('caps_lock')
type_on_keyboard('ECHO')
press('caps_lock')
type_on_keyboard(' caps-ok')
press('left')
press('left')
press('left')
press('left')
press('left')
press('left')
press('left')
type_on_keyboard('x')
press('ret')
checks.append(('keyboard caps lock and cursor keys', wait_for('\nxcaps-ok', 10)))


# Serial: a long line arrives complete, by interrupt.
type_on_serial(b'echo ' + b's' * 200 + b' | wc -c\r')
checks.append(('serial long line', wait_for('\n201', 15)))

# Line editing: insert in the middle, history, Ctrl-A / Ctrl-K, Tab.
type_on_serial(b'echo hello wrld\x1b[D\x1b[D\x1b[Do\r')
checks.append(('editing: insert with cursor keys', wait_for('\nhello world', 10)))
type_on_serial(b'\x1b[A\x01\x0becho again\r')
checks.append(('editing: history and Ctrl-A, Ctrl-K', wait_for('\nagain', 10)))
type_on_serial(b'ls /et\t')
collect(0.5)
type_on_serial(b'\r')
checks.append(('editing: tab completion', wait_for('passwd', 10)))

# A line longer than the screen scrolls sideways: edit at both ends, and
# the terminal is never sent a row as long as the line.
long_start = len(received)
type_on_serial(b'echo ' + b'a' * 150 + b'END\x01' + b'\x1b[C' * 5 + b'S\x05Z\r')
long_result = b'\nS' + b'a' * 150 + b'ENDZ'
long_ok = wait_for(long_result.decode(), 15)
if long_ok:
    shown = bytes(received[long_start:received.index(long_result, long_start)])
    for separator in (b'\r', b'\b'):
        shown = shown.replace(separator, b'\n')
    long_ok = max(len(row) for row in shown.split(b'\n')) < 150
checks.append(('editing: a line longer than the screen', long_ok))

def interrupt_then_type(data):
    """Ctrl-C, then (once it has taken effect) more input: Ctrl-C throws
    away what was typed ahead of it, as a terminal does."""
    type_on_serial(b'\x03')
    time.sleep(0.5)
    type_on_serial(data)


# Ctrl-C: clears the line at the prompt, ends a sleeping program, a busy
# program and a whole loop.
type_on_serial(b'echo partial\x03echo cleared\r')
collect(1)
checks.append(('ctrl-c at the prompt', b'\ncleared' in received and b'\npartial' not in received))
type_on_serial(b'sleep 30\r')
time.sleep(1)
interrupt_then_type(b'echo status=$?\r')
checks.append(('ctrl-c ends a sleeping program', wait_for('status=130', 10)))
type_on_serial(b'yes > /dev/null\r')
time.sleep(1)
interrupt_then_type(b'echo busy=$?\r')
checks.append(('ctrl-c ends a busy program', wait_for('busy=130', 10)))
type_on_serial(b'while true; do :; done; echo skipped-after-builtins\r')
time.sleep(1.5)
interrupt_then_type(b'echo builtin-loop-ended\r')
checks.append(('ctrl-c ends a loop of builtins',
               wait_for('\nbuiltin-loop-ended', 10) and b'\nskipped-after-builtins' not in received))
type_on_serial(b'while true; do sleep 1; done; echo not-reached\r')
time.sleep(1.5)
interrupt_then_type(b'echo loop-ended\r')
checks.append(('ctrl-c ends a loop', wait_for('\nloop-ended', 10) and b'\nnot-reached' not in received))

# Job control: Ctrl-Z stops the foreground program, which bg continues
# in the background and kill %1 ends.
type_on_serial(b'sleep 30\r')
time.sleep(1)
type_on_serial(b'\x1a')
checks.append(('ctrl-z stops a program', wait_for('[1]+  Stopped                 sleep 30', 10)))
type_on_serial(b'ps -o stat= -o comm= | grep sleep\r')
checks.append(('a stopped program shows as T', wait_for('T    sleep', 10)))
type_on_serial(b'bg\r')
checks.append(('bg continues a job', wait_for('[1]+ sleep 30 &', 10)))
type_on_serial(b'kill %1\r')
time.sleep(1)
type_on_serial(b'\r')
checks.append(('kill %1 ends a job, reported at the prompt',
               wait_for('[1]+  Exit 143                sleep 30', 10)))

# fg: a stopped reader gets the console back.
type_on_serial(b'cat\r')
time.sleep(1)
type_on_serial(b'\x1a')
checks.append(('ctrl-z stops a reader', wait_for('[1]+  Stopped                 cat', 10)))
type_on_serial(b'jobs\r')
time.sleep(0.5)
type_on_serial(b'fg\r')
time.sleep(1)
type_on_serial(b'typed-to-cat\r')
time.sleep(0.5)
type_on_serial(b'\x04echo fg-status=$?\r')
checks.append(('fg brings a job back', wait_for('fg-status=0', 10) and
               received.count(b'typed-to-cat') >= 2))

# A background program that reads the console stops until fg.
type_on_serial(b'cat &\r')
time.sleep(1)
type_on_serial(b'jobs\r')
checks.append(('a background reader stops', wait_for('[1]+  Stopped                 cat', 10)))
type_on_serial(b'fg %1\r')
time.sleep(1)
type_on_serial(b'read-after-fg\r')
time.sleep(0.5)
type_on_serial(b'\x04echo reader-status=$?\r')
checks.append(('the background reader reads after fg', wait_for('reader-status=0', 10) and
               received.count(b'read-after-fg') >= 2))
# A whole pipeline stops and comes back; Ctrl-C then ends it.
type_on_serial(b'sleep 30 | cat\r')
time.sleep(1)
type_on_serial(b'\x1a')
checks.append(('ctrl-z stops a pipeline', wait_for('[1]+  Stopped                 sleep 30 | cat', 10)))
type_on_serial(b'fg\r')
time.sleep(1)
interrupt_then_type(b'echo pipeline-status=$?\r')
checks.append(('fg, then ctrl-c ends the pipeline', wait_for('pipeline-status=130', 10)))
type_on_serial(b'sleep 1 & wait $!; echo waited=$?\r')
checks.append(('wait for a background job', wait_for('waited=0', 10)))

# History is shared through the file: a new shell recalls the last line.
type_on_serial(b'sh\r')
time.sleep(1)
type_on_serial(b'\x1b[A\x1b[A\r')
collect(1.5)
checks.append(('history shared through the file', received.count(b'waited=0') >= 2))
type_on_serial(b'exit\r')
time.sleep(0.5)

# The framebuffer console: after scrolling (through its copy in memory),
# UTF-8 text and a coloured letter are drawn from the font.
def font_glyphs():
    source = open(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'kernel', 'debug',
                               'Debug.ConsoleFont.inc')).read()
    declaration = source.split('ConsoleFontCodePoints: array')[1].split(');')[0]
    code_points = [int(value, 16) for value in re.findall(r'\$([0-9A-F]{4})', declaration)]
    rows = re.findall(r'\(((?:\$[0-9A-F]{2}, ){15}\$[0-9A-F]{2})\)', source)
    return {code: [int(value[1:], 16) for value in row.split(', ')] for code, row in zip(code_points, rows)}


def cell_matches(pixels, width, row, column, glyph, foreground, background):
    for glyph_row in range(16):
        for glyph_column in range(8):
            x = 8 + column * 8 + glyph_column
            y = 8 + row * 16 + glyph_row
            offset = (y * width + x) * 3
            expected = foreground if glyph[glyph_row] & (0x80 >> glyph_column) else background
            if tuple(pixels[offset:offset + 3]) != expected:
                return False
    return True


type_on_serial(b"seq 1 80; printf 'A\\303\\251\\342\\202\\254\\033[31mR\\033[0m'; sleep 4\r")
time.sleep(2.5)
monitor.sendall(('screendump ' + screen_path + '\n').encode())
time.sleep(1)
screen_ok = False
try:
    data = open(screen_path, 'rb').read()
    header = re.match(rb'P6\s+(\d+)\s+(\d+)\s+255\s', data)
    width, height = int(header.group(1)), int(header.group(2))
    pixels = data[header.end():]
    glyphs = font_glyphs()
    last_row = (height - 16) // 16 - 1
    gray, blue, red = (0xC0, 0xC0, 0xC0), (0x10, 0x18, 0x30), (0xC0, 0x30, 0x30)
    screen_ok = (cell_matches(pixels, width, last_row, 0, glyphs[ord('A')], gray, blue) and
                 cell_matches(pixels, width, last_row, 1, glyphs[0xE9], gray, blue) and
                 cell_matches(pixels, width, last_row, 2, glyphs[0x20AC], gray, blue) and
                 cell_matches(pixels, width, last_row, 3, glyphs[ord('R')], red, blue))
except (OSError, AttributeError, KeyError):
    pass
checks.append(('framebuffer console: UTF-8 and colour after scrolling', screen_ok))
time.sleep(2)

serial_in.write(b'exit 0\r')
try:
    qemu.wait(timeout=30)
except subprocess.TimeoutExpired:
    qemu.kill()
collect(0.5)

# Both keyboards delivered keys (QEMU sent them where the test meant).
counts = re.search(rb'keys pressed: PS/2 (\d+), USB (\d+)', received)
checks.append(('keys came from the PS/2 and the USB keyboard',
               counts is not None and int(counts.group(1)) > 0 and int(counts.group(2)) > 0))

failed = False
for name, passed in checks:
    print(('[input] pass: ' if passed else '[input] FAIL: ') + name)
    failed = failed or not passed
with open(serial_log, 'wb') as log:
    log.write(received)
if failed:
    print('INPUT TEST FAILED (serial log in ' + serial_log + ')')
    sys.exit(1)
print('INPUT TEST PASSED')
