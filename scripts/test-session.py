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
in with a wrong password, then the right one, and asks `service list`
and `ifconfig eth0` (the network service's static configuration, and a
ping of QEMU's gateway),
and as the user keeps a mouse speed in the user's settings (mousesettings
--remember). The Control Panel, opened from the Start menu as the
user, keeps a display scale of 150% and 100% again, lets a smaller mode
go back by itself, sets the mouse's speed, types German characters with
the German layout (in its own box and in a terminal), sets the volume,
the time zone (root's password asked; date and the taskbar clock
follow), adds a user and gives them a new password, shows eth0's
address from DHCP on the Network page and gives eth1 a static address
(kept in the settings and applied: ifconfig shows it) and then what it
had again; the taskbar's network icon names eth0's address in its
tooltip and lists the interfaces when clicked. Then from the
screen: Log off on the Start menu ends the
session and brings the login window back (with the system's mouse
settings); a wrong password there is refused, the new user logs in
with the password the Control Panel gave them and logs off, the right
password starts the user's desktop again, with the user's mouse speed,
and the Control Panel removes the new user with their home; and Shut
down on the Start menu
stops the services in order (the session before the display server) and
powers the machine off: QEMU exits by itself. Both times Notepad holds
unsaved text: logging off, it asks whether to save (the test answers
No) and the session ends; shutting down, nobody answers and the session
manager ends it after the session's time is up.

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
    options.write('autologin=user heapchecks\n')
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
    '-netdev', 'user,id=net0', '-device', 'virtio-net-pci,netdev=net0',
    '-audiodev', 'none,id=sound0', '-device', 'intel-hda', '-device', 'hda-output,audiodev=sound0',
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


def report_qemu_gone():
    # QEMU ended in the middle of the test (the serial pipe broke): say
    # how it ended and what it printed, and keep what it left, so the
    # cause is not lost when the next run reuses this folder.
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
    print('SESSION TEST FAILED: QEMU ended during the test (' + ending + '); its errors and the serial log are '
          'kept in ' + kept)
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


def run_and_read(command):
    """What a command prints in the root shell on the serial console."""
    global marker_count
    marker_count += 1
    marker = 'OUT' + str(marker_count)
    start = len(received)
    type_on_serial(command.encode() + b'; m=DONE; echo ' + marker.encode() + b' $m\r')
    wait_for(marker + ' DONE', 20, start)
    output = bytes(received[start:])
    # From the line after the command's echo.
    return output[output.find(b'\n'):]


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

# The network service gave eth0 the static configuration of
# /etc/settings/Network.settings at start, and QEMU's gateway answers.
start = len(received)
type_on_serial(b'ifconfig eth0 | grep inet; ping -c 1 -W 5 10.0.2.2 | grep -c "bytes from"; n=DONE; echo NETWORK $n\r')
networked = wait_for('NETWORK DONE', 20, start)
network_log = bytes(received[start:])
checks.append(('the network service configured eth0 and the gateway answers a ping',
               networked and b'inet 10.0.2.15  netmask 255.255.255.0' in network_log and
               re.search(rb'(?m)^1\r?$', network_log) is not None))

# The user's mouse settings (libconfiguration): kept by mousesettings
# --remember in the user's own settings, given to the display server by
# the session manager at their next login (and the system's in between).
start = len(received)
type_on_serial(b'su user -c "mousesettings -r -s 15; settings get Mouse/Speed; stat -c %a \\$HOME/.settings/Mouse.settings"; '
               b'm=DONE; echo REMEMBERED $m\r')
remembered = wait_for('REMEMBERED DONE', 15, start)
remembered_log = bytes(received[start:])
checks.append(('mousesettings --remember keeps the user\'s mouse settings (theirs alone)',
               remembered and b'speed 15, acceleration 0, left-handed off' in remembered_log and
               re.search(rb'\n15\r?\n600\r?\n', remembered_log) is not None))


def control_panel_part():
    """The session log from the last Control Panel started, and the places
    it said."""
    log = session_log()
    part = log[log.rfind(b'started controlpanel'):]
    return part, places(part)


