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
  ss - show sockets

  ss [-tuwxlanrpeiH46s] [ state STATE | exclude STATE ]... [ EXPRESSION ]

  In the manner of iproute2's ss: the connected sockets (-l the
  listening and unconnected ones, -a all of them), of every kind unless
  -t, -u, -w (ICMP) or -x (local sockets, of which there are none yet)
  name some; ports by name unless -n, hosts by name with -r; -p the
  owning process, -e the owner's user id; -s counts. The filter picks
  sockets by state and by "sport = :22", "dport != :http", "src
  10.0.0.0/8", "dst [::1]" joined with and, or, not and parentheses
  (Ss.Filters). The kernel keeps no TCP internals (window, round trip
  time) to show, so -i adds nothing yet.

  The sockets come from the kernel's list as netstat's do; names come
  through Netstat.Names (userland/commands/netstat). The units are in
  userland/commands/ss.
}
program ss;

{$mode objfpc}
{$H+}

uses
  SysUtils,
  Abi.SystemCalls,
  Sys.NetworkInterfaces,
  Sys.Streams,
  Util.CommandLine,
  Util.Messages,
  Netstat.Names,
  Ss.Filters,
  Ss.Options,
  Ss.Sockets,
  Ss.Summary,
  Ss.Table;

const
  Usage = 'Usage: ss [OPTION]... [ state STATE | exclude STATE ]... [ FILTER ]'#10 +
    'Show sockets.'#10 +
    #10 +
    '  -t, --tcp          TCP sockets'#10 +
    '  -u, --udp          UDP sockets'#10 +
    '  -w, --raw          ICMP sockets'#10 +
    '  -x, --unix         local sockets (there are none yet)'#10 +
    '  -l, --listening    only listening (and unconnected) sockets'#10 +
    '  -a, --all          sockets in every state'#10 +
    '  -n, --numeric      ports as numbers'#10 +
    '  -r, --resolve      hosts by name'#10 +
    '  -p, --processes    the process each socket belongs to'#10 +
    '  -e, --extended     the user id of each socket''s owner'#10 +
    '  -i, --info         TCP internals (the kernel keeps none to show yet)'#10 +
    '  -H, --no-header    no header line'#10 +
    '  -4, --ipv4         IPv4 only'#10 +
    '  -6, --ipv6         IPv6 only'#10 +
    '  -s, --summary      count the sockets'#10 +
    #10 +
    'STATE: established, syn-sent, syn-recv, fin-wait-1, fin-wait-2, time-wait,'#10 +
    'closed, close-wait, last-ack, listening, closing, or all, connected,'#10 +
    'synchronized, bucket, big.'#10 +
    'FILTER: sport OP PORT, dport OP PORT (OP: = != < > <= >=; PORT :22 or :ssh),'#10 +
    'src ADDRESS[/N][:PORT], dst ADDRESS[/N][:PORT], joined by and, or, not, ( ).'#10;

  OptionTcp = 1;
  OptionUdp = 2;
  OptionRaw = 3;
  OptionLocal = 4;
  OptionListening = 5;
  OptionAll = 6;
  OptionNumeric = 7;
  OptionResolve = 8;
  OptionProcesses = 9;
  OptionExtended = 10;
  OptionInfo = 11;
  OptionNoHeader = 12;
  OptionIpv4 = 13;
  OptionIpv6 = 14;
  OptionSummary = 15;

{ Port names in filters, as TCP's (the lists hardly differ). }
function ResolvePortName(const Name: string; out Port: Word): Boolean;
begin
  Result := LookUpServicePort(Name, ProtocolTcp, Port) or
    LookUpServicePort(Name, ProtocolUdp, Port);
end;

procedure ParseArguments(out Options: TSsOptions);
var
  CommandLine: TCommandLine;
  Code: Integer;
  Value: string;
  ErrorText: string;
begin
  Options := Default(TSsOptions);
  CommandLine := TCommandLine.Create([
    CommandOption('t', 'tcp', False, OptionTcp),
    CommandOption('u', 'udp', False, OptionUdp),
    CommandOption('w', 'raw', False, OptionRaw),
    CommandOption('x', 'unix', False, OptionLocal),
    CommandOption('l', 'listening', False, OptionListening),
    CommandOption('a', 'all', False, OptionAll),
    CommandOption('n', 'numeric', False, OptionNumeric),
    CommandOption('r', 'resolve', False, OptionResolve),
    CommandOption('p', 'processes', False, OptionProcesses),
    CommandOption('e', 'extended', False, OptionExtended),
    CommandOption('i', 'info', False, OptionInfo),
    CommandOption('H', 'no-header', False, OptionNoHeader),
    CommandOption('4', 'ipv4', False, OptionIpv4),
    CommandOption('6', 'ipv6', False, OptionIpv6),
    CommandOption('s', 'summary', False, OptionSummary)], Usage);
  while CommandLine.NextOption(Code, Value) do
    case Code of
      OptionTcp: Options.ShowTcp := True;
      OptionUdp: Options.ShowUdp := True;
      OptionRaw: Options.ShowRaw := True;
      OptionLocal: Options.ShowLocal := True;
      OptionListening: Options.ListeningOnly := True;
      OptionAll: Options.All := True;
      OptionNumeric: Options.Numeric := True;
      OptionResolve: Options.ResolveHosts := True;
      OptionProcesses: Options.ShowProcesses := True;
      OptionExtended: Options.Extended := True;
      OptionInfo: Options.ShowInternals := True;
      OptionNoHeader: Options.NoHeader := True;
      OptionIpv4: Options.ShowIpv4 := True;
      OptionIpv6: Options.ShowIpv6 := True;
      OptionSummary: Options.Summary := True;
    end;
  if not Options.ShowIpv4 and not Options.ShowIpv6 then
  begin
    Options.ShowIpv4 := True;
    Options.ShowIpv6 := True;
  end;
  if not Options.ShowTcp and not Options.ShowUdp and not Options.ShowRaw and not Options.ShowLocal then
  begin
    Options.ShowTcp := True;
    Options.ShowUdp := True;
    Options.ShowRaw := True;
    Options.ShowLocal := True;
  end;
  if not ParseSocketFilter(CommandLine.Operands, @ResolvePortName, Options.Filter, ErrorText) then
    FailWithUsageHint(ErrorText);
  CommandLine.Free;
end;

var
  Options: TSsOptions;
  Entries: TSocketInformationList;
  Error: LongInt;
begin
  ParseArguments(Options);
  Error := ListSockets(Entries);
  if Error <> 0 then
    FailWithError(1, Error, 'cannot read the list of sockets');
  if Options.Summary then
    ShowSocketSummary(Entries)
  else
    ShowSocketTable(SelectSockets(Entries, Options), Options);
  FreeSocketFilter(Options.Filter);
  FlushStream(StandardOutput);
end.
