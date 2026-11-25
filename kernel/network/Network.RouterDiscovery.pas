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
  Finding routers and what they offer (RFC 4861 6.3, RFC 4862 5.5,
  RFC 8106), on interfaces in Ipv6ModeAutomatic.

  Once the link-local address is ready, a router solicitation goes to
  all routers, again after 4 s, three in all, until an advertisement
  comes. An advertisement (from a link-local address, hop limit 255) is
  taken whenever it comes:
    - its router lifetime makes or renews the default route through the
      router (0 removes it), its hop limit, reachable time and
      retransmission timer replace ours when they are not 0;
    - its source link-layer address goes to the neighbour cache;
    - an MTU option between 1280 and the interface's MTU becomes the
      link's MTU for IPv6;
    - a prefix with the on-link flag makes or renews the route to the
      prefix for its valid lifetime; one with the autonomous flag and 64
      bits gets an address (the prefix and our interface identifier:
      stable-privacy or EUI-64, Network.Ipv6Identifiers) with its
      lifetimes, and a temporary one beside it
      (Network.TemporaryAddresses), an address already made keeping at least two
      hours of the valid one unless the new one is longer (5.5.3 e);
    - DNS servers (RDNSS) are kept for their lifetime (0 forgets one);
    - its M (managed) and O (other configuration) flags are kept for the
      network service, which asks DHCPv6 as they say.
  The route metric of an interface's routers is its index, so the first
  interface's router is the default among equals.
}
unit Network.RouterDiscovery;

{$mode objfpc}
{$pointermath on}

interface

uses
  Network.IpDatagrams,
  Network.Interfaces;

const
  RouterSolicitations = 3;
  RouterSolicitationIntervalSeconds = 4;

procedure HandleRouterAdvertisement(constref Datagram: TIpDatagram; Message: PByte; Length: LongWord);
{ Starts soliciting routers on the interface. }
procedure StartRouterSolicitation(NetworkInterface: PNetworkInterface);
procedure StopRouterSolicitation(NetworkInterface: PNetworkInterface);
{ On the network thread: sends what is due. }
procedure RunRouterSolicitationTimer(NetworkInterface: PNetworkInterface; Now: QWord);
{ Forgets the DNS servers routers gave the interface. }
procedure ForgetRouterDnsServers(NetworkInterface: PNetworkInterface);
{ On the network thread: drops DNS servers whose lifetime ended. True if
  any went. }
function ExpireRouterDnsServers(NetworkInterface: PNetworkInterface; Now: QWord): Boolean;

implementation

uses
  Abi.SystemCalls,
  Runtime.Memory,
  Network.ByteOrder,
  Network.Core,
  Network.Ipv6Addresses,
  Network.Ipv6Types,
  Network.Ipv6,
  Network.Ipv6AddressList,
  Network.Ipv6Identifiers,
  Network.TemporaryAddresses,
  Network.Ipv6Routing,
  Network.NeighborMessages,
  Network.NeighborCache,
  Network.ChangeWatchers;

const
  RouterAdvertisementBytes = 16;
  PrefixOptionBytes = 32;
  PrefixFlagOnLink = $80;
  PrefixFlagAutonomous = $40;
  AdvertisementFlagManaged = $80;
  AdvertisementFlagOtherConfiguration = $40;
  InfiniteLifetime = $FFFFFFFF;
  TwoHoursSeconds = 2 * 60 * 60;
  NanosecondsPerSecond = QWord(1000) * 1000 * 1000;

{ The NetworkNow time a lifetime in seconds ends at. }
function LifetimeEnd(Now: QWord; Seconds: LongWord): QWord;
begin
  if Seconds = InfiniteLifetime then
    Result := Ipv6Forever
  else
    Result := Now + QWord(Seconds) * NanosecondsPerSecond;
end;

procedure StartRouterSolicitation(NetworkInterface: PNetworkInterface);
begin
  NetworkInterface^.Ipv6.SolicitationsSent := 0;
  NetworkInterface^.Ipv6.NextSolicitation := NetworkNow;
  RequestNetworkWakeAt(NetworkInterface^.Ipv6.NextSolicitation);
end;

procedure StopRouterSolicitation(NetworkInterface: PNetworkInterface);
begin
  NetworkInterface^.Ipv6.NextSolicitation := 0;
end;

