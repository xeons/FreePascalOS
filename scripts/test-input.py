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
Input test: boots the system in text mode (kernel option mode=text) with
root logged in automatically on the console (autologin=root: the service
manager's console service runs login -a, which starts /bin/sh) and types
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
    options.write('test-exit kshell mode=text autologin=root heapchecks\n')
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
    '-netdev', 'user,id=net0', '-device', 'virtio-net-pci,netdev=net0',
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
    # Network cards, each on its own user-mode network: their links must
    # come back after waking.
    '-netdev', 'user,id=net1', '-device', 'e1000e,netdev=net1',
    '-netdev', 'user,id=net2', '-device', 'e1000,netdev=net2',
    '-netdev', 'user,id=net3', '-device', 'rtl8139,netdev=net3',
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


def wait_for_after(text, start, seconds):
    # The text seen in what came after position start of the output.
    deadline = time.time() + seconds
    while time.time() < deadline:
        collect(0.2)
        if text.encode() in received[start:]:
            return True
    return False


def report_qemu_gone():
    # QEMU ended in the middle of the test (the serial pipe broke): say
    # how it ended and what it printed, and keep everything it left, so
    # the cause is not lost when the next run reuses this folder.
    try:
        status = qemu.wait(timeout=10)
    except subprocess.TimeoutExpired:
        qemu.kill()
        status = qemu.wait()
    if status < 0:
        ending = 'killed by signal ' + str(-status)
    else:
        ending = 'exit status ' + str(status)
    with open(serial_log, 'wb') as log:
        log.write(received)
    kept = work + '-qemu-gone-' + time.strftime('%Y%m%d-%H%M%S')
    shutil.copytree(work, kept, ignore=shutil.ignore_patterns('*.img', 'esp', 'serial.in', 'serial.out'))
    print('INPUT TEST FAILED: QEMU ended during the test (' + ending + '); its errors, the serial log and the '
          'last screen are kept in ' + kept)
    with open(os.path.join(work, 'qemu-errors.log'), 'rb') as errors:
        sys.stdout.write(errors.read().decode(errors='replace'))
    sys.exit(1)


def type_on_serial(data):
    try:
        for byte in data:
            serial_in.write(bytes([byte]))
            time.sleep(0.02)
    except BrokenPipeError:
        report_qemu_gone()


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
    # The level triggered lines (AC'97, e1000, RTL8139) with their counts.
    type_on_serial(b'interrupts\r')
    kernel_shell_ok = kernel_shell_ok and wait_for(' handlers, fired ', 10)
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

KEY_NAMES = {' ': 'spc', '-': 'minus', '|': 'shift-backslash', '.': 'dot', '=': 'equal', '>': 'shift-dot',
             '/': 'slash'}


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
# A key held for 1.5 s repeats (after 500 ms, 11 a second: about ten);
# Caps Lock on the USB keyboard capitalizes and sets its lights.
type_on_keyboard('echo rep')
monitor.sendall(b'sendkey x 1500\n')
time.sleep(1.8)
type_on_keyboard('-end')
press('ret')
repeated = None
for attempt in range(50):
    collect(0.2)
    repeated = re.search(rb'\nrep(x+)-end', bytes(received))
    if repeated:
        break
checks.append(('usb keyboard: a held key repeats', repeated is not None and 5 <= len(repeated.group(1)) <= 20))
type_on_keyboard('echo ')
press('caps_lock')
type_on_keyboard('usb')
press('caps_lock')
type_on_keyboard('-locks')
press('ret')
checks.append(('usb keyboard: caps lock', wait_for('\nUSB-locks', 10)))
checks.append(('usb keyboard: lock lights', b'usbkeyboard0 lights: Num Lock Caps Lock' in received))
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


def is_blue(colour, margin):
    """A clearly blue pixel ('rrggbb'): blue above red by margin and not
    below green. Icons are drawn smoothly from the icon theme's pictures,
    so their colours are told apart this way rather than exactly."""
    if len(colour) != 6:
        return False
    red, green, blue = (int(colour[i:i + 2], 16) for i in (0, 2, 4))
    return blue - red >= margin and blue >= green


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

# The graphical checks below look at exact pixels of the Classic theme
# (the look the system had first: its colours are what they name), so
# the system's theme setting is Classic from here on; the display
# server's own section switches to the default (Sunrise) and back while
# it runs, to check the theme is followed live.
type_on_serial(b'settings set -s Appearance/Theme classic; m=DONE; echo CLASSIC $m\r')
checks.append(('theme: the system\'s setting set to Classic', wait_for('CLASSIC DONE', 10)))

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
# wide, title bars 22 high (their gradient starts 3 pixels into the frame).
# The second window has the text beam over its left half (a pointer
# area). The server reads the pointer's shapes from /lib/pointers, and
# checks every window move (copying what stays visible) against a full
# redraw (--check-moves).
type_on_serial(b'displayserver --check-moves &\r')
server_ready = wait_for('displayserver: ready (1280x800, 100 DPI, scale 100%)', 20)
checks.append(('display server: the pointer\'s shapes read from files',
               wait_for('displayserver: 11 of 11 pointer shapes from /lib/pointers, 11 with pictures', 10)))
type_on_serial(b'wintest -t First -x 100 -y 100 > /tmp/w1.log &\r')
time.sleep(1.5)
type_on_serial(b'wintest -t Second -x 250 -y 200 -c D0E8F0 -b > /tmp/w2.log &\r')
time.sleep(2)
pixel = take_screen()
checks.append(('display server: two windows, stacked, the top one active',
               server_ready and pixel(400, 300) == 'd0e8f0' and pixel(150, 150) == 'f0e8d0' and
               pixel(249, 185) == '17375e' and pixel(99, 85) == '7c7a76'))
# wintest names no icon, so each title bar shows the generic picture (a
# little window: a light body under a navy strip) 16 pixels square, 3
# right of the client area's left and 20 above its top: First's at
# 103-118 x 80-95, Second's at 253-268 x 180-195. On First's inactive
# grey bar its navy strip stands out (no grey of the bar or its title
# is blue), on Second's navy bar its light body.
def icon_box(screen, left, top):
    return [tuple(int(screen(x, y)[i:i + 2], 16) for i in (0, 2, 4))
            for x in range(left, left + 16) for y in range(top, top + 16)]


def has_navy(colours):
    return any(blue - red >= 0x30 and red < 0x70 for red, green, blue in colours)


def has_light(colours):
    return any(min(colour) >= 0xb8 for colour in colours)


checks.append(('window icons: a window without one shows the generic picture (Classic)',
               has_navy(icon_box(pixel, 103, 80)) and has_light(icon_box(pixel, 253, 180)) and
               not has_navy(icon_box(pixel, 140, 80))))
# The pointer is drawn from its 32 pixel pictures at 100% (the build
# draws them, /lib/pointers/*.cur). The text beam's hotspot is in the
# middle of its stem, one white pixel between black ones: so it is 7
# pixels up. The arrow's left edge below its tip is black, the pixel
# inside it (one right, four down) white.
point_tablet_at(320, 330)
beam = take_screen()
point_tablet_at(480, 330)
arrow = take_screen()
checks.append(('pointer shapes: the text beam over a window\'s pointer area, the arrow beside it',
               beam(319, 323) == '000000' and beam(320, 323) == 'ffffff' and beam(321, 323) == '000000' and
               arrow(480, 331) == '000000' and arrow(481, 334) == 'ffffff' and arrow(319, 323) == 'd0e8f0'))
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
checks.append(('display server: maximized', wait_for('resized 1280 778', 10) and wait_for('MAXIMIZED DONE', 5)))
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
# at 379-398 x 79-96): hot under the pointer (a lighter face), pressed
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
               hot(382, 86) == 'e2ded6' and hot(380, 80) == 'ffffff' and
               pressed(382, 86) == 'cbc6bd' and pressed(379, 79) == '7e7a72' and pressed(380, 80) == '35322d' and
               let_up(382, 86) == 'cbc6bd' and let_up(380, 80) == 'ffffff'))
# The theme followed live: set to Sunrise, the display server draws the
# active window's title bar gold (its edge a dark gold line along the
# bar's left, 3 pixels into the frame, at x 99) and the bare desktop in
# Sunrise's blue-violet; set back to Classic, the navy gradient (which
# starts with 17375e at the bar's left) and the teal desktop return.
type_on_serial(b'settings set -s Appearance/Theme sunrise\r')
time.sleep(2)
sunrise = take_screen()
type_on_serial(b'settings set -s Appearance/Theme classic\r')
time.sleep(2)
classic_again = take_screen()
checks.append(('theme: the display server follows the setting live (Sunrise, then Classic again)',
               sunrise(99, 89) == 'ae7a06' and sunrise(500, 350) == '6c78b4' and
               classic_again(99, 89) == '17375e' and classic_again(500, 350) == '2f5f7a'))
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
               re.search(rb'resized 1280 778\r?\nmoved 100 100\r?\nresized 300 200', log_from_here) is not None and
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
               speed_set and pixel(680, 501) == '000000' and pixel(681, 504) == 'ffffff' and
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

# Remembered display settings (the system's settings, libconfiguration):
# a mode and a scale changed with --remember are kept in
# /etc/settings/Display.settings and given back by the next display
# server; deleting them (settings delete -s Display) brings the displays'
# own back for the checks that follow.
type_on_serial(b'displayserver &\r')
wait_for('displayserver: ready', 20)
remember_from = len(received)
type_on_serial(b'displaymode -r 1024x768; displayscale -d 1 -r 125; m=DONE; echo REMEMBER $m\r')
wait_for('REMEMBER DONE', 15)
type_on_serial(b'kill %1; wait; settings list -s Display/0; settings list -s Display/1; m=DONE; echo KEPT $m\r')
kept = wait_for('KEPT DONE', 15)
kept_log = bytes(received[remember_from:])
type_on_serial(b'displayserver &\r')
restarted = wait_for('displayserver: ready (1024x768, 80 DPI, scale 100%)', 20)
restarted_log = bytes(received[remember_from:])
type_on_serial(b'kill %1; wait; settings delete -s Display; ls /etc/settings | grep -c Display; m=DONE; echo FORGOTTEN $m\r')
forgotten = wait_for('FORGOTTEN DONE', 15)
type_on_serial(b'displayserver &\r')
defaults_back = wait_for_count('displayserver: ready (1280x800, 100 DPI, scale 100%)',
                               received.count(b'displayserver: ready (1280x800, 100 DPI, scale 100%)') + 1, 20)
type_on_serial(b'kill %1; wait; m=DONE; echo DEFAULTS $m\r')
wait_for('DEFAULTS DONE', 15)
checks.append(('remembered display settings: a mode and a scale kept in the system\'s settings',
               kept and b'remembered display 0: mode 1024x768' in kept_log and
               b'remembered display 1: scale 125%' in kept_log and
               re.search(rb'Mode = "1024x768"\r?\n', kept_log) is not None and
               re.search(rb'Scale = 125\r?\n', kept_log) is not None))
checks.append(('remembered display settings: the next display server gives them back',
               restarted and b'display 0: remembered mode 1024x768' in restarted_log and
               b'display 1: remembered scale 125%' in restarted_log and
               re.search(rb'display 1: 1024x768 at 1024,0, \d+ DPI, scale 125%', restarted_log) is not None))
checks.append(('remembered display settings: deleted, the displays\' own come back',
               forgotten and re.search(rb'\n0\r?\nFORGOTTEN DONE', bytes(received)) is not None and defaults_back))

# Owned windows (ownertest: A at 100,100 400x300 green, B owned by A,
# C at 300,250 300x200 blue overlapping A; a key takes each step):
# hiding A hides B too and B's program is told (B is not Visible any
# more); showing A shows B again; C and A come in front of each other
# when activated, until C is given A as its owner: then C stays in front
# of A; owned by nothing again, A covers it.
type_on_serial(b'displayserver &\r')
wait_for('displayserver: ready', 20)
point_tablet_at(900, 700)
# Each step is waited for by its line ("step N", which ownertest prints
# when it takes the key), not by a fixed time: under TCG on a busy host a
# key can take longer than any sleep chosen here.
owner_start = len(received)
type_on_serial(b'ownertest | tee /tmp/o.log &\r')
wait_for_after('visible A 1 B 1 C 1', owner_start, 20)
overlaps = []
for step in range(1, 8):
    press('a')
    wait_for_after('step %d' % step, owner_start, 15)
    time.sleep(0.5)
    overlaps.append(take_screen()(400, 320))
