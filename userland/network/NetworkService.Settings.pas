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
  The network's configuration, from the system's settings
  (/etc/settings/Network.settings, libconfiguration):

    HostName = "freepascalos"          the machine's node name (optional)
    DnsServers = []                    the DNS servers; empty: those DHCP
                                       gives (a list overrides DHCP's)
    SearchDomain = ""                  where names without a dot are looked
                                       up (else the domain DHCP gives)

    [Interfaces/eth0]
    Method = "dhcp"                    dhcp, static or none (a section
                                       without Method is static)
    Address = "10.0.2.15/24"           static: the address and its prefix
    Gateway = "10.0.2.2"               static: the default route through it
    Up = true                          false: turned off (a lease given
                                       back first)
    Ipv6Method = "auto"                auto, static or none (IPv6 off)
    Ipv6Address = "fec0::10/64"        static: an IPv6 address and prefix
    Ipv6Gateway = "fec0::2"            static: the IPv6 default route

  Address and Gateway are read only for static (the Control Panel keeps
  them for a switch back), Ipv6Address and Ipv6Gateway likewise only for
  Ipv6Method static (NetworkService.Ipv6Settings). An interface without
  a section is left alone for IPv4 (Method none, Up true) and is auto
  for IPv6. The file
  is read whole each time it changes (ReadNetworkSettings); what does
  not make sense is reported in the interface's Problem and that
  interface is not configured.
}
unit NetworkService.Settings;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Sys.InternetAddresses,
  NetworkService.Ipv6Settings;

type
  TAddressMethod = (MethodNone, MethodStatic, MethodDhcp);

  TInterfaceSettings = record
    Name: string;
    Method: TAddressMethod;
    { Static: the address (HasAddress False: none given). }
    HasAddress: Boolean;
    Address: TInternetAddress;
    PrefixLength: LongWord;
    HasGateway: Boolean;
    Gateway: TInternetAddress;
    Up: Boolean;
    { Not empty: the section cannot be applied, and says why. }
    Problem: string;
    { Applied apart from the rest: a change to it leaves a lease alone. }
    Ipv6: TIpv6Settings;
  end;

  TNetworkSettings = record
    Interfaces: array of TInterfaceSettings;
    DnsServers: array of TInternetAddress;
    SearchDomain: string;
    HostName: string;
    { Lines about values that were left out. }
    Problems: TStringArray;
  end;

function ReadNetworkSettings: TNetworkSettings;
{ The settings of the interface Name: its section's, or Method none
  (and IPv6 auto). }
function InterfaceSettingsOf(constref Settings: TNetworkSettings; const Name: string): TInterfaceSettings;
{ The same IPv4 settings (Ipv6 is compared with SameIpv6Settings). }
function SameInterfaceSettings(constref First, Second: TInterfaceSettings): Boolean;
function AddressMethodName(Method: TAddressMethod): string;

implementation

uses
  Configuration.Settings,
  Configuration.Locations;

const
  InterfacesSection = 'Network/Interfaces';
  DnsServersSetting = 'Network/DnsServers';
  SearchDomainSetting = 'Network/SearchDomain';
  HostNameSetting = 'Network/HostName';
  DefaultPrefixLength = 24;

function AddressMethodName(Method: TAddressMethod): string;
begin
  case Method of
    MethodStatic: Result := 'static';
    MethodDhcp: Result := 'dhcp';
  else
    Result := 'none';
  end;
end;

function DefaultInterfaceSettings(const Name: string): TInterfaceSettings;
begin
  Result.Name := Name;
  Result.Method := MethodNone;
  Result.HasAddress := False;
  Result.Address := AnyIpv4Address;
  Result.PrefixLength := 0;
  Result.HasGateway := False;
  Result.Gateway := AnyIpv4Address;
  Result.Up := True;
  Result.Problem := '';
  Result.Ipv6 := DefaultIpv6Settings;
end;

procedure ReadStaticAddress(Store: TSettings; const Section: string; var Entry: TInterfaceSettings);
var
  AddressText: string;
  GatewayText: string;
  HasPrefix: Boolean;
