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

"""Reference pictures from the installed Firefox, driven over its
Marionette protocol (no extra packages): a headless Firefox with a
profile of its own per worker, the viewport sized exactly (the window
grown by what its frame takes), the page loaded and then left a few
seconds to settle (scripts that build the page after the load event),
and a picture of the viewport. Used by scripts/compare-sites.py."""

import base64
import json
import os
import socket
import subprocess
import time

PREFERENCES = (
    # Overlay scroll bars: the page gets the whole width, as webbrowse's does.
    'user_pref("widget.gtk.overlay-scrollbars.enabled", true);',
    'user_pref("ui.useOverlayScrollbars", 1);',
    'user_pref("browser.shell.checkDefaultBrowser", false);',
    'user_pref("datareporting.policy.dataSubmissionEnabled", false);',
    'user_pref("toolkit.telemetry.reportingpolicy.firstRun", false);',
    'user_pref("browser.startup.homepage_override.mstone", "ignore");',
    'user_pref("browser.aboutwelcome.enabled", false);',
)


class MarionetteError(Exception):
    pass


class Marionette:
    """One connection to a Firefox started with --marionette."""

    def __init__(self, port, timeout=60):
        deadline = time.time() + timeout
        while True:
            try:
                self.socket = socket.create_connection(('127.0.0.1', port), timeout=5)
                break
            except OSError:
                if time.time() > deadline:
                    raise MarionetteError('Firefox did not open its Marionette port %d' % port)
                time.sleep(0.25)
        self.socket.settimeout(120)
        self.buffer = b''
        self.next_id = 1
        self.receive()

    def receive(self):
        while b':' not in self.buffer:
            self.fill()
        length, _, rest = self.buffer.partition(b':')
        length = int(length)
        self.buffer = rest
        while len(self.buffer) < length:
            self.fill()
        message = self.buffer[:length]
        self.buffer = self.buffer[length:]
        return json.loads(message.decode('utf-8'))

    def fill(self):
        chunk = self.socket.recv(1 << 20)
        if not chunk:
            raise MarionetteError('Firefox closed the connection')
        self.buffer += chunk

    def command(self, name, parameters=None):
        message_id = self.next_id
        self.next_id += 1
        data = json.dumps([0, message_id, name, parameters or {}]).encode('utf-8')
        self.socket.sendall(str(len(data)).encode('ascii') + b':' + data)
        while True:
            reply = self.receive()
            if isinstance(reply, list) and len(reply) == 4 and reply[0] == 1 and reply[1] == message_id:
                break
        if reply[2]:
            raise MarionetteError('%s: %s' % (name, reply[2].get('message', reply[2])))
        result = reply[3]
        if isinstance(result, dict) and 'value' in result:
            return result['value']
        return result

    def close(self):
        try:
            self.socket.close()
        except OSError:
            pass


class ReferenceBrowser:
    """A headless Firefox for one worker; started on first use."""

    def __init__(self, profile_directory, port):
        self.profile = profile_directory
        self.port = port
        self.process = None
        self.client = None

    def start(self):
        os.makedirs(self.profile, exist_ok=True)
        with open(os.path.join(self.profile, 'user.js'), 'w') as preferences:
            preferences.write('\n'.join(PREFERENCES) + '\n')
            preferences.write('user_pref("marionette.port", %d);\n' % self.port)
        # A large headless screen (the window may be taller than the
        # default 1366 x 768), and the browser's own scripts reachable
        # (narrow viewports: below the window's minimum width the page's
        # browser element is narrowed instead).
        environment = dict(os.environ, MOZ_HEADLESS_WIDTH='2560', MOZ_HEADLESS_HEIGHT='2000',
                           MOZ_REMOTE_ALLOW_SYSTEM_ACCESS='1')
        self.process = subprocess.Popen(['firefox', '--headless', '--marionette', '-no-remote', '-profile', self.profile],
                                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, env=environment)
        self.client = Marionette(self.port)
        self.client.command('WebDriver:NewSession', {'capabilities': {'alwaysMatch': {'pageLoadStrategy': 'normal'}}})
        self.client.command('WebDriver:SetTimeouts', {'pageLoad': 45000, 'script': 30000})

    def stop(self):
        if self.client is not None:
            try:
                self.client.command('Marionette:Quit', {'flags': ['eForceQuit']})
            except (MarionetteError, OSError):
                pass
            self.client.close()
            self.client = None
        if self.process is not None:
            try:
                self.process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                self.process.kill()
            self.process = None

    def chrome_script(self, script):
        self.client.command('Marionette:SetContext', {'value': 'chrome'})
        try:
            return self.client.command('WebDriver:ExecuteScript', {'script': script, 'args': []})
        finally:
            self.client.command('Marionette:SetContext', {'value': 'content'})

    def size_viewport(self, width, height):
        self.chrome_script('gBrowser.selectedBrowser.style.maxWidth = ""; return 0;')
        self.client.command('WebDriver:SetWindowRect', {'width': width, 'height': height})
        for _ in range(3):
            inner = self.client.command('WebDriver:ExecuteScript',
                                        {'script': 'return [window.innerWidth, window.innerHeight];', 'args': []})
            if inner == [width, height]:
                return
            if inner[0] > width and inner[1] == height:
                # The window cannot be that narrow: narrow the page's browser.
                self.chrome_script('gBrowser.selectedBrowser.style.maxWidth = "%dpx"; return 0;' % width)
                continue
            rect = self.client.command('WebDriver:GetWindowRect')
            self.client.command('WebDriver:SetWindowRect', {'width': rect['width'] + width - inner[0],
                                                            'height': rect['height'] + height - inner[1]})

    def screenshot(self, url, width, height, png, settle_seconds=3.0):
        """The viewport of url at width x height into png; True when made."""
        try:
            if self.client is None:
                self.start()
            self.client.command('WebDriver:Navigate', {'url': 'about:blank'})
            self.size_viewport(width, height)
            try:
                self.client.command('WebDriver:Navigate', {'url': url})
            except MarionetteError:
                pass  # the load timed out: take what is there
            time.sleep(settle_seconds)
            self.client.command('WebDriver:ExecuteScript', {'script': 'window.scrollTo(0, 0); return 0;', 'args': []})
            time.sleep(0.3)
            data = self.client.command('WebDriver:TakeScreenshot', {'full': False, 'hash': False})
            with open(png, 'wb') as out:
                out.write(base64.b64decode(data))
            return True
        except (MarionetteError, OSError, ValueError):
            self.stop()
            return False
