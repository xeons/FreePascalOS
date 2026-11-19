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
  IPv6's destination cache (RFC 4861 5.1) for the kernel: the path MTU
  of destinations that sent Packet Too Big (RFC 8201: kept ten minutes,
  then the link's MTU is tried again) and the first hops redirects gave
  (kept ten minutes too). The table itself is Network.DestinationTable;
  this unit keeps the one table, with the network's clock and wake-ups.
  Under the network lock.
}
unit Network.Ipv6DestinationCache;

{$mode objfpc}

interface

uses
  Network.Ipv6Addresses,
  Network.Interfaces;

const
  PathMtuLifetimeSeconds = 10 * 60;
  RedirectLifetimeSeconds = 10 * 60;

{ The MTU of the path to Destination leaving by NetworkInterface: the
  link's, or less if a Packet Too Big said so. }
function Ipv6PathMtu(NetworkInterface: PNetworkInterface; constref Destination: TIpv6Address): LongWord;
{ A Packet Too Big about a datagram to Destination said Mtu. True if
  the path MTU became smaller (TCP then sends smaller segments). }
function NoteIpv6PacketTooBig(NetworkInterface: PNetworkInterface; constref Destination: TIpv6Address;
  Mtu: LongWord): Boolean;
{ A redirect (already checked): Destination is reached through NextHop
  (a router, or Destination itself) on NetworkInterface. }
procedure NoteIpv6Redirect(NetworkInterface: PNetworkInterface; constref Destination, NextHop: TIpv6Address);
{ The first hop a redirect gave for Destination on NetworkInterface;
  False if there is none. }
function FindIpv6Redirect(NetworkInterface: PNetworkInterface; constref Destination: TIpv6Address;
  out NextHop: TIpv6Address): Boolean;
{ Forgets what was learned through the interface (IPv6 stopped on it). }
procedure ForgetIpv6Destinations(NetworkInterface: PNetworkInterface);
{ On the network thread: drops what expired. }
procedure RunIpv6DestinationTimers(Now: QWord);

implementation

uses
  Network.Core,
  Network.DestinationTable;

const
  NanosecondsPerSecond = QWord(1000) * 1000 * 1000;

var
  Table: TDestinationTable;

function AsDestination(constref Address: TIpv6Address): TDestinationAddress;
begin
  Move(Address[0], Result[0], DestinationAddressBytes);
end;

function LinkMtuOf(NetworkInterface: PNetworkInterface): LongWord;
begin
  Result := NetworkInterface^.Mtu;
  if (NetworkInterface^.Ipv6.Mtu <> 0) and (NetworkInterface^.Ipv6.Mtu < Result) then
    Result := NetworkInterface^.Ipv6.Mtu;
end;

function Ipv6PathMtu(NetworkInterface: PNetworkInterface; constref Destination: TIpv6Address): LongWord;
var
  Learned: LongWord;
begin
  Result := LinkMtuOf(NetworkInterface);
  if IsMulticastIpv6Address(Destination) then
    Exit;
  Learned := LookupPathMtu(Table, AsDestination(Destination), NetworkNow);
  if (Learned <> 0) and (Learned < Result) then
    Result := Learned;
end;

function NoteIpv6PacketTooBig(NetworkInterface: PNetworkInterface; constref Destination: TIpv6Address;
  Mtu: LongWord): Boolean;
var
  Now: QWord;
begin
  Now := NetworkNow;
  Result := RecordPathMtu(Table, AsDestination(Destination), NetworkInterface^.Index, Mtu,
    LinkMtuOf(NetworkInterface), Now, QWord(PathMtuLifetimeSeconds) * NanosecondsPerSecond);
  RequestNetworkWakeAt(Now + QWord(PathMtuLifetimeSeconds) * NanosecondsPerSecond);
end;

procedure NoteIpv6Redirect(NetworkInterface: PNetworkInterface; constref Destination, NextHop: TIpv6Address);
var
  Now: QWord;
begin
  Now := NetworkNow;
  RecordRedirect(Table, AsDestination(Destination), AsDestination(NextHop), NetworkInterface^.Index, Now,
    QWord(RedirectLifetimeSeconds) * NanosecondsPerSecond);
  RequestNetworkWakeAt(Now + QWord(RedirectLifetimeSeconds) * NanosecondsPerSecond);
end;

function FindIpv6Redirect(NetworkInterface: PNetworkInterface; constref Destination: TIpv6Address;
  out NextHop: TIpv6Address): Boolean;
var
  Hop: TDestinationAddress;
  InterfaceIndex: LongWord;
begin
  NextHop := Destination;
  Result := LookupRedirect(Table, AsDestination(Destination), NetworkNow, Hop, InterfaceIndex) and
    (InterfaceIndex = NetworkInterface^.Index);
  if Result then
    Move(Hop[0], NextHop[0], Ipv6AddressLength);
end;

procedure ForgetIpv6Destinations(NetworkInterface: PNetworkInterface);
begin
  ForgetDestinationsOn(Table, NetworkInterface^.Index);
end;

procedure RunIpv6DestinationTimers(Now: QWord);
var
  NextExpiry: QWord;
begin
  NextExpiry := ExpireDestinations(Table, Now);
  if NextExpiry <> NoExpiry then
    RequestNetworkWakeAt(NextExpiry);
end;

end.
