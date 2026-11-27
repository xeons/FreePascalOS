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

uses
  SysUtils,
  Abi.SystemCalls,
  Sys.InternetAddresses,
  Sys.NetworkInterfaces,
  Sys.AddressText,
  Sys.InterfaceText,
  Util.CommandLine,
  Util.Messages,
  Util.Numbers,
  Sys.Streams;

const
  Usage = 'Usage: route [-n] [-4|-6|-A inet|inet6]'#10 +
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
    { '' for the interface that reaches the gateway. }
    InterfaceName: string;
    Metric: LongWord;
  end;

var
  HostRoute: Boolean = False;
  { AddressFamilyIPv4 or AddressFamilyIPv6. }
  Family: Word = AddressFamilyIPv4;

procedure ShowIpv6Routes(const Routes: TRouteList);
var
  Route: TAbiRoute;
begin
  PrintStringLine('Kernel IPv6 routing table');
  PrintStringLine('Destination                    Next Hop                   Flag Met  Iface');
  for Route in Routes do
  begin
    if Route.Destination.Family <> AddressFamilyIPv6 then
      Continue;
    PrintStringLine(Format('%-30s %-26s %-4s %-4u %s', [InterfaceAddressToText(Route.Destination),
      AddressToText(RouteGateway(Route)), RouteFlagsToText(Route), Route.Metric,
      InterfaceNameToText(Route.InterfaceName)]));
  end;
end;

procedure ShowIpv4Routes(const Routes: TRouteList);
var
  Route: TAbiRoute;
begin
  PrintStringLine('Kernel IP routing table');
  PrintStringLine('Destination     Gateway         Genmask         Flags Metric Iface');
  for Route in Routes do
  begin
    if Route.Destination.Family <> AddressFamilyIPv4 then
      Continue;
    PrintStringLine(Format('%-15s %-15s %-15s %-5s %-6u %s', [AddressToText(InterfaceAddressHost(Route.Destination)),
      AddressToText(RouteGateway(Route)), NetmaskToText(Route.Destination.PrefixLength), RouteFlagsToText(Route),
      Route.Metric, InterfaceNameToText(Route.InterfaceName)]));
  end;
end;

procedure ShowRoutes;
var
  Routes: TRouteList;
  Error: LongInt;
begin
  Error := ListRoutes(Routes);
  if Error <> ErrorNone then
    FailWithError(1, Error, 'cannot read the routing table');
  SortRoutes(Routes);
  if Family = AddressFamilyIPv6 then
    ShowIpv6Routes(Routes)
  else
    ShowIpv4Routes(Routes);
end;

function ParseTarget(const Text: string; var Request: TRouteRequest): Boolean;
begin
  if Text = 'default' then
  begin
    if Family = AddressFamilyIPv6 then
      Request.Destination := AnyIpv6Address
    else
      Request.Destination := AnyIpv4Address;
    Request.PrefixLength := 0;
    Request.HasPrefix := True;
    Exit(True);
  end;
  Result := TextToAddressWithPrefix(Text, Request.Destination, Request.PrefixLength, Request.HasPrefix);
  { An IPv6 target makes an IPv6 route. }
  if Result and (Request.Destination.Family = AddressFamilyIPv6) then
  begin
    Family := AddressFamilyIPv6;
    Request.Gateway := AnyIpv6Address;
  end;
end;

function ValueAfter(const Operands: TStringArray; var Index: Integer): string;
begin
  if Index + 1 >= Length(Operands) then
    FailWithUsageHint(Format('''%s'' needs a value', [Operands[Index]]));
  Inc(Index);
  Result := Operands[Index];
end;

procedure ApplySetting(const Setting, Value: string; var Request: TRouteRequest);
var
  Number: QWord;
begin
  if Setting = 'gw' then
  begin
    if not TextToAddress(Value, Request.Gateway) or (Request.Gateway.Family <> Family) then
      Fail(1, Format('%s: bad address', [Value]));
  end
  else if Setting = 'dev' then
    Request.InterfaceName := Value
  else if Setting = 'netmask' then
  begin
    if not TextToNetmask(Value, Request.PrefixLength) then
      Fail(1, Format('%s: bad netmask', [Value]));
    Request.HasPrefix := True;
  end
  else if Setting = 'metric' then
  begin
    if not ParseUnsignedDecimal(Value, Number) or (Number > High(LongWord)) then
      Fail(1, Format('%s: bad metric', [Value]));
    Request.Metric := LongWord(Number);
  end
  else
    FailWithUsageHint(Format('unknown setting ''%s''', [Setting]));