press('a')
wait_for_after('step 8', owner_start, 15)
type_on_serial(b'm=DONE; cat /tmp/o.log; kill %1; wait; echo OWNERS $m\r')
owners_ok = wait_for('OWNERS DONE', 15)
log_from_here = bytes(received[received.rfind(b'ownertest |'):])
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
# stem, 7 pixels above the hotspot, black either side of the middle.
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
# Shift+click, then large icons), the pickers (a checked list box item
# toggled with Space, a numeric up/down box stepped by the wheel, a date
# picked from the date picker's calendar), and layout without positions
# (the Layout page: the window resized by its corner, 60 wider and 40
# taller, moves the button anchored to the bottom right of the page by
# as much). The message boxes are owned by the
# window: a click on its title bar while one is open changes nothing in
# its client area (the box stays above it) and leaves its title bar
# inactive (it is disabled), and Enter still goes to the box.
def client_area_of_tour(pixel):
    # Every fourth pixel of the window's client area (60,40, 480x360).
    return [pixel(x, y) for x in range(60, 540, 4) for y in range(40, 400, 4)]


owned_box_above = False
menus_survived = False
hint_pixels = []
picture_pixels = ('', '')
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
anchored_before = None
anchored_after = None
if tour_started:
    click_at(*place['bold'])
    click_at(*place['list-item-3'])
    click_at(*place['combo'])
    click_at(*place['combo-second'])
    # Moving between the menu bar's menus with the mouse: File, then
    # Help, then File again (each press on another heading switches),
    # File's own heading closes it, File opens again and a press outside
    # every menu (the title bar) closes it. A menu closed by a press
    # outside it was once freed while the menu bar still pointed at it,
    # so the next press on a heading crashed the program.
    menus_from = len(received)
    file_heading = (place['help'][0] - 35, place['help'][1])
    for heading in (file_heading, place['help'], file_heading, file_heading, file_heading):
        click_at(*heading)
        time.sleep(0.3)
    click_at(80, 30)
    time.sleep(0.5)
    click_at(*place['help'])
    click_at(place['help'][0] - 8, place['help'][1] + 21)
    time.sleep(1)
    # The pointer where it will click (the window's title bar, y 17-38),
    # so it is drawn in the same place on both screens.
    point_tablet_at(80, 30)
    before = client_area_of_tour(take_screen())
    click_at(80, 30)
    pixel = take_screen()
    owned_box_above = before == client_area_of_tour(pixel) and pixel(59, 30) == '7c7a76'
    menus_survived = b'unhandled exception' not in bytes(received[menus_from:])
    press('ret')
    time.sleep(0.8)
    press('ctrl-m')
    time.sleep(1)
    press('esc')
    time.sleep(0.8)
    # The split button's arrow opens its menu; its second item.
    if 'split-arrow' in place and 'split-menu-2' in place:
        click_at(*place['split-arrow'])
        time.sleep(0.5)
        click_at(*place['split-menu-2'])
        time.sleep(0.5)
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
        # third item (Classic's: 24 pixels each, 5 in: its edge and
        # padding).
        right_click_at(*place['paste-box'])
        click_at(place['paste-box'][0] + 30, place['paste-box'][1] + 5 + 2 * 24 + 12)
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
    # The Pickers page: an item of the checked list box picked by a click
    # on its text and toggled with Space, the numeric up/down box stepped
    # by the wheel (a PS/2 notch, the pointer resting on the box), and a
    # day picked from the date picker's dropped calendar (a pop-up, whose
    # 20th the tour says where it is when it drops).
    click_at(*place['pickers-tab'])
    type_on_serial(b'm=DONE; cat /tmp/t.log; echo PICKERS $m\r')
    wait_for('PICKERS DONE', 10)
    place = places()
    if all(name in place for name in ('checked-item-2', 'quantity', 'date-button')):
        click_at(*place['checked-item-2'])
        press('spc')
        point_tablet_at(*place['quantity'])
        move_ps2_mouse('mouse_move 0 0 1\n')
        time.sleep(0.5)
        click_at(*place['date-button'])
        time.sleep(1)
        type_on_serial(b'm=DONE; cat /tmp/t.log; echo DROPPED $m\r')
        wait_for('DROPPED DONE', 10)
        place = places()
        if 'calendar-day-20' in place:
            click_at(*place['calendar-day-20'])
    # Hints, timers and pictures: the pointer resting on the Bold button
    # shows its hint (two lines, in a tooltip above it); the Pictures
    # page's timer ticks; its picture box shows the animation the tour
    # wrote and read back, zoomed: its blue frame, and the page through
    # its transparent middle.
    if 'pictures-tab' in place:
        bold_x, bold_y = place['bold']
        point_tablet_at(bold_x, bold_y)
        time.sleep(1.5)
        pixel = take_screen()
        hint_pixels = [pixel(x, y) for x in range(bold_x - 40, bold_x + 41, 2) for y in range(bold_y - 60, bold_y - 8, 2)]
        click_at(*place['pictures-tab'])
        type_on_serial(b'm=DONE; cat /tmp/t.log; echo PICTURES $m\r')
        wait_for('PICTURES DONE', 10)
        place = places()
        if all(name in place for name in ('picture-border', 'picture-inside')):
            # (The pointer off the picture, so no hint covers it.)
            point_tablet_at(80, 30)
            time.sleep(0.8)
            pixel = take_screen()
            picture_pixels = (pixel(*place['picture-border']), pixel(*place['picture-inside']))
    # The Layout page, then the window's bottom right corner (its client
    # area ends at 540,400; the frame is 4 wide) dragged 60 right and 40
    # down: the tour says where the anchored button is each time.
    if 'layout-tab' in place:
        click_at(*place['layout-tab'])
        type_on_serial(b'm=DONE; cat /tmp/t.log; echo LAYOUT $m\r')
        wait_for('LAYOUT DONE', 10)
        anchored_before = places().get('anchored-apply')
        drag(542, 402, 602, 442)
        time.sleep(1)
        type_on_serial(b'm=DONE; cat /tmp/t.log; echo RESIZED $m\r')
        wait_for('RESIZED DONE', 10)
        anchored_after = places().get('anchored-apply')
type_on_serial(b'm=DONE; cat /tmp/t.log; kill %1; wait; echo TOUR $m\r')
tour_ok = tour_started and wait_for('TOUR DONE', 15)
log_from_here = bytes(received[received.rfind(b'TOUR $m'):])
checks.append(('controls tour: toolbar, list box, combo box', tour_ok and b'toolbar Bold 1' in log_from_here and
               b'list Item 3' in log_from_here and b'combo Second' in log_from_here))
checks.append(('controls tour: menu, message box, accelerator', tour_ok and b'menu About' in log_from_here and
               b'answer 1' in log_from_here and b'answer 2' in log_from_here))
checks.append(('controls tour: switching menus with the mouse, closing one by a press outside',
               tour_ok and menus_survived and b'menu About' in log_from_here))
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
# The document icon's lines of text are blue.
checks.append(('controls tour: list view large icons',
               tour_ok and b'view 3' in log_from_here and any(is_blue(colour, 60) for colour in icon_pixels)))
checks.append(('controls tour: checked list box (Space), numeric up/down (the wheel), a date from the calendar pop-up',
               tour_ok and b'checked Pears 1' in log_from_here and
               (b'quantity 6' in log_from_here or b'quantity 4' in log_from_here) and
               b'date 2026-11-20' in log_from_here))
checks.append(('controls tour: a hint shows when the pointer rests on a control (two lines, in a tooltip)',
               tour_ok and b'hint Bold / Makes the text bold (stays down)' in log_from_here and
               'f4efd8' in hint_pixels))
checks.append(('controls tour: a timer ticks', tour_ok and b'tick 3' in log_from_here))
checks.append(('controls tour: a split button\'s arrow opens its menu',
               tour_ok and b'looks Second choice' in log_from_here))
checks.append(('controls tour: a picture box shows an animation read from a file, transparent in its middle',
               tour_ok and b'picture 12' in log_from_here and picture_pixels == ('3060c0', 'cbc6bd')))
checks.append(('controls tour: a button anchored to the bottom right follows the corner of a resized window',
               tour_ok and anchored_before is not None and anchored_after is not None and
               anchored_after == (anchored_before[0] + 60, anchored_before[1] + 40)))

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
dialog_refreshed = False
if dialogs_started:
    click_at(*place['open-button'])
    time.sleep(1)
    place = dialog_places('OPEN')
    open_screen = take_screen()
    # Another program adds a file to the folder shown: the list is read
    # again (the dialog watches its folder).
    type_on_serial(b'touch /dialog-refresh.txt\r')
    time.sleep(1.5)
    dialog_places('REFRESHED')
    refreshed_log = bytes(received[received.rfind(b'REFRESHED $m'):])
    dialog_refreshed = b'folder changed' in refreshed_log and b'row dialog-refresh.txt' in refreshed_log
    if 'file-etc' in place:
        click_at(*place['file-etc'])
        press('ret')
        time.sleep(1)
        place = dialog_places('ETC')
    # passwd is chosen by typing its name in the list (the list has the
    # focus, from the click on etc): /etc has more files than the list
    # shows, and which of them show changes as files are added there.
    if 'file-ok' in place:
        type_on_keyboard('passwd')
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
# (A marker of its own: "DIALOGS DONE" was already printed once above.)
type_on_serial(b'm=DONE; cat /tmp/d.log; kill %1; wait; echo DIALOGS-ENDED $m\r')
dialogs_ok = dialogs_started and wait_for('DIALOGS-ENDED DONE', 15)
log_from_here = bytes(received[received.rfind(b'DIALOGS-ENDED $m'):])
type_on_serial(b'rm /dialog-refresh.txt\r')
checks.append(('common dialogs: the file list follows a change another program made',
               dialogs_started and dialog_refreshed))
checks.append(('common dialogs: open a file (a folder opened, a file chosen)',
               dialogs_ok and b'opened /etc/passwd' in log_from_here))
checks.append(('common dialogs: save a file (a name typed; replacing refused)',
               dialogs_ok and b'saved /tmp/notes.txt' in log_from_here and b'cancelled save' in log_from_here and
               b'saved /etc/passwd' not in log_from_here))
checks.append(('common dialogs: choose a colour and a font',
               dialogs_ok and b'color 00FF00' in log_from_here and b'font 110 bold' in log_from_here))
# Window icons: dialogtour names its window's icon (app-dialogs), drawn
# at the left of its title bar (16 pixels, 3 right of the client area's
# left and 20 above its top); the open dialog, owned by it, names none
# and shows its owner's: the opaque pixels of the two icons are alike
# (the owner's bar is inactive, the dialog's active, so only the icon's
# own pixels match), and the owner's has the white of its little
# windows, which the plain navy bar has not.
def title_icon_pixels(screen, client):
    left, top = client[0] + 3, client[1] - 20
    return [screen(x, y) for y in range(top, top + 16) for x in range(left, left + 16)]


if dialogs_started and 'tour-client' in place and 'dialog-client' in place:
    owner_icon = title_icon_pixels(open_screen, place['tour-client'])
    dialog_icon = title_icon_pixels(open_screen, place['dialog-client'])
    alike = sum(1 for a, b in zip(owner_icon, dialog_icon) if a == b)
    owner_has_icon = any(len(colour) == 6 and all(int(colour[i:i + 2], 16) >= 0xdc for i in (0, 2, 4))
                         for colour in owner_icon)
else:
    alike, owner_has_icon = 0, False
checks.append(('window icons: a window\'s icon in its title bar, and its dialog shows the same',
               owner_has_icon and alike >= 40))

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
# kill asks a program with windows to end: Notepad, with nothing to
# save, closes its window as if its close button were clicked and ends
# by itself (status 0, not 143).
type_on_serial(b'notepad > /tmp/k.log & until grep -q title /tmp/k.log 2>/dev/null; do sleep 0.2; done; sleep 1; '
               b'kill $!; wait $!; echo NOTEPAD-ASKED $?; tail -n 1 /tmp/k.log\r')
asked_ended = wait_for('NOTEPAD-ASKED 0', 30)
collect(0.5)
asked_output = bytes(received[received.rfind(b'NOTEPAD-ASKED 0'):])
checks.append(('notepad: kill asks it to end, and it closes its window by itself (status 0)',
               asked_ended and re.search(rb'NOTEPAD-ASKED 0\r?\nexit', asked_output) is not None))
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

