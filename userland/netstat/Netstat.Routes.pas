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
  the kernel keeps none of the three per route, so they are 0).
}
unit Netstat.Routes;

{$mode objfpc}

interface

procedure ShowRoutingTable;

implementation

uses
  Abi.SystemCalls,
  Sys.Errors,
  Sys.Format,
  Sys.InternetAddresses,
  Sys.NetworkInterfaces,
  Sys.Streams,
  Util.Messages;

procedure WriteRoute(constref Route: TAbiRoute);
var
  DestinationText: array[0..Ipv4AddressTextCapacity - 1] of Char;
  GatewayText: array[0..Ipv4AddressTextCapacity - 1] of Char;
  MaskText: array[0..Ipv4AddressTextCapacity - 1] of Char;
  Flags: array[0..7] of Char;
begin
  FormatInternetAddress(InterfaceAddressHost(Route.Destination), @DestinationText[0], SizeOf(DestinationText));
  FormatInternetAddress(RouteGateway(Route), @GatewayText[0], SizeOf(GatewayText));
  FormatNetmask(Route.Destination.PrefixLength, @MaskText[0], SizeOf(MaskText));
  FormatRouteFlags(Route, @Flags[0], SizeOf(Flags));
  WriteFormatted(StandardOutput, '%-15s %-15s %-15s %-5s %5u %-5u %6u %s'#10, [ArgumentText(@DestinationText[0]),
    ArgumentText(@GatewayText[0]), ArgumentText(@MaskText[0]), ArgumentText(@Flags[0]), ArgumentUnsigned(0),
    ArgumentUnsigned(0), ArgumentUnsigned(0), ArgumentText(@Route.InterfaceName[0])]);
end;

procedure ShowRoutingTable;
var
  Routes: TRouteList;
  Index: Integer;
  Error: LongInt;
begin
  Error := ListRoutes(Routes);
  if Error <> ErrorNone then
    FailWithError(1, Error, 'cannot read the routing table', []);
  SortRoutes(Routes);
  WriteLine(StandardOutput, 'Kernel IP routing table');
  WriteLine(StandardOutput, 'Destination     Gateway         Genmask         Flags   MSS Window  irtt Iface');
  for Index := 0 to High(Routes) do
    WriteRoute(Routes[Index]);
end;

end.
