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
  UDP (RFC 768).

  A datagram goes to the socket bound to its port that fits it best (one
  bound to its destination address before one bound to every address);
  a broadcast goes to every socket bound to its port. With no socket,
  the sender gets an ICMP port unreachable (not for a broadcast). The
  checksum is checked when the sender gave one.

  Sending: a datagram must fit one frame (no fragments), a broadcast
  needs SocketOptionBroadcast. A connected socket learns of a port
  unreachable that comes back (its next call fails with
  ErrorConnectionRefused), as on other systems.
}
unit Network.Udp;

{$mode objfpc}
{$pointermath on}

interface

uses
  Network.Addresses,
  Network.Ipv4,
  Network.Sockets,
  Network.IpDatagrams;

const
  UdpHeaderBytes = 8;

procedure UdpInput(constref Datagram: TIpDatagram; Payload: PByte; Length: LongWord);
{ A destination unreachable about a datagram we sent (its endpoints as
  we sent it): a connected socket hears of Error. }
procedure UdpReportError(constref Local, Remote: TNetworkEndpoint; Error: LongInt);
function SendUdpDatagram(Socket: PSocket; Data: PByte; Length: LongWord;
  constref Destination: TNetworkEndpoint): Int64;
{ True if Destination is a broadcast address for a socket bound to
  BoundInterface (nil: any). }
function IsBroadcastAddress(Destination: TIpv4Address; BoundInterface: Pointer): Boolean;

implementation

uses
  Abi.SystemCalls,
  Runtime.Memory,
  Network.ByteOrder,
  Network.Checksums,
  Network.Packets,
  Network.Interfaces,
  Network.DatagramSockets,
  Network.IpOutput,
  Network.Icmp,
  Network.Icmpv6,
  Network.Statistics;

procedure CountUdpReceiveError;
begin
  Inc(NetworkStatistics.Udp.ReceiveErrors);
end;

{ Queues the datagram for Socket and counts what became of it. }
procedure DeliverToSocket(Socket: PSocket; constref Source: TNetworkEndpoint; TimeToLive: Byte;
  Data: PByte; Length: LongWord);
begin
  if QueueDatagramForSocket(Socket, Source, TimeToLive, Data, Length) then
    Inc(NetworkStatistics.Udp.Received)
  else if not Socket^.ReceiveIsShut then
  begin
    CountUdpReceiveError;
    Inc(NetworkStatistics.Udp.ReceiveQueueErrors);
  end;
end;

function IsBroadcastAddress(Destination: TIpv4Address; BoundInterface: Pointer): Boolean;
var
  Position: Integer;
  Candidate: PNetworkInterface;
begin
  if Destination = LimitedBroadcastAddress then
    Exit(True);
  for Position := 0 to NetworkInterfaceCount - 1 do
  begin
    Candidate := NetworkInterfaceAt(Position);
    if ((BoundInterface = nil) or (BoundInterface = Candidate)) and not Candidate^.IsLoopback and
       Candidate^.HasAddress and (Candidate^.PrefixLength < 31) and
       (Destination = InterfaceBroadcastAddress(Candidate)) then
      Exit(True);
  end;
  Result := False;
end;

{ Tells the sender no socket has the port. }
procedure SendPortUnreachable(constref Datagram: TIpDatagram);
begin
  if Datagram.Family = AddressFamilyIPv6 then
    SendIcmpv6Error(Datagram.Header, Datagram.TotalLength, Icmpv6TypeDestinationUnreachable,
      Icmpv6CodePortUnreachable, 0)
  else
    SendIcmpError(Datagram.Header, Datagram.TotalLength, IcmpTypeDestinationUnreachable, IcmpCodePortUnreachable);
end;

procedure UdpInput(constref Datagram: TIpDatagram; Payload: PByte; Length: LongWord);
var
  DatagramLength: LongWord;
  Checksum: Word;
  Sum: LongWord;
  Source: TNetworkEndpoint;
  Destination: TNetworkEndpoint;
  Socket: PSocket;
  Best: PSocket;
  Delivered: Boolean;