# Notepad remembers its format in the user's settings (root's here, in
# /.settings): word wrap, turned off last above, is off when it starts;
# turned on and Notepad ended, the next Notepad starts with it on. The
# settings are deleted afterwards.
type_on_serial(b'displayserver &\r')
wait_for('displayserver: ready', 20)
type_on_serial(b'notepad > /tmp/n2.log &\r')
time.sleep(3)
press('alt-o')
time.sleep(0.5)
press('w')
time.sleep(0.8)
press('alt-f')
time.sleep(0.5)
press('x')
time.sleep(1)
remembered_from = len(received)
type_on_serial(b'cat /tmp/n2.log; settings get Notepad/WordWrap; notepad > /tmp/n3.log & sleep 3; cat /tmp/n3.log; '
               b'kill $!; wait $!; settings delete Notepad; kill %1; wait; m=DONE; echo NOTEPAD-AGAIN $m\r')
again_ok = wait_for('NOTEPAD-AGAIN DONE', 30)
again_log = bytes(received[remembered_from:])
checks.append(('notepad: word wrap is remembered for the next Notepad (the user\'s settings)',
               again_ok and b'settings word-wrap off, status-bar on' in again_log and
               re.search(rb'wrap on \d+', again_log) is not None and
               re.search(rb'\ntrue\r?\n', again_log) is not None and
               b'settings word-wrap on, status-bar on' in again_log))

def shell_output(command, marker, seconds=20):
    # What the serial shell printed for command (a long command line is
    # echoed scrolled sideways, so what follows the typing is taken).
    start = len(received)
    type_on_serial(command.encode() + b'; m=DONE; echo ' + marker.encode() + b' $m\r')
    wait_for(marker + ' DONE', seconds)
    return bytes(received[start:])


# The calculator, from the keyboard: 12*(3+4) typed on the keyboard
# (Shift for * and the parentheses) and Enter give 84, the expression
# shown above it; Ctrl+C copies the number (read back
# with the clipboard tool). Its settings are deleted afterwards.
type_on_serial(b'displayserver &\r')
wait_for('displayserver: ready', 20)
type_on_serial(b'calculator > /tmp/calc.log &\r')
time.sleep(3)
for key in ('1', '2', 'shift-8', 'shift-9', '3', 'shift-equal', '4', 'shift-0', 'ret'):
    press(key)
time.sleep(1)
press('ctrl-c')
time.sleep(0.8)
calculator_from = len(received)
type_on_serial(b'clipboard -p; echo; kill %2; wait %2; cat /tmp/calc.log; settings delete Calculator; kill %1; wait; '
               b'm=DONE; echo CALCULATOR $m\r')
calculator_ok = wait_for('CALCULATOR DONE', 30)
calculator_log = bytes(received[calculator_from:])
checks.append(('calculator: 12*(3+4) typed on the keyboard and Enter give 84; Ctrl+C copies it',
               calculator_ok and re.search(rb'result 12 \xc3\x97 \(3 \+ 4\) = 84', calculator_log) is not None and
               re.search(rb'\n84\r?\n', calculator_log) is not None and b'copied 84' in calculator_log))
# The browser shows a local page (file:///tmp/browser-test.html, written
# here): it prints the page's title and that it loaded, the page's
# script logs to the console (scripting is on), and the page's orange
# background is on the screen inside the window. Its settings and
# profile are deleted afterwards. The page has a float at the start of a
# line followed by a word too wide to go beside it, which once made the
# layout move the line down for ever and froze the browser
# (www.wikipedia.org's fundraising banner): then nothing was painted.
type_on_serial(b"printf '<!DOCTYPE html><title>Browser test</title><body style=\"background:#ff8000\">"
               b"<p>Local page</p><div style=\"width:300px\"><span style=\"float:left;width:200px;height:20px\">"
               b"</span>Unbreakablewordwiderthanroom</div>"
               b"<script>console.log(\"script ran \" + (40 + 2))</script>' "
               b"> /tmp/browser-test.html\r")
time.sleep(0.5)
type_on_serial(b'displayserver &\r')
wait_for('displayserver: ready', 20)
type_on_serial(b'/app/browser/browser file:///tmp/browser-test.html > /tmp/browser.log 2>&1 &\r')


def browser_colour_near(colour, expected):
    return len(colour) == 6 and all(abs(int(colour[i:i + 2], 16) - int(expected[i:i + 2], 16)) <= 8 for i in (0, 2, 4))


# The page on the screen: a new renderer runs its platform scripts first
# (seconds under TCG, more on a busy host), so the screen is looked at
# until the page shows, for up to 40 s.
time.sleep(8)
browser_screen = take_screen()
browser_deadline = time.time() + 32
while not browser_colour_near(browser_screen(500, 500), 'ff8000') and time.time() < browser_deadline:
    time.sleep(1)
    browser_screen = take_screen()

browser_from = len(received)
type_on_serial(b'kill %2; wait %2; cat /tmp/browser.log; settings delete Browser; rm -r /.settings/browser; kill %1; wait; '
               b'm=DONE; echo BROWSER $m\r')
browser_ok = wait_for('BROWSER DONE', 30)
browser_log = bytes(received[browser_from:])
checks.append(('browser: a local page loads (title, loaded), its script runs, its background is on the screen '
               '(a float wider than the room beside it does not hang the layout)',
               browser_ok and b'title Browser test' in browser_log and
               b'loaded file:///tmp/browser-test.html' in browser_log and b'console log script ran 42' in browser_log and
               browser_colour_near(browser_screen(500, 500), 'ff8000')))
# The browser's chrome, laid out as browsers were before they hid their
# menus: the menu bar, then the toolbars, then the tabs under them, then
# the page (the window prints where each is). From the keyboard: Tools >
# Options... (Alt+T, O), the Tabs pane (Ctrl+Tab), "Open new windows in a
# new tab" turned off (Alt+B) and OK (Enter): the setting is kept; the
# Library (Ctrl+Shift+B, closed with Alt+F4); the location bar (Ctrl+L)
# suggests the page visited when part of its title is typed, and Down
# and Enter go to it; the find bar (Ctrl+F) finds text on the page and
# Highlight all (Alt+A) highlights every match. Its settings and profile
# are deleted afterwards.
type_on_serial(b'displayserver &\r')
wait_for('displayserver: ready', 20)
type_on_serial(b'/app/browser/browser file:///tmp/browser-test.html > /tmp/chrome.log 2>&1 &\r')
time.sleep(8)
press('alt-t')
time.sleep(0.6)
press('o')
time.sleep(2)
press('ctrl-tab')
time.sleep(0.5)
press('alt-b')
time.sleep(0.3)
press('ret')
time.sleep(1)
press('ctrl-shift-b')
time.sleep(2.5)
press('alt-f4')
time.sleep(1)
press('ctrl-l')
time.sleep(0.3)
type_on_keyboard('browser')
time.sleep(1.5)
press('down')
time.sleep(0.3)
press('ret')
time.sleep(3)
press('ctrl-f')
time.sleep(0.5)
type_on_keyboard('Local')
time.sleep(1)
press('alt-a')
time.sleep(1)
chrome_screen = take_screen()
chrome_from = len(received)
type_on_serial(b'kill %2; wait %2; cat /tmp/chrome.log; settings get Browser/NewWindowsInTabs; settings delete Browser; '
               b'rm -r /.settings/browser; kill %1; wait; m=DONE; echo CHROME $m\r')
chrome_ok = wait_for('CHROME DONE', 30)
chrome_log = bytes(received[chrome_from:])
layout = re.search(rb'layout menu (\d+) toolbars (\d+) tabs (\d+) content (\d+)', chrome_log)
checks.append(('browser chrome: the menu bar, then the toolbars, then the tabs under them, then the page',
               chrome_ok and layout is not None and
               int(layout.group(1)) < int(layout.group(2)) < int(layout.group(3)) < int(layout.group(4))))
checks.append(('browser chrome: Tools > Options... changes a setting from the keyboard and keeps it',
               chrome_ok and b'options open' in chrome_log and b'options saved' in chrome_log and
               re.search(rb'\nfalse\r?\n', chrome_log) is not None))
checks.append(('browser chrome: the Library opens (Ctrl+Shift+B)', chrome_ok and b'library open bookmarks' in chrome_log))
checks.append(('browser chrome: the location bar suggests a visited page by its title, and goes to it',
               chrome_ok and re.search(rb'suggest browser [1-9]', chrome_log) is not None and
               chrome_log.count(b'loaded file:///tmp/browser-test.html') >= 2))
checks.append(('browser chrome: the find bar finds text and highlights every match',
               chrome_ok and b'found Local' in chrome_log and b'highlight Local' in chrome_log))
# The browser's process model: pages run in content processes, one per
# site. Two local pages (the site file:) share one renderer, a page
# served from here (http://10.0.2.2, another site) gets its own: two
# webcontent processes. The served page loops for ever (the slow script
# watchdog off, Browser/ScriptRunLimit 0): its tab gets the "not
# responding" bar (Browser/HangTimeout 4 s) and Stop page ends its
# process (the tab shows it crashed). about:crash crashes the local
# pages' renderer: both its tabs show "This tab crashed", Reload brings
# the page back in a new process, and the browser itself lives on.
import functools
import http.server
import threading
served_directory = os.path.join(work, 'served')
os.makedirs(served_directory, exist_ok=True)
with open(os.path.join(served_directory, 'hang.html'), 'w') as page:
    page.write('<!DOCTYPE html><title>Hang</title><body style="background:#0080ff"><p>This page will hang</p>'
               '<script>setTimeout(function(){ while(true){} }, 4000)</script>')
served = http.server.ThreadingHTTPServer(('127.0.0.1', 0), functools.partial(
    http.server.SimpleHTTPRequestHandler, directory=served_directory))
threading.Thread(target=served.serve_forever, daemon=True).start()
served_port = served.server_address[1]
type_on_serial(b"printf '<!DOCTYPE html><title>Local A</title><body style=\"background:#ff8000\"><h1>A</h1>' > /tmp/pa.html; "
               b"printf '<!DOCTYPE html><title>Local B</title><body style=\"background:#ffff00\"><h1>B</h1>' > /tmp/pb.html; "
               b"settings set Browser/ScriptRunLimit 0; settings set Browser/HangTimeout 4\r")
time.sleep(1)
type_on_serial(b'displayserver &\r')
wait_for('displayserver: ready', 20)
type_on_serial(('/app/browser/browser file:///tmp/pa.html http://10.0.2.2:' + str(served_port) +
                '/hang.html file:///tmp/pb.html > /tmp/procs.log 2>&1 &\r').encode())
time.sleep(14)
processes_from = len(received)
# (pgrep never counts itself; ps | grep counted the grep too.)
type_on_serial(b'm=DONE; echo RENDERERS $(pgrep -c webcontent) $m\r')
# The count itself, not the echoed command line (which has RENDERERS
# too, and comes first: on a busy host pgrep answers later).
renderers_deadline = time.time() + 20
while time.time() < renderers_deadline and \
        re.search(rb'RENDERERS \d+ DONE', bytes(received[processes_from:])) is None:
    collect(0.2)
processes_two = re.search(rb'RENDERERS 2 DONE', bytes(received[processes_from:])) is not None
# The served tab is the last (the third address opened after the first).
press('ctrl-tab')
time.sleep(0.5)
press('ctrl-tab')
time.sleep(8)
hung_screen = take_screen()
click_at(590, 171)
time.sleep(3)
press('ctrl-tab')
time.sleep(1)
press('ctrl-l')
for character in 'about:crash':
    press({':': 'shift-semicolon'}.get(character, character))
press('ret')
time.sleep(4)
crashed_screen = take_screen()
click_at(105, 278)
time.sleep(6)
reloaded_screen = take_screen()
procs_from = len(received)
type_on_serial(b'kill %2; wait %2; cat /tmp/procs.log; settings delete Browser; rm -r /.settings/browser; kill %1; wait; '
               b'm=DONE; echo PROCS $m\r')
