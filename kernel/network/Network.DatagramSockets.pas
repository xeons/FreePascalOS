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
  What UDP and ICMP sockets have in common: datagrams queued as they
  arrive and read one at a time (a datagram longer than the reader's
  buffer is cut short, the rest dropped), "connecting" (which only
  fixes the peer: datagrams go to it, and only its datagrams are
  taken), a port bound on first use, and the source address a datagram
  leaves with. Under the network lock.
}
unit Network.DatagramSockets;

{$mode objfpc}

interface

uses
  Network.Addresses,
  Network.Sockets;

{ Puts a received datagram on the socket's queue (dropped if it is
  full or the socket was shut for receiving). }
{ False if the socket's queue had no room for it (or it takes nothing
  more). }
function QueueDatagramForSocket(Socket: PSocket; constref Source: TNetworkEndpoint; TimeToLive: Byte;
  Data: PByte; Length: LongWord): Boolean;
function ReceiveDatagram(Socket: PSocket; Data: PByte; Length: LongWord; Flags: LongWord;
  out Source: TNetworkEndpoint): Int64;
{ Fixes the peer (an address of family AddressFamilyUnspecified
  forgets it). }
function ConnectDatagramSocket(Socket: PSocket; constref Destination: TNetworkEndpoint): LongInt;
{ Binds a port the kernel chooses if the socket has none. }
function BindDatagramSocketImplicitly(Socket: PSocket): LongInt;
{ The interface a datagram to Destination may leave by: for a
  multicast group the socket's multicast interface, else its bound one
  (nil: by the routes). }
function DatagramOutInterface(Socket: PSocket; constref Destination: TNetworkEndpoint): Pointer;
{ The address a datagram to Destination leaves with: the socket's own,
  else that of the interface it goes out of. }
function DatagramSourceAddress(Socket: PSocket; constref Destination: TNetworkEndpoint;
  out Source: TNetworkEndpoint): LongInt;
{ True if the socket takes a datagram from Source arriving for
  Destination (with its port) on NetworkInterface. }
function DatagramSocketMatches(Socket: PSocket; constref Source, Destination: TNetworkEndpoint;
  IsBroadcast: Boolean; NetworkInterface: Pointer): Boolean;

implementation

uses
  Abi.SystemCalls,
  Runtime.Memory,
  Network.Udp,
  Network.Datagrams,
  Network.Interfaces,
  Network.IpOutput,
  Network.Ports;

function QueueDatagramForSocket(Socket: PSocket; constref Source: TNetworkEndpoint; TimeToLive: Byte;
  Data: PByte; Length: LongWord): Boolean;
begin
  if Socket^.ReceiveIsShut then
    Exit(False);
  Result := EnqueueDatagram(Socket^.Datagrams, Source, TimeToLive, Data, Length);
  if Result then
    UpdateSocketReadiness(Socket);
end;

function ReceiveDatagram(Socket: PSocket; Data: PByte; Length: LongWord; Flags: LongWord;
  out Source: TNetworkEndpoint): Int64;
var
  Entry: PDatagramEntry;
  Count: LongWord;
  Error: LongInt;
  Deadline: QWord;
begin
  Source := UnspecifiedEndpoint(Socket^.Family);
  Deadline := SocketWaitDeadline(Socket^.ReceiveTimeout);
  repeat
    Entry := FirstDatagram(Socket^.Datagrams);
    if Entry <> nil then
    begin
      Count := Entry^.Length;
      if Count > Length then
        Count := Length;
      CopyMemory(Data, DatagramData(Entry), Count);
      Source := Entry^.Source;
      Socket^.ReceivedTimeToLive := Entry^.TimeToLive;
      if (Flags and SocketFlagPeek) = 0 then
        RemoveFirstDatagram(Socket^.Datagrams);
      UpdateSocketReadiness(Socket);
      Exit(Count);
    end;
    Error := TakePendingError(Socket);
    if Error <> ErrorNone then
      Exit(-Error);
    if Socket^.ReceiveIsShut then
      Exit(0);
    if Socket^.NonBlocking or ((Flags and SocketFlagDontWait) <> 0) then
      Exit(-ErrorWouldBlock);
    Error := WaitOnSocket(@Socket^.Readable, Deadline);
  until Error <> ErrorNone;
  Result := -Error;
