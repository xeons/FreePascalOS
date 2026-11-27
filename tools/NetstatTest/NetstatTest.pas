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
  NetstatTest - checks the plain logic of netstat and ss on the host
  (make netstat-test): the ports list's parser (Netstat.Services, over
  the real userland/data/etc/ports and odd lines) and ss's filters
  (Ss.Filters: states, port and address conditions, and, or, not,
  parentheses, errors).

    NetstatTest PORTS-FILE
}
program NetstatTest;

{$mode objfpc}
{$H+}

uses
  Classes,
  SysUtils,
  TestChecks,
  Sys.InternetAddresses,
  Netstat.Services,
  Ss.Filters;

function TestResolver(const Name: string; out Port: Word): Boolean;
begin
  Port := 0;
  Result := True;
  if Name = 'ssh' then
    Port := 22
  else if Name = 'http' then
    Port := 80
  else
    Result := False;
end;

procedure TestServicesText;
const
  Text = '# comment line'#10 +
    'ssh   22/tcp'#10 +
    'http  80/tcp  www  # web'#10 +
    'domain 53/udp'#10 +
    'domain 53/tcp'#10 +
    'other  22/tcp'#10 +
    'broken 70000/tcp'#10 +
    'noport tcp'#10 +
    'nonumber x/tcp'#10 +
    #9'  tabbed'#9'8080/TCP'#9'alt1 alt2'#13#10 +
    'lonely'#10;
var
  Table: TServiceTable;
  Port: Word;
begin
  Table := ParseServices(Text);
  Check(Length(Table) = 6, 'services: six good lines');
  Check(ServiceNameOf(Table, 22, 'tcp') = 'ssh', 'services: 22/tcp is ssh (the first line wins)');
  Check(ServiceNameOf(Table, 22, 'udp') = '', 'services: 22/udp has no name');
  Check(ServiceNameOf(Table, 53, 'udp') = 'domain', 'services: 53/udp is domain');
  Check(ServiceNameOf(Table, 8080, 'tcp') = 'tabbed', 'services: protocols compare without case, tabs and CR');
  Check(ServicePortOf(Table, 'www', 'tcp', Port) and (Port = 80), 'services: an alias gives its port');
  Check(ServicePortOf(Table, 'ALT2', 'tcp', Port) and (Port = 8080), 'services: the second alias, any case');
  Check(not ServicePortOf(Table, 'www', 'udp', Port), 'services: not for another protocol');
  Check(not ServicePortOf(Table, 'broken', 'tcp', Port), 'services: a port beyond 65535 is skipped');
  Check(Length(Table[1].Aliases) = 1, 'services: the comment is not an alias');
end;

procedure TestPortsFile(const Path: string);
var
  Lines: TStringList;
  Table: TServiceTable;
  Port: Word;
begin
  Lines := TStringList.Create;
  try
    Lines.LoadFromFile(Path);
    Table := ParseServices(Lines.Text);
  finally
    Lines.Free;
  end;
  Check(Length(Table) > 40, 'ports file: many entries');
  Check(ServiceNameOf(Table, 22, 'tcp') = 'ssh', 'ports file: ssh');
  Check(ServiceNameOf(Table, 80, 'tcp') = 'http', 'ports file: http');
  Check(ServiceNameOf(Table, 443, 'tcp') = 'https', 'ports file: https');
  Check(ServiceNameOf(Table, 53, 'udp') = 'domain', 'ports file: domain over UDP');
  Check(ServiceNameOf(Table, 53, 'tcp') = 'domain', 'ports file: domain over TCP');
  Check(ServiceNameOf(Table, 68, 'udp') = 'bootpc', 'ports file: bootpc');
  Check(ServicePortOf(Table, 'www', 'tcp', Port) and (Port = 80), 'ports file: www is 80');
end;

function Facts(State: TSocketState; const Local: string; LocalPort: Word; const Peer: string;
  PeerPort: Word): TSocketFacts;
begin
  Result := Default(TSocketFacts);
  Result.State := State;
  TextToAddress(Local, Result.LocalAddress);
  TextToAddress(Peer, Result.PeerAddress);
  Result.LocalPort := LocalPort;
  Result.PeerPort := PeerPort;