procs_ok = wait_for('PROCS DONE', 30)
served.shutdown()
procs_log = bytes(received[procs_from:])
checks.append(('browser processes: one renderer per site (two for three tabs)', processes_two))
checks.append(('browser processes: the looping page is "not responding", Stop ends its renderer and its tab shows '
               'it crashed',
               procs_ok and re.search(rb'process hung 1 tab 2', procs_log) is not None and
               b'process stop 0 tab 2' in procs_log and re.search(rb'process crashed 137 tab 2', procs_log) is not None))
checks.append(('browser processes: about:crash crashes the local pages\' renderer (both its tabs), the served tab is '
               'untouched, Reload starts the page in a new renderer, the browser lives on',
               procs_ok and len(re.findall(rb'process crashed \d+ tab [01]', procs_log)) == 2 and
               procs_log.count(b'loaded file:///tmp/pa.html') >= 2 and b'exit' in procs_log and
               browser_colour_near(reloaded_screen(500, 400), 'ff8000')))
# A renderer starting up runs the platform scripts for its window's
# realm (seconds under TCG, more on a busy host) and answers the pings
# between them (Web.LongWork), so it is not "not responding": neither the
# first local page (Browser/HangTimeout 8 s by default) nor the local
# pages here (4 s, including the new renderer Reload starts) are taken
# for hung; only the looping page is.
checks.append(('browser processes: a renderer starting up answers pings (only the looping page is "not responding")',
               browser_ok and b'process hung' not in browser_log and
               procs_ok and re.search(rb'process hung 1 tab [01]', procs_log) is None))
# Paint on a new picture (480x320, white): the rectangle tool picked by
# its button in the tool box, a rectangle dragged with the pointer from
# (20, 20) to (120, 80) of the picture (Paint prints where its top left
# pixel and the buttons are), saved as a PNG through the save dialog
# (File > Save As from the keyboard, the name typed, Enter), and read
# back with imageinfo -p: the outline (2 pixels wide, the primary colour,
# black) on the left and top edges, white inside and outside it (a pixel
# either way allowed, for the tablet's rounding). kill asks Paint to end:
# with the picture saved it asks nothing and ends.
type_on_serial(b'displayserver &\r')
wait_for('displayserver: ready', 20)
type_on_serial(b'paint > /tmp/p.log &\r')
time.sleep(4)
type_on_serial(b'm=DONE; cat /tmp/p.log; echo PAINT-STARTED $m\r')
wait_for('PAINT-STARTED DONE', 15)
paint_log = bytes(received[received.rfind(b'PAINT-STARTED $m'):])
paint_place = {match.group(1).decode(): (int(match.group(2)), int(match.group(3)))
               for match in re.finditer(rb'place (\S+) (\d+) (\d+)', paint_log)}
paint_started = b'title Untitled - Paint' in paint_log and 'canvas' in paint_place and \
    'tool-rectangle' in paint_place
paint_output = b''
if paint_started:
    click_at(*paint_place['tool-rectangle'])
    canvas_left, canvas_top = paint_place['canvas']
    drag(canvas_left + 20, canvas_top + 20, canvas_left + 120, canvas_top + 80)
    press('alt-f')
    time.sleep(0.5)
    press('a')
    time.sleep(1.5)
    for key in ('slash', 't', 'm', 'p', 'slash', 'r', 'e', 'c', 't', 'dot', 'p', 'n', 'g', 'ret'):
        press(key)
    time.sleep(2)
    paint_output = shell_output('cat /tmp/p.log; imageinfo -p 19,50 -p 20,50 -p 21,50 -p 22,50 -p 70,19 -p 70,20 '
                                '-p 70,21 -p 70,22 -p 70,50 -p 10,50 -p 150,50 /tmp/rect.png', 'PAINT-SAVED')


def paint_pixel(x, y):
    found = re.search(rb'/tmp/rect.png: pixel ' + str(x).encode() + b',' + str(y).encode() + rb' ([0-9A-F]{8})',
                      paint_output)
    return found.group(1).decode() if found else ''


checks.append(('paint: started on a new picture (the title, where the picture and the tools are)', paint_started))
checks.append(('paint: the rectangle tool picked, a rectangle dragged, saved as a PNG through the save dialog',
               paint_started and b'tool rectangle' in paint_output and b'saved /tmp/rect.png' in paint_output and
               b'title rect.png - Paint' in paint_output and b'/tmp/rect.png: PNG, 480 x 320' in paint_output))
checks.append(('paint: the saved picture has the rectangle (black outline, white inside and outside)',
               any(paint_pixel(x, 50) == 'FF000000' for x in (19, 20, 21, 22)) and
               any(paint_pixel(70, y) == 'FF000000' for y in (19, 20, 21, 22)) and
               paint_pixel(70, 50) == 'FFFFFFFF' and paint_pixel(10, 50) == 'FFFFFFFF' and
               paint_pixel(150, 50) == 'FFFFFFFF'))
type_on_serial(b'kill %2; wait %2; echo PAINT-ASKED $?; kill %1; wait; m=DONE; echo PAINT-ENDED $m\r')
paint_ended = wait_for('PAINT-ENDED DONE', 30)
checks.append(('paint: kill asks it to end, and with the picture saved it ends by itself (status 0)',
               paint_ended and b'PAINT-ASKED 0' in received))

# The file manager (files), on a folder made over the serial shell:
# large icon, list and details views (Ctrl+Shift+2, 5, 6); sorting by a column's header; a folder
# opened with a double click and Back; a new folder (Ctrl+Shift+N)
# renamed with F2; a file copied with Ctrl+C and pasted with Ctrl+V into
# another folder (the copy read back the same); a file dragged onto a
# folder (moved); a file deleted after the question; a file another
# program makes shows without a refresh; the properties of a file (its
# size and mode) and a permission's check box changing its mode (stat
# reads it back); a folder tree copied onto another volume (the virtio
# disk's ext4) with the progress window, and read back; a name already
# there asked about (Skip keeps it, Replace takes the new one); a text
# file opened in Notepad with a double click (Notepad prints its title
# into the same log). It prints where the things to click are.
files_log_text = b''


def files_log(marker):
    # The log so far: only what was added since the last look is read
    # (tail from the bytes seen; the serial line turns each line feed
    # into a carriage return and a line feed), so a long log does not
    # make every look slow under TCG.
    global files_log_text
    offset = len(files_log_text.replace(b'\r\n', b'\n'))
    command = b'm=DONE; tail -c +' + str(offset + 1).encode() + b' /tmp/f.log; echo ' + marker.encode() + b' $m'
    type_on_serial(command + b'\r')
    wait_for(marker + ' DONE', 15)
    output = bytes(received[received.rfind(command):])
    output = output[output.find(b'\n') + 1:]
    end = output.find((marker + ' DONE').encode())
    if end >= 0:
        files_log_text += output[:end]
    return files_log_text


def wait_for_files_log(texts, seconds, since=None):
    # The log until every text has come since the last look (the log
    # only grows, so what is past the last look's length is new), or
    # since the length given: operations run in the background, and
    # under TCG take a while.
    seen = len(files_log_text) if since is None else since
    deadline = time.time() + seconds
    attempt = 0
    while time.time() < deadline:
        attempt += 1
        log = files_log('FLOOK' + str(attempt))
        if all(text.encode() in log[seen:] for text in texts):
            return True
        time.sleep(0.5)
    return False


type_on_serial(b'mkdir -p /tmp/fm/sub /tmp/fm/tree/a/b; echo hello > /tmp/fm/alpha.txt; echo world > /tmp/fm/beta.txt; '
               b'echo deep > /tmp/fm/tree/a/b/deep.txt; dd if=/dev/zero of=/tmp/fm/tree/big.bin bs=65536 count=32 '
               b'2>/dev/null; chmod 644 /tmp/fm/alpha.txt /tmp/fm/beta.txt; settings set -t integer '
               b'Files/ProgressDelay 0; m=DONE; echo FILES-PREPARED $m\r')
wait_for('FILES-PREPARED DONE', 30)
type_on_serial(b'displayserver &\r')
wait_for('displayserver: ready', 20)
type_on_serial(b'files /tmp/fm >> /tmp/f.log &\r')
files_started = wait_for_files_log(['folder /tmp/fm 4', 'place item-alpha.txt', 'place command-view'], 30)
checks.append(('files: a folder shown at start (its items, the places to click)', files_started))
place = places()
views_ok = sorted_ok = back_ok = new_folder_ok = renamed_ok = False
if files_started:
    press('ctrl-shift-5')
    press('ctrl-shift-2')
    press('ctrl-shift-6')
    views_ok = wait_for_files_log(['view list', 'view large', 'view details', 'place header-size'], 20)
    place = places()
    # Sorted by size (a header click), then by name again.
    click_at(*place['header-size'])
    sorted_ok = wait_for_files_log(['sort size ascending'], 15)
    click_at(*places()['header-name'])
    wait_for_files_log(['sort name ascending'], 15)
    place = places()
    double_click_at(*place['item-sub'])
    back_ok = wait_for_files_log(['folder /tmp/fm/sub 0'], 15)
    press('alt-left')
    back_ok = back_ok and wait_for_files_log(['folder /tmp/fm 4'], 15)
    # A new folder, put up for renaming at once: Escape keeps its name,
    # F2 renames it.
    press('ctrl-shift-n')
    new_folder_ok = wait_for_files_log(['new-folder New folder'], 15)
    press('esc')
    time.sleep(0.5)
    press('f2')
    time.sleep(0.5)
    type_on_keyboard('made')
    press('ret')
    renamed_ok = wait_for_files_log(['renamed New folder made'], 15)
checks.append(('files: icon, list and details views; sorted by a header click', views_ok and sorted_ok))
checks.append(('files: a folder opened with a double click, and Back (Alt+Left)', back_ok))
output = shell_output('test -d "/tmp/fm/made" && echo MADE-OK', 'FILES-MADE')
checks.append(('files: a new folder (Ctrl+Shift+N) renamed in place with F2',
               new_folder_ok and renamed_ok and b'\nMADE-OK' in output))

# Copy and paste: beta.txt into the new folder.
copied_ok = False
place = places()
if renamed_ok and 'item-beta.txt' in place and 'item-made' in place:
    click_at(*place['item-beta.txt'])
    press('ctrl-c')
    wait_for_files_log(['clipboard copy 1'], 10)
    double_click_at(*places()['item-made'])
    wait_for_files_log(['folder /tmp/fm/made 0'], 15)
    press('ctrl-v')
    copied_ok = wait_for_files_log(['copied 1'], 30)
output = shell_output('sha256sum /tmp/fm/beta.txt /tmp/fm/made/beta.txt', 'FILES-COPIED')
digests = re.findall(rb'([0-9a-f]{64})  /tmp/fm/', output)
checks.append(('files: a file copied (Ctrl+C) and pasted (Ctrl+V) into another folder, the same',
               copied_ok and len(digests) == 2 and digests[0] == digests[1]))

# Dragged with the mouse onto a folder of the same volume: moved.
moved_ok = False
press('alt-left')
wait_for_files_log(['folder /tmp/fm 5'], 15)
place = places()
if 'item-alpha.txt' in place and 'item-sub' in place:
    drag(place['item-alpha.txt'][0], place['item-alpha.txt'][1], place['item-sub'][0], place['item-sub'][1])
    moved_ok = wait_for_files_log(['dropped move 1 /tmp/fm/sub', 'moved 1', 'refreshed'], 30)
output = shell_output('test -f /tmp/fm/sub/alpha.txt && test ! -e /tmp/fm/alpha.txt && echo MOVED-OK', 'FILES-MOVED')
checks.append(('files: a file dragged onto a folder is moved there', moved_ok and b'\nMOVED-OK' in output))

# Deleted after the question (Enter: Yes).
deleted_ok = False
place = places()
if 'item-beta.txt' in place:
    click_at(*place['item-beta.txt'])
    press('delete')
    asked = wait_for_files_log(['asking delete 1'], 10)
    press('ret')
    deleted_ok = asked and wait_for_files_log(['trashed 1', 'refreshed'], 30)
output = shell_output('test ! -e /tmp/fm/beta.txt && ls /tmp/.Trash-0/files/beta.txt && echo DELETED-OK',
                      'FILES-DELETED')
checks.append(('files: a file moved to the recycle bin after asking (in /tmp/.Trash-0)',
               deleted_ok and b'\nDELETED-OK' in output))