end;

function BindDatagramSocketImplicitly(Socket: PSocket): LongInt;
var
  Port: Word;
begin
  if Socket^.IsBound then
    Exit(ErrorNone);
  if Socket^.Protocol = SocketProtocolIcmpRaw then
  begin
    Socket^.IsBound := True;
    Exit(ErrorNone);
  end;
  Port := ChooseDynamicPort(Socket, Socket^.Local, nil);
  if Port = 0 then
    Exit(ErrorAddressInUse);
  Socket^.Local.Port := Port;
  Socket^.IsBound := True;
  Result := ErrorNone;
end;

function DatagramOutInterface(Socket: PSocket; constref Destination: TNetworkEndpoint): Pointer;
begin
  Result := Socket^.BoundInterface;
  if EndpointIsMulticast(Destination) and (Socket^.MulticastInterface <> nil) then
    Result := Socket^.MulticastInterface;
end;

function DatagramSourceAddress(Socket: PSocket; constref Destination: TNetworkEndpoint;
  out Source: TNetworkEndpoint): LongInt;
begin
  Result := ChooseSourceAddress(Destination, PNetworkInterface(DatagramOutInterface(Socket, Destination)), Source);
  if Result <> ErrorNone then
    Exit;
  if EndpointIsUnspecified(Socket^.Local) then
    Exit;
  { A socket bound to a broadcast address sends from the interface's. }
  if (Socket^.Local.Family = AddressFamilyIPv4) and IsBroadcastAddress(Socket^.Local.Address, nil) then
    Exit;
  Source := Socket^.Local;
  Source.Port := 0;
end;

function ConnectDatagramSocket(Socket: PSocket; constref Destination: TNetworkEndpoint): LongInt;
var
  Source: TNetworkEndpoint;
  Peer: TNetworkEndpoint;
begin
  if Destination.Family = AddressFamilyUnspecified then
  begin
    Socket^.IsConnected := False;
    Socket^.Peer := UnspecifiedEndpoint(Socket^.Family);
    Exit(ErrorNone);
  end;
  Peer := Destination;
  if EndpointIsUnspecified(Peer) then
    Peer := LoopbackEndpoint(Peer.Family, Peer.Port);
  Result := DatagramSourceAddress(Socket, Peer, Source);
  if Result <> ErrorNone then
    Exit;
  Result := BindDatagramSocketImplicitly(Socket);
  if Result <> ErrorNone then
    Exit;
  if EndpointIsUnspecified(Socket^.Local) then
  begin
    Source.Port := Socket^.Local.Port;
    Socket^.Local := Source;
  end;
  Socket^.Peer := Peer;
  Socket^.IsConnected := True;
end;

function DatagramSocketMatches(Socket: PSocket; constref Source, Destination: TNetworkEndpoint;
  IsBroadcast: Boolean; NetworkInterface: Pointer): Boolean;
begin
  Result := False;
  if not SocketTakesFamily(Socket, Destination.Family) or not Socket^.IsBound or
     (Socket^.Local.Port <> Destination.Port) then
    Exit;
  if (Socket^.BoundInterface <> nil) and (Socket^.BoundInterface <> NetworkInterface) then
    Exit;
  { A group's datagrams go to sockets bound to every address or to the
    group (as on Linux, whichever socket joined it). }
  if EndpointIsMulticast(Destination) and not EndpointIsUnspecified(Socket^.Local) and
     not EndpointAddressesEqual(Socket^.Local, Destination) then
    Exit;
  if not IsBroadcast and not EndpointIsUnspecified(Socket^.Local) and
     not EndpointAddressesEqual(Socket^.Local, Destination) then
    Exit;
  if Socket^.IsConnected and not EndpointsEqual(Socket^.Peer, Source) then
    Exit;
  Result := True;
end;

end.
