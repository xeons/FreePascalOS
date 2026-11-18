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

"""Native (device tree) boot test of the AArch64 build in QEMU.

    test-arm64-native.py <fpos.img> <system-disk-image>

QEMU's virt machine loads build/arm64/native/fpos.img as it would load
Linux (-kernel, Linux arm64 Image header), with the system image as the
initial RAM disk (-initrd) and the kernel options as -append; no UEFI
firmware, no ACPI: everything comes from the device tree QEMU makes.

    1. EL1 (the boot stub and kernel entered at EL1, PSCI by HVC), four
       Cortex-A76 processors, a virtio network card and a ramfb screen;
       "test-exit init=/bin/true": the kernel ends QEMU once /bin/true
       ran from the RAM disk.
    2. The same at EL2 (virtualization=on, as the Raspberry Pi's firmware
       enters: PSCI by SMC).
    3. The network over the virtio card: netlog=10.0.2.2:PORT (QEMU's
       user networking hands that to this machine's loopback, where this
       script listens) with the kernel's own DHCP, and the kernel debug
       shell on TCP (netshell=2323, forwarded from a local port), which
       must answer "help": the inbound TCP path an SSH session uses too.

Each boot must show the stub's messages, the device tree's platform
devices, the GIC, timer and PSCI, every processor, the PCI devices with
the BARs the kernel assigned, the framebuffer, and the system volume on
the RAM disk. A compressed system image (.xz or .gz, as make serves it)
must be unpacked by the kernel, which logs the sizes and the time. Serial logs stay next to the image
(test-arm64-native-el1.log, -el2.log, -network.log). Not part of make
test; make arm64-native-test runs it.
"""

import os
import socket
import subprocess
import sys
import time

TIMEOUT = int(os.environ.get('TIMEOUT', '300'))


def qemu_command(image, system_image, options, log, el2=False, extra=()):
    machine = 'virt,gic-version=2' + (',virtualization=on' if el2 else '')
    return ['qemu-system-aarch64', '-machine', machine, '-cpu', 'cortex-a76', '-smp', '4', '-m', '2G',
            '-display', 'none', '-monitor', 'none', '-serial', 'file:' + log, '-no-reboot',
            '-semihosting-config', 'enable=on,target=native',
            '-kernel', image, '-initrd', system_image, '-append', options,
            '-device', 'ramfb', *extra]


def read_log(path):
    try:
        with open(path, 'rb') as log:
            return log.read().decode('utf-8', errors='replace')
    except OSError:
        return ''


def check(name, log_path, expectations, status=None):
    text = read_log(log_path)
    missing = [what for what, needle in expectations if needle not in text]
    if status is not None and status != 1:
        missing.append('QEMU exit status 1 (was %s)' % status)
    if missing:
        print('ARM64 NATIVE (%s): failed (%s), missing:' % (name, log_path))
        for what in missing:
            print('    ' + what)
        return False
    print('ARM64 NATIVE (%s): passed (%s)' % (name, log_path))
    return True


COMPRESSED_IMAGE_KINDS = {'.xz': 'xz', '.gz': 'gzip'}


def unpacking_expectations(system_image):
    """The kernel's unpacking of a compressed RAM disk image."""
    kind = COMPRESSED_IMAGE_KINDS.get(os.path.splitext(system_image)[1])
    if kind is None:
        return []
    return [('the %s RAM disk image unpacked' % kind, '[ramdisk] %s image: compressed ' % kind)]


def boot_expectations(psci_conduit):
    return [
        ('the boot stub', 'FreePascalOS native boot'),
        ('the RAM disk found by the stub', 'RAM disk: '),
        ('the ramfb screen', 'Framebuffer: 1024 x 768, 32 bits'),
        ('the kernel started', 'kernel starting'),
        ('the device tree read', '[dt] Device tree of linux,dummy-virt'),
        ('GIC, timer and PSCI from the tree', 'PSCI 1.1 (%s)' % psci_conduit),
        ('four processors', '[smp] 4 processors running'),
        ('PCI BARs assigned', 'BARs assigned from the device tree'),
        ('the virtio network card', 'eth0: virtio network device'),
        ('the system volume on the RAM disk', 'System volume: /ramdisk0p1'),
        ('user mode ran /bin/true', '/bin/true exited with code 0'),
    ]


