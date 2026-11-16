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
  ifconfig - show and configure network interfaces

  ifconfig [-a] [-s] [INTERFACE]
  ifconfig INTERFACE [ADDRESS[/PREFIX]] [netmask MASK] [mtu N] [up|down]

  Without arguments (or with -a) shows every interface: its state, MTU,
  address, netmask and broadcast address, hardware address and what
  went through it, in the manner of net-tools' ifconfig; -s a table of
  the counters. With an interface and settings, changes it (root
  only): an address with a prefix or a netmask (0.0.0.0 removes the
  address), the MTU, and turning it on or off, in the order given.
}
program ifconfig;

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
  Usage: PChar = 'Usage: ifconfig [-a] [-s] [INTERFACE]'#10 +
    '  or:  ifconfig INTERFACE [ADDRESS[/PREFIX]] [netmask MASK] [mtu N] [up|down]'#10 +
    'Show the network interfaces, or configure one (root only).'#10 +
    #10 +
    '  -a, --all     show every interface (the default)'#10 +
    '  -s, --short   a table of the counters'#10;

  OptionAll = 1;
  OptionShort = 2;

var
  ShortListing: Boolean = False;

procedure ShowCounters(constref Description: TAbiNetworkInterface);
begin
  WriteFormatted(StandardOutput, '        RX packets %u  bytes %u'#10, [
    ArgumentUnsigned(Description.Counters.ReceivedPackets), ArgumentUnsigned(Description.Counters.ReceivedBytes)]);
  WriteFormatted(StandardOutput, '        RX errors %u  dropped %u'#10, [
    ArgumentUnsigned(Description.Counters.ReceiveErrors), ArgumentUnsigned(Description.Counters.ReceiveDrops)]);
  WriteFormatted(StandardOutput, '        TX packets %u  bytes %u'#10, [
    ArgumentUnsigned(Description.Counters.SentPackets), ArgumentUnsigned(Description.Counters.SentBytes)]);
  WriteFormatted(StandardOutput, '        TX errors %u  dropped %u'#10, [
    ArgumentUnsigned(Description.Counters.SendErrors), ArgumentUnsigned(Description.Counters.SendDrops)]);
end;

procedure ShowAddress(constref Description: TAbiNetworkInterface; Index: LongWord);
var
  Address: TInternetAddress;
  PrefixLength: LongWord;
  AddressText: array[0..Ipv4AddressTextCapacity - 1] of Char;
  MaskText: array[0..Ipv4AddressTextCapacity - 1] of Char;
  BroadcastText: array[0..Ipv4AddressTextCapacity - 1] of Char;
  Mask: LongWord;
begin
  Address := InterfaceAddressHost(Description.Addresses[Index]);
  PrefixLength := Description.Addresses[Index].PrefixLength;
  FormatInternetAddress(Address, @AddressText[0], SizeOf(AddressText));
  FormatNetmask(PrefixLength, @MaskText[0], SizeOf(MaskText));
  WriteFormatted(StandardOutput, '        inet %s  netmask %s', [ArgumentText(@AddressText[0]),
    ArgumentText(@MaskText[0])]);
  if ((Description.Flags and InterfaceFlagBroadcast) <> 0) and (PrefixLength < 31) then
  begin
    Mask := 0;
    if PrefixLength > 0 then
      Mask := LongWord($FFFFFFFF shl (32 - PrefixLength));
    FormatInternetAddress(Ipv4AddressFromValue(Ipv4AddressValue(Address) or not Mask), @BroadcastText[0],
      SizeOf(BroadcastText));
    WriteFormatted(StandardOutput, '  broadcast %s', [ArgumentText(@BroadcastText[0])]);
  end;
  WriteCharacter(StandardOutput, #10);
end;

procedure ShowInterface(constref Description: TAbiNetworkInterface);
var
  FlagsText: array[0..63] of Char;
  HardwareText: array[0..31] of Char;
  Index: LongWord;
begin
  FormatInterfaceFlags(Description.Flags, @FlagsText[0], SizeOf(FlagsText));
  WriteFormatted(StandardOutput, '%s: flags=<%s>  mtu %u'#10, [ArgumentText(@Description.Name[0]),
    ArgumentText(@FlagsText[0]), ArgumentUnsigned(Description.Mtu)]);
  Index := 0;
  while Index < Description.AddressCount do
  begin
    ShowAddress(Description, Index);
    Inc(Index);
  end;
  if (Description.Flags and InterfaceFlagLoopback) <> 0 then
    WriteLine(StandardOutput, '        loop')
  else
  begin
    FormatHardwareAddress(@Description.HardwareAddress[0], Description.HardwareAddressLength, @HardwareText[0],
      SizeOf(HardwareText));
    WriteFormatted(StandardOutput, '        ether %s  (%s)'#10, [ArgumentText(@HardwareText[0]),
      ArgumentText(@Description.Description[0])]);
  end;
  ShowCounters(Description);
  WriteCharacter(StandardOutput, #10);
end;

procedure ShowShortHeading;
begin
  WriteLine(StandardOutput, 'Iface      MTU    RX-OK RX-ERR RX-DRP    TX-OK TX-ERR TX-DRP Flg');
end;

procedure ShowShortLine(constref Description: TAbiNetworkInterface);
var
  Flags: array[0..7] of Char;
  Length: Integer;
begin
  Length := 0;
  if (Description.Flags and InterfaceFlagBroadcast) <> 0 then
  begin
    Flags[Length] := 'B';
    Inc(Length);
  end;
  if (Description.Flags and InterfaceFlagLoopback) <> 0 then
  begin
    Flags[Length] := 'L';
    Inc(Length);
  end;
  if (Description.Flags and InterfaceFlagRunning) <> 0 then
  begin
    Flags[Length] := 'R';
    Inc(Length);
  end;
  if (Description.Flags and InterfaceFlagUp) <> 0 then
  begin
    Flags[Length] := 'U';
    Inc(Length);
  end;
  Flags[Length] := #0;
  WriteFormatted(StandardOutput, '%-8s %5u %8u %6u %6u %8u %6u %6u %s'#10, [
    ArgumentText(@Description.Name[0]), ArgumentUnsigned(Description.Mtu),
    ArgumentUnsigned(Description.Counters.ReceivedPackets), ArgumentUnsigned(Description.Counters.ReceiveErrors),
    ArgumentUnsigned(Description.Counters.ReceiveDrops), ArgumentUnsigned(Description.Counters.SentPackets),
    ArgumentUnsigned(Description.Counters.SendErrors), ArgumentUnsigned(Description.Counters.SendDrops),
    ArgumentText(@Flags[0])]);