end;

{ Parses Words and checks the filter against Socket. }
procedure CheckFilter(const Words: array of string; constref Socket: TSocketFacts; Expected: Boolean;
  const Name: string);
var
  Filter: TSocketFilter;
  ErrorText: string;
begin
  if not ParseSocketFilter(Words, @TestResolver, Filter, ErrorText) then
  begin
    Check(False, Name + ' (parse failed: ' + ErrorText + ')');
    Exit;
  end;
  Check(ExpressionMatches(Filter.Expression, Socket) = Expected, Name);
  FreeSocketFilter(Filter);
end;

procedure CheckRefused(const Words: array of string; const Name: string);
var
  Filter: TSocketFilter;
  ErrorText: string;
begin
  Check(not ParseSocketFilter(Words, @TestResolver, Filter, ErrorText) and (ErrorText <> ''), Name);
  FreeSocketFilter(Filter);
end;

procedure TestStates;
var
  Filter: TSocketFilter;
  ErrorText: string;
  States: TSocketStates;
begin
  Check(ParseSocketFilter([], nil, Filter, ErrorText) and not Filter.HasStates and (Filter.Expression = nil),
    'filter: nothing given');
  Check(EffectiveStates(Filter, DefaultSocketStates) = DefaultSocketStates, 'filter: the defaults stay');
  Check(ParseSocketFilter(['state', 'established'], nil, Filter, ErrorText) and
    (EffectiveStates(Filter, DefaultSocketStates) = [StateEstablished]), 'filter: state established');
  Check(ParseSocketFilter(['state', 'listening', 'state', 'syn-sent'], nil, Filter, ErrorText) and
    (EffectiveStates(Filter, []) = [StateListen, StateSynSent]), 'filter: two states add up');
  Check(ParseSocketFilter(['state', 'connected', 'exclude', 'established'], nil, Filter, ErrorText) and
    not (StateEstablished in EffectiveStates(Filter, [])) and (StateCloseWait in EffectiveStates(Filter, [])) and
    not (StateListen in EffectiveStates(Filter, [])), 'filter: connected less established');
  Check(ParseSocketFilter(['exclude', 'time-wait'], nil, Filter, ErrorText) and
    (EffectiveStates(Filter, AllSocketStates) = AllSocketStates - [StateTimeWait]),
    'filter: exclude alone takes from the defaults');
  Check(StatesOfName('bucket', States) and (States = [StateSynReceived, StateTimeWait]), 'filter: bucket');
  Check(StatesOfName('synchronized', States) and not (StateSynSent in States) and (StateEstablished in States),
    'filter: synchronized');
  Check(StatesOfName('all', States) and (States = AllSocketStates), 'filter: all');
  CheckRefused(['state', 'sleeping'], 'filter: an unknown state is refused');
  CheckRefused(['state'], 'filter: a state is missing');
  Check(SocketStateName(StateEstablished) = 'ESTAB', 'state name: ESTAB');
  Check(SocketStateName(StateClosed) = 'UNCONN', 'state name: UNCONN');
  Check(SocketStateName(StateFinWait1) = 'FIN-WAIT-1', 'state name: FIN-WAIT-1');
end;

procedure TestExpressions;
var
  Ssh, Web, Six: TSocketFacts;
