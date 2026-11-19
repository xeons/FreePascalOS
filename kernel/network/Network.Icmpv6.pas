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
  ICMPv6 (RFC 4443): echo, errors, and the hand-off of Neighbor
  Discovery and MLD messages.

  Every message's checksum covers the IPv6 pseudo-header. Echo requests
  are answered (multicast ones too, from an address of the interface
  they came in on). Echo replies, and errors about echo requests, go to
  the IPv6 echo sockets with the request's identifier; raw ICMPv6
  sockets get every message. Destination unreachable about UDP or TCP
  goes to the socket or connection. A Packet Too Big about a datagram
  this machine sent lowers the path MTU to its destination
  (Network.Ipv6DestinationCache), and TCP's segments to it follow.
  Neighbor Discovery's messages go to Network.NeighborDiscovery,
  Network.RouterDiscovery and Network.Ipv6Redirects, MLD queries to
  Network.Mld.

  Errors are sent for an unknown next header or option, a routing
  header with segments left, a closed UDP port and a neighbour that
  never answered; never about an ICMPv6 error, a datagram sent to a
  multicast group or from an address that is not a unicast one. An
  error quotes as much of the datagram as keeps it within the minimum
  MTU (1280 bytes).
}
unit Network.Icmpv6;

{$mode objfpc}
{$pointermath on}

interface

uses
  Network.Ipv6Addresses,
  Network.Packets,
  Network.Interfaces,
  Network.IpDatagrams;

const
  Icmpv6HeaderBytes = 8;
  Icmpv6TypeDestinationUnreachable = 1;
  Icmpv6TypePacketTooBig = 2;
  Icmpv6TypeTimeExceeded = 3;
  Icmpv6TypeParameterProblem = 4;
  Icmpv6TypeEchoRequest = 128;
  Icmpv6TypeEchoReply = 129;
  Icmpv6TypeMulticastListenerQuery = 130;
  Icmpv6TypeRouterSolicitation = 133;
  Icmpv6TypeRouterAdvertisement = 134;
  Icmpv6TypeNeighborSolicitation = 135;
  Icmpv6TypeNeighborAdvertisement = 136;
  Icmpv6TypeMulticastListenerReportV2 = 143;

  { Destination unreachable. }
  Icmpv6CodeNoRoute = 0;
  Icmpv6CodeProhibited = 1;
  Icmpv6CodeAddressUnreachable = 3;
  Icmpv6CodePortUnreachable = 4;
  { Parameter problem. }
  Icmpv6CodeErroneousField = 0;
  Icmpv6CodeUnknownNextHeader = 1;
  Icmpv6CodeUnknownOption = 2;

procedure Icmpv6Input(constref Datagram: TIpDatagram; Message: PByte; Length: LongWord);
{ Sends an ICMPv6 error about the datagram at Original (its fixed header
  first, OriginalLength bytes) to its source. Parameter: the pointer of
  a parameter problem, the MTU of a packet too big, else 0. }
procedure SendIcmpv6Error(Original: PByte; OriginalLength: LongWord; IcmpType, Code: Byte; Parameter: LongWord);
{ A datagram sent from this machine could not be delivered (no
  neighbour answered): its sender is told (address unreachable). }
procedure ReportUndeliverableIpv6Datagram(Original: PByte; OriginalLength: LongWord);
{ Fills in the checksum of the ICMPv6 message in Packet (all of it) for
  Source and Destination. }
procedure WriteIcmpv6Checksum(Packet: PPacket; constref Source, Destination: TIpv6Address);
{ Sends the ICMPv6 message in Packet out of NetworkInterface with Source
  as it is (:: allowed) and HopLimit, the checksum filled in. Takes the
  packet. }
function TransmitIcmpv6(Packet: PPacket; constref Source, Destination: TIpv6Address; HopLimit: Byte;
  NetworkInterface: PNetworkInterface): LongInt;

implementation

