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
  The network's settings, as the system keeps them in
  /etc/settings/Network.settings, read, checked and written in one
  place (the system settings service writes them; the Control Panel
  shows them; the network service applies them):

    DnsServers = ["10.0.2.3"]     the DNS servers; empty: those DHCP gives
    SearchDomain = ""             where names without a dot are looked up

    [Interfaces/eth0]
    Method = "dhcp"               "static", "dhcp" or "none"
    Address = "10.0.2.15/24"      the address and its prefix (static)
    Gateway = "10.0.2.2"          the default route through it (static)
    Up = true                     turned on

  An interface without a section is left alone (as "none"). For DHCP
  and "none" an Address and Gateway may stay in the file, remembered for
  when the interface is set static again; they must still be valid.

  Checking: a static address needs its prefix (1-30 bits), and must be
  an address of a host - not 0.0.0.0, a loopback, multicast or reserved
  address, nor its network's own address or broadcast. A gateway must be
  a host on the same network and not the address itself. DNS servers
  are host addresses too, at most MaximumDnsServers; the search domain
  is a domain name (letters, digits, hyphens and dots, labels of 1-63
  characters).
}
unit Configuration.NetworkSettings;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Configuration.Settings;

const
  NetworkSettingsGroup = 'Network';
  NetworkInterfacesSection = 'Network/Interfaces';
  DnsServersSetting = 'Network/DnsServers';
  SearchDomainSetting = 'Network/SearchDomain';
  { The longest search domain the kernel keeps (DnsDomainCapacity less
    its terminator). }
  MaximumSearchDomainLength = 63;

type
  TNetworkMethod = (NetworkMethodNone, NetworkMethodStatic, NetworkMethodDhcp);
  { auto: what routers advertise (SLAAC, and DHCPv6 when their M or O
    flag says); static: the address given; none: no IPv6 on the
    interface; dhcpv6: an address from a DHCPv6 server whatever the
    routers say (their routes and prefixes still taken). }
  TIpv6Method = (Ipv6MethodAuto, Ipv6MethodStatic, Ipv6MethodNone, Ipv6MethodDhcpv6);

  TInterfaceSettings = record
    Name: string;
    Method: TNetworkMethod;
    { "10.0.2.15/24", or empty. }
    Address: string;
    { "10.0.2.2", or empty. }
    Gateway: string;
    Up: Boolean;
    { The file has a section for it. }
    Configured: Boolean;
    Ipv6Method: TIpv6Method;
    { "fec0::10/64", or empty (kept for static only). }
    Ipv6Address: string;
    { "fec0::2" or "fe80::1", or empty. }
    Ipv6Gateway: string;
  end;

  TDnsSettings = record
    { Empty: the servers DHCP gives. }
    Servers: TStringArray;
    SearchDomain: string;
  end;

  TNetworkSettingsProblem = (NetworkSettingsValid, ProblemBadInterfaceName, ProblemNoAddress, ProblemBadAddress,
    ProblemBadPrefix, ProblemAddressNotHost, ProblemBadGateway, ProblemGatewayOutsideNetwork,
    ProblemGatewayIsAddress, ProblemBadDnsServer, ProblemTooManyDnsServers, ProblemBadSearchDomain,
    ProblemNoIpv6Address, ProblemBadIpv6Address, ProblemBadIpv6Prefix, ProblemIpv6AddressNotHost,
    ProblemBadIpv6Gateway, ProblemIpv6GatewayIsAddress);

{ "static", "dhcp", "none" (any letter case); False for anything else. }
function ParseNetworkMethod(const Text: string; out Method: TNetworkMethod): Boolean;
function NetworkMethodName(Method: TNetworkMethod): string;
{ "auto", "static", "none", "dhcpv6" (any letter case); False for
  anything else. }
function ParseIpv6Method(const Text: string; out Method: TIpv6Method): Boolean;
function Ipv6MethodName(Method: TIpv6Method): string;

{ What the settings say about interface Name (Method none, Up and
  Ipv6Method auto when it has no section). }
function ReadInterfaceSettings(Store: TSettings; const Name: string): TInterfaceSettings;
function ReadDnsSettings(Store: TSettings): TDnsSettings;
{ Write to the system's scope (the caller flushes). An empty Address,
  Gateway, Ipv6Address or Ipv6Gateway removes the key. }
procedure WriteInterfaceSettings(Store: TSettings; const Settings: TInterfaceSettings);
procedure WriteDnsSettings(Store: TSettings; const Dns: TDnsSettings);

