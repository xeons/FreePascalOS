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
  netstat -r: the routing table as net-tools' netstat -rn writes it
  (route -n's columns, with MSS, Window and irtt in place of Metric;
  the kernel keeps none of the three per route, so they are 0), then
  IPv6's as netstat -rn -6 writes it.
}
unit Netstat.Routes;

{$mode objfpc}
{$H+}

interface

uses
  Netstat.Selection;

procedure ShowRoutingTable(constref Selection: TNetstatSelection);

implementation

uses
  SysUtils,
  Abi.SystemCalls,
  Sys.InternetAddresses,
  Sys.NetworkInterfaces,
  Sys.AddressText,
  Sys.InterfaceText,
  Util.Messages,
  Sys.Streams;

procedure WriteRoute(constref Route: TAbiRoute);
begin
  PrintString(Format('%-15s %-15s %-15s %-5s %5u %-5u %6u %s'#10, [
    AddressToText(InterfaceAddressHost(Route.Destination)), AddressToText(RouteGateway(Route)),
    NetmaskToText(Route.Destination.PrefixLength), RouteFlagsToText(Route), 0, 0, 0,
    InterfaceNameToText(Route.InterfaceName)]));
end;

procedure WriteIpv6Route(constref Route: TAbiRoute);
begin
  PrintString(Format('%-30s %-26s %-5s %5u %s'#10, [InterfaceAddressToText(Route.Destination),
    AddressToText(RouteGateway(Route)), RouteFlagsToText(Route), QWord(Route.Metric),
    InterfaceNameToText(Route.InterfaceName)]));
end;

procedure ShowIpv4Routes(const Routes: TRouteList);
var
  Index: Integer;
begin
  PrintStringLine('Kernel IP routing table');
  PrintStringLine('Destination     Gateway         Genmask         Flags   MSS Window  irtt Iface');
  for Index := 0 to High(Routes) do
    if Routes[Index].Destination.Family = AddressFamilyIPv4 then
      WriteRoute(Routes[Index]);
end;

procedure ShowIpv6Routes(const Routes: TRouteList);
var
  Index: Integer;
begin
  PrintStringLine('Kernel IPv6 routing table');
  PrintStringLine('Destination                    Next Hop                   Flag  Metric Iface');
  for Index := 0 to High(Routes) do
    if Routes[Index].Destination.Family = AddressFamilyIPv6 then
      WriteIpv6Route(Routes[Index]);
end;

procedure ShowRoutingTable(constref Selection: TNetstatSelection);
var
  Routes: TRouteList;
  Error: LongInt;
begin
  Error := ListRoutes(Routes);
  if Error <> ErrorNone then
    FailWithError(1, Error, 'cannot read the routing table');
  SortRoutes(Routes);
  if Selection.ShowIpv4 then
    ShowIpv4Routes(Routes);
  if Selection.ShowIpv4 and Selection.ShowIpv6 then
    PrintStringLine('');
  if Selection.ShowIpv6 then
    ShowIpv6Routes(Routes);
end;

end.
