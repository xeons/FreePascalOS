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
control_path = os.path.relpath(os.path.join(work, 'control.sock'))
screen_path = os.path.abspath(os.path.join(work, 'screen.ppm'))
serial_log = os.path.join(work, 'serial.log')

# A FIFO pair carries the serial port: QEMU writes serial.out, reads serial.in.
for suffix in ('.in', '.out'):
    os.mkfifo(os.path.join(work, 'serial' + suffix))
# Disks and sound devices for suspend to RAM: every driver must bring its
# hardware back after waking (virtio, NVMe and USB disks; HD Audio, AC'97
# and USB audio, each recorded into a WAV file).
for name in ('virtio', 'nvme', 'usb'):
    source = os.path.join(build_directory, 'test-disk-' + name + '.img')
    if not os.path.exists(source):
        # QEMU would not start without it (and nothing would read the
        # serial pipe): say so now rather than wait.
        print('INPUT TEST FAILED: ' + source + ' is missing (make test-disk, or make test, builds it)')
        sys.exit(1)
    shutil.copyfile(source, os.path.join(work, name + '.img'))
recordings = {name: os.path.join(work, 'audio-' + name + '.wav') for name in ('hda', 'ac97', 'usb')}

# One processor slot is left free, to plug a processor in later (ACPI
# hotplug: a general purpose event, its AML method and a Notify).
processors = os.environ.get('PROCESSORS', '4')
# QEMU lays the processors out as cores of one socket.
cpu_model = 'host-x86_64-cpu' if os.environ.get('ACCEL') == 'kvm' else 'max-x86_64-cpu'
qemu = subprocess.Popen([
    'qemu-system-x86_64', '-machine', 'q35',
    *(['-accel', 'kvm', '-cpu', 'host'] if os.environ.get('ACCEL') == 'kvm' else ['-cpu', 'max']),
    '-m', '512M', '-smp', processors + ',maxcpus=' + str(int(processors) + 1),
    '-drive', 'if=pflash,format=raw,readonly=on,file=' + firmware_code,
    '-drive', 'if=pflash,format=raw,file=' + os.path.join(work, 'vars.fd'),
    '-drive', 'format=raw,file=fat:rw:' + os.path.join(work, 'esp'),
    '-drive', 'format=raw,file=' + os.path.join(work, 'system.img'),
    '-device', 'isa-debug-exit,iobase=0xf4,iosize=0x04',
    '-device', 'qemu-xhci,id=xhci,p2=8,p3=8', '-device', 'usb-kbd,bus=xhci.0,id=usbkbd',
    '-device', 'usb-tablet,bus=xhci.0',
    '-drive', 'if=none,id=virtio0,format=raw,file=' + os.path.join(work, 'virtio.img'),
    '-device', 'virtio-blk-pci,drive=virtio0',
    '-drive', 'if=none,id=nvme0,format=raw,file=' + os.path.join(work, 'nvme.img'),
    '-device', 'nvme,serial=fpostest,drive=nvme0',
    '-drive', 'if=none,id=usbdisk0,format=raw,file=' + os.path.join(work, 'usb.img'),
    '-device', 'usb-storage,bus=xhci.0,drive=usbdisk0',
    '-audiodev', 'wav,id=sound0,path=' + recordings['hda'],
    '-device', 'intel-hda', '-device', 'hda-output,audiodev=sound0',
    '-audiodev', 'wav,id=sound1,path=' + recordings['ac97'], '-device', 'AC97,audiodev=sound1',
    '-audiodev', 'wav,id=sound2,path=' + recordings['usb'], '-device', 'usb-audio,bus=xhci.0,audiodev=sound2',
    # A second display (its own device, with no firmware picture): the
    # first stays the console's at 1280x800; this one starts at 1024x768.
    '-device', 'bochs-display,id=video1,xres=1024,yres=768',
    '-serial', 'pipe:' + os.path.join(work, 'serial'),
    '-display', 'none', '-no-reboot',
    '-monitor', 'unix:' + monitor_path + ',server,nowait',
    '-qmp', 'unix:' + control_path + ',server,nowait'],
    stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
    stderr=open(os.path.join(work, 'qemu-errors.log'), 'wb'))

serial_out = os.open(os.path.join(work, 'serial.out'), os.O_RDONLY | os.O_NONBLOCK)


def open_serial_input():
    # Opening a FIFO to write waits until someone reads it: QEMU, once it
    # runs. If QEMU ended instead (it could not start), that wait would
    # never end, so the open does not wait and is tried while QEMU lives.
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
    print('INPUT TEST FAILED: QEMU did not start (errors in ' + os.path.join(work, 'qemu-errors.log') + ')')
    with open(os.path.join(work, 'qemu-errors.log'), 'rb') as errors:
        sys.stdout.write(errors.read().decode(errors='replace'))
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

def send_to_monitor(command):
    # QEMU may be gone already (the guest crashed or powered off): the
    # checks after this then fail, and the log is still written.
    try:
        monitor.sendall(command.encode())
    except OSError:
        pass


def ask_monitor(command):
    # What earlier commands answered is read away first.
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
        answer = monitor.recv(65536)
    except OSError:
        pass
    return answer.decode(errors='replace')


# Mouse commands go to one device at a time, chosen by its number.
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


def move_ps2_mouse(command):
    send_to_monitor('mouse_set ' + mice.get('QEMU PS/2 Mouse', '0') + '\n')
    time.sleep(0.2)
    send_to_monitor(command)
    time.sleep(0.2)


def place_tablet(x, y):
    # Absolute positions need QMP (HMP's mouse_move is relative). QEMU's
    # range is 0-32767; the kernel's 0-65535.
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


# Input events: the PS/2 mouse (motion, a click, the wheel), the USB
# tablet (an absolute position) and a key, read from /dev/events. The
# key does not reach the console meanwhile (the next line would start
# with it otherwise).
type_on_serial(b'events -n 7; m=DONE; echo EVENTS $m\r')
time.sleep(1.5)
move_ps2_mouse('mouse_move 4 2\n')
move_ps2_mouse('mouse_button 1\n')
move_ps2_mouse('mouse_button 0\n')
move_ps2_mouse('mouse_move 0 0 1\n')
place_tablet(16384, 8192)
press('a')
events_ok = wait_for('EVENTS DONE', 20)
checks.append(('input events: PS/2 mouse motion, button and wheel',
               events_ok and b'motion 4 2' in received and b'button 1 press' in received and
               b'button 1 release' in received and b'wheel 1' in received))
