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
Interrupt remapping test: boots the system twice, behind QEMU's Intel
IOMMU (intel-iommu,intremap=on) and behind its AMD IOMMU
(amd-iommu,intremap=on), with the kernel option intremap=on, and checks
in each that the kernel turned remapping on and that interrupts still
arrive through it: the serial console (an I/O APIC edge line) runs the
shell, the e1000's level triggered line gets DHCP and ping answers, the
AHCI disk (by message) is the system disk; then the machine sleeps
(suspend -t 5: the alarm wakes it) and the network answers again, the
IOMMU set up again after waking.

    test-interrupt-remapping.py <esp-directory> <system-disk-image>

Exits with 0 when every check passed.
"""
import os
import shutil
import subprocess
import sys
import time

esp_directory, system_disk = sys.argv[1], sys.argv[2]
build_directory = os.path.dirname(esp_directory)

firmware_code = '/usr/share/edk2/x64/OVMF_CODE.4m.fd'
firmware_variables = '/usr/share/edk2/x64/OVMF_VARS.4m.fd'
for candidate in ('/usr/share/OVMF/x64/OVMF_CODE.4m.fd', '/usr/share/OVMF/OVMF_CODE.fd'):
    if not os.path.exists(firmware_code):
        firmware_code = candidate
for candidate in ('/usr/share/OVMF/x64/OVMF_VARS.4m.fd', '/usr/share/OVMF/OVMF_VARS.fd'):
    if not os.path.exists(firmware_variables):
        firmware_variables = candidate


def run_machine(iommu, expected_line):
    work = os.path.join(build_directory, 'remapping-test-' + iommu)
    shutil.rmtree(work, ignore_errors=True)
    os.makedirs(work)
    shutil.copytree(esp_directory, os.path.join(work, 'esp'))
    with open(os.path.join(work, 'esp', 'FreePascalOS', 'options.txt'), 'w') as options:
        options.write('mode=text autologin=root intremap=on\n')
    shutil.copy(system_disk, os.path.join(work, 'system.img'))
    shutil.copy(firmware_variables, os.path.join(work, 'vars.fd'))
    for suffix in ('.in', '.out'):
        os.mkfifo(os.path.join(work, 'serial' + suffix))
    qemu = subprocess.Popen([
        'qemu-system-x86_64', '-machine', 'q35,kernel-irqchip=split', '-cpu', 'max', '-m', '512M', '-smp', '4',
        '-drive', 'if=pflash,format=raw,readonly=on,file=' + firmware_code,
        '-drive', 'if=pflash,format=raw,file=' + os.path.join(work, 'vars.fd'),
        '-drive', 'format=raw,file=fat:rw:' + os.path.join(work, 'esp'),
        '-drive', 'format=raw,file=' + os.path.join(work, 'system.img'),
        '-device', iommu + ',intremap=on',
        '-netdev', 'user,id=net0', '-device', 'e1000,netdev=net0',
        '-serial', 'pipe:' + os.path.join(work, 'serial'),
        '-display', 'none', '-no-reboot'],
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
    received = bytearray()

    def collect(seconds):
        end = time.time() + seconds
        while time.time() < end and qemu.poll() is None:
            try:
                chunk = os.read(serial_out, 4096)
                if chunk:
                    received.extend(chunk)
                    continue
            except BlockingIOError:
                pass
            time.sleep(0.05)

    def wait_for(text, seconds):
        end = time.time() + seconds
        while time.time() < end and qemu.poll() is None:
            collect(0.2)
            if text.encode() in received:
                return True
        return text.encode() in received

    def type_line(text):
        for byte in text.encode() + b'\r':
            serial_in.write(bytes([byte]))
            time.sleep(0.02)

    checks = []
    shell = serial_in is not None and wait_for('fpos:/$ ', 150)
    checks.append(('the shell runs (serial console through the I/O APIC)', shell))
    checks.append(('interrupt remapping is on', expected_line.encode() in received))
    if shell:
        checks.append(('the e1000 gets an address (its level triggered line)', wait_for('eth0: configured', 60)))
        type_line('ping -c 2 10.0.2.2; echo PING-$?')
        checks.append(('ping answers', wait_for('PING-0', 30)))
        type_line('suspend -t 5; echo WOKE-$?')
        checks.append(('the alarm wakes the machine', wait_for('WOKE-0', 90)))
        collect(3)
        type_line('ping -c 2 10.0.2.2; echo AGAIN-$?')
        checks.append(('ping answers after waking', wait_for('AGAIN-0', 40)))
    if qemu.poll() is None:
        qemu.kill()
    qemu.wait()
    with open(os.path.join(work, 'serial.log'), 'wb') as log:
        log.write(received)
    failed = False
    for name, passed in checks:
        print('[remapping] ' + ('pass: ' if passed else 'FAIL: ') + iommu + ': ' + name)
        failed = failed or not passed
    if failed:
        print('[remapping] serial log in ' + os.path.join(work, 'serial.log'))
    return not failed


passed = run_machine('intel-iommu', 'interrupt remapping on (VT-d')
passed = run_machine('amd-iommu', 'interrupt remapping on (AMD-Vi') and passed
if not passed:
    print('INTERRUPT REMAPPING TEST FAILED')
    sys.exit(1)
print('INTERRUPT REMAPPING TEST PASSED')
