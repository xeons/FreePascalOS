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
  IPv6's routing table, beside IPv4's (Network.Routing): which interface
  a datagram leaves by and its next hop there.

  Interface routes come with the addresses (fe80::/64 with the
  link-local address, a manual address's prefix) and go with them;
  routers' advertisements add on-link prefixes and default routes that
  expire with their lifetimes (RouteFlagAutomatic); others are added by
  hand. Advertisements only ever renew or remove routes they made: a
  route added by hand or with an address keeps its lifetime (forever)
  whatever a router says, and one made by hand over an automatic route
  takes it over. A gateway is usually a router's link-local address, so a route
  always names its interface. A lookup takes the longest prefix on an
  interface that is up, the lowest metric among equals. Link-local and
  multicast destinations are not looked up here: they leave by the
  interface their scope names. Under the network lock.
}
unit Network.Ipv6Routing;

{$mode objfpc}

interface

uses
  Abi.SystemCalls,
  Network.Ipv6Addresses,
  Network.Interfaces;

const
  MaximumIpv6Routes = 64;

{ Adds a route, or renews one that is there (same destination, prefix,
  gateway and interface: its lifetime and metric are taken). ExpiresAt
  is a NetworkNow time, or Ipv6Forever. NetworkInterface nil: the one
  whose prefix has the gateway (ErrorNetworkUnreachable if none has;
  a link-local gateway needs its interface). }
function AddIpv6Route(constref Destination: TIpv6Address; PrefixLength: LongWord; constref Gateway: TIpv6Address;
  NetworkInterface: PNetworkInterface; Flags, Metric: LongWord; ExpiresAt: QWord): LongInt;
{ Removes the route with this destination and prefix and gateway (any
  gateway if Gateway is ::) and, if NetworkInterface is not nil, on that
  interface; ErrorNotFound if there is none. }
function RemoveIpv6Route(constref Destination: TIpv6Address; PrefixLength: LongWord;
  constref Gateway: TIpv6Address; NetworkInterface: PNetworkInterface): LongInt;
{ The same for a route that came from router advertisements only
  (RouteFlagAutomatic): ErrorNotFound for any other. }
function RemoveAutomaticIpv6Route(constref Destination: TIpv6Address; PrefixLength: LongWord;
  constref Gateway: TIpv6Address; NetworkInterface: PNetworkInterface): LongInt;
{ The flags of that route (RouteFlag*); False if there is none. }
function FindIpv6RouteFlags(constref Destination: TIpv6Address; PrefixLength: LongWord;
  constref Gateway: TIpv6Address; NetworkInterface: PNetworkInterface; out Flags: LongWord;
  out ExpiresAt: QWord): Boolean;
{ Removes the routes of NetworkInterface: all of them, or only those
  that came from router advertisements. }
procedure RemoveIpv6InterfaceRoutes(NetworkInterface: PNetworkInterface; OnlyAutomatic: Boolean);
{ The interface and next hop for Destination (a global address);
  BoundInterface, if not nil, is the only one considered. False if no
  route covers it. }
function LookupIpv6Route(constref Destination: TIpv6Address; BoundInterface: PNetworkInterface;
  out NetworkInterface: PNetworkInterface; out NextHop: TIpv6Address): Boolean;
{ True if the table has the route with this destination, prefix and
  gateway on NetworkInterface. }
function Ipv6RouteExists(constref Destination: TIpv6Address; PrefixLength: LongWord; constref Gateway: TIpv6Address;
  NetworkInterface: PNetworkInterface): Boolean;
{ On the network thread: drops the routes whose lifetime ended. True if
  any went. }
function RunIpv6RouteTimers(Now: QWord): Boolean;
function Ipv6RouteCount: Integer;
{ The route at Position (from 0) as the system call shows it. }
function DescribeIpv6Route(Position: Integer; out Description: TAbiRoute): Boolean;

implementation

uses
  Runtime.Memory,
  Runtime.Text,
  Network.Core,
  Network.Ipv6Types;

type
  PIpv6Route = ^TIpv6Route;
  TIpv6Route = record
    InUse: Boolean;
    Destination: TIpv6Address;
    PrefixLength: LongWord;
    { ::: on the link. }
    Gateway: TIpv6Address;
    NetworkInterface: PNetworkInterface;
    Flags: LongWord;
    Metric: LongWord;
    ExpiresAt: QWord;
  end;

var
  Routes: array[0..MaximumIpv6Routes - 1] of TIpv6Route;

{ The interface of the on-link route (one without a gateway) whose
  prefix has Address. }
function InterfaceReaching(constref Address: TIpv6Address): PNetworkInterface;
var
  Index: Integer;
begin
  for Index := 0 to MaximumIpv6Routes - 1 do
    if Routes[Index].InUse and IsUnspecifiedIpv6Address(Routes[Index].Gateway) and
       SameIpv6Prefix(Address, Routes[Index].Destination, Routes[Index].PrefixLength) then
      Exit(Routes[Index].NetworkInterface);
  Result := nil;
