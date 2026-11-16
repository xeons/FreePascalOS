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
  ICMP sockets, for ping.

  An ICMP echo socket (SocketKindDatagram, ProtocolIcmp) may be opened by
  anyone, like Linux's "ping sockets": it can only send echo requests,
  and the kernel puts the socket's own identifier (its port, chosen when
  it is first used) into each and fills in the checksum; it receives the
  echo replies with that identifier and the ICMP errors (unreachable,
  time exceeded) about its requests. So nobody can forge other ICMP
  messages or read anyone else's.

  A raw ICMP socket (SocketKindRaw) is root's: it sends ICMP messages as
  given and receives a copy of every ICMP message that arrives.

  Messages are read whole, from the ICMP header on (no IP header);
  SocketOptionReceivedTimeToLive gives the time to live (hop limit) of
  the last one.

  An IPv6 socket of either kind does the same with ICMPv6: echo
  requests are type 128, replies 129, and the kernel fills in the
  checksum (which covers the IPv6 pseudo-header) of everything sent.
}
unit Network.IcmpSockets;

{$mode objfpc}
{$pointermath on}

interface

uses
  Network.Addresses,
  Network.Ipv4,
  Network.Sockets,
  Network.IpDatagrams;

{ A copy of an ICMP message for every raw socket. }
procedure DeliverToRawSockets(constref Datagram: TIpDatagram; Message: PByte; Length: LongWord);
{ An echo reply, or an error about an echo request, with Identifier. }
procedure DeliverEchoMessage(constref Datagram: TIpDatagram; Message: PByte; Length: LongWord;
  Identifier: Word);
function SendIcmpMessage(Socket: PSocket; Data: PByte; Length: LongWord;
  constref Destination: TNetworkEndpoint): Int64;

implementation

uses
  Abi.SystemCalls,
  Runtime.Memory,
  Network.ByteOrder,
  Network.Checksums,
  Network.Packets,
  Network.Icmp,
  Network.Icmpv6,
  Network.Ipv6,
  Network.IpOutput,
  Network.Udp,
  Network.DatagramSockets;

procedure DeliverToRawSockets(constref Datagram: TIpDatagram; Message: PByte; Length: LongWord);
var
  Socket: PSocket;
  Source: TNetworkEndpoint;
begin
  Source := DatagramSource(Datagram, 0);
  Socket := FirstSocket;
  while Socket <> nil do
  begin
    if (Socket^.Protocol = SocketProtocolIcmpRaw) and (Socket^.Family = Datagram.Family) and
       ((Socket^.BoundInterface = nil) or (Socket^.BoundInterface = Datagram.ArrivalInterface)) then
      QueueDatagramForSocket(Socket, Source, Datagram.TimeToLive, Message, Length);
    Socket := NextSocket(Socket);
  end;
end;

procedure DeliverEchoMessage(constref Datagram: TIpDatagram; Message: PByte; Length: LongWord;
  Identifier: Word);
var
  Socket: PSocket;
  Source: TNetworkEndpoint;
begin
  Source := DatagramSource(Datagram, 0);
  Socket := FirstSocket;
  while Socket <> nil do
  begin
    if (Socket^.Protocol = SocketProtocolIcmpEcho) and (Socket^.Family = Datagram.Family) and Socket^.IsBound and
       (Socket^.Local.Port = Identifier) then
      QueueDatagramForSocket(Socket, Source, Datagram.TimeToLive, Message, Length);
    Socket := NextSocket(Socket);
  end;
end;

function SendIcmpMessage(Socket: PSocket; Data: PByte; Length: LongWord;
  constref Destination: TNetworkEndpoint): Int64;
var
  Target: TNetworkEndpoint;
  Source: TNetworkEndpoint;
  Packet: PPacket;
  Message: PByte;
  Error: LongInt;
  EchoRequestType: Byte;
  Protocol: Byte;
  Sum: LongWord;
begin
  if Length < IcmpHeaderBytes then
    Exit(-ErrorInvalidArgument);
  EchoRequestType := IcmpTypeEchoRequest;
  Protocol := IpProtocolIcmp;
  if Socket^.Family = AddressFamilyIPv6 then
  begin
    EchoRequestType := Icmpv6TypeEchoRequest;
    Protocol := NextHeaderIcmpv6;
  end;
  if (Socket^.Protocol = SocketProtocolIcmpEcho) and ((Data[0] <> EchoRequestType) or (Data[1] <> 0)) then
    Exit(-ErrorInvalidArgument);
  Target := Destination;
  if EndpointIsUnspecified(Target) then
    Target := LoopbackEndpoint(Target.Family, 0);
  if (Target.Family = AddressFamilyIPv4) and IsBroadcastAddress(Target.Address, Socket^.BoundInterface) and
     not Socket^.BroadcastAllowed then
    Exit(-ErrorAccessDenied);
  Error := DatagramSourceAddress(Socket, Target, Source);
  if Error <> ErrorNone then
    Exit(-Error);
  if Length > IpPayloadLimit(Target, Socket^.BoundInterface) then
    Exit(-ErrorMessageTooLong);
  Error := BindDatagramSocketImplicitly(Socket);
  if Error <> ErrorNone then
    Exit(-Error);
  Packet := AllocatePacket(PacketHeadroom);
  if Packet = nil then
    Exit(-ErrorOutOfMemory);
  Message := AppendToPacket(Packet, Length);
  if Message = nil then
  begin
    FreePacket(Packet);
    Exit(-ErrorMessageTooLong);
  end;
  CopyMemory(Message, Data, Length);
  if Socket^.Protocol = SocketProtocolIcmpEcho then
    WriteBigEndian16(Message + 4, Socket^.Local.Port);
  if Socket^.Family = AddressFamilyIPv6 then
  begin
    WriteBigEndian16(Message + 2, 0);
    Sum := TransportPseudoHeaderSum(Source, Target, NextHeaderIcmpv6, Length);
    WriteBigEndian16(Message + 2, FinishChecksum(AddToChecksum(Sum, Message, Length)));
  end
  else if Socket^.Protocol = SocketProtocolIcmpEcho then
  begin
    WriteBigEndian16(Message + 2, 0);
    WriteBigEndian16(Message + 2, InternetChecksum(Message, Length));
  end;
  Error := SendIpPacket(Packet, Source, Target, Protocol, Socket^.TimeToLive, False, Socket^.BoundInterface);
  if Error <> ErrorNone then
    Exit(-Error);
  Result := Length;
end;

end.