procedure RunRouterSolicitationTimer(NetworkInterface: PNetworkInterface; Now: QWord);
var
  State: ^TIpv6InterfaceState;
begin
  State := @NetworkInterface^.Ipv6;
  if State^.NextSolicitation = 0 then
    Exit;
  if State^.NextSolicitation > Now then
  begin
    RequestNetworkWakeAt(State^.NextSolicitation);
    Exit;
  end;
  if State^.SolicitationsSent >= RouterSolicitations then
  begin
    State^.NextSolicitation := 0;
    Exit;
  end;
  SendRouterSolicitation(NetworkInterface);
  Inc(State^.SolicitationsSent);
  State^.NextSolicitation := Now + RouterSolicitationIntervalSeconds * NanosecondsPerSecond;
  RequestNetworkWakeAt(State^.NextSolicitation);
end;

procedure ForgetRouterDnsServers(NetworkInterface: PNetworkInterface);
var
  Index: Integer;
begin
  for Index := 0 to MaximumDnsServers - 1 do
    NetworkInterface^.Ipv6.DnsServers[Index].InUse := False;
end;

function ExpireRouterDnsServers(NetworkInterface: PNetworkInterface; Now: QWord): Boolean;
var
  Index: Integer;
  Server: ^TIpv6DnsServer;
begin
  Result := False;
  for Index := 0 to MaximumDnsServers - 1 do
  begin
    Server := @NetworkInterface^.Ipv6.DnsServers[Index];
    if not Server^.InUse or (Server^.ValidUntil = Ipv6Forever) then
      Continue;
    if Server^.ValidUntil <= Now then
    begin
      Server^.InUse := False;
      Result := True;
    end
    else
      RequestNetworkWakeAt(Server^.ValidUntil);
  end;
end;

{ Keeps (or forgets, Lifetime 0) one DNS server; True if the list
  changed. }
function TakeDnsServer(NetworkInterface: PNetworkInterface; constref Address: TIpv6Address; Lifetime: LongWord;
  Now: QWord): Boolean;
var
  Index: Integer;
  Free: Integer;
  Server: ^TIpv6DnsServer;
begin
  Free := -1;
  for Index := 0 to MaximumDnsServers - 1 do
  begin
    Server := @NetworkInterface^.Ipv6.DnsServers[Index];
    if not Server^.InUse then
    begin
      if Free < 0 then
        Free := Index;
      Continue;
    end;
    if not Ipv6AddressesEqual(Server^.Address, Address) then
      Continue;
    if Lifetime = 0 then
    begin
      Server^.InUse := False;
      Exit(True);
    end;
    Server^.ValidUntil := LifetimeEnd(Now, Lifetime);
    Exit(False);
  end;
  if (Lifetime = 0) or (Free < 0) then
    Exit(False);
  Server := @NetworkInterface^.Ipv6.DnsServers[Free];
  Server^.InUse := True;
  Server^.Address := Address;
  Server^.ValidUntil := LifetimeEnd(Now, Lifetime);
  if Server^.ValidUntil <> Ipv6Forever then
    RequestNetworkWakeAt(Server^.ValidUntil);
  Result := True;
end;

function HandleDnsOption(NetworkInterface: PNetworkInterface; Option: PByte; OptionLength: LongWord;
  Now: QWord): Boolean;
var
  Lifetime: LongWord;
  Position: LongWord;
  Address: TIpv6Address;
begin
  Result := False;
  if OptionLength < 24 then
    Exit;
  Lifetime := ReadBigEndian32(Option + 4);
  Position := 8;
  while Position + Ipv6AddressLength <= OptionLength do
  begin
    CopyMemory(@Address[0], Option + Position, Ipv6AddressLength);
    if TakeDnsServer(NetworkInterface, Address, Lifetime, Now) then
      Result := True;
    Position := Position + Ipv6AddressLength;
  end;
end;

{ The valid lifetime an address already made keeps (RFC 4862 5.5.3 e). }
function RenewedValidEnd(Entry: PIpv6InterfaceAddress; ValidLifetime: LongWord; Now: QWord): QWord;
var
  Offered: QWord;
  RemainingSeconds: QWord;
