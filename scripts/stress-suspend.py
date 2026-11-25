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
Suspend to RAM stress test: boots the input test's machine (the same
devices, four processors) with root logged in on the serial console, then
suspends and wakes it many times in a row, waiting a different time
before each wake-up (none, a moment, two seconds). A wake that does not
come back is reported with what QEMU says about the processors. With
POINTERS=1, each round then also checks that the PS/2 mouse and the USB
tablet still deliver input events. With LOAD=1, background shell loops
start and end programs all the time, also across each suspend: every
program that ends frees kernel memory, so processors that wake shoot
down translations at once, while the others are still being woken.
A background "timetest --watch" reads the uptime all the time across
every suspend; at the end it must report that no read went back (the
uptime pauses while asleep, and must continue from no earlier than
the last time it gave).

    stress-suspend.py <esp-directory> <system-disk-image> [rounds]

Environment: ACCEL=kvm to use KVM (the default is TCG); WORK_NAME, the
name of its work directory in the build directory (suspend-stress), so
that several can run at once. Exits with 0 when every round woke.
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
rounds = int(sys.argv[3]) if len(sys.argv) > 3 else 30
build_directory = os.path.dirname(esp_directory)
work = os.path.join(build_directory, os.environ.get('WORK_NAME', 'suspend-stress'))
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
check_pointers = os.environ.get('POINTERS') == '1'
serial_log = os.path.join(work, 'serial.log')
for suffix in ('.in', '.out'):
    os.mkfifo(os.path.join(work, 'serial' + suffix))
for name in ('virtio', 'nvme', 'usb'):
    shutil.copyfile(os.path.join(build_directory, 'test-disk-' + name + '.img'),
                    os.path.join(work, name + '.img'))

kvm = os.environ.get('ACCEL') == 'kvm'
qemu = subprocess.Popen([
    'qemu-system-x86_64', '-machine', 'q35',
    *(['-accel', 'kvm', '-cpu', 'host'] if kvm else ['-cpu', 'max']),
    '-m', '512M', '-smp', '4,maxcpus=5',
    '-drive', 'if=pflash,format=raw,readonly=on,file=' + firmware_code,
    '-drive', 'if=pflash,format=raw,file=' + os.path.join(work, 'vars.fd'),
    '-drive', 'format=raw,file=fat:rw:' + os.path.join(work, 'esp'),
    '-drive', 'format=raw,file=' + os.path.join(work, 'system.img'),
    '-device', 'isa-debug-exit,iobase=0xf4,iosize=0x04',
    '-device', 'qemu-xhci,id=xhci,p2=8,p3=8', '-device', 'usb-kbd,bus=xhci.0',
    '-device', 'usb-tablet,bus=xhci.0',
    '-drive', 'if=none,id=virtio0,format=raw,file=' + os.path.join(work, 'virtio.img'),
    '-device', 'virtio-blk-pci,drive=virtio0',
    '-drive', 'if=none,id=nvme0,format=raw,file=' + os.path.join(work, 'nvme.img'),
    '-device', 'nvme,serial=fpostest,drive=nvme0',
    '-drive', 'if=none,id=usbdisk0,format=raw,file=' + os.path.join(work, 'usb.img'),
    '-device', 'usb-storage,bus=xhci.0,drive=usbdisk0',
    '-audiodev', 'none,id=sound0', '-device', 'intel-hda', '-device', 'hda-output,audiodev=sound0',
    '-audiodev', 'none,id=sound1', '-device', 'AC97,audiodev=sound1',
    '-audiodev', 'none,id=sound2', '-device', 'usb-audio,bus=xhci.0,audiodev=sound2',
    '-device', 'bochs-display,id=video1,xres=1024,yres=768',
    '-serial', 'pipe:' + os.path.join(work, 'serial'),
    '-display', 'none', '-no-reboot',
    '-monitor', 'unix:' + monitor_path + ',server,nowait',
    '-qmp', 'unix:' + control_path + ',server,nowait'],
    stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
    stderr=open(os.path.join(work, 'qemu-errors.log'), 'wb'))

serial_out = os.open(os.path.join(work, 'serial.out'), os.O_RDONLY | os.O_NONBLOCK)
serial_in = None
deadline = time.time() + 60
while serial_in is None and time.time() < deadline and qemu.poll() is None:
    try:
        descriptor = os.open(os.path.join(work, 'serial.in'), os.O_WRONLY | os.O_NONBLOCK)
        os.set_blocking(descriptor, True)
        serial_in = os.fdopen(descriptor, 'wb', buffering=0)
    except OSError:
        time.sleep(0.1)
if serial_in is None:
    print('SUSPEND STRESS FAILED: QEMU did not start')
    sys.exit(1)
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
        time.sleep(0.02)


def wait_for(text, seconds, start=0):
    deadline = time.time() + seconds
    while time.time() < deadline:
        collect(0.1)
        if received.find(text.encode(), start) >= 0:
            return True
    return False


def type_on_serial(data):
    for byte in data:
        serial_in.write(bytes([byte]))
        time.sleep(0.02)


def save_log():
    with open(serial_log, 'wb') as log:
        log.write(received)


def finish(code):
    save_log()
    qemu.kill()
    sys.exit(code)


if not wait_for('fpos:/$ ', 180):
    print('SUSPEND STRESS FAILED: the shell did not start (serial log in ' + serial_log + ')')
    finish(1)

