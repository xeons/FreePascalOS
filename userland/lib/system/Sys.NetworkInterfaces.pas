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
  connection, and the DNS servers. Anyone may list; only root may
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

function ListNetworkInterfaces(out Interfaces: TNetworkInterfaceList): LongInt;
{ False if there is no interface Name. }
function FindNetworkInterface(Name: PChar; out Description: TAbiNetworkInterface): Boolean;
function SetInterfaceAddress(Name: PChar; constref Address: TInternetAddress; PrefixLength: LongWord): LongInt;
function RemoveInterfaceAddress(Name: PChar): LongInt;
function SetInterfaceUp(Name: PChar; Up: Boolean): LongInt;
function SetInterfaceMtu(Name: PChar; Mtu: LongWord): LongInt;

function ListRoutes(out Routes: TRouteList): LongInt;
{ Gateway 0.0.0.0: on the link of InterfaceName. InterfaceName nil or
  empty: the interface that reaches the gateway. }
function AddRoute(constref Destination: TInternetAddress; PrefixLength: LongWord;
  constref Gateway: TInternetAddress; InterfaceName: PChar; Metric: LongWord): LongInt;
{ Gateway 0.0.0.0: whatever the route's gateway. }
function RemoveRoute(constref Destination: TInternetAddress; PrefixLength: LongWord;
  constref Gateway: TInternetAddress): LongInt;

function ListArpEntries(out Entries: TArpEntryList): LongInt;
function ListSockets(out Entries: TSocketInformationList): LongInt;
function GetDnsServers(out Servers: TAbiDnsServers): LongInt;
function SetDnsServers(constref Servers: TAbiDnsServers): LongInt;

{ "52:54:00:12:34:56". }
function FormatHardwareAddress(Bytes: PByte; Length: LongWord; Buffer: PChar; Capacity: PtrUInt): PChar;
{ "UP,BROADCAST,RUNNING" (as ifconfig shows them). }
function FormatInterfaceFlags(Flags: LongWord; Buffer: PChar; Capacity: PtrUInt): PChar;

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

function FormatHardwareAddress(Bytes: PByte; Length: LongWord; Buffer: PChar; Capacity: PtrUInt): PChar;
const
  Digits: PChar = '0123456789abcdef';
var
  Text: array[0..3 * HardwareAddressCapacity] of Char;
  Index: LongWord;
  Position: Integer;
begin
  Position := 0;
  Index := 0;
  while (Index < Length) and (Index < HardwareAddressCapacity) do
  begin
    if Index > 0 then
    begin
      Text[Position] := ':';
      Inc(Position);
    end;
    Text[Position] := Digits[Bytes[Index] shr 4];
    Text[Position + 1] := Digits[Bytes[Index] and $0F];
    Position := Position + 2;
    Inc(Index);
  end;
  Text[Position] := #0;
  Result := Buffer;
  CopyText(Buffer, @Text[0], Capacity);
end;

procedure AppendFlag(Text: PChar; Capacity: PtrUInt; Name: PChar);
var
  Length: PtrUInt;
begin
  Length := TextLength(Text);
  if Length > 0 then
  begin
    CopyText(Text + Length, ',', Capacity - Length);
    Inc(Length);
  end;
  CopyText(Text + Length, Name, Capacity - Length);
end;

function FormatInterfaceFlags(Flags: LongWord; Buffer: PChar; Capacity: PtrUInt): PChar;
var
  Text: array[0..63] of Char;
begin
  Text[0] := #0;
  if (Flags and InterfaceFlagUp) <> 0 then
    AppendFlag(@Text[0], SizeOf(Text), 'UP');
  if (Flags and InterfaceFlagBroadcast) <> 0 then
    AppendFlag(@Text[0], SizeOf(Text), 'BROADCAST');
  if (Flags and InterfaceFlagLoopback) <> 0 then
    AppendFlag(@Text[0], SizeOf(Text), 'LOOPBACK');
  if (Flags and InterfaceFlagRunning) <> 0 then
    AppendFlag(@Text[0], SizeOf(Text), 'RUNNING');
  Result := Buffer;
  CopyText(Buffer, @Text[0], Capacity);
end;

end.