begin
  Offered := LifetimeEnd(Now, ValidLifetime);
  if (ValidLifetime > TwoHoursSeconds) or (Offered > Entry^.ValidUntil) then
    Exit(Offered);
  if Entry^.ValidUntil = Ipv6Forever then
    RemainingSeconds := High(QWord)
  else if Entry^.ValidUntil > Now then
    RemainingSeconds := (Entry^.ValidUntil - Now) div NanosecondsPerSecond
  else
    RemainingSeconds := 0;
  if RemainingSeconds <= TwoHoursSeconds then
    Exit(Entry^.ValidUntil);
  Result := Now + QWord(TwoHoursSeconds) * NanosecondsPerSecond;
end;

{ An address for the prefix (SLAAC); True if one was made. }
function ConfigureFromPrefix(NetworkInterface: PNetworkInterface; constref Prefix: TIpv6Address;
  ValidLifetime, PreferredLifetime: LongWord; Now: QWord): Boolean;
var
  Address: TIpv6Address;
  Entry: PIpv6InterfaceAddress;
  ValidEnd: QWord;
  PreferredEnd: QWord;
begin
  Result := False;
  Address := SlaacAddressOf(NetworkInterface, Prefix);
  PreferredEnd := LifetimeEnd(Now, PreferredLifetime);
  Entry := FindIpv6Address(NetworkInterface, Address);
  if Entry <> nil then
  begin
    if Entry^.Origin <> Ipv6OriginAutomatic then
      Exit;
    ValidEnd := RenewedValidEnd(Entry, ValidLifetime, Now);
    AddIpv6Address(NetworkInterface, Address, 64, Ipv6OriginAutomatic, ValidEnd, PreferredEnd);
    UpdateTemporaryAddresses(NetworkInterface, Prefix, ValidEnd, PreferredEnd, Now);
    Exit;
  end;
  if ValidLifetime = 0 then
    Exit;
  ValidEnd := LifetimeEnd(Now, ValidLifetime);
  Result := AddIpv6Address(NetworkInterface, Address, 64, Ipv6OriginAutomatic, ValidEnd, PreferredEnd) = ErrorNone;
  if Result then
    UpdateTemporaryAddresses(NetworkInterface, Prefix, ValidEnd, PreferredEnd, Now);
end;

function HandlePrefixOption(NetworkInterface: PNetworkInterface; Option: PByte; OptionLength: LongWord;
  Now: QWord): Boolean;
var
  PrefixLength: LongWord;
  Flags: Byte;
  ValidLifetime: LongWord;
  PreferredLifetime: LongWord;
  Prefix: TIpv6Address;
begin
  Result := False;
  if OptionLength < PrefixOptionBytes then
    Exit;
  PrefixLength := Option[2];
  Flags := Option[3];
  ValidLifetime := ReadBigEndian32(Option + 4);
  PreferredLifetime := ReadBigEndian32(Option + 8);
  CopyMemory(@Prefix[0], Option + 16, Ipv6AddressLength);
  if (PrefixLength > 128) or IsLinkLocalIpv6Address(Prefix) or IsMulticastIpv6Address(Prefix) or
     (PreferredLifetime > ValidLifetime) then
    Exit;
  if (Flags and PrefixFlagOnLink) <> 0 then
  begin
    if ValidLifetime = 0 then
      Result := RemoveAutomaticIpv6Route(Prefix, PrefixLength, UnspecifiedIpv6Address, NetworkInterface) = ErrorNone
    else
    begin
      Result := not Ipv6RouteExists(Prefix, PrefixLength, UnspecifiedIpv6Address, NetworkInterface);
      AddIpv6Route(Prefix, PrefixLength, UnspecifiedIpv6Address, NetworkInterface, RouteFlagAutomatic,
        NetworkInterface^.Index, LifetimeEnd(Now, ValidLifetime));
    end;
  end;
  if ((Flags and PrefixFlagAutonomous) <> 0) and (PrefixLength = 64) then
    if ConfigureFromPrefix(NetworkInterface, Prefix, ValidLifetime, PreferredLifetime, Now) then
      Result := True;
end;

procedure HandleMtuOption(NetworkInterface: PNetworkInterface; Option: PByte; OptionLength: LongWord);
var
  Mtu: LongWord;
begin
  if OptionLength < 8 then
    Exit;
  Mtu := ReadBigEndian32(Option + 4);
  if (Mtu >= MinimumIpv6Mtu) and (Mtu <= NetworkInterface^.Mtu) then
    NetworkInterface^.Ipv6.Mtu := Mtu;
end;

