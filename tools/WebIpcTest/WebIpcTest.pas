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
  WebIpcTest: the browser's process protocol (libwebipc) on the host:
  the wire format (every type both ways, and that a message cut short
  or claiming too much is refused), messages in pieces (lengths around
  the piece size, the header kept, handles on the first piece, pieces
  that do not fit together refused) and every typed payload both ways.

    WebIpcTest
}
program WebIpcTest;

{$mode objfpc}
{$H+}

uses
  SysUtils,
  TestChecks,
  WebIpcTest.Wire,
  WebIpcTest.Fragments,
  WebIpcTest.Payloads;

begin
  RunWireChecks;
  RunFragmentChecks;
  RunPayloadChecks;
  FinishChecks('WEB IPC TEST');
end.