begin
  if Length < UdpHeaderBytes then
  begin
    CountUdpReceiveError;
    CountReceiveError(Datagram.ArrivalInterface);
    Exit;
  end;
  DatagramLength := ReadBigEndian16(Payload + 4);
  Checksum := ReadBigEndian16(Payload + 6);
  if (DatagramLength < UdpHeaderBytes) or (DatagramLength > Length) then
  begin
    CountUdpReceiveError;
    CountReceiveError(Datagram.ArrivalInterface);
    Exit;
  end;
  { Over IPv6 the checksum may not be left out. }
  if (Checksum = 0) and (Datagram.Family = AddressFamilyIPv6) then
  begin
    CountUdpReceiveError;
    CountReceiveError(Datagram.ArrivalInterface);
    Exit;
  end;
  if Checksum <> 0 then
  begin
    Sum := DatagramPseudoHeaderSum(Datagram, IpProtocolUdp, DatagramLength);
    if FinishChecksum(AddToChecksum(Sum, Payload, DatagramLength)) <> 0 then
    begin
      CountUdpReceiveError;
      CountReceiveError(Datagram.ArrivalInterface);
      Exit;
    end;
  end;
  Source := DatagramSource(Datagram, ReadBigEndian16(Payload));
  Destination := DatagramDestination(Datagram, ReadBigEndian16(Payload + 2));

  Best := nil;
  Delivered := False;
  Socket := FirstSocket;
  while Socket <> nil do
  begin
    if (Socket^.Protocol = SocketProtocolUdp) and
       DatagramSocketMatches(Socket, Source, Destination, Datagram.IsBroadcast, Datagram.ArrivalInterface) then
    begin
      if Datagram.IsBroadcast then
      begin
        DeliverToSocket(Socket, Source, Datagram.TimeToLive, Payload + UdpHeaderBytes,
          DatagramLength - UdpHeaderBytes);
        Delivered := True;
      end
      else if (Best = nil) or (EndpointIsUnspecified(Best^.Local) and not EndpointIsUnspecified(Socket^.Local)) or
              (not Best^.IsConnected and Socket^.IsConnected) then
        Best := Socket;
    end;
    Socket := NextSocket(Socket);
  end;
  if Best <> nil then
  begin
    DeliverToSocket(Best, Source, Datagram.TimeToLive, Payload + UdpHeaderBytes,
      DatagramLength - UdpHeaderBytes);
    Exit;
  end;
  if not Delivered then
    Inc(NetworkStatistics.Udp.NoPorts);
  if not Delivered and not Datagram.IsBroadcast then
    SendPortUnreachable(Datagram);
end;

procedure UdpReportError(constref Local, Remote: TNetworkEndpoint; Error: LongInt);
var
  Socket: PSocket;
begin
  Socket := FirstSocket;
  while Socket <> nil do
  begin
    if (Socket^.Protocol = SocketProtocolUdp) and Socket^.IsConnected and (Socket^.Local.Port = Local.Port) and
       EndpointsEqual(Socket^.Peer, Remote) then
    begin
      Socket^.PendingError := Error;
      UpdateSocketReadiness(Socket);
    end;
    Socket := NextSocket(Socket);
  end;
end;

function SendUdpDatagram(Socket: PSocket; Data: PByte; Length: LongWord;
  constref Destination: TNetworkEndpoint): Int64;
var
  Target: TNetworkEndpoint;
  Source: TNetworkEndpoint;
  Packet: PPacket;
  Header: PByte;
  Sum: LongWord;
  Checksum: Word;
  Error: LongInt;
begin
  Target := Destination;
  if EndpointIsUnspecified(Target) then
    Target := LoopbackEndpoint(Target.Family, Target.Port);
  if Target.Port = 0 then
    Exit(-ErrorInvalidArgument);
  if (Target.Family = AddressFamilyIPv4) and IsBroadcastAddress(Target.Address, Socket^.BoundInterface) and
     not Socket^.BroadcastAllowed then
    Exit(-ErrorAccessDenied);
  Error := DatagramSourceAddress(Socket, Target, Source);
  if Error <> ErrorNone then
    Exit(-Error);
  if (Length > MaximumDatagramBytes) or
     (Length + UdpHeaderBytes > IpPayloadLimit(Target, Socket^.BoundInterface)) then
    Exit(-ErrorMessageTooLong);
  Error := BindDatagramSocketImplicitly(Socket);
  if Error <> ErrorNone then
    Exit(-Error);
  Packet := AllocatePacket(PacketHeadroom);
  if Packet = nil then
    Exit(-ErrorOutOfMemory);
  Header := AppendToPacket(Packet, UdpHeaderBytes + Length);
  WriteBigEndian16(Header, Socket^.Local.Port);
  WriteBigEndian16(Header + 2, Target.Port);
  WriteBigEndian16(Header + 4, UdpHeaderBytes + Length);
  WriteBigEndian16(Header + 6, 0);
  CopyMemory(Header + UdpHeaderBytes, Data, Length);
  Sum := TransportPseudoHeaderSum(Source, Target, IpProtocolUdp, UdpHeaderBytes + Length);
  Checksum := FinishChecksum(AddToChecksum(Sum, Header, UdpHeaderBytes + Length));
  { Zero means "no checksum"; the same value in ones' complement is all
    ones. }
  if Checksum = 0 then
    Checksum := $FFFF;
  WriteBigEndian16(Header + 6, Checksum);
  Error := SendIpPacket(Packet, Source, Target, IpProtocolUdp, Socket^.TimeToLive, False, Socket^.BoundInterface);
  if Error <> ErrorNone then
    Exit(-Error);
  Inc(NetworkStatistics.Udp.Sent);
  Result := Length;
end;

end.
