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
  Which IPv6 addresses the network settings take: an interface's static
  address (a unicast address of a global, unique local or site prefix:
  not ::, ::1, multicast or link-local, with a prefix of 1 to 128), its
  gateway (any unicast address, link-local ones included: routers are
  usually known by those) and DNS servers of either family.
}
unit Configuration.Ipv6Checks;

{$mode objfpc}
{$H+}

interface

uses
  Sys.InternetAddresses;

type
  TIpv6AddressCheck = (Ipv6AddressValid, Ipv6AddressMissingPrefix, Ipv6AddressBadPrefix, Ipv6AddressNotIpv6,
    Ipv6AddressNotHost);

{ "fec0::10/64". }
function CheckIpv6InterfaceAddress(const Text: string; out Address: TInternetAddress;
  out PrefixLength: LongWord): TIpv6AddressCheck;
{ A unicast IPv6 address (link-local allowed). }
function IsIpv6GatewayAddress(const Text: string; out Address: TInternetAddress): Boolean;
{ A DNS server: an IPv4 host address (not 0.0.0.0, multicast or
  reserved) or a unicast IPv6 address other than ::. }
function IsDnsServerAddress(const Text: string): Boolean;

implementation

uses
  Abi.SystemCalls;

function IsUnicastIpv6(constref Address: TInternetAddress): Boolean;
begin
  Result := (Address.Family = AddressFamilyIPv6) and not AddressIsUnspecified(Address) and
    not AddressIsLoopback(Address) and not AddressIsMulticast(Address);
end;

function CheckIpv6InterfaceAddress(const Text: string; out Address: TInternetAddress;
  out PrefixLength: LongWord): TIpv6AddressCheck;
var
  HasPrefix: Boolean;
begin
  Address := AnyIpv6Address;
  PrefixLength := 0;
  if (Text = '') or not ParseAddressWithPrefix(PChar(Text), Address, PrefixLength, HasPrefix) or
     (Address.Family <> AddressFamilyIPv6) then
    Exit(Ipv6AddressNotIpv6);
  if not HasPrefix then
    Exit(Ipv6AddressMissingPrefix);
  if (PrefixLength < 1) or (PrefixLength > 128) then
    Exit(Ipv6AddressBadPrefix);
  if not IsUnicastIpv6(Address) or AddressIsLinkLocal(Address) then
    Exit(Ipv6AddressNotHost);
  Result := Ipv6AddressValid;
end;

function IsIpv6GatewayAddress(const Text: string; out Address: TInternetAddress): Boolean;
begin
  Result := (Text <> '') and ParseIpv6Address(PChar(Text), Address) and IsUnicastIpv6(Address);
end;

function IsDnsServerAddress(const Text: string): Boolean;
var
  Address: TInternetAddress;
begin
  if (Text = '') or not ParseInternetAddress(PChar(Text), Address) then
    Exit(False);
  if Address.Family = AddressFamilyIPv4 then
    Result := not AddressIsUnspecified(Address) and (Address.Bytes[0] < 224)
  else
    Result := IsUnicastIpv6(Address);
end;

end.
