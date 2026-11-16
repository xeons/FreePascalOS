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
  Network.Sockets;

const
  UdpHeaderBytes = 8;

procedure UdpInput(constref Datagram: TIpv4Datagram; Payload: PByte; Length: LongWord);
{ An ICMP error about a datagram we sent (its endpoints as we sent it). }
procedure UdpReportError(Source, Destination: TIpv4Address; SourcePort, DestinationPort: Word;
  IcmpType, Code: Byte);
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
  Network.Icmp;

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

procedure UdpInput(constref Datagram: TIpv4Datagram; Payload: PByte; Length: LongWord);
var
  DatagramLength: LongWord;
  Checksum: Word;
  Sum: LongWord;
  Source: TNetworkEndpoint;
  DestinationPort: Word;
  Socket: PSocket;
  Best: PSocket;
  Delivered: Boolean;
begin
  if Length < UdpHeaderBytes then
  begin
    CountReceiveError(Datagram.ArrivalInterface);
    Exit;
  end;
  DatagramLength := ReadBigEndian16(Payload + 4);
  Checksum := ReadBigEndian16(Payload + 6);
  if (DatagramLength < UdpHeaderBytes) or (DatagramLength > Length) then
  begin
    CountReceiveError(Datagram.ArrivalInterface);
    Exit;
  end;
  if Checksum <> 0 then
  begin
    Sum := PseudoHeaderSum(Datagram.Source, Datagram.Destination, IpProtocolUdp, DatagramLength);
    if FinishChecksum(AddToChecksum(Sum, Payload, DatagramLength)) <> 0 then
    begin
      CountReceiveError(Datagram.ArrivalInterface);
      Exit;
    end;
  end;
  Source := MakeEndpoint(Datagram.Source, ReadBigEndian16(Payload));
  DestinationPort := ReadBigEndian16(Payload + 2);

  Best := nil;
  Delivered := False;
  Socket := FirstSocket;
  while Socket <> nil do
  begin
    if (Socket^.Protocol = SocketProtocolUdp) and
       DatagramSocketMatches(Socket, Source, Datagram.Destination, DestinationPort, Datagram.IsBroadcast,
         Datagram.ArrivalInterface) then
    begin
      if Datagram.IsBroadcast then
      begin
        QueueDatagramForSocket(Socket, Source, Datagram.TimeToLive, Payload + UdpHeaderBytes,
          DatagramLength - UdpHeaderBytes);
        Delivered := True;
      end
      else if (Best = nil) or ((Best^.Local.Address = AnyAddress) and (Socket^.Local.Address <> AnyAddress)) or
              (not Best^.IsConnected and Socket^.IsConnected) then
        Best := Socket;
    end;
    Socket := NextSocket(Socket);
  end;
  if Best <> nil then
  begin
    QueueDatagramForSocket(Best, Source, Datagram.TimeToLive, Payload + UdpHeaderBytes,
      DatagramLength - UdpHeaderBytes);
    Exit;
  end;
  if not Delivered and not Datagram.IsBroadcast then
    SendIcmpError(Datagram.Header, Datagram.TotalLength, IcmpTypeDestinationUnreachable, IcmpCodePortUnreachable);
end;

procedure UdpReportError(Source, Destination: TIpv4Address; SourcePort, DestinationPort: Word;
  IcmpType, Code: Byte);
var
  Socket: PSocket;
begin
  if IcmpType <> IcmpTypeDestinationUnreachable then
    Exit;
  Socket := FirstSocket;
  while Socket <> nil do
  begin
    if (Socket^.Protocol = SocketProtocolUdp) and Socket^.IsConnected and (Socket^.Local.Port = SourcePort) and
       (Socket^.Peer.Address = Destination) and (Socket^.Peer.Port = DestinationPort) then
    begin
      if Code = IcmpCodePortUnreachable then
        Socket^.PendingError := ErrorConnectionRefused
      else
        Socket^.PendingError := ErrorHostUnreachable;
      UpdateSocketReadiness(Socket);
    end;
    Socket := NextSocket(Socket);
  end;
end;

function SendUdpDatagram(Socket: PSocket; Data: PByte; Length: LongWord;
  constref Destination: TNetworkEndpoint): Int64;
var
  Target: TNetworkEndpoint;
  Source: TIpv4Address;
  Packet: PPacket;
  Header: PByte;
  Sum: LongWord;
  Checksum: Word;
  Error: LongInt;
begin
  Target := Destination;
  if Target.Address = AnyAddress then
    Target.Address := LoopbackAddress;
  if Target.Port = 0 then
    Exit(-ErrorInvalidArgument);
  if IsBroadcastAddress(Target.Address, Socket^.BoundInterface) and not Socket^.BroadcastAllowed then
    Exit(-ErrorAccessDenied);
  Error := DatagramSourceAddress(Socket, Target.Address, Source);
  if Error <> ErrorNone then
    Exit(-Error);
  if (Length > MaximumDatagramBytes) or
     (Length + UdpHeaderBytes > PayloadLimit(Target.Address, Socket^.BoundInterface)) then
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
  Sum := PseudoHeaderSum(Source, Target.Address, IpProtocolUdp, UdpHeaderBytes + Length);
  Checksum := FinishChecksum(AddToChecksum(Sum, Header, UdpHeaderBytes + Length));
  { Zero means "no checksum"; the same value in ones' complement is all
    ones. }
  if Checksum = 0 then
    Checksum := $FFFF;
  WriteBigEndian16(Header + 6, Checksum);
  Error := SendIpv4(Packet, Source, Target.Address, IpProtocolUdp, Socket^.TimeToLive, False,
    Socket^.BoundInterface);
  if Error <> ErrorNone then
    Exit(-Error);
  Result := Length;
end;

end.
