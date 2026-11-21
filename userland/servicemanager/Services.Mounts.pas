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
  The mounts of /etc/fstab, made by the first service manager before any
  service starts (a memory volume on /tmp, by default). What happened
  to each goes to the manager's log and the console.
}
unit Services.Mounts;

{$mode objfpc}
{$H+}

interface

procedure MountFileSystems;

implementation

uses
  Sys.MountTable,
  Sys.MountAll,
  Services.Logs;

procedure MountFileSystems;
var
  Messages: TMountMessages;
  Message: string;
begin
  MountAllFromTable(MountTablePath, Messages);
  for Message in Messages do
    Say(Message);
end;

end.