uses
  Abi.SystemCalls,
  Runtime.Memory,
  Network.ByteOrder,
  Network.Checksums,
  Network.Addresses,
  Network.Ipv6,
  Network.Ipv6AddressList,
  Network.IcmpSockets,
  Network.NeighborDiscovery,
  Network.RouterDiscovery,
  Network.Ipv6Redirects,
  Network.Ipv6DestinationCache,
  Network.TcpPathMtu,
  Network.Mld,
  Network.Udp,
  Network.TcpInput,
  Network.Statistics;

const
  { What an error may quote: the minimum MTU less the IPv6 and ICMPv6
    headers. }
  MaximumQuotedBytes = 1280 - 40 - Icmpv6HeaderBytes;
  FixedHeaderBytes = 40;
  QuotedTransportBytes = 8;

procedure WriteIcmpv6Checksum(Packet: PPacket; constref Source, Destination: TIpv6Address);
var
  Message: PByte;
  Sum: LongWord;
begin
  Message := PacketData(Packet);
  WriteBigEndian16(Message + 2, 0);
  Sum := Ipv6PseudoHeaderSum(@Source[0], @Destination[0], NextHeaderIcmpv6, Packet^.Length);
  WriteBigEndian16(Message + 2, FinishChecksum(AddToChecksum(Sum, Message, Packet^.Length)));
end;

function TransmitIcmpv6(Packet: PPacket; constref Source, Destination: TIpv6Address; HopLimit: Byte;
  NetworkInterface: PNetworkInterface): LongInt;
begin
  WriteIcmpv6Checksum(Packet, Source, Destination);
  Result := TransmitIpv6(Packet, Source, Destination, NextHeaderIcmpv6, HopLimit, NetworkInterface, Destination);
end;

{ Sends a message (in Packet) through the routes, the source chosen
  first so that the checksum can cover it. }
function SendRoutedIcmpv6(Packet: PPacket; constref Source, Destination: TIpv6Address;
  ScopeInterface: PNetworkInterface): LongInt;
var
  NetworkInterface: PNetworkInterface;
  NextHop: TIpv6Address;
  RoutedSource: TIpv6Address;
  ChosenSource: TIpv6Address;
begin
  Result := RouteIpv6Datagram(Destination, ScopeInterface, NetworkInterface, NextHop, RoutedSource);
  if Result <> ErrorNone then
  begin
    Inc(NetworkStatistics.Icmpv6.SendErrors);
    FreePacket(Packet);
    Exit;
  end;
  ChosenSource := Source;
  if IsUnspecifiedIpv6Address(ChosenSource) then
    ChosenSource := RoutedSource;
  WriteIcmpv6Checksum(Packet, ChosenSource, Destination);
  Result := SendIpv6(Packet, ChosenSource, Destination, NextHeaderIcmpv6, 0, ScopeInterface);
end;

procedure SendEchoReply(constref Datagram: TIpDatagram; Message: PByte; Length: LongWord);
var
  Packet: PPacket;
  Reply: PByte;
  Source: TIpv6Address;
begin
  if Length > PacketCapacity - PacketHeadroom then
    Exit;
  Packet := AllocatePacket(PacketHeadroom);
  if Packet = nil then
    Exit;
  Reply := AppendToPacket(Packet, Length);
  CopyMemory(Reply, Message, Length);
  Reply[0] := Icmpv6TypeEchoReply;
  Reply[1] := 0;
  { A request to a group is answered from one of our own addresses. }
  Source := Datagram.Destination6;
  if IsMulticastIpv6Address(Source) then
    Source := UnspecifiedIpv6Address;
  SendRoutedIcmpv6(Packet, Source, Datagram.Source6, Datagram.ArrivalInterface);
end;

{ The error a destination unreachable stands for, for a socket. }
function UnreachableError(Code: Byte): LongInt;
begin
  case Code of
    Icmpv6CodeNoRoute: Result := ErrorNetworkUnreachable;
    Icmpv6CodeAddressUnreachable: Result := ErrorHostUnreachable;
  else
    Result := ErrorConnectionRefused;
  end;
end;