function CheckInterfaceSettings(const Settings: TInterfaceSettings): TNetworkSettingsProblem;
function CheckDnsSettings(const Dns: TDnsSettings): TNetworkSettingsProblem;
{ A sentence saying what is wrong. }
function NetworkSettingsProblemText(Problem: TNetworkSettingsProblem): string;

{ "10.0.2.15/24": the address and its prefix (both needed). }
function ParseInterfaceAddress(const Text: string; out AddressValue: LongWord; out PrefixLength: LongWord): Boolean;
{ A dotted quad as a number (the first byte highest). }
function ParseHostAddress(const Text: string; out AddressValue: LongWord): Boolean;
{ An address and a prefix ("24") or netmask ("255.255.255.0") as typed
  in two boxes, put together: "10.0.2.15/24". False if either is not
  valid. }
function JoinAddressAndPrefix(const AddressText, PrefixText: string; out Joined: string): Boolean;
{ The other way: "10.0.2.15/24" into "10.0.2.15" and "24" (empty
  strings when Text is empty or not an address with a prefix). }
procedure SplitAddressAndPrefix(const Text: string; out AddressText, PrefixText: string);
{ Interface names are settings names (Configuration.Names) of at most
  15 characters: eth0, lo. }
function IsInterfaceName(const Name: string): Boolean;
function IsSearchDomain(const Text: string): Boolean;
{ Server texts split at commas, semicolons and spaces, empty parts left
  out: "10.0.2.3, 8.8.8.8" -> ["10.0.2.3", "8.8.8.8"]. }
function SplitServerList(const Text: string): TStringArray;
function JoinServerList(const Servers: TStringArray): string;

implementation

uses
  Abi.SystemCalls,
  Sys.InternetAddresses,
  Configuration.Names,
  Configuration.Ipv6Checks;

const
  MethodNames: array[TNetworkMethod] of string = ('none', 'static', 'dhcp');
  Ipv6MethodNames: array[TIpv6Method] of string = ('auto', 'static', 'none', 'dhcpv6');
  MaximumInterfaceNameLength = NetworkInterfaceNameCapacity - 1;
  MaximumLabelLength = 63;

function ParseNetworkMethod(const Text: string; out Method: TNetworkMethod): Boolean;
var
  Candidate: TNetworkMethod;
begin
  Method := NetworkMethodNone;
  for Candidate := Low(TNetworkMethod) to High(TNetworkMethod) do
    if LowerCase(Trim(Text)) = MethodNames[Candidate] then
    begin
      Method := Candidate;
      Exit(True);
    end;
  Result := False;
end;

function NetworkMethodName(Method: TNetworkMethod): string;
begin
  Result := MethodNames[Method];
end;

function ParseIpv6Method(const Text: string; out Method: TIpv6Method): Boolean;
var
  Candidate: TIpv6Method;
begin
  Method := Ipv6MethodAuto;
  for Candidate := Low(TIpv6Method) to High(TIpv6Method) do
    if LowerCase(Trim(Text)) = Ipv6MethodNames[Candidate] then
    begin
      Method := Candidate;
      Exit(True);
    end;
  Result := False;
end;

function Ipv6MethodName(Method: TIpv6Method): string;
begin
  Result := Ipv6MethodNames[Method];
end;

function InterfaceSection(const Name: string): string;
begin
  Result := NetworkInterfacesSection + '/' + Name;
end;

function ReadInterfaceSettings(Store: TSettings; const Name: string): TInterfaceSettings;
var
  Section: string;
  Sections: TStringArray;
  Index: Integer;
begin
  Result := Default(TInterfaceSettings);
  Result.Name := Name;
  Result.Method := NetworkMethodNone;
  Result.Up := True;
  Result.Ipv6Method := Ipv6MethodAuto;
  Sections := Store.ListSections(NetworkInterfacesSection);
  for Index := 0 to High(Sections) do
    if Sections[Index] = Name then
      Result.Configured := True;
  if not Result.Configured then
    Exit;
  Section := InterfaceSection(Name);
  { The first network service took a missing method for static. }
  if not ParseNetworkMethod(Store.ReadString(Section + '/Method', 'static'), Result.Method) then
    Result.Method := NetworkMethodNone;
  Result.Address := Trim(Store.ReadString(Section + '/Address', ''));
  Result.Gateway := Trim(Store.ReadString(Section + '/Gateway', ''));
  Result.Up := Store.ReadBoolean(Section + '/Up', True);
  if not ParseIpv6Method(Store.ReadString(Section + '/Ipv6Method', 'auto'), Result.Ipv6Method) then
    Result.Ipv6Method := Ipv6MethodAuto;
  Result.Ipv6Address := Trim(Store.ReadString(Section + '/Ipv6Address', ''));
  Result.Ipv6Gateway := Trim(Store.ReadString(Section + '/Ipv6Gateway', ''));