def wait_for_control_panel(text, seconds, after=0):
    """Until the last Control Panel's lines hold text more than `after`
    times; its part of the log and its places."""
    deadline = time.time() + seconds
    while True:
        part, found = control_panel_part()
        if part.count(text.encode()) > after or time.time() > deadline:
            return part, found
        time.sleep(1)


def start_control_panel(login_marker):
    """Opens the Control Panel from the Start menu of the session that
    `login_marker` began."""
    log = session_log()
    found = places(log[log.rfind(login_marker):])
    if 'start' in found:
        click_at(*found['start'])
        time.sleep(1)
        log = session_log()
        found = places(log[log.rfind(login_marker):])
    if 'start-controlpanel' in found:
        click_at(*found['start-controlpanel'])
    return wait_for_control_panel('page display', 30)


def click_place(found, name):
    if name in found:
        click_at(*found[name])
    else:
        print('[session] no place ' + name)


def choose_in_combo(found, name, key, count):
    """Drops a combo box down and moves its choice with a key."""
    click_place(found, name)
    time.sleep(0.5)
    for step in range(count):
        press(key)
    press('ret')
    time.sleep(0.5)


def apply_and_keep(found, after):
    """Apply, then Keep in "Keep these settings?"; True once kept."""
    click_place(found, 'apply')
    part, found = wait_for_control_panel('place keep-yes', 30, after)
    click_place(found, 'keep-yes')
    part, found = wait_for_control_panel('kept', 20, after)
    return part.count(b'kept') > after


def type_with_shift(text):
    """Types text on the keyboard, capitals with Shift."""
    for character in text:
        if character == ' ':
            press('spc')
        elif character.isupper():
            press('shift-' + character.lower())
        else:
            press(character)


def type_address(text):
    """Types an address on the keyboard (dots and slashes by their keys'
    names)."""
    names = {'.': 'dot', '/': 'slash'}
    for character in text:
        press(names.get(character, character))


def replace_box_text(found, name, text):
    """Clicks a box and types text over what it holds."""
    click_place(found, name)
    press('ctrl-a')
    if text:
        type_address(text)
    else:
        press('backspace')


def log_in_through_window(name, password):
    """Types a name and a password into the login window shown last,
    each over what its box holds."""
    log = session_log()
    found = places(log[log.rfind(b'login window shown') - 400:])
    for box, text in (('login-user-name', name), ('login-password', password)):
        click_place(found, box)
        press('ctrl-a')
        type_on_keyboard(text)
    press('ret')


def open_notepad_with_text(after):
    """Starts Notepad from the Start menu and types into it, so it has
    unsaved text; `after` counts the logins before this session."""
    log = session_log()
    found = places(log[log.rfind(b'session: user logged in'):])
    if 'start' in found:
        click_at(*found['start'])
        time.sleep(1)
        log = session_log()
        found = places(log[log.rfind(b'session: user logged in'):])
    if 'start-notepad' in found:
        click_at(*found['start-notepad'])
    log = wait_for_session_log(['title Untitled - Notepad'], 30, after=after)
    time.sleep(1)
    type_on_keyboard('hello')
    time.sleep(1)
    return log.count(b'title Untitled - Notepad') > after


# The Control Panel, from the Start menu, as the user (an ordinary one:
# what only root may change asks for root's password).
part, found = start_control_panel(b'session: user logged in')
checks.append(('the Start menu starts the Control Panel on its Display page',
               b'started controlpanel' in part and b'page display' in part))

# Display: 150% kept (the server keeps it in the system's settings), then
# 100% kept again; a smaller mode not answered goes back by itself.
choose_in_combo(found, 'display-scales', 'down', 2)
kept = apply_and_keep(found, 0)
part, found = control_panel_part()
screen = take_screen()
scale_kept = run_and_read('settings get -s Display/0/Scale')
checks.append(('Display: a scale of 150% is applied, kept and remembered (the taskbar 1.5 times as high)',
               kept and b'applied display 0 mode 1280 x 800 scale 150' in part and b'scale 150' in part and
               re.search(rb'\n150\r?\n', scale_kept) is not None and screen(640, 760) == 'cbc6bd'))
