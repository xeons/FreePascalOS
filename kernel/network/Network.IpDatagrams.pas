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
  A received datagram as the protocols above IP see it, whichever IP
  version brought it: UDP, TCP and the ICMP sockets take a TIpDatagram
  from Network.Ipv4 and Network.Ipv6 alike and ask it for its endpoints
  and its pseudo-header sum.
}
unit Network.IpDatagrams;

{$mode objfpc}
{$pointermath on}

interface

uses
  Network.Addresses,
  Network.Ipv6Addresses,
  Network.Interfaces;

type
  TIpDatagram = record
    { AddressFamilyIPv4 or AddressFamilyIPv6. }
    Family: Word;
    { IPv4's addresses. }
    Source: TIpv4Address;
    Destination: TIpv4Address;
    { IPv6's addresses. }
    Source6: TIpv6Address;
    Destination6: TIpv6Address;
    { The upper-layer protocol (IPv6: after the extension headers). }
    Protocol: Byte;
    { The time to live, or the hop limit. }
    TimeToLive: Byte;
    { Sent to a broadcast address, or (IPv6) to a multicast group. }
    IsBroadcast: Boolean;
    ArrivalInterface: PNetworkInterface;
    { The whole datagram, header first (for ICMP errors about it), and
      where the upper-layer data begins. }
    Header: PByte;
    HeaderLength: LongWord;
    TotalLength: LongWord;
  end;

{ The datagram's source and destination with a port (a link-local IPv6
  address gets the arrival interface as its scope). }
function DatagramSource(constref Datagram: TIpDatagram; Port: Word): TNetworkEndpoint;
function DatagramDestination(constref Datagram: TIpDatagram; Port: Word): TNetworkEndpoint;
{ The pseudo-header sum UDP, TCP and ICMPv6 start their checksum with. }
function DatagramPseudoHeaderSum(constref Datagram: TIpDatagram; Protocol: Byte; Length: LongWord): LongWord;

implementation

uses
  Abi.SystemCalls,
  Network.Checksums;

function ArrivalIndex(constref Datagram: TIpDatagram): LongWord;
begin
  Result := 0;
  if Datagram.ArrivalInterface <> nil then
    Result := Datagram.ArrivalInterface^.Index;
end;

function DatagramSource(constref Datagram: TIpDatagram; Port: Word): TNetworkEndpoint;
begin
  if Datagram.Family = AddressFamilyIPv6 then
    Result := MakeIpv6Endpoint(Datagram.Source6, Port, ArrivalIndex(Datagram))
  else
    Result := MakeEndpoint(Datagram.Source, Port);
end;

function DatagramDestination(constref Datagram: TIpDatagram; Port: Word): TNetworkEndpoint;
begin
  if Datagram.Family = AddressFamilyIPv6 then
    Result := MakeIpv6Endpoint(Datagram.Destination6, Port, ArrivalIndex(Datagram))
  else
    Result := MakeEndpoint(Datagram.Destination, Port);
end;

function DatagramPseudoHeaderSum(constref Datagram: TIpDatagram; Protocol: Byte; Length: LongWord): LongWord;
begin
  if Datagram.Family = AddressFamilyIPv6 then
    Result := Ipv6PseudoHeaderSum(@Datagram.Source6[0], @Datagram.Destination6[0], Protocol, Length)
  else
    Result := PseudoHeaderSum(Datagram.Source, Datagram.Destination, Protocol, Length);
end;

end.
