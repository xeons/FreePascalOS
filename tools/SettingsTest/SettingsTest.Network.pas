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
  The network's settings and state files on the host
  (Configuration.NetworkSettings, Configuration.NetworkState): reading
  and writing Network.settings over a storage in memory, every check
  the system settings service makes before it writes them (methods,
  addresses and prefixes, the gateway on the interface's network, DNS
  servers, the search domain), the two boxes of an address and its
  prefix or netmask, and reading a state file the network service
  writes.
}
unit SettingsTest.Network;

{$mode objfpc}
{$H+}

interface

type
  TCheckProcedure = procedure(const Name: string; Passed: Boolean);

procedure TestNetworkSettings(Check: TCheckProcedure);
procedure TestNetworkState(Check: TCheckProcedure);

implementation

uses
  SysUtils,
  Configuration.Scopes,
  Configuration.Settings,
  Configuration.NetworkSettings,
  Configuration.NetworkState,
  SettingsTest.MemoryStorage;

const
  SampleSettings =
    '# QEMU''s user networking'#10 +
    'DnsServers = ["10.0.2.3"]'#10 +
    'SearchDomain = ""'#10 +
    ''#10 +
    '[Interfaces/eth0]'#10 +
    'Method = "dhcp"'#10 +
    'Address = "10.0.2.15/24"'#10 +
    'Gateway = "10.0.2.2"'#10 +
    'Up = true'#10 +
    ''#10 +
    '[Interfaces/eth2]'#10 +
    'Address = "192.168.7.4/24"'#10 +
    'Ipv6Method = "STATIC"'#10 +
    'Ipv6Address = "fd00::7/64"'#10 +
    'Ipv6Gateway = "fe80::1"'#10 +
    ''#10 +
    '[Interfaces/eth3]'#10 +
    'Method = "none"'#10 +
    'Ipv6Method = "none"'#10;

  SampleState =
    'Method = "dhcp"'#10 +
    'State = "configured"'#10 +
    'Address = "10.0.2.15/24"'#10 +
    'Gateway = "10.0.2.2"'#10 +
    'DnsServers = ["10.0.2.3", "10.0.2.4"]'#10 +
    'Domain = "example.org"'#10 +
    'LeaseSeconds = 86400'#10 +
    'LeaseObtained = 1794268800'#10 +
    'DhcpServer = "10.0.2.2"'#10 +
    'Ipv6Method = "auto"'#10 +
    'Ipv6Addresses = ["fe80::5054:ff:fe12:3456/64", "fec0::5054:ff:fe12:3456/64"]'#10 +
    'Ipv6Gateway = "fe80::2"'#10 +
    'Ipv6DnsServers = ["fec0::3"]'#10;

function StaticSettings(const Address, Gateway: string): TInterfaceSettings;
begin
  Result := Default(TInterfaceSettings);
  Result.Name := 'eth1';
  Result.Method := NetworkMethodStatic;
  Result.Address := Address;
  Result.Gateway := Gateway;
  Result.Up := True;
end;

function DnsSettings(const Servers: array of string; const Domain: string): TDnsSettings;
var
  Index: Integer;
begin
  Result := Default(TDnsSettings);
  SetLength(Result.Servers, Length(Servers));
  for Index := 0 to High(Servers) do
    Result.Servers[Index] := Servers[Index];
  Result.SearchDomain := Domain;
end;

function StaticIpv6Settings(const Address, Gateway: string): TInterfaceSettings;
begin
  Result := StaticSettings('10.0.2.15/24', '');
  Result.Ipv6Method := Ipv6MethodStatic;
  Result.Ipv6Address := Address;
  Result.Ipv6Gateway := Gateway;
end;

procedure TestReadingAndWriting(Check: TCheckProcedure);
var
  Storage: TMemoryStorage;
  Store: TSettings;
  Settings: TInterfaceSettings;
  Dns: TDnsSettings;
  Text: string;
