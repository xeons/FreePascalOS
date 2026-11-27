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
  The IPv6 part of an interface's section in Network.settings:

    Ipv6Method = "auto"             auto, dhcpv6, static or none (none:
                                    IPv6 off)
    Ipv6Address = "fec0::10/64"     static only
    Ipv6Gateway = "fec0::2"         static only, optional

  An interface without a section, or a section without Ipv6Method, is
  auto: the kernel takes what the routers advertise, and DHCPv6 is asked
  when their M (addresses) or O (other configuration) flag says so;
  dhcpv6 asks a DHCPv6 server for an address whatever the routers say
  (their routes and prefixes are still taken).
}
unit NetworkService.Ipv6Settings;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Abi.SystemCalls,
  Sys.InternetAddresses,
  Configuration.Settings;

type
  TIpv6Method = (Ipv6MethodAuto, Ipv6MethodStatic, Ipv6MethodNone, Ipv6MethodDhcpv6);

  TIpv6Settings = record
    Method: TIpv6Method;
    HasAddress: Boolean;
    Address: TInternetAddress;
    PrefixLength: LongWord;
    HasGateway: Boolean;
    Gateway: TInternetAddress;
    { Not empty: the IPv6 settings cannot be applied, and say why. }
    Problem: string;
  end;

function DefaultIpv6Settings: TIpv6Settings;
{ Reads the IPv6 keys of the interface section Section. }
function ReadIpv6Settings(Store: TSettings; const Section: string): TIpv6Settings;
function SameIpv6Settings(constref First, Second: TIpv6Settings): Boolean;
function Ipv6MethodName(Method: TIpv6Method): string;

implementation

uses
  Sys.AddressText;

const
  DefaultIpv6PrefixLength = 64;

function DefaultIpv6Settings: TIpv6Settings;
begin
  Result := Default(TIpv6Settings);
  Result.Method := Ipv6MethodAuto;
  Result.Address := AnyIpv6Address;
  Result.Gateway := AnyIpv6Address;
end;

function Ipv6MethodName(Method: TIpv6Method): string;
begin
  case Method of
    Ipv6MethodStatic: Result := 'static';
    Ipv6MethodNone: Result := 'none';
    Ipv6MethodDhcpv6: Result := 'dhcpv6';
  else
    Result := 'auto';
  end;
end;

procedure ReadStaticIpv6Address(Store: TSettings; const Section: string; var Settings: TIpv6Settings);
var
  AddressText: string;
  GatewayText: string;
  HasPrefix: Boolean;
begin
  AddressText := Trim(Store.ReadString(Section + '/Ipv6Address', ''));
  if AddressText = '' then
  begin
    Settings.Problem := 'Ipv6Method static needs an Ipv6Address';
    Exit;
  end;
  if not TextToAddressWithPrefix(AddressText, Settings.Address, Settings.PrefixLength, HasPrefix) or
     (Settings.Address.Family <> AddressFamilyIPv6) then
  begin
    Settings.Problem := 'the IPv6 address "' + AddressText + '" is not an IPv6 address with a prefix';
    Exit;
  end;
  if not HasPrefix then
    Settings.PrefixLength := DefaultIpv6PrefixLength;
  Settings.HasAddress := True;
  GatewayText := Trim(Store.ReadString(Section + '/Ipv6Gateway', ''));
  if GatewayText = '' then
    Exit;
  if not TextToAddress(GatewayText, Settings.Gateway) or (Settings.Gateway.Family <> AddressFamilyIPv6) then
  begin
    Settings.Problem := 'the IPv6 gateway "' + GatewayText + '" is not an IPv6 address';
    Exit;
  end;
  Settings.HasGateway := True;
end;

function ReadIpv6Settings(Store: TSettings; const Section: string): TIpv6Settings;
var
  MethodText: string;
begin
  Result := DefaultIpv6Settings;
  MethodText := LowerCase(Trim(Store.ReadString(Section + '/Ipv6Method', 'auto')));
  if MethodText = 'auto' then
    Result.Method := Ipv6MethodAuto
  else if MethodText = 'none' then
    Result.Method := Ipv6MethodNone
  else if MethodText = 'dhcpv6' then
    Result.Method := Ipv6MethodDhcpv6
  else if MethodText = 'static' then
  begin
    Result.Method := Ipv6MethodStatic;
    ReadStaticIpv6Address(Store, Section, Result);
  end
  else
    Result.Problem := 'the IPv6 method "' + MethodText + '" is not one (auto, dhcpv6, static or none)';
end;

function SameIpv6Settings(constref First, Second: TIpv6Settings): Boolean;
begin
  Result := (First.Method = Second.Method) and (First.HasAddress = Second.HasAddress) and
    AddressesAreEqual(First.Address, Second.Address) and (First.PrefixLength = Second.PrefixLength) and
    (First.HasGateway = Second.HasGateway) and AddressesAreEqual(First.Gateway, Second.Gateway) and
    (First.Problem = Second.Problem);
end;

end.
