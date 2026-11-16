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

  route [-n]
  route add|del default|[-net|-host] TARGET[/PREFIX] [netmask MASK] [gw GATEWAY] [dev INTERFACE] [metric N]

  Shows the routing table in the manner of net-tools' route -n (it is
  always numeric): the default route first, then the networks in
  order. "add" and "del" change it (root only): "default" is
  0.0.0.0/0, -host a single address (/32), -net a network given with a
  prefix or a netmask. A route through a gateway leaves by the
  interface that reaches the gateway, unless "dev" names one.
}
program route;

{$mode objfpc}
{$pointermath on}

uses
  Abi.SystemCalls,
  Runtime.Text,
  Sys.Errors,
  Sys.Format,
  Sys.InternetAddresses,
  Sys.NetworkInterfaces,
  Sys.Streams,
  Sys.Text,
  Util.Messages,
  Util.Options;

const
  Usage: PChar = 'Usage: route [-n]'#10 +
    '  or:  route add|del default|[-net|-host] TARGET[/PREFIX] [netmask MASK] [gw GATEWAY]'#10 +
    '                    [dev INTERFACE] [metric N]'#10 +
    'Show the routing table, or add or remove a route (root only).'#10 +
    #10 +
    '  -n, --numeric   numeric addresses (always)'#10;

  OptionNumeric = 1;

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
  WriteLine(StandardOutput, 'Kernel IP routing table');
  WriteLine(StandardOutput, 'Destination     Gateway         Genmask         Flags Metric Iface');
  for Index := 0 to High(Routes) do
  begin
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
    Request.Destination := AnyIpv4Address;
    Request.PrefixLength := 0;
    Request.HasPrefix := True;
    Exit(True);
  end;
  Result := ParseAddressWithPrefix(Text, Request.Destination, Request.PrefixLength, Request.HasPrefix);
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
      if not ParseIpv4Address(Value, Request.Gateway) then
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
  if HostRoute then
    Request.PrefixLength := 32;
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
    OptionDefinition('n', 'numeric', False, OptionNumeric)], Usage);
  { "route add -net ...": what follows the command is its own. }
  Parser.StopAtFirstOperand := True;
  while NextOption(Parser, Code, Value) do
    ;
  if Parser.OperandCount = 0 then
    ShowRoutes
  else if TextIsEqual(Parser.Operands[0], 'add') or TextIsEqual(Parser.Operands[0], 'del') then
    ChangeRoute(Parser.Operands, Parser.OperandCount)
  else
    FailWithUsageHint('unknown command ''%s''', [ArgumentText(Parser.Operands[0])]);
  FlushStream(StandardOutput);
end.