begin
  Storage := TMemoryStorage.Create;
  Storage.Seed('Network', SampleSettings);
  Store := TSettings.Create(nil, TSettingsScope.Create(Storage, False));

  Settings := ReadInterfaceSettings(Store, 'eth0');
  Check('network: eth0 is read', Settings.Configured and (Settings.Method = NetworkMethodDhcp) and
    (Settings.Address = '10.0.2.15/24') and (Settings.Gateway = '10.0.2.2') and Settings.Up);
  Settings := ReadInterfaceSettings(Store, 'eth2');
  Check('network: a section without a method is static (as the first network service took it)',
    Settings.Configured and (Settings.Method = NetworkMethodStatic) and Settings.Up);
  Check('network: IPv6 settings are read (method in any case)', (Settings.Ipv6Method = Ipv6MethodStatic) and
    (Settings.Ipv6Address = 'fd00::7/64') and (Settings.Ipv6Gateway = 'fe80::1'));
  Settings := ReadInterfaceSettings(Store, 'eth3');
  Check('network: IPv6 can be turned off', Settings.Ipv6Method = Ipv6MethodNone);
  Settings := ReadInterfaceSettings(Store, 'eth0');
  Check('network: a section without Ipv6Method is IPv6 auto', (Settings.Ipv6Method = Ipv6MethodAuto) and
    (Settings.Ipv6Address = ''));
  Settings := ReadInterfaceSettings(Store, 'eth1');
  Check('network: an interface without a section is left alone', not Settings.Configured and
    (Settings.Method = NetworkMethodNone) and (Settings.Ipv6Method = Ipv6MethodAuto));
  Dns := ReadDnsSettings(Store);
  Check('network: the DNS servers are read', (Length(Dns.Servers) = 1) and (Dns.Servers[0] = '10.0.2.3') and
    (Dns.SearchDomain = ''));

  Settings := StaticSettings('192.168.50.2/24', '');
  WriteInterfaceSettings(Store, Settings);
  Dns := DnsSettings([], 'example.org');
  WriteDnsSettings(Store, Dns);
  Check('network: changes are written', Store.Flush = 0);
  Text := Storage.TextOf('Network');
  Check('network: a new interface gets a section, comments stay', (Pos('[Interfaces/eth1]', Text) > 0) and
    (Pos('Method = "static"', Text) > 0) and (Pos('Address = "192.168.50.2/24"', Text) > 0) and
    (Pos('# QEMU''s user networking', Text) = 1));
  Check('network: automatic DNS servers are an empty list', (Pos('DnsServers = []', Text) > 0) and
    (Pos('SearchDomain = "example.org"', Text) > 0));

  Check('network: the IPv6 method is written', Pos('Ipv6Method = "auto"', Text) > 0);

  Settings.Ipv6Method := Ipv6MethodStatic;
  Settings.Ipv6Address := 'fd00::50/64';
  Settings.Ipv6Gateway := 'fd00::1';
  WriteInterfaceSettings(Store, Settings);
  Store.Flush;
  Settings := ReadInterfaceSettings(Store, 'eth1');
  Check('network: a static IPv6 address is written and read back', (Settings.Ipv6Method = Ipv6MethodStatic) and
    (Settings.Ipv6Address = 'fd00::50/64') and (Settings.Ipv6Gateway = 'fd00::1'));

  Settings.Method := NetworkMethodDhcp;
  Settings.Address := '';
  Settings.Ipv6Method := Ipv6MethodAuto;
  Settings.Ipv6Address := '';
  Settings.Ipv6Gateway := '';
  WriteInterfaceSettings(Store, Settings);
  Store.Flush;
  Settings := ReadInterfaceSettings(Store, 'eth1');
  Check('network: back to DHCP, an empty address removes the key', (Settings.Method = NetworkMethodDhcp) and
    (Settings.Address = '') and (Pos('192.168.50.2', Storage.TextOf('Network')) = 0));
  Check('network: back to IPv6 auto, the empty IPv6 keys go', (Settings.Ipv6Method = Ipv6MethodAuto) and
    (Pos('fd00::50', Storage.TextOf('Network')) = 0));
  Store.Free;
  Storage.Free;