end;

function FindRoute(constref Destination: TIpv6Address; PrefixLength: LongWord; constref Gateway: TIpv6Address;
  AnyGateway: Boolean; NetworkInterface: PNetworkInterface): PIpv6Route;
var
  Index: Integer;
begin
  for Index := 0 to MaximumIpv6Routes - 1 do
  begin
    Result := @Routes[Index];
    if Result^.InUse and (Result^.PrefixLength = PrefixLength) and
       Ipv6AddressesEqual(Result^.Destination, Destination) and
       (AnyGateway or Ipv6AddressesEqual(Result^.Gateway, Gateway)) and
       ((NetworkInterface = nil) or (Result^.NetworkInterface = NetworkInterface)) then
      Exit;
  end;
  Result := nil;
end;

function AddIpv6Route(constref Destination: TIpv6Address; PrefixLength: LongWord; constref Gateway: TIpv6Address;
  NetworkInterface: PNetworkInterface; Flags, Metric: LongWord; ExpiresAt: QWord): LongInt;
var
  Prefix: TIpv6Address;
  Route: PIpv6Route;
  Index: Integer;
begin
  if PrefixLength > 128 then
    Exit(ErrorInvalidArgument);
  Prefix := Ipv6PrefixOf(Destination, PrefixLength);
  if NetworkInterface = nil then
  begin
    if IsUnspecifiedIpv6Address(Gateway) or IsLinkLocalIpv6Address(Gateway) then
      Exit(ErrorInvalidArgument);
    NetworkInterface := InterfaceReaching(Gateway);
    if NetworkInterface = nil then
      Exit(ErrorNetworkUnreachable);
  end;
  Route := FindRoute(Prefix, PrefixLength, Gateway, False, NetworkInterface);
  if Route <> nil then
  begin
    if (Flags and RouteFlagAutomatic) <> 0 then
    begin
      { A router renews only what routers made. }
      if (Route^.Flags and RouteFlagAutomatic) = 0 then
        Exit(ErrorExists);
      Route^.ExpiresAt := ExpiresAt;
      Route^.Metric := Metric;
      Exit(ErrorNone);
    end;
    if (Route^.Flags and RouteFlagAutomatic) = 0 then
      Exit(ErrorExists);
    { Made by hand (or with an address) over a router's: it is ours now,
      for as long as it is wanted. }
    Route^.Flags := (Flags and (RouteFlagGateway or RouteFlagInterface)) or (Route^.Flags and RouteFlagGateway);
    Route^.Metric := Metric;
    Route^.ExpiresAt := ExpiresAt;
    Exit(ErrorNone);
  end;
  for Index := 0 to MaximumIpv6Routes - 1 do
  begin
    Route := @Routes[Index];
    if Route^.InUse then
      Continue;
    Route^.InUse := True;
    Route^.Destination := Prefix;
    Route^.PrefixLength := PrefixLength;
    Route^.Gateway := Gateway;
    Route^.NetworkInterface := NetworkInterface;
    Route^.Flags := Flags and (RouteFlagGateway or RouteFlagInterface or RouteFlagAutomatic);
    if not IsUnspecifiedIpv6Address(Gateway) then
      Route^.Flags := Route^.Flags or RouteFlagGateway;
    Route^.Metric := Metric;
    Route^.ExpiresAt := ExpiresAt;
    if ExpiresAt <> Ipv6Forever then
      RequestNetworkWakeAt(ExpiresAt);
    Exit(ErrorNone);
  end;
  Result := ErrorNoSpace;
end;

function RemoveIpv6Route(constref Destination: TIpv6Address; PrefixLength: LongWord;
  constref Gateway: TIpv6Address; NetworkInterface: PNetworkInterface): LongInt;
var
  Route: PIpv6Route;
begin
  if PrefixLength > 128 then
    Exit(ErrorInvalidArgument);
  Route := FindRoute(Ipv6PrefixOf(Destination, PrefixLength), PrefixLength, Gateway,
    IsUnspecifiedIpv6Address(Gateway), NetworkInterface);
  if Route = nil then
    Exit(ErrorNotFound);
  Route^.InUse := False;
  Result := ErrorNone;
end;

function RemoveAutomaticIpv6Route(constref Destination: TIpv6Address; PrefixLength: LongWord;
  constref Gateway: TIpv6Address; NetworkInterface: PNetworkInterface): LongInt;
var
  Route: PIpv6Route;
begin
  if PrefixLength > 128 then
    Exit(ErrorInvalidArgument);
  Route := FindRoute(Ipv6PrefixOf(Destination, PrefixLength), PrefixLength, Gateway,
    IsUnspecifiedIpv6Address(Gateway), NetworkInterface);
  if (Route = nil) or ((Route^.Flags and RouteFlagAutomatic) = 0) then
    Exit(ErrorNotFound);
  Route^.InUse := False;
  Result := ErrorNone;
end;

