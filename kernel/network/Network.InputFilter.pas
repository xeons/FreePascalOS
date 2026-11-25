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
  Martian addresses (RFC 1812 5.3.7, RFC 1122 3.2.1.3, RFC 4291 2.5):
  which source and destination addresses an arriving datagram may not
  have, given what the interface it came in on is.

  On every interface: a source that is the limited broadcast or a
  multicast group, or 0.0.0.0 for anything but UDP and IGMP (a DHCP
  client, an IGMPv3 report); a destination of 0.0.0.0; an IPv6 source
  that is a multicast group; an IPv6 source or destination that is
  IPv4-mapped (::ffff:0:0/96 never appears on the wire, RFC 4291
  2.5.5.2); an IPv6 destination of ::.

  On any interface but lo: the loopback addresses 127.0.0.0/8 and ::1,
  as source or destination (a datagram to 127.0.0.1 from the LAN must
  never reach a service that listens only on lo), a source that is one
  of this machine's own addresses, and a source that is the arrival
  interface's directed broadcast address (answering it would reflect to
  the whole subnet).

  An interface without an IPv4 address yet takes, besides broadcasts,
  only UDP to the DHCP client's port 68: a DHCP server may send its
  offer to the address it offers.

  Also: whether an address a DHCP server offers can be a host's.

  IPv4 addresses are LongWords in the machine's order (as
  Network.Addresses has them), IPv6 ones their 16 bytes. Pure and
  self-contained: the host test builds it, with crafted headers.
}
unit Network.InputFilter;

{$mode objfpc}

interface

const
  DhcpClientPort = 68;
  InputProtocolIgmp = 2;
  InputProtocolUdp = 17;

type
  { What the filter needs to know of the interface a datagram came in
    on. }
  TArrivalInterface = record
    IsLoopback: Boolean;
    HasAddress: Boolean;
    Address: LongWord;
    PrefixLength: LongWord;
  end;

function Ipv4SourceIsMartian(Source: LongWord; Protocol: Byte; constref Arrival: TArrivalInterface;
  SourceIsOwnAddress: Boolean): Boolean;
function Ipv4DestinationIsMartian(Destination: LongWord; constref Arrival: TArrivalInterface): Boolean;
{ An interface without an address takes a unicast datagram of Protocol
  to DestinationPort (UDP; 0 when unknown). }
function UnconfiguredInterfaceAccepts(Protocol: Byte; DestinationPort: Word): Boolean;
function Ipv6SourceIsMartian(constref Source: array of Byte; ArrivedOnLoopback: Boolean): Boolean;
function Ipv6DestinationIsMartian(constref Destination: array of Byte; ArrivedOnLoopback: Boolean): Boolean;
{ Address, offered with a mask of PrefixLength bits, can be a host's:
  not 0.0.0.0/8, loopback, multicast, 240.0.0.0/4 or the limited
  broadcast, nor its subnet's network or broadcast address. }
function DhcpOfferedAddressIsUsable(Address: LongWord; PrefixLength: LongWord): Boolean;

implementation

const
  LimitedBroadcast = LongWord($FFFFFFFF);

function PrefixMask(PrefixLength: LongWord): LongWord;
begin
  if PrefixLength = 0 then
    Exit(0);
  if PrefixLength >= 32 then
    Exit($FFFFFFFF);
  Result := LongWord($FFFFFFFF shl (32 - PrefixLength));
end;

function IsLoopbackAddress(Address: LongWord): Boolean;
begin
  Result := (Address shr 24) = 127;
end;

function IsMulticastAddress(Address: LongWord): Boolean;
begin
  Result := (Address shr 28) = $E;
end;

{ The first Count bytes are Value, the 16 bytes being there. }
function BytesAre(constref Address: array of Byte; First, Count: Integer; Value: Byte): Boolean;
var
  Index: Integer;
begin
  if Length(Address) <> 16 then
    Exit(False);
  for Index := First to First + Count - 1 do
    if Address[Index] <> Value then
      Exit(False);
  Result := True;
end;

function IsUnspecifiedIpv6(constref Address: array of Byte): Boolean;
begin
  Result := BytesAre(Address, 0, 16, 0);
end;

function IsLoopbackIpv6(constref Address: array of Byte): Boolean;
begin
  Result := BytesAre(Address, 0, 15, 0) and (Address[15] = 1);
end;

function IsMulticastIpv6(constref Address: array of Byte): Boolean;
begin
  Result := (Length(Address) = 16) and (Address[0] = $FF);
end;

function IsIpv4MappedIpv6(constref Address: array of Byte): Boolean;
begin
  Result := BytesAre(Address, 0, 10, 0) and BytesAre(Address, 10, 2, $FF);
end;

function IsDirectedBroadcastOf(Address: LongWord; constref Arrival: TArrivalInterface): Boolean;
begin
  Result := Arrival.HasAddress and (Arrival.PrefixLength < 31) and
    (Address = (Arrival.Address or not PrefixMask(Arrival.PrefixLength)));
end;

function Ipv4SourceIsMartian(Source: LongWord; Protocol: Byte; constref Arrival: TArrivalInterface;
  SourceIsOwnAddress: Boolean): Boolean;
begin
  if (Source = LimitedBroadcast) or IsMulticastAddress(Source) then
    Exit(True);
  if Source = 0 then
    Exit(not (Protocol in [InputProtocolUdp, InputProtocolIgmp]));
  if Arrival.IsLoopback then
    Exit(False);
  Result := IsLoopbackAddress(Source) or SourceIsOwnAddress or IsDirectedBroadcastOf(Source, Arrival);
end;

function Ipv4DestinationIsMartian(Destination: LongWord; constref Arrival: TArrivalInterface): Boolean;
begin
  if Destination = 0 then
    Exit(True);
  Result := not Arrival.IsLoopback and IsLoopbackAddress(Destination);
end;

function UnconfiguredInterfaceAccepts(Protocol: Byte; DestinationPort: Word): Boolean;
begin
  Result := (Protocol = InputProtocolUdp) and (DestinationPort = DhcpClientPort);
end;

function Ipv6SourceIsMartian(constref Source: array of Byte; ArrivedOnLoopback: Boolean): Boolean;
begin
  if IsMulticastIpv6(Source) or IsIpv4MappedIpv6(Source) then
    Exit(True);
  Result := not ArrivedOnLoopback and IsLoopbackIpv6(Source);
end;

function Ipv6DestinationIsMartian(constref Destination: array of Byte; ArrivedOnLoopback: Boolean): Boolean;
begin
  if IsUnspecifiedIpv6(Destination) or IsIpv4MappedIpv6(Destination) then
    Exit(True);
  Result := not ArrivedOnLoopback and IsLoopbackIpv6(Destination);
end;

function DhcpOfferedAddressIsUsable(Address: LongWord; PrefixLength: LongWord): Boolean;
var
  Mask: LongWord;
begin
  if ((Address shr 24) = 0) or IsLoopbackAddress(Address) or IsMulticastAddress(Address) or
     ((Address shr 28) = $F) then
    Exit(False);
  if (PrefixLength = 0) or (PrefixLength >= 31) then
    Exit(True);
  Mask := PrefixMask(PrefixLength);
  Result := ((Address and not Mask) <> 0) and ((Address and not Mask) <> not Mask);
end;

end.
