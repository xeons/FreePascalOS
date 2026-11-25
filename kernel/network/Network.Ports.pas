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
  Ports: who may bind which one, and the ports the kernel picks.

  Each protocol has its own ports (an ICMP echo socket's port is the
  identifier of its echo requests). Two sockets of a protocol may not
  bind the same port on overlapping addresses (one of them 0.0.0.0 or
  ::, or both the same), unless:
    - UDP: both asked for SocketOptionReuseAddress and belong to the
      same user (or the new one is root's), so that nobody can bind
      beside another user's socket and take its unicast datagrams;
    - TCP: the new one asked for it and the other is not listening (a
      connection waiting out TIME_WAIT, or one that is still closing);
    - both are bound to interfaces (SocketOptionInterface), different
      ones: a DHCP client has a socket on port 68 for each interface.
  TCP connections whose socket has gone still hold their port until
  they are freed. IPv4 and IPv6 never overlap: a socket of each family
  may have the same port.

  A port of 0 is given one from the dynamic range (49152-65535). A
  connection's port is found as RFC 6056's algorithm 4 says: the search
  starts at a keyed hash of its endpoints plus a counter that moves on
  with each use (Network.UnpredictableNumbers), so its ports say nothing
  about those towards other peers and a port just let go is not handed
  out again at once; with no peer known yet (bind, listen, a datagram
  socket) it starts at a random place (algorithm 1).
}
unit Network.Ports;

{$mode objfpc}

interface

uses
  Network.Addresses,
  Network.Sockets;

const
  FirstDynamicPort = 49152;
  LastDynamicPort = 65535;
  { Binding below this is root's. }
  FirstUnprivilegedPort = 1024;

{ True if Socket may bind Address:Port (with AllowReuse: as its
  SocketOptionReuseAddress allows). }
function PortIsFree(Socket: PSocket; constref Address: TNetworkEndpoint; Port: Word; AllowReuse: Boolean): Boolean;
{ A free port from the dynamic range for Socket on Address, towards
  Remote (nil: no peer known); 0 if every one is taken. }
function ChooseDynamicPort(Socket: PSocket; constref Address: TNetworkEndpoint; Remote: PNetworkEndpoint): Word;

implementation

uses
  Abi.SystemCalls,
  Network.TcpTypes,
  Network.TcpConnections,
  Network.KeyedNumbers,
  Network.UnpredictableNumbers;

function AddressesOverlap(constref First, Second: TNetworkEndpoint): Boolean;
begin
  if First.Family <> Second.Family then
    Exit(False);
  Result := EndpointIsUnspecified(First) or EndpointIsUnspecified(Second) or EndpointAddressesEqual(First, Second);
end;

{ An IPv6 socket on :: without Ipv6Only also has the port for IPv4. }
function CoversIpv4(Socket: PSocket; constref Address: TNetworkEndpoint): Boolean;
begin
  Result := (Socket^.Family = AddressFamilyIPv6) and not Socket^.Ipv6Only and
    (Address.Family = AddressFamilyIPv6) and EndpointIsUnspecified(Address);
end;

{ Other's address and the one Socket wants overlap, v4-mapped sharing
  counted. }
function SocketAddressesOverlap(Other, Socket: PSocket; constref Address: TNetworkEndpoint): Boolean;
begin
  if AddressesOverlap(Other^.Local, Address) then
    Exit(True);
  Result := ((Address.Family = AddressFamilyIPv4) and CoversIpv4(Other, Other^.Local)) or
    ((Other^.Local.Family = AddressFamilyIPv4) and CoversIpv4(Socket, Address));
end;

function ConflictsWithSocket(Socket, Other: PSocket; constref Address: TNetworkEndpoint; Port: Word;
  AllowReuse: Boolean): Boolean;
var
  Connection: PTcpConnection;
begin
  Result := False;
  if (Other = Socket) or (Other^.Protocol <> Socket^.Protocol) or not Other^.IsBound or
     (Other^.Local.Port <> Port) or not SocketAddressesOverlap(Other, Socket, Address) then
    Exit;
  if (Socket^.BoundInterface <> nil) and (Other^.BoundInterface <> nil) and
     (Socket^.BoundInterface <> Other^.BoundInterface) then
    Exit;
  case Socket^.Protocol of
    SocketProtocolUdp:
      Result := not (AllowReuse and Other^.ReuseAddress and
        ((Socket^.Owner.UserId = Other^.Owner.UserId) or (Socket^.Owner.UserId = 0)));
    SocketProtocolTcp:
      begin
        Connection := PTcpConnection(Other^.Connection);
        Result := not AllowReuse or ((Connection <> nil) and (Connection^.State = TcpListen));
      end;
    SocketProtocolIcmpEcho:
      Result := True;
  else
    Result := False;
  end;
end;

{ A TCP connection without a socket that still has the port. }
function ConflictsWithOrphan(Socket: PSocket; constref Address: TNetworkEndpoint; Port: Word;
  AllowReuse: Boolean): Boolean;
var
  Connection: PTcpConnection;
begin
  Result := False;
  if Socket^.Protocol <> SocketProtocolTcp then
    Exit;
  Connection := FirstTcpConnection;
  while Connection <> nil do
  begin
    if (Connection^.Socket = nil) and (Connection^.Listener = nil) and (Connection^.Local.Port = Port) and
       AddressesOverlap(Connection^.Local, Address) and not AllowReuse then
      Exit(True);
    Connection := NextTcpConnection(Connection);
  end;
end;

function PortIsFree(Socket: PSocket; constref Address: TNetworkEndpoint; Port: Word; AllowReuse: Boolean): Boolean;
var
  Other: PSocket;
begin
  Other := FirstSocket;
  while Other <> nil do
  begin
    if ConflictsWithSocket(Socket, Other, Address, Port, AllowReuse) then
      Exit(False);
    Other := NextSocket(Other);
  end;
  Result := not ConflictsWithOrphan(Socket, Address, Port, AllowReuse);
end;

function ChooseDynamicPort(Socket: PSocket; constref Address: TNetworkEndpoint; Remote: PNetworkEndpoint): Word;
var
  Offset: LongWord;
  Index: LongWord;
  Counter: LongWord;
  Attempt: LongWord;
  Candidate: Word;
begin
  Index := 0;
  Counter := 0;
  if Remote <> nil then
    StartDynamicPortSearch(Address, Remote^, Offset, Index, Counter)
  else
    Offset := RandomDynamicPortOffset;
  Attempt := 0;
  while Attempt <= LastDynamicPort - FirstDynamicPort do
  begin
    Candidate := DynamicPortCandidate(Offset, Counter, Attempt, FirstDynamicPort, LastDynamicPort);
    if PortIsFree(Socket, Address, Candidate, False) then
    begin
      if Remote <> nil then
        CountDynamicPortUse(Index, Attempt + 1);
      Exit(Candidate);
    end;
    Inc(Attempt);
  end;
  Result := 0;
end;

end.
