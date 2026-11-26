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
Clock source test: boots the system in several timer configurations at
once and checks in each, from the shell, what the kernel says of its
clock (powerstat --clock), that the clocks hold (timetest: monotonic,
sleeps on time, the clock page or the system call) and, where asked,
that idle processors stay quiet (powerstat --check-idle), that a busy
one defers its tick (--check-busy) and that the machine sleeps and the
alarm wakes it (suspend -t 5) with the timers working after waking
(timetest again, its sleeps woken by the HPET broadcast):

  tcg-hpet     the HPET as the clock (clocksource=hpet), every idle
               processor woken by the HPET's comparator (idlebroadcast=
               force), through an I/O APIC input
  tcg-message  the comparator's interrupt as an FSB message (QEMU's
               hpet.msi=on)
  tcg-legacy   legacy replacement (hpetroute=legacy), and the watchdog
               seeing the counter drift (clockdrifttest): the clock
               moves to the HPET
  tcg-none     no HPET and no PIT (hpet=off,pit=off): the counter's
               rate measured against the ACPI PM timer, the boot
               processor's broadcast
  kvm-hpet     under KVM (when /dev/kvm can be used): the HPET clock and
               broadcast through legacy replacement, which is the way
               that works there

    test-clock-sources.py <esp-directory> <system-disk-image>

Exits with 0 when every check passed.
"""
import os
import shutil
import subprocess
import sys
import threading
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

kvm_usable = os.access('/dev/kvm', os.R_OK | os.W_OK)

# name, kernel options, machine, KVM, extra QEMU arguments, lines powerstat
# --clock must show, lines the kernel log must show, whether to suspend.
CONFIGURATIONS = [
    ('tcg-hpet', 'clocksource=hpet idlebroadcast=force', 'q35', False, [],
     ['Clock source: HPET (chosen by the clocksource option), programs make the system call',
      'HPET event timer: comparator', 'Broadcast timer: HPET comparator'],
     ['[hal] Clock: HPET'], True),
    ('tcg-message', 'idlebroadcast=force', 'q35', False, ['-global', 'hpet.msi=on'],
     ['message (FSB delivery)', 'Broadcast timer: HPET comparator'],
     [], True),
    ('tcg-legacy', 'hpetroute=legacy clockdrifttest idlebroadcast=force', 'q35', False, [],
     ['legacy replacement (IRQ 0, input', 'the watchdog moved it from the time stamp counter',
      'legacy replacement capable (in use)'],
     ['the clock is the HPET from now on'], False),
    ('tcg-none', '', 'q35,hpet=off,pit=off', False, [],
     ['HPET: none', 'rate: measured against the ACPI PM timer', 'Broadcast timer: boot processor'],
     ['[hal] No HPET'], False),
]
if kvm_usable:
    CONFIGURATIONS.append(
        ('kvm-hpet', 'clocksource=hpet idlebroadcast=force', 'q35', True, [],
         ['Clock source: HPET', 'legacy replacement (IRQ 0, input', 'Broadcast timer: HPET comparator'],
         [], True))


def run_machine(name, options, machine, kvm, extra, clock_lines, log_lines, suspend, results):
    work = os.path.join(build_directory, 'clock-test-' + name)
    shutil.rmtree(work, ignore_errors=True)
    os.makedirs(work)
    shutil.copytree(esp_directory, os.path.join(work, 'esp'))
    with open(os.path.join(work, 'esp', 'FreePascalOS', 'options.txt'), 'w') as file:
        file.write('mode=text autologin=root ' + options + '\n')
    shutil.copy(system_disk, os.path.join(work, 'system.img'))
    shutil.copy(firmware_variables, os.path.join(work, 'vars.fd'))
    for suffix in ('.in', '.out'):
        os.mkfifo(os.path.join(work, 'serial' + suffix))
    acceleration = ['-accel', 'kvm', '-cpu', 'host'] if kvm else ['-cpu', 'max']
    qemu = subprocess.Popen(
        ['qemu-system-x86_64', '-machine', machine] + acceleration + ['-m', '512M', '-smp', '2',
         '-drive', 'if=pflash,format=raw,readonly=on,file=' + firmware_code,
         '-drive', 'if=pflash,format=raw,file=' + os.path.join(work, 'vars.fd'),
         '-drive', 'format=raw,file=fat:rw:' + os.path.join(work, 'esp'),
         '-drive', 'format=raw,file=' + os.path.join(work, 'system.img')] + extra +
        ['-serial', 'pipe:' + os.path.join(work, 'serial'), '-display', 'none', '-no-reboot'],
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

    def wait_for(text, seconds, after=0):
        end = time.time() + seconds
        while time.time() < end and qemu.poll() is None:
            collect(0.2)
            if text.encode() in received[after:]:
                return True
        return text.encode() in received[after:]

    def type_line(text):
        for byte in text.encode() + b'\r':
            serial_in.write(bytes([byte]))
            time.sleep(0.02)

    def command(text, marker, seconds):
        start = len(received)
        type_line(text + '; echo ' + marker + '-$?')
        return wait_for(marker + '-0', seconds, start)

    checks = []
    shell = serial_in is not None and wait_for('fpos:/$ ', 240)
    checks.append(('the shell runs', shell))
    if shell:
        start = len(received)
        type_line('powerstat --clock; echo CLOCK-$?')
        clock_shown = wait_for('CLOCK-0', 30, start)
        output = bytes(received[start:])
        checks.append(('powerstat --clock answers', clock_shown))
        for line in clock_lines:
            checks.append(('powerstat --clock shows "' + line + '"', line.encode() in output))
        for line in log_lines:
            checks.append(('the kernel log shows "' + line + '"', line.encode() in received))
        checks.append(('timetest passes', command('timetest > time.log', 'TIME', 300)))
        checks.append(('idle processors stay quiet', command('powerstat --check-idle 3 5', 'IDLE', 60)))
        checks.append(('a busy processor defers its tick', command('powerstat --check-busy 3 20', 'BUSY', 60)))
        if suspend:
            checks.append(('the alarm wakes the machine', command('suspend -t 5', 'WOKE', 120)))
            collect(3)
            checks.append(('timetest passes after waking', command('timetest > again.log', 'AGAIN', 300)))
            checks.append(('powerstat --clock answers after waking', command('powerstat --clock', 'CLOCKAGAIN', 30)))
        if not all(passed for _, passed in checks):
            type_line('grep FAIL time.log again.log')
            collect(3)
    if qemu.poll() is None:
        qemu.kill()
    qemu.wait()
    with open(os.path.join(work, 'serial.log'), 'wb') as log:
        log.write(received)
    results[name] = (checks, os.path.join(work, 'serial.log'))


results = {}
threads = []
for configuration in CONFIGURATIONS:
    thread = threading.Thread(target=run_machine, args=configuration + (results,))
    thread.start()
    threads.append(thread)
for thread in threads:
    thread.join()

failed = False
for configuration in CONFIGURATIONS:
    name = configuration[0]
    checks, log = results.get(name, ([('the machine ran', False)], ''))
    machine_failed = False
    for check, passed in checks:
        print('[clock] ' + ('pass: ' if passed else 'FAIL: ') + name + ': ' + check)
        machine_failed = machine_failed or not passed
    if machine_failed:
        print('[clock] serial log in ' + log)
    failed = failed or machine_failed
if not kvm_usable:
    print('[clock] KVM not usable here: kvm-hpet left out')
if failed:
    print('CLOCK SOURCE TEST FAILED')
    sys.exit(1)
print('CLOCK SOURCE TEST PASSED')