end;

function ReadDnsSettings(Store: TSettings): TDnsSettings;
begin
  Result := Default(TDnsSettings);
  Result.Servers := Store.ReadList(DnsServersSetting, nil);
  Result.SearchDomain := Trim(Store.ReadString(SearchDomainSetting, ''));
end;

procedure WriteOptionalString(Store: TSettings; const Path, Value: string);
begin
  if Value = '' then
    Store.Delete(Path, ScopeSystem)
  else
    Store.WriteString(Path, Value, ScopeSystem);
end;

procedure WriteInterfaceSettings(Store: TSettings; const Settings: TInterfaceSettings);
var
  Section: string;
begin
  Section := InterfaceSection(Settings.Name);
  Store.WriteString(Section + '/Method', NetworkMethodName(Settings.Method), ScopeSystem);
  WriteOptionalString(Store, Section + '/Address', Settings.Address);
  WriteOptionalString(Store, Section + '/Gateway', Settings.Gateway);
  Store.WriteBoolean(Section + '/Up', Settings.Up, ScopeSystem);
  Store.WriteString(Section + '/Ipv6Method', Ipv6MethodName(Settings.Ipv6Method), ScopeSystem);
  WriteOptionalString(Store, Section + '/Ipv6Address', Settings.Ipv6Address);
  WriteOptionalString(Store, Section + '/Ipv6Gateway', Settings.Ipv6Gateway);
end;

procedure WriteDnsSettings(Store: TSettings; const Dns: TDnsSettings);
begin
  Store.WriteList(DnsServersSetting, Dns.Servers, ScopeSystem);
  Store.WriteString(SearchDomainSetting, Dns.SearchDomain, ScopeSystem);
end;

function ParseHostAddress(const Text: string; out AddressValue: LongWord): Boolean;
var
  Address: TInternetAddress;
begin
  AddressValue := 0;
  Result := (Text <> '') and TextToIpv4Address(Text, Address);
  if Result then
    AddressValue := Ipv4AddressValue(Address);
end;

function ParseInterfaceAddress(const Text: string; out AddressValue: LongWord; out PrefixLength: LongWord): Boolean;
var
  Address: TInternetAddress;
  HasPrefix: Boolean;
begin
  AddressValue := 0;
  PrefixLength := 0;
  Result := (Text <> '') and TextToAddressWithPrefix(Text, Address, PrefixLength, HasPrefix) and HasPrefix;
  if Result then
    AddressValue := Ipv4AddressValue(Address);
end;

function NetworkMask(PrefixLength: LongWord): LongWord;
begin
  if PrefixLength = 0 then
    Result := 0
  else
    Result := LongWord(QWord($FFFFFFFF) shl (32 - PrefixLength));
end;

function HostMask(PrefixLength: LongWord): LongWord;
begin
  Result := NetworkMask(PrefixLength) xor $FFFFFFFF;
end;

{ Not 0.0.0.0/8, loopback (127/8), multicast or reserved (224 and up). }
function IsUsableHostAddress(AddressValue: LongWord): Boolean;
var
  FirstByte: LongWord;
begin
  FirstByte := AddressValue shr 24;
  Result := (FirstByte <> 0) and (FirstByte <> 127) and (FirstByte < 224);
end;

{ A host of its network: neither the network's own address (all host
  bits clear) nor its broadcast (all set). }
function IsHostOfNetwork(AddressValue, PrefixLength: LongWord): Boolean;
var
  HostBits: LongWord;
begin
  HostBits := AddressValue and HostMask(PrefixLength);
  Result := (HostBits <> 0) and (HostBits <> HostMask(PrefixLength));
end;

function CheckAddressAndGateway(const Settings: TInterfaceSettings): TNetworkSettingsProblem;
var
  AddressValue: LongWord;
  PrefixLength: LongWord;
  GatewayValue: LongWord;
  Address: TInternetAddress;
  HasPrefix: Boolean;