{ A Packet Too Big about a datagram we sent (Quoted: its header). }
procedure HandlePacketTooBig(constref Datagram: TIpDatagram; Message: PByte; Quoted: PByte);
var
  QuotedSource: TIpv6Address;
  QuotedDestination: TIpv6Address;
begin
  CopyMemory(@QuotedSource[0], Quoted + 8, Ipv6AddressLength);
  CopyMemory(@QuotedDestination[0], Quoted + 24, Ipv6AddressLength);
  if not IsLocalIpv6Address(QuotedSource) or IsMulticastIpv6Address(QuotedDestination) then
    Exit;
  if NoteIpv6PacketTooBig(Datagram.ArrivalInterface, QuotedDestination, ReadBigEndian32(Message + 4)) then
    TcpPathMtuChanged(MakeIpv6Endpoint(QuotedDestination, 0, Datagram.ArrivalInterface^.Index),
      Ipv6PathMtu(Datagram.ArrivalInterface, QuotedDestination));
end;

{ An error about a datagram we sent: to whoever sent it. }
procedure HandleError(constref Datagram: TIpDatagram; Message: PByte; Length: LongWord);
var
  Quoted: PByte;
  QuotedSource: TIpv6Address;
  QuotedDestination: TIpv6Address;
  QuotedPayload: PByte;
  Local: TNetworkEndpoint;
  Remote: TNetworkEndpoint;
  ScopeId: LongWord;
begin
  if Length < Icmpv6HeaderBytes + FixedHeaderBytes + QuotedTransportBytes then
    Exit;
  Quoted := Message + Icmpv6HeaderBytes;
  CopyMemory(@QuotedSource[0], Quoted + 8, Ipv6AddressLength);
  CopyMemory(@QuotedDestination[0], Quoted + 24, Ipv6AddressLength);
  QuotedPayload := Quoted + FixedHeaderBytes;
  ScopeId := Datagram.ArrivalInterface^.Index;
  if Message[0] = Icmpv6TypePacketTooBig then
    HandlePacketTooBig(Datagram, Message, Quoted);
  case Quoted[6] of
    NextHeaderUdp, NextHeaderTcp:
      begin
        if Message[0] <> Icmpv6TypeDestinationUnreachable then
          Exit;
        Local := MakeIpv6Endpoint(QuotedSource, ReadBigEndian16(QuotedPayload), ScopeId);
        Remote := MakeIpv6Endpoint(QuotedDestination, ReadBigEndian16(QuotedPayload + 2), ScopeId);
        if Quoted[6] = NextHeaderUdp then
          UdpReportError(Local, Remote, UnreachableError(Message[1]))
        else
          TcpReportError(Local, Remote, ReadBigEndian32(QuotedPayload + 4), UnreachableError(Message[1]));
      end;
    NextHeaderIcmpv6:
      if QuotedPayload[0] = Icmpv6TypeEchoRequest then
        DeliverEchoMessage(Datagram, Message, Length, ReadBigEndian16(QuotedPayload + 4));
  end;
end;

procedure Icmpv6Input(constref Datagram: TIpDatagram; Message: PByte; Length: LongWord);
var
  Sum: LongWord;
