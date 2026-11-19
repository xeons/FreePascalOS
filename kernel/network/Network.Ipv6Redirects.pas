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
  ICMPv6 redirects (RFC 4861 8): a router telling this host that a
  destination is better reached through another first hop on the same
  link (a router), or directly (the destination is on the link).

  A redirect is believed only as RFC 4861 8.1 says: from a link-local
  address, with hop limit 255 and code 0, at least 40 bytes, for a
  destination that is not multicast, from the router that is the first
  hop for that destination now, and with a target that is link-local or
  the destination itself; its options must all have lengths. It then
  goes to the destination cache (Network.Ipv6DestinationCache, for ten
  minutes), and the target's link-layer address, if the redirect gives
  it, to the neighbour cache. Under the network lock.
}
unit Network.Ipv6Redirects;

{$mode objfpc}
{$pointermath on}

interface

uses
  Network.IpDatagrams;

const
  Icmpv6TypeRedirect = 137;
  RedirectMessageBytes = 40;

procedure HandleRedirect(constref Datagram: TIpDatagram; Message: PByte; Length: LongWord);

implementation

uses
  Runtime.Memory,
  Network.Ipv6Addresses,
  Network.Interfaces,
  Network.Ipv6,
  Network.Ipv6Routing,
  Network.Ipv6DestinationCache,
  Network.NeighborMessages,
  Network.NeighborCache,
  Debug.Output;

{ The first hop datagrams to Destination take from NetworkInterface
  now; False if none (no route, or another interface). }
function CurrentFirstHop(NetworkInterface: PNetworkInterface; constref Destination: TIpv6Address;
  out FirstHop: TIpv6Address): Boolean;
var
  RouteInterface: PNetworkInterface;
begin
  FirstHop := Destination;
  if FindIpv6Redirect(NetworkInterface, Destination, FirstHop) then
    Exit(True);
  Result := LookupIpv6Route(Destination, NetworkInterface, RouteInterface, FirstHop) and
    (RouteInterface = NetworkInterface);
end;

procedure WriteRedirect(NetworkInterface: PNetworkInterface; constref Destination, Target: TIpv6Address);
var
  DestinationText: array[0..Ipv6AddressTextCapacity - 1] of Char;
  TargetText: array[0..Ipv6AddressTextCapacity - 1] of Char;
begin
  FormatIpv6Address(Destination, @DestinationText[0]);
  FormatIpv6Address(Target, @TargetText[0]);
  DebugBeginMessage;
  DebugWriteTag('network');
  DebugWrite(@NetworkInterface^.Name[0]);
  DebugWrite(': redirect: ');
  DebugWrite(@DestinationText[0]);
  DebugWrite(' through ');
  DebugWriteLine(@TargetText[0]);
  DebugEndMessage;
end;

procedure HandleRedirect(constref Datagram: TIpDatagram; Message: PByte; Length: LongWord);
var
  NetworkInterface: PNetworkInterface;
  Target: TIpv6Address;
  Destination: TIpv6Address;
  FirstHop: TIpv6Address;
  Options: PByte;
  OptionsLength: LongWord;
  Hardware: PByte;
  IsOnLink: Boolean;
begin
  NetworkInterface := Datagram.ArrivalInterface;
  if NetworkInterface^.IsLoopback or not NetworkInterface^.Ipv6.IsStarted or
     (Datagram.TimeToLive <> NeighborDiscoveryHopLimit) or (Length < RedirectMessageBytes) or (Message[1] <> 0) or
     not IsLinkLocalIpv6Address(Datagram.Source6) then
    Exit;
  CopyMemory(@Target[0], Message + 8, Ipv6AddressLength);
  CopyMemory(@Destination[0], Message + 24, Ipv6AddressLength);
  IsOnLink := Ipv6AddressesEqual(Target, Destination);
  if IsMulticastIpv6Address(Destination) or not (IsOnLink or IsLinkLocalIpv6Address(Target)) then
    Exit;
  Options := Message + RedirectMessageBytes;
  OptionsLength := Length - RedirectMessageBytes;
  if not NeighborOptionsAreValid(Options, OptionsLength) then
    Exit;
  if not CurrentFirstHop(NetworkInterface, Destination, FirstHop) or
     not Ipv6AddressesEqual(FirstHop, Datagram.Source6) then
    Exit;
  NoteIpv6Redirect(NetworkInterface, Destination, Target);
  Hardware := FindLinkAddressOption(Options, OptionsLength, NeighborOptionTargetLinkAddress);
  if Hardware <> nil then
    NeighborSeen(NetworkInterface, Target, Hardware, not IsOnLink);
  WriteRedirect(NetworkInterface, Destination, Target);
end;

end.
