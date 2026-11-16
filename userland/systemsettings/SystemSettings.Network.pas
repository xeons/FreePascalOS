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
  The network's settings, changed for an administrator: an interface's
  method, address, gateway and whether it is on; the DNS servers and the
  search domain. Everything is checked here, whatever the program that
  asks has checked already (Configuration.NetworkSettings: the method's
  name, the address and its prefix, the gateway on the interface's
  network, the DNS servers' addresses), and the interface must be one
  the kernel has (not loopback). What passes is written to
  /etc/settings/Network.settings; the network service watches the file
  and applies it, so nothing is set in the kernel here.
}
unit SystemSettings.Network;

{$mode objfpc}
{$H+}

interface

uses
  Sys.SystemSettings;

function SetNetworkInterface(const Request: TSystemSettingsRequest): LongInt;
function SetDnsServers(const Request: TSystemSettingsRequest): LongInt;

implementation

uses
  SysUtils,
  Abi.SystemCalls,
  Sys.NetworkInterfaces,
  Configuration.Settings,
  Configuration.Locations,
  Configuration.NetworkSettings,
  SystemSettings.Report;

function TextOf(const Field: array of Char): string;
begin
  Result := Trim(string(PChar(@Field[0])));
end;

{ An interface of the kernel's that is not loopback. }
function IsConfigurableInterface(const Name: string): Boolean;
var
  Description: TAbiNetworkInterface;
begin
  Result := IsInterfaceName(Name) and FindNetworkInterface(PChar(Name), Description) and
    ((Description.Flags and InterfaceFlagLoopback) = 0);
end;

function WriteSettings(const Settings: TInterfaceSettings): LongInt;
var
  Store: TSettings;
begin
  Store := OpenSystemSettings;
  WriteInterfaceSettings(Store, Settings);
  Result := Store.Flush;
  Store.Free;
end;

{ The IPv6 fields of the request; with no method given, those the file
  has now. False for a method that is not one. }
function TakeIpv6Fields(const Request: TSystemSettingsRequest; var Settings: TInterfaceSettings): Boolean;
var
  Store: TSettings;
  Current: TInterfaceSettings;
begin
  if TextOf(Request.NetworkIpv6Method) = '' then
  begin
    Store := OpenSystemSettings;
    Current := ReadInterfaceSettings(Store, Settings.Name);
    Store.Free;
    Settings.Ipv6Method := Current.Ipv6Method;
    Settings.Ipv6Address := Current.Ipv6Address;
    Settings.Ipv6Gateway := Current.Ipv6Gateway;
    Exit(True);
  end;
  Result := ParseIpv6Method(TextOf(Request.NetworkIpv6Method), Settings.Ipv6Method);
  Settings.Ipv6Address := TextOf(Request.NetworkIpv6Address);
  Settings.Ipv6Gateway := TextOf(Request.NetworkIpv6Gateway);
end;

function Ipv6Summary(const Settings: TInterfaceSettings): string;
begin
  Result := 'IPv6 ' + Ipv6MethodName(Settings.Ipv6Method);
  if Settings.Ipv6Address <> '' then
    Result := Result + ' ' + Settings.Ipv6Address;
  if Settings.Ipv6Gateway <> '' then
    Result := Result + ' via ' + Settings.Ipv6Gateway;
end;

function SetNetworkInterface(const Request: TSystemSettingsRequest): LongInt;
var
  Settings: TInterfaceSettings;
  Problem: TNetworkSettingsProblem;
begin
  Settings := Default(TInterfaceSettings);
  Settings.Name := TextOf(Request.NetworkInterface);
  if not ParseNetworkMethod(TextOf(Request.NetworkMethod), Settings.Method) then
    Exit(ErrorInvalidArgument);
  Settings.Address := TextOf(Request.NetworkAddress);
  Settings.Gateway := TextOf(Request.NetworkGateway);
  Settings.Up := (Request.Flags and SystemFlagInterfaceUp) <> 0;
  Settings.Configured := True;
  if not IsConfigurableInterface(Settings.Name) then
    Exit(ErrorNotFound);
  if not TakeIpv6Fields(Request, Settings) then
    Exit(ErrorInvalidArgument);
  Problem := CheckInterfaceSettings(Settings);
  if Problem <> NetworkSettingsValid then
  begin
    Say(Settings.Name + ': refused: ' + NetworkSettingsProblemText(Problem));
    Exit(ErrorInvalidArgument);
  end;
  Result := WriteSettings(Settings);
  if Result = ErrorNone then
    Say(Format('network interface %s: %s %s%s, %s, %s', [Settings.Name, NetworkMethodName(Settings.Method),
      Settings.Address, BoolToStr(Settings.Gateway <> '', ' via ' + Settings.Gateway, ''),
      BoolToStr(Settings.Up, 'up', 'down'), Ipv6Summary(Settings)]));
end;

function SetDnsServers(const Request: TSystemSettingsRequest): LongInt;
var
  Dns: TDnsSettings;
  Problem: TNetworkSettingsProblem;
  Store: TSettings;
begin
  Dns := Default(TDnsSettings);
  Dns.Servers := SplitServerList(TextOf(Request.Text));
  Dns.SearchDomain := TextOf(Request.SearchDomain);
  Problem := CheckDnsSettings(Dns);
  if Problem <> NetworkSettingsValid then
  begin
    Say('DNS servers refused: ' + NetworkSettingsProblemText(Problem));
    Exit(ErrorInvalidArgument);
  end;
  Store := OpenSystemSettings;
  WriteDnsSettings(Store, Dns);
  Result := Store.Flush;
  Store.Free;
  if Result = ErrorNone then
    Say('DNS servers: ' + BoolToStr(Length(Dns.Servers) = 0, 'from DHCP', JoinServerList(Dns.Servers)) +
      BoolToStr(Dns.SearchDomain <> '', ', search ' + Dns.SearchDomain, ''));
end;

end.