checks.append(('input events: USB tablet position (0-65535)', events_ok and b'position 32768 16384' in received))
checks.append(('input events: a key with its character', events_ok and b'key 0x1E press a' in received))
type_on_serial(b'm=CLEAN; echo CONSOLE $m\r')
checks.append(('input events: the key did not reach the console', wait_for('CONSOLE CLEAN', 10)))

def take_screen(device=''):
    # A fresh screen dump (of the first display, or of the QEMU device
    # named): a function giving the colour at (x, y) as 'rrggbb' ('' if
    # there is no dump or the point is off it); its size is pixel.size.
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


def screen_pixel(x, y):
    return take_screen()(x, y)


# The display device: QEMU's EDID says 325x203 mm, which at 1280 pixels
# across is 100 DPI. A program filling it shows on the screen, with its
# frame a quarter inch (25 pixels) in; once it ends the console's screen
# (dark blue) is back.
type_on_serial(b'display\r')
checks.append(('display device: size, physical size and DPI',
               wait_for('325x203 mm', 10) and wait_for('100 DPI, scale 100%', 10)))
type_on_serial(b'display -f 336699 -s 3; m=DONE; echo FILLED $m\r')
time.sleep(1.5)
filled = screen_pixel(640, 400) == '336699' and screen_pixel(26, 400) == 'ffffff'
checks.append(('display device: a program draws on the screen', filled))
given_back = wait_for('FILLED DONE', 15)
time.sleep(0.5)
# (In the margin, where no text is.)
checks.append(('display device: the console has the screen again', given_back and screen_pixel(2, 400) == '101830'))

# Display modes: the list (from QEMU's EDID and the common sizes), a
# program setting 1024x768 for as long as it has the display (the screen
# dump is that size, the frame a quarter inch in at 80 DPI: 20 pixels),
# then the boot mode and the console back. The second display is its own
# device, set to the mode its EDID prefers.
type_on_serial(b'display -l; m=DONE; echo MODES $m\r')
modes_ok = wait_for('MODES DONE', 10)
checks.append(('display modes: listed',
               modes_ok and re.search(rb'\n1024x768\r?\n', received) is not None and b'1280x800 *' in received))
type_on_serial(b'display -m 1024x768 -f 663399 -s 3; m=DONE; echo MODE $m\r')
time.sleep(1.5)
pixel = take_screen()
checks.append(('display modes: a program sets 1024x768',
               pixel.size == (1024, 768) and pixel(512, 400) == '663399' and pixel(21, 400) == 'ffffff'))
mode_given_back = wait_for('MODE DONE', 15)
time.sleep(0.5)
pixel = take_screen()
checks.append(('display modes: the boot mode and the console back after it',
               mode_given_back and pixel.size == (1280, 800) and pixel(2, 400) == '101830'))
type_on_serial(b'display -d 1; m=DONE; echo SECOND $m\r')
second_ok = wait_for('SECOND DONE', 10)
checks.append(('display modes: a second display, driven natively',
               second_ok and b'1024x768 pixels, 4096 bytes a line' in received and
               take_screen('video1').size == (1024, 768)))

# Drawing with libdrawing and libfont: drawtest draws a window (at 100
# DPI everything is its logical size: the window at 80,60, 400 wide). The
# desktop, the window's face, the title bar's gradient and its white text
# are on the screen; 9 point text (13 pixels at 100 DPI, rounded) picks
# the 13 pixel faces of DejaVu Sans, regular and bold.
type_on_serial(b'drawtest -s 3; m=DONE; echo DRAWN $m\r')
time.sleep(1.5)
pixel = take_screen()
title_text = any(pixel(x, y) == 'ffffff' for x in range(87, 190) for y in range(64, 80))
checks.append(('drawing: desktop, window, title bar and its text',
               pixel(5, 5) == '3a6ea5' and pixel(300, 250) == 'c8c4bc' and pixel(83, 63) == '1c3f6e' and title_text))
checks.append(('drawing: fonts picked by point size and DPI',
               wait_for('100 DPI: title 13 px bold, text 13 px', 15) and wait_for('DRAWN DONE', 10)))

# The display server's desktop: the first display (1280x800) and the
# second (1024x768) to its right. The tablet spans all of it.
desktop = {'width': 2304, 'height': 800}