choose_in_combo(found, 'display-scales', 'up', 2)
kept = apply_and_keep(found, 1)
part, found = control_panel_part()
scale_kept = run_and_read('settings get -s Display/0/Scale')
checks.append(('Display: back to 100%, kept',
               kept and b'scale 100' in part and re.search(rb'\n100\r?\n', scale_kept) is not None))
choose_in_combo(found, 'display-modes', 'up', 1)
click_place(found, 'apply')
part, found = wait_for_control_panel('reverted', 45)
mode_now = run_and_read('displaymode')
checks.append(('Display: a new mode left unanswered goes back when the countdown ends',
               b'keep-countdown 0' in part and b'reverted' in part and b'1280x800' in mode_now and
               re.search(rb'applied display 0 mode (?!1280 x 800)\d+ x \d+', part) is not None))

# Mouse: a speed of 20 reaches the display server; 15 again.
click_place(found, 'page-mouse')
part, found = wait_for_control_panel('page mouse', 20)
click_place(found, 'mouse-speed-20')
click_place(found, 'apply')
part, found = wait_for_control_panel('applied mouse speed 20', 20)
mouse_now = run_and_read('mousesettings')
click_place(found, 'mouse-speed-15')
click_place(found, 'apply')
part, found = wait_for_control_panel('applied mouse speed 15', 20)
checks.append(('Mouse: the speed chosen reaches the display server',
               b'applied mouse speed 20, acceleration 0, left-handed off' in part and
               b'speed 20, acceleration 0, left-handed off' in mouse_now and
               b'applied mouse speed 15' in part))

# Keyboard: German; keys typed with it give German characters, in the
# Control Panel's box and in a terminal; then US again.
click_place(found, 'page-keyboard')
part, found = wait_for_control_panel('page keyboard', 20)
click_place(found, 'keyboard-layout-de')
click_place(found, 'apply')
part, found = wait_for_control_panel('applied keyboard layout de', 20)
layout_now = run_and_read('keyboardsettings')
click_place(found, 'keyboard-try')
for key in ('z', 'y', 'apostrophe'):
    press(key)
part, found = wait_for_control_panel('typed yz\u00e4', 20)
typed = 'typed yz\u00e4'.encode() in part
log = session_log()
desktop_places = places(log[log.rfind(b'session: user logged in'):])
click_place(desktop_places, 'start')
time.sleep(1)
log = session_log()
desktop_places = places(log[log.rfind(b'session: user logged in'):])
click_place(desktop_places, 'start-terminal')
time.sleep(3)
# German keys for "echo yz\u00e4 > /tmp/kb": z and y swapped, the a umlaut
# on the apostrophe key, > on Shift and the key by the left Shift, / on
# Shift+7.
for key in ('e', 'c', 'h', 'o', 'spc', 'z', 'y', 'apostrophe', 'spc', 'shift-less', 'spc', 'shift-7', 't', 'm',
            'p', 'shift-7', 'k', 'b', 'ret'):
    press(key)
time.sleep(1)
type_on_keyboard('exit')
press('ret')
time.sleep(2)
typed_in_terminal = run_and_read('cat /tmp/kb')
part, found = control_panel_part()
click_place(found, 'page-keyboard')
time.sleep(1)
click_place(found, 'keyboard-layout-us')
click_place(found, 'apply')
part, found = wait_for_control_panel('applied keyboard layout us', 20)
checks.append(('Keyboard: German keys type German characters, in the Control Panel and in a terminal',
               b'layout de, repeat delay 500, rate 11' in layout_now and typed and
               'yz\u00e4'.encode() in typed_in_terminal and b'applied keyboard layout us' in part))

# Sound: the volume at 40% reaches the output, is kept, and the volume
# icon shows it.
click_place(found, 'page-sound')
part, found = wait_for_control_panel('page sound', 20)
click_place(found, 'sound-volume-40')
click_place(found, 'apply')
part, found = wait_for_control_panel('applied volume 0 40', 20)
time.sleep(1.5)
volume_now = run_and_read('mixer; settings get -s Sound/0/Volume')
log = session_log()
checks.append(('Sound: the volume reaches the output, is kept, and the volume icon shows it',
               b'applied volume 0 40' in part and re.search(rb'volume 40%\r?\n40\r?\n', volume_now) is not None and
               b'Volume: 40%' in log))

