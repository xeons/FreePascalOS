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
  ndp - show IPv6's neighbour cache

  ndp [-a] [-n] [-i INTERFACE] [ADDRESS]

  IPv6's arp: shows the neighbours whose Ethernet addresses Neighbor
  Discovery found (or is asking for: "(incomplete)"), with their
  interface, how long the entry has before it changes, its state
  (INCOMPLETE, REACHABLE, STALE, PROBE) and R for a router, in the
  manner of BSD's ndp -a (always numeric). -i shows one interface's,
  ADDRESS one neighbour.
}
program ndp;

{$mode objfpc}
{$H+}

uses
  SysUtils,
  Abi.SystemCalls,
  Sys.InternetAddresses,
  Sys.NetworkInterfaces,
  Sys.AddressText,
  Sys.Streams,
  Sys.Format,
  Util.Messages,
  Util.Options;

const
  Usage: PChar = 'Usage: ndp [-a] [-n] [-i INTERFACE] [ADDRESS]'#10 +
    'Show the IPv6 neighbour cache: the Ethernet addresses of the neighbours.'#10 +
    #10 +
    '  -a, --all              every neighbour (the default)'#10 +
    '  -n, --numeric          numeric addresses (always)'#10 +
    '  -i, --device=INTERFACE only the neighbours on INTERFACE'#10;

  OptionAll = 1;
  OptionNumeric = 2;
  OptionInterface = 3;
  EthernetAddressBytes = 6;

function NeighborAddress(constref Entry: TAbiNeighborEntry): TInternetAddress;
begin
  Result := AnyIpv6Address;
  Move(Entry.Address[0], Result.Bytes[0], 16);
end;

function StateName(State: LongWord): string;
begin
  case State of
    NeighborStateIncomplete: Result := 'INCOMPLETE';
    NeighborStateReachable: Result := 'REACHABLE';
    NeighborStateStale: Result := 'STALE';
    NeighborStateProbe: Result := 'PROBE';
  else
    Result := '?';
  end;
end;

function LinkLayerText(constref Entry: TAbiNeighborEntry): string;
var
  Buffer: array[0..31] of Char;
begin
  if Entry.State = NeighborStateIncomplete then
    Exit('(incomplete)');
  Result := StrPas(FormatHardwareAddress(@Entry.HardwareAddress[0], EthernetAddressBytes, @Buffer[0],
    SizeOf(Buffer)));
end;

function FlagsText(constref Entry: TAbiNeighborEntry): string;
begin
  Result := '';
  if (Entry.Flags and NeighborFlagRouter) <> 0 then
    Result := 'R';
end;

procedure ShowEntry(constref Entry: TAbiNeighborEntry);
var
  Line: string;
begin
  Line := Format('%-40s %-18s %-9s %6us  %-10s %s', [AddressToText(NeighborAddress(Entry)), LinkLayerText(Entry),
    StrPas(PChar(@Entry.InterfaceName[0])), Entry.ExpiresInSeconds, StateName(Entry.State), FlagsText(Entry)]);
  WriteLine(StandardOutput, PChar(TrimRight(Line)));
end;

var
  Parser: TOptionParser;
  Code: Integer;
  Value: PChar;
  InterfaceName: string = '';
  Wanted: TInternetAddress;
  HasWanted: Boolean = False;
  Entries: TNeighborEntryList;
  Entry: TAbiNeighborEntry;
  Error: LongInt;
  Shown: Integer = 0;

begin
  BeginOptions(Parser, [
    OptionDefinition('a', 'all', False, OptionAll),
    OptionDefinition('n', 'numeric', False, OptionNumeric),
    OptionDefinition('i', 'device', True, OptionInterface)], Usage);
  while NextOption(Parser, Code, Value) do
    if Code = OptionInterface then
      InterfaceName := Value;
  if Parser.OperandCount > 1 then
    FailWithUsageHint('extra operand ''%s''', [ArgumentText(Parser.Operands[1])]);
  if Parser.OperandCount = 1 then
  begin
    if not TextToAddress(Parser.Operands[0], Wanted) or (Wanted.Family <> AddressFamilyIPv6) then
      Fail(1, '%s: Unknown host', [ArgumentText(Parser.Operands[0])]);
    HasWanted := True;
  end;
  Error := ListNeighbors(Entries);
  if Error <> ErrorNone then
    FailWithError(1, Error, 'cannot read the neighbour cache', []);
  WriteLine(StandardOutput, 'Neighbor                                 Linklayer Address  Netif      Expire  State      Flags');
  for Entry in Entries do
  begin
    if HasWanted and not AddressesAreEqual(NeighborAddress(Entry), Wanted) then
      Continue;
    if (InterfaceName <> '') and (StrPas(PChar(@Entry.InterfaceName[0])) <> InterfaceName) then
      Continue;
    ShowEntry(Entry);
    Inc(Shown);
  end;
  FlushStream(StandardOutput);
  if HasWanted and (Shown = 0) then
    Fail(1, '%s: no entry', [ArgumentText(Parser.Operands[0])]);
end.