end;

procedure TestIpv6Checks(Check: TCheckProcedure);
var
  Method: TIpv6Method;
  Settings: TInterfaceSettings;
begin
  Check('network: IPv6 methods are read in any case', ParseIpv6Method('AUTO', Method) and
    (Method = Ipv6MethodAuto) and ParseIpv6Method(' static', Method) and (Method = Ipv6MethodStatic) and
    ParseIpv6Method('none', Method) and (Method = Ipv6MethodNone) and not ParseIpv6Method('dhcp', Method) and
    (Ipv6MethodName(Ipv6MethodNone) = 'none'));
  Check('network: a static IPv6 address with a gateway',
    CheckInterfaceSettings(StaticIpv6Settings('fd00::10/64', 'fd00::1')) = NetworkSettingsValid);
  Check('network: a link-local IPv6 gateway is taken',
    CheckInterfaceSettings(StaticIpv6Settings('fec0::10/64', 'fe80::2')) = NetworkSettingsValid);
  Check('network: a static IPv6 address without a gateway',
    CheckInterfaceSettings(StaticIpv6Settings('2001:db8::5/128', '')) = NetworkSettingsValid);
  Check('network: static IPv6 needs an address',
    CheckInterfaceSettings(StaticIpv6Settings('', '')) = ProblemNoIpv6Address);
  Check('network: an IPv6 gateway needs an address too',
    CheckInterfaceSettings(StaticIpv6Settings('', 'fd00::1')) = ProblemNoIpv6Address);
  Check('network: an IPv6 address needs its prefix',
    (CheckInterfaceSettings(StaticIpv6Settings('fd00::10', '')) = ProblemBadIpv6Prefix) and
    (CheckInterfaceSettings(StaticIpv6Settings('fd00::10/0', '')) = ProblemBadIpv6Prefix) and
    (CheckInterfaceSettings(StaticIpv6Settings('fd00::10/129', '')) = ProblemBadIpv6Address));
  Check('network: not an IPv6 address',
    (CheckInterfaceSettings(StaticIpv6Settings('fd00:::10/64', '')) = ProblemBadIpv6Address) and
    (CheckInterfaceSettings(StaticIpv6Settings('10.0.2.15/24', '')) = ProblemBadIpv6Address));
  Check('network: ::, ::1, multicast and link-local IPv6 addresses are not hosts',
    (CheckInterfaceSettings(StaticIpv6Settings('::/64', '')) = ProblemIpv6AddressNotHost) and
    (CheckInterfaceSettings(StaticIpv6Settings('::1/128', '')) = ProblemIpv6AddressNotHost) and
    (CheckInterfaceSettings(StaticIpv6Settings('ff02::1/64', '')) = ProblemIpv6AddressNotHost) and
    (CheckInterfaceSettings(StaticIpv6Settings('fe80::5/64', '')) = ProblemIpv6AddressNotHost));
  Check('network: bad IPv6 gateways',
    (CheckInterfaceSettings(StaticIpv6Settings('fd00::10/64', 'router')) = ProblemBadIpv6Gateway) and
    (CheckInterfaceSettings(StaticIpv6Settings('fd00::10/64', '10.0.2.2')) = ProblemBadIpv6Gateway) and
    (CheckInterfaceSettings(StaticIpv6Settings('fd00::10/64', 'ff02::2')) = ProblemBadIpv6Gateway) and
    (CheckInterfaceSettings(StaticIpv6Settings('fd00::10/64', 'fd00::10')) = ProblemIpv6GatewayIsAddress));
  Settings := StaticIpv6Settings('fd00::10/64', '');
  Settings.Ipv6Method := Ipv6MethodAuto;
  Check('network: IPv6 auto keeps a valid address for later', CheckInterfaceSettings(Settings) =
    NetworkSettingsValid);
  Settings.Ipv6Method := Ipv6MethodNone;
  Settings.Ipv6Address := '';
  Check('network: IPv6 off needs no address', CheckInterfaceSettings(Settings) = NetworkSettingsValid);
  Check('network: IPv6 DNS servers', CheckDnsSettings(DnsSettings(['fec0::3', '10.0.2.3'], '')) =
    NetworkSettingsValid);
  Check('network: bad IPv6 DNS servers', (CheckDnsSettings(DnsSettings(['::'], '')) = ProblemBadDnsServer) and
    (CheckDnsSettings(DnsSettings(['ff02::fb'], '')) = ProblemBadDnsServer) and
    (CheckDnsSettings(DnsSettings(['fec0::3::1'], '')) = ProblemBadDnsServer));
