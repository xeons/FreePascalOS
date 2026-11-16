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
  IPv4 (RFC 791): datagrams in and out.

  Received datagrams are checked (version, lengths, header checksum)
  and taken if they are for this machine: one of its addresses on any
  interface, the limited broadcast 255.255.255.255, the broadcast
  address of the network they arrived from, or (UDP only) anything on
  an interface without an address yet, which a DHCP client needs.
  Nothing is forwarded. Fragments are put together first
  (Network.Fragments); then the datagram goes to ICMP, UDP or TCP, and
  a protocol nobody speaks is answered with protocol unreachable.

  Sending picks the route (or the loopback interface for an address of
  this machine, or for a broadcast the interface it is meant for), the
  source address if the sender has none, and puts the header in front.
  Datagrams are never fragmented: one that does not fit the interface's
  MTU fails with ErrorMessageTooLong. TCP sets "don't fragment".
}
unit Network.Ipv4;

{$mode objfpc}
{$pointermath on}

interface

uses
  Network.Addresses,
  Network.Packets,
  Network.Interfaces;

const
  Ipv4HeaderBytes = 20;
  DefaultTimeToLive = 64;
  IpProtocolIcmp = 1;
  IpProtocolTcp = 6;
  IpProtocolUdp = 17;

type
  { A received datagram, as the protocols above see it. }
  TIpv4Datagram = record
    Source: TIpv4Address;
    Destination: TIpv4Address;
    Protocol: Byte;
    TimeToLive: Byte;
    { Sent to a broadcast address. }
    IsBroadcast: Boolean;
    ArrivalInterface: PNetworkInterface;
    { The whole datagram, header first (for ICMP errors about it). }
    Header: PByte;
    HeaderLength: LongWord;
    TotalLength: LongWord;
  end;

{ A datagram that arrived (Data: what follows the Ethernet header, or
  the whole frame on lo). }
procedure Ipv4Input(NetworkInterface: PNetworkInterface; Data: PByte; Length: LongWord);
{ Where a datagram to Destination goes: the interface, the next hop on
  it, and the source address it is sent from. BoundInterface, if not
  nil, is the only interface it may leave by. ErrorNetworkUnreachable if
  no route covers it. }