begin
  { Local 10.0.2.15:22 talking to 10.0.2.2:51000. }
  Ssh := Facts(StateEstablished, '10.0.2.15', 22, '10.0.2.2', 51000);
  { Local 10.0.2.15:40000 to 192.0.2.10:80. }
  Web := Facts(StateEstablished, '10.0.2.15', 40000, '192.0.2.10', 80);
  Six := Facts(StateListen, '::1', 8080, '::', 0);

  CheckFilter(['sport', '=', ':22'], Ssh, True, 'expression: sport = :22');
  CheckFilter(['sport', '=', ':22'], Web, False, 'expression: sport = :22 (not the web socket)');
  CheckFilter(['dport = :80'], Web, True, 'expression: one argument with blanks');
  CheckFilter(['dport', 'eq', '80'], Web, True, 'expression: eq and a bare number');
  CheckFilter(['sport', ':ssh'], Ssh, True, 'expression: no operator, a service name');
  CheckFilter(['dport', '=', ':http'], Web, True, 'expression: dport = :http');
  CheckFilter(['dport', '!=', ':80'], Web, False, 'expression: !=');
  CheckFilter(['sport', '>', ':1024'], Web, True, 'expression: > 1024');
  CheckFilter(['sport', 'lt', ':1024'], Ssh, True, 'expression: lt 1024');
  CheckFilter(['sport', '>=', ':22'], Ssh, True, 'expression: >= on the edge');
  CheckFilter(['sport', 'le', ':21'], Ssh, False, 'expression: le below');
  CheckFilter(['(', 'dport', '=', ':ssh', 'or', 'sport', '=', ':ssh', ')'], Ssh, True,
    'expression: parentheses and or');
  CheckFilter(['( dport = :ssh or sport = :ssh )'], Web, False, 'expression: one quoted argument');
  CheckFilter(['sport', '=', ':22', 'and', 'dst', '10.0.2.2'], Ssh, True, 'expression: and with an address');
  CheckFilter(['sport', '=', ':22', 'dst', '10.0.2.3'], Ssh, False, 'expression: juxtaposition is and');
  CheckFilter(['not', 'sport', '=', ':22'], Web, True, 'expression: not');
  CheckFilter(['!', '(', 'sport', '=', ':22', ')'], Ssh, False, 'expression: ! and parentheses');
  CheckFilter(['dst', '192.0.2.0/24'], Web, True, 'expression: a prefix');
  CheckFilter(['dst', '192.0.3.0/24'], Web, False, 'expression: another prefix');
  CheckFilter(['dst', '192.0.2.10:80'], Web, True, 'expression: an address and a port');
  CheckFilter(['dst', '192.0.2.10:81'], Web, False, 'expression: the port differs');
  CheckFilter(['src', '*:22'], Ssh, True, 'expression: any address, port 22');
  CheckFilter(['src', '10.0.2.15'], Ssh, True, 'expression: src');
  CheckFilter(['src', '::1'], Six, True, 'expression: an IPv6 address');
  CheckFilter(['src', '[::1]:8080'], Six, True, 'expression: an IPv6 address in brackets with a port');
  CheckFilter(['src', '[::1]:8081'], Six, False, 'expression: the IPv6 port differs');
  CheckFilter(['src', '10.0.2.15'], Six, False, 'expression: another family never matches');
  CheckFilter(['dst', '!=', '10.0.2.2'], Ssh, False, 'expression: dst !=');
  CheckFilter(['dport', '=', ':*'], Six, True, 'expression: any port');
  CheckFilter(['sport', '=', ':22', 'or', 'sport', '=', ':80', 'and', 'dst', '1.2.3.4'], Ssh, True,
    'expression: and binds tighter than or');
  CheckFilter(['state', 'established', 'sport', '=', ':22'], Ssh, True, 'expression: after a state');

  CheckRefused(['sport', '=', ':gopherx'], 'refused: an unknown service');
  CheckRefused(['sport', '=', ':70000'], 'refused: a port beyond 65535');
  CheckRefused(['sport', '='], 'refused: the port is missing');
  CheckRefused(['(', 'sport', '=', ':22'], 'refused: a ")" is missing');
  CheckRefused(['sport', '=', ':22', ')'], 'refused: a ")" too many');
  CheckRefused(['dst', 'nowhere'], 'refused: not an address');
  CheckRefused(['dst', '<', '10.0.0.1'], 'refused: addresses are not ordered');
  CheckRefused(['bogus'], 'refused: an unknown word');
  CheckRefused(['sport', '=', ':22', 'or'], 'refused: or at the end');
end;

begin
  if ParamCount < 1 then
  begin
    WriteLn('usage: NetstatTest PORTS-FILE');
    Halt(2);
  end;
  TestServicesText;
  TestPortsFile(ParamStr(1));
  TestStates;
  TestExpressions;
  FinishChecks('NetstatTest');
end.
