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
  Sending for UDP, TCP and the ICMP sockets whichever IP version their
  endpoints have: the source a datagram leaves with, how much it may
  carry, the pseudo-header sum of its checksum, and handing it to
  Network.Ipv4 or Network.Ipv6.

  For IPv6 the interface a datagram may leave by is the socket's bound
  interface, else the one a link-local destination's scope id names.
}
unit Network.IpOutput;

{$mode objfpc}

interface

uses
  Network.Addresses,
  Network.Packets,
  Network.Interfaces;

{ The source address (port 0) for a datagram to Destination.
  ErrorNetworkUnreachable if there is no route. }
function ChooseSourceAddress(constref Destination: TNetworkEndpoint; BoundInterface: PNetworkInterface;
  out Source: TNetworkEndpoint): LongInt;
{ Sends the packet (the protocol's header and data, with headroom) from
  Source (unspecified: chosen) to Destination. Takes the packet. }
function SendIpPacket(Packet: PPacket; constref Source, Destination: TNetworkEndpoint; Protocol, HopLimit: Byte;
  DontFragment: Boolean; BoundInterface: PNetworkInterface): LongInt;
{ The largest payload a datagram to Destination can carry; 0 if there
  is no route. }
function IpPayloadLimit(constref Destination: TNetworkEndpoint; BoundInterface: PNetworkInterface): LongWord;
{ The pseudo-header sum of a UDP, TCP or ICMPv6 checksum. }
function TransportPseudoHeaderSum(constref Source, Destination: TNetworkEndpoint; Protocol: Byte;
  Length: LongWord): LongWord;
{ The address is one of this machine's (or 127.x.x.x, ::1). }
function IsLocalEndpointAddress(constref Endpoint: TNetworkEndpoint): Boolean;

implementation

uses
  Abi.SystemCalls,
  Network.Ipv6Addresses,
  Network.Checksums,
  Network.Ipv4,
  Network.Ipv6,
  Network.Ipv6AddressList;

{ The interface an IPv6 datagram to Destination may leave by. }
function ScopeInterfaceOf(constref Destination: TNetworkEndpoint; BoundInterface: PNetworkInterface): PNetworkInterface;
begin
  Result := BoundInterface;
  if (Result = nil) and (Destination.ScopeId <> 0) then
    Result := FindInterfaceByIndex(Destination.ScopeId);
end;

function ChooseSourceAddress(constref Destination: TNetworkEndpoint; BoundInterface: PNetworkInterface;
  out Source: TNetworkEndpoint): LongInt;
var
  NetworkInterface: PNetworkInterface;
  NextHop: TIpv4Address;
  Source4: TIpv4Address;
  NextHop6: TIpv6Address;
  Source6: TIpv6Address;
begin
  if Destination.Family = AddressFamilyIPv6 then
  begin
    Result := RouteIpv6Datagram(Destination.Address6, ScopeInterfaceOf(Destination, BoundInterface),
      NetworkInterface, NextHop6, Source6);
    Source := MakeIpv6Endpoint(Source6, 0, Destination.ScopeId);
    if (Result = ErrorNone) and IsLinkLocalIpv6Address(Source6) then
      Source.ScopeId := NetworkInterface^.Index;
  end
  else
  begin
    Result := RouteDatagram(Destination.Address, BoundInterface, NetworkInterface, NextHop, Source4);
    Source := MakeEndpoint(Source4, 0);
  end;
end;

function SendIpPacket(Packet: PPacket; constref Source, Destination: TNetworkEndpoint; Protocol, HopLimit: Byte;
  DontFragment: Boolean; BoundInterface: PNetworkInterface): LongInt;
begin
  if Destination.Family = AddressFamilyIPv6 then
    Result := SendIpv6(Packet, Source.Address6, Destination.Address6, Protocol, HopLimit,
      ScopeInterfaceOf(Destination, BoundInterface))
  else
    Result := SendIpv4(Packet, Source.Address, Destination.Address, Protocol, HopLimit, DontFragment,
      BoundInterface);
end;

function IpPayloadLimit(constref Destination: TNetworkEndpoint; BoundInterface: PNetworkInterface): LongWord;
begin
  if Destination.Family = AddressFamilyIPv6 then
    Result := Ipv6PayloadLimit(Destination.Address6, ScopeInterfaceOf(Destination, BoundInterface))
  else
    Result := PayloadLimit(Destination.Address, BoundInterface);
end;

function TransportPseudoHeaderSum(constref Source, Destination: TNetworkEndpoint; Protocol: Byte;
  Length: LongWord): LongWord;
begin
  if Destination.Family = AddressFamilyIPv6 then
    Result := Ipv6PseudoHeaderSum(@Source.Address6[0], @Destination.Address6[0], Protocol, Length)
  else
    Result := PseudoHeaderSum(Source.Address, Destination.Address, Protocol, Length);
end;

function IsLocalEndpointAddress(constref Endpoint: TNetworkEndpoint): Boolean;
begin
  if Endpoint.Family = AddressFamilyIPv6 then
    Result := IsLocalIpv6Address(Endpoint.Address6)
  else
    Result := IsLocalAddress(Endpoint.Address);
end;

end.
