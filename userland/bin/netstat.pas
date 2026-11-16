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
  netstat - show network connections, the routing table, the interfaces
  and the protocols' statistics

  netstat [-tuwlanp] [-4|-6]
  netstat -r [-4|-6]
  netstat -i
  netstat -s [-t|-u] [-4|-6]

  In the manner of net-tools' netstat. Without -r, -i or -s it lists
  the sockets: the connected ones, the listening ones with -l, both
  with -a; TCP and UDP unless -t, -u or -w (ICMP) name some. -p adds
  the process each socket belongs to (the one that made it, or accepted
  its connection). -r is the routing table (as route -n), -i the
  interfaces with their counters, -s the counters of IP, ICMP, IPv6,
  ICMPv6, TCP and UDP. IPv6 sockets are tcp6, udp6 and icmp6, and IPv6
  routes follow IPv4's in a table of their own; -4 or -6 keeps to one
  IP version. Addresses are numeric whatever -n says, until reverse lookups
  exist; the names would come through Netstat.Names alone.

  The pieces are in userland/netstat (Netstat.*).
}
program netstat;

{$mode objfpc}
{$H+}

uses
  SysUtils,
  Sys.Streams,
  Util.CommandLine,
  Util.Messages,
  Netstat.Selection,
  Netstat.Connections,
  Netstat.Routes,
  Netstat.Interfaces,
  Netstat.Statistics;

const
  Usage = 'Usage: netstat [-tuwlanp]'#10 +
    '  or:  netstat -r'#10 +
    '  or:  netstat -i'#10 +
    '  or:  netstat -s [-t|-u]'#10 +
    'Show network connections, the routing table, the interfaces or the'#10 +
    'protocol statistics.'#10 +
    #10 +
    '  -t, --tcp          TCP sockets'#10 +
    '  -u, --udp          UDP sockets'#10 +
    '  -w, --raw          ICMP sockets'#10 +
    '  -l, --listening    only listening sockets'#10 +
    '  -a, --all          listening and connected sockets'#10 +
    '  -n, --numeric      numeric addresses and ports (always, for now)'#10 +
    '  -p, --programs     the process id and name of each socket''s owner'#10 +
    '  -r, --route        the routing table'#10 +
    '  -i, --interfaces   the interfaces and their counters'#10 +
    '  -s, --statistics   the counters of IP, ICMP, IPv6, ICMPv6, TCP and UDP'#10 +
    '  -4, --inet         IPv4 only'#10 +
    '  -6, --inet6        IPv6 only'#10;

  OptionTcp = 1;
  OptionUdp = 2;
  OptionRaw = 3;
  OptionListening = 4;
  OptionAll = 5;
  OptionNumeric = 6;
  OptionPrograms = 7;
  OptionRoute = 8;
  OptionInterfaces = 9;
  OptionStatistics = 10;
  OptionIpv4 = 11;
  OptionIpv6 = 12;

type
  TNetstatView = (ViewConnections, ViewRoutes, ViewInterfaces, ViewStatistics);

var
  Selection: TNetstatSelection;
  View: TNetstatView = ViewConnections;

procedure ChooseView(Chosen: TNetstatView);
begin
  if (View <> ViewConnections) and (View <> Chosen) then
    FailWithUsageHint('-r, -i and -s cannot be combined');
  View := Chosen;
end;

procedure ParseArguments;
var
  CommandLine: TCommandLine;
  Code: Integer;
  Value: string;
begin
  Selection := Default(TNetstatSelection);
  { No reverse lookups yet: numeric whatever is asked. }
  Selection.Numeric := True;
  CommandLine := TCommandLine.Create([
    CommandOption('t', 'tcp', False, OptionTcp),
    CommandOption('u', 'udp', False, OptionUdp),
    CommandOption('w', 'raw', False, OptionRaw),
    CommandOption('l', 'listening', False, OptionListening),
    CommandOption('a', 'all', False, OptionAll),
    CommandOption('n', 'numeric', False, OptionNumeric),
    CommandOption('p', 'programs', False, OptionPrograms),
    CommandOption('r', 'route', False, OptionRoute),
    CommandOption('i', 'interfaces', False, OptionInterfaces),
    CommandOption('s', 'statistics', False, OptionStatistics),
    CommandOption('4', 'inet', False, OptionIpv4),
    CommandOption('6', 'inet6', False, OptionIpv6)], Usage);
  while CommandLine.NextOption(Code, Value) do
    case Code of
      OptionTcp: Selection.ShowTcp := True;
      OptionUdp: Selection.ShowUdp := True;
      OptionRaw: Selection.ShowRaw := True;
      OptionListening: Selection.ListeningOnly := True;
      OptionAll: Selection.All := True;
      OptionNumeric: Selection.Numeric := True;
      OptionPrograms: Selection.ShowOwners := True;
      OptionRoute: ChooseView(ViewRoutes);
      OptionInterfaces: ChooseView(ViewInterfaces);
      OptionStatistics: ChooseView(ViewStatistics);
      OptionIpv4: Selection.ShowIpv4 := True;
      OptionIpv6: Selection.ShowIpv6 := True;
    end;
  if not Selection.ShowIpv4 and not Selection.ShowIpv6 then
  begin
    Selection.ShowIpv4 := True;
    Selection.ShowIpv6 := True;
  end;
  if CommandLine.OperandCount > 0 then
    FailWithUsageHint(Format('unexpected operand ''%s''', [CommandLine.Operands[0]]));
  if not Selection.ShowTcp and not Selection.ShowUdp and not Selection.ShowRaw then
  begin
    Selection.ShowTcp := True;
    Selection.ShowUdp := True;
  end;
  CommandLine.Free;
end;

begin
  ParseArguments;
  case View of
    ViewRoutes: ShowRoutingTable(Selection);
    ViewInterfaces: ShowInterfaceTable;
    ViewStatistics: ShowProtocolStatistics(Selection);
  else
    ShowConnections(Selection);
  end;
  FlushStream(StandardOutput);
end.