# Undo (Ctrl+Z) brings it back from the recycle bin, Redo (Ctrl+Y) sends
# it there again.
undo_ok = False
if deleted_ok:
    press('ctrl-z')
    undo_ok = wait_for_files_log(['undo delete', 'restored 1'], 30)
    output = shell_output('test -f /tmp/fm/beta.txt && echo UNDONE-OK', 'FILES-UNDONE')
    undo_ok = undo_ok and b'\nUNDONE-OK' in output
    press('ctrl-y')
    undo_ok = undo_ok and wait_for_files_log(['redo delete', 'trashed 1'], 30)
checks.append(('files: Ctrl+Z restores what was deleted, Ctrl+Y deletes it again', undo_ok))

# Another program makes a file: it shows without a refresh.
type_on_serial(b'echo gamma > /tmp/fm/gamma.txt\r')
appeared = wait_for_files_log(['refreshed', 'place item-gamma.txt'], 20)
checks.append(('files: a file made by another program appears without a refresh', appeared))

# Properties: the size and mode; the group's write box changes the mode.
properties_ok = mode_changed = False
place = places()
if appeared and 'item-gamma.txt' in place:
    click_at(*place['item-gamma.txt'])
    press('alt-ret')
    properties_ok = wait_for_files_log(['properties /tmp/fm/gamma.txt size 6 mode 0644',
                                        'place properties-tab-security'], 15)
    if properties_ok:
        click_at(*places()['properties-tab-security'])
        properties_ok = wait_for_files_log(['place permission-group-write'], 15)
    if properties_ok:
        click_at(*places()['permission-group-write'])
        mode_changed = wait_for_files_log(['mode /tmp/fm/gamma.txt 0664'], 15)
        press('esc')
        time.sleep(1)
output = shell_output('stat -c %a /tmp/fm/gamma.txt', 'FILES-MODE')
checks.append(('files: properties show the size and permissions; a check box changes the mode',
               properties_ok and mode_changed and b'\n664' in output))

# A folder tree copied onto another volume, with the progress window.
tree_copied = progress_shown = False
place = places()
if 'item-tree' in place:
    click_at(*place['item-tree'])
    press('ctrl-c')
    press('ctrl-l')
    time.sleep(0.5)
    type_on_keyboard('/volumes/disk3p1')
    press('ret')
    if wait_for_files_log(['folder /volumes/disk3p1'], 15):
        press('ctrl-v')
        tree_copied = wait_for_files_log(['operation copying 1', 'copied 1'], 60)
        progress_shown = b'progress-shown copying' in files_log_text[files_log_text.rfind(b'folder /volumes/disk3p1'):]
output = shell_output('sha256sum /tmp/fm/tree/big.bin /volumes/disk3p1/tree/big.bin; cat /volumes/disk3p1/tree/a/b/deep.txt',
                      'FILES-TREE', 30)
digests = re.findall(rb'([0-9a-f]{64})  /', output)
checks.append(('files: a folder tree copied onto another volume with the progress window, the same',
               tree_copied and progress_shown and len(digests) == 2 and digests[0] == digests[1] and
               b'\ndeep' in output))

# A name already there: Skip leaves the one there, Replace takes the new.
skipped_ok = replaced_ok = False
press('alt-left')
if wait_for_files_log(['folder /tmp/fm 4'], 15):
    place = places()
    click_at(*place['item-gamma.txt'])
    press('ctrl-c')
    press('alt-right')
    wait_for_files_log(['folder /volumes/disk3p1'], 15)
    press('ctrl-v')
    wait_for_files_log(['copied 1', 'refreshed'], 30)
    type_on_serial(b'echo changed > /tmp/fm/gamma.txt\r')
    press('ctrl-v')
    if wait_for_files_log(['question conflict gamma.txt', 'place question-skip'], 30):
        click_at(*places()['question-skip'])
        skipped_ok = wait_for_files_log(['answer skip', 'copied 0'], 30)
    output = shell_output('cat /volumes/disk3p1/gamma.txt', 'FILES-SKIPPED')
    skipped_ok = skipped_ok and b'\ngamma' in output
    press('ctrl-v')
    if wait_for_files_log(['question conflict gamma.txt', 'place question-replace'], 30):
        click_at(*places()['question-replace'])
        replaced_ok = wait_for_files_log(['answer replace', 'copied 1'], 30)
    output = shell_output('cat /volumes/disk3p1/gamma.txt', 'FILES-REPLACED')
    replaced_ok = replaced_ok and b'\nchanged' in output
checks.append(('files: a name already there is asked about (Skip keeps it, Replace takes the new one)',
               skipped_ok and replaced_ok))

# A text file opened in Notepad with a double click.
notepad_opened = False
press('alt-left')
if wait_for_files_log(['folder /tmp/fm 4'], 15):
    double_click_at(*places()['item-gamma.txt'])
    notepad_opened = wait_for_files_log(['opened-with-notepad /tmp/fm/gamma.txt', 'title gamma.txt - Notepad'], 30)
checks.append(('files: a text file opened in Notepad with a double click', notepad_opened))
type_on_serial(b'kill $(pgrep notepad)\r')
time.sleep(1)

# Tabs: Ctrl+T opens a new one (at Home), Ctrl+Tab goes back to the
# first, Ctrl+W closes the second.
press('ctrl-t')
tabs_ok = wait_for_files_log(['tab new 2', 'folder Home'], 15)
press('ctrl-tab')
tabs_ok = tabs_ok and wait_for_files_log(['tab switch 0', 'folder /tmp/fm 4'], 15)
press('ctrl-tab')
wait_for_files_log(['tab switch 1'], 15)
press('ctrl-w')
tabs_ok = tabs_ok and wait_for_files_log(['tab close 1', 'folder /tmp/fm 4'], 15)
checks.append(('files: a new tab (Ctrl+T), switching tabs (Ctrl+Tab) and closing one (Ctrl+W)', tabs_ok))

# Compressed folders: the tree compressed to ZIP from its context menu,
# browsed like a folder, and extracted again with "Extract all" (the
# extracted copy the same as the original).
zipped_ok = extracted_ok = False
place = places()
if 'item-tree' in place:
    click_at(*place['item-tree'])
    right_click_at(*place['item-tree'])
    if wait_for_files_log(['context-menu items', 'place context-compress-to-zip-file'], 15):
        click_at(*places()['context-compress-to-zip-file'])
        zipped_ok = wait_for_files_log(['compressed 1', 'place item-tree.zip'], 60)
if zipped_ok:
    double_click_at(*places()['item-tree.zip'])
    zipped_ok = wait_for_files_log(['folder /tmp/fm/tree.zip 1', 'place item-tree'], 20)
# Searching inside the archive (Ctrl+E there searches its entries, at
# any depth), and the entry found opened from the results (taken out of
# the archive into Notepad); Back returns to the archive.
archive_search_ok = False
if zipped_ok:
    press('ctrl-e')
    type_on_keyboard('deep')
    press('ret')
    archive_search_ok = wait_for_files_log(['search /tmp/fm/tree.zip deep', 'search-result 1', 'search-done 1',
                                            'place item-deep.txt'], 30)
    if archive_search_ok:
        double_click_at(*places()['item-deep.txt'])
        archive_search_ok = wait_for_files_log(['title deep.txt - Notepad'], 30)
        shell_output('kill $(pgrep notepad); while pgrep notepad > /dev/null; do sleep 0.2; done',
                     'ARCHIVE-NOTEPAD-ENDED')
    press('alt-left')
    zipped_ok = wait_for_files_log(['folder /tmp/fm/tree.zip 1'], 15)
checks.append(('files: searching inside a compressed folder (Ctrl+E) finds an entry deep in it, which opens',
               archive_search_ok))
if zipped_ok:
    # Up again, the archive selected (Up selects the folder it came
    # from, which shows Extract all at once; a click on it then changes
    # nothing, so its place may already have come with the folder).
    up_from = len(files_log_text)
    press('alt-up')
    wait_for_files_log(['folder /tmp/fm '], 15)
    click_at(*places()['item-tree.zip'])
    if wait_for_files_log(['place command-extract'], 15, since=up_from):
        click_at(*places()['command-extract'])
        if wait_for_files_log(['extract-dialog /tmp/fm/tree', 'place extract-go'], 15):
            click_at(*places()['extract-go'])
            extracted_ok = wait_for_files_log(['extracted 1'], 60)
# (Extracted into a folder named after the archive: the tree itself.)
output = shell_output('sha256sum /tmp/fm/tree/big.bin /tmp/fm/tree/tree/big.bin; cat /tmp/fm/tree/tree/a/b/deep.txt',
                      'FILES-ZIP', 30)
digests = re.findall(rb'([0-9a-f]{64})  /', output)
checks.append(('files: a folder compressed to ZIP (context menu) and browsed like a folder', zipped_ok))
checks.append(('files: Extract all brings the same files back', extracted_ok and len(digests) == 2 and
               digests[0] == digests[1] and b'\ndeep' in output))
type_on_serial(b'rm -rf /tmp/fm/tree.zip /tmp/fm/tree/tree\r')
time.sleep(1)
press('alt-left')
wait_for_files_log(['folder /tmp/fm '], 15)

# Search: Ctrl+E, a word, Enter: the file deep in the tree is found
# (results come in as they are found), Escape goes back.
press('ctrl-e')
type_on_keyboard('deep')
press('ret')
search_ok = wait_for_files_log(['search /tmp/fm deep', 'search-result 1', 'search-done 1', 'place item-deep.txt'], 30)
press('alt-left')
wait_for_files_log(['folder /tmp/fm '], 15)
checks.append(('files: searching the folder (Ctrl+E) finds a file deep inside it', search_ok))

# The preview pane (Alt+P) shows a picture.
type_on_serial(b'cp /usr/share/icons/app-paint.ico /tmp/fm/picture.ico\r')
preview_ok = False
if wait_for_files_log(['refreshed', 'place item-picture.ico'], 20):
    click_at(*places()['item-picture.ico'])
    press('alt-p')
    preview_ok = wait_for_files_log(['pane preview', 'preview image /tmp/fm/picture.ico'], 20)
    press('alt-p')
    wait_for_files_log(['pane none'], 10)
checks.append(('files: the preview pane (Alt+P) shows a picture', preview_ok))
type_on_serial(b'rm /tmp/fm/picture.ico\r')
time.sleep(1)
# The system clipboard and drag and drop between two programs: a second
# Files window (on /tmp/fm2, its own process) dragged by its title bar
# onto the second display; a path typed into the first window's address
# box and copied (Ctrl+C) is on the display server's clipboard (the
# clipboard tool prints it) and pasted (Ctrl+V) into the second window's
# address box, which then goes there; a file dragged from the first
# window into the second is moved there (the display server follows the
# drag from one program's window to the other's).
def second_files_places(marker):
    start = len(received)
    type_on_serial(b'm=DONE; cat /tmp/f2.log; echo ' + marker.encode() + b' $m\r')
    wait_for(marker + ' DONE', 15)
    output = bytes(received[start:])
    return output, {match.group(1).decode(): (int(match.group(2)), int(match.group(3)))
                    for match in re.finditer(rb'place (\S+) (\d+) (\d+)', output)}


def first_files_places(marker):
    # The first window's places from its own log (the second's are in
    # what the serial line received too).
    log = files_log(marker)
    return {match.group(1).decode(): (int(match.group(2)), int(match.group(3)))
            for match in re.finditer(rb'place (\S+) (\d+) (\d+)', log)}


type_on_serial(b'kill $(pgrep notepad); mkdir -p /tmp/fm2; files /tmp/fm2 > /tmp/f2.log &\r')
second_output, second_place = b'', {}
for attempt in range(30):
    second_output, second_place = second_files_places('FILES2-' + str(attempt))
    if b'folder /tmp/fm2 0' in second_output and 'tab-new' in second_place and 'address' in second_place:
        break
    time.sleep(1)
second_moved = False
if 'tab-new' in second_place:
    title_x, title_y = second_place['tab-new'][0] + 300, second_place['tab-new'][1] - 32
    before = second_place.get('folder-empty-space')
    drag(title_x, title_y, title_x + 1280, title_y)
    time.sleep(1.5)
    second_output, second_place = second_files_places('FILES2-MOVED')
    second_moved = second_place.get('folder-empty-space', before) != before