begin
  if Settings.Address = '' then
  begin
    if Settings.Gateway <> '' then
      Exit(ProblemNoAddress);
    Exit(NetworkSettingsValid);
  end;
  if not TextToAddressWithPrefix(Settings.Address, Address, PrefixLength, HasPrefix) then
    Exit(ProblemBadAddress);
  if not HasPrefix or (PrefixLength < 1) or (PrefixLength > 30) then
    Exit(ProblemBadPrefix);
  AddressValue := Ipv4AddressValue(Address);
  if not IsUsableHostAddress(AddressValue) or not IsHostOfNetwork(AddressValue, PrefixLength) then
    Exit(ProblemAddressNotHost);
  if Settings.Gateway = '' then
    Exit(NetworkSettingsValid);
  if not ParseHostAddress(Settings.Gateway, GatewayValue) or not IsUsableHostAddress(GatewayValue) then
    Exit(ProblemBadGateway);
  if GatewayValue = AddressValue then
    Exit(ProblemGatewayIsAddress);
  if ((GatewayValue xor AddressValue) and NetworkMask(PrefixLength)) <> 0 then
    Exit(ProblemGatewayOutsideNetwork);
  if not IsHostOfNetwork(GatewayValue, PrefixLength) then
    Exit(ProblemBadGateway);
  Result := NetworkSettingsValid;
end;

function CheckIpv6AddressAndGateway(const Settings: TInterfaceSettings): TNetworkSettingsProblem;
var
  Address: TInternetAddress;
  Gateway: TInternetAddress;
  PrefixLength: LongWord;
begin
  if Settings.Ipv6Address = '' then
  begin
    if (Settings.Ipv6Method = Ipv6MethodStatic) or (Settings.Ipv6Gateway <> '') then
      Exit(ProblemNoIpv6Address);
    Exit(NetworkSettingsValid);
  end;
  case CheckIpv6InterfaceAddress(Settings.Ipv6Address, Address, PrefixLength) of
    Ipv6AddressNotIpv6: Exit(ProblemBadIpv6Address);
    Ipv6AddressMissingPrefix, Ipv6AddressBadPrefix: Exit(ProblemBadIpv6Prefix);
    Ipv6AddressNotHost: Exit(ProblemIpv6AddressNotHost);
  end;
  if Settings.Ipv6Gateway = '' then
    Exit(NetworkSettingsValid);
  if not IsIpv6GatewayAddress(Settings.Ipv6Gateway, Gateway) then
    Exit(ProblemBadIpv6Gateway);
  if AddressesAreEqual(Gateway, Address) then
    Exit(ProblemIpv6GatewayIsAddress);
  Result := NetworkSettingsValid;
end;

function CheckInterfaceSettings(const Settings: TInterfaceSettings): TNetworkSettingsProblem;
begin
  if not IsInterfaceName(Settings.Name) then
    Exit(ProblemBadInterfaceName);
  if (Settings.Method = NetworkMethodStatic) and (Settings.Address = '') then
    Exit(ProblemNoAddress);
  Result := CheckAddressAndGateway(Settings);
  if Result = NetworkSettingsValid then
    Result := CheckIpv6AddressAndGateway(Settings);
end;

function CheckDnsSettings(const Dns: TDnsSettings): TNetworkSettingsProblem;
var
  Index: Integer;
begin
  if Length(Dns.Servers) > MaximumDnsServers then
    Exit(ProblemTooManyDnsServers);
  for Index := 0 to High(Dns.Servers) do
    if not IsDnsServerAddress(Dns.Servers[Index]) then
      Exit(ProblemBadDnsServer);
  if (Dns.SearchDomain <> '') and not IsSearchDomain(Dns.SearchDomain) then
    Exit(ProblemBadSearchDomain);
  Result := NetworkSettingsValid;
end;