function RouteDatagram(Destination: TIpv4Address; BoundInterface: PNetworkInterface;
  out NetworkInterface: PNetworkInterface; out NextHop: TIpv4Address; out Source: TIpv4Address): LongInt;
{ Sends the packet (the protocol's header and data, with headroom) as
  the payload of a datagram. Source AnyAddress: the address of the
  interface it leaves by. Takes the packet, also on failure. }
function SendIpv4(Packet: PPacket; Source, Destination: TIpv4Address; Protocol, TimeToLive: Byte;
  DontFragment: Boolean; BoundInterface: PNetworkInterface): LongInt;
{ The largest payload a datagram to Destination can carry; 0 if there
  is no route. }
function PayloadLimit(Destination: TIpv4Address; BoundInterface: PNetworkInterface): LongWord;

implementation

uses
  Abi.SystemCalls,
  Io.NetworkAdapters,
  Network.ByteOrder,
  Network.Checksums,
  Network.Routing,
  Network.Ethernet,
  Network.Arp,
  Network.Loopback,
  Network.Fragments,
  Network.Icmp,
  Network.Udp,
  Network.TcpInput,
  Memory.KernelHeap;

const
  FlagDontFragment = $4000;
  FlagMoreFragments = $2000;
  FragmentOffsetMask = $1FFF;

var
  NextIdentification: Word;

function IsBroadcastFor(NetworkInterface: PNetworkInterface; Destination: TIpv4Address): Boolean;
begin
  if Destination = LimitedBroadcastAddress then
    Exit(True);
  Result := NetworkInterface^.HasAddress and (NetworkInterface^.PrefixLength < 31) and
    (Destination = InterfaceBroadcastAddress(NetworkInterface));
end;

function AcceptsDestination(NetworkInterface: PNetworkInterface; Destination: TIpv4Address;
  Protocol: Byte): Boolean;
begin
  if IsBroadcastFor(NetworkInterface, Destination) then
    Exit(True);
  if IsLocalAddress(Destination) then
    Exit(True);
  Result := not NetworkInterface^.HasAddress and (Protocol = IpProtocolUdp);
end;

procedure DeliverDatagram(constref Datagram: TIpv4Datagram);
var
  Payload: PByte;
  PayloadLength: LongWord;
begin
  Payload := Datagram.Header + Datagram.HeaderLength;
  PayloadLength := Datagram.TotalLength - Datagram.HeaderLength;
  case Datagram.Protocol of
    IpProtocolIcmp: IcmpInput(Datagram, Payload, PayloadLength);
    IpProtocolUdp: UdpInput(Datagram, Payload, PayloadLength);
    IpProtocolTcp: TcpInput(Datagram, Payload, PayloadLength);
  else
    if not Datagram.IsBroadcast then
      SendIcmpError(Datagram.Header, Datagram.TotalLength, IcmpTypeDestinationUnreachable,
        IcmpCodeProtocolUnreachable);
  end;
end;

procedure Ipv4Input(NetworkInterface: PNetworkInterface; Data: PByte; Length: LongWord);
var
  Datagram: TIpv4Datagram;
  Flags: Word;
  FragmentOffset: LongWord;
  Whole: PByte;
  WholeLength: LongWord;
begin
  if (Length < Ipv4HeaderBytes) or ((Data[0] shr 4) <> 4) then
  begin
    CountReceiveError(NetworkInterface);
    Exit;
  end;
  Datagram.HeaderLength := LongWord(Data[0] and $0F) * 4;
  Datagram.TotalLength := ReadBigEndian16(Data + 2);
  if (Datagram.HeaderLength < Ipv4HeaderBytes) or (Datagram.TotalLength < Datagram.HeaderLength) or
     (Datagram.TotalLength > Length) or (InternetChecksum(Data, Datagram.HeaderLength) <> 0) then
  begin
    CountReceiveError(NetworkInterface);
    Exit;
  end;
  Datagram.Source := ReadIpv4Address(Data + 12);
  Datagram.Destination := ReadIpv4Address(Data + 16);
  Datagram.Protocol := Data[9];
  Datagram.TimeToLive := Data[8];
  Datagram.ArrivalInterface := NetworkInterface;
  Datagram.Header := Data;
  if (Datagram.Source = LimitedBroadcastAddress) or IsMulticastAddress(Datagram.Source) or
     IsMulticastAddress(Datagram.Destination) or
     not AcceptsDestination(NetworkInterface, Datagram.Destination, Datagram.Protocol) then
  begin
    CountReceiveDrop(NetworkInterface);
    Exit;
  end;
  Datagram.IsBroadcast := IsBroadcastFor(NetworkInterface, Datagram.Destination);

  Flags := ReadBigEndian16(Data + 6);
  FragmentOffset := LongWord(Flags and FragmentOffsetMask) * 8;
  if ((Flags and FlagMoreFragments) = 0) and (FragmentOffset = 0) then
  begin
    DeliverDatagram(Datagram);
    Exit;
  end;
  if not AddFragment(Datagram, ReadBigEndian16(Data + 4), FragmentOffset,
       (Flags and FlagMoreFragments) <> 0, Whole, WholeLength) then
    Exit;
  { The whole datagram, its header without fragment fields. }
  Datagram.Header := Whole;
  Datagram.HeaderLength := Ipv4HeaderBytes;
  Datagram.TotalLength := WholeLength;
  DeliverDatagram(Datagram);
  FreeKernelMemory(Whole);
end;

{ The interface a broadcast to Destination leaves by. }
function BroadcastInterface(Destination: TIpv4Address; BoundInterface: PNetworkInterface): PNetworkInterface;
var
  Position: Integer;
  Candidate: PNetworkInterface;
  NextHop: TIpv4Address;
begin
  if BoundInterface <> nil then
    Exit(BoundInterface);
  for Position := 0 to NetworkInterfaceCount - 1 do
  begin
    Candidate := NetworkInterfaceAt(Position);
    if not Candidate^.IsLoopback and Candidate^.IsUp and Candidate^.HasAddress and
       (Destination <> LimitedBroadcastAddress) and (Destination = InterfaceBroadcastAddress(Candidate)) then
      Exit(Candidate);
  end;
  { The limited broadcast: the interface of the default route, else the
    first one that is up. }
  if LookupRoute(AnyAddress, Result, NextHop) and not Result^.IsLoopback then
    Exit;
  for Position := 0 to NetworkInterfaceCount - 1 do
  begin
    Candidate := NetworkInterfaceAt(Position);
    if not Candidate^.IsLoopback and Candidate^.IsUp then
      Exit(Candidate);
  end;
  Result := nil;
end;

function IsBroadcastDestination(Destination: TIpv4Address; BoundInterface: PNetworkInterface): Boolean;
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
       IsBroadcastFor(Candidate, Destination) then
      Exit(True);
  end;
  Result := False;
end;

function RouteDatagram(Destination: TIpv4Address; BoundInterface: PNetworkInterface;
  out NetworkInterface: PNetworkInterface; out NextHop: TIpv4Address; out Source: TIpv4Address): LongInt;
var
  Owner: PNetworkInterface;
begin
  NextHop := Destination;
  Source := AnyAddress;
  NetworkInterface := nil;
  if IsLocalAddress(Destination) then
  begin
    NetworkInterface := LoopbackInterface;
    Owner := FindInterfaceWithAddress(Destination);
    if Owner <> nil then
      Source := Destination
    else
      Source := LoopbackAddress;
    Exit(ErrorNone);
  end;
  if IsBroadcastDestination(Destination, BoundInterface) then
  begin
    NetworkInterface := BroadcastInterface(Destination, BoundInterface);
    if NetworkInterface = nil then
      Exit(ErrorNetworkUnreachable);
  end
  else if BoundInterface <> nil then
  begin
    NetworkInterface := BoundInterface;
    if not LookupRoute(Destination, Owner, NextHop) or (Owner <> BoundInterface) then
      NextHop := Destination;
  end
  else if not LookupRoute(Destination, NetworkInterface, NextHop) then
    Exit(ErrorNetworkUnreachable);
  if not NetworkInterface^.IsUp then
    Exit(ErrorNetworkUnreachable);
  if NetworkInterface^.HasAddress then
    Source := NetworkInterface^.Address;
  Result := ErrorNone;
end;

function PayloadLimit(Destination: TIpv4Address; BoundInterface: PNetworkInterface): LongWord;
var
  NetworkInterface: PNetworkInterface;
  NextHop: TIpv4Address;
  Source: TIpv4Address;
begin
  if RouteDatagram(Destination, BoundInterface, NetworkInterface, NextHop, Source) <> ErrorNone then
    Exit(0);
  Result := NetworkInterface^.Mtu - Ipv4HeaderBytes;
end;

procedure WriteHeader(Header: PByte; TotalLength: LongWord; Source, Destination: TIpv4Address;
  Protocol, TimeToLive: Byte; DontFragment: Boolean);
begin
  Header[0] := $45;
  Header[1] := 0;
  WriteBigEndian16(Header + 2, Word(TotalLength));
  WriteBigEndian16(Header + 4, NextIdentification);
  Inc(NextIdentification);
  if DontFragment then
    WriteBigEndian16(Header + 6, FlagDontFragment)
  else
    WriteBigEndian16(Header + 6, 0);
  Header[8] := TimeToLive;
  Header[9] := Protocol;
  WriteBigEndian16(Header + 10, 0);
  WriteIpv4Address(Header + 12, Source);
  WriteIpv4Address(Header + 16, Destination);
  WriteBigEndian16(Header + 10, InternetChecksum(Header, Ipv4HeaderBytes));
end;

function SendIpv4(Packet: PPacket; Source, Destination: TIpv4Address; Protocol, TimeToLive: Byte;
  DontFragment: Boolean; BoundInterface: PNetworkInterface): LongInt;
var
  NetworkInterface: PNetworkInterface;
  NextHop: TIpv4Address;
  RoutedSource: TIpv4Address;
  Header: PByte;
begin
  Result := RouteDatagram(Destination, BoundInterface, NetworkInterface, NextHop, RoutedSource);
  if Result = ErrorNone then
  begin
    if Source = AnyAddress then
      Source := RoutedSource;
    if Packet^.Length + Ipv4HeaderBytes > NetworkInterface^.Mtu then
      Result := ErrorMessageTooLong;
  end;
  if Result <> ErrorNone then
  begin
    FreePacket(Packet);
    Exit;
  end;
  Header := PrependToPacket(Packet, Ipv4HeaderBytes);
  if Header = nil then
  begin
    FreePacket(Packet);
    Exit(ErrorOutOfMemory);
  end;
  WriteHeader(Header, Packet^.Length, Source, Destination, Protocol, TimeToLive, DontFragment);
  Packet^.NetworkInterface := NetworkInterface;
  if NetworkInterface^.IsLoopback then
    TransmitInterfaceFrame(NetworkInterface, Packet)
  else if IsBroadcastDestination(Destination, BoundInterface) then
    SendEthernetFrame(NetworkInterface, BroadcastEthernetAddress, EtherTypeIpv4, Packet)
  else
    SendToNeighbour(NetworkInterface, NextHop, Packet);
end;

end.
