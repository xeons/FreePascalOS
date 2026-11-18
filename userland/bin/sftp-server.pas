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
  sftp-server - the SFTP subsystem of the SSH server

  sftp-server

  Speaks SFTP version 3 on its standard input and output, as the user
  it runs as: sshd starts it for "subsystem sftp", which OpenSSH's sftp
  and (since OpenSSH 9) scp ask for. Units in userland/sftp-server.
}
program sftp_server;

{$mode objfpc}{$H+}

uses
  Sftp.Server;

begin
  Halt(RunSftpServer);
end.