function NetworkSettingsProblemText(Problem: TNetworkSettingsProblem): string;
begin
  case Problem of
    NetworkSettingsValid: Result := 'The settings are valid.';
    ProblemBadInterfaceName: Result := 'There is no such network interface.';
    ProblemNoAddress: Result := 'An address is needed (with its prefix, such as 192.168.1.10/24).';
    ProblemBadAddress: Result := 'The address is not an IPv4 address such as 192.168.1.10.';
    ProblemBadPrefix: Result := 'The prefix must be 1 to 30 (or a netmask such as 255.255.255.0).';
    ProblemAddressNotHost: Result := 'The address cannot be given to a computer (it is reserved, or its network''s own ' +
      'address or broadcast).';
    ProblemBadGateway: Result := 'The gateway is not the address of a computer.';
    ProblemGatewayOutsideNetwork: Result := 'The gateway must be on the same network as the address.';
    ProblemGatewayIsAddress: Result := 'The gateway cannot be the interface''s own address.';
    ProblemBadDnsServer: Result := 'A DNS server is not an address such as 10.0.2.3 or fec0::3.';
    ProblemTooManyDnsServers: Result := Format('At most %d DNS servers can be used.', [MaximumDnsServers]);
    ProblemBadSearchDomain: Result := 'The search domain is not a domain name such as example.org.';
    ProblemNoIpv6Address: Result := 'An IPv6 address is needed (with its prefix, such as fd00::10/64).';
    ProblemBadIpv6Address: Result := 'The IPv6 address is not an address such as fd00::10.';
    ProblemBadIpv6Prefix: Result := 'The IPv6 prefix must be 1 to 128 (such as fd00::10/64).';
    ProblemIpv6AddressNotHost: Result := 'The IPv6 address cannot be given to a computer (it is unspecified, ' +
      'loopback, multicast or link-local).';
    ProblemBadIpv6Gateway: Result := 'The IPv6 gateway is not the address of a computer.';
    ProblemIpv6GatewayIsAddress: Result := 'The IPv6 gateway cannot be the interface''s own address.';
  else
    Result := 'The settings are not valid.';
  end;
end;

function JoinAddressAndPrefix(const AddressText, PrefixText: string; out Joined: string): Boolean;
var
  AddressValue: LongWord;
  PrefixLength: LongWord;
  Number: Integer;
begin
  Joined := '';
  if not ParseHostAddress(Trim(AddressText), AddressValue) then
    Exit(False);
  if Pos('.', PrefixText) > 0 then
  begin
    if not TextToNetmask(Trim(PrefixText), PrefixLength) then
      Exit(False);
  end
  else
  begin
    if not TryStrToInt(Trim(PrefixText), Number) or (Number < 0) or (Number > 32) then
      Exit(False);
    PrefixLength := LongWord(Number);
  end;
  Joined := Trim(AddressText) + '/' + IntToStr(PrefixLength);
  Result := True;
end;

procedure SplitAddressAndPrefix(const Text: string; out AddressText, PrefixText: string);
var
  AddressValue: LongWord;
  PrefixLength: LongWord;
begin
  AddressText := '';
  PrefixText := '';
  if not ParseInterfaceAddress(Text, AddressValue, PrefixLength) then
    Exit;
  AddressText := Copy(Text, 1, Pos('/', Text) - 1);
  PrefixText := IntToStr(PrefixLength);
end;

function IsInterfaceName(const Name: string): Boolean;
begin
  Result := (Length(Name) <= MaximumInterfaceNameLength) and IsSettingsName(Name);
end;

function IsLabelCharacter(Character: Char): Boolean;
begin
  Result := Character in ['a'..'z', 'A'..'Z', '0'..'9', '-'];
end;

function IsSearchDomain(const Text: string): Boolean;
var
  Index: Integer;
  LabelLength: Integer;
begin
  if (Text = '') or (Length(Text) > MaximumSearchDomainLength) then
    Exit(False);
  LabelLength := 0;
  for Index := 1 to Length(Text) do
  begin
    if Text[Index] = '.' then
    begin
      if LabelLength = 0 then
        Exit(False);
      LabelLength := 0;
    end
    else if IsLabelCharacter(Text[Index]) then
    begin
      { A label neither starts nor ends with a hyphen. }
      if (Text[Index] = '-') and ((LabelLength = 0) or (Index = Length(Text)) or (Text[Index + 1] = '.')) then
        Exit(False);
      Inc(LabelLength);
      if LabelLength > MaximumLabelLength then
        Exit(False);
    end
    else
      Exit(False);
  end;
  Result := LabelLength > 0;
end;

function SplitServerList(const Text: string): TStringArray;
var
  Index: Integer;
  Current: string;

  procedure TakeCurrent;
  begin
    if Current = '' then
      Exit;
    SetLength(Result, Length(Result) + 1);
    Result[High(Result)] := Current;
    Current := '';
  end;

begin
  Result := nil;
  Current := '';
  for Index := 1 to Length(Text) do
    if Text[Index] in [',', ';', ' ', #9] then
      TakeCurrent
    else
      Current := Current + Text[Index];
  TakeCurrent;
end;

function JoinServerList(const Servers: TStringArray): string;
var
  Index: Integer;
begin
  Result := '';
  for Index := 0 to High(Servers) do
  begin
    if Result <> '' then
      Result := Result + ', ';
    Result := Result + Servers[Index];
  end;
end;

end.
