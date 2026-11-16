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
  route - show and change the routing table

  route [-n] [-4|-6|-A inet|inet6]
  route [-6] add|del default|[-net|-host] TARGET[/PREFIX] [netmask MASK] [gw GATEWAY] [dev INTERFACE] [metric N]

  Shows the routing table in the manner of net-tools' route -n (it is
  always numeric): the default route first, then the networks in
  order. "add" and "del" change it (root only): "default" is
  0.0.0.0/0, -host a single address (/32), -net a network given with a
  prefix or a netmask. A route through a gateway leaves by the
  interface that reaches the gateway, unless "dev" names one.

  -6 (or -A inet6) shows IPv6's routing table instead, as route -A
  inet6 does; with it, or with an IPv6 target, "add" and "del" change
  IPv6 routes ("default" is ::/0, -host a /128). A link-local gateway
  (fe80::2, as routers advertise) needs "dev".
}
program route;

{$mode objfpc}
{$H+}
{$pointermath on}

uses
  SysUtils,
  Abi.SystemCalls,
  Runtime.Text,
  Sys.Errors,
  Sys.Format,
  Sys.InternetAddresses,
  Sys.NetworkInterfaces,
  Sys.AddressText,
  Sys.Streams,
  Sys.Text,
  Util.Messages,
  Util.Options;

const
  Usage: PChar = 'Usage: route [-n] [-4|-6|-A inet|inet6]'#10 +
    '  or:  route [-6] add|del default|[-net|-host] TARGET[/PREFIX] [netmask MASK] [gw GATEWAY]'#10 +
    '                    [dev INTERFACE] [metric N]'#10 +
    'Show the routing table, or add or remove a route (root only).'#10 +
    #10 +
    '  -n, --numeric   numeric addresses (always)'#10 +
    '  -4              IPv4 (the default)'#10 +
    '  -6              IPv6'#10 +
    '  -A FAMILY       inet (IPv4) or inet6 (IPv6)'#10;

  OptionNumeric = 1;
  OptionIpv4 = 2;
  OptionIpv6 = 3;
  OptionFamily = 4;

type
  TRouteRequest = record
    Destination: TInternetAddress;
    PrefixLength: LongWord;
    HasPrefix: Boolean;
    Gateway: TInternetAddress;
    InterfaceName: PChar;
    Metric: LongWord;
  end;

var
  HostRoute: Boolean = False;
  { AddressFamilyIPv4 or AddressFamilyIPv6. }
  Family: Word = AddressFamilyIPv4;

procedure ShowIpv6Routes(const Routes: TRouteList);
var
  Route: TAbiRoute;
  Flags: array[0..7] of Char;
  Line: string;
begin
  WriteLine(StandardOutput, 'Kernel IPv6 routing table');
  WriteLine(StandardOutput, 'Destination                    Next Hop                   Flag Met  Iface');
  for Route in Routes do
  begin
    if Route.Destination.Family <> AddressFamilyIPv6 then
      Continue;
    FormatRouteFlags(Route, @Flags[0], SizeOf(Flags));
    Line := Format('%-30s %-26s %-4s %-4u %s', [InterfaceAddressToText(Route.Destination),
      AddressToText(RouteGateway(Route)), StrPas(PChar(@Flags[0])), Route.Metric,
      StrPas(PChar(@Route.InterfaceName[0]))]);
    WriteLine(StandardOutput, PChar(Line));
  end;
end;

procedure ShowRoutes;
var
  Routes: TRouteList;
  Index: Integer;
  Error: LongInt;
  DestinationText: array[0..Ipv4AddressTextCapacity - 1] of Char;
  GatewayText: array[0..Ipv4AddressTextCapacity - 1] of Char;
  MaskText: array[0..Ipv4AddressTextCapacity - 1] of Char;
  Flags: array[0..7] of Char;
begin
  Error := ListRoutes(Routes);
  if Error <> ErrorNone then
    FailWithError(1, Error, 'cannot read the routing table', []);
  SortRoutes(Routes);
  if Family = AddressFamilyIPv6 then
  begin
    ShowIpv6Routes(Routes);
    Exit;
  end;
  WriteLine(StandardOutput, 'Kernel IP routing table');
  WriteLine(StandardOutput, 'Destination     Gateway         Genmask         Flags Metric Iface');
  for Index := 0 to High(Routes) do
  begin
    if Routes[Index].Destination.Family <> AddressFamilyIPv4 then
      Continue;
    FormatInternetAddress(InterfaceAddressHost(Routes[Index].Destination), @DestinationText[0],
      SizeOf(DestinationText));
    FormatInternetAddress(RouteGateway(Routes[Index]), @GatewayText[0], SizeOf(GatewayText));
    FormatNetmask(Routes[Index].Destination.PrefixLength, @MaskText[0], SizeOf(MaskText));
    FormatRouteFlags(Routes[Index], @Flags[0], SizeOf(Flags));
    WriteFormatted(StandardOutput, '%-15s %-15s %-15s %-5s %-6u %s'#10, [ArgumentText(@DestinationText[0]),
      ArgumentText(@GatewayText[0]), ArgumentText(@MaskText[0]), ArgumentText(@Flags[0]),
      ArgumentUnsigned(Routes[Index].Metric), ArgumentText(@Routes[Index].InterfaceName[0])]);
  end;
end;