begin
  Sum := DatagramPseudoHeaderSum(Datagram, NextHeaderIcmpv6, Length);
  if (Length < 4) or (FinishChecksum(AddToChecksum(Sum, Message, Length)) <> 0) then
  begin
    Inc(NetworkStatistics.Icmpv6.Received);
    Inc(NetworkStatistics.Icmpv6.ReceiveErrors);
    CountReceiveError(Datagram.ArrivalInterface);
    Exit;
  end;
  CountIcmpv6Received(Message[0]);
  DeliverToRawSockets(Datagram, Message, Length);
  case Message[0] of
    Icmpv6TypeEchoRequest:
      if Length >= Icmpv6HeaderBytes then
        SendEchoReply(Datagram, Message, Length);
    Icmpv6TypeEchoReply:
      if Length >= Icmpv6HeaderBytes then
        DeliverEchoMessage(Datagram, Message, Length, ReadBigEndian16(Message + 4));
    Icmpv6TypeDestinationUnreachable, Icmpv6TypePacketTooBig, Icmpv6TypeTimeExceeded, Icmpv6TypeParameterProblem:
      HandleError(Datagram, Message, Length);
    Icmpv6TypeRouterAdvertisement:
      HandleRouterAdvertisement(Datagram, Message, Length);
    Icmpv6TypeNeighborSolicitation:
      HandleNeighborSolicitation(Datagram, Message, Length);
    Icmpv6TypeNeighborAdvertisement:
      HandleNeighborAdvertisement(Datagram, Message, Length);
    Icmpv6TypeMulticastListenerQuery:
      HandleMulticastListenerQuery(Datagram, Message, Length);
    Icmpv6TypeRedirect:
      HandleRedirect(Datagram, Message, Length);
  end;
end;

{ True for an ICMPv6 error message (or one we cannot tell). }
function QuotesIcmpv6Error(Original: PByte; OriginalLength: LongWord): Boolean;
begin
  if Original[6] <> NextHeaderIcmpv6 then
    Exit(False);
  if OriginalLength < FixedHeaderBytes + 1 then
    Exit(True);
  Result := Original[FixedHeaderBytes] < Icmpv6TypeEchoRequest;
end;

procedure SendIcmpv6Error(Original: PByte; OriginalLength: LongWord; IcmpType, Code: Byte; Parameter: LongWord);
var
  OriginalSource: TIpv6Address;
  OriginalDestination: TIpv6Address;
  QuotedLength: LongWord;
  Packet: PPacket;
  Message: PByte;
  ScopeInterface: PNetworkInterface;
begin
  if OriginalLength < FixedHeaderBytes then
    Exit;
  CopyMemory(@OriginalSource[0], Original + 8, Ipv6AddressLength);
  CopyMemory(@OriginalDestination[0], Original + 24, Ipv6AddressLength);
  if IsUnspecifiedIpv6Address(OriginalSource) or IsMulticastIpv6Address(OriginalSource) or
     IsMulticastIpv6Address(OriginalDestination) or QuotesIcmpv6Error(Original, OriginalLength) then
    Exit;
  QuotedLength := OriginalLength;
  if QuotedLength > MaximumQuotedBytes then
    QuotedLength := MaximumQuotedBytes;
  if Icmpv6HeaderBytes + QuotedLength > PacketCapacity - PacketHeadroom then
    QuotedLength := PacketCapacity - PacketHeadroom - Icmpv6HeaderBytes;
  Packet := AllocatePacket(PacketHeadroom);
  if Packet = nil then
    Exit;
  Message := AppendToPacket(Packet, Icmpv6HeaderBytes + QuotedLength);
  FillMemory(Message, Icmpv6HeaderBytes, 0);
  Message[0] := IcmpType;
  Message[1] := Code;
  WriteBigEndian32(Message + 4, Parameter);
  CopyMemory(Message + Icmpv6HeaderBytes, Original, QuotedLength);
  { A link-local sender is answered on the link the datagram belongs to. }
  ScopeInterface := nil;
  if IsLinkLocalIpv6Address(OriginalSource) then
    ScopeInterface := FindInterfaceWithIpv6Address(OriginalDestination, True);
  SendRoutedIcmpv6(Packet, OriginalDestination, OriginalSource, ScopeInterface);
end;

procedure ReportUndeliverableIpv6Datagram(Original: PByte; OriginalLength: LongWord);
var
  OriginalSource: TIpv6Address;
begin
  if OriginalLength < FixedHeaderBytes then
    Exit;
  CopyMemory(@OriginalSource[0], Original + 8, Ipv6AddressLength);
  if IsLocalIpv6Address(OriginalSource) then
    SendIcmpv6Error(Original, OriginalLength, Icmpv6TypeDestinationUnreachable, Icmpv6CodeAddressUnreachable, 0);
end;

end.
