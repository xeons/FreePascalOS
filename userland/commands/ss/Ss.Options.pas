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
  What ss was asked to show, and how.
}
unit Ss.Options;

{$mode objfpc}
{$H+}

interface

uses
  Ss.Filters;

type
  TSsOptions = record
    { -t, -u, -w (ICMP: ss's "raw"), -x (local sockets: there are none);
      none given: all of them. }
    ShowTcp: Boolean;
    ShowUdp: Boolean;
    ShowRaw: Boolean;
    ShowLocal: Boolean;
    { -l, -a; neither: connected sockets only. }
    ListeningOnly: Boolean;
    All: Boolean;
    { -n: ports as numbers; -r: hosts by name. }
    Numeric: Boolean;
    ResolveHosts: Boolean;
    { -p: the owning process; -e: more about each socket; -i: TCP's
      internals (the kernel keeps none to show yet). }
    ShowProcesses: Boolean;
    Extended: Boolean;
    ShowInternals: Boolean;
    { -4, -6; neither: both. }
    ShowIpv4: Boolean;
    ShowIpv6: Boolean;
    { -s: counts instead of sockets. }
    Summary: Boolean;
    { -H: no header line. }
    NoHeader: Boolean;
    Filter: TSocketFilter;
  end;

implementation

end.
