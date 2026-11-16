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
  The routing table: which interface a datagram leaves by, and the next
  hop it is sent to there (the destination itself on the link, else a
  gateway).

  Giving an interface an address adds an interface route for its
  network (10.0.2.0/24 on eth0), which goes when the address goes;
  other routes are added and removed by hand (route add default gw
  10.0.2.2), the gateway on a network an interface reaches. A lookup
  takes the route with the longest prefix that covers the destination,
  on an interface that is up, the lowest metric among equals. Used
  under the network lock.
}
unit Network.Routing;

{$mode objfpc}

interface

uses
  Abi.SystemCalls,
  Network.Addresses,
  Network.Interfaces;

const
  MaximumRoutes = 64;

type
  PRoute = ^TRoute;
  TRoute = record
    InUse: Boolean;
    Destination: TIpv4Address;
    PrefixLength: LongWord;
    { AnyAddress: on the link. }
    Gateway: TIpv4Address;
    NetworkInterface: PNetworkInterface;
    { RouteFlagGateway, RouteFlagInterface. }
    Flags: LongWord;
    Metric: LongWord;
  end;

{ Adds a route. NetworkInterface nil: the interface whose network has
  the gateway. ErrorNetworkUnreachable if none has, ErrorExists for a
  route that is there already, ErrorNoSpace when the table is full. }
function AddRoute(Destination: TIpv4Address; PrefixLength: LongWord; Gateway: TIpv4Address;
  NetworkInterface: PNetworkInterface; Flags, Metric: LongWord): LongInt;
{ Removes the route with this destination, prefix and gateway (any
  gateway if Gateway is AnyAddress); ErrorNotFound if there is none. }
function RemoveRoute(Destination: TIpv4Address; PrefixLength: LongWord; Gateway: TIpv4Address): LongInt;
{ Removes every route that goes out of NetworkInterface. }
procedure RemoveInterfaceRoutes(NetworkInterface: PNetworkInterface);
{ The interface and next hop for Destination; False if no route covers
  it. }
function LookupRoute(Destination: TIpv4Address; out NetworkInterface: PNetworkInterface;
  out NextHop: TIpv4Address): Boolean;
function RouteCount: Integer;
{ The route at Position (from 0) as the system call shows it; False past
  the last. }
function DescribeRoute(Position: Integer; out Description: TAbiRoute): Boolean;

implementation

uses
  Runtime.Memory,
  Runtime.Text;

var
  Routes: array[0..MaximumRoutes - 1] of TRoute;

{ The interface whose own network (or own address) has Address. }
function InterfaceReaching(Address: TIpv4Address): PNetworkInterface;
var
  Position: Integer;
  Candidate: PNetworkInterface;
begin
  for Position := 0 to NetworkInterfaceCount - 1 do
  begin
    Candidate := NetworkInterfaceAt(Position);
    if Candidate^.HasAddress and SameNetwork(Candidate^.Address, Address, Candidate^.PrefixLength) then
      Exit(Candidate);
  end;
  Result := nil;
end;

function FindRoute(Destination: TIpv4Address; PrefixLength: LongWord; Gateway: TIpv4Address;
  AnyGateway: Boolean): Integer;
var
  Index: Integer;
begin
  for Index := 0 to MaximumRoutes - 1 do
    if Routes[Index].InUse and (Routes[Index].Destination = Destination) and
       (Routes[Index].PrefixLength = PrefixLength) and
       (AnyGateway or (Routes[Index].Gateway = Gateway)) then
      Exit(Index);
  Result := -1;
end;

function AddRoute(Destination: TIpv4Address; PrefixLength: LongWord; Gateway: TIpv4Address;
  NetworkInterface: PNetworkInterface; Flags, Metric: LongWord): LongInt;
var
  Index: Integer;
