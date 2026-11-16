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
  ICMP (RFC 792).

  Echo requests to this machine are answered (not those sent to a
  broadcast address). Echo replies, and errors about echo requests, go
  to the ICMP sockets ping uses (Network.IcmpSockets); raw ICMP sockets
  get a copy of every message. Destination unreachable and time
  exceeded about a UDP or TCP datagram go to its socket or connection.

  Errors are sent about datagrams that cannot be delivered (no protocol,
  no port, no answer to ARP), but never about an ICMP error, a
  broadcast, a fragment after the first, or a datagram from no one.
}
unit Network.Icmp;

{$mode objfpc}
{$pointermath on}

interface

uses
  Network.Ipv4;

const
  IcmpHeaderBytes = 8;
  IcmpTypeEchoReply = 0;
  IcmpTypeDestinationUnreachable = 3;
  IcmpTypeEchoRequest = 8;
  IcmpTypeTimeExceeded = 11;
  IcmpTypeParameterProblem = 12;

  IcmpCodeNetworkUnreachable = 0;
  IcmpCodeHostUnreachable = 1;
  IcmpCodeProtocolUnreachable = 2;
  IcmpCodePortUnreachable = 3;

procedure IcmpInput(constref Datagram: TIpv4Datagram; Message: PByte; Length: LongWord);
{ Sends an ICMP error about the datagram at Original (its header first,
  OriginalLength bytes) to its source. }
procedure SendIcmpError(Original: PByte; OriginalLength: LongWord; IcmpType, Code: Byte);
{ A datagram sent from this machine could not be delivered (ARP got no
  answer): its sender is told by an ICMP destination unreachable with
  Code, sent to itself. }
procedure ReportUndeliverableDatagram(Original: PByte; OriginalLength: LongWord; Code: Byte);

implementation

uses
  Runtime.Memory,
  Network.ByteOrder,
  Network.Checksums,
  Network.Addresses,
  Network.Packets,
  Network.Interfaces,
  Network.IcmpSockets,
  Network.Udp,
  Network.TcpInput,
  Network.Statistics;

const
  { The original header and the first 8 bytes of its payload. }
  QuotedPayloadBytes = 8;

procedure SendEchoReply(constref Datagram: TIpv4Datagram; Message: PByte; Length: LongWord);
var
  Packet: PPacket;
  Reply: PByte;
begin
  if Length + IcmpHeaderBytes > PacketCapacity - PacketHeadroom then
    Exit;
  Packet := AllocatePacket(PacketHeadroom);
  if Packet = nil then
    Exit;
  Reply := AppendToPacket(Packet, Length);
  CopyMemory(Reply, Message, Length);
  Reply[0] := IcmpTypeEchoReply;
  Reply[1] := 0;
  WriteBigEndian16(Reply + 2, 0);
  WriteBigEndian16(Reply + 2, InternetChecksum(Reply, Length));
  SendIpv4(Packet, Datagram.Destination, Datagram.Source, IpProtocolIcmp, DefaultTimeToLive, False, nil);
end;

{ An error about a datagram we sent: to whoever sent it. }
procedure HandleError(constref Datagram: TIpv4Datagram; Message: PByte; Length: LongWord);
var
  Quoted: PByte;
  QuotedHeaderLength: LongWord;
  QuotedSource: TIpv4Address;
  QuotedDestination: TIpv4Address;
  QuotedPayload: PByte;
begin
  if Length < IcmpHeaderBytes + Ipv4HeaderBytes + QuotedPayloadBytes then
    Exit;
  Quoted := Message + IcmpHeaderBytes;
  QuotedHeaderLength := LongWord(Quoted[0] and $0F) * 4;
  if (QuotedHeaderLength < Ipv4HeaderBytes) or
     (Length < IcmpHeaderBytes + QuotedHeaderLength + QuotedPayloadBytes) then
    Exit;
  QuotedSource := ReadIpv4Address(Quoted + 12);
  QuotedDestination := ReadIpv4Address(Quoted + 16);
  QuotedPayload := Quoted + QuotedHeaderLength;
  case Quoted[9] of
    IpProtocolUdp:
      UdpReportError(QuotedSource, QuotedDestination, ReadBigEndian16(QuotedPayload),
        ReadBigEndian16(QuotedPayload + 2), Message[0], Message[1]);
    IpProtocolTcp:
      TcpReportError(QuotedSource, QuotedDestination, ReadBigEndian16(QuotedPayload),
        ReadBigEndian16(QuotedPayload + 2), ReadBigEndian32(QuotedPayload + 4), Message[0], Message[1]);
    IpProtocolIcmp:
      if QuotedPayload[0] = IcmpTypeEchoRequest then
        DeliverEchoMessage(Datagram, Message, Length, ReadBigEndian16(QuotedPayload + 4));
  end;
