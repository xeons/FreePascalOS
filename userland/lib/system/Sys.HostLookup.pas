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
  Looking a host up to connect to it, as getaddrinfo does: every
  address of the families asked for (an address written as one, then
  /etc/hosts, then DNS: A and AAAA records), in the order to try them.

  IPv6 addresses come first when this machine can reach them: the
  kernel finds a route and a source address of the right scope (a
  global address for a global destination; ::1 always), which is asked
  by connecting a UDP socket without sending anything. Then the IPv4
  addresses, then the IPv6 ones that cannot be reached. So with a
  global IPv6 address and a default route IPv6 is preferred, else IPv4.
}
unit Sys.HostLookup;

{$mode objfpc}
{$H+}

interface

uses
  Sys.InternetAddresses,
  Sys.HostNames;

type
  TInternetAddressArray = Sys.InternetAddresses.TInternetAddressArray;

{ The addresses of Host (HostFamily* of Sys.HostNames) in the order to
  try them; ErrorNone, or the resolver's error (HostLookupErrorMessage
  says it in words). }
function ResolveHost(const Host: string; Families: LongWord; out Addresses: TInternetAddressArray): LongInt;
{ True if this machine has a route and a fitting source address for the
  IPv6 address. }
function Ipv6AddressIsReachable(constref Address: TInternetAddress): Boolean;
{ Puts the addresses in the order to try them (see above). }
procedure OrderAddressesForConnecting(var Addresses: TInternetAddressArray);

implementation

uses
  Abi.SystemCalls,
  Sys.Sockets;

const
  { Any port: connecting a UDP socket sends nothing. }
  ProbePort = 9;

function Ipv6AddressIsReachable(constref Address: TInternetAddress): Boolean;
var
  Socket: Int64;
begin
  if Address.Family <> AddressFamilyIPv6 then
    Exit(False);
  if AddressIsLoopback(Address) then
    Exit(True);
  Socket := CreateSocket(AddressFamilyIPv6, SocketKindDatagram, ProtocolUdp);
  if Socket < 0 then
    Exit(False);
  Result := ConnectSocket(Socket, MakeSocketAddress(Address, ProbePort)) = ErrorNone;
  CloseSocket(Socket);
end;

procedure AppendAddress(var Addresses: TInternetAddressArray; constref Address: TInternetAddress);
begin
  SetLength(Addresses, Length(Addresses) + 1);
  Addresses[High(Addresses)] := Address;
end;

procedure OrderAddressesForConnecting(var Addresses: TInternetAddressArray);
var
  Reachable: TInternetAddressArray;
  Ipv4: TInternetAddressArray;
  Unreachable: TInternetAddressArray;
  Address: TInternetAddress;
begin
  Reachable := nil;
  Ipv4 := nil;
  Unreachable := nil;
  for Address in Addresses do
    if Address.Family = AddressFamilyIPv4 then
      AppendAddress(Ipv4, Address)
    else if Ipv6AddressIsReachable(Address) then
      AppendAddress(Reachable, Address)
    else
      AppendAddress(Unreachable, Address);
  Addresses := nil;
  for Address in Reachable do
    AppendAddress(Addresses, Address);
  for Address in Ipv4 do
    AppendAddress(Addresses, Address);
  for Address in Unreachable do
    AppendAddress(Addresses, Address);
end;

function ResolveHost(const Host: string; Families: LongWord; out Addresses: TInternetAddressArray): LongInt;
var
  Found: THostAddresses;
begin
  Addresses := nil;
  Result := LookUpHostAddresses(Host, Families, Found);
  if Result <> ErrorNone then
    Exit;
  Addresses := Copy(Found.Addresses);
  OrderAddressesForConnecting(Addresses);
end;

end.
