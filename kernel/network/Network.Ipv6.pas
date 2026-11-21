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
  IPv6 (RFC 8200): datagrams in and out.

  A datagram that arrives is checked (version, payload length), taken
  if it is for one of this machine's addresses (not a tentative one), or
  for a multicast group the interface listens to, and its extension
  headers are walked (Network.Ipv6Headers): hop-by-hop and destination
  options are looked through, a routing header with segments left is
  refused, a fragment goes to reassembly (Network.Ipv6Fragments) and the
  whole datagram is walked again. What is left goes to ICMPv6, UDP or
  TCP; another protocol gets a parameter problem back. Nothing is
  forwarded.

  Sending, a datagram to one of this machine's addresses goes through
  lo; one to a link-local address or a multicast group leaves by the
  interface its zone names (the socket's interface, the address's scope
  id, else the first Ethernet interface with IPv6); others follow the
  routes (Network.Ipv6Routing), or the first hop a redirect gave
  (Network.Ipv6DestinationCache). Its source is chosen by RFC 6724
  (Network.Ipv6AddressList). Multicast goes to its 33:33 Ethernet
  address, the rest to the next hop's through the neighbour cache. A
  datagram larger than the path MTU (the link's, or what a Packet Too
  Big said) is sent in fragments (Network.FragmentBuilder), each with
  the same random identification.
}
unit Network.Ipv6;

{$mode objfpc}
{$pointermath on}

interface

uses
  Network.Ipv6Addresses,
  Network.Packets,
  Network.Interfaces;

const
  Ipv6HeaderBytes = 40;
  NextHeaderHopByHop = 0;
  NextHeaderTcp = 6;
  NextHeaderUdp = 17;
  NextHeaderRouting = 43;
  NextHeaderFragment = 44;
  NextHeaderIcmpv6 = 58;
  NextHeaderNone = 59;
  NextHeaderDestinationOptions = 60;
  { Neighbor Discovery's messages go with this hop limit, and are
    believed only with it. }
  NeighborDiscoveryHopLimit = 255;

{ A datagram that arrived (Data: what follows the Ethernet header, or
  the whole frame on lo). }
