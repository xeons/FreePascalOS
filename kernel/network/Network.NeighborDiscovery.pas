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
  Neighbour solicitations and advertisements that arrive (RFC 4861 7.2,
  RFC 4862 5.4).

  Both are believed only with hop limit 255 and well-formed options. A
  solicitation for one of our addresses is answered (to the asker, or
  to all nodes when the asker had no address yet) and teaches us the
  asker's Ethernet address; one for an address we are still testing,
  from ::, is another host testing the same address: ours is a
  duplicate. An advertisement for an address we are testing means the
  same; others go to the neighbour cache.
}
unit Network.NeighborDiscovery;

{$mode objfpc}
{$pointermath on}

interface

uses
  Network.IpDatagrams;

procedure HandleNeighborSolicitation(constref Datagram: TIpDatagram; Message: PByte; Length: LongWord);
procedure HandleNeighborAdvertisement(constref Datagram: TIpDatagram; Message: PByte; Length: LongWord);

implementation

uses
  Runtime.Memory,
  Network.Ipv6Addresses,
  Network.Ipv6Types,
  Network.Ipv6,
  Network.Ipv6AddressList,
  Network.Ipv6Interfaces,
  Network.Interfaces,
  Network.NeighborMessages,
  Network.NeighborCache;

{ The checks every Neighbor Discovery message must pass. }
function IsBelievable(constref Datagram: TIpDatagram; Message: PByte; Length: LongWord): Boolean;
begin
  Result := (Datagram.TimeToLive = NeighborDiscoveryHopLimit) and (Message[1] = 0) and
    (Length >= NeighborMessageBytes) and
    NeighborOptionsAreValid(Message + NeighborMessageBytes, Length - NeighborMessageBytes) and
    not Datagram.ArrivalInterface^.IsLoopback;
end;

procedure HandleNeighborSolicitation(constref Datagram: TIpDatagram; Message: PByte; Length: LongWord);
var
  NetworkInterface: PNetworkInterface;
  Target: TIpv6Address;
  Entry: PIpv6InterfaceAddress;
  SourceLinkAddress: PByte;
  FromUnspecified: Boolean;
begin
  if not IsBelievable(Datagram, Message, Length) then
    Exit;
  NetworkInterface := Datagram.ArrivalInterface;
  CopyMemory(@Target[0], Message + 8, Ipv6AddressLength);
  if IsMulticastIpv6Address(Target) then
    Exit;
  SourceLinkAddress := FindLinkAddressOption(Message + NeighborMessageBytes, Length - NeighborMessageBytes,
    NeighborOptionSourceLinkAddress);
  FromUnspecified := IsUnspecifiedIpv6Address(Datagram.Source6);
  { From ::, only to a solicited-node group, and without an address
    option. }
  if FromUnspecified and (not Datagram.IsBroadcast or (SourceLinkAddress <> nil)) then
    Exit;
  Entry := FindIpv6Address(NetworkInterface, Target);
  if Entry = nil then
    Exit;
  if Entry^.State = Ipv6AddressTentative then
  begin
    if FromUnspecified then
      Ipv6DuplicateAddress(NetworkInterface, Entry);
    Exit;
  end;
  if FromUnspecified then
  begin
    SendNeighborAdvertisement(NetworkInterface, Target, AllNodesIpv6Address, False);
    Exit;
  end;
  NeighborSeen(NetworkInterface, Datagram.Source6, SourceLinkAddress, False);
  SendNeighborAdvertisement(NetworkInterface, Target, Datagram.Source6, True);
end;

procedure HandleNeighborAdvertisement(constref Datagram: TIpDatagram; Message: PByte; Length: LongWord);
var
  NetworkInterface: PNetworkInterface;
  Target: TIpv6Address;
  Entry: PIpv6InterfaceAddress;
  Flags: Byte;
  TargetLinkAddress: PByte;
begin
  if not IsBelievable(Datagram, Message, Length) then
    Exit;
  NetworkInterface := Datagram.ArrivalInterface;
  CopyMemory(@Target[0], Message + 8, Ipv6AddressLength);
  Flags := Message[4];
  if IsMulticastIpv6Address(Target) or
     (Datagram.IsBroadcast and ((Flags and AdvertisementFlagSolicited) <> 0)) then
    Exit;
  Entry := FindIpv6Address(NetworkInterface, Target);
  if Entry <> nil then
  begin
    if Entry^.State = Ipv6AddressTentative then
      Ipv6DuplicateAddress(NetworkInterface, Entry);
    Exit;
  end;
  TargetLinkAddress := FindLinkAddressOption(Message + NeighborMessageBytes, Length - NeighborMessageBytes,
    NeighborOptionTargetLinkAddress);
  NeighborAdvertised(NetworkInterface, Target, TargetLinkAddress, (Flags and AdvertisementFlagSolicited) <> 0,
    (Flags and AdvertisementFlagOverride) <> 0, (Flags and AdvertisementFlagRouter) <> 0);
end;

end.
