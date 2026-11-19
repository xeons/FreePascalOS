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

  The order is RFC 6724's destination address selection
  (AddressSelection): for each address the source the kernel would send
  from (asked by connecting a UDP socket, which sends nothing; none if
  there is no route), then the addresses without a source last, a
  source of the destination's scope and label first, then the policy
  table's precedence (IPv6 before IPv4), the smaller scope, the longest
  matching prefix. So with a global IPv6 address and a default route
  IPv6 is preferred, else IPv4.
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
  AddressSelection,
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

function SelectionAddressOf(constref Address: TInternetAddress): TSelectionAddress;
begin
  if Address.Family = AddressFamilyIPv4 then
    Result := MappedIpv4SelectionAddress(Address.Bytes[0], Address.Bytes[1], Address.Bytes[2], Address.Bytes[3])
  else
    Move(Address.Bytes[0], Result[0], SelectionAddressBytes);
end;

{ The source the kernel would send to Address from; False if it has no
  route there. }
function FindSourceFor(constref Address: TInternetAddress; out Source: TSelectionAddress): Boolean;
var
  Socket: Int64;
  Local: TAbiSocketAddress;
  LocalAddress: TInternetAddress;
begin
  FillChar(Source, SizeOf(Source), 0);
  Socket := CreateSocket(Address.Family, SocketKindDatagram, ProtocolUdp);
  if Socket < 0 then
    Exit(False);
  Result := (ConnectSocket(Socket, MakeSocketAddress(Address, ProbePort)) = ErrorNone) and
    (GetLocalSocketAddress(Socket, Local) = ErrorNone);
  CloseSocket(Socket);
  if not Result then
    Exit;
  LocalAddress.Family := Address.Family;
  Move(Local.Address[0], LocalAddress.Bytes[0], SizeOf(LocalAddress.Bytes));
  Source := SelectionAddressOf(LocalAddress);
end;

procedure OrderAddressesForConnecting(var Addresses: TInternetAddressArray);
var
  Candidates: array of TDestinationCandidate;
  Original: TInternetAddressArray;
  Index: Integer;
begin
  Candidates := nil;
  SetLength(Candidates, Length(Addresses));
  for Index := 0 to High(Addresses) do
  begin
    Candidates[Index].Address := SelectionAddressOf(Addresses[Index]);
    Candidates[Index].HasSource := FindSourceFor(Addresses[Index], Candidates[Index].Source);
    Candidates[Index].SourceIsDeprecated := False;
    Candidates[Index].OriginalPosition := Index;
  end;
  OrderDestinationCandidates(Candidates);
  Original := Copy(Addresses);
  for Index := 0 to High(Candidates) do
    Addresses[Index] := Original[Candidates[Index].OriginalPosition];
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