end;

procedure TestChecks(Check: TCheckProcedure);
var
  Settings: TInterfaceSettings;
  Method: TNetworkMethod;
begin
  Check('network: methods are read in any case', ParseNetworkMethod('DHCP', Method) and
    (Method = NetworkMethodDhcp) and ParseNetworkMethod('static', Method) and (Method = NetworkMethodStatic) and
    ParseNetworkMethod(' none ', Method) and (Method = NetworkMethodNone));
  Check('network: an unknown method is refused', not ParseNetworkMethod('bootp', Method) and
    not ParseNetworkMethod('', Method));

  Check('network: a static address with a gateway on its network',
    CheckInterfaceSettings(StaticSettings('10.0.2.15/24', '10.0.2.2')) = NetworkSettingsValid);
  Check('network: a static address without a gateway',
    CheckInterfaceSettings(StaticSettings('192.168.50.2/24', '')) = NetworkSettingsValid);
  Check('network: static needs an address', CheckInterfaceSettings(StaticSettings('', '')) = ProblemNoAddress);
  Check('network: a gateway needs an address too', CheckInterfaceSettings(StaticSettings('', '10.0.2.2')) =
    ProblemNoAddress);
  Check('network: the prefix is needed', CheckInterfaceSettings(StaticSettings('10.0.2.15', '')) =
    ProblemBadPrefix);
  Check('network: prefixes of 0, 31 and 32 are refused',
    (CheckInterfaceSettings(StaticSettings('10.0.2.15/0', '')) = ProblemBadPrefix) and
    (CheckInterfaceSettings(StaticSettings('10.0.2.15/31', '')) = ProblemBadPrefix) and
    (CheckInterfaceSettings(StaticSettings('10.0.2.15/32', '')) = ProblemBadPrefix));
  Check('network: not an address', (CheckInterfaceSettings(StaticSettings('10.0.2/24', '')) = ProblemBadAddress) and
    (CheckInterfaceSettings(StaticSettings('10.0.2.300/24', '')) = ProblemBadAddress) and
    (CheckInterfaceSettings(StaticSettings('ten/24', '')) = ProblemBadAddress));
  Check('network: the network''s own address and broadcast are not hosts',
    (CheckInterfaceSettings(StaticSettings('10.0.2.0/24', '')) = ProblemAddressNotHost) and
    (CheckInterfaceSettings(StaticSettings('10.0.2.255/24', '')) = ProblemAddressNotHost));
  Check('network: loopback, multicast and 0.0.0.0 are not hosts',
    (CheckInterfaceSettings(StaticSettings('127.0.0.5/8', '')) = ProblemAddressNotHost) and
    (CheckInterfaceSettings(StaticSettings('224.0.0.9/24', '')) = ProblemAddressNotHost) and
    (CheckInterfaceSettings(StaticSettings('0.0.0.7/24', '')) = ProblemAddressNotHost));
  Check('network: a gateway on another network is refused',
    CheckInterfaceSettings(StaticSettings('10.0.2.15/24', '10.0.3.1')) = ProblemGatewayOutsideNetwork);
  Check('network: but on the same wider network it is taken',
    CheckInterfaceSettings(StaticSettings('10.0.2.15/16', '10.0.3.1')) = NetworkSettingsValid);
  Check('network: the gateway is not the address itself',
    CheckInterfaceSettings(StaticSettings('10.0.2.15/24', '10.0.2.15')) = ProblemGatewayIsAddress);
  Check('network: the gateway is not the broadcast',
    CheckInterfaceSettings(StaticSettings('10.0.2.15/24', '10.0.2.255')) = ProblemBadGateway);
  Check('network: a gateway that is not an address',
    CheckInterfaceSettings(StaticSettings('10.0.2.15/24', 'router')) = ProblemBadGateway);

  Settings := StaticSettings('', '');
  Settings.Method := NetworkMethodDhcp;
  Check('network: DHCP needs no address', CheckInterfaceSettings(Settings) = NetworkSettingsValid);
  Settings.Address := '10.0.2.0/24';
  Check('network: but one remembered must be valid', CheckInterfaceSettings(Settings) = ProblemAddressNotHost);
  Settings := StaticSettings('10.0.2.15/24', '');
  Settings.Name := 'eth 0';
  Check('network: an interface name that is not a name', CheckInterfaceSettings(Settings) = ProblemBadInterfaceName);
  Settings.Name := 'averyverylongname';
  Check('network: an interface name too long for the kernel', CheckInterfaceSettings(Settings) =
    ProblemBadInterfaceName);

  Check('network: DNS servers and a search domain',
    CheckDnsSettings(DnsSettings(['10.0.2.3', '8.8.8.8'], 'example.org')) = NetworkSettingsValid);
  Check('network: no DNS servers (automatic)', CheckDnsSettings(DnsSettings([], '')) = NetworkSettingsValid);
  Check('network: a DNS server that is not an address',
    (CheckDnsSettings(DnsSettings(['10.0.2.3', 'dns'], '')) = ProblemBadDnsServer) and
    (CheckDnsSettings(DnsSettings(['0.0.0.0'], '')) = ProblemBadDnsServer) and
    (CheckDnsSettings(DnsSettings(['239.1.1.1'], '')) = ProblemBadDnsServer));
  Check('network: too many DNS servers',
    CheckDnsSettings(DnsSettings(['1.1.1.1', '1.0.0.1', '8.8.8.8', '8.8.4.4', '9.9.9.9'], '')) =
    ProblemTooManyDnsServers);
  Check('network: bad search domains', (CheckDnsSettings(DnsSettings([], 'example..org')) = ProblemBadSearchDomain) and
    (CheckDnsSettings(DnsSettings([], '-example.org')) = ProblemBadSearchDomain) and
    (CheckDnsSettings(DnsSettings([], 'exa mple.org')) = ProblemBadSearchDomain) and
    (CheckDnsSettings(DnsSettings([], 'example.org.')) = ProblemBadSearchDomain));
  Check('network: good search domains', IsSearchDomain('lan') and IsSearchDomain('my-home.example.org') and
    IsSearchDomain('10x.example'));
