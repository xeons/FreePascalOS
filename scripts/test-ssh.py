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
SSH test: boots the system in text mode (root logged in on the serial
console) with QEMU's user network forwarding a free port of the host
to the guest's port 22, where the sshd service listens, and talks to
it with the host's OpenSSH client (/usr/bin/ssh, scp, sftp):

  - client keys made with ssh-keygen (ed25519, ecdsa, rsa) are put in
    the user's ~/.ssh/authorized_keys from the serial shell;
  - exec: a command's output, standard error apart, and exit status;
    with each cipher, host key algorithm and the libssh.org name of the
    key exchange; with the ecdsa and rsa keys (rsa-sha2-512);
  - a command's input: 300 KB through cat and back (flow control);
  - a pseudo-terminal session (ssh -tt): tty, stty size, the exit status;
  - several channels over one connection (ControlMaster);
  - scp (SFTP underneath) a file to the guest and back;
  - sftp batch: mkdir, cd, put, ls, rename, get, rm, rmdir;
  - logging in with a password (SSH_ASKPASS), and as root;
  - a wrong key and a wrong password refused;
  - mlkem768x25519-sha256 by default (no post-quantum warning) and forced;
  - -L and -R forwarding to a host side echo server;
  - agent forwarding with the host's ssh-agent (ssh-add -l in the guest,
    and the guest's own ssh logging in to its sshd with the key);
  - the guest's ssh-keygen and ssh over loopback (exec, pty);
  - an authorized_keys command= key, keyboard-interactive;
  - after a restart with a new sshd_config: a user certificate
    (TrustedUserCAKeys), a host certificate (@cert-authority), client
    keep-alives and a Match block;
  - the server's log.

    test-ssh.py <esp-directory> <system-disk-image>

