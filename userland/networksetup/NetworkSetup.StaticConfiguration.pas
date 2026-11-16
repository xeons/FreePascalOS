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
  The static network configuration, from the system's settings
  (/etc/settings/Network.settings, libconfiguration):

    DnsServers = ["10.0.2.3"]          the DNS servers, for the resolver
    SearchDomain = ""                  where names without a dot are looked up

    [Interfaces/eth0]
    Method = "static"                  static (this unit), or none; dhcp
                                       comes with the DHCP client
    Address = "10.0.2.15/24"           the address and its prefix
    Gateway = "10.0.2.2"               the default route through it
    Up = true                          turned on

  Each interface named under Interfaces is set up as its section says;
  one that does not exist is left out with a message. This is the piece
  a DHCP client replaces for interfaces whose Method is dhcp.
}
unit NetworkSetup.StaticConfiguration;

{$mode objfpc}
{$H+}

interface

{ Applies the configuration; returns the number of problems (0: all of
  it applied). }
function ApplyStaticConfiguration: Integer;

implementation

uses
  SysUtils,
  Abi.SystemCalls,
  Sys.Errors,
  Sys.InternetAddresses,
  Sys.NetworkInterfaces,
  Configuration.Settings,
  Configuration.Locations;

const
  InterfacesSection = 'Network/Interfaces';
  DnsServersSetting = 'Network/DnsServers';
  SearchDomainSetting = 'Network/SearchDomain';

var
  Problems: Integer;

procedure Say(const Text: string);
begin
  WriteLn('networksetup: ', Text);
end;

procedure Complain(const Text: string);
begin
  Say(Text);
  Inc(Problems);
end;

function ErrorText(Error: LongInt): string;
begin
  Result := string(ErrorMessage(Error));
end;

procedure AddDefaultRoute(const Name, GatewayText: string; Metric: LongWord);
var
  Gateway: TInternetAddress;
  Error: LongInt;
begin
  if not ParseIpv4Address(PChar(GatewayText), Gateway) then
  begin
    Complain(Name + ': the gateway "' + GatewayText + '" is not an address');
    Exit;
  end;
  { One left from before is replaced. }
  RemoveRoute(AnyIpv4Address, 0, Gateway);
  Error := AddRoute(AnyIpv4Address, 0, Gateway, PChar(Name), Metric);
  if Error <> ErrorNone then
    Complain(Name + ': default route through ' + GatewayText + ': ' + ErrorText(Error))
  else
    Say(Name + ': default route through ' + GatewayText);
end;

procedure ConfigureStatically(Store: TSettings; const Name: string; Metric: LongWord);
var
  Section: string;
  AddressText: string;
  GatewayText: string;
  Address: TInternetAddress;
  PrefixLength: LongWord;
  HasPrefix: Boolean;
  Error: LongInt;
begin
  Section := InterfacesSection + '/' + Name;
  AddressText := Store.ReadString(Section + '/Address', '');
  if AddressText <> '' then
  begin
    if not ParseAddressWithPrefix(PChar(AddressText), Address, PrefixLength, HasPrefix) then
    begin
      Complain(Name + ': "' + AddressText + '" is not an address with a prefix');
      Exit;
    end;
    if not HasPrefix then
      PrefixLength := 24;
    Error := SetInterfaceAddress(PChar(Name), Address, PrefixLength);
    if Error <> ErrorNone then
    begin
      Complain(Name + ': address ' + AddressText + ': ' + ErrorText(Error));
      Exit;
    end;
    Say(Name + ': address ' + AddressText);
  end;
  Error := SetInterfaceUp(PChar(Name), Store.ReadBoolean(Section + '/Up', True));
  if Error <> ErrorNone then
    Complain(Name + ': ' + ErrorText(Error));
  GatewayText := Store.ReadString(Section + '/Gateway', '');
  if GatewayText <> '' then
    AddDefaultRoute(Name, GatewayText, Metric);
end;

procedure ConfigureInterface(Store: TSettings; const Name: string; Metric: LongWord);
var
  Description: TAbiNetworkInterface;
  Method: string;
begin
  if not FindNetworkInterface(PChar(Name), Description) then
  begin
    Say(Name + ': no such interface, left out');
    Exit;
  end;
  Method := LowerCase(Store.ReadString(InterfacesSection + '/' + Name + '/Method', 'static'));
  if Method = 'static' then
    ConfigureStatically(Store, Name, Metric)
  else if Method = 'none' then
    Say(Name + ': not configured (Method = none)')
  else
    Complain(Name + ': the method "' + Method + '" is not available');
end;

procedure ApplyDnsServers(Store: TSettings);
var
  Names: TStringArray;
  Servers: TAbiDnsServers;
  Address: TInternetAddress;
  Index: Integer;
  Domain: string;
  Listed: string;
  Error: LongInt;
begin
  Names := Store.ReadList(DnsServersSetting, nil);
  Domain := Store.ReadString(SearchDomainSetting, '');
  FillChar(Servers, SizeOf(Servers), 0);
  for Index := 0 to High(Names) do
  begin
    if Servers.Count >= MaximumDnsServers then
    begin
      Complain('more than ' + IntToStr(MaximumDnsServers) + ' DNS servers: the rest are left out');
      Break;
    end;
    if not ParseIpv4Address(PChar(Names[Index]), Address) then
    begin
      Complain('the DNS server "' + Names[Index] + '" is not an address');
      Continue;
    end;
    Servers.Servers[Servers.Count] := MakeSocketAddress(Address, 53);
    Inc(Servers.Count);
  end;
  if Length(Domain) >= DnsDomainCapacity then
    Domain := Copy(Domain, 1, DnsDomainCapacity - 1);
  if Domain <> '' then
    Move(Domain[1], Servers.SearchDomain[0], Length(Domain));
  Error := SetDnsServers(Servers);
  if Error <> ErrorNone then
    Complain('DNS servers: ' + ErrorText(Error))
  else if Servers.Count > 0 then
  begin
    Listed := '';
    for Index := 0 to High(Names) do
    begin
      if Listed <> '' then
        Listed := Listed + ', ';
      Listed := Listed + Names[Index];
    end;
    Say('DNS servers: ' + Listed);
  end;
end;

function ApplyStaticConfiguration: Integer;
var
  Store: TSettings;
  Names: TStringArray;
  Index: Integer;
begin
  Problems := 0;
  Store := OpenSystemSettings;
  try
    Names := Store.ListSections(InterfacesSection);
    if Length(Names) = 0 then
      Say('no interfaces are configured in /etc/settings/Network.settings');
    for Index := 0 to High(Names) do
      ConfigureInterface(Store, Names[Index], LongWord(Index));
    ApplyDnsServers(Store);
  finally
    Store.Free;
  end;
  Result := Problems;
end;

end.