begin
  if PrefixLength > 32 then
    Exit(ErrorInvalidArgument);
  Destination := Destination and PrefixMask(PrefixLength);
  if NetworkInterface = nil then
  begin
    if Gateway = AnyAddress then
      Exit(ErrorInvalidArgument);
    NetworkInterface := InterfaceReaching(Gateway);
    if NetworkInterface = nil then
      Exit(ErrorNetworkUnreachable);
  end;
  if FindRoute(Destination, PrefixLength, Gateway, False) >= 0 then
    Exit(ErrorExists);
  for Index := 0 to MaximumRoutes - 1 do
  begin
    if not Routes[Index].InUse then
    begin
      Routes[Index].InUse := True;
      Routes[Index].Destination := Destination;
      Routes[Index].PrefixLength := PrefixLength;
      Routes[Index].Gateway := Gateway;
      Routes[Index].NetworkInterface := NetworkInterface;
      Routes[Index].Flags := Flags and (RouteFlagGateway or RouteFlagInterface);
      if Gateway <> AnyAddress then
        Routes[Index].Flags := Routes[Index].Flags or RouteFlagGateway;
      Routes[Index].Metric := Metric;
      Exit(ErrorNone);
    end;
  end;
  Result := ErrorNoSpace;
end;

function RemoveRoute(Destination: TIpv4Address; PrefixLength: LongWord; Gateway: TIpv4Address): LongInt;
var
  Index: Integer;
begin
  if PrefixLength > 32 then
    Exit(ErrorInvalidArgument);
  Index := FindRoute(Destination and PrefixMask(PrefixLength), PrefixLength, Gateway, Gateway = AnyAddress);
  if Index < 0 then
    Exit(ErrorNotFound);
  Routes[Index].InUse := False;
  Result := ErrorNone;
end;

procedure RemoveInterfaceRoutes(NetworkInterface: PNetworkInterface);
var
  Index: Integer;
begin
  for Index := 0 to MaximumRoutes - 1 do
    if Routes[Index].InUse and (Routes[Index].NetworkInterface = NetworkInterface) then
      Routes[Index].InUse := False;
end;

function LookupRoute(Destination: TIpv4Address; out NetworkInterface: PNetworkInterface;
  out NextHop: TIpv4Address): Boolean;
var
  Index: Integer;
  Best: Integer;
begin
  Best := -1;
  for Index := 0 to MaximumRoutes - 1 do
  begin
    if not Routes[Index].InUse or not Routes[Index].NetworkInterface^.IsUp or
       not SameNetwork(Destination, Routes[Index].Destination, Routes[Index].PrefixLength) then
      Continue;
    if (Best < 0) or (Routes[Index].PrefixLength > Routes[Best].PrefixLength) or
       ((Routes[Index].PrefixLength = Routes[Best].PrefixLength) and
        (Routes[Index].Metric < Routes[Best].Metric)) then
      Best := Index;
  end;
  Result := Best >= 0;
  if not Result then
  begin
    NetworkInterface := nil;
    NextHop := AnyAddress;
    Exit;
  end;
  NetworkInterface := Routes[Best].NetworkInterface;
  if Routes[Best].Gateway <> AnyAddress then
    NextHop := Routes[Best].Gateway
  else
    NextHop := Destination;
end;

function RouteCount: Integer;
var
  Index: Integer;
begin
  Result := 0;
  for Index := 0 to MaximumRoutes - 1 do
    if Routes[Index].InUse then
      Inc(Result);
end;

function DescribeRoute(Position: Integer; out Description: TAbiRoute): Boolean;
var
  Index: Integer;
  Seen: Integer;
  Route: PRoute;
begin
  FillMemory(@Description, SizeOf(Description), 0);
  Seen := 0;
  for Index := 0 to MaximumRoutes - 1 do
  begin
    if not Routes[Index].InUse then
      Continue;
    if Seen = Position then
    begin
      Route := @Routes[Index];
      Description.Destination.Family := AddressFamilyIPv4;
      Description.Destination.PrefixLength := Route^.PrefixLength;
      WriteIpv4Address(@Description.Destination.Address[0], Route^.Destination);
      WriteIpv4Address(@Description.Gateway[0], Route^.Gateway);
      CopyText(@Description.InterfaceName[0], @Route^.NetworkInterface^.Name[0],
        NetworkInterfaceNameCapacity);
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