def point_tablet_at(x, y):
    # The tablet at desktop pixel (x, y): QEMU's range is 0-32767 across
    # the whole desktop.
    width, height = desktop['width'], desktop['height']
    place_tablet((x * 32767 + (width - 1) // 2) // (width - 1), (y * 32767 + (height - 1) // 2) // (height - 1))


def click_at(x, y):
    point_tablet_at(x, y)
    send_to_monitor('mouse_button 1\n')
    time.sleep(0.3)
    send_to_monitor('mouse_button 0\n')
    time.sleep(0.5)


def hold_key(name, down):
    # A key held down (or let go) through QMP: sendkey presses and
    # releases at once, which cannot make a Ctrl+click.
    try:
        control.sendall(json.dumps({'execute': 'input-send-event', 'arguments': {'events': [
            {'type': 'key', 'data': {'down': down, 'key': {'type': 'qcode', 'data': name}}}]}}).encode() + b'\n')
        control.recv(65536)
    except (OSError, AttributeError):
        pass
    time.sleep(0.2)


def click_holding(key, x, y):
    hold_key(key, True)
    click_at(x, y)
    hold_key(key, False)


def right_click_at(x, y):
    point_tablet_at(x, y)
    send_to_monitor('mouse_button 2\n')
    time.sleep(0.3)
    send_to_monitor('mouse_button 0\n')
    time.sleep(0.8)


def drag(from_x, from_y, to_x, to_y):
    point_tablet_at(from_x, from_y)
    send_to_monitor('mouse_button 1\n')
    time.sleep(0.3)
    point_tablet_at((from_x + to_x) // 2, (from_y + to_y) // 2)
    point_tablet_at(to_x, to_y)
    send_to_monitor('mouse_button 0\n')
    time.sleep(0.8)


# The display server with two windows (wintest): the second over the
# first and active (its title bar's gradient starts dark), the first's
# inactive (grey). Dragging the second's title bar moves it (the first
# shows where it was); dragging its corner resizes it (the program is
# told the new size); its close button asks it to close (it ends); the
# first is active again and gets a key. Ending the server gives the
# screen back to the console. At 100 DPI logical units are pixels: the
# client areas start at 100,100 and 250,200, 300x200; frames are 4
# wide, title bars 18 high (their gradient starts 3 pixels into the frame).
# The second window has the text beam over its left half (a pointer
# area). The server reads the pointer's shapes from /lib/pointers, and
# checks every window move (copying what stays visible) against a full
# redraw (--check-moves).
type_on_serial(b'displayserver --check-moves &\r')
server_ready = wait_for('displayserver: ready (1280x800, 100 DPI, scale 100%)', 20)
checks.append(('display server: the pointer\'s shapes read from files',
               wait_for('displayserver: 7 of 7 pointer shapes from /lib/pointers', 10)))
type_on_serial(b'wintest -t First -x 100 -y 100 > /tmp/w1.log &\r')
time.sleep(1.5)
type_on_serial(b'wintest -t Second -x 250 -y 200 -c D0E8F0 -b > /tmp/w2.log &\r')
time.sleep(2)
pixel = take_screen()
checks.append(('display server: two windows, stacked, the top one active',
               server_ready and pixel(400, 300) == 'd0e8f0' and pixel(150, 150) == 'f0e8d0' and
               pixel(249, 185) == '17375e' and pixel(99, 85) == '7c7a76'))
# The text beam's hotspot is in the middle of its stem: its top bar, 7
# pixels up, is black either side of a white middle. The arrow's tip is
# black, the pixel below and right of it white.
point_tablet_at(320, 330)
beam = take_screen()
point_tablet_at(480, 330)
arrow = take_screen()
checks.append(('pointer shapes: the text beam over a window\'s pointer area, the arrow beside it',
               beam(319, 323) == '000000' and beam(320, 323) == 'ffffff' and beam(321, 323) == '000000' and
               arrow(480, 330) == '000000' and arrow(481, 332) == 'ffffff' and arrow(319, 323) == 'd0e8f0'))
drag(300, 190, 400, 240)
pixel = take_screen()
checks.append(('display server: a window dragged by its title bar',
               pixel(600, 400) == 'd0e8f0' and pixel(260, 210) == 'f0e8d0' and pixel(300, 330) == '2f5f7a'))
drag(652, 452, 702, 502)
time.sleep(0.5)
pixel = take_screen()
type_on_serial(b'm=DONE; cat /tmp/w2.log; echo W2 $m\r')
checks.append(('display server: a window resized by its corner',
               wait_for('resized 350 250', 10) and pixel(690, 490) == 'd0e8f0'))
# Maximized: the client area fills the screen below the title bar.
click_at(673, 240)
type_on_serial(b'm=DONE; cat /tmp/w2.log; echo MAXIMIZED $m\r')
checks.append(('display server: maximized', wait_for('resized 1280 782', 10) and wait_for('MAXIMIZED DONE', 5)))
# Its close button is now at the top right corner.
click_at(1271, 8)
time.sleep(0.5)
send_to_monitor('sendkey a\n')
time.sleep(0.8)
type_on_serial(b'm=DONE; cat /tmp/w1.log /tmp/w2.log; echo LOGS $m\r')
logs_ok = wait_for('LOGS DONE', 10)
checks.append(('display server: the close button, then a key for the window left',
               logs_ok and received.count(b'\nclose') >= 1 and b'key 0x1E a' in received and
               take_screen()(500, 350) == '2f5f7a'))

# The title buttons of the window left (First, active; its close button
# at 383-398 x 83-96): hot under the pointer (a lighter face), pressed
# while held (sunken: dark at its top left), back to normal when the
# pointer goes off it with the button held; let go there, nothing
# happens. The pointer is at the button's bottom right, clear of the
# pixels looked at.
closes_before = received.count(b'\nclose')
point_tablet_at(397, 95)
hot = take_screen()
send_to_monitor('mouse_button 1\n')
time.sleep(0.4)
pressed = take_screen()
point_tablet_at(250, 250)
let_up = take_screen()
send_to_monitor('mouse_button 0\n')
time.sleep(0.5)
checks.append(('title buttons: hot, pressed, and up again off the button',
               hot(386, 86) == 'e2ded6' and hot(384, 84) == 'ffffff' and
               pressed(386, 86) == 'cbc6bd' and pressed(383, 83) == '7e7a72' and pressed(384, 84) == '35322d' and
               let_up(386, 86) == 'cbc6bd' and let_up(384, 84) == 'ffffff'))
# Over the right border the pointer is the left-right resize arrow: its
# hotspot in the middle of a white shaft (the arrow's tip is black).
point_tablet_at(402, 150)
resize_arrow = take_screen()
checks.append(('pointer shapes: the resize arrow over a border',
               resize_arrow(402, 150) == 'ffffff' and resize_arrow(396, 150) == 'ffffff' and
               resize_arrow(408, 150) == 'ffffff' and resize_arrow(402, 148) == '000000'))


def double_click_at(x, y):
    point_tablet_at(x, y)
    for state in ('1', '0', '1', '0'):
        send_to_monitor('mouse_button ' + state + '\n')
        time.sleep(0.05)
    time.sleep(1)


# A double click on the title bar maximizes the window, another (on the
# maximized title bar, now at the top) restores it (wintest also prints
# where the window went back to).
type_on_serial(b'm=DONE; echo TITLE $m\r')
wait_for('TITLE DONE', 10)
double_click_at(250, 90)
double_click_at(250, 9)
type_on_serial(b'm=DONE; cat /tmp/w1.log; echo DOUBLE $m\r')
wait_for('DOUBLE DONE', 10)
log_from_here = bytes(received[received.rfind(b'TITLE DONE'):])
checks.append(('title bar: a double click maximizes, another restores',
               re.search(rb'resized 1280 782\r?\nmoved 100 100\r?\nresized 300 200', log_from_here) is not None and
               received.count(b'\nclose') == closes_before))
# Dragged partly off the screen and back: each move copies what stays
# visible, and the picture is the same as drawing everything again.
drag(250, 90, 100, 40)
drag(100, 40, 250, 90)
type_on_serial(b'm=DONE; echo DRAGGED $m\r')
wait_for('DRAGGED DONE', 10)
move_reports = re.findall(rb'(\d+) moves compared with a full redraw, (\d+) differed', bytes(received))
checks.append(('window moves: copying what moved gives the picture a full redraw gives',
               len(move_reports) >= 3 and int(move_reports[-1][0]) >= 3 and
               all(differed == b'0' for compared, differed in move_reports) and
               b'unlike a full redraw' not in received))
# Left-handed: the right button acts as the left one (and back).
type_on_serial(b'mousesettings --left-handed on\r')
left_handed_on = wait_for('speed 10, acceleration 0, left-handed on', 10)
right_click_at(250, 200)
type_on_serial(b'mousesettings -l off\r')
left_handed_off = wait_for('speed 10, acceleration 0, left-handed off', 10)
right_click_at(250, 200)
type_on_serial(b'm=DONE; cat /tmp/w1.log; echo HANDED $m\r')
wait_for('HANDED DONE', 10)
log_from_here = bytes(received[received.rfind(b'DRAGGED DONE'):])
checks.append(('mouse settings: left-handed swaps the buttons',
               left_handed_on and left_handed_off and
               re.search(rb'button 1 press 150 100\r?\nbutton 2 press 150 100', log_from_here) is not None))
# The speed doubles a mouse's movement (40 units: 80 pixels); a tablet's
# positions stay where they are.
type_on_serial(b'mousesettings --speed 20\r')
speed_set = wait_for('speed 20, acceleration 0', 10)
point_tablet_at(600, 500)
move_ps2_mouse('mouse_move 40 0\n')
time.sleep(0.5)
pixel = take_screen()
type_on_serial(b'mousesettings -s 10; m=DONE; echo SPEED $m\r')
checks.append(('mouse settings: the speed multiplies relative motion',
               speed_set and pixel(680, 500) == '000000' and pixel(681, 502) == 'ffffff' and
               pixel(600, 500) == '2f5f7a' and wait_for('SPEED DONE', 10)))
type_on_serial(b'kill %1; wait; m=DONE; echo SERVER $m\r')
checks.append(('display server: ended, the console has the screen again',
               wait_for('SERVER DONE', 15) and screen_pixel(2, 400) == '101830'))
type_on_serial(b'kill %2 2>/dev/null; wait\r')
time.sleep(1)


def wait_for_count(text, count, seconds):
    # The text seen at least count times (it may have come before).
    deadline = time.time() + seconds
    while time.time() < deadline:
        collect(0.2)
        if received.count(text.encode()) >= count:
            return True
    return False


# Two displays: the second (1024x768) to the right of the first, at 150%
# (displayscale -d 1). A window dragged by its title bar across the edge
# shows on the second display (its own screen dump) and is told its new
# scale (wintest prints it, and draws its 300x200 logical units as
# 450x300 pixels: from 220,210 there). Then the first display set to
# 1024x768 (displaymode) with a window near its right edge: the screen
# dump is that size, the window is moved onto it (its frame ends at the
# edge: the client area at 720) and told the new DPI (80), the second
# display's window stays; then back to 1280x800. Every move is checked
# against a full redraw: a window crossing from one display's back
# buffer to the other's is drawn again where copying cannot serve.
servers_before = received.count(b'displayserver: display 1: 1024x768 at 1280,0')
reports_before = len(re.findall(rb'moves compared with a full redraw', bytes(received)))
type_on_serial(b'displayserver --check-moves &\r')
two_displays = wait_for_count('displayserver: display 1: 1024x768 at 1280,0', servers_before + 1, 20)
time.sleep(1)
type_on_serial(b'displayscale -d 1 150\r')
second_scaled = wait_for('scale 150%, 150 DPI', 10)
type_on_serial(b'wintest -t Travel -x 100 -y 100 -c 80C0F0 > /tmp/w3.log &\r')
time.sleep(2)
drag(300, 90, 1700, 200)
time.sleep(1)
second = take_screen('video1')
first = take_screen()
type_on_serial(b'm=DONE; cat /tmp/w3.log; echo TRAVEL $m\r')
travelled = wait_for('TRAVEL DONE', 10)
checks.append(('several displays: a window dragged onto the second display',
               two_displays and second.size == (1024, 768) and second(400, 400) == '80c0f0' and
               first(250, 200) == '2f5f7a'))
move_reports = re.findall(rb'(\d+) moves compared with a full redraw, (\d+) differed', bytes(received))
checks.append(('window moves: across two displays, the picture a full redraw gives',
               len(move_reports) > reports_before and int(move_reports[-1][0]) >= 1 and
               all(differed == b'0' for compared, differed in move_reports) and
               b'unlike a full redraw' not in received))
checks.append(('several displays: the window told the second display\'s scale',
               second_scaled and travelled and b'scale 150 150' in received and second(660, 500) == '80c0f0'))
type_on_serial(b'wintest -t Edge -x 900 -y 300 -c F0C080 > /tmp/w4.log &\r')
time.sleep(2)
type_on_serial(b'displaymode 1024x768\r')
mode_set = wait_for('display 0: 1024x768, at 0,0 size 1024x768, scale 100%, 80 DPI', 10)
time.sleep(1.5)
first = take_screen()
second = take_screen('video1')
type_on_serial(b'm=DONE; cat /tmp/w4.log; echo EDGE $m\r')
edge_logged = wait_for('EDGE DONE', 10)
checks.append(('display modes: the server sets 1024x768, windows kept on the screen',
               mode_set and first.size == (1024, 768) and first(900, 400) == 'f0c080' and
               first(1018, 400) == 'f0c080' and edge_logged and b'moved 720 300' in received and
               b'scale 100 80' in received and second(400, 400) == '80c0f0'))
type_on_serial(b'displaymode 1280x800\r')
mode_back = wait_for('display 0: 1280x800, at 0,0 size 1280x800, scale 100%, 100 DPI', 10)
time.sleep(1.5)
first = take_screen()
checks.append(('display modes: the server sets 1280x800 again',
               mode_back and first.size == (1280, 800) and first(900, 400) == 'f0c080' and first(1100, 400) == '2f5f7a'))
type_on_serial(b'kill %2 %3; kill %1; wait; m=DONE; echo DISPLAYS $m\r')
checks.append(('several displays: the server ended, the console has the screen again',
               wait_for('DISPLAYS DONE', 15) and screen_pixel(2, 400) == '101830'))

# Owned windows (ownertest: A at 100,100 400x300 green, B owned by A,
# C at 300,250 300x200 blue overlapping A; a key takes each step):
# hiding A hides B too and B's program is told (B is not Visible any
# more); showing A shows B again; C and A come in front of each other
# when activated, until C is given A as its owner: then C stays in front
# of A; owned by nothing again, A covers it.
type_on_serial(b'displayserver &\r')
wait_for('displayserver: ready', 20)
point_tablet_at(900, 700)
type_on_serial(b'ownertest > /tmp/o.log &\r')
time.sleep(2.5)
overlaps = []
for step in range(7):
    press('a')
    time.sleep(0.8)
    overlaps.append(take_screen()(400, 320))
press('a')
time.sleep(0.5)
type_on_serial(b'm=DONE; cat /tmp/o.log; kill %1; wait; echo OWNERS $m\r')
owners_ok = wait_for('OWNERS DONE', 15)
log_from_here = bytes(received[received.rfind(b'ownertest >'):])
checks.append(('owned windows: hidden with its owner, the program is told (Visible follows)',
               owners_ok and b'visible B 0' in log_from_here and b'visible A 0 B 0 C 1' in log_from_here and
               b'visible B 1' in log_from_here and b'visible A 1 B 1 C 1' in log_from_here))
checks.append(('owned windows: the owner changed later, the window stays above its new owner',
               owners_ok and b'step 7' in log_from_here and
               overlaps == ['4040c0', '40c040', '4040c0', '40c040', '4040c0', '4040c0', '40c040']))

# Controls (libcontrols, controlsdemo, client area at 120,80): keys to
# the edit box, Tab to the check box and Space, a click on a radio
# button, three on the scroll bar's arrow, one on the swatch (a control
# the program made itself, which posts a message of its own); mnemonics:
# Alt+R toggles the check box back, Alt+N (the label's) goes back to the
# edit box for an x; the display's scale changed to 150% and back (the
# window is told, and gets a client area of the same logical size: 1.5
# times the pixels, the swatch where its logical place is now); Enter
# presses the default button.
type_on_serial(b'displayserver &\r')
wait_for('displayserver: ready', 20)
type_on_serial(b'controlsdemo > /tmp/c.log &\r')
time.sleep(2.5)
for key in ('h', 'i', 'tab', 'spc'):
    press(key)
time.sleep(0.5)
click_at(147, 204)
for step in range(3):
    click_at(384, 242)
click_at(438, 120)
swatch = take_screen()(430, 110)
press('alt-r')
press('alt-n')
press('x')
time.sleep(0.5)
# Over the edit box (196-396 x 92-114) the pointer is the text beam: its
# top bar, 7 pixels above the hotspot, black either side of the middle.
point_tablet_at(350, 103)
time.sleep(0.5)
pixel = take_screen()
checks.append(('pointer shapes: the text beam over an edit box',
               pixel(349, 96) == '000000' and pixel(351, 96) == '000000'))
type_on_serial(b'displayscale 150\r')
time.sleep(2)
# The client area at 150%: from 180,120, the swatch at 615,138 (84 square).
swatch_at_150 = take_screen()(645, 165)
type_on_serial(b'displayscale 100\r')
time.sleep(2)
swatch_at_100 = take_screen()(430, 110)
press('ret')
time.sleep(1)
type_on_serial(b'cat /tmp/c.log; kill %1; wait; m=DONE; echo CONTROLS $m\r')
controls_ok = wait_for('CONTROLS DONE', 15)
checks.append(('controls: edit box, check box, radio button, scroll bar, default button',
               controls_ok and b'edit hi' in received and b'check 1' in received and
               b'radio Large' in received and b'scroll 3' in received and b'clicked OK' in received))
checks.append(('controls: mnemonics (Alt+R on the check box, Alt+N on the label)',
               controls_ok and b'check 0' in received and b'edit hix' in received))
checks.append(('controls: a control of the program\'s own, and its posted message',
               b'swatch 1' in received and swatch == '30a040'))
checks.append(('display server: the scale changed to 150% and back, the window laid out again',
               b'scale 150%, 150 DPI' in received and b'scale 150 540 450' in received and
               b'scale 100 360 300' in received and swatch_at_150 == '30a040' and swatch_at_100 == '30a040'))

# A program started while the scale is 150% lays its controls out for
# its whole client area (180,120, 540x450 pixels): the status bar runs
# along its bottom, in the face colour, not black.
type_on_serial(b'displayserver &\r')
wait_for('displayserver: ready', 20)
type_on_serial(b'displayscale 150; controlsdemo > /tmp/c150.log &\r')
time.sleep(3)
pixel = take_screen()
checks.append(('controls: a program started at 150% fills its window', pixel(700, 556) == 'cbc6bd'))
type_on_serial(b'kill %2 %1 2>/dev/null; wait; m=DONE; echo STARTED-AT-150 $m\r')
wait_for('STARTED-AT-150 DONE', 15)

# The rest of the controls (controlstour), which prints where its
# controls are: a toolbar toggle, a list box, a combo box's dropped
# list, a menu bar's menu and a message box (Help > About, Enter), an
# accelerator's message box (Ctrl+M, Escape), the menus from the
# keyboard (Alt+H then Enter; Alt+H then A; F10, Right, Down, Enter;
# Alt alone, Right, Down, Enter: About each time), the tab control, the
# clipboard (Ctrl+A and Ctrl+C in one edit box, Ctrl+V in another, Paste
# from the context menu, lines pasted into the multi-line edit box), the
# tree view (a click, Right, Down) and the list view (a row, a header,
# sorting by a header as numbers, a click, a Ctrl+click and a
# Shift+click, then large icons). The message boxes are owned by the
# window: a click on its title bar while one is open changes nothing in
# its client area (the box stays above it) and leaves its title bar
# inactive (it is disabled), and Enter still goes to the box.
def client_area_of_tour(pixel):
    # Every fourth pixel of the window's client area (60,40, 480x360).
    return [pixel(x, y) for x in range(60, 540, 4) for y in range(40, 400, 4)]


owned_box_above = False
def places():
    return {match.group(1).decode(): (int(match.group(2)), int(match.group(3)))
            for match in re.finditer(rb'place (\S+) (\d+) (\d+)', bytes(received))}


type_on_serial(b'displayserver &\r')
wait_for('displayserver: ready', 20)
type_on_serial(b'controlstour > /tmp/t.log &\r')
time.sleep(3)
type_on_serial(b'm=DONE; cat /tmp/t.log; echo PLACES $m\r')
wait_for('PLACES DONE', 10)
place = places()
tour_started = all(name in place for name in ('help', 'bold', 'text-tab', 'tree-tab', 'details-tab', 'list-item-3',
                                               'combo', 'combo-second'))
icon_pixels = []
if tour_started:
    click_at(*place['bold'])
    click_at(*place['list-item-3'])
    click_at(*place['combo'])
    click_at(*place['combo-second'])
    click_at(*place['help'])
    click_at(place['help'][0] - 8, place['help'][1] + 21)
    time.sleep(1)
    # The pointer where it will click (the window's title bar, y 21-39),
    # so it is drawn in the same place on both screens.
    point_tablet_at(80, 30)
    before = client_area_of_tour(take_screen())
    click_at(80, 30)
    pixel = take_screen()
    owned_box_above = before == client_area_of_tour(pixel) and pixel(59, 30) == '7c7a76'
    press('ret')
    time.sleep(0.8)
    press('ctrl-m')
    time.sleep(1)
    press('esc')
    time.sleep(0.8)
    click_at(*place['text-tab'])
    type_on_serial(b'm=DONE; cat /tmp/t.log; echo TEXT $m\r')
    wait_for('TEXT DONE', 10)
    place = places()
    if all(name in place for name in ('copy-box', 'paste-box', 'text-edit')):
        click_at(*place['copy-box'])
        press('ctrl-a')
        press('ctrl-c')
        click_at(*place['paste-box'])
        press('ctrl-v')
        time.sleep(0.5)
        # The context menu opens where the button was let go; Paste is its
        # third item (18 pixels each, 2 in).
        right_click_at(*place['paste-box'])
        click_at(place['paste-box'][0] + 30, place['paste-box'][1] + 2 + 2 * 18 + 9)
        # Three lines copied from the multi-line edit box and pasted at
        # the end of its last line: five lines.
        click_at(*place['text-edit'])
        press('ctrl-a')
        press('ctrl-c')
        press('end')
        press('ctrl-v')
        time.sleep(0.5)
    for keys in (('alt-h', 'ret'), ('alt-h', 'a'), ('f10', 'right', 'down', 'ret'),
                 ('alt', 'right', 'down', 'ret')):
        for key in keys:
            press(key)
            time.sleep(0.3)
        time.sleep(1)
        press('ret')
        time.sleep(0.8)
    click_at(*place['tree-tab'])
    type_on_serial(b'm=DONE; cat /tmp/t.log; echo TREE $m\r')
    wait_for('TREE DONE', 10)
    place = places()
    if 'tree-line-1' in place:
        click_at(*place['tree-line-1'])
    press('right')
    press('down')
    click_at(*place['details-tab'])
    type_on_serial(b'm=DONE; cat /tmp/t.log; echo DETAILS $m\r')
    wait_for('DETAILS DONE', 10)
    place = places()
    if 'details-row-2' in place:
        click_at(*place['details-row-2'])
    if 'details-header-1' in place:
        click_at(*place['details-header-1'])
    if all(name in place for name in ('details-row-1', 'details-row-3', 'details-header-2', 'large-icons')):
        click_at(*place['details-header-2'])
        click_at(*place['details-row-1'])
        click_holding('ctrl', *place['details-row-3'])
        click_holding('shift', *place['details-row-2'])
        click_at(*place['large-icons'])
        type_on_serial(b'm=DONE; cat /tmp/t.log; echo ICONS $m\r')
        wait_for('ICONS DONE', 10)
        place = places()
        if 'details-icon-1' in place:
            icon_x, icon_y = place['details-icon-1']
            pixel = take_screen()
            icon_pixels = [pixel(x, y) for x in range(icon_x - 8, icon_x + 9) for y in range(icon_y - 8, icon_y + 9)]
type_on_serial(b'm=DONE; cat /tmp/t.log; kill %1; wait; echo TOUR $m\r')
tour_ok = tour_started and wait_for('TOUR DONE', 15)
log_from_here = bytes(received[received.rfind(b'TOUR $m'):])
checks.append(('controls tour: toolbar, list box, combo box', tour_ok and b'toolbar Bold 1' in log_from_here and
               b'list Item 3' in log_from_here and b'combo Second' in log_from_here))
checks.append(('controls tour: menu, message box, accelerator', tour_ok and b'menu About' in log_from_here and
               b'answer 1' in log_from_here and b'answer 2' in log_from_here))
checks.append(('controls tour: menus from the keyboard (Alt+H, a mnemonic letter, F10, Alt alone)',
               tour_ok and log_from_here.count(b'menu About') == 5 and log_from_here.count(b'answer 1') == 5))
checks.append(('owned windows: a message box stays above its disabled owner and keeps the keyboard',
               tour_ok and owned_box_above and b'answer 1' in log_from_here))
checks.append(('controls tour: tabs, tree view, list view', tour_ok and b'page 2' in log_from_here and
               b'tree System' in log_from_here and b'tree lib' in log_from_here and b'page 3' in log_from_here and
               b'row picture.bmp' in log_from_here and b'column 0' in log_from_here))
checks.append(('controls tour: clipboard keys and context menu in edit boxes',
               tour_ok and re.search(rb'pasted copy me\r?\n', log_from_here) is not None and
               b'pasted copy mecopy me' in log_from_here and b'edit 5' in log_from_here))
checks.append(('controls tour: list view sorted by a header (as numbers)',
               tour_ok and b'column 1' in log_from_here and b'order notes.txt,tour,picture.bmp' in log_from_here))
checks.append(('controls tour: list view selection with Ctrl+click and Shift+click',
               tour_ok and b'selected notes.txt,picture.bmp' in log_from_here and
               b'selected tour,picture.bmp' in log_from_here))
# The document icon's lines of text are this blue.
checks.append(('controls tour: list view large icons',
               tour_ok and b'view 3' in log_from_here and '5b87c0' in icon_pixels))

# The common dialogs (dialogtour), which prints where the controls of
# each dialog are when it appears: the open dialog (a click on /etc and
# Enter opens it, a click on passwd and OK takes it), the save dialog
# (a name typed and Enter; then an existing file, whose replacement is
# refused, and Escape), the colour dialog (a basic colour, OK) and the
# font dialog (a size that shows in its list, Bold, OK).
type_on_serial(b'displayserver &\r')
wait_for('displayserver: ready', 20)
type_on_serial(b'dialogtour > /tmp/d.log &\r')
time.sleep(3)


def dialog_places(marker):
    type_on_serial(b'm=DONE; cat /tmp/d.log; echo ' + marker.encode() + b' $m\r')
    wait_for(marker + ' DONE', 10)
    return places()


place = dialog_places('DIALOGS')
dialogs_started = all(name in place for name in ('open-button', 'save-button', 'color-button', 'font-button'))
if dialogs_started:
    click_at(*place['open-button'])
    time.sleep(1)
    place = dialog_places('OPEN')
    if 'file-etc' in place:
        click_at(*place['file-etc'])
        press('ret')
        time.sleep(1)
        place = dialog_places('ETC')
    if 'file-passwd' in place:
        click_at(*place['file-passwd'])
        click_at(*place['file-ok'])
    time.sleep(1)
    click_at(*place['save-button'])
    time.sleep(1)
    type_on_keyboard('notes.txt')
    press('ret')
    time.sleep(1)
    click_at(*place['save-button'])
    time.sleep(1)
    for key in ('slash', 'e', 't', 'c', 'slash', 'p', 'a', 's', 's', 'w', 'd', 'ret'):
        press(key)
    time.sleep(1)
    # The question whether to replace it: Escape says no; Escape again
    # cancels the dialog.
    press('esc')
    time.sleep(0.8)
    press('esc')
    time.sleep(0.8)
    click_at(*place['color-button'])
    time.sleep(1)
    place = dialog_places('COLOR')
    if 'color-3' in place:
        click_at(*place['color-3'])
        click_at(*place['color-ok'])
    time.sleep(1)
    click_at(*place['font-button'])
    time.sleep(1)
    place = dialog_places('FONT')
    if 'size-11' in place:
        click_at(*place['size-11'])
        click_at(*place['bold'])
        click_at(*place['font-ok'])
    time.sleep(1)
type_on_serial(b'm=DONE; cat /tmp/d.log; kill %1; wait; echo DIALOGS $m\r')
dialogs_ok = dialogs_started and wait_for('DIALOGS DONE', 15)
log_from_here = bytes(received[received.rfind(b'DIALOGS $m'):])
checks.append(('common dialogs: open a file (a folder opened, a file chosen)',
               dialogs_ok and b'opened /etc/passwd' in log_from_here))
checks.append(('common dialogs: save a file (a name typed; replacing refused)',
               dialogs_ok and b'saved /tmp/notes.txt' in log_from_here and b'cancelled save' in log_from_here and
               b'saved /etc/passwd' not in log_from_here))
checks.append(('common dialogs: choose a colour and a font',
               dialogs_ok and b'color 00FF00' in log_from_here and b'font 110 bold' in log_from_here))

# Notepad, from the keyboard: /etc/passwd opened from the command line
# (its name in the title, its first line shown); words typed at its end,
# the last undone (Ctrl+Z) and done again (Ctrl+Y); saved as
# /tmp/note.txt through the save dialog (File > Save As from the
# keyboard, the name typed, Enter) and read back over the serial shell;
# a word found (Ctrl+F, typed, Enter) and found again (F3); a new
# document (Ctrl+N: nothing to save) with a line too long for the
# window, broken into rows by word wrap (Format > Word Wrap), where Home
# goes to the start of the caret's row, and joined again; then File >
# Exit asks to save the changes: Cancel keeps it open, No ends it.
type_on_serial(b'displayserver &\r')
wait_for('displayserver: ready', 20)
type_on_serial(b'notepad /etc/passwd > /tmp/n.log &\r')
time.sleep(3)


def notepad_log(marker):
    type_on_serial(b'm=DONE; cat /tmp/n.log; echo ' + marker.encode() + b' $m\r')
    wait_for(marker + ' DONE', 15)
    return bytes(received[received.rfind(marker.encode() + b' $m'):])


def last_status(log):
    found = re.findall(rb'status (\d+) (\d+)', log)
    return (int(found[-1][0]), int(found[-1][1])) if found else (0, 0)


log_from_here = notepad_log('NOTEPAD-OPENED')
notepad_started = b'title passwd - Notepad' in log_from_here
checks.append(('notepad: a file opened from the command line (title, first line)',
               notepad_started and b'opened /etc/passwd' in log_from_here and
               b'first-line root:x:0:0:Administrator:/:/bin/sh' in log_from_here))
long_line = 'the quick brown fox jumps over the lazy dog ' * 3
wrapped_status = (0, 0)
file_ok = False
if notepad_started:
    press('ctrl-end')
    type_on_keyboard('hello world')
    press('ctrl-z')
    time.sleep(0.5)
    press('ctrl-y')
    time.sleep(0.5)
    press('alt-f')
    time.sleep(0.5)
    press('a')
    time.sleep(1.5)
    for key in ('slash', 't', 'm', 'p', 'slash', 'n', 'o', 't', 'e', 'dot', 't', 'x', 't', 'ret'):
        press(key)
    time.sleep(1.5)
    # (The file ends without a line feed: the echo follows on its line.)
    type_on_serial(b'cat /tmp/note.txt; m=DONE; echo NOTE $m\r')
    file_ok = wait_for('NOTE DONE', 10)
    file_output = bytes(received[received.rfind(b'NOTE $m'):])
    file_ok = file_ok and re.search(rb'\nroot:x:0:0:Administrator:/:/bin/sh\r?\nuser:x:1000:.*\r?\n'
                                    rb'nobody:x:65534:65534:Nobody:/:/bin/false\r?\nhello worldNOTE DONE',
                                    file_output) is not None
    press('ctrl-home')
    press('ctrl-f')
    time.sleep(1)
    type_on_keyboard('user')
    press('ret')
    time.sleep(0.8)
    press('esc')
    time.sleep(0.8)
    press('f3')
    time.sleep(0.5)
    press('ctrl-n')
    time.sleep(0.8)
    type_on_keyboard(long_line.strip())
    press('alt-o')
    time.sleep(0.5)
    press('w')
    time.sleep(0.8)
    press('home')
    time.sleep(0.5)
    wrapped_status = last_status(notepad_log('NOTEPAD-WRAPPED'))
    press('alt-o')
    time.sleep(0.5)
    press('w')
    time.sleep(0.8)
    press('alt-f')
    time.sleep(0.5)
    press('x')
    time.sleep(1)
    press('esc')
    time.sleep(0.8)
    press('alt-f')
    time.sleep(0.5)
    press('x')
    time.sleep(1)
    press('alt-n')
    time.sleep(1)
log_from_here = notepad_log('NOTEPAD-ENDED')
type_on_serial(b'kill %1; wait; m=DONE; echo NOTEPAD-SERVER $m\r')
wait_for('NOTEPAD-SERVER DONE', 15)
wrap_rows = re.search(rb'wrap on (\d+)', log_from_here)
checks.append(('notepad: undo a word, redo it', notepad_started and
               re.search(rb'undone hello \r?\n', log_from_here) is not None and
               b'redone hello world' in log_from_here))
checks.append(('notepad: saved as a new file through the save dialog (its text read back)',
               notepad_started and b'saved /tmp/note.txt' in log_from_here and
               b'title note.txt - Notepad' in log_from_here and file_ok))
checks.append(('notepad: find (Ctrl+F) and find next (F3)',
               notepad_started and b'found 2 1' in log_from_here and b'found 2 27' in log_from_here))
checks.append(('notepad: word wrap breaks a long line into rows; Home goes to the row\'s start',
               notepad_started and b'title Untitled - Notepad' in log_from_here and wrap_rows is not None and
               int(wrap_rows.group(1)) >= 2 and b'wrap off 1' in log_from_here and wrapped_status[0] == 1 and
               1 < wrapped_status[1] < len(long_line.strip()) + 1))
checks.append(('notepad: Exit asks to save the changes (Cancel stays, No ends it)',
               notepad_started and b'answer cancel' in log_from_here and b'answer no' in log_from_here and
               log_from_here.count(b'\nexit') == 1 and
               log_from_here.find(b'answer cancel') < log_from_here.find(b'answer no')))

# Suspend to RAM: the machine sleeps (QEMU says so), wakes on request,
# and every device works again: the disks (a file written and read back
# on each), the three sound outputs (recorded), and the display.
type_on_serial(b'suspend; echo RESUMED $?\r')
asleep = wait_for('suspending to RAM', 20)
time.sleep(2)
status = b''
try:
    # What earlier commands answered is still waiting: read it away first.
    monitor.settimeout(0.2)
    while True:
        monitor.recv(65536)
except OSError:
    pass
try:
    monitor.sendall(b'info status\n')
    time.sleep(0.5)
    monitor.settimeout(1)
    status = monitor.recv(65536)
except OSError:
    pass
checks.append(('suspend to RAM: the machine went to sleep', asleep and b'suspended' in status))
send_to_monitor('system_wakeup\n')
checks.append(('suspend to RAM: woke and the program went on', wait_for('RESUMED 0', 90)))
# (The markers are built from a variable: the shell echoes the command
# line, which must not already hold them.)
# Every disk read raw past what was read so far (the system disk on AHCI
# is disk1, then the virtio, NVMe and USB disks), then a file written,
# synced and read back on the system volume and the virtio (ext4), NVMe
# (FAT32) and USB (exFAT) volumes.
type_on_serial(b'for n in 1 3 4 5; do dd if=/dev/disk$n bs=4096 skip=2000 count=16 2>/dev/null | wc -c; done; '
               b'm=DONE; echo READS $m\r')
reads_ok = wait_for('READS DONE', 90)
checks.append(('suspend to RAM: AHCI, virtio, NVMe and USB disks read after waking',
               reads_ok and received.count(b'65536') >= 4))
type_on_serial(b'for d in / /volumes/disk3p1 /volumes/disk4p1 /volumes/disk5p1; do '
               b'echo s3 > $d/s3.txt && cat $d/s3.txt; done; sync; m=DONE; echo WRITES $m\r')
writes_ok = wait_for('WRITES DONE', 90)
checks.append(('suspend to RAM: files written on AHCI, virtio, NVMe and USB volumes after waking',
               writes_ok and received.count(b's3\r\n') + received.count(b's3\n') >= 4))
type_on_serial(b'tone 1000 0.5; tone -d /dev/audio1 700 0.5; tone -d /dev/audio2 500 0.5; m=DONE; echo TONES $m\r')
checks.append(('suspend to RAM: the sound outputs played after waking', wait_for('TONES DONE', 90)))
monitor.sendall(('screendump ' + screen_path + '\n').encode())
time.sleep(1)
display_ok = False
try:
    data = open(screen_path, 'rb').read()
    header = re.match(rb'P6\s+(\d+)\s+(\d+)\s+255\s', data)
    display_ok = int(header.group(1)) > 640 and bytes((0x10, 0x18, 0x30)) in data[header.end():]
except (OSError, AttributeError):
    pass
checks.append(('suspend to RAM: the display came back', display_ok))
type_on_serial(b'events -n 2; m=DONE; echo WOKEN-EVENTS $m\r')
time.sleep(1.5)
move_ps2_mouse('mouse_move -3 5\n')
place_tablet(8192, 16384)
checks.append(('suspend to RAM: the PS/2 mouse and USB tablet work after waking',
               wait_for('WOKEN-EVENTS DONE', 20) and b'motion -3 5' in received and
               b'position 16384 32768' in received))

# Plugging a processor in raises a GPE; its method (\_GPE._E02) tells
# the processor's device to check itself, which the kernel logs.
send_to_monitor('device_add ' + cpu_model + ',id=hotcpu,socket-id=0,core-id=' + processors + ',thread-id=0\n')
checks.append(('a processor plugged in: GPE, its AML method and the Notify',
               wait_for('notify \\_SB_.CPUS.C00' + processors + ' 0x01', 20)))

# The power button: every program ends, the disks are written out, and
# the machine powers itself off (ACPI S5): QEMU exits on its own.
send_to_monitor('system_powerdown\n')
try:
    qemu.wait(timeout=60)
except subprocess.TimeoutExpired:
    qemu.kill()
    qemu.wait()
collect(0.5)
checks.append(('the power button shut down and powered off (S5)',
               qemu.returncode == 0 and b'power button pressed' in received and
               b'entering S5' in received))

# What the sound outputs played after waking.
check_audio = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'check-audio.py')
for name, expected in (('hda', '1000:0.5'), ('ac97', '700:0.5'), ('usb', '500:0.5')):
    played = subprocess.run([sys.executable, '-I', check_audio, recordings[name], expected],
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    checks.append(('suspend to RAM: ' + name + ' sound after waking (' + played.stdout.decode().strip() + ')',
                   played.returncode == 0))

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
