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
  Network interfaces and routes as strings, for programs that work with
  strings rather than character buffers: an interface's name, its
  hardware address and flags, and a route's flags (the same text as
  the formatting routines of Sys.NetworkInterfaces).
}
unit Sys.InterfaceText;

{$mode objfpc}
{$H+}

interface

uses
  Abi.SystemCalls;

{ The text of a name field of the kernel's records (an interface's
  name, a route's interface): up to its terminator. }
function InterfaceNameToText(const Name: array of Char): string;
{ "52:54:00:12:34:56": the first Length bytes. }
function HardwareAddressToText(const Bytes: array of Byte; Length: LongWord): string;
{ "UP,BROADCAST,RUNNING" (as ifconfig shows them). }
function InterfaceFlagsToText(Flags: LongWord): string;
{ "UG", "U", "UH" ... as route -n shows the flags. }
function RouteFlagsToText(constref Route: TAbiRoute): string;

implementation

uses
  SysUtils;

function InterfaceNameToText(const Name: array of Char): string;
var
  Count: Integer;
begin
  Count := 0;
  while (Count < System.Length(Name)) and (Name[Count] <> #0) do
    Inc(Count);
  SetString(Result, PChar(@Name[0]), Count);
end;

function HardwareAddressToText(const Bytes: array of Byte; Length: LongWord): string;
var
  Index: Integer;
begin
  Result := '';
  for Index := 0 to Integer(Length) - 1 do
  begin
    if Index > High(Bytes) then
      Break;
    if Index > 0 then
      Result := Result + ':';
    Result := Result + LowerCase(IntToHex(Bytes[Index], 2));
  end;
end;

procedure AppendFlag(var Text: string; const Name: string);
begin
  if Text <> '' then
    Text := Text + ',';
  Text := Text + Name;
end;

function InterfaceFlagsToText(Flags: LongWord): string;
begin
  Result := '';
  if (Flags and InterfaceFlagUp) <> 0 then
    AppendFlag(Result, 'UP');
  if (Flags and InterfaceFlagBroadcast) <> 0 then
    AppendFlag(Result, 'BROADCAST');
  if (Flags and InterfaceFlagLoopback) <> 0 then
    AppendFlag(Result, 'LOOPBACK');
  if (Flags and InterfaceFlagRunning) <> 0 then
    AppendFlag(Result, 'RUNNING');
end;

function IsHostRoute(constref Route: TAbiRoute): Boolean;
begin
  Result := ((Route.Destination.Family = AddressFamilyIPv4) and (Route.Destination.PrefixLength = 32)) or
    ((Route.Destination.Family = AddressFamilyIPv6) and (Route.Destination.PrefixLength = 128));
end;

function RouteFlagsToText(constref Route: TAbiRoute): string;
begin
  Result := '';
  if (Route.Flags and RouteFlagUp) <> 0 then
    Result := Result + 'U';
  if (Route.Flags and RouteFlagGateway) <> 0 then
    Result := Result + 'G';
  if IsHostRoute(Route) then
    Result := Result + 'H';
  if (Route.Flags and RouteFlagAutomatic) <> 0 then
    Result := Result + 'A';
end;

end.
