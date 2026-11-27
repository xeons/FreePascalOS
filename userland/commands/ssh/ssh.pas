{
  FreePascalOS
  Copyright (C) 2026 Brandon Scott

  This program is free software: you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation, either version 3 of the License, or
  (at your option) any later version.

  This program is distributed in the hope that it will be useful,
  but WITHOUT ANY WARRANTY; without even the implied warranty of
  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
  GNU General Public License for more details.

  You should have received a copy of the GNU General Public License
  along with this program.  If not, see <https://www.gnu.org/licenses/>.
}

{
  ssh - the SSH client

  ssh [-AaNTtvq] [-p PORT] [-i FILE] [-l USER] [-o OPTION=VALUE]
      [-L [BIND:]PORT:HOST:HOSTPORT] [-R [BIND:]PORT:HOST:HOSTPORT]
      [-e CHAR] [USER@]HOST [COMMAND [ARGUMENT...]]

  Logs in to HOST and runs COMMAND there, or an interactive shell in a
  pseudo-terminal (the local terminal in raw mode; ~. at the start of a
  line disconnects). The key exchange is mlkem768x25519-sha256 (post-
  quantum hybrid) when the server has it, else curve25519-sha256; keys
  come from the agent (SSH_AUTH_SOCK) and ~/.ssh/id_ed25519 and
  ~/.ssh/id_ecdsa (or -i), then keyboard-interactive and the password
  are tried. The server's host key is checked against ~/.ssh/known_hosts
  (a new one is asked about). Units in userland/commands/ssh, the protocol in
  libssh. The exit status is the remote command's, 255 for an error.

    -p PORT    the server's port (22)
    -i FILE    a private key (OpenSSH format, no passphrase)
    -l USER    the user to log in as
    -o OPT=V   an option as in ssh_config (see SshClient.Options)
    -L SPEC    forward a local port to HOST:HOSTPORT through the server
    -R SPEC    forward a port of the server to HOST:HOSTPORT from here
    -A / -a    forward the agent / do not
    -N         no command (for forwarding only)
    -t / -T    a pseudo-terminal / none
    -e CHAR    the escape character (none: no escapes)
    -v         say what happens; -q: say less
}
program ssh;

{$mode objfpc}{$H+}

uses
  SysUtils,
  Util.Messages,
  SshClient.Options,
  SshClient.Session;

const
  Usage = 'usage: ssh [-AaNTtvq] [-p port] [-i identity] [-l user] [-o option=value]'#10 +
    '           [-L [bind:]port:host:hostport] [-R [bind:]port:host:hostport]'#10 +
    '           [-e char] [user@]host [command [argument ...]]'#10;

var
  Arguments: TStringArray;
  Options: TSshClientOptions;
  Problem: string;
  Index: Integer;
begin
  Arguments := nil;
  SetLength(Arguments, ParamCount);
  for Index := 1 to ParamCount do
    Arguments[Index - 1] := ParamStr(Index);
  if (Length(Arguments) = 1) and (Arguments[0] = '--help') then
  begin
    Write(Usage);
    Halt(0);
  end;
  if not ParseClientOptions(Arguments, Options, Problem) then
  begin
    WriteLn(ErrOutput, 'ssh: ', Problem);
    Write(ErrOutput, Usage);
    Halt(255);
  end;
  Halt(RunClient(Options));
end.