Prints "SSH TEST PASSED" and exits with 0 when every check passed.
"""
import os
import shutil
import socket
import stat
import subprocess
import sys
import tempfile
import time

esp_directory, system_disk = sys.argv[1], sys.argv[2]
build_directory = os.path.dirname(esp_directory)
work = os.path.abspath(os.path.join(build_directory, 'ssh-test'))
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

serial_log = os.path.join(work, 'serial.log')
for suffix in ('.in', '.out'):
    os.mkfifo(os.path.join(work, 'serial' + suffix))


def free_port():
    with socket.socket() as probe:
        probe.bind(('127.0.0.1', 0))
        return probe.getsockname()[1]


port = free_port()
accelerated = os.environ.get('ACCEL') == 'kvm'
qemu = subprocess.Popen([
    'qemu-system-x86_64', '-machine', 'q35',
    *(['-accel', 'kvm', '-cpu', 'host'] if accelerated else ['-cpu', 'max']),
    '-m', '512M', '-smp', '2',
    '-drive', 'if=pflash,format=raw,readonly=on,file=' + firmware_code,
    '-drive', 'if=pflash,format=raw,file=' + os.path.join(work, 'vars.fd'),
    '-drive', 'format=raw,file=fat:rw:' + os.path.join(work, 'esp'),
    '-drive', 'format=raw,file=' + os.path.join(work, 'system.img'),
    '-device', 'isa-debug-exit,iobase=0xf4,iosize=0x04',
    '-netdev', 'user,id=net0,hostfwd=tcp:127.0.0.1:%d-:22' % port,
    '-device', 'virtio-net-pci,netdev=net0',
    '-serial', 'pipe:' + os.path.join(work, 'serial'),
    '-display', 'none', '-no-reboot'],
    stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
    stderr=open(os.path.join(work, 'qemu-errors.log'), 'wb'))

serial_out = os.open(os.path.join(work, 'serial.out'), os.O_RDONLY | os.O_NONBLOCK)
received = bytearray()


def give_up(message):
    with open(serial_log, 'wb') as log:
        log.write(received)
    print('SSH TEST FAILED: ' + message + ' (serial log in ' + serial_log + ')')
    qemu.kill()
    sys.exit(1)


def open_serial_input():
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
    give_up('QEMU did not start (errors in ' + os.path.join(work, 'qemu-errors.log') + ')')


serial_in = open_serial_input()


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
    try:
        for byte in data:
            serial_in.write(bytes([byte]))
            time.sleep(0.01)
    except BrokenPipeError:
        give_up('QEMU ended during the test')


def shell(command, marker, seconds=30):
    """Runs command on the serial shell; what it printed."""
    start = len(received)
    type_on_serial(command.encode() + b'; m=DONE; echo ' + marker.encode() + b' $m\r')
    wait_for(marker + ' DONE', seconds, start)
    return bytes(received[start:]).decode(errors='replace')


checks = []


def check(name, condition, detail=''):
    checks.append((name, bool(condition)))
    if not condition and detail:
        print('  ' + name + ': ' + detail.strip()[-800:])


if not wait_for('fpos:/$ ', 180):
    give_up('the shell did not start')

# Client keys: three that are let in, one that is not.
keys = {}
for kind, extra in (('ed25519', []), ('ecdsa', ['-b', '256']), ('rsa', ['-b', '2048']), ('wrong', [])):
    path = os.path.join(work, 'id_' + kind)
    key_type = 'ed25519' if kind == 'wrong' else kind
    subprocess.run(['ssh-keygen', '-q', '-t', key_type, *extra, '-N', '', '-C', 'test-' + kind, '-f', path],
                   check=True, stdin=subprocess.DEVNULL)
    keys[kind] = path

# authorized_keys for the user (and root's for the ed25519 key), written
# from the serial shell a line at a time.
shell('mkdir -p /home/user/.ssh /.ssh; rm -f /home/user/.ssh/authorized_keys', 'MKDIR')
for kind in ('ed25519', 'ecdsa', 'rsa'):
    with open(keys[kind] + '.pub') as public_file:
        line = public_file.read().strip()
    shell("echo '" + line + "' >> /home/user/.ssh/authorized_keys", 'KEY-' + kind.upper(), 60)
with open(keys['ed25519'] + '.pub') as public_file:
    shell("echo '" + public_file.read().strip() + "' > /.ssh/authorized_keys", 'ROOT-KEY', 60)
listing = shell('chown user:user /home/user/.ssh /home/user/.ssh/authorized_keys; chmod 700 /home/user/.ssh; '
                'wc -l /home/user/.ssh/authorized_keys', 'AUTHORIZED')
check('authorized_keys written', '3 /home/user/.ssh/authorized_keys' in listing, listing)

common = ['-F', '/dev/null', '-o', 'StrictHostKeyChecking=no', '-o', 'UserKnownHostsFile=/dev/null',
          '-o', 'LogLevel=ERROR', '-o', 'ConnectTimeout=60', '-o', 'ServerAliveInterval=0']
key_options = ['-o', 'BatchMode=yes', '-o', 'IdentitiesOnly=yes', '-o', 'PasswordAuthentication=no']


def ssh(arguments, key='ed25519', user='user', extra=(), input_data=None, timeout=180, tty=False):
    command = ['ssh', *common, *key_options, '-i', keys[key], '-p', str(port), *extra]
    if tty:
        command.append('-tt')
    command += [user + '@127.0.0.1', *arguments]
    try:
        return subprocess.run(command, input=input_data, capture_output=True, timeout=timeout)
    except subprocess.TimeoutExpired as expired:
        return subprocess.CompletedProcess(command, -1, expired.stdout or b'', (expired.stderr or b'') + b' (timed out)')


def text(result):
    return 'status %d, out %r, err %r' % (result.returncode, result.stdout[-300:], result.stderr[-300:])


# The service makes its host keys and starts listening: wait until a
# command runs.
deadline = time.time() + 240
first = None
while time.time() < deadline:
    first = ssh(['echo', 'ready'], timeout=120)
    if first.returncode == 0 and b'ready' in first.stdout:
        break
    time.sleep(3)
check('sshd answers on port 22 (forwarded to %d)' % port, first is not None and first.returncode == 0, text(first))
if first is None or first.returncode != 0:
    print(shell('service status sshd; cat /var/log/sshd.log', 'SSHD-LOG'))

# exec: output, standard error and exit status.
result = ssh(['echo ssh-exec-ok; echo to-stderr 1>&2; exit 3'])
check('exec: output, standard error and exit status',
      result.returncode == 3 and result.stdout == b'ssh-exec-ok\n' and b'to-stderr' in result.stderr,
      text(result))
result = ssh(['whoami; echo $HOME; echo $SSH_CONNECTION'])
check('exec: runs as the user, with HOME and SSH_CONNECTION',
      result.returncode == 0 and result.stdout.startswith(b'user\n/home/user\n10.0.2.2 '),
      text(result))

for cipher in ('chacha20-poly1305@openssh.com', 'aes256-gcm@openssh.com', 'aes128-gcm@openssh.com'):
    result = ssh(['echo', 'cipher-' + cipher], extra=['-c', cipher])
    check('exec with ' + cipher, result.returncode == 0 and ('cipher-' + cipher).encode() in result.stdout,
          text(result))
for algorithm in ('ssh-ed25519', 'ecdsa-sha2-nistp256'):
    result = ssh(['echo', 'hostkey-ok'], extra=['-o', 'HostKeyAlgorithms=' + algorithm])
    check('host key ' + algorithm, result.returncode == 0 and b'hostkey-ok' in result.stdout, text(result))
result = ssh(['echo', 'kex-ok'], extra=['-o', 'KexAlgorithms=curve25519-sha256@libssh.org'])
check('key exchange curve25519-sha256@libssh.org', result.returncode == 0 and b'kex-ok' in result.stdout,
      text(result))
result = ssh(['echo', 'ecdsa-key-ok'], key='ecdsa')
check('publickey with an ecdsa-sha2-nistp256 key', result.returncode == 0 and b'ecdsa-key-ok' in result.stdout,
      text(result))
result = ssh(['echo', 'rsa-key-ok'], key='rsa', extra=['-o', 'PubkeyAcceptedAlgorithms=rsa-sha2-512'])
check('publickey with an RSA key (rsa-sha2-512)', result.returncode == 0 and b'rsa-key-ok' in result.stdout,
      text(result))

# A command's input, 300 KB through cat and back.
payload = bytes((i * 7 + i // 251) & 0xFF for i in range(300000))
result = ssh(['cat'], input_data=payload, timeout=300)
check('exec: 300 KB of input through cat and back', result.returncode == 0 and result.stdout == payload,
      'status %d, %d bytes back' % (result.returncode, len(result.stdout)))

# A pseudo-terminal.
result = ssh([], tty=True, input_data=b'tty; stty size; echo PTY-$USER-MARK\nexit 5\n', timeout=180)
output = result.stdout.replace(b'\r', b'')
check('pty session: a terminal of 24 by 80, the exit status',
      result.returncode == 5 and b'/dev/pts' in output and b'24 80' in output and b'PTY-user-MARK' in output,
      text(result))

# Several channels over one connection.
# The control socket in a short directory: a socket path holds at most
# 107 bytes, and ssh adds a temporary suffix to it while it binds.
control_directory = tempfile.mkdtemp(prefix='fpos-ssh-')
control = os.path.join(control_directory, 'control')
master = subprocess.Popen(['ssh', *common, *key_options, '-i', keys['ed25519'], '-p', str(port),
                           '-o', 'ControlMaster=yes', '-o', 'ControlPath=' + control, '-N', 'user@127.0.0.1'],
                          stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
deadline = time.time() + 120
while time.time() < deadline and not os.path.exists(control):
    time.sleep(0.5)
multiplexed = ['-o', 'ControlPath=' + control, '-o', 'ControlMaster=no']
slow = subprocess.Popen(['ssh', *common, *multiplexed, '-p', str(port), 'user@127.0.0.1', 'sleep 3; echo channel-one'],
                        stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
quick = ssh(['echo channel-two'], extra=multiplexed)
slow_output, _ = slow.communicate(timeout=120)
check('two channels at once over one connection',
      os.path.exists(control) and quick.returncode == 0 and b'channel-two' in quick.stdout and
      slow.returncode == 0 and b'channel-one' in slow_output, text(quick))
subprocess.run(['ssh', *common, '-o', 'ControlPath=' + control, '-O', 'exit', 'user@127.0.0.1'],
               capture_output=True, timeout=30)
master.wait(timeout=30)
shutil.rmtree(control_directory, ignore_errors=True)

# scp, which speaks SFTP underneath.
original = os.path.join(work, 'original.bin')
with open(original, 'wb') as data_file:
    data_file.write(bytes((i * 13 + i // 997) & 0xFF for i in range(400000)))
scp = ['scp', *common, *key_options, '-i', keys['ed25519'], '-P', str(port)]
upload = subprocess.run(scp + [original, 'user@127.0.0.1:/home/user/copy.bin'], capture_output=True, timeout=300)
returned = os.path.join(work, 'returned.bin')
download = subprocess.run(scp + ['user@127.0.0.1:/home/user/copy.bin', returned], capture_output=True, timeout=300)
same = os.path.exists(returned) and open(original, 'rb').read() == open(returned, 'rb').read()
check('scp to the guest and back', upload.returncode == 0 and download.returncode == 0 and same,
      text(upload) + ' / ' + text(download))

# sftp batch operations.
batch = os.path.join(work, 'batch.txt')
sftp_returned = os.path.join(work, 'sftp-returned.bin')
with open(batch, 'w') as batch_file:
    batch_file.write('pwd\nmkdir sftpdir\ncd sftpdir\nput %s first.bin\nls -l\nrename first.bin second.bin\n'
                     'get second.bin %s\nrm second.bin\ncd ..\nrmdir sftpdir\nls\n' % (original, sftp_returned))
sftp = subprocess.run(['sftp', *common, *key_options, '-i', keys['ed25519'], '-P', str(port), '-b', batch,
                       'user@127.0.0.1'], capture_output=True, timeout=300)
same = os.path.exists(sftp_returned) and open(original, 'rb').read() == open(sftp_returned, 'rb').read()
check('sftp: mkdir, cd, put, ls, rename, get, rm, rmdir',
      sftp.returncode == 0 and same and b'/home/user' in sftp.stdout and b'first.bin' in sftp.stdout, text(sftp))

# Passwords, through SSH_ASKPASS.
def password_login(user, password, command):
    askpass = os.path.join(work, 'askpass-' + user + '.sh')
    with open(askpass, 'w') as script:
        script.write('#!/bin/sh\necho "%s"\n' % password)
    os.chmod(askpass, stat.S_IRWXU)
    environment = dict(os.environ, SSH_ASKPASS=askpass, SSH_ASKPASS_REQUIRE='force', DISPLAY=':0')
    try:
        return subprocess.run(['ssh', *common, '-o', 'PreferredAuthentications=password', '-o', 'PubkeyAuthentication=no',
                               '-o', 'NumberOfPasswordPrompts=1', '-p', str(port), user + '@127.0.0.1', command],
                              capture_output=True, timeout=180, env=environment, stdin=subprocess.DEVNULL)
    except subprocess.TimeoutExpired:
        return subprocess.CompletedProcess([], -1, b'', b'timed out')


result = password_login('user', 'user', 'echo password-ok')
check('password login', result.returncode == 0 and b'password-ok' in result.stdout, text(result))
result = password_login('root', 'root', 'id -u')
check('root logs in with its password', result.returncode == 0 and result.stdout.strip() == b'0', text(result))
result = ssh(['id -u'], user='root')
check('root logs in with its key', result.returncode == 0 and result.stdout.strip() == b'0', text(result))

# Refusals.
result = ssh(['echo should-not-run'], key='wrong')
check('a key not in authorized_keys is refused',
      result.returncode == 255 and b'should-not-run' not in result.stdout and b'Permission denied' in result.stderr,
      text(result))
result = password_login('user', 'not-the-password', 'echo should-not-run')
check('a wrong password is refused',
      result.returncode == 255 and b'should-not-run' not in result.stdout and b'Permission denied' in result.stderr,
      text(result))
result = password_login('nobody', 'x', 'echo should-not-run')
check('a locked account is refused', result.returncode == 255 and b'should-not-run' not in result.stdout, text(result))

# Post-quantum key exchange: the default is mlkem768x25519-sha256 (no
# warning from OpenSSH), and it can be asked for alone.
result = ssh(['echo', 'pq-ok'], extra=['-v'])
check('the default key exchange is mlkem768x25519-sha256, without the post-quantum warning',
      result.returncode == 0 and b'kex: algorithm: mlkem768x25519-sha256' in result.stderr and
      b'post-quantum' not in result.stderr, text(result))
result = ssh(['echo', 'mlkem-ok'], extra=['-o', 'KexAlgorithms=mlkem768x25519-sha256'])
check('key exchange mlkem768x25519-sha256 forced', result.returncode == 0 and b'mlkem-ok' in result.stdout,
      text(result))


# A host side echo server for the forwarding tests.
def start_echo_server():
    listener = socket.socket()
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    listener.bind(('127.0.0.1', 0))
    listener.listen(4)

    def serve():
        while True:
            try:
                connection, _ = listener.accept()
            except OSError:
                return
            with connection:
                while True:
                    data = connection.recv(65536)
                    if not data:
                        break
                    connection.sendall(b'echo:' + data)

    import threading
    threading.Thread(target=serve, daemon=True).start()
    return listener


echo_server = start_echo_server()
echo_port = echo_server.getsockname()[1]

# -L: a local port forwarded through the guest to the host's echo server
# (the guest reaches the host as 10.0.2.2).
local_port = free_port()
forwarder = subprocess.Popen(['ssh', *common, *key_options, '-i', keys['ed25519'], '-p', str(port), '-N',
                              '-o', 'ExitOnForwardFailure=yes',
                              '-L', '%d:10.0.2.2:%d' % (local_port, echo_port), 'user@127.0.0.1'],
                             stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
echoed = b''
deadline = time.time() + 90
while time.time() < deadline and not echoed:
    try:
        with socket.create_connection(('127.0.0.1', local_port), timeout=30) as forwarded:
            forwarded.sendall(b'through -L')
            forwarded.shutdown(socket.SHUT_WR)
            while True:
                chunk = forwarded.recv(4096)
                if not chunk:
                    break
                echoed += chunk
    except OSError:
        time.sleep(1)
forwarder.terminate()
forwarder.wait(timeout=30)
check('-L: a local port forwarded to a host server through the guest', echoed == b'echo:through -L', repr(echoed))

# -R: a port of the guest forwarded back to the host's echo server.
result = ssh(['sleep 1; printf through-R | nc -N 127.0.0.1 9022'],
             extra=['-o', 'ExitOnForwardFailure=yes', '-R', '9022:127.0.0.1:%d' % echo_port])
check('-R: a guest port forwarded to a host server', result.returncode == 0 and b'echo:through-R' in result.stdout,
      text(result))
echo_server.close()

# Agent forwarding with the host's ssh-agent: the guest lists its keys,
# and the guest's own ssh logs in to the guest's sshd over loopback with
# the forwarded key.
agent = subprocess.run(['ssh-agent', '-s'], capture_output=True, text=True)
agent_environment = dict(os.environ)
for line in agent.stdout.split(';'):
    line = line.strip()
    if line.startswith('SSH_AUTH_SOCK=') or line.startswith('SSH_AGENT_PID='):
        name, value = line.split('=', 1)
        agent_environment[name] = value
subprocess.run(['ssh-add', keys['ed25519']], env=agent_environment, capture_output=True)
fingerprint = subprocess.run(['ssh-keygen', '-l', '-f', keys['ed25519'] + '.pub'], capture_output=True,
                             text=True).stdout.split()[1].encode()


def agent_ssh(arguments, timeout=180):
    command = ['ssh', *common, '-o', 'BatchMode=yes', '-o', 'PasswordAuthentication=no', '-A', '-p', str(port),
               'user@127.0.0.1', *arguments]
    try:
        return subprocess.run(command, capture_output=True, timeout=timeout, env=agent_environment,
                              stdin=subprocess.DEVNULL)
    except subprocess.TimeoutExpired:
        return subprocess.CompletedProcess(command, -1, b'', b'timed out')


result = agent_ssh(['echo $SSH_AUTH_SOCK; ssh-add -l'])
check('agent forwarding: SSH_AUTH_SOCK in the session, ssh-add -l lists the host agent\'s key',
      result.returncode == 0 and b'port:sshagent-' in result.stdout and fingerprint in result.stdout, text(result))
result = agent_ssh(['ssh -v -o BatchMode=yes -o StrictHostKeyChecking=accept-new '
                    '-o UserKnownHostsFile=/home/user/.ssh/known_hosts user@127.0.0.1 echo loopback-agent-ok'])
check('the system\'s ssh logs in to its own sshd with the forwarded agent key (mlkem768x25519)',
      result.returncode == 0 and b'loopback-agent-ok' in result.stdout and
      b'key exchange mlkem768x25519-sha256' in result.stderr, text(result))
subprocess.run(['ssh-agent', '-k'], env=agent_environment, capture_output=True)

# The system's ssh-keygen and ssh: a key made in the guest, then exec
# and a pseudo-terminal over loopback.
result = ssh(['rm -f /home/user/.ssh/id_ed25519 /home/user/.ssh/id_ed25519.pub; '
              'ssh-keygen -q -t ed25519 -N "" -C guest-key -f /home/user/.ssh/id_ed25519 && '
              'cat /home/user/.ssh/id_ed25519.pub >> /home/user/.ssh/authorized_keys && '
              'ssh-keygen -l -f /home/user/.ssh/id_ed25519 && '
              'ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new 127.0.0.1 "echo loopback-key-ok; exit 4"; '
              'echo status=$?'])
check('ssh-keygen in the guest, and the guest\'s ssh with that key over loopback (exit status passed)',
      b'guest-key (ED25519)' in result.stdout and b'loopback-key-ok' in result.stdout and b'status=4' in result.stdout,
      text(result))
result = ssh(['ssh -tt -o BatchMode=yes 127.0.0.1 "tty; stty size"'], tty=True)
check('the guest\'s ssh with a pseudo-terminal', b'/dev/pts' in result.stdout, text(result))

# A key with command= runs that command instead (SSH_ORIGINAL_COMMAND
# set), and no-pty refuses a terminal.
forced_key = os.path.join(work, 'id_forced')
subprocess.run(['ssh-keygen', '-q', '-t', 'ed25519', '-N', '', '-f', forced_key], check=True, stdin=subprocess.DEVNULL)
keys['forced'] = forced_key
with open(forced_key + '.pub') as public_file:
    forced_line = 'command="echo forced:$SSH_ORIGINAL_COMMAND",no-pty ' + public_file.read().strip()
shell("echo '" + forced_line + "' >> /home/user/.ssh/authorized_keys", 'FORCED-KEY', 60)
result = ssh(['whoami'], key='forced')
check('authorized_keys command= runs instead, with SSH_ORIGINAL_COMMAND',
      result.returncode == 0 and result.stdout.strip() == b'forced:whoami', text(result))

# keyboard-interactive: the password prompt.
askpass = os.path.join(work, 'askpass-kbd.sh')
with open(askpass, 'w') as script:
    script.write('#!/bin/sh\necho "user"\n')
os.chmod(askpass, stat.S_IRWXU)
try:
    result = subprocess.run(['ssh', *common, '-o', 'PreferredAuthentications=keyboard-interactive',
                             '-o', 'PubkeyAuthentication=no', '-p', str(port), 'user@127.0.0.1', 'echo kbd-ok'],
                            capture_output=True, timeout=180, stdin=subprocess.DEVNULL,
                            env=dict(os.environ, SSH_ASKPASS=askpass, SSH_ASKPASS_REQUIRE='force', DISPLAY=':0'))
except subprocess.TimeoutExpired:
    result = subprocess.CompletedProcess([], -1, b'', b'timed out')
check('keyboard-interactive login', result.returncode == 0 and b'kbd-ok' in result.stdout, text(result))

# Certificates: a user certificate against TrustedUserCAKeys, a host
# certificate against an @cert-authority line, a Match block, and
# client keep-alives; sshd restarted with the new configuration.
ca_key = os.path.join(work, 'ssh_ca')
subprocess.run(['ssh-keygen', '-q', '-t', 'ed25519', '-N', '', '-C', 'test-ca', '-f', ca_key], check=True,
               stdin=subprocess.DEVNULL)
certified_key = os.path.join(work, 'id_certified')
subprocess.run(['ssh-keygen', '-q', '-t', 'ecdsa', '-b', '256', '-N', '', '-f', certified_key], check=True,
               stdin=subprocess.DEVNULL)
subprocess.run(['ssh-keygen', '-q', '-s', ca_key, '-I', 'test-user', '-n', 'user', '-V', '-5m:+1h',
                certified_key + '.pub'], check=True, stdin=subprocess.DEVNULL, capture_output=True)
host_public = ssh(['cat /etc/ssh/ssh_host_ed25519_key.pub']).stdout.decode().strip()
host_public_path = os.path.join(work, 'ssh_host_ed25519_key.pub')
with open(host_public_path, 'w') as host_file:
    host_file.write(host_public + '\n')
subprocess.run(['ssh-keygen', '-q', '-s', ca_key, '-h', '-I', 'test-host', '-n', '127.0.0.1', host_public_path],
               check=True, stdin=subprocess.DEVNULL, capture_output=True)
with open(ca_key + '.pub') as ca_file:
    ca_line = ca_file.read().strip()
with open(os.path.join(work, 'ssh_host_ed25519_key-cert.pub')) as cert_file:
    host_certificate = cert_file.read().strip()
shell("echo '" + ca_line + "' > /etc/ssh/user_ca.pub", 'CA-KEY', 60)
shell("echo '" + host_certificate + "' > /etc/ssh/ssh_host_ed25519_key-cert.pub", 'HOST-CERT', 60)
for line in ('TrustedUserCAKeys /etc/ssh/user_ca.pub', 'HostCertificate /etc/ssh/ssh_host_ed25519_key-cert.pub',
             'ClientAliveInterval 2', 'Match User root', '  PasswordAuthentication no'):
    shell("echo '" + line + "' >> /etc/ssh/sshd_config", 'CONFIG', 30)
shell('sshd -t; service restart sshd', 'RESTART', 60)
deadline = time.time() + 120
while time.time() < deadline:
    if ssh(['true'], timeout=60).returncode == 0:
        break
    time.sleep(2)
result = subprocess.run(['ssh', *common, '-o', 'BatchMode=yes', '-o', 'IdentitiesOnly=yes', '-i', certified_key,
                         '-p', str(port), 'user@127.0.0.1', 'echo cert-ok'],
                        capture_output=True, timeout=180, stdin=subprocess.DEVNULL)
check('a user certificate signed by TrustedUserCAKeys logs in', result.returncode == 0 and b'cert-ok' in result.stdout,
      text(result))
known_hosts = os.path.join(work, 'known_hosts_ca')
with open(known_hosts, 'w') as known_file:
    known_file.write('@cert-authority [127.0.0.1]:%d %s\n' % (port, ca_line))
result = subprocess.run(['ssh', '-F', '/dev/null', '-o', 'StrictHostKeyChecking=yes', '-o',
                         'UserKnownHostsFile=' + known_hosts, '-o', 'HostKeyAlgorithms=ssh-ed25519-cert-v01@openssh.com',
                         *key_options, '-i', keys['ed25519'], '-p', str(port), 'user@127.0.0.1', 'echo host-cert-ok'],
                        capture_output=True, timeout=180, stdin=subprocess.DEVNULL)
check('a host certificate checked against @cert-authority', result.returncode == 0 and b'host-cert-ok' in result.stdout,
      text(result))
result = ssh(['sleep 7; echo still-here'])
check('ClientAliveInterval: keep-alives answered, an idle session stays',
      result.returncode == 0 and b'still-here' in result.stdout, text(result))
result = password_login('root', 'root', 'echo should-not-run')
check('Match User root: PasswordAuthentication no applies to root only',
      result.returncode == 255 and b'should-not-run' not in result.stdout, text(result))
result = password_login('user', 'user', 'echo match-user-ok')
check('Match User root: other users keep their passwords', result.returncode == 0 and b'match-user-ok' in result.stdout,
      text(result))

# The server's log.
log = shell('cat /var/log/sshd.log | grep -c "logged in"; ls -l /etc/ssh', 'SSHD-LOG')
check('the log tells who logged in; the host keys are made (0600)',
      'ssh_host_ed25519_key' in log and 'rw-------' in log and 'ssh_host_ecdsa_key.pub' in log, log)

qemu.kill()
qemu.wait()
with open(serial_log, 'wb') as serial_file:
    serial_file.write(received)

failed = [name for name, passed in checks if not passed]
for name, passed in checks:
    print(('ok   ' if passed else 'FAIL ') + name)
if failed:
    print('SSH TEST FAILED: %d of %d checks (serial log in %s)' % (len(failed), len(checks), serial_log))
    sys.exit(1)
print('SSH TEST PASSED: %d checks' % len(checks))