end;

procedure Show(Name: PChar);
var
  Interfaces: TNetworkInterfaceList;
  Index: Integer;
  Found: Boolean;
  Error: LongInt;
begin
  Error := ListNetworkInterfaces(Interfaces);
  if Error <> ErrorNone then
    FailWithError(1, Error, 'cannot list the interfaces', []);
  if ShortListing then
    ShowShortHeading;
  Found := False;
  for Index := 0 to High(Interfaces) do
  begin
    if (Name <> nil) and not TextIsEqual(@Interfaces[Index].Name[0], Name) then
      Continue;
    Found := True;
    if ShortListing then
      ShowShortLine(Interfaces[Index])
    else
      ShowInterface(Interfaces[Index]);
  end;
  if (Name <> nil) and not Found then
    Fail(1, '%s: error fetching interface information: Device not found', [ArgumentText(Name)]);
end;

procedure CheckChange(Name: PChar; Error: LongInt);
begin
  if Error <> ErrorNone then
    FailWithError(1, Error, '%s', [ArgumentText(Name)]);
end;

{ Applies the settings in the operands after the interface's name. }
procedure Configure(const Operands: PPChar; Count: Integer);
var
  Name: PChar;
  Index: Integer;
  Setting: PChar;
  Address: TInternetAddress;
  PrefixLength: LongWord;
  HasPrefix: Boolean;
  Mtu: QWord;
  Description: TAbiNetworkInterface;
begin
  Name := Operands[0];
  if not FindNetworkInterface(Name, Description) then
    Fail(1, '%s: error fetching interface information: Device not found', [ArgumentText(Name)]);
  Index := 1;
  while Index < Count do
  begin
    Setting := Operands[Index];
    if TextIsEqual(Setting, 'up') then
      CheckChange(Name, SetInterfaceUp(Name, True))
    else if TextIsEqual(Setting, 'down') then
      CheckChange(Name, SetInterfaceUp(Name, False))
    else if TextIsEqual(Setting, 'mtu') or TextIsEqual(Setting, 'netmask') then
    begin
      if Index + 1 >= Count then
        FailWithUsageHint('''%s'' needs a value', [ArgumentText(Setting)]);
      Inc(Index);
      if TextIsEqual(Setting, 'mtu') then
      begin
        if not ParseUnsigned(Operands[Index], Mtu) or (Mtu > High(LongWord)) then
          Fail(1, 'invalid MTU ''%s''', [ArgumentText(Operands[Index])]);
        CheckChange(Name, SetInterfaceMtu(Name, LongWord(Mtu)));
      end
      else
      begin
        if not ParseNetmask(Operands[Index], PrefixLength) then
          Fail(1, 'invalid netmask ''%s''', [ArgumentText(Operands[Index])]);
        if not FindNetworkInterface(Name, Description) or (Description.AddressCount = 0) then
          Fail(1, '%s: no address to apply the netmask to', [ArgumentText(Name)]);
        CheckChange(Name, SetInterfaceAddress(Name, InterfaceAddressHost(Description.Addresses[0]), PrefixLength));
      end;
    end
    else if ParseAddressWithPrefix(Setting, Address, PrefixLength, HasPrefix) then
    begin
      if AddressIsUnspecified(Address) then
        CheckChange(Name, RemoveInterfaceAddress(Name))
      else
      begin
        { Without a prefix: the class's, as ifconfig always did. }
        if not HasPrefix then
        begin
          if Address.Bytes[0] < 128 then
            PrefixLength := 8
          else if Address.Bytes[0] < 192 then
            PrefixLength := 16
          else
            PrefixLength := 24;
        end;
        CheckChange(Name, SetInterfaceAddress(Name, Address, PrefixLength));
      end;
    end
    else
      Fail(1, '%s: unknown setting ''%s''', [ArgumentText(Name), ArgumentText(Setting)]);
    Inc(Index);
  end;
end;

var
  Parser: TOptionParser;
  Code: Integer;
  Value: PChar;

begin
  BeginOptions(Parser, [
    OptionDefinition('a', 'all', False, OptionAll),
    OptionDefinition('s', 'short', False, OptionShort)], Usage);
  while NextOption(Parser, Code, Value) do
    if Code = OptionShort then
      ShortListing := True;
  case Parser.OperandCount of
    0: Show(nil);
    1: Show(Parser.Operands[0]);
  else
    Configure(Parser.Operands, Parser.OperandCount);
  end;
  FlushStream(StandardOutput);
end.
