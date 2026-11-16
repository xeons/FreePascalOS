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
  bind the same port on overlapping addresses (one of them 0.0.0.0, or
  both the same), unless:
    - UDP: both asked for SocketOptionReuseAddress;
    - TCP: the new one asked for it and the other is not listening (a
      connection waiting out TIME_WAIT, or one that is still closing).
  TCP connections whose socket has gone still hold their port until
  they are freed.

  A port of 0 is given one from the dynamic range (49152-65535), taken
  in turn so that a port just let go is not handed out again at once.
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
function PortIsFree(Socket: PSocket; Address: TIpv4Address; Port: Word; AllowReuse: Boolean): Boolean;
{ A free port from the dynamic range for Socket on Address; 0 if every
  one is taken. }
function ChooseDynamicPort(Socket: PSocket; Address: TIpv4Address): Word;

implementation

uses
  Network.TcpTypes,
  Network.TcpConnections;

var
  NextDynamicPort: LongWord = FirstDynamicPort;

function AddressesOverlap(First, Second: TIpv4Address): Boolean;
begin
  Result := (First = AnyAddress) or (Second = AnyAddress) or (First = Second);
end;

function ConflictsWithSocket(Socket, Other: PSocket; Address: TIpv4Address; Port: Word;
  AllowReuse: Boolean): Boolean;
var
  Connection: PTcpConnection;
begin
  Result := False;
  if (Other = Socket) or (Other^.Protocol <> Socket^.Protocol) or not Other^.IsBound or
     (Other^.Local.Port <> Port) or not AddressesOverlap(Other^.Local.Address, Address) then
    Exit;
  case Socket^.Protocol of
    SocketProtocolUdp:
      Result := not (AllowReuse and Other^.ReuseAddress);
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
function ConflictsWithOrphan(Socket: PSocket; Address: TIpv4Address; Port: Word; AllowReuse: Boolean): Boolean;
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
       AddressesOverlap(Connection^.Local.Address, Address) and not AllowReuse then
      Exit(True);
    Connection := NextTcpConnection(Connection);
  end;
end;

function PortIsFree(Socket: PSocket; Address: TIpv4Address; Port: Word; AllowReuse: Boolean): Boolean;
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

function ChooseDynamicPort(Socket: PSocket; Address: TIpv4Address): Word;
var
  Tries: LongWord;
  Candidate: Word;
begin
  for Tries := 1 to LastDynamicPort - FirstDynamicPort + 1 do
  begin
    Candidate := Word(NextDynamicPort);
    Inc(NextDynamicPort);
    if NextDynamicPort > LastDynamicPort then
      NextDynamicPort := FirstDynamicPort;
    if PortIsFree(Socket, Address, Candidate, False) then
      Exit(Candidate);
  end;
  Result := 0;
end;

end.