end;

procedure TestAddressBoxes(Check: TCheckProcedure);
var
  Joined: string;
  AddressText: string;
  PrefixText: string;
  Servers: TStringArray;
begin
  Check('network: an address and a prefix', JoinAddressAndPrefix('192.168.50.2', '24', Joined) and
    (Joined = '192.168.50.2/24'));
  Check('network: an address and a netmask', JoinAddressAndPrefix(' 10.0.2.15 ', '255.255.0.0', Joined) and
    (Joined = '10.0.2.15/16'));
  Check('network: a netmask with holes is refused', not JoinAddressAndPrefix('10.0.2.15', '255.0.255.0', Joined));
  Check('network: a prefix that is not a number is refused', not JoinAddressAndPrefix('10.0.2.15', 'x', Joined) and
    not JoinAddressAndPrefix('10.0.2.15', '33', Joined) and not JoinAddressAndPrefix('', '24', Joined));
  SplitAddressAndPrefix('10.0.2.15/24', AddressText, PrefixText);
  Check('network: split into the two boxes', (AddressText = '10.0.2.15') and (PrefixText = '24'));
  SplitAddressAndPrefix('nonsense', AddressText, PrefixText);
  Check('network: nonsense splits into empty boxes', (AddressText = '') and (PrefixText = ''));
  Servers := SplitServerList(' 10.0.2.3, 8.8.8.8;9.9.9.9  1.1.1.1 ');
  Check('network: a server list as typed', (Length(Servers) = 4) and (Servers[0] = '10.0.2.3') and
    (Servers[3] = '1.1.1.1') and (JoinServerList(Servers) = '10.0.2.3, 8.8.8.8, 9.9.9.9, 1.1.1.1'));
  Check('network: an empty server list', (Length(SplitServerList('  ')) = 0) and (JoinServerList(nil) = ''));