checks.append(('files: a second window (another process) dragged onto the second display', second_moved))
pasted_across = clipboard_shows = False
place = first_files_places('FILES1-PLACES-A')
if second_moved and 'address' in place:
    click_at(*place['address'])
    press('ctrl-a')
    type_on_keyboard('/tmp/fm/sub')
    press('ctrl-a')
    press('ctrl-c')
    time.sleep(0.5)
    output = shell_output('clipboard -p; echo', 'CLIP-SHOWN')
    clipboard_shows = b'\n/tmp/fm/sub' in output
    press('esc')
    click_at(*second_place['address'])
    press('ctrl-a')
    press('ctrl-v')
    press('ret')
    for attempt in range(15):
        second_output, second_place = second_files_places('FILES2-PASTED-' + str(attempt))
        if b'folder /tmp/fm/sub 1' in second_output:
            pasted_across = True
            break
        time.sleep(1)
checks.append(('clipboard: typed and copied (Ctrl+C) in one window, on the system clipboard (clipboard -p)',
               clipboard_shows))
checks.append(('clipboard: pasted (Ctrl+V) into another program\'s window', pasted_across))
dragged_across = False
if pasted_across:
    # The second window back on its own folder, then gamma.txt dragged
    # into it from the first.
    click_at(*second_place['address'])
    press('ctrl-a')
    type_on_keyboard('/tmp/fm2')
    press('ret')
    time.sleep(1.5)
    second_output, second_place = second_files_places('FILES2-BACK')
    place = first_files_places('FILES1-PLACES-B')
    if 'item-gamma.txt' in place and 'folder-empty-space' in second_place:
        drag(place['item-gamma.txt'][0], place['item-gamma.txt'][1], *second_place['folder-empty-space'])
        for attempt in range(20):
            second_output, second_place = second_files_places('FILES2-DROPPED-' + str(attempt))
            if b'dropped move 1 /tmp/fm2' in second_output and b'moved 1' in second_output:
                break
            time.sleep(1)
output = shell_output('test -f /tmp/fm2/gamma.txt && test ! -e /tmp/fm/gamma.txt && echo DRAGGED-OK', 'FILES2-CHECK')
dragged_across = b'dropped move 1 /tmp/fm2' in second_output and b'\nDRAGGED-OK' in output
checks.append(('drag and drop: a file dragged from one Files window into another program\'s window is moved',
               dragged_across))
type_on_serial(b'kill %3; wait %3; mv /tmp/fm2/gamma.txt /tmp/fm/ 2>/dev/null; rm -r /tmp/fm2\r')
time.sleep(2)

type_on_serial(b'kill $(pgrep notepad); kill %2; wait %2; settings delete Files; rm -r /volumes/disk3p1/tree '
               b'/volumes/disk3p1/gamma.txt; kill %1; wait; m=DONE; echo FILES-ENDED $m\r')
files_ended = wait_for('FILES-ENDED DONE', 30)
checks.append(('files: asked to end, it closes (exit)', files_ended and b'\nexit' in files_log('FILES-LAST')))

# The terminal window (terminal: the shell on a pseudo-terminal, drawn
# in Terminus at 11 points: 10x18 cells at 100 DPI). Keys typed on the PS/2 keyboard
# go to the active window, so a command typed there writes a file the
# serial shell reads; the window shows text (in the terminal's text
# colour); text selected with the mouse is copied (Ctrl+Shift+C) and
# pasted (Ctrl+Shift+V) into the next command; dragging the window's
# corner 160x96 pixels further gives the shell the rows and columns that
# fit (stty size); exit closes the window. A second terminal closed
# with Alt+F4 hangs its shell up (status 129).
type_on_serial(b'displayserver &\r')
wait_for('displayserver: ready', 20)
terminal_from = len(received)
type_on_serial(b'terminal > /tmp/t.log &\r')
time.sleep(3)
type_on_serial(b'm=DONE; cat /tmp/t.log; echo TERMINAL $m\r')
terminal_started = wait_for('TERMINAL DONE', 10)
place = re.search(rb'terminal: /dev/pts(\d+), 25 rows, 80 columns, window at (\d+),(\d+), (\d+)x(\d+) pixels, '
                  rb'cells (\d+)x(\d+)', bytes(received[terminal_from:]))
checks.append(('terminal: started on a pseudo-terminal, 25 rows of 80 columns', terminal_started and place is not None))
left, top, width, height, cell_width, cell_height = \
    (int(place.group(n)) for n in range(2, 8)) if place else (100, 80, 820, 454, 10, 18)
type_on_keyboard('echo terminal-ok > /tmp/term.txt')
press('ret')
type_on_keyboard('echo copied-text')
press('ret')
time.sleep(1.5)
pixel = take_screen()
text_pixels = sum(1 for x in range(left, left + width - 20, 2) for y in range(top, top + height, 2)
                  if pixel(x, y) == 'd0d0d0')
background_pixels = sum(1 for x in range(left, left + width - 20, 8) for y in range(top, top + height, 8)
                        if pixel(x, y) == '101010')
checks.append(('terminal: draws its text', text_pixels > 100 and background_pixels > 1000))
# Settings changed while it runs are taken at once (libconfiguration's
# change notification): a background colour set with the settings tool
# from the serial shell repaints the window, and deleting it brings the
# terminal's own back.
type_on_serial(b'settings set Terminal/BackgroundColor "#203040"; m=DONE; echo RECOLOURED $m\r')
wait_for('RECOLOURED DONE', 10)
time.sleep(1.5)
pixel = take_screen()
recoloured_pixels = sum(1 for x in range(left, left + width - 20, 8) for y in range(top, top + height, 8)
                        if pixel(x, y) == '203040')
type_on_serial(b'settings delete Terminal/BackgroundColor; m=DONE; echo UNCOLOURED $m\r')
wait_for('UNCOLOURED DONE', 10)
time.sleep(1.5)
pixel = take_screen()
restored_pixels = sum(1 for x in range(left, left + width - 20, 8) for y in range(top, top + height, 8)
                      if pixel(x, y) == '101010')
checks.append(('terminal: a colour changed with the settings tool shows at once, and goes again',
               recoloured_pixels > 1000 and restored_pixels > 1000))
# Rows 0 and 1 are the two commands, row 2 what the second printed.
row_middle = top + 2 + 2 * cell_height + cell_height // 2
drag(left + 2 + 1, row_middle, left + 2 + 11 * cell_width - 1, row_middle)
press('ctrl-shift-c')
type_on_keyboard('echo ')
press('ctrl-shift-v')
type_on_keyboard(' > /tmp/paste.txt')
press('ret')
time.sleep(1)
typed_from = len(received)
type_on_serial(b'm=DONE; cat /tmp/term.txt /tmp/paste.txt; echo TYPED $m\r')
typed_ok = wait_for('TYPED DONE', 10)
typed_log = bytes(received[typed_from:])
checks.append(('terminal: keys typed in the window reach its shell', typed_ok and b'\nterminal-ok' in typed_log))
checks.append(('terminal: text selected with the mouse, copied and pasted',
               typed_ok and b'\ncopied-text' in typed_log))
drag(left + width + 2, top + height + 2, left + width + 2 + 160, top + height + 2 + 96)
time.sleep(1)
type_on_keyboard('stty size > /tmp/size.txt')
press('ret')
time.sleep(1)
sized_from = len(received)
type_on_serial(b'm=DONE; cat /tmp/size.txt /tmp/t.log; echo SIZED $m\r')
sized_ok = wait_for('SIZED DONE', 10)
sized_log = bytes(received[sized_from:])
# The grid inside a 2 pixel margin, beside a 16 pixel scroll bar.
new_rows, new_columns = (height + 96 - 4) // cell_height, (width + 160 - 4 - 16) // cell_width
checks.append(('terminal: resized by its corner, the shell sees the new size',
               sized_ok and ('\n%d %d' % (new_rows, new_columns)).encode() in sized_log and
               ('terminal: %d rows, %d columns' % (new_rows, new_columns)).encode() in sized_log))
type_on_keyboard('exit')
press('ret')
time.sleep(1.5)
ended_from = len(received)
type_on_serial(b'm=DONE; cat /tmp/t.log; echo ENDED $m\r')
ended_ok = wait_for('ENDED DONE', 10)
checks.append(('terminal: the shell exits, the window closes',
               ended_ok and b'terminal: the shell ended with status 0' in bytes(received[ended_from:]) and
               take_screen()(left + 100, top + 100) != '101010'))
type_on_serial(b'terminal -x 200 -y 120 > /tmp/t2.log &\r')
time.sleep(3)
press('alt-f4')
time.sleep(2)
closed_from = len(received)
type_on_serial(b'm=DONE; cat /tmp/t2.log; settings get Terminal/Rows; settings delete Terminal; kill %1; wait; '
               b'echo CLOSED $m\r')
closed_ok = wait_for('CLOSED DONE', 15)
checks.append(('terminal: closing the window hangs the shell up',
               closed_ok and b'terminal: closed; the shell ended with status 129' in bytes(received[closed_from:])))
# The first window's size when it closed is kept in the user's settings
# (Terminal/Rows, Terminal/Columns): the second starts at it.
checks.append(('terminal: the next window starts at the size the last one closed at',
               closed_ok and re.search(('terminal: /dev/pts\\d+, %d rows, %d columns, window at 200,120' %
                          (new_rows, new_columns)).encode(), bytes(received[closed_from:])) is not None and
               re.search(('\n%d\r?\n' % new_rows).encode(), bytes(received[closed_from:])) is not None))

# The desktop shell (desktop): a wallpaper on both displays (its sky
# starts 0f2c42 at the top), the taskbar along the bottom of the first (30 high: 770-799) with the
# Start button, the clock and the shell's own notification icons (a
# loudspeaker with its blue sound waves, then the network's); a second
# shell is refused. A window
# (wintest First, with a notification icon of its own, the third) gets a taskbar button: a click
# on the wallpaper takes the keyboard from it, a click on its button
# gives it back, another minimizes it (it is hidden, the program told)
# and a third restores it. Maximized, it stops above the taskbar
# (1280x748: the work area less the title bar), and its button's menu
# restores it. A new window low on the screen is moved into the work
# area. A double click on an icon starts controlstour, whose button's
# menu closes it; the Start menu starts dialogtour, and its Shut down
# asks first (Escape says no). The pointer resting on wintest's icon
# shows its tooltip; when wintest ends, its icon and button go.
def colour_near(colour, expected, tolerance):
    if len(colour) != 6:
        return False
    return all(abs(int(colour[i:i + 2], 16) - int(expected[i:i + 2], 16)) <= tolerance for i in (0, 2, 4))


def near_pixels(pixel, x, y, reach):
    return [pixel(px, py) for px in range(x - reach, x + reach + 1) for py in range(y - reach, y + reach + 1)]


def shell_places(marker):
    type_on_serial(b'm=DONE; cat /tmp/s.log; echo ' + marker.encode() + b' $m\r')
    wait_for(marker + ' DONE', 10)
    return places()


def log_since(marker):
    return bytes(received[received.rfind(marker.encode()):])


def wait_for_shell_log(texts, seconds):
    # The shell's log (with what the programs it started print) until it
    # has every text since the last look: a started program may take a
    # while to show its window.
    start = len(received)
    deadline = time.time() + seconds
    attempt = 0
    while time.time() < deadline:
        attempt += 1
        shell_places('LOOK' + str(attempt))
        if all(text.encode() in received[start:] for text in texts):
            return True
        time.sleep(1)
    return False


type_on_serial(b'displayserver &\r')
wait_for('displayserver: ready', 20)
type_on_serial(b'desktop > /tmp/s.log &\r')
time.sleep(8)
first = take_screen()
second = take_screen('video1')
place = shell_places('SHELL')
shell_log = log_since('SHELL $m')
shell_started = all(name in place for name in ('start', 'icon-controlstour', 'clock', 'notification-1'))
checks.append(('desktop: wallpaper on both displays, the taskbar along the bottom of the first',
               shell_started and colour_near(first(640, 4), '0f2c42', 4) and colour_near(second(500, 4), '0f2c42', 4) and
               first(640, 785) == 'cbc6bd' and second(500, 785) != 'cbc6bd'))
clock_shown = re.search(rb'clock (\d\d):(\d\d)', shell_log)
checks.append(('desktop: the clock shows the time',
               shell_started and clock_shown is not None and int(clock_shown.group(1)) < 24 and
               '000000' in near_pixels(first, place['clock'][0], place['clock'][1], 8)))
