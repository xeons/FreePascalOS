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
  What netstat was asked to show: which protocols, which sockets, and
  how.
}
unit Netstat.Selection;

{$mode objfpc}

interface

type
  TNetstatSelection = record
    { -t, -u, -w; none of them given: TCP and UDP. }
    ShowTcp: Boolean;
    ShowUdp: Boolean;
    ShowRaw: Boolean;
    { -l: listening sockets only; -a: listening and connected. Neither:
      connected only. }
    ListeningOnly: Boolean;
    All: Boolean;
    { -n: addresses and ports as numbers. }
    Numeric: Boolean;
    { -p: the process each socket belongs to. }
    ShowOwners: Boolean;
  end;

implementation

end.
