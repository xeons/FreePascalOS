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
  Sys.InterfaceText,
  Util.CommandLine,
  Util.Messages,
  Sys.Streams;

const
  Usage ='Usage: ndp [-a] [-n] [-i INTERFACE] [ADDRESS]'#10 +
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
begin
  if Entry.State = NeighborStateIncomplete then
    Exit('(incomplete)');
  Result := HardwareAddressToText(Entry.HardwareAddress, EthernetAddressBytes);
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
    InterfaceNameToText(Entry.InterfaceName), Entry.ExpiresInSeconds, StateName(Entry.State), FlagsText(Entry)]);
  PrintStringLine(TrimRight(Line));
end;

var
  CommandLine: TCommandLine;
  Code: Integer;
  Value: string;
  InterfaceName: string = '';
  Wanted: TInternetAddress;
  HasWanted: Boolean = False;
  Entries: TNeighborEntryList;
  Entry: TAbiNeighborEntry;
  Error: LongInt;
  Shown: Integer = 0;

begin
  CommandLine := TCommandLine.Create([
    CommandOption('a', 'all', False, OptionAll),
    CommandOption('n', 'numeric', False, OptionNumeric),
    CommandOption('i', 'device', True, OptionInterface)], Usage);
  while CommandLine.NextOption(Code, Value) do
    if Code = OptionInterface then
      InterfaceName := Value;
  if CommandLine.OperandCount > 1 then
    FailWithUsageHint(Format('extra operand ''%s''', [CommandLine.Operands[1]]));
  if CommandLine.OperandCount = 1 then
  begin
    if not TextToAddress(CommandLine.Operands[0], Wanted) or (Wanted.Family <> AddressFamilyIPv6) then
      Fail(1, Format('%s: Unknown host', [CommandLine.Operands[0]]));
    HasWanted := True;
  end;
  Error := ListNeighbors(Entries);
  if Error <> ErrorNone then
    FailWithError(1, Error, 'cannot read the neighbour cache');
  PrintStringLine('Neighbor                                Linklayer Address  Netif      Expire  State      Flags');
  for Entry in Entries do
  begin
    if HasWanted and not AddressesAreEqual(NeighborAddress(Entry), Wanted) then
      Continue;
    if (InterfaceName <> '') and (InterfaceNameToText(Entry.InterfaceName) <> InterfaceName) then
      Continue;
    ShowEntry(Entry);
    Inc(Shown);
  end;
  if HasWanted and (Shown = 0) then
    Fail(1, Format('%s: no entry', [CommandLine.Operands[0]]));
end.