checks.append(('desktop: the Start button and the shell\'s notification icon',
               shell_started and any(is_blue(colour, 80) for colour in
                                     near_pixels(first, place['notification-1'][0], place['notification-1'][1], 7)) and
               first(place['start'][0], place['start'][1] - 9) == 'cbc6bd'))
type_on_serial(b'desktop 2>&1; echo REFUSED-$?\r')
checks.append(('desktop: a second shell is refused',
               wait_for('another shell is running', 10) and wait_for('REFUSED-1', 10)))
type_on_serial(b'wintest -t First -x 100 -y 100 -n Hello > /tmp/w5.log &\r')
time.sleep(2)
place = shell_places('FIRST')
first_log = log_since('FIRST $m')
first_listed = 'task-First' in place and re.search(rb'task \d+ active First', first_log) is not None
checks.append(('desktop: a window gets a taskbar button, a notification icon its own',
               first_listed and b'notification 3 Hello' in first_log))
type_on_serial(b'm=DONE; echo BUTTONS $m\r')
wait_for('BUTTONS DONE', 10)
if first_listed:
    click_at(640, 400)
    click_at(*place['task-First'])
    click_at(*place['task-First'])
    minimized = take_screen()
    click_at(*place['task-First'])
    restored = take_screen()
type_on_serial(b'm=DONE; cat /tmp/w5.log; echo MINIMIZED $m\r')
wait_for('MINIMIZED DONE', 10)
buttons_log = log_since('BUTTONS DONE')
checks.append(('desktop: a taskbar button activates, minimizes and restores its window',
               first_listed and re.search(rb'active 0\r?\nactive 1\r?\nvisible 0\r?\nactive 0\r?\nvisible 1\r?\n'
                                          rb'active 1', buttons_log) is not None and
               minimized(250, 200) != 'f0e8d0' and restored(250, 200) == 'f0e8d0'))
click_at(373, 90)
time.sleep(0.5)
maximized = take_screen()
type_on_serial(b'm=DONE; cat /tmp/w5.log; echo MAXIMIZED $m\r')
wait_for('MAXIMIZED DONE', 10)
checks.append(('desktop: a maximized window stops above the taskbar',
               b'resized 1280 748' in log_since('BUTTONS DONE') and maximized(640, 765) == 'f0e8d0' and
               maximized(640, 785) == 'cbc6bd'))
place = shell_places('MENU')
if 'task-First' in place:
    right_click_at(*place['task-First'])
    place = shell_places('CONTEXT')
    if 'context-restore' in place:
        click_at(*place['context-restore'])
type_on_serial(b'm=DONE; cat /tmp/w5.log; echo RESTORED $m\r')
wait_for('RESTORED DONE', 10)
checks.append(('desktop: a taskbar button\'s menu restores its window',
               re.search(rb'resized 1280 748\r?\n(moved 100 100\r?\n)?resized 300 200', log_since('MAXIMIZED DONE'))
               is not None))
type_on_serial(b'wintest -t Low -x 600 -y 700 > /tmp/w6.log &\r')
time.sleep(2)
type_on_serial(b'm=DONE; cat /tmp/w6.log; echo LOW $m\r')
checks.append(('desktop: a new window is placed inside the work area',
               wait_for('LOW DONE', 10) and b'moved 600 566' in log_since('w6.log; echo LOW')))
place = shell_places('ICONS')
if 'icon-controlstour' in place:
    double_click_at(*place['icon-controlstour'])
    wait_for_shell_log(['place help', 'place task-Controls-tour'], 30)
place = shell_places('TOUR')
tour_log = log_since('ICONS $m')
checks.append(('desktop: a double click on an icon starts its program',
               b'started controlstour' in tour_log and b'place help' in tour_log and
               re.search(rb'task \d+ active Controls tour', tour_log) is not None))
# Window icons: controlstour names its icon (app-components: red, gold,
# blue and green blocks); the desktop hears it ("task-icon N
# app-components") and draws it on the window's button, and the display
# server at the left of its title bar (its client area at 60,40: the
# icon at 63-78, 20-35). Red is in neither the Classic title bar nor the
# taskbar.
def is_red(colour):
    return len(colour) == 6 and int(colour[0:2], 16) >= 0xa0 and int(colour[2:4], 16) <= 0x80 and \
        int(colour[4:6], 16) <= 0x80


tour_screen = take_screen()
title_icon_red = any(is_red(tour_screen(x, y)) for x in range(63, 79) for y in range(20, 36))
button_icon_red = 'task-icon-Controls-tour' in place and \
    any(is_red(colour) for colour in near_pixels(tour_screen, *place['task-icon-Controls-tour'], 8))
checks.append(('window icons: a program\'s icon in its title bar and on its taskbar button',
               re.search(rb'task-icon \d+ app-components', tour_log) is not None and title_icon_red and
               button_icon_red))
if 'task-Controls-tour' in place:
    right_click_at(*place['task-Controls-tour'])
    place = shell_places('TOURMENU')
    if 'context-close' in place:
        click_at(*place['context-close'])
        wait_for_shell_log(['task-gone'], 20)
place = shell_places('CLOSED')
checks.append(('desktop: a taskbar button\'s menu closes its window',
               b'context close' in log_since('TOUR $m') and
               re.search(rb'task-gone \d+', log_since('TOURMENU $m')) is not None))
# The programs are in a submenu for each category: the Dialogs tour in
# Development's.
if 'start' in place:
    click_at(*place['start'])
    place = shell_places('START')
    if 'start-category-development' in place:
        click_at(*place['start-category-development'])
        place = shell_places('SUBMENU')
    if 'start-dialogtour' in place:
        click_at(*place['start-dialogtour'])
        wait_for_shell_log(['place open-button', 'place task-Dialog-tour'], 30)
place = shell_places('STARTED')
checks.append(('desktop: the Start menu starts a program from its category\'s submenu',
               b'place start-category-development' in log_since('CLOSED $m') and
               b'menu Dialogs tour' in log_since('CLOSED $m') and b'started dialogtour' in log_since('CLOSED $m') and
               b'place open-button' in log_since('CLOSED $m')))
if 'start' in place:
    click_at(*place['start'])
    place = shell_places('SHUTDOWN')
    if 'start-shutdown' in place:
        click_at(*place['start-shutdown'])
        time.sleep(1)
        press('esc')
        time.sleep(1)
place = shell_places('ASKED')
checks.append(('desktop: Shut down asks first, and No leaves everything running',
               b'asking shut down' in log_since('STARTED $m') and b'shut down cancelled' in log_since('STARTED $m')))
if 'notification-3' in place:
    point_tablet_at(*place['notification-3'])
    time.sleep(1.5)
    tooltip = take_screen()
    point_tablet_at(640, 400)
    tooltip_x = place['notification-3'][0]
    tooltip_shown = 'f4efd8' in [tooltip(tooltip_x, y) for y in range(745, 769)]
else:
    tooltip_shown = False
type_on_serial(b'kill %3; m=DONE; echo ENDED $m\r')
time.sleep(1.5)
shell_places('GONE')
checks.append(('desktop: a notification icon\'s tooltip; the icon goes with its program',
               tooltip_shown and b'tooltip Hello' in log_since('ASKED $m') and
               b'notification-gone 3' in log_since('ENDED $m')))
# The task manager (taskmanager), opened with Ctrl+Shift+Escape (a key
# the desktop takes for the whole desktop): two busy programs (burn,
# the second ignoring requests to end) are at the top of its Processes
# list, sorted by CPU; End asks the first, which ends; the second does
# not, and End now (confirmed) ends it outright. The Performance tab's
# processor graph moves on. The Programs tab lists a Notepad with text
# in it: Switch To brings it forward, End Program asks it to end, it
# asks about saving (No) and ends. The taskbar's own menu brings the
# task manager forward; closed, it has kept its tab and size in the
# user's settings.
def task_manager_rows(log):
    # The newest look's first rows: (pid, name, cpu) in order.
    looks = log.split(b'\ncpu ')
    for look in reversed(looks[:-1]):
        rows = re.findall(rb'process (\d+) (\S+) (\d+) \d+', look)
        if rows:
            return [(int(pid), name.decode(), int(cpu)) for pid, name, cpu in rows]
    return []


def wait_for_task_manager(texts, seconds):
    # Like wait_for_shell_log, for what the task manager (started by the
    # desktop, so writing to its log) prints.
    return wait_for_shell_log(texts, seconds)


type_on_serial(b'burn > /tmp/b1.log & burn -i > /tmp/b2.log & notepad > /tmp/n9.log &\r')
time.sleep(3)
type_on_keyboard('unsaved words')
time.sleep(0.5)
type_on_serial(b'm=DONE; cat /tmp/b1.log /tmp/b2.log; echo BURNS $m\r')
wait_for('BURNS DONE', 10)
burns_log = log_since('cat /tmp/b1.log')
ready = re.findall(rb'burn: ready (\d+)', burns_log)
polite_burn, stubborn_burn = (int(ready[0]), int(ready[1])) if len(ready) == 2 else (0, 0)
press('ctrl-shift-esc')
opened = wait_for_task_manager(['hotkey task manager', 'started taskmanager', 'place tab-performance',
                                'place row-' + str(stubborn_burn)], 40)
time.sleep(2)
place = shell_places('TASKS')
tm_log = log_since('BURNS DONE')
top_rows = task_manager_rows(tm_log)
checks.append(('task manager: Ctrl+Shift+Escape opens it on the Processes tab',
               opened and b'tab processes' in tm_log and b'settings size 600 440, tab processes, sort 3 descending'
               in tm_log))
checks.append(('task manager: the busy programs are at the top when sorted by CPU',
               len(top_rows) >= 2 and {top_rows[0][0], top_rows[1][0]} == {polite_burn, stubborn_burn} and
               top_rows[0][2] >= 10 and top_rows[1][2] >= 10))
# End (ask): the polite one ends.
# Sorted by CPU the rows trade places at every refresh (the two burns
# are near equal), so a row's place could change between reading it and
# clicking it; and by PID, every command the serial shell runs (a new,
# highest PID) pushes the rows down. Sorted by name (ascending, equal
# names by PID) the burns come first and stay put: other programs come
# and go after them. Task Manager's lines reach the serial log only when
# /tmp/s.log is shown, so it is shown before the direction is looked at.
if 'name-header' in place:
    click_at(*place['name-header'])
    time.sleep(1.5)
    place = shell_places('BYNAME1')
    sorted_log = log_since('BYNAME1 $m')
    if sorted_log.rfind(b'sort 0 descending') > sorted_log.rfind(b'sort 0 ascending'):
        click_at(*place['name-header'])
        time.sleep(1.5)
    place = shell_places('BYNAME')
if 'row-' + str(polite_burn) in place:
    right_click_at(*place['row-' + str(polite_burn)])
    place = shell_places('MENU1')
    if 'menu-end' in place:
        click_at(*place['menu-end'])
wait_for_task_manager(['ended ' + str(polite_burn)], 20)
asked_log = log_since('MENU1 $m')
checks.append(('task manager: End asks a process to end, and it ends',
               ('asked ' + str(polite_burn)).encode() in asked_log and
               ('ended ' + str(polite_burn)).encode() in asked_log))
# The stubborn one: asked, it stays; End now (Yes) ends it outright.
place = shell_places('STUBBORN')
if 'row-' + str(stubborn_burn) in place:
    right_click_at(*place['row-' + str(stubborn_burn)])
    place = shell_places('MENU2')
    if 'menu-end' in place:
        click_at(*place['menu-end'])
time.sleep(3)
place = shell_places('STILL')
stubborn_log = log_since('MENU2 $m')
stayed = (('asked ' + str(stubborn_burn)).encode() in stubborn_log and
          ('ended ' + str(stubborn_burn)).encode() not in stubborn_log)
if 'row-' + str(stubborn_burn) in place:
    right_click_at(*place['row-' + str(stubborn_burn)])
    place = shell_places('MENU3')
    if 'menu-end-now' in place:
        click_at(*place['menu-end-now'])
        time.sleep(1)
        press('ret')
wait_for_task_manager(['ended ' + str(stubborn_burn)], 20)
ended_log = log_since('MENU3 $m')
checks.append(('task manager: a process that ignores the request stays; End now (confirmed) ends it',
               stayed and ('ended-now ' + str(stubborn_burn)).encode() in ended_log and
               ('ended ' + str(stubborn_burn)).encode() in ended_log))
