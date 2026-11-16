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
{$pointermath on}

uses
  Abi.SystemCalls,
  Runtime.Text,
  Sys.Errors,
  Sys.Format,
  Sys.InternetAddresses,
  Sys.NetworkInterfaces,
  Sys.Streams,
  Util.Messages,
  Util.Options;

const
  Usage: PChar = 'Usage: arp [-n] [-i INTERFACE] [ADDRESS]'#10 +
    'Show the ARP cache: the Ethernet addresses of the neighbours.'#10 +
    #10 +
    '  -n, --numeric          numeric addresses (always)'#10 +
    '  -i, --device=INTERFACE only the neighbours on INTERFACE'#10;

  OptionNumeric = 1;
  OptionInterface = 2;
  EthernetAddressBytes = 6;

var
  Parser: TOptionParser;
  Code: Integer;
  Value: PChar;
  InterfaceName: PChar = nil;
  Wanted: TInternetAddress;
  HasWanted: Boolean = False;
  Entries: TArpEntryList;
  Index: Integer;
  Error: LongInt;
  Address: TInternetAddress;
  AddressText: array[0..Ipv4AddressTextCapacity - 1] of Char;
  HardwareText: array[0..31] of Char;
  Shown: Integer = 0;

begin
  BeginOptions(Parser, [
    OptionDefinition('n', 'numeric', False, OptionNumeric),
    OptionDefinition('i', 'device', True, OptionInterface)], Usage);
  while NextOption(Parser, Code, Value) do
    if Code = OptionInterface then
      InterfaceName := Value;
  if Parser.OperandCount > 1 then
    FailWithUsageHint('extra operand ''%s''', [ArgumentText(Parser.Operands[1])]);
  if Parser.OperandCount = 1 then
  begin
    if not ParseIpv4Address(Parser.Operands[0], Wanted) then
      Fail(1, '%s: Unknown host', [ArgumentText(Parser.Operands[0])]);
    HasWanted := True;
  end;
  Error := ListArpEntries(Entries);
  if Error <> ErrorNone then
    FailWithError(1, Error, 'cannot read the ARP cache', []);
  WriteLine(StandardOutput, 'Address          HWtype  HWaddress          Iface     Expires');
  for Index := 0 to High(Entries) do
  begin
    Address := AnyIpv4Address;
    Move(Entries[Index].Address[0], Address.Bytes[0], 4);
    if HasWanted and not AddressesAreEqual(Address, Wanted) then
      Continue;
    if (InterfaceName <> nil) and not TextIsEqual(@Entries[Index].InterfaceName[0], InterfaceName) then
      Continue;
    FormatInternetAddress(Address, @AddressText[0], SizeOf(AddressText));
    if Entries[Index].State = ArpStateReachable then
    begin
      FormatHardwareAddress(@Entries[Index].HardwareAddress[0], EthernetAddressBytes, @HardwareText[0],
        SizeOf(HardwareText));
      WriteFormatted(StandardOutput, '%-16s ether   %-18s %-9s %us'#10, [ArgumentText(@AddressText[0]),
        ArgumentText(@HardwareText[0]), ArgumentText(@Entries[Index].InterfaceName[0]),
        ArgumentUnsigned(Entries[Index].ExpiresInSeconds)]);
    end
    else
      WriteFormatted(StandardOutput, '%-16s         %-18s %s'#10, [ArgumentText(@AddressText[0]),
        ArgumentText('(incomplete)'), ArgumentText(@Entries[Index].InterfaceName[0])]);
    Inc(Shown);
  end;
  FlushStream(StandardOutput);
  if HasWanted and (Shown = 0) then
    Fail(1, '%s: no entry', [ArgumentText(Parser.Operands[0])]);
end.
