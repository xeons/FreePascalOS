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
  Neighbor Discovery's messages (RFC 4861 4): building and sending
  neighbour solicitations and advertisements and router solicitations,
  and finding the options of a received message.

  Every message goes with hop limit 255 and carries our Ethernet address
  in a link-layer address option, except a solicitation for duplicate
  address detection, which is sent from :: without one. A solicitation's
  source is the interface's link-local address (another of its
  addresses before that one is ready).
}
unit Network.NeighborMessages;

{$mode objfpc}
{$pointermath on}

interface

uses
  Network.Ipv6Addresses,
  Network.Interfaces;

const
  NeighborOptionSourceLinkAddress = 1;
  NeighborOptionTargetLinkAddress = 2;
  NeighborOptionPrefixInformation = 3;
  NeighborOptionMtu = 5;
  NeighborOptionRecursiveDnsServer = 25;

  { Neighbor advertisement flags (the first byte after the checksum). }
  AdvertisementFlagRouter = $80;
  AdvertisementFlagSolicited = $40;
  AdvertisementFlagOverride = $20;

  { Solicitation and advertisement: header, reserved, target. }
  NeighborMessageBytes = 24;
  RouterSolicitationBytes = 8;

{ A solicitation for Target sent to Destination (its solicited-node
  group, or Target itself to check on it). ForDuplicateDetection: from
  ::, without our link-layer address. }
procedure SendNeighborSolicitation(NetworkInterface: PNetworkInterface; constref Target, Destination: TIpv6Address;
  ForDuplicateDetection: Boolean);
{ An advertisement of our Target to Destination. }
procedure SendNeighborAdvertisement(NetworkInterface: PNetworkInterface; constref Target, Destination: TIpv6Address;
  Solicited: Boolean);
{ A router solicitation to all routers. }
procedure SendRouterSolicitation(NetworkInterface: PNetworkInterface);
{ True if every option in Options (Length bytes) has a length. }
function NeighborOptionsAreValid(Options: PByte; Length: LongWord): Boolean;
{ The Ethernet address in the first link-layer address option of
  OptionType; nil if there is none. }
function FindLinkAddressOption(Options: PByte; Length: LongWord; OptionType: Byte): PByte;

implementation

uses
  Runtime.Memory,
  Io.NetworkAdapters,
  Network.Packets,
  Network.Ipv6,
  Network.Ipv6AddressList,
  Network.Icmpv6;

const
  LinkAddressOptionBytes = 8;

{ The address a solicitation goes from: the link-local one, or failing
  that another that is ready; :: if there is none. }
function SolicitationSource(NetworkInterface: PNetworkInterface; constref Target: TIpv6Address): TIpv6Address;
begin
  if FindLinkLocalAddress(NetworkInterface, Result) then
    Exit;
  if not SelectIpv6Source(NetworkInterface, Target, Result) then
    Result := UnspecifiedIpv6Address;
end;

procedure AppendLinkAddressOption(Packet: PPacket; NetworkInterface: PNetworkInterface; OptionType: Byte);
var
  Option: PByte;
begin
  Option := AppendToPacket(Packet, LinkAddressOptionBytes);
  if Option = nil then
    Exit;
  Option[0] := OptionType;
  Option[1] := 1;
  CopyMemory(Option + 2, @NetworkInterface^.HardwareAddress[0], EthernetAddressLength);
end;

{ A packet with an ICMPv6 message of MessageType and Length bytes,
  zeroed but for the type; nil if memory is short. }
function NewMessage(MessageType: Byte; Length: LongWord; out Message: PByte): PPacket;
begin
  Result := AllocatePacket(PacketHeadroom);
  Message := nil;
  if Result = nil then
    Exit;
  Message := AppendToPacket(Result, Length);
  FillMemory(Message, Length, 0);
  Message[0] := MessageType;
end;

procedure SendNeighborSolicitation(NetworkInterface: PNetworkInterface; constref Target, Destination: TIpv6Address;
  ForDuplicateDetection: Boolean);
var
  Packet: PPacket;
  Message: PByte;
  Source: TIpv6Address;
begin
  if NetworkInterface^.IsLoopback then
    Exit;
  Packet := NewMessage(Icmpv6TypeNeighborSolicitation, NeighborMessageBytes, Message);
  if Packet = nil then
    Exit;
  CopyMemory(Message + 8, @Target[0], Ipv6AddressLength);
  Source := UnspecifiedIpv6Address;
  if not ForDuplicateDetection then
    Source := SolicitationSource(NetworkInterface, Target);
  if not IsUnspecifiedIpv6Address(Source) then
    AppendLinkAddressOption(Packet, NetworkInterface, NeighborOptionSourceLinkAddress);
  TransmitIcmpv6(Packet, Source, Destination, NeighborDiscoveryHopLimit, NetworkInterface);
end;

procedure SendNeighborAdvertisement(NetworkInterface: PNetworkInterface; constref Target, Destination: TIpv6Address;
  Solicited: Boolean);
var
  Packet: PPacket;
  Message: PByte;
begin
  if NetworkInterface^.IsLoopback then
    Exit;
  Packet := NewMessage(Icmpv6TypeNeighborAdvertisement, NeighborMessageBytes, Message);
  if Packet = nil then
    Exit;
  Message[4] := AdvertisementFlagOverride;
  if Solicited then
    Message[4] := Message[4] or AdvertisementFlagSolicited;
  CopyMemory(Message + 8, @Target[0], Ipv6AddressLength);
  AppendLinkAddressOption(Packet, NetworkInterface, NeighborOptionTargetLinkAddress);
  TransmitIcmpv6(Packet, Target, Destination, NeighborDiscoveryHopLimit, NetworkInterface);
end;

procedure SendRouterSolicitation(NetworkInterface: PNetworkInterface);
var
  Packet: PPacket;
  Message: PByte;
  Source: TIpv6Address;
begin
  Packet := NewMessage(Icmpv6TypeRouterSolicitation, RouterSolicitationBytes, Message);
  if Packet = nil then
    Exit;
  if not FindLinkLocalAddress(NetworkInterface, Source) then
    Source := UnspecifiedIpv6Address;
  if not IsUnspecifiedIpv6Address(Source) then
    AppendLinkAddressOption(Packet, NetworkInterface, NeighborOptionSourceLinkAddress);
  TransmitIcmpv6(Packet, Source, AllRoutersIpv6Address, NeighborDiscoveryHopLimit, NetworkInterface);
end;

function NeighborOptionsAreValid(Options: PByte; Length: LongWord): Boolean;
var
  Position: LongWord;
  OptionLength: LongWord;
begin
  Position := 0;
  while Position < Length do
  begin
    if Position + 2 > Length then
      Exit(False);
    OptionLength := LongWord(Options[Position + 1]) * 8;
    if (OptionLength = 0) or (Position + OptionLength > Length) then
      Exit(False);
    Position := Position + OptionLength;
  end;
  Result := True;
end;

function FindLinkAddressOption(Options: PByte; Length: LongWord; OptionType: Byte): PByte;
var
  Position: LongWord;
  OptionLength: LongWord;
begin
  Position := 0;
  while Position + 2 <= Length do
  begin
    OptionLength := LongWord(Options[Position + 1]) * 8;
    if (OptionLength = 0) or (Position + OptionLength > Length) then
      Exit(nil);
    if (Options[Position] = OptionType) and (OptionLength >= LinkAddressOptionBytes) then
      Exit(Options + Position + 2);
    Position := Position + OptionLength;
  end;
  Result := nil;
end;

end.