{ Goes through the options; True if what the interface has changed. }
function HandleOptions(NetworkInterface: PNetworkInterface; Options: PByte; Length: LongWord; Now: QWord): Boolean;
var
  Position: LongWord;
  OptionLength: LongWord;
begin
  Result := False;
  Position := 0;
  while Position + 2 <= Length do
  begin
    OptionLength := LongWord(Options[Position + 1]) * 8;
    if (OptionLength = 0) or (Position + OptionLength > Length) then
      Exit;
    case Options[Position] of
      NeighborOptionPrefixInformation:
        if HandlePrefixOption(NetworkInterface, Options + Position, OptionLength, Now) then
          Result := True;
      NeighborOptionMtu:
        HandleMtuOption(NetworkInterface, Options + Position, OptionLength);
      NeighborOptionRecursiveDnsServer:
        if HandleDnsOption(NetworkInterface, Options + Position, OptionLength, Now) then
          Result := True;
    end;
    Position := Position + OptionLength;
  end;
end;

{ The default route through the router, as its lifetime says; True if
  one appeared or went. }
function HandleRouterLifetime(NetworkInterface: PNetworkInterface; constref Router: TIpv6Address;
  LifetimeSeconds: LongWord; Now: QWord): Boolean;
var
  WasDefault: Boolean;
begin
  WasDefault := Ipv6RouteExists(UnspecifiedIpv6Address, 0, Router, NetworkInterface);
  if LifetimeSeconds = 0 then
    { Only a route the router made goes with it. }
    Exit(RemoveAutomaticIpv6Route(UnspecifiedIpv6Address, 0, Router, NetworkInterface) = ErrorNone);
  AddIpv6Route(UnspecifiedIpv6Address, 0, Router, NetworkInterface, RouteFlagAutomatic, NetworkInterface^.Index,
    Now + QWord(LifetimeSeconds) * NanosecondsPerSecond);
  Result := not WasDefault;
end;

procedure HandleRouterAdvertisement(constref Datagram: TIpDatagram; Message: PByte; Length: LongWord);
var
  NetworkInterface: PNetworkInterface;
  Options: PByte;
  OptionsLength: LongWord;
  Now: QWord;
  Changed: Boolean;
  Value: LongWord;
  RouterFlags: LongWord;
begin
  NetworkInterface := Datagram.ArrivalInterface;
  if (NetworkInterface^.Ipv6.Mode <> Ipv6ModeAutomatic) or not NetworkInterface^.Ipv6.IsStarted or
     (Datagram.TimeToLive <> NeighborDiscoveryHopLimit) or (Message[1] <> 0) or
     (Length < RouterAdvertisementBytes) or not IsLinkLocalIpv6Address(Datagram.Source6) then
    Exit;
  Options := Message + RouterAdvertisementBytes;
  OptionsLength := Length - RouterAdvertisementBytes;
  if not NeighborOptionsAreValid(Options, OptionsLength) then
    Exit;
  Now := NetworkNow;
  StopRouterSolicitation(NetworkInterface);
  if Message[4] <> 0 then
    NetworkInterface^.Ipv6.HopLimit := Message[4];
  Value := ReadBigEndian32(Message + 8);
  if Value <> 0 then
    NetworkInterface^.Ipv6.ReachableMilliseconds := Value;
  Value := ReadBigEndian32(Message + 12);
  if Value <> 0 then
    NetworkInterface^.Ipv6.RetransmitMilliseconds := Value;
  NeighborSeen(NetworkInterface, Datagram.Source6,
    FindLinkAddressOption(Options, OptionsLength, NeighborOptionSourceLinkAddress), True);
  Changed := HandleRouterLifetime(NetworkInterface, Datagram.Source6, ReadBigEndian16(Message + 6), Now);
  RouterFlags := 0;
  if (Message[5] and AdvertisementFlagManaged) <> 0 then
    RouterFlags := RouterFlags or Ipv6RouterFlagManaged;
  if (Message[5] and AdvertisementFlagOtherConfiguration) <> 0 then
    RouterFlags := RouterFlags or Ipv6RouterFlagOtherConfiguration;
  if RouterFlags <> NetworkInterface^.Ipv6.RouterFlags then
  begin
    NetworkInterface^.Ipv6.RouterFlags := RouterFlags;
    Changed := True;
  end;
  if HandleOptions(NetworkInterface, Options, OptionsLength, Now) then
    Changed := True;
  if Changed then
    NoteNetworkChange;
end;

end.