function FindIpv6RouteFlags(constref Destination: TIpv6Address; PrefixLength: LongWord;
  constref Gateway: TIpv6Address; NetworkInterface: PNetworkInterface; out Flags: LongWord;
  out ExpiresAt: QWord): Boolean;
var
  Route: PIpv6Route;
begin
  Flags := 0;
  ExpiresAt := 0;
  if PrefixLength > 128 then
    Exit(False);
  Route := FindRoute(Ipv6PrefixOf(Destination, PrefixLength), PrefixLength, Gateway, False, NetworkInterface);
  Result := Route <> nil;
  if Result then
  begin
    Flags := Route^.Flags;
    ExpiresAt := Route^.ExpiresAt;
  end;
end;

procedure RemoveIpv6InterfaceRoutes(NetworkInterface: PNetworkInterface; OnlyAutomatic: Boolean);
var
  Index: Integer;
begin
  for Index := 0 to MaximumIpv6Routes - 1 do
    if Routes[Index].InUse and (Routes[Index].NetworkInterface = NetworkInterface) and
       (not OnlyAutomatic or ((Routes[Index].Flags and RouteFlagAutomatic) <> 0)) then
      Routes[Index].InUse := False;
end;

function LookupIpv6Route(constref Destination: TIpv6Address; BoundInterface: PNetworkInterface;
  out NetworkInterface: PNetworkInterface; out NextHop: TIpv6Address): Boolean;
var
  Index: Integer;
  Best: PIpv6Route;
  Route: PIpv6Route;
begin
  Best := nil;
  for Index := 0 to MaximumIpv6Routes - 1 do
  begin
    Route := @Routes[Index];
    if not Route^.InUse or not InterfaceIsUsable(Route^.NetworkInterface) or
       ((BoundInterface <> nil) and (Route^.NetworkInterface <> BoundInterface)) or
       not SameIpv6Prefix(Destination, Route^.Destination, Route^.PrefixLength) then
      Continue;
    if (Best = nil) or (Route^.PrefixLength > Best^.PrefixLength) or
       ((Route^.PrefixLength = Best^.PrefixLength) and (Route^.Metric < Best^.Metric)) then
      Best := Route;
  end;
  Result := Best <> nil;
  if not Result then
  begin
    NetworkInterface := nil;
    NextHop := UnspecifiedIpv6Address;
    Exit;
  end;
  NetworkInterface := Best^.NetworkInterface;
  if IsUnspecifiedIpv6Address(Best^.Gateway) then
    NextHop := Destination
  else
    NextHop := Best^.Gateway;
end;

function Ipv6RouteExists(constref Destination: TIpv6Address; PrefixLength: LongWord; constref Gateway: TIpv6Address;
  NetworkInterface: PNetworkInterface): Boolean;
begin
  Result := FindRoute(Ipv6PrefixOf(Destination, PrefixLength), PrefixLength, Gateway, False,
    NetworkInterface) <> nil;
end;

function RunIpv6RouteTimers(Now: QWord): Boolean;
var
  Index: Integer;
begin
  Result := False;
  for Index := 0 to MaximumIpv6Routes - 1 do
  begin
    if not Routes[Index].InUse or (Routes[Index].ExpiresAt = Ipv6Forever) then
      Continue;
    if Routes[Index].ExpiresAt <= Now then
    begin
      Routes[Index].InUse := False;
      Result := True;
    end
    else
      RequestNetworkWakeAt(Routes[Index].ExpiresAt);
  end;
end;

function Ipv6RouteCount: Integer;
var
  Index: Integer;
begin
  Result := 0;
  for Index := 0 to MaximumIpv6Routes - 1 do
    if Routes[Index].InUse then
      Inc(Result);
end;

function DescribeIpv6Route(Position: Integer; out Description: TAbiRoute): Boolean;
var
  Index: Integer;
  Seen: Integer;
  Route: PIpv6Route;
begin
  FillMemory(@Description, SizeOf(Description), 0);
  Seen := 0;
  for Index := 0 to MaximumIpv6Routes - 1 do
  begin
    if not Routes[Index].InUse then
      Continue;
    if Seen = Position then
    begin
      Route := @Routes[Index];
      Description.Destination.Family := AddressFamilyIPv6;
      Description.Destination.PrefixLength := Route^.PrefixLength;
      CopyMemory(@Description.Destination.Address[0], @Route^.Destination[0], Ipv6AddressLength);
      CopyMemory(@Description.Gateway[0], @Route^.Gateway[0], Ipv6AddressLength);
      CopyText(@Description.InterfaceName[0], @Route^.NetworkInterface^.Name[0], NetworkInterfaceNameCapacity);
      Description.Flags := Route^.Flags;
      if Route^.NetworkInterface^.IsUp then
        Description.Flags := Description.Flags or RouteFlagUp;
      Description.Metric := Route^.Metric;
      Exit(True);
    end;
    Inc(Seen);
  end;
  Result := False;
end;

end.