end;

procedure IcmpInput(constref Datagram: TIpv4Datagram; Message: PByte; Length: LongWord);
begin
  if (Length < IcmpHeaderBytes) or (InternetChecksum(Message, Length) <> 0) then
  begin
    Inc(NetworkStatistics.Icmp.Received);
    Inc(NetworkStatistics.Icmp.ReceiveErrors);
    CountReceiveError(Datagram.ArrivalInterface);
    Exit;
  end;
  CountIcmpReceived(Message[0]);
  DeliverToRawSockets(Datagram, Message, Length);
  case Message[0] of
    IcmpTypeEchoRequest:
      if not Datagram.IsBroadcast then
        SendEchoReply(Datagram, Message, Length);
    IcmpTypeEchoReply:
      DeliverEchoMessage(Datagram, Message, Length, ReadBigEndian16(Message + 4));
    IcmpTypeDestinationUnreachable, IcmpTypeTimeExceeded, IcmpTypeParameterProblem:
      HandleError(Datagram, Message, Length);
  end;
end;

function IsIcmpError(Original: PByte; HeaderLength, OriginalLength: LongWord): Boolean;
var
  OriginalType: Byte;
begin
  if (Original[9] <> IpProtocolIcmp) or (OriginalLength < HeaderLength + 1) then
    Exit(False);
  OriginalType := Original[HeaderLength];
  Result := (OriginalType <> IcmpTypeEchoRequest) and (OriginalType <> IcmpTypeEchoReply);
end;

procedure SendIcmpError(Original: PByte; OriginalLength: LongWord; IcmpType, Code: Byte);
var
  HeaderLength: LongWord;
  QuotedLength: LongWord;
  OriginalSource: TIpv4Address;
  Packet: PPacket;
  Message: PByte;
begin
  if OriginalLength < Ipv4HeaderBytes then
    Exit;
  HeaderLength := LongWord(Original[0] and $0F) * 4;
  OriginalSource := ReadIpv4Address(Original + 12);
  if (HeaderLength < Ipv4HeaderBytes) or (HeaderLength > OriginalLength) or
     (OriginalSource = AnyAddress) or (OriginalSource = LimitedBroadcastAddress) or
     IsMulticastAddress(OriginalSource) or ((ReadBigEndian16(Original + 6) and $1FFF) <> 0) or
     IsIcmpError(Original, HeaderLength, OriginalLength) then
    Exit;
  QuotedLength := HeaderLength + QuotedPayloadBytes;
  if QuotedLength > OriginalLength then
    QuotedLength := OriginalLength;
  Packet := AllocatePacket(PacketHeadroom);
  if Packet = nil then
    Exit;
  Message := AppendToPacket(Packet, IcmpHeaderBytes + QuotedLength);
  FillMemory(Message, IcmpHeaderBytes, 0);
  Message[0] := IcmpType;
  Message[1] := Code;
  CopyMemory(Message + IcmpHeaderBytes, Original, QuotedLength);
  WriteBigEndian16(Message + 2, InternetChecksum(Message, IcmpHeaderBytes + QuotedLength));
  SendIpv4(Packet, AnyAddress, OriginalSource, IpProtocolIcmp, DefaultTimeToLive, False, nil);
end;

procedure ReportUndeliverableDatagram(Original: PByte; OriginalLength: LongWord; Code: Byte);
begin
  if (OriginalLength >= Ipv4HeaderBytes) and IsLocalAddress(ReadIpv4Address(Original + 12)) then
    SendIcmpError(Original, OriginalLength, IcmpTypeDestinationUnreachable, Code);
end;

end.
