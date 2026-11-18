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
  The SSH server's log: one line per event on standard error, which the
  service manager keeps in /var/log/sshd.log. Each line starts with
  "sshd[PROCESS]: ", the process being the listener or the one serving
  a connection. Passwords never go in.
}
unit Sshd.Log;

{$mode objfpc}{$H+}

interface

procedure LogLine(const Text: string);

implementation

uses
  SysUtils,
  Sys.Processes;

procedure LogLine(const Text: string);
begin
  WriteLn(ErrOutput, 'sshd[', CurrentProcessId, ']: ', Text);
  Flush(ErrOutput);
end;

end.