def run_to_exit(command):
    try:
        return subprocess.run(command, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                              stderr=subprocess.DEVNULL, timeout=TIMEOUT).returncode
    except subprocess.TimeoutExpired:
        return 'timeout'


def free_port(kind=socket.SOCK_STREAM):
    with socket.socket(socket.AF_INET, kind) as probe:
        probe.bind(('127.0.0.1', 0))
        return probe.getsockname()[1]


def network_case(image, system_image, log):
    """netlog and the TCP debug shell over virtio-net."""
    netlog = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    netlog.bind(('127.0.0.1', 0))
    netlog.settimeout(0.5)
    netlog_port = netlog.getsockname()[1]
    shell_port = free_port()
    options = 'init=/bin/true netlog=10.0.2.2:%d netshell=2323' % netlog_port
    extra = ['-netdev', 'user,id=net0,hostfwd=tcp:127.0.0.1:%d-:2323' % shell_port,
             '-device', 'virtio-net-pci,netdev=net0']
    qemu = subprocess.Popen(qemu_command(image, system_image, options, log, extra=extra),
                            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    lines = []
    shell_answer = b''
    deadline = time.time() + TIMEOUT
    try:
        while time.time() < deadline and qemu.poll() is None:
            try:
                data, _ = netlog.recvfrom(2048)
                lines.append(data.decode('utf-8', errors='replace'))
            except socket.timeout:
                pass
            if any('/bin/true exited' in line for line in lines):
                break
        try:
            with socket.create_connection(('127.0.0.1', shell_port), timeout=10) as shell:
                shell.settimeout(5)
                shell.sendall(b'help\n')
                end = time.time() + 10
                while time.time() < end and b'kshell> ' not in shell_answer[8:]:
                    try:
                        chunk = shell.recv(4096)
                    except socket.timeout:
                        break
                    if not chunk:
                        break
                    shell_answer += chunk
        except OSError:
            pass
    finally:
        qemu.kill()
        qemu.wait()
        netlog.close()
    with open(log + '.netlog', 'w') as received:
        received.write('\n'.join(lines) + '\n')
    text = '\n'.join(lines)
    missing = []
    if 'kernel starting' not in text:
        missing.append('the kernel log over netlog')
    if '/bin/true exited' not in text:
        missing.append('the log up to user mode over netlog')
    if b'kshell> ' not in shell_answer:
        missing.append('an answer from the TCP debug shell')
    if missing:
        print('ARM64 NATIVE (network): failed (%s, %s.netlog), missing:' % (log, log))
        for what in missing:
            print('    ' + what)
        return False
    print('ARM64 NATIVE (network): passed (%d netlog lines, the TCP shell answered)' % len(lines))
    return True


def main():
    image, system_image = sys.argv[1], sys.argv[2]
    directory = os.path.dirname(os.path.dirname(os.path.abspath(image)))
    cases = os.environ.get('CASES', 'el1 el2 network').split()
    passed = True
    network = ['-netdev', 'user,id=net0', '-device', 'virtio-net-pci,netdev=net0']
    if 'el1' in cases:
        log = os.path.join(directory, 'test-arm64-native-el1.log')
        status = run_to_exit(qemu_command(image, system_image, 'test-exit init=/bin/true', log, extra=network))
        passed &= check('EL1', log, boot_expectations('HVC') + unpacking_expectations(system_image), status)
    if 'el2' in cases:
        log = os.path.join(directory, 'test-arm64-native-el2.log')
        status = run_to_exit(qemu_command(image, system_image, 'test-exit init=/bin/true', log, el2=True,
                                          extra=network))
        passed &= check('EL2', log, boot_expectations('SMC') + unpacking_expectations(system_image), status)
    if 'network' in cases:
        passed &= network_case(image, system_image, os.path.join(directory, 'test-arm64-native-network.log'))
    sys.exit(0 if passed else 1)


if __name__ == '__main__':
    main()
