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
control = os.path.join(work, 'control')
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
