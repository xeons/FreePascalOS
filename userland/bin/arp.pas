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
  arp - show the ARP cache

  arp [-n] [-i INTERFACE] [ADDRESS]

  Shows the neighbours whose Ethernet addresses the kernel knows (or is
  asking for: "(incomplete)"), with their interface and how long the
  entry is kept, in the manner of net-tools' arp -n (always numeric).
  -i shows one interface's, ADDRESS one neighbour.
}
program arp;

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
  Util.Output;

const
  Usage = 'Usage: arp [-n] [-i INTERFACE] [ADDRESS]'#10 +
    'Show the ARP cache: the Ethernet addresses of the neighbours.'#10 +
    #10 +
    '  -n, --numeric          numeric addresses (always)'#10 +
    '  -i, --device=INTERFACE only the neighbours on INTERFACE'#10;

  OptionNumeric = 1;
  OptionInterface = 2;
  EthernetAddressBytes = 6;

function EntryAddress(constref Entry: TAbiArpEntry): TInternetAddress;
begin
  Result := AnyIpv4Address;
  Move(Entry.Address[0], Result.Bytes[0], 4);
end;

procedure ShowEntry(constref Entry: TAbiArpEntry);
var
  AddressText: string;
  InterfaceName: string;
begin
  AddressText := AddressToText(EntryAddress(Entry));
  InterfaceName := InterfaceNameToText(Entry.InterfaceName);
  if Entry.State = ArpStateReachable then
    PrintStringLine(Format('%-16s ether   %-18s %-9s %us', [AddressText,
      HardwareAddressToText(Entry.HardwareAddress, EthernetAddressBytes), InterfaceName,
      Entry.ExpiresInSeconds]))
  else
    PrintStringLine(Format('%-16s         %-18s %s', [AddressText, '(incomplete)', InterfaceName]));
end;

var
  CommandLine: TCommandLine;
  Code: Integer;
  Value: string;
  InterfaceName: string = '';
  Wanted: TInternetAddress;
  HasWanted: Boolean = False;
  Entries: TArpEntryList;
  Entry: TAbiArpEntry;
  Error: LongInt;
  Shown: Integer = 0;

begin
  CommandLine := TCommandLine.Create([
    CommandOption('n', 'numeric', False, OptionNumeric),
    CommandOption('i', 'device', True, OptionInterface)], Usage);
  while CommandLine.NextOption(Code, Value) do
    if Code = OptionInterface then
      InterfaceName := Value;
  if CommandLine.OperandCount > 1 then
    FailWithUsageHint(Format('extra operand ''%s''', [CommandLine.Operands[1]]));
  if CommandLine.OperandCount = 1 then
  begin
    if not TextToIpv4Address(CommandLine.Operands[0], Wanted) then
      Fail(1, Format('%s: Unknown host', [CommandLine.Operands[0]]));
    HasWanted := True;
  end;
  Error := ListArpEntries(Entries);
  if Error <> ErrorNone then
    FailWithError(1, Error, 'cannot read the ARP cache');
  PrintStringLine('Address          HWtype  HWaddress          Iface     Expires');
  for Entry in Entries do
  begin
    if HasWanted and not AddressesAreEqual(EntryAddress(Entry), Wanted) then
      Continue;
    if (InterfaceName <> '') and (InterfaceNameToText(Entry.InterfaceName) <> InterfaceName) then
      Continue;
    ShowEntry(Entry);
    Inc(Shown);
  end;
  if HasWanted and (Shown = 0) then
    Fail(1, Format('%s: no entry', [CommandLine.Operands[0]]));
end.