procedure Ipv6Input(NetworkInterface: PNetworkInterface; Data: PByte; Length: LongWord);
{ Where a datagram to Destination goes: the interface, the next hop on
  it, and the source it is sent from. ScopeInterface (the socket's, or
  that of the destination's scope id) is the only interface it may
  leave by when it is not nil. ErrorNetworkUnreachable if no route
  covers it, ErrorAddressNotAvailable if the interface has no address
  to send it from. }
function RouteIpv6Datagram(constref Destination: TIpv6Address; ScopeInterface: PNetworkInterface;
  out NetworkInterface: PNetworkInterface; out NextHop: TIpv6Address; out Source: TIpv6Address): LongInt;
{ Sends the packet (the upper-layer header and data, with headroom) as
  the payload of a datagram. Source :: picks one. HopLimit 0: the
  interface's (64 unless a router said otherwise). Takes the packet,
  also on failure. }
function SendIpv6(Packet: PPacket; constref Source, Destination: TIpv6Address; NextHeader, HopLimit: Byte;
  ScopeInterface: PNetworkInterface): LongInt;
{ Puts the IPv6 header in front and sends it out of NetworkInterface to
  NextHop (for multicast, to the group), with Source as it is (:: too,
  as duplicate address detection needs). Takes the packet. }
function TransmitIpv6(Packet: PPacket; constref Source, Destination: TIpv6Address; NextHeader, HopLimit: Byte;
  NetworkInterface: PNetworkInterface; constref NextHop: TIpv6Address): LongInt;
{ Sends a payload too large for a packet (Payload, PayloadLength bytes:
  the upper-layer header and data) in fragments, routed as SendIpv6
  does. }
function SendLargeIpv6(Payload: PByte; PayloadLength: LongWord; constref Source, Destination: TIpv6Address;
  NextHeader, HopLimit: Byte; ScopeInterface: PNetworkInterface): LongInt;
{ The largest payload a datagram to Destination can carry without
  fragments (the path MTU less the header); 0 if there is no route. }
function Ipv6PayloadLimit(constref Destination: TIpv6Address; ScopeInterface: PNetworkInterface): LongWord;
{ The MTU of IPv6 on the interface: what a router advertised, else the
  interface's. }
function Ipv6LinkMtu(NetworkInterface: PNetworkInterface): LongWord;

implementation

uses
  Abi.SystemCalls,
  Runtime.Memory,
  Memory.KernelHeap,
  Network.ByteOrder,
  Network.Addresses,
  Network.IpDatagrams,
  Network.Ipv6Types,
  Network.Ipv6AddressList,
  Network.Ipv6Routing,
  Network.Ipv6Headers,
  Network.Ipv6Fragments,
  Network.Ipv6DestinationCache,
  Network.FragmentBuilder,
  Kernel.Random,
  Network.NeighborCache,
  Network.Ethernet,
  Network.Loopback,
  Network.Icmpv6,
  Network.Udp,
  Network.TcpInput,
  Network.Statistics;

function Ipv6LinkMtu(NetworkInterface: PNetworkInterface): LongWord;
begin
  Result := NetworkInterface^.Mtu;
  if (NetworkInterface^.Ipv6.Mtu <> 0) and (NetworkInterface^.Ipv6.Mtu < Result) then
    Result := NetworkInterface^.Ipv6.Mtu;
end;

{ --- Input --------------------------------------------------------------- }

function AcceptsDestination(NetworkInterface: PNetworkInterface; constref Destination: TIpv6Address): Boolean;
begin
  if IsMulticastIpv6Address(Destination) then
    Result := NetworkInterface^.IsLoopback or InterfaceListensToIpv6Group(NetworkInterface, Destination)
  else
    Result := IsLocalIpv6Address(Destination);
end;

procedure DeliverDatagram(constref Datagram: TIpDatagram);
var
  Payload: PByte;
  PayloadLength: LongWord;
begin
  Payload := Datagram.Header + Datagram.HeaderLength;
  PayloadLength := Datagram.TotalLength - Datagram.HeaderLength;
  if Datagram.Protocol in [NextHeaderIcmpv6, NextHeaderUdp, NextHeaderTcp] then
    Inc(NetworkStatistics.Ipv6.Delivered);
  case Datagram.Protocol of
    NextHeaderIcmpv6: Icmpv6Input(Datagram, Payload, PayloadLength);
    NextHeaderUdp: UdpInput(Datagram, Payload, PayloadLength);
    NextHeaderTcp: TcpInput(Datagram, Payload, PayloadLength);
  end;
end;

procedure HandleWalkedDatagram(var Datagram: TIpDatagram; constref Walk: TIpv6HeaderWalk;
  AlreadyReassembled: Boolean);
var
  Whole: PByte;
  WholeLength: LongWord;
begin
  case Walk.Outcome of
    WalkReachedUpperLayer:
      begin
        Datagram.Protocol := Walk.NextHeader;
        Datagram.HeaderLength := Walk.Offset;
        if Walk.NextHeader in [NextHeaderIcmpv6, NextHeaderUdp, NextHeaderTcp] then
          DeliverDatagram(Datagram)
        else
        begin
          Inc(NetworkStatistics.Ipv6.UnknownProtocols);
          SendIcmpv6Error(Datagram.Header, Datagram.TotalLength, Icmpv6TypeParameterProblem,
            Icmpv6CodeUnknownNextHeader, Walk.NextHeaderPointer);
        end;
      end;
    WalkReachedFragment:
      begin
        Inc(NetworkStatistics.Ipv6.ReassemblyFragments);
        if AlreadyReassembled then
          Exit;
        if not AddIpv6Fragment(Datagram, Walk, Whole, WholeLength) then
          Exit;
        Inc(NetworkStatistics.Ipv6.Reassembled);
        Datagram.Header := Whole;
        Datagram.TotalLength := WholeLength;
        HandleWalkedDatagram(Datagram, WalkIpv6Headers(Whole, WholeLength), True);
        FreeKernelMemory(Whole);
      end;
    WalkParameterProblem:
      begin
        Inc(NetworkStatistics.Ipv6.HeaderErrors);
        SendIcmpv6Error(Datagram.Header, Datagram.TotalLength, Icmpv6TypeParameterProblem, Walk.ProblemCode,
          Walk.ProblemPointer);
      end;
    WalkMalformed:
      Inc(NetworkStatistics.Ipv6.HeaderErrors);
  end;
end;

procedure Ipv6Input(NetworkInterface: PNetworkInterface; Data: PByte; Length: LongWord);
var
  Datagram: TIpDatagram;
  PayloadLength: LongWord;
begin
  Inc(NetworkStatistics.Ipv6.Received);
  if (Length < Ipv6HeaderBytes) or ((Data[0] shr 4) <> 6) then
  begin
    Inc(NetworkStatistics.Ipv6.HeaderErrors);
    CountReceiveError(NetworkInterface);
    Exit;
  end;
  PayloadLength := ReadBigEndian16(Data + 4);
  if Ipv6HeaderBytes + PayloadLength > Length then
  begin
    Inc(NetworkStatistics.Ipv6.HeaderErrors);
    CountReceiveError(NetworkInterface);
    Exit;
  end;
  if NetworkInterface^.Ipv6.Mode = Ipv6ModeOff then
  begin
    CountReceiveDrop(NetworkInterface);
    Exit;
  end;
  FillMemory(@Datagram, SizeOf(Datagram), 0);
  Datagram.Family := AddressFamilyIPv6;
  CopyMemory(@Datagram.Source6[0], Data + 8, Ipv6AddressLength);
  CopyMemory(@Datagram.Destination6[0], Data + 24, Ipv6AddressLength);
  Datagram.TimeToLive := Data[7];
  Datagram.ArrivalInterface := NetworkInterface;
  Datagram.Header := Data;
  Datagram.TotalLength := Ipv6HeaderBytes + PayloadLength;
  Datagram.IsBroadcast := IsMulticastIpv6Address(Datagram.Destination6);
  if IsMulticastIpv6Address(Datagram.Source6) then
  begin
    Inc(NetworkStatistics.Ipv6.AddressErrors);
    CountReceiveDrop(NetworkInterface);
    Exit;
  end;
  if not AcceptsDestination(NetworkInterface, Datagram.Destination6) then
  begin
    { Multicast for groups nobody here joined is no error. }
    if not Datagram.IsBroadcast then
      Inc(NetworkStatistics.Ipv6.AddressErrors);
    CountReceiveDrop(NetworkInterface);
    Exit;
  end;
  HandleWalkedDatagram(Datagram, WalkIpv6Headers(Data, Datagram.TotalLength), False);
end;

{ --- Output -------------------------------------------------------------- }

{ The interface a link-scope destination leaves by without a zone: the
  first Ethernet interface that is up and does IPv6. }
function DefaultScopeInterface: PNetworkInterface;
var
  Position: Integer;
begin
  for Position := 0 to NetworkInterfaceCount - 1 do
  begin
    Result := NetworkInterfaceAt(Position);
    if not Result^.IsLoopback and InterfaceIsUsable(Result) and (Result^.Ipv6.Mode <> Ipv6ModeOff) then
      Exit;
  end;
  Result := nil;
end;

function RouteIpv6Datagram(constref Destination: TIpv6Address; ScopeInterface: PNetworkInterface;
  out NetworkInterface: PNetworkInterface; out NextHop: TIpv6Address; out Source: TIpv6Address): LongInt;
var
  Redirected: TIpv6Address;
begin
  NextHop := Destination;
  Source := UnspecifiedIpv6Address;
  NetworkInterface := nil;
  if IsLocalIpv6Address(Destination) then
  begin
    NetworkInterface := LoopbackInterface;
    Source := Destination;
    Exit(ErrorNone);
  end;
  if IsLinkLocalIpv6Address(Destination) or IsMulticastIpv6Address(Destination) then
  begin
    NetworkInterface := ScopeInterface;
    if NetworkInterface = nil then
      NetworkInterface := DefaultScopeInterface;
    if (NetworkInterface = nil) or not InterfaceIsUsable(NetworkInterface) then
      Exit(ErrorNetworkUnreachable);
  end
  else
  begin
    if not LookupIpv6Route(Destination, ScopeInterface, NetworkInterface, NextHop) then
      Exit(ErrorNetworkUnreachable);
    { A redirect knows a better first hop on the same link. }
    if FindIpv6Redirect(NetworkInterface, Destination, Redirected) then
      NextHop := Redirected;
  end;
  if NetworkInterface^.Ipv6.Mode = Ipv6ModeOff then
    Exit(ErrorNetworkUnreachable);
  if not SelectIpv6Source(NetworkInterface, Destination, Source) then
    Exit(ErrorAddressNotAvailable);
  Result := ErrorNone;
end;

function Ipv6PayloadLimit(constref Destination: TIpv6Address; ScopeInterface: PNetworkInterface): LongWord;
var
  NetworkInterface: PNetworkInterface;
  NextHop: TIpv6Address;
  Source: TIpv6Address;
begin
  if RouteIpv6Datagram(Destination, ScopeInterface, NetworkInterface, NextHop, Source) <> ErrorNone then
    Exit(0);
  Result := Ipv6PathMtu(NetworkInterface, Destination) - Ipv6HeaderBytes;
end;

{ Counts an ICMPv6 message going out (behind a hop-by-hop header too). }
procedure CountOutgoingIcmpv6(Packet: PPacket; NextHeader: Byte);
var
  Data: PByte;
begin
  Data := PacketData(Packet);
  if (NextHeader = NextHeaderIcmpv6) and (Packet^.Length > 0) then
    CountIcmpv6Sent(Data[0])
  else if (NextHeader = NextHeaderHopByHop) and (Packet^.Length > 8) and (Data[0] = NextHeaderIcmpv6) then
    CountIcmpv6Sent(Data[8]);
end;

procedure WriteHeader(Header: PByte; PayloadLength: LongWord; constref Source, Destination: TIpv6Address;
  NextHeader, HopLimit: Byte);
begin
  FillMemory(Header, 4, 0);
  Header[0] := $60;
  WriteBigEndian16(Header + 4, Word(PayloadLength));
  Header[6] := NextHeader;
  Header[7] := HopLimit;
  CopyMemory(Header + 8, @Source[0], Ipv6AddressLength);
  CopyMemory(Header + 24, @Destination[0], Ipv6AddressLength);
end;

{ Hands a whole datagram (header first) to the link: lo, a multicast
  group's Ethernet address, or the next hop through the neighbour
  cache. Takes the packet. }
procedure DeliverToLink(Packet: PPacket; constref Destination: TIpv6Address; NetworkInterface: PNetworkInterface;
  constref NextHop: TIpv6Address);
begin
  Packet^.NetworkInterface := NetworkInterface;
  if NetworkInterface^.IsLoopback then
    TransmitInterfaceFrame(NetworkInterface, Packet)
  else if IsMulticastIpv6Address(Destination) then
    SendEthernetFrame(NetworkInterface, MulticastEthernetAddress(Destination), EtherTypeIpv6, Packet)
  else
    SendToIpv6Neighbor(NetworkInterface, NextHop, Packet);
end;

{ Cuts the datagram at Datagram (header first, Length bytes) into
  fragments of at most Mtu bytes and sends each. }
function SendFragments(Datagram: PByte; Length, Mtu: LongWord; constref Destination: TIpv6Address;
  NetworkInterface: PNetworkInterface; constref NextHop: TIpv6Address): LongInt;
var
  Plan: TFragmentPlan;
  Identification: LongWord;
  Index: LongWord;
  Fragment: PPacket;
  Space: PByte;
  FragmentLength: LongWord;
begin
  if (Mtu > PacketCapacity - PacketHeadroom) or not PlanIpv6Fragments(Datagram, Length, Mtu, Plan) then
  begin
    Inc(NetworkStatistics.Ipv6.SendDiscards);
    Exit(ErrorMessageTooLong);
  end;
  Identification := LongWord(RandomQWord);
  Inc(NetworkStatistics.Ipv6.FragmentedDatagrams);
  for Index := 0 to Plan.FragmentCount - 1 do
  begin
    Fragment := AllocatePacket(PacketHeadroom);
    if Fragment = nil then
    begin
      Inc(NetworkStatistics.Ipv6.SendDiscards);
      Exit(ErrorOutOfMemory);
    end;
    Space := AppendToPacket(Fragment, Mtu);
    FragmentLength := BuildIpv6Fragment(Datagram, Plan, Index, Identification, Space);
    Fragment^.Length := FragmentLength;
    Inc(NetworkStatistics.Ipv6.FragmentsCreated);
    DeliverToLink(Fragment, Destination, NetworkInterface, NextHop);
  end;
  Result := ErrorNone;
end;

function TransmitIpv6(Packet: PPacket; constref Source, Destination: TIpv6Address; NextHeader, HopLimit: Byte;
  NetworkInterface: PNetworkInterface; constref NextHop: TIpv6Address): LongInt;
var
  Header: PByte;
  Mtu: LongWord;
begin
  CountOutgoingIcmpv6(Packet, NextHeader);
  Header := PrependToPacket(Packet, Ipv6HeaderBytes);
  if Header = nil then
  begin
    Inc(NetworkStatistics.Ipv6.SendDiscards);
    FreePacket(Packet);
    Exit(ErrorOutOfMemory);
  end;
  if HopLimit = 0 then
    HopLimit := NetworkInterface^.Ipv6.HopLimit;
  WriteHeader(Header, Packet^.Length - Ipv6HeaderBytes, Source, Destination, NextHeader, HopLimit);
  Mtu := Ipv6PathMtu(NetworkInterface, Destination);
  if Packet^.Length <= Mtu then
  begin
    DeliverToLink(Packet, Destination, NetworkInterface, NextHop);
    Exit(ErrorNone);
  end;
  Result := SendFragments(Header, Packet^.Length, Mtu, Destination, NetworkInterface, NextHop);
  FreePacket(Packet);
end;

function SendLargeIpv6(Payload: PByte; PayloadLength: LongWord; constref Source, Destination: TIpv6Address;
  NextHeader, HopLimit: Byte; ScopeInterface: PNetworkInterface): LongInt;
var
  NetworkInterface: PNetworkInterface;
  NextHop: TIpv6Address;
  RoutedSource: TIpv6Address;
  ChosenSource: TIpv6Address;
  Datagram: PByte;
begin
  Inc(NetworkStatistics.Ipv6.SendRequests);
  if PayloadLength > $FFFF then
  begin
    Inc(NetworkStatistics.Ipv6.SendDiscards);
    Exit(ErrorMessageTooLong);
  end;
  Result := RouteIpv6Datagram(Destination, ScopeInterface, NetworkInterface, NextHop, RoutedSource);
  if Result <> ErrorNone then
  begin
    Inc(NetworkStatistics.Ipv6.NoRoutes);
    Exit;
  end;
  ChosenSource := Source;
  if IsUnspecifiedIpv6Address(ChosenSource) then
    ChosenSource := RoutedSource;
  Datagram := AllocateKernelMemory(Ipv6HeaderBytes + PayloadLength);
  if Datagram = nil then
  begin
    Inc(NetworkStatistics.Ipv6.SendDiscards);
    Exit(ErrorOutOfMemory);
  end;
  if HopLimit = 0 then
    HopLimit := NetworkInterface^.Ipv6.HopLimit;
  WriteHeader(Datagram, PayloadLength, ChosenSource, Destination, NextHeader, HopLimit);
  CopyMemory(Datagram + Ipv6HeaderBytes, Payload, PayloadLength);
  Result := SendFragments(Datagram, Ipv6HeaderBytes + PayloadLength, Ipv6PathMtu(NetworkInterface, Destination),
    Destination, NetworkInterface, NextHop);
  FreeKernelMemory(Datagram);
end;

function SendIpv6(Packet: PPacket; constref Source, Destination: TIpv6Address; NextHeader, HopLimit: Byte;
  ScopeInterface: PNetworkInterface): LongInt;
var
  NetworkInterface: PNetworkInterface;
  NextHop: TIpv6Address;
  RoutedSource: TIpv6Address;
  ChosenSource: TIpv6Address;
begin
  Inc(NetworkStatistics.Ipv6.SendRequests);
  Result := RouteIpv6Datagram(Destination, ScopeInterface, NetworkInterface, NextHop, RoutedSource);
  if Result <> ErrorNone then
  begin
    Inc(NetworkStatistics.Ipv6.NoRoutes);
    if NextHeader = NextHeaderIcmpv6 then
      Inc(NetworkStatistics.Icmpv6.SendErrors);
    FreePacket(Packet);
    Exit;
  end;
  ChosenSource := Source;
  if IsUnspecifiedIpv6Address(ChosenSource) then
    ChosenSource := RoutedSource;
  Result := TransmitIpv6(Packet, ChosenSource, Destination, NextHeader, HopLimit, NetworkInterface, NextHop);
end;

end.
