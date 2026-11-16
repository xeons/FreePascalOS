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
procedure QueueDatagramForSocket(Socket: PSocket; constref Source: TNetworkEndpoint; TimeToLive: Byte;
  Data: PByte; Length: LongWord);
function ReceiveDatagram(Socket: PSocket; Data: PByte; Length: LongWord; Flags: LongWord;
  out Source: TNetworkEndpoint): Int64;
{ Fixes the peer (an address of family AddressFamilyUnspecified
  forgets it). }
function ConnectDatagramSocket(Socket: PSocket; constref Destination: TNetworkEndpoint): LongInt;
{ Binds a port the kernel chooses if the socket has none. }
function BindDatagramSocketImplicitly(Socket: PSocket): LongInt;
{ The address a datagram to Destination leaves with: the socket's own,
  else that of the interface it goes out of. }
function DatagramSourceAddress(Socket: PSocket; Destination: TIpv4Address; out Source: TIpv4Address): LongInt;
{ True if the socket takes a datagram from Source arriving for
  Destination:Port on NetworkInterface. }
function DatagramSocketMatches(Socket: PSocket; constref Source: TNetworkEndpoint; Destination: TIpv4Address;
  Port: Word; IsBroadcast: Boolean; NetworkInterface: Pointer): Boolean;

implementation

uses
  Abi.SystemCalls,
  Runtime.Memory,
  Network.Datagrams,
  Network.Interfaces,
  Network.Ipv4,
  Network.Ports;

procedure QueueDatagramForSocket(Socket: PSocket; constref Source: TNetworkEndpoint; TimeToLive: Byte;
  Data: PByte; Length: LongWord);
begin
  if Socket^.ReceiveIsShut then
    Exit;
  if EnqueueDatagram(Socket^.Datagrams, Source, TimeToLive, Data, Length) then
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
  Source := MakeEndpoint(AnyAddress, 0);
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
  Port := ChooseDynamicPort(Socket, Socket^.Local.Address);
  if Port = 0 then
    Exit(ErrorAddressInUse);
  Socket^.Local.Port := Port;
  Socket^.IsBound := True;
  Result := ErrorNone;
end;

function DatagramSourceAddress(Socket: PSocket; Destination: TIpv4Address; out Source: TIpv4Address): LongInt;
var
  NetworkInterface: PNetworkInterface;
  NextHop: TIpv4Address;
begin
  Result := RouteDatagram(Destination, Socket^.BoundInterface, NetworkInterface, NextHop, Source);
  if (Result = ErrorNone) and (Socket^.Local.Address <> AnyAddress) and
     (Socket^.Local.Address <> LimitedBroadcastAddress) then
    Source := Socket^.Local.Address;
end;

function ConnectDatagramSocket(Socket: PSocket; constref Destination: TNetworkEndpoint): LongInt;
var
  Source: TIpv4Address;
  Peer: TNetworkEndpoint;
begin
  if Destination.Family = AddressFamilyUnspecified then
  begin
    Socket^.IsConnected := False;
    Socket^.Peer := MakeEndpoint(AnyAddress, 0);
    Exit(ErrorNone);
  end;
  Peer := Destination;
  if Peer.Address = AnyAddress then
    Peer.Address := LoopbackAddress;
  Result := DatagramSourceAddress(Socket, Peer.Address, Source);
  if Result <> ErrorNone then
    Exit;
  Result := BindDatagramSocketImplicitly(Socket);
  if Result <> ErrorNone then
    Exit;
  if Socket^.Local.Address = AnyAddress then
    Socket^.Local.Address := Source;
  Socket^.Peer := Peer;
  Socket^.IsConnected := True;
end;

function DatagramSocketMatches(Socket: PSocket; constref Source: TNetworkEndpoint; Destination: TIpv4Address;
  Port: Word; IsBroadcast: Boolean; NetworkInterface: Pointer): Boolean;
begin
  Result := False;
  if not Socket^.IsBound or (Socket^.Local.Port <> Port) then
    Exit;
  if (Socket^.BoundInterface <> nil) and (Socket^.BoundInterface <> NetworkInterface) then
    Exit;
  if not IsBroadcast and (Socket^.Local.Address <> AnyAddress) and (Socket^.Local.Address <> Destination) then
    Exit;
  if Socket^.IsConnected and ((Socket^.Peer.Address <> Source.Address) or (Socket^.Peer.Port <> Source.Port)) then
    Exit;
  Result := True;
end;

end.