end;

procedure ParseRequest(const Operands: TStringArray; out Request: TRouteRequest);
var
  Index: Integer;
  Setting: string;
  Value: string;
begin
  Request := Default(TRouteRequest);
  Request.Destination := AnyIpv4Address;
  Request.PrefixLength := 32;
  Request.Gateway := AnyIpv4Address;
  if Family = AddressFamilyIPv6 then
    Request.Gateway := AnyIpv6Address;
  Index := 1;
  while (Index < Length(Operands)) and ((Operands[Index] = '-net') or (Operands[Index] = '-host')) do
  begin
    if Operands[Index] = '-host' then
      HostRoute := True;
    Inc(Index);
  end;
  if Index >= Length(Operands) then
    FailWithUsageHint('missing route target');
  if not ParseTarget(Operands[Index], Request) then
    Fail(1, Format('%s: bad address', [Operands[Index]]));
  Inc(Index);
  while Index < Length(Operands) do
  begin
    Setting := Operands[Index];
    Value := ValueAfter(Operands, Index);
    ApplySetting(Setting, Value, Request);
    Inc(Index);
  end;
  if HostRoute and (Family = AddressFamilyIPv6) then
    Request.PrefixLength := 128
  else if HostRoute then
    Request.PrefixLength := 32
  else if not Request.HasPrefix and (Family = AddressFamilyIPv6) then
    Request.PrefixLength := 128;
end;

procedure ChangeRoute(const Operands: TStringArray);
var
  Request: TRouteRequest;
  Error: LongInt;
begin
  ParseRequest(Operands, Request);
  if Operands[0] = 'add' then
  begin
    if AddressIsUnspecified(Request.Gateway) and (Request.InterfaceName = '') then
      Fail(1, 'a route needs a gateway (gw) or an interface (dev)');
    Error := AddRoute(Request.Destination, Request.PrefixLength, Request.Gateway, PChar(Request.InterfaceName),
      Request.Metric);
  end
  else
    Error := RemoveRoute(Request.Destination, Request.PrefixLength, Request.Gateway);
  if Error = ErrorNotFound then
    Fail(1, 'no such route');
  if Error <> ErrorNone then
    FailWithError(1, Error, Format('cannot %s the route', [Operands[0]]));
end;

var
  CommandLine: TCommandLine;
  Code: Integer;
  Value: string;

begin
  CommandLine := TCommandLine.Create([
    CommandOption('n', 'numeric', False, OptionNumeric),
    CommandOption('4', '', False, OptionIpv4),
    CommandOption('6', '', False, OptionIpv6),
    CommandOption('A', '', True, OptionFamily)], Usage);
  { "route add -net ...": what follows the command is its own. }
  CommandLine.StopAtFirstOperand := True;
  while CommandLine.NextOption(Code, Value) do
    case Code of
      OptionIpv4: Family := AddressFamilyIPv4;
      OptionIpv6: Family := AddressFamilyIPv6;
      OptionFamily:
        if Value = 'inet6' then
          Family := AddressFamilyIPv6
        else if Value = 'inet' then
          Family := AddressFamilyIPv4
        else
          FailWithUsageHint(Format('unknown address family %s', [Value]));
    end;
  if CommandLine.OperandCount = 0 then
    ShowRoutes
  else if (CommandLine.Operands[0] = 'add') or (CommandLine.Operands[0] = 'del') then
    ChangeRoute(CommandLine.Operands)
  else
    FailWithUsageHint(Format('unknown command ''%s''', [CommandLine.Operands[0]]));
end.
