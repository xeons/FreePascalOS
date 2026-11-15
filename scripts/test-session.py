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
Session test: boots the system the way it normally boots - the service
manager in the graphical mode - with the kernel option autologin=user,
and checks, without typing anything, that the display server and the
session come up and the desktop shell runs as the user (the taskbar and
the wallpaper in a screen dump, its lines in /var/log/session.log, read
from a root shell on the serial console). On the serial console it logs
in with a wrong password, then the right one, and asks `service list`.
Then from the screen: Log off on the Start menu ends the session and
brings the login window back; a wrong password there is refused, the
right one starts the desktop again; and Shut down on the Start menu
stops the services in order (the session before the display server) and
powers the machine off: QEMU exits by itself.

    test-session.py <esp-directory> <system-disk-image>

Exits with 0 when every check passed.
"""
import os
import re
import shutil
import socket
import subprocess
import sys
import time

esp_directory, system_disk = sys.argv[1], sys.argv[2]
build_directory = os.path.dirname(esp_directory)
work = os.path.join(build_directory, 'session-test')
shutil.rmtree(work, ignore_errors=True)
os.makedirs(work)
shutil.copytree(esp_directory, os.path.join(work, 'esp'))
with open(os.path.join(work, 'esp', 'FreePascalOS', 'options.txt'), 'w') as options:
    options.write('autologin=user\n')
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
serial_log = os.path.join(work, 'serial.log')
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
    '-device', 'qemu-xhci,id=xhci', '-device', 'usb-tablet,bus=xhci.0',
    '-serial', 'pipe:' + os.path.join(work, 'serial'),
    '-display', 'none', '-no-reboot',
    '-monitor', 'unix:' + monitor_path + ',server,nowait',
    '-qmp', 'unix:' + control_path + ',server,nowait'],
    stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
    stderr=open(os.path.join(work, 'qemu-errors.log'), 'wb'))

serial_out = os.open(os.path.join(work, 'serial.out'), os.O_RDONLY | os.O_NONBLOCK)


def open_serial_input():
    deadline = time.time() + 60
    while time.time() < deadline and qemu.poll() is None:
        try:
            descriptor = os.open(os.path.join(work, 'serial.in'), os.O_WRONLY | os.O_NONBLOCK)
            os.set_blocking(descriptor, True)
            return os.fdopen(descriptor, 'wb', buffering=0)
        except OSError:
            time.sleep(0.1)
    print('SESSION TEST FAILED: QEMU did not start (errors in ' + os.path.join(work, 'qemu-errors.log') + ')')
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


def wait_for(text, seconds, start=0):
    deadline = time.time() + seconds
    while time.time() < deadline:
        collect(0.2)
        if text.encode() in received[start:]:
            return True
    return False


def type_on_serial(data):
    for byte in data:
        serial_in.write(bytes([byte]))
        time.sleep(0.02)


monitor = None
for attempt in range(50):
    try:
        monitor = socket.socket(socket.AF_UNIX)
        monitor.connect(monitor_path)
        break
    except OSError:
        time.sleep(0.1)
control = None
for attempt in range(50):
    try:
        control = socket.socket(socket.AF_UNIX)
        control.connect(control_path)
        break
    except OSError:
        time.sleep(0.1)
control.settimeout(2)
control.recv(65536)
control.sendall(b'{"execute": "qmp_capabilities"}\n')
control.recv(65536)


def send_to_monitor(command):
    # QEMU may be gone already (powered off): the checks then fail.
    try:
        monitor.sendall(command.encode())
    except OSError:
        pass
    time.sleep(0.1)


def ask_monitor(command):
    # What earlier commands answered is read away first.
    answer = b''
    try:
        monitor.settimeout(0.2)
        while monitor.recv(65536):
            pass
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


# Buttons go to the mouse chosen by its number: the USB tablet.
for match in re.finditer(r'Mouse #(\d+): ([^\r\n(]*)', ask_monitor('info mice\n')):
    if match.group(2).strip() == 'QEMU HID Tablet':
        send_to_monitor('mouse_set ' + match.group(1) + '\n')


def press(name):
    send_to_monitor('sendkey ' + name + '\n')


def type_on_keyboard(text):
    for character in text:
        press(character)


def place_tablet(x, y):
    # Absolute positions need QMP; its range is 0-32767 across the
    # 1280x800 screen.
    command = ('{"execute": "input-send-event", "arguments": {"events": ['
               '{"type": "abs", "data": {"axis": "x", "value": %d}}, '
               '{"type": "abs", "data": {"axis": "y", "value": %d}}]}}\n') % (
                   (x * 32767 + 639) // 1279, (y * 32767 + 399) // 799)
    control.sendall(command.encode())
    try:
        control.recv(65536)
    except OSError:
        pass
    time.sleep(0.2)


def click_at(x, y):
    place_tablet(x, y)
    send_to_monitor('mouse_button 1\n')
    time.sleep(0.3)
    send_to_monitor('mouse_button 0\n')
    time.sleep(0.5)


def take_screen():
    path = os.path.abspath(os.path.join(work, 'screen.ppm'))
    if os.path.exists(path):
        os.remove(path)
    send_to_monitor('screendump ' + path + '\n')
    deadline = time.time() + 5
    while time.time() < deadline and not os.path.exists(path):
        time.sleep(0.1)
    time.sleep(0.5)
    try:
        data = open(path, 'rb').read()
        header = re.match(rb'P6\s+(\d+)\s+(\d+)\s+255\s', data)
        width = int(header.group(1))
        pixels = data[header.end():]
    except (OSError, AttributeError):
        return lambda x, y: ''

    def pixel(x, y):
        offset = (y * width + x) * 3
        return pixels[offset:offset + 3].hex()
    return pixel


def colour_near(colour, expected, tolerance):
    if len(colour) != 6:
        return False
    return all(abs(int(colour[i:i + 2], 16) - int(expected[i:i + 2], 16)) <= tolerance for i in (0, 2, 4))


marker_count = 0


def session_log():
    """The session's log (the session manager's and the desktop's lines),
    read through the serial shell."""
    global marker_count
    marker_count += 1
    marker = 'LOG' + str(marker_count)
    start = len(received)
    type_on_serial(b'm=DONE; cat /var/log/session.log; echo ' + marker.encode() + b' $m\r')
    wait_for(marker + ' DONE', 15, start)
    return bytes(received[start:])


def wait_for_session_log(texts, seconds, after=0):
    """Until the log has every text (counting only lines after the first
    `after` occurrences of the last login window), or the time runs out."""
    deadline = time.time() + seconds
    while time.time() < deadline:
        log = session_log()
        if all(log.count(text.encode()) > after for text in texts):
            return log
        time.sleep(1)
    return session_log()


def places(log):
    found = {}
    for match in re.finditer(rb'place (\S+) (\d+) (\d+)', log):
        found[match.group(1).decode()] = (int(match.group(2)), int(match.group(3)))
    return found


checks = []

# The system comes up by itself: the service manager starts the display
# server, then (once it is ready) the session, and the serial console.
started = wait_for('servicemanager: started session', 90) and wait_for('fpos login: ', 30)
checks.append(('the service manager started the display server, then the session',
               started and re.search(rb'started displayserver.*displayserver is ready.*started session',
                                     bytes(received), re.S) is not None))
if not started:
    print('SESSION TEST FAILED: the services did not start (serial log in ' + serial_log + ')')
    with open(serial_log, 'wb') as log:
        log.write(received)
    qemu.kill()
    sys.exit(1)

# The serial console asks for a password: a wrong one is refused.
type_on_serial(b'root\r')
wait_for('Password: ', 10)
type_on_serial(b'wrong\r')
checks.append(('serial console: a wrong password is refused', wait_for('Login incorrect', 15)))
wait_for('fpos login: ', 10, received.rfind(b'Login incorrect'))
type_on_serial(b'root\r')
wait_for('Password: ', 10, received.rfind(b'Login incorrect'))
type_on_serial(b'root\r')
checks.append(('serial console: root logs in', wait_for('fpos:/$ ', 15)))

# The desktop came up for the user without anyone typing anything.
log = wait_for_session_log(['user logged in', 'desktop: ready', 'place start', 'place clock'], 60)
screen = take_screen()
place = places(log)
checks.append(('the desktop started by itself for the automatic user',
               b'logging user in automatically' in log and b'session: user logged in' in log and
               b'login window shown' not in log))
checks.append(('the taskbar and the wallpaper are on the screen',
               screen(640, 785) == 'cbc6bd' and colour_near(screen(640, 4), '0f2c42', 4)))
start = len(received)
type_on_serial(b'ps -e -o user= -o comm= | grep -e desktop -e manager -e display; service list\r')
wait_for('serialconsole', 15, start)
collect(1)
listing = bytes(received[start:])
checks.append(('the desktop runs as the user, the services as root',
               re.search(rb'user +desktop', listing) is not None and
               re.search(rb'root +sessionmanager', listing) is not None and
               re.search(rb'root +displayserver', listing) is not None))
checks.append(('service list: the graphical services run, the text console does not',
               re.search(rb'displayserver +running', listing) is not None and
               re.search(rb'session +running', listing) is not None and
               re.search(rb'serialconsole +running', listing) is not None and
               re.search(rb'console +stopped', listing) is not None))

# Log off: the session ends and the login window comes back.
if 'start' in place:
    click_at(*place['start'])
    time.sleep(1)
    place = places(session_log())
if 'start-logoff' in place:
    click_at(*place['start-logoff'])
    time.sleep(1)
    press('ret')
log = wait_for_session_log(['session of user ended', 'login window shown'], 30)
screen = take_screen()
place = places(log)
checks.append(('Log off ends the session and shows the login window',
               b'asking log off' in log and b'logging off user' in log and
               b'session of user ended' in log and b'login window shown' in log and
               screen(640, 785) != 'cbc6bd'))

# The login window: a wrong password is refused, the right one works.
type_on_keyboard('user')
press('tab')
type_on_keyboard('wrong')
press('ret')
log = wait_for_session_log(['login refused for user'], 20)
checks.append(('the login window refuses a wrong password', b'login refused for user' in log))
type_on_keyboard('user')
press('ret')
log = wait_for_session_log(['user logged in'], 30, after=1)
log = wait_for_session_log(['desktop: ready'], 30, after=1)
place = places(log[log.rfind(b'session: user logged in'):])
screen = take_screen()
checks.append(('the right password starts the desktop again',
               log.count(b'session: user logged in') == 2 and log.count(b'desktop: ready') == 2 and
               screen(640, 785) == 'cbc6bd'))

# Shut down from the Start menu: through the session manager (the user
# may not shut down; it may), the kernel, and the service manager, which
# stops the session before the display server; then the machine is off.
log = wait_for_session_log(['place start'], 10, after=1)
place = places(log[log.rfind(b'session: user logged in'):])
if 'start' in place:
    click_at(*place['start'])
    time.sleep(1)
    log = session_log()
    place = places(log[log.rfind(b'session: user logged in'):])
if 'start-shutdown' in place:
    click_at(*place['start-shutdown'])
    time.sleep(1)
    press('ret')
try:
    qemu.wait(timeout=90)
except subprocess.TimeoutExpired:
    qemu.kill()
    qemu.wait()
collect(0.5)
everything = bytes(received)
checks.append(('Shut down stops the services in order and powers off',
               qemu.returncode == 0 and b'waiting for the services to stop' in everything and
               re.search(rb'stopped session.*stopping displayserver.*stopped displayserver.*every service has stopped',
                         everything, re.S) is not None and
               b'entering S5' in everything))

failed = False
for name, passed in checks:
    print(('[session] pass: ' if passed else '[session] FAIL: ') + name)
    failed = failed or not passed
with open(serial_log, 'wb') as log_file:
    log_file.write(received)
if failed:
    print('SESSION TEST FAILED (serial log in ' + serial_log + ')')
    sys.exit(1)
print('SESSION TEST PASSED')