begin
  AddressText := Store.ReadString(Section + '/Address', '');
  if AddressText <> '' then
  begin
    if not ParseAddressWithPrefix(PChar(AddressText), Entry.Address, Entry.PrefixLength, HasPrefix) then
    begin
      Entry.Problem := 'the address "' + AddressText + '" is not an address with a prefix';
      Exit;
    end;
    if not HasPrefix then
      Entry.PrefixLength := DefaultPrefixLength;
    Entry.HasAddress := True;
  end;
  GatewayText := Store.ReadString(Section + '/Gateway', '');
  if GatewayText <> '' then
  begin
    if not ParseIpv4Address(PChar(GatewayText), Entry.Gateway) then
    begin
      Entry.Problem := 'the gateway "' + GatewayText + '" is not an address';
      Exit;
    end;
    Entry.HasGateway := True;
  end;
end;

function ReadInterface(Store: TSettings; const Name: string): TInterfaceSettings;
var
  Section: string;
  MethodText: string;
begin
  Result := DefaultInterfaceSettings(Name);
  Section := InterfacesSection + '/' + Name;
  { A section without a Method is static, as it was before DHCP. }
  MethodText := LowerCase(Store.ReadString(Section + '/Method', 'static'));
  Result.Up := Store.ReadBoolean(Section + '/Up', True);
  Result.Ipv6 := ReadIpv6Settings(Store, Section);
  if MethodText = 'static' then
  begin
    Result.Method := MethodStatic;
    ReadStaticAddress(Store, Section, Result);
  end
  else if MethodText = 'dhcp' then
    Result.Method := MethodDhcp
  else if MethodText <> 'none' then
    Result.Problem := 'the method "' + MethodText + '" is not one (dhcp, static or none)';
end;

procedure ReadDnsServers(Store: TSettings; var Settings: TNetworkSettings);
var
  Names: TStringArray;
  Index: Integer;
  Address: TInternetAddress;
begin
  Names := Store.ReadList(DnsServersSetting, nil);
  Settings.DnsServers := nil;
  for Index := 0 to High(Names) do
    if ParseInternetAddress(PChar(Names[Index]), Address) then
    begin
      SetLength(Settings.DnsServers, Length(Settings.DnsServers) + 1);
      Settings.DnsServers[High(Settings.DnsServers)] := Address;
    end
    else
    begin
      SetLength(Settings.Problems, Length(Settings.Problems) + 1);
      Settings.Problems[High(Settings.Problems)] := 'the DNS server "' + Names[Index] + '" is not an address';
    end;
end;

function ReadNetworkSettings: TNetworkSettings;
var
  Store: TSettings;
  Names: TStringArray;
  Index: Integer;
begin
  Result.Interfaces := nil;
  Result.Problems := nil;
  Store := OpenSystemSettings;
  try
    Names := Store.ListSections(InterfacesSection);
    SetLength(Result.Interfaces, Length(Names));
    for Index := 0 to High(Names) do
      Result.Interfaces[Index] := ReadInterface(Store, Names[Index]);
    ReadDnsServers(Store, Result);
    Result.SearchDomain := Store.ReadString(SearchDomainSetting, '');
    Result.HostName := Store.ReadString(HostNameSetting, '');
  finally
    Store.Free;
  end;
end;

function InterfaceSettingsOf(constref Settings: TNetworkSettings; const Name: string): TInterfaceSettings;
var
  Index: Integer;
begin
  for Index := 0 to High(Settings.Interfaces) do
    if Settings.Interfaces[Index].Name = Name then
      Exit(Settings.Interfaces[Index]);
  Result := DefaultInterfaceSettings(Name);
end;

function SameInterfaceSettings(constref First, Second: TInterfaceSettings): Boolean;
begin
  Result := (First.Name = Second.Name) and (First.Method = Second.Method) and
    (First.HasAddress = Second.HasAddress) and AddressesAreEqual(First.Address, Second.Address) and
    (First.PrefixLength = Second.PrefixLength) and (First.HasGateway = Second.HasGateway) and
    AddressesAreEqual(First.Gateway, Second.Gateway) and (First.Up = Second.Up) and
    (First.Problem = Second.Problem);
end;

end.