monitor = socket.socket(socket.AF_UNIX)
monitor.connect(monitor_path)


def ask_monitor(command):
    try:
        monitor.settimeout(0.2)
        while monitor.recv(65536):
            pass
    except OSError:
        pass
    monitor.sendall((command + '\n').encode())
    answer = b''
    monitor.settimeout(1)
    try:
        while True:
            chunk = monitor.recv(65536)
            if not chunk:
                break
            answer += chunk
    except OSError:
        pass
    return answer.decode(errors='replace')


mice = {}
for match in re.finditer(r'Mouse #(\d+): ([^\r\n(]*)', ask_monitor('info mice')):
    mice[match.group(2).strip()] = match.group(1)
control = socket.socket(socket.AF_UNIX)
control.connect(control_path)
control.settimeout(1)
control.recv(65536)
control.sendall(b'{"execute": "qmp_capabilities"}\n')
control.recv(65536)


def pointers_work(round_number):
    """A PS/2 mouse motion and a USB tablet position reach a program
    reading /dev/events."""
    start = len(received)
    # A new position each round: the same one again is no motion, and
    # the driver reports none.
    tablet_x = 4096 + 1024 * (round_number % 8)
    type_on_serial(('events -n 2; echo POINTED%d" done"\r' % round_number).encode())
    time.sleep(1.5)
    ask_monitor('mouse_set ' + mice.get('QEMU PS/2 Mouse', '0'))
    ask_monitor('mouse_move -3 5')
    ask_monitor('mouse_set ' + mice.get('QEMU HID Tablet', '0'))
    control.sendall(json.dumps({'execute': 'input-send-event', 'arguments': {'events': [
        {'type': 'abs', 'data': {'axis': 'x', 'value': tablet_x}},
        {'type': 'abs', 'data': {'axis': 'y', 'value': 16384}}]}}).encode() + b'\n')
    try:
        control.recv(65536)
    except OSError:
        pass
    finished = wait_for('POINTED%d done' % round_number, 20, start)
    shown = bytes(received[start:])
    expected_position = 'position %d 32768' % (tablet_x * 2)
    return finished and b'motion -3 5' in shown and expected_position.encode() in shown


if os.environ.get('LOAD') == '1':
    for loop in range(3):
        type_on_serial(b'sh -c "while true; do /bin/true; done" &\r')
        collect(0.5)

type_on_serial(b'rm -f /tmp/watch-stop; timetest --watch /tmp/watch-stop &\r')
collect(0.5)

delays = [0, 0.1, 2]
pointer_failures = 0
woken = 0
for round_number in range(rounds):
    delay = delays[round_number % len(delays)]
    start = len(received)
    marker = 'WOKE%d' % round_number
    # The marker is built by the shell, so the echoed command line does
    # not already hold it.
    type_on_serial(('suspend; echo WOKE%d" $?"\r' % round_number).encode())
    if not wait_for('suspending to RAM', 30, start):
        print('round %d: did not start suspending' % round_number)
        finish(1)
    time.sleep(delay)
    # system_wakeup does nothing until the machine is asleep: wait for it.
    asleep = False
    wait_until = time.time() + 30
    while time.time() < wait_until:
        if 'suspended' in ask_monitor('info status'):
            asleep = True
            break
        collect(0.05)
    if not asleep:
        print('round %d: the machine did not go to sleep' % round_number)
        finish(1)
    ask_monitor('system_wakeup')
    if wait_for(marker + ' 0', 60, start):
        woken += 1
        if check_pointers and not pointers_work(round_number):
            pointer_failures += 1
            print('round %d (wake after %.1f s): woke, but the mouse or tablet did not work' %
                  (round_number, delay), flush=True)
            continue
        print('round %d (wake after %.1f s): woke' % (round_number, delay), flush=True)
        continue
    print('round %d (wake after %.1f s): DID NOT WAKE' % (round_number, delay))
    for command in ('info status', 'info cpus', 'info registers -a'):
        print('--- ' + command)
        print(ask_monitor(command))
    # Each processor's stack, to find where it waits (the return
    # addresses on it).
    for processor in range(4):
        ask_monitor('cpu %d' % processor)
        print('--- processor %d: local APIC, then its stack' % processor)
        print(ask_monitor('info lapic'))
        print(ask_monitor('x/96gx $rsp'))
    print('serial log in ' + serial_log)
    print('SUSPEND STRESS FAILED: %d of %d rounds woke' % (woken, round_number + 1))
    finish(1)

start = len(received)
type_on_serial(b'touch /tmp/watch-stop\r')
watch_report = re.compile(rb'timetest: watch: (\d+) uptime reads, (\d+) went back')
match = None
deadline = time.time() + 30
while match is None and time.time() < deadline:
    collect(0.2)
    match = watch_report.search(bytes(received), start)
if match is None:
    print('SUSPEND STRESS FAILED: the uptime watch did not report')
    finish(1)
if int(match.group(2)) != 0:
    print('SUSPEND STRESS FAILED: the uptime went back %s times in %s reads across the suspends' %
          (match.group(2).decode(), match.group(1).decode()))
    finish(1)
print('uptime: %s reads across the suspends, none went back' % match.group(1).decode())

if pointer_failures > 0:
    print('SUSPEND STRESS FAILED: the mouse or tablet failed after %d of %d wakes' % (pointer_failures, rounds))
    finish(1)
print('SUSPEND STRESS PASSED: %d of %d rounds woke' % (woken, rounds))
finish(0)