end;

procedure TestNetworkSettings(Check: TCheckProcedure);
begin
  TestReadingAndWriting(Check);
  TestChecks(Check);
  TestIpv6Checks(Check);
  TestAddressBoxes(Check);
end;

procedure TestNetworkState(Check: TCheckProcedure);
var
  State: TInterfaceState;
begin
  Check('network state: a state file is read', ParseInterfaceState('eth0', SampleState, State) and State.Known and
    (State.Name = 'eth0') and (State.Method = NetworkMethodDhcp) and (State.Progress = ProgressConfigured) and
    (State.Address = '10.0.2.15/24') and (State.Gateway = '10.0.2.2') and (Length(State.DnsServers) = 2) and
    (State.DnsServers[1] = '10.0.2.4') and (State.Domain = 'example.org') and (State.LeaseSeconds = 86400) and
    (State.LeaseObtained = 1794268800) and (State.DhcpServer = '10.0.2.2'));
  Check('network state: the IPv6 keys are read', (State.Ipv6Method = Ipv6MethodAuto) and
    (Length(State.Ipv6Addresses) = 2) and (State.Ipv6Addresses[1] = 'fec0::5054:ff:fe12:3456/64') and
    (State.Ipv6Gateway = 'fe80::2') and (Length(State.Ipv6DnsServers) = 1) and
    (State.Ipv6DnsServers[0] = 'fec0::3'));
  Check('network state: the lease ends a lease''s length after it began', LeaseExpires(State) = 1794268800 + 86400);
  Check('network state: every state is known', (ParseInterfaceProgress('down') = ProgressDown) and
    (ParseInterfaceProgress('no-link') = ProgressNoLink) and (ParseInterfaceProgress('configuring') =
    ProgressConfiguring) and (ParseInterfaceProgress('failed') = ProgressFailed) and
    (InterfaceProgressName(ProgressNoLink) = 'no-link'));
  Check('network state: a state still configuring, without an address',
    ParseInterfaceState('eth1', 'Method = "dhcp"'#10'State = "configuring"'#10'Address = ""'#10, State) and
    (State.Progress = ProgressConfiguring) and (State.Address = '') and (LeaseExpires(State) = 0) and
    (State.Ipv6Method = Ipv6MethodAuto) and (Length(State.Ipv6Addresses) = 0));
  Check('network state: a file without a known state is not taken',
    not ParseInterfaceState('eth1', 'Method = "dhcp"'#10'State = "dreaming"'#10, State) and not State.Known and
    not ParseInterfaceState('eth1', '', State));
  Check('network state: the file''s path', InterfaceStatePath('eth0') = '/var/lib/network/eth0.state');
end;

end.