function ParseTarget(Text: PChar; var Request: TRouteRequest): Boolean;
begin
  if TextIsEqual(Text, 'default') then
  begin
    if Family = AddressFamilyIPv6 then
      Request.Destination := AnyIpv6Address
    else
      Request.Destination := AnyIpv4Address;
    Request.PrefixLength := 0;
    Request.HasPrefix := True;
    Exit(True);
  end;
  Result := ParseAddressWithPrefix(Text, Request.Destination, Request.PrefixLength, Request.HasPrefix);
  { An IPv6 target makes an IPv6 route. }
  if Result and (Request.Destination.Family = AddressFamilyIPv6) then
  begin
    Family := AddressFamilyIPv6;
    Request.Gateway := AnyIpv6Address;
  end;
end;

function ValueAfter(Operands: PPChar; Count: Integer; var Index: Integer): PChar;
begin
  if Index + 1 >= Count then
    FailWithUsageHint('''%s'' needs a value', [ArgumentText(Operands[Index])]);
  Inc(Index);
  Result := Operands[Index];
end;

procedure ParseRequest(Operands: PPChar; Count: Integer; out Request: TRouteRequest);
var
  Index: Integer;
  Setting: PChar;
  Value: PChar;
  Number: QWord;
begin
  Request.Destination := AnyIpv4Address;
  Request.PrefixLength := 32;
  Request.HasPrefix := False;
  Request.Gateway := AnyIpv4Address;
  if Family = AddressFamilyIPv6 then
    Request.Gateway := AnyIpv6Address;
  Request.InterfaceName := nil;
  Request.Metric := 0;
  Index := 1;
  while (Index < Count) and (TextIsEqual(Operands[Index], '-net') or TextIsEqual(Operands[Index], '-host')) do
  begin
    if TextIsEqual(Operands[Index], '-host') then
      HostRoute := True;
    Inc(Index);
  end;
  if Index >= Count then
    FailWithUsageHint('missing route target', []);
  if not ParseTarget(Operands[Index], Request) then
    Fail(1, '%s: bad address', [ArgumentText(Operands[Index])]);
  Inc(Index);
  while Index < Count do
  begin
    Setting := Operands[Index];
    Value := ValueAfter(Operands, Count, Index);
    if TextIsEqual(Setting, 'gw') then
    begin
      if not ParseInternetAddress(Value, Request.Gateway) or (Request.Gateway.Family <> Family) then
        Fail(1, '%s: bad address', [ArgumentText(Value)]);
    end
    else if TextIsEqual(Setting, 'dev') then
      Request.InterfaceName := Value
    else if TextIsEqual(Setting, 'netmask') then
    begin
      if not ParseNetmask(Value, Request.PrefixLength) then
        Fail(1, '%s: bad netmask', [ArgumentText(Value)]);
      Request.HasPrefix := True;
    end
    else if TextIsEqual(Setting, 'metric') then
    begin
      if not ParseUnsigned(Value, Number) or (Number > High(LongWord)) then
        Fail(1, '%s: bad metric', [ArgumentText(Value)]);
      Request.Metric := LongWord(Number);
    end
    else
      FailWithUsageHint('unknown setting ''%s''', [ArgumentText(Setting)]);
    Inc(Index);
  end;
  if HostRoute and (Family = AddressFamilyIPv6) then
    Request.PrefixLength := 128
  else if HostRoute then
    Request.PrefixLength := 32
  else if not Request.HasPrefix and (Family = AddressFamilyIPv6) then
    Request.PrefixLength := 128;
end;

procedure ChangeRoute(Operands: PPChar; Count: Integer);
var
  Request: TRouteRequest;
  Error: LongInt;
begin
  ParseRequest(Operands, Count, Request);
  if TextIsEqual(Operands[0], 'add') then
  begin
    if AddressIsUnspecified(Request.Gateway) and (Request.InterfaceName = nil) then
      Fail(1, 'a route needs a gateway (gw) or an interface (dev)', []);
    Error := AddRoute(Request.Destination, Request.PrefixLength, Request.Gateway, Request.InterfaceName,
      Request.Metric);
  end
  else
    Error := RemoveRoute(Request.Destination, Request.PrefixLength, Request.Gateway);
  if Error = ErrorNotFound then
    Fail(1, 'no such route', []);
  if Error <> ErrorNone then
    FailWithError(1, Error, 'cannot %s the route', [ArgumentText(Operands[0])]);
end;

var
  Parser: TOptionParser;
  Code: Integer;
  Value: PChar;

begin
  BeginOptions(Parser, [
    OptionDefinition('n', 'numeric', False, OptionNumeric),
    OptionDefinition('4', nil, False, OptionIpv4),
    OptionDefinition('6', nil, False, OptionIpv6),
    OptionDefinition('A', nil, True, OptionFamily)], Usage);
  { "route add -net ...": what follows the command is its own. }
  Parser.StopAtFirstOperand := True;
  while NextOption(Parser, Code, Value) do
    case Code of
      OptionIpv4: Family := AddressFamilyIPv4;
      OptionIpv6: Family := AddressFamilyIPv6;
      OptionFamily:
        if TextIsEqual(Value, 'inet6') then
          Family := AddressFamilyIPv6
        else if TextIsEqual(Value, 'inet') then
          Family := AddressFamilyIPv4
        else
          FailWithUsageHint('unknown address family %s', [ArgumentText(Value)]);
    end;
  if Parser.OperandCount = 0 then
    ShowRoutes
  else if TextIsEqual(Parser.Operands[0], 'add') or TextIsEqual(Parser.Operands[0], 'del') then
    ChangeRoute(Parser.Operands, Parser.OperandCount)
  else
    FailWithUsageHint('unknown command ''%s''', [ArgumentText(Parser.Operands[0])]);
  FlushStream(StandardOutput);
end.