# Date and Time: Europe/Berlin, which needs root's password; the taskbar
# clock and date show the new local time.
zones = run_and_read('timezone -l').decode(errors='replace')
zone_names = re.findall(r'^([A-Z][A-Za-z_/]+) [-+]\d{4} ', zones, re.M)
click_place(found, 'page-datetime')
part, found = wait_for_control_panel('page datetime', 20)
click_place(found, 'datetime-zones')
press('home')
for step in range(zone_names.index('Europe/Berlin') if 'Europe/Berlin' in zone_names else 0):
    press('down')
click_place(found, 'apply')
part, found = wait_for_control_panel('password-asked', 20)
type_on_keyboard('root')
press('ret')
part, found = wait_for_control_panel('applied time-zone Europe/Berlin', 30)
time.sleep(2)
before = run_and_read('date +%H:%M; timezone')
log = session_log()
clocks = re.findall(rb'clock (\d\d:\d\d)', log)
after = run_and_read('date +%H:%M')
times_now = re.findall(rb'\n(\d\d:\d\d)\r?\n', before + after)
checks.append(('Date and Time: a new time zone (root\'s password asked) reaches date and the taskbar clock',
               b'password-asked Administrator' in part and b'applied time-zone Europe/Berlin' in part and
               b'Europe/Berlin +0' in before and bool(clocks) and clocks[-1] in times_now))

# Users: alice added (the password given before is not asked again),
# then a new password for her.
click_place(found, 'page-users')
part, found = wait_for_control_panel('page users', 20)
click_place(found, 'users-add')
part, found = wait_for_control_panel('dialog Add a User', 20)
type_on_keyboard('alice')
press('tab')
type_with_shift('Alice Example')
press('tab')
type_on_keyboard('secret1')
press('tab')
type_on_keyboard('secret1')
press('ret')
part, found = wait_for_control_panel('user-added alice', 30)
account = run_and_read('grep "^alice:" /etc/passwd; stat -c "%U %G %a" /home/alice')
click_place(found, 'user-row-alice')
click_place(found, 'users-password')
part, found = wait_for_control_panel('dialog Password of alice', 20)
type_on_keyboard('secret2')
press('tab')
type_on_keyboard('secret2')
press('ret')
part, found = wait_for_control_panel('password-changed alice', 30)
checks.append(('Users: a new user, with a home of their own, and a new password for them',
               b'user-added alice' in part and part.count(b'password-asked') == 1 and
               b'alice:x:1001:1001:Alice Example:/home/alice:/bin/sh' in account and
               b'alice alice 755' in account and b'password-changed alice' in part))

# Network: eth0 has its address from DHCP (the network service's state);
# eth1 is given a static address (the administrator's password given
# before goes with it, not asked again), which the system settings
# service keeps in Network.settings and the network service applies at
# once; then eth1 gets back what it had.
click_place(found, 'page-network')
part, found = wait_for_control_panel('page network', 20)
time.sleep(2)
part, found = control_panel_part()
eth1_line = re.search(rb'network-interface eth1 (\w+) (up|down)', part)
eth1_method = eth1_line.group(1).decode() if eth1_line else 'none'
eth1_was_down = eth1_line is not None and eth1_line.group(2) == b'down'
checks.append(('Network: the page lists eth0 with DHCP and the address 10.0.2.15',
               b'network-interface eth0 dhcp' in part and
               re.search(rb'network-(?:interface eth0 dhcp up|state eth0) connected 10\.0\.2\.15/24', part)
               is not None))
click_place(found, 'network-row-eth1')
part, found = wait_for_control_panel('network-chosen eth1', 10)
click_place(found, 'network-tab-address')
if eth1_was_down:
    click_place(found, 'network-enabled')
