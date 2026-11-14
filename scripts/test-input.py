#!/usr/bin/env python3
"""
Input device test: boots the system with /bin/sh as the first program and
types into it, both on the emulated PS/2 keyboard (QEMU monitor "sendkey")
and on the serial port, then checks what the shell printed.

    test-input.py <esp-directory> <system-disk-image>

Exits with 0 when every check passed.
"""
import os
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
    options.write('test-exit\n')
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
serial_log = os.path.join(work, 'serial.log')

# A FIFO pair carries the serial port: QEMU writes serial.out, reads serial.in.
for suffix in ('.in', '.out'):
    os.mkfifo(os.path.join(work, 'serial' + suffix))
qemu = subprocess.Popen([
    'qemu-system-x86_64', '-machine', 'q35', '-cpu', 'max', '-m', '512M', '-smp', '1',
    '-drive', 'if=pflash,format=raw,readonly=on,file=' + firmware_code,
    '-drive', 'if=pflash,format=raw,file=' + os.path.join(work, 'vars.fd'),
    '-drive', 'format=raw,file=fat:rw:' + os.path.join(work, 'esp'),
    '-drive', 'format=raw,file=' + os.path.join(work, 'system.img'),
    '-device', 'isa-debug-exit,iobase=0xf4,iosize=0x04',
    '-serial', 'pipe:' + os.path.join(work, 'serial'),
    '-display', 'none', '-no-reboot',
    '-monitor', 'unix:' + monitor_path + ',server,nowait'],
    stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

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


if not wait_for('fpos:/$ ', 90):
    print('INPUT TEST FAILED: the shell did not start')
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


checks = []

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

# Keyboard: Caps Lock (inverts Shift), arrow keys ignored while editing.
press('caps_lock')
type_on_keyboard('ECHO')
press('caps_lock')
press('left')
type_on_keyboard(' caps | tr a-z A-Z')
press('ret')
checks.append(('keyboard caps lock and arrows', wait_for('\nCAPS', 10)))

# Serial: a long line arrives complete, by interrupt.
serial_in.write(b'echo ' + b's' * 200 + b' | wc -c\n')
checks.append(('serial long line', wait_for('\n201', 10)))

# Serial: an escape sequence in the middle of a line is ignored.
serial_in.write(b'ec\x1b[Dho serial-escape\n')
checks.append(('serial escape sequence', wait_for('\nserial-escape', 10)))

serial_in.write(b'exit 0\n')
try:
    qemu.wait(timeout=30)
except subprocess.TimeoutExpired:
    qemu.kill()
collect(0.5)

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