# The Performance tab: the processor graph moves on from one look to the next.
place = shell_places('PERFORMANCE')
graph = None
if 'tab-performance' in place:
    click_at(*place['tab-performance'])
    wait_for_task_manager(['graph cpu'], 15)
    graph = re.findall(rb'graph cpu (\d+) (\d+) (\d+) (\d+)', log_since('PERFORMANCE $m'))
graph_moved = False
if graph:
    graph_left, graph_top, graph_width, graph_height = (int(value) for value in graph[-1])
    before = take_screen()
    time.sleep(3)
    after = take_screen()
    changed = sum(1 for x in range(graph_left + 4, graph_left + graph_width - 4, 3)
                  for y in range(graph_top + 20, graph_top + graph_height - 4, 3) if before(x, y) != after(x, y))
    graph_moved = changed > 20
checks.append(('task manager: the Performance tab\'s processor graph moves on',
               graph_moved and b'performance cpu' in log_since('PERFORMANCE $m')))
# The Programs tab: Notepad's window; Switch To; End Program, No to saving.
place = shell_places('PROGRAMS')
if 'tab-programs' in place:
    click_at(*place['tab-programs'])
    wait_for_task_manager(['Untitled - Notepad', 'place end-program'], 15)
programs_log = log_since('PROGRAMS $m')
notepad_window = re.search(rb'program (\d+) (\d+) Untitled - Notepad', programs_log)
place = shell_places('NOTEPAD')
if notepad_window and 'program-' + notepad_window.group(1).decode() in place:
    click_at(*place['program-' + notepad_window.group(1).decode()])
    click_at(*place['switch-to'])
    time.sleep(1)
    # Notepad is in front now: the task manager's taskbar button brings
    # it back.
    place = shell_places('SWITCHED')
    if 'task-Task-Manager' in place:
        click_at(*place['task-Task-Manager'])
    place = shell_places('BACK')
    click_at(*place['program-' + notepad_window.group(1).decode()])
    click_at(*place['end-program'])
    time.sleep(2)
    press('alt-n')
    wait_for_task_manager(['ended ' + notepad_window.group(2).decode()], 20)
type_on_serial(b'm=DONE; cat /tmp/n9.log; echo NOTEPAD9 $m\r')
wait_for('NOTEPAD9 DONE', 10)
switched_log = log_since('NOTEPAD $m')
checks.append(('task manager: the Programs tab lists Notepad; Switch To brings it forward',
               notepad_window is not None and re.search(rb'task \d+ active Untitled - Notepad', switched_log)
               is not None))
checks.append(('task manager: End Program asks Notepad to end; it asks about saving (No) and ends',
               notepad_window is not None and b'answer no' in switched_log and
               ('ended ' + notepad_window.group(2).decode()).encode() in switched_log))
# The taskbar's own menu brings the task manager forward (the wallpaper
# took the keyboard from it); Alt+F4 closes it, and the next one would
# start on the tab and at the size it had.
click_at(1000, 400)
right_click_at(900, 785)
place = shell_places('TASKBARMENU')
if 'taskbar-task-manager' in place:
    click_at(*place['taskbar-task-manager'])
    time.sleep(1.5)
    shell_places('CHOSEN')
    press('alt-f4')
    time.sleep(1.5)
type_on_serial(b'pgrep -x taskmanager || echo gone; settings get TaskManager/Tab; settings get TaskManager/Width; '
               b'settings delete TaskManager; m=DONE; echo CLOSED $m\r')
closed = wait_for('CLOSED DONE', 15)
closed_log = log_since('TASKBARMENU $m')
checks.append(('task manager: the taskbar\'s menu brings it forward; closed, it keeps its tab and size',
               closed and b'context task manager' in closed_log and
               re.search(rb'task \d+ active Task Manager', closed_log) is not None and
               re.search(rb'\ngone\r?\n0\r?\n600\r?\n', closed_log) is not None))
type_on_serial(b'pkill -x burn; pkill -x notepad; m=DONE; echo TASKS-ENDED $m\r')
wait_for('TASKS-ENDED DONE', 10)
type_on_serial(b'kill %4 %2; kill %1; wait; m=DONE; echo DESKTOP $m\r')
checks.append(('desktop: the server ended, the console has the screen again',
               wait_for('DESKTOP DONE', 20) and screen_pixel(2, 400) == '101830'))

# A USB disk plugged in while the system runs (a copy of the FAT32 test
# partition): the xHCI driver notices the port, the disk's volume is
# mounted under /volumes and announced to a watch on the list of volumes
# (volumes -w), and it reads. Then it is unplugged while a program has a
# file on it open and a watch on it: the watch hears that its volume is
# gone, the list of volumes that it left, the open file is closed later
# without harm, and the system goes on.
hotplug_image = os.path.abspath(os.path.join(work, 'usb-hotplug.img'))
shutil.copyfile(os.path.join(build_directory, 'test-disk-nvme.img'), hotplug_image)
# The file manager runs meanwhile: its places show the disk as it
# arrives (shown, then opened) and drop it when it is unplugged, and the
# folder shown on it is left for the volumes.
type_on_serial(b'displayserver &\r')
wait_for('displayserver: ready', 20)
type_on_serial(b'files /volumes > /tmp/f2.log &\r')
time.sleep(3)
start = len(received)
type_on_serial(b'volumes -w -n 1 -t 60000; m=DONE; echo ARRIVED $m\r')
waiting = wait_for('waiting for volumes', 20)
send_to_monitor('drive_add 0 if=none,id=usbdisk1,format=raw,file=' + hotplug_image + '\n')
send_to_monitor('device_add usb-storage,bus=xhci.0,drive=usbdisk1,id=usbdisk1\n')
arrived = wait_for('ARRIVED DONE', 60)
arrival = re.search(rb'arrived: (disk\d+p1) fat32 "FAT32TEST" \S+ at /volumes/(disk\d+p1)', bytes(received[start:]))
hotplug_volume = arrival.group(1).decode() if arrival else 'none'
checks.append(('a USB disk plugged in: announced on the list of volumes and mounted',
               waiting and arrived and arrival is not None))
start = len(received)
type_on_serial(('cat /volumes/' + hotplug_volume + '/fstype.txt; volumes | grep ' + hotplug_volume +
                ' | grep -c removable; m=DONE; echo READ $m\r').encode())
read_ok = wait_for('READ DONE', 30)
checks.append(('a USB disk plugged in: its files read, the volume removable',
               read_ok and re.search(rb'\nfat32\r?\n1\r?\n', bytes(received[start:])) is not None))


def hotplug_files_log(marker):
    type_on_serial(b'm=DONE; cat /tmp/f2.log; echo ' + marker.encode() + b' $m\r')
    wait_for(marker + ' DONE', 15)
    return bytes(received[received.rfind(marker.encode() + b' $m'):])


files_log_now = hotplug_files_log('HOTPLUG-FILES')
volume_place = 'tree-volume-' + hotplug_volume
place = places()
volume_shown = ('volume-added ' + hotplug_volume).encode() in files_log_now and volume_place in place
if volume_shown:
    click_at(*place[volume_place])
    volume_shown = ('folder /volumes/' + hotplug_volume).encode() in hotplug_files_log('HOTPLUG-OPENED')
checks.append(('files: a USB disk plugged in shows among the places, and opens', volume_shown))
start = len(received)
type_on_serial(('sleep 4 < /volumes/' + hotplug_volume + '/fstype.txt & watch -n 2 -t 60000 /volumes/' +
                hotplug_volume + ' /volumes; m=DONE; echo UNPLUGGED $m\r').encode())
time.sleep(2)
send_to_monitor('device_del usbdisk1\n')
unplugged = wait_for('UNPLUGGED DONE', 60)
after_unplug = bytes(received[start:])
files_log_now = hotplug_files_log('HOTPLUG-GONE')
checks.append(('files: an unplugged disk leaves the places; the folder shown on it is left',
               ('volume-removed ' + hotplug_volume).encode() in files_log_now and
               ('folder-gone /volumes/' + hotplug_volume).encode() in files_log_now and
               b'folder /volumes ' in files_log_now[files_log_now.find(b'folder-gone'):]))
type_on_serial(b'kill %2; wait %2; kill %1; wait %1; m=DONE; echo HOTPLUG-FILES-ENDED $m\r')
wait_for('HOTPLUG-FILES-ENDED DONE', 20)
checks.append(('a USB disk unplugged: its watch hears the volume is gone, the list that it left',
               unplugged and ('/volumes/' + hotplug_volume + ': volume gone').encode() in after_unplug and
               ('/volumes: removed: ' + hotplug_volume + ' (directory)').encode() in after_unplug))
time.sleep(3)
start = len(received)
type_on_serial(('wait; cat /volumes/' + hotplug_volume + '/fstype.txt; m=DONE; echo STILL $m\r').encode())
still = wait_for('STILL DONE', 30)
checks.append(('a USB disk unplugged: its volume is gone, its open file closed, the system goes on',
               still and b'No such file or directory' in bytes(received[start:]) and
               b'gone (its disk was removed)' in after_unplug + bytes(received[start:])))

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
# Each network card is set up again and announces its link once it is
# up (the kernel logs it on the serial port).
links_ok = all(wait_for('(' + card + '): link up after waking', 30)
               for card in ('Intel 82574L', 'Intel 82540EM', 'Realtek RTL8139'))
checks.append(('suspend to RAM: the e1000e, e1000 and RTL8139 links are up after waking', links_ok))
type_on_serial(b'events -n 2; m=DONE; echo WOKEN-EVENTS $m\r')
time.sleep(1.5)
move_ps2_mouse('mouse_move -3 5\n')
place_tablet(8192, 16384)
checks.append(('suspend to RAM: the PS/2 mouse and USB tablet work after waking',
               wait_for('WOKEN-EVENTS DONE', 20) and b'motion -3 5' in received and
               b'position 16384 32768' in received))

# The battery backed clock's alarm wakes the machine by itself (no
# system_wakeup), and the kernel says so; the processors' memory type
# ranges are set again as they wake.
type_on_serial(b'suspend -t 6; echo ALARM-WOKE $?\r')
alarm_asleep = wait_for('suspending to RAM', 30)
checks.append(('suspend to RAM: the alarm wakes the machine (suspend -t)',
               alarm_asleep and wait_for('ALARM-WOKE 0', 90) and b'woken by the alarm' in received))

# Plugging a processor in (the free slot) raises a GPE; its method
# (\_GPE._E02) tells the processor's device to check itself (the Notify,
# which the kernel logs), then its _STA and _MAT, and it is brought up.
send_to_monitor('device_add ' + cpu_model + ',id=hotcpu,socket-id=0,core-id=' + processors + ',thread-id=0\n')
checks.append(('a processor plugged in: GPE, its AML method and the Notify',
               wait_for('\\_SB_.CPUS.C00' + processors + ' 0x01', 20)))
checks.append(('a processor plugged in is brought up', wait_for('plugged in and running', 60)))

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

# Every program checks its heap (the kernel option heapchecks); a failed
# check is reported on the console.
heap_reports = re.findall(rb'heap check in [^\r\n]*', bytes(received))
checks.append(('no heap check failed' + ''.join('\n    ' + report.decode(errors='replace')
                                                 for report in heap_reports),
               not heap_reports))

# A program that dies of an exception prints it on the console. One
# check makes one do that on purpose: about:crash crashes the renderer
# of the browser's local pages (its report, in the browser's log, comes
# right after "go about:crash" and starts in webcontent); that one is
# left out, and nothing else.
def is_deliberate_crash(match):
    before = bytes(received[max(0, match.start() - 200):match.start()])
    first_frame = bytes(received[match.end():match.end() + 100])
    return before.rstrip().endswith(b'go about:crash') and \
        re.match(rb'\r?\n\s*\$[0-9A-F]+\s+webcontent\+\$', first_frame) is not None


crash_matches = list(re.finditer(rb'An unhandled exception occurred[^\r\n]*\r?\n[^\r\n]*', bytes(received)))
deliberate = [match for match in crash_matches if is_deliberate_crash(match)][:1]
crash_reports = [match.group(0) for match in crash_matches if match not in deliberate]
checks.append(('no program died of an unhandled exception' +
               ''.join('\n    ' + report.decode(errors='replace').replace('\r', '').replace('\n', ' ')
                       for report in crash_reports),
               not crash_reports))

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