click_place(found, 'network-method-static')
replace_box_text(found, 'network-address', '192.168.50.2')
replace_box_text(found, 'network-prefix', '24')
replace_box_text(found, 'network-gateway', '')
click_place(found, 'apply')
part, found = wait_for_control_panel('applied network eth1 static 192.168.50.2/24', 30)
kept = run_and_read('settings get -s Network/Interfaces/eth1/Method; settings get -s Network/Interfaces/eth1/Address')
configured = b''
for attempt in range(15):
    configured = run_and_read('ifconfig eth1')
    if b'inet 192.168.50.2' in configured:
        break
    time.sleep(1)
checks.append(('Network: a static address for eth1 is kept in the settings and applied by the network service',
               b'applied network eth1 static 192.168.50.2/24 up' in part and part.count(b'password-asked') == 1 and
               re.search(rb'\nstatic\r?\n192\.168\.50\.2/24\r?\n', kept) is not None and
               b'inet 192.168.50.2  netmask 255.255.255.0' in configured))
click_place(found, 'network-method-' + eth1_method)
if eth1_was_down:
    click_place(found, 'network-enabled')
click_place(found, 'apply')
part, found = wait_for_control_panel('applied network eth1 ' + eth1_method, 30)
kept = run_and_read('settings get -s Network/Interfaces/eth1/Method')
checks.append(('Network: eth1 gets back the method it had (' + eth1_method + ')',
               ('applied network eth1 ' + eth1_method).encode() in part and
               re.search(('\\n' + eth1_method + '\\r?\\n').encode(), kept) is not None))
click_place(found, 'ok')
part, found = wait_for_control_panel('closed', 20)

# The taskbar's network icon: its tooltip names eth0's address, and a
# click opens the list of interfaces.
log = session_log()
desktop_part = log[log.rfind(b'session: user logged in'):]
network_icon = re.findall(rb'notification (\d+) eth0: ', desktop_part)
desktop_places = places(desktop_part)
icon_place = desktop_places.get('notification-' + network_icon[-1].decode()) if network_icon else None
if icon_place:
    place_tablet(*icon_place)
    time.sleep(1.5)
    click_at(*icon_place)
    time.sleep(1.5)
    # A press outside the pop-up closes it, like a menu (the clock does
    # nothing when clicked).
    click_place(desktop_places, 'clock')
    place_tablet(640, 400)
    time.sleep(1)
log = session_log()
desktop_part = log[log.rfind(b'session: user logged in'):]
checks.append(('the taskbar\'s network icon: its tooltip names eth0\'s address, a click lists the interfaces',
               icon_place is not None and
               'tooltip eth0: 10.0.2.15 \u2014 connected'.encode() in desktop_part and
               b'network-popup' in desktop_part and b'network-popup-row eth0 eth0: 10.0.2.15' in desktop_part))

# Log off with Notepad holding unsaved text: the session's programs are
# asked to end, so Notepad asks whether to save (No is answered), and
# the session ends without anything being ended outright; the login
# window comes back.
notepad_open = open_notepad_with_text(0)
log = session_log()
place = places(log[log.rfind(b'session: user logged in'):])
if 'start' in place:
    click_at(*place['start'])
    time.sleep(1)
    place = places(session_log())
if 'start-logoff' in place:
    click_at(*place['start-logoff'])
    time.sleep(1)
    press('ret')
time.sleep(3)
press('alt-n')
log = wait_for_session_log(['session of user ended', 'login window shown'], 30)
screen = take_screen()
place = places(log)
logoff_part = log[log.rfind(b'logging off user'):]
checks.append(('Log off ends the session and shows the login window',
               b'asking log off' in log and b'logging off user' in log and
               b'session of user ended' in log and b'login window shown' in log and
               screen(640, 785) != 'cbc6bd'))
checks.append(('Log off asks the programs to end: Notepad asks to save its text, and ends when told No',
               notepad_open and b'asking session' in logoff_part and b'to end (log-off)' in logoff_part and
               b'desktop: asked to end (log-off)' in logoff_part and b'answer no' in logoff_part and
               b'\nexit' in logoff_part and b'did not end in time' not in logoff_part))
checks.append(('the session manager gives the display server the system\'s mouse settings after a session',
               re.search(rb'session of user ended.*mouse settings of the system: speed 10, acceleration 0, '
                         rb'left-handed off.*login window shown', log, re.S) is not None))

