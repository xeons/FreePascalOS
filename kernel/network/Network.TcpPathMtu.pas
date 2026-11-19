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
  TCP and path MTU discovery: the entry point the IP layers call when
  they learn that the path to a destination carries smaller datagrams
  (an ICMP "fragmentation needed" or ICMPv6 "packet too big", RFC 1191,
  RFC 8201).

  Every synchronized connection to that address whose MSS no longer
  fits lowers it to what the new MTU leaves (less the IP and TCP
  headers; never below 536 bytes for IPv4 or 1220 for IPv6) and sends
  what is in flight again in segments of the new size - a datagram too
  large was dropped, and that is not congestion, so the windows stay as
  they are. A larger MTU is left alone (the next connection uses it).
  Under the network lock.
}
unit Network.TcpPathMtu;

{$mode objfpc}

interface

uses
  Network.Addresses;

{ The path to Destination's address now carries datagrams of at most
  PathMtu bytes (IP header included). }
procedure TcpPathMtuChanged(constref Destination: TNetworkEndpoint; PathMtu: LongWord);

implementation

uses
  Abi.SystemCalls,
  Network.TcpTypes,
  Network.TcpConnections,
  Network.TcpOutput;

const
  Ipv4HeaderBytes = 20;
  Ipv6HeaderBytes = 40;
  { What the smallest MTUs leave: 576 for IPv4, 1280 for IPv6. }
  MinimumIpv4Segment = 536;
  MinimumIpv6Segment = 1220;

function SegmentSizeFor(Family: Word; PathMtu: LongWord): LongWord;
var
  Headers: LongWord;
  Minimum: LongWord;
begin
  if Family = AddressFamilyIPv6 then
  begin
    Headers := Ipv6HeaderBytes + TcpHeaderBytes;
    Minimum := MinimumIpv6Segment;
  end
  else
  begin
    Headers := Ipv4HeaderBytes + TcpHeaderBytes;
    Minimum := MinimumIpv4Segment;
  end;
  if PathMtu <= Headers + Minimum then
    Result := Minimum
  else
    Result := PathMtu - Headers;
end;

procedure TcpPathMtuChanged(constref Destination: TNetworkEndpoint; PathMtu: LongWord);
var
  Connection: PTcpConnection;
  Size: LongWord;
begin
  Size := SegmentSizeFor(Destination.Family, PathMtu);
  Connection := FirstTcpConnection;
  while Connection <> nil do
  begin
    if not (Connection^.State in [TcpClosed, TcpListen, TcpTimeWait]) and
       EndpointAddressesEqual(Connection^.Remote, Destination) and (Connection^.MaximumSegment > Size) then
    begin
      Connection^.MaximumSegment := Size;
      ResendAfterSegmentSizeChange(Connection);
    end;
    Connection := NextTcpConnection(Connection);
  end;
end;

end.
