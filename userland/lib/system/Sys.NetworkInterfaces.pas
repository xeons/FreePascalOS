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
  The network's configuration: the interfaces (their addresses, state,
  MTU and counters), the routes, the ARP cache, every socket and
  connection, the DNS servers, and the protocols' counters. Anyone may
  list; only root may
  change (ErrorNotPermitted otherwise), as ifconfig, route and the
  network setup service do.
}
unit Sys.NetworkInterfaces;

{$mode objfpc}
{$pointermath on}

interface

uses
  Abi.SystemCalls,
  Sys.InternetAddresses;

type
  TNetworkInterfaceList = array of TAbiNetworkInterface;
  TRouteList = array of TAbiRoute;
  TArpEntryList = array of TAbiArpEntry;
  TSocketInformationList = array of TAbiSocketInformation;
  TNeighborEntryList = array of TAbiNeighborEntry;

function ListNetworkInterfaces(out Interfaces: TNetworkInterfaceList): LongInt;
{ False if there is no interface Name. }
function FindNetworkInterface(Name: PChar; out Description: TAbiNetworkInterface): Boolean;
{ IPv4: the interface's address becomes Address. IPv6: Address is added
  beside the interface's other addresses. }
function SetInterfaceAddress(Name: PChar; constref Address: TInternetAddress; PrefixLength: LongWord): LongInt;
{ Takes the interface's IPv4 address away. }
function RemoveInterfaceAddress(Name: PChar): LongInt;
{ Adds an IPv6 address (one that never expires) to the interface. }
function AddInterfaceIpv6Address(Name: PChar; constref Address: TInternetAddress; PrefixLength: LongWord): LongInt;
{ Removes one of the interface's IPv6 addresses. }
function RemoveInterfaceIpv6Address(Name: PChar; constref Address: TInternetAddress): LongInt;
{ Ipv6ModeOff, Ipv6ModeLinkLocal or Ipv6ModeAutomatic. }
function SetInterfaceIpv6Mode(Name: PChar; Mode: LongWord): LongInt;
{ Ipv6Option* (temporary addresses, EUI-64 identifiers). }
function SetInterfaceIpv6Options(Name: PChar; Options: LongWord): LongInt;
{ The secret of every interface's stable-privacy identifiers
  (StableSecretBytes at Secret). }
function SetIpv6StableSecret(Secret: PByte): LongInt;
{ The interface's IPv4 address, if it has one. }
function FindInterfaceIpv4Address(constref Description: TAbiNetworkInterface;
  out Address: TAbiInterfaceAddress): Boolean;
{ True if the interface has Address (of either family) with PrefixLength. }
function InterfaceHasAddress(constref Description: TAbiNetworkInterface; constref Address: TInternetAddress;
  PrefixLength: LongWord): Boolean;
function SetInterfaceUp(Name: PChar; Up: Boolean): LongInt;
function SetInterfaceMtu(Name: PChar; Mtu: LongWord): LongInt;

function ListRoutes(out Routes: TRouteList): LongInt;
{ In the order route -n shows them: the default route first, then the
  networks by address, a longer prefix before a shorter one. }
procedure SortRoutes(var Routes: TRouteList);
{ The gateway of a route as an address. }
function RouteGateway(constref Route: TAbiRoute): TInternetAddress;
{ Gateway 0.0.0.0: on the link of InterfaceName. InterfaceName nil or
  empty: the interface that reaches the gateway. }
function AddRoute(constref Destination: TInternetAddress; PrefixLength: LongWord;
  constref Gateway: TInternetAddress; InterfaceName: PChar; Metric: LongWord): LongInt;
{ Gateway 0.0.0.0: whatever the route's gateway. }
function RemoveRoute(constref Destination: TInternetAddress; PrefixLength: LongWord;
  constref Gateway: TInternetAddress): LongInt;

function ListArpEntries(out Entries: TArpEntryList): LongInt;
{ IPv6's neighbour cache. }
function ListNeighbors(out Entries: TNeighborEntryList): LongInt;
function ListSockets(out Entries: TSocketInformationList): LongInt;
function GetDnsServers(out Servers: TAbiDnsServers): LongInt;
function SetDnsServers(constref Servers: TAbiDnsServers): LongInt;
{ A handle (an automatic reset event) that becomes ready after every
  change to the network's configuration: an adapter that appears, a
  link that comes or goes, an interface turned on or off or given an
  address, a route, the DNS servers. Or minus an error code. Closed with
  CloseHandle (Sys.Objects). }
function WatchNetworkChanges: Int64;
{ The counters of IP, ICMP, TCP and UDP since the start. }
function GetNetworkStatistics(out Statistics: TAbiNetworkStatistics): LongInt;

implementation

uses
  Runtime.Memory,
  Runtime.Text,
  Sys.Kernel,
  Sys.Errors;

const
  { Room asked for at first; asked again with more if there are more. }
  FirstCapacity = 16;

function ListNetworkInterfaces(out Interfaces: TNetworkInterfaceList): LongInt;
var
  Count: Int64;
begin
  SetLength(Interfaces, FirstCapacity);
  repeat
    Count := KernelListNetworkInterfaces(@Interfaces[0], Length(Interfaces));
    if Count < 0 then
    begin
      SetLength(Interfaces, 0);
      Exit(ErrorCodeOf(Count));
    end;
    if Count <= Length(Interfaces) then
      Break;
    SetLength(Interfaces, Count);
  until False;
  SetLength(Interfaces, Count);
  Result := ErrorNone;
end;

function FindNetworkInterface(Name: PChar; out Description: TAbiNetworkInterface): Boolean;
var
  Interfaces: TNetworkInterfaceList;
  Index: Integer;
begin
  FillMemory(@Description, SizeOf(Description), 0);
  Result := False;
  if ListNetworkInterfaces(Interfaces) <> ErrorNone then
    Exit;
  for Index := 0 to High(Interfaces) do
    if TextIsEqual(@Interfaces[Index].Name[0], Name) then
    begin
      Description := Interfaces[Index];
      Exit(True);
    end;
end;

function Configure(Name: PChar; var Configuration: TAbiInterfaceConfiguration): LongInt;
begin
  CopyText(@Configuration.Name[0], Name, NetworkInterfaceNameCapacity);
  Result := ErrorCodeOf(KernelConfigureNetworkInterface(Configuration));
end;

function SetInterfaceAddress(Name: PChar; constref Address: TInternetAddress; PrefixLength: LongWord): LongInt;
var
  Configuration: TAbiInterfaceConfiguration;
begin
  FillMemory(@Configuration, SizeOf(Configuration), 0);
  Configuration.Changes := InterfaceChangeAddress;
  Configuration.Address.Family := Address.Family;
  Configuration.Address.PrefixLength := PrefixLength;
  CopyMemory(@Configuration.Address.Address[0], @Address.Bytes[0], 16);
  Result := Configure(Name, Configuration);
end;

function RemoveInterfaceAddress(Name: PChar): LongInt;
var
  Configuration: TAbiInterfaceConfiguration;
begin
  FillMemory(@Configuration, SizeOf(Configuration), 0);
  Configuration.Changes := InterfaceChangeAddress;
  Configuration.Address.Family := AddressFamilyUnspecified;
  Result := Configure(Name, Configuration);
end;

function AddInterfaceIpv6Address(Name: PChar; constref Address: TInternetAddress; PrefixLength: LongWord): LongInt;
begin
  if Address.Family <> AddressFamilyIPv6 then
    Exit(ErrorAddressFamilyNotSupported);
  Result := SetInterfaceAddress(Name, Address, PrefixLength);
end;

function RemoveInterfaceIpv6Address(Name: PChar; constref Address: TInternetAddress): LongInt;
var
  Configuration: TAbiInterfaceConfiguration;
begin
  if Address.Family <> AddressFamilyIPv6 then
    Exit(ErrorAddressFamilyNotSupported);
  FillMemory(@Configuration, SizeOf(Configuration), 0);
  Configuration.Changes := InterfaceChangeRemoveAddress;
  Configuration.Address.Family := AddressFamilyIPv6;
  CopyMemory(@Configuration.Address.Address[0], @Address.Bytes[0], 16);
  Result := Configure(Name, Configuration);
end;

function SetInterfaceIpv6Mode(Name: PChar; Mode: LongWord): LongInt;
var
  Configuration: TAbiInterfaceConfiguration;
begin
  FillMemory(@Configuration, SizeOf(Configuration), 0);
  Configuration.Changes := InterfaceChangeIpv6Mode;
  Configuration.Ipv6Mode := Mode;
  Result := Configure(Name, Configuration);
end;

function SetInterfaceIpv6Options(Name: PChar; Options: LongWord): LongInt;
var
  Configuration: TAbiInterfaceConfiguration;
begin
  FillMemory(@Configuration, SizeOf(Configuration), 0);
  Configuration.Changes := InterfaceChangeIpv6Options;
  Configuration.Ipv6Options := Options;
  Result := Configure(Name, Configuration);
end;

function SetIpv6StableSecret(Secret: PByte): LongInt;
var
  Configuration: TAbiInterfaceConfiguration;
begin
  FillMemory(@Configuration, SizeOf(Configuration), 0);
  Configuration.Changes := InterfaceChangeStableSecret;
  CopyMemory(@Configuration.StableSecret[0], Secret, StableSecretBytes);
  { Any interface will do; lo is always there. }
  Result := Configure('lo', Configuration);
  FillMemory(@Configuration.StableSecret[0], StableSecretBytes, 0);
end;

function FindInterfaceIpv4Address(constref Description: TAbiNetworkInterface;
  out Address: TAbiInterfaceAddress): Boolean;
var
  Index: LongWord;
begin
  FillMemory(@Address, SizeOf(Address), 0);
  Index := 0;
  while (Index < Description.AddressCount) and (Index < MaximumInterfaceAddresses) do
  begin
    if Description.Addresses[Index].Family = AddressFamilyIPv4 then
    begin
      Address := Description.Addresses[Index];
      Exit(True);
    end;
    Inc(Index);
  end;
  Result := False;
end;

function InterfaceHasAddress(constref Description: TAbiNetworkInterface; constref Address: TInternetAddress;
  PrefixLength: LongWord): Boolean;
var
  Index: LongWord;
begin
  Index := 0;
  while (Index < Description.AddressCount) and (Index < MaximumInterfaceAddresses) do
  begin
    if AddressesAreEqual(InterfaceAddressHost(Description.Addresses[Index]), Address) and
       (Description.Addresses[Index].PrefixLength = PrefixLength) then
      Exit(True);
    Inc(Index);
  end;
  Result := False;
end;

function SetInterfaceUp(Name: PChar; Up: Boolean): LongInt;
var
  Configuration: TAbiInterfaceConfiguration;
begin
  FillMemory(@Configuration, SizeOf(Configuration), 0);
  Configuration.Changes := InterfaceChangeUp;
  Configuration.Up := Ord(Up);
  Result := Configure(Name, Configuration);
end;

function SetInterfaceMtu(Name: PChar; Mtu: LongWord): LongInt;
var
  Configuration: TAbiInterfaceConfiguration;
begin
  FillMemory(@Configuration, SizeOf(Configuration), 0);
  Configuration.Changes := InterfaceChangeMtu;
  Configuration.Mtu := Mtu;
  Result := Configure(Name, Configuration);
end;

function ListRoutes(out Routes: TRouteList): LongInt;
var
  Count: Int64;
begin
  SetLength(Routes, FirstCapacity);
  repeat
    Count := KernelListRoutes(@Routes[0], Length(Routes));
    if Count < 0 then
    begin
      SetLength(Routes, 0);
      Exit(ErrorCodeOf(Count));
    end;
    if Count <= Length(Routes) then
      Break;
    SetLength(Routes, Count);
  until False;
  SetLength(Routes, Count);
  Result := ErrorNone;
end;

procedure DescribeRoute(constref Destination: TInternetAddress; PrefixLength: LongWord;
  constref Gateway: TInternetAddress; out Route: TAbiRoute);
begin
  FillMemory(@Route, SizeOf(Route), 0);
  Route.Destination.Family := Destination.Family;
  Route.Destination.PrefixLength := PrefixLength;
  CopyMemory(@Route.Destination.Address[0], @Destination.Bytes[0], 16);
  CopyMemory(@Route.Gateway[0], @Gateway.Bytes[0], 16);
end;

function AddRoute(constref Destination: TInternetAddress; PrefixLength: LongWord;
  constref Gateway: TInternetAddress; InterfaceName: PChar; Metric: LongWord): LongInt;
var
  Route: TAbiRoute;
begin
  DescribeRoute(Destination, PrefixLength, Gateway, Route);
  if InterfaceName <> nil then
    CopyText(@Route.InterfaceName[0], InterfaceName, NetworkInterfaceNameCapacity);
  Route.Metric := Metric;
  Result := ErrorCodeOf(KernelChangeRoute(RouteAdd, Route));
end;

function RemoveRoute(constref Destination: TInternetAddress; PrefixLength: LongWord;
  constref Gateway: TInternetAddress): LongInt;
var
  Route: TAbiRoute;
begin
  DescribeRoute(Destination, PrefixLength, Gateway, Route);
  Result := ErrorCodeOf(KernelChangeRoute(RouteRemove, Route));
end;

function ListArpEntries(out Entries: TArpEntryList): LongInt;
var
  Count: Int64;
begin
  SetLength(Entries, FirstCapacity * 4);
  repeat
    Count := KernelListArpEntries(@Entries[0], Length(Entries));
    if Count < 0 then
    begin
      SetLength(Entries, 0);
      Exit(ErrorCodeOf(Count));
    end;
    if Count <= Length(Entries) then
      Break;
    SetLength(Entries, Count);
  until False;
  SetLength(Entries, Count);
  Result := ErrorNone;
end;

function ListNeighbors(out Entries: TNeighborEntryList): LongInt;
var
  Count: Int64;
begin
  SetLength(Entries, FirstCapacity * 4);
  repeat
    Count := KernelListNeighbors(@Entries[0], Length(Entries));
    if Count < 0 then
    begin
      SetLength(Entries, 0);
      Exit(ErrorCodeOf(Count));
    end;
    if Count <= Length(Entries) then
      Break;
    SetLength(Entries, Count);
  until False;
  SetLength(Entries, Count);
  Result := ErrorNone;
end;

function ListSockets(out Entries: TSocketInformationList): LongInt;
var
  Count: Int64;
begin
  SetLength(Entries, FirstCapacity * 4);
  repeat
    Count := KernelListSockets(@Entries[0], Length(Entries));
    if Count < 0 then
    begin
      SetLength(Entries, 0);
      Exit(ErrorCodeOf(Count));
    end;
    if Count <= Length(Entries) then
      Break;
    SetLength(Entries, Count);
  until False;
  SetLength(Entries, Count);
  Result := ErrorNone;
end;

function GetDnsServers(out Servers: TAbiDnsServers): LongInt;
begin
  Result := ErrorCodeOf(KernelGetDnsServers(Servers));
end;

function SetDnsServers(constref Servers: TAbiDnsServers): LongInt;
begin
  Result := ErrorCodeOf(KernelSetDnsServers(Servers));
end;

function WatchNetworkChanges: Int64;
begin
  Result := KernelWatchNetworkChanges;
end;

function GetNetworkStatistics(out Statistics: TAbiNetworkStatistics): LongInt;
begin
  FillMemory(@Statistics, SizeOf(Statistics), 0);
  Result := ErrorCodeOf(KernelGetNetworkStatistics(Statistics));
end;

{ Negative, 0 or positive as First's destination comes before, with or
  after Second's (byte by byte, as written). }
function CompareDestinations(constref First, Second: TAbiRoute): Integer;
var
  Index: Integer;
begin
  for Index := 0 to 15 do
    if First.Destination.Address[Index] <> Second.Destination.Address[Index] then
      Exit(Integer(First.Destination.Address[Index]) - Integer(Second.Destination.Address[Index]));
  Result := 0;
end;

function RouteComesBefore(constref First, Second: TAbiRoute): Boolean;
var
  Comparison: Integer;
begin
  { IPv4 routes before IPv6 ones. }
  if First.Destination.Family <> Second.Destination.Family then
    Exit(First.Destination.Family = AddressFamilyIPv4);
  if (First.Destination.PrefixLength = 0) <> (Second.Destination.PrefixLength = 0) then
    Exit(First.Destination.PrefixLength = 0);
  Comparison := CompareDestinations(First, Second);
  if Comparison <> 0 then
    Exit(Comparison < 0);
  if First.Destination.PrefixLength <> Second.Destination.PrefixLength then
    Exit(First.Destination.PrefixLength > Second.Destination.PrefixLength);
  Result := First.Metric < Second.Metric;
end;

procedure SortRoutes(var Routes: TRouteList);
var
  Index: Integer;
  Place: Integer;
  Held: TAbiRoute;
begin
  for Index := 1 to High(Routes) do
  begin
    Held := Routes[Index];
    Place := Index;
    while (Place > 0) and RouteComesBefore(Held, Routes[Place - 1]) do
    begin
      Routes[Place] := Routes[Place - 1];
      Dec(Place);
    end;
    Routes[Place] := Held;
  end;
end;

function RouteGateway(constref Route: TAbiRoute): TInternetAddress;
begin
  if Route.Destination.Family = AddressFamilyIPv6 then
  begin
    Result := AnyIpv6Address;
    CopyMemory(@Result.Bytes[0], @Route.Gateway[0], 16);
  end
  else
  begin
    Result := AnyIpv4Address;
    CopyMemory(@Result.Bytes[0], @Route.Gateway[0], 4);
  end;
end;

end.