# The login window: a wrong password is refused, the right one works.
type_on_keyboard('user')
press('tab')
type_on_keyboard('wrong')
press('ret')
log = wait_for_session_log(['login refused for user'], 20)
checks.append(('the login window refuses a wrong password', b'login refused for user' in log))
# The user the Control Panel added logs in with the password it gave
# them, and logs off. (The refused login left its name in the box: it
# is chosen whole and typed over.)
log_in_through_window('alice', 'secret2')
log = wait_for_session_log(['alice logged in', 'place start'], 30)
log = wait_for_session_log(['desktop: ready'], 30, after=1)
listing = run_and_read('ps -e -o user= -o comm= | grep desktop')
checks.append(('the new user logs in through the login window, with the password the Control Panel gave',
               b'session: alice logged in' in log and re.search(rb'alice +desktop', listing) is not None))
place = places(log[log.rfind(b'session: alice logged in'):])
if 'start' in place:
    click_at(*place['start'])
    time.sleep(1)
    log = session_log()
    place = places(log[log.rfind(b'session: alice logged in'):])
if 'start-logoff' in place:
    click_at(*place['start-logoff'])
    time.sleep(1)
    press('ret')
log = wait_for_session_log(['session of alice ended', 'login window shown'], 30, after=1)
log_in_through_window('user', 'user')
log = wait_for_session_log(['user logged in'], 30, after=1)
log = wait_for_session_log(['desktop: ready'], 30, after=2)
place = places(log[log.rfind(b'session: user logged in'):])
screen = take_screen()
checks.append(('the right password starts the desktop again',
               log.count(b'session: user logged in') == 2 and log.count(b'desktop: ready') == 3 and
               screen(640, 785) == 'cbc6bd'))
start = len(received)
type_on_serial(b'mousesettings; m=DONE; echo MOUSE $m\r')
mouse_asked = wait_for('MOUSE DONE', 15, start)
checks.append(('the user\'s mouse settings are given back at their next login',
               log.count(b'mouse settings of user: speed 10, acceleration 0, left-handed off') == 1 and
               b'mouse settings of user: speed 15, acceleration 0, left-handed off' in log and
               mouse_asked and b'speed 15, acceleration 0, left-handed off' in bytes(received[start:])))

# The Control Panel removes alice, with her home (a new Control Panel:
# root's password is asked again).
part, found = start_control_panel(b'session: user logged in')
click_place(found, 'page-users')
part, found = wait_for_control_panel('page users', 20)
click_place(found, 'user-row-alice')
click_place(found, 'users-remove')
part, found = wait_for_control_panel('place user-remove-home', 20)
click_place(found, 'user-remove-home')
click_place(found, 'user-ok')
part, found = wait_for_control_panel('password-asked', 20)
type_on_keyboard('root')
press('ret')
part, found = wait_for_control_panel('user-removed alice', 30)
gone = run_and_read('grep -c "^alice:" /etc/passwd /etc/group /etc/shadow; test -e /home/alice || echo home-gone')
checks.append(('Users: the Control Panel removes a user with their home',
               b'user-removed alice' in part and b'/etc/passwd:0' in gone and b'/etc/group:0' in gone and
               b'/etc/shadow:0' in gone and b'home-gone' in gone))
click_place(found, 'ok')
wait_for_control_panel('closed', 20)

# Shut down from the Start menu: through the session manager (the user
# may not shut down; it may), the kernel, and the service manager, which
# stops the session before the display server; then the machine is off.
# Notepad holds unsaved text again and nobody answers its question: the
# session manager ends it once its programs' time is up, well within
# the session service's stop-timeout.
open_notepad_with_text(1)
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
               b'session did not stop in time' not in everything and
               b'entering S5' in everything))

# Every program checks its heap (the kernel option heapchecks); a failed
# check is reported on the console.
heap_reports = re.findall(rb'heap check in [^\r\n]*', bytes(received))
checks.append(('no heap check failed' + ''.join('\n    ' + report.decode(errors='replace')
                                                 for report in heap_reports),
               not heap_reports))

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
