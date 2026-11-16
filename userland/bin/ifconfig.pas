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
  ifconfig INTERFACE [inet6] add|del IPV6ADDRESS[/PREFIX]
  ifconfig INTERFACE inet6 auto|linklocal|off

  Without arguments (or with -a) shows every interface: its state, MTU,
  address, netmask and broadcast address, its IPv6 addresses with their
  prefix length and scope, hardware address and what went through it,
  in the manner of net-tools' ifconfig; -s a table of the counters.
  With an interface and settings, changes it (root only): an address
  with a prefix or a netmask (0.0.0.0 removes the address), an IPv6
  address added or removed (a prefix of 64 if none is given), IPv6's
  mode (auto: router advertisements and SLAAC; linklocal: only the
  link-local and manual addresses; off), the MTU, and turning it on or
  off, in the order given.
}
program ifconfig;

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
  Usage ='Usage: ifconfig [-a] [-s] [INTERFACE]'#10 +
    '  or:  ifconfig INTERFACE [ADDRESS[/PREFIX]] [netmask MASK] [mtu N] [up|down]'#10 +
    '  or:  ifconfig INTERFACE [inet6] add|del IPV6ADDRESS[/PREFIX]'#10 +
    '  or:  ifconfig INTERFACE inet6 auto|linklocal|off'#10 +
    'Show the network interfaces, or configure one (root only).'#10 +
    #10 +
    '  -a, --all     show every interface (the default)'#10 +
    '  -s, --short   a table of the counters'#10;

  OptionAll = 1;
  OptionShort = 2;
  DefaultIpv6PrefixLength = 64;

var
  ShortListing: Boolean = False;

procedure Say(const Line: string);
begin
  PrintStringLine(Line);
end;

procedure ShowCounters(constref Description: TAbiNetworkInterface);
begin
  Say(Format('        RX packets %u  bytes %u', [Description.Counters.ReceivedPackets,
    Description.Counters.ReceivedBytes]));
  Say(Format('        RX errors %u  dropped %u', [Description.Counters.ReceiveErrors,
    Description.Counters.ReceiveDrops]));
  Say(Format('        TX packets %u  bytes %u', [Description.Counters.SentPackets, Description.Counters.SentBytes]));
  Say(Format('        TX errors %u  dropped %u', [Description.Counters.SendErrors, Description.Counters.SendDrops]));
end;

procedure ShowIpv4Address(constref Description: TAbiNetworkInterface; constref Entry: TAbiInterfaceAddress);
var
  Address: TInternetAddress;
  Line: string;
  Mask: LongWord;
begin
  Address := InterfaceAddressHost(Entry);
  Line := Format('        inet %s  netmask %s', [AddressToText(Address), NetmaskToText(Entry.PrefixLength)]);
  if ((Description.Flags and InterfaceFlagBroadcast) <> 0) and (Entry.PrefixLength < 31) then
  begin
    Mask := 0;
    if Entry.PrefixLength > 0 then
      Mask := LongWord($FFFFFFFF shl (32 - Entry.PrefixLength));
    Line := Line + '  broadcast ' + AddressToText(Ipv4AddressFromValue(Ipv4AddressValue(Address) or not Mask));
  end;
  Say(Line);
end;

{ The scope as net-tools shows it: "0x20<link>". }
function ScopeText(constref Address: TInternetAddress): string;
begin
  if AddressIsLoopback(Address) then
    Result := '0x10<host>'
  else if AddressIsLinkLocal(Address) then
    Result := '0x20<link>'
  else if (Address.Bytes[0] = $FE) and ((Address.Bytes[1] and $C0) = $C0) then
    Result := '0x40<site>'
  else
    Result := '0x0<global>';
end;

procedure ShowIpv6Address(constref Entry: TAbiInterfaceAddress);
var
  Address: TInternetAddress;
  Line: string;
begin
  Address := InterfaceAddressHost(Entry);
  Line := Format('        inet6 %s  prefixlen %d  scopeid %s', [AddressToText(Address), Entry.PrefixLength,
    ScopeText(Address)]);
  if (Entry.Flags and InterfaceAddressFlagTentative) <> 0 then
    Line := Line + '  tentative';
  if (Entry.Flags and InterfaceAddressFlagDeprecated) <> 0 then
    Line := Line + '  deprecated';
  Say(Line);
end;

function InterfaceName(constref Description: TAbiNetworkInterface): string;
begin
  Result := InterfaceNameToText(Description.Name);
end;

procedure ShowInterface(constref Description: TAbiNetworkInterface);
var
  Index: LongWord;
begin
  Say(Format('%s: flags=<%s>  mtu %u', [InterfaceName(Description), InterfaceFlagsToText(Description.Flags),
    Description.Mtu]));
  Index := 0;
  while (Index < Description.AddressCount) and (Index < MaximumInterfaceAddresses) do
  begin
    if Description.Addresses[Index].Family = AddressFamilyIPv6 then
      ShowIpv6Address(Description.Addresses[Index])
    else
      ShowIpv4Address(Description, Description.Addresses[Index]);
    Inc(Index);
  end;
  if (Description.Flags and InterfaceFlagLoopback) <> 0 then
    Say('        loop')
  else
    Say(Format('        ether %s  (%s)', [HardwareAddressToText(Description.HardwareAddress,
      Description.HardwareAddressLength), InterfaceNameToText(Description.Description)]));
  ShowCounters(Description);
  Say('');
end;

procedure ShowShortHeading;
begin
  Say('Iface      MTU    RX-OK RX-ERR RX-DRP    TX-OK TX-ERR TX-DRP Flg');
end;

procedure ShowShortLine(constref Description: TAbiNetworkInterface);
var
  Flags: string;
begin
  Flags := '';
  if (Description.Flags and InterfaceFlagBroadcast) <> 0 then
    Flags := Flags + 'B';
  if (Description.Flags and InterfaceFlagLoopback) <> 0 then
    Flags := Flags + 'L';
  if (Description.Flags and InterfaceFlagRunning) <> 0 then
    Flags := Flags + 'R';
  if (Description.Flags and InterfaceFlagUp) <> 0 then
    Flags := Flags + 'U';
  Say(Format('%-8s %5u %8u %6u %6u %8u %6u %6u %s', [InterfaceName(Description), Description.Mtu,
    Description.Counters.ReceivedPackets, Description.Counters.ReceiveErrors, Description.Counters.ReceiveDrops,
    Description.Counters.SentPackets, Description.Counters.SendErrors, Description.Counters.SendDrops, Flags]));
end;

procedure FailNoDevice(const Name: string);
begin
  Fail(1, Format('%s: error fetching interface information: Device not found', [Name]));
end;

procedure Show(const Name: string);
var
  Interfaces: TNetworkInterfaceList;
  Description: TAbiNetworkInterface;
  Found: Boolean;
  Error: LongInt;
begin
  Error := ListNetworkInterfaces(Interfaces);
  if Error <> ErrorNone then
    FailWithError(1, Error, 'cannot list the interfaces');
  if ShortListing then
    ShowShortHeading;
  Found := False;
  for Description in Interfaces do
  begin
    if (Name <> '') and (InterfaceName(Description) <> Name) then
      Continue;
    Found := True;
    if ShortListing then
      ShowShortLine(Description)
    else
      ShowInterface(Description);
  end;
  if (Name <> '') and not Found then
    FailNoDevice(Name);
end;

procedure CheckChange(const Name: string; Error: LongInt);
begin
  if Error <> ErrorNone then
    FailWithError(1, Error, Name);
end;

{ The settings after the interface's name, taken one by one. }
type
  TSettingReader = record
    Operands: TStringArray;
    Index: Integer;
  end;

function HasMore(constref Reader: TSettingReader): Boolean;
begin
  Result := Reader.Index < Length(Reader.Operands);
end;

function TakeSetting(var Reader: TSettingReader): string;
begin
  Result := Reader.Operands[Reader.Index];
  Inc(Reader.Index);
end;

{ The value a setting needs. }
function TakeValueOf(var Reader: TSettingReader; const Setting: string): string;
begin
  if not HasMore(Reader) then
    FailWithUsageHint(Format('''%s'' needs a value', [Setting]));
  Result := TakeSetting(Reader);
end;

{ "add" or "del" an IPv6 address. }
procedure ChangeIpv6Address(const Name, Operation, Text: string);
var
  Address: TInternetAddress;
  PrefixLength: LongWord;
  HasPrefix: Boolean;
begin
  if not TextToAddressWithPrefix(Text, Address, PrefixLength, HasPrefix) or (Address.Family <> AddressFamilyIPv6) then
    Fail(1, Format('%s: invalid IPv6 address ''%s''', [Name, Text]));
  if not HasPrefix then
    PrefixLength := DefaultIpv6PrefixLength;
  if Operation = 'add' then
    CheckChange(Name, AddInterfaceIpv6Address(PChar(Name), Address, PrefixLength))
  else
    CheckChange(Name, RemoveInterfaceIpv6Address(PChar(Name), Address));
end;

{ "auto", "linklocal" or "off". }
procedure ChangeIpv6Mode(const Name, ModeName: string);
var
  Mode: LongWord;
begin
  if ModeName = 'auto' then
    Mode := Ipv6ModeAutomatic
  else if ModeName = 'linklocal' then
    Mode := Ipv6ModeLinkLocal
  else if ModeName = 'off' then
    Mode := Ipv6ModeOff
  else
  begin
    Fail(1, Format('%s: unknown IPv6 setting ''%s''', [Name, ModeName]));
    Exit;
  end;
  CheckChange(Name, SetInterfaceIpv6Mode(PChar(Name), Mode));
end;

procedure ChangeMtu(const Name, Text: string);
var
  Mtu: LongInt;
begin
  if not TryStrToInt(Text, Mtu) or (Mtu <= 0) then
    Fail(1, Format('invalid MTU ''%s''', [Text]));
  CheckChange(Name, SetInterfaceMtu(PChar(Name), LongWord(Mtu)));
end;

procedure ChangeNetmask(const Name, Text: string);
var
  PrefixLength: LongWord;
  Description: TAbiNetworkInterface;
  Current: TAbiInterfaceAddress;
begin
  if not TextToNetmask(Text, PrefixLength) then
    Fail(1, Format('invalid netmask ''%s''', [Text]));
  if not FindNetworkInterface(PChar(Name), Description) or not FindInterfaceIpv4Address(Description, Current) then
    Fail(1, Format('%s: no address to apply the netmask to', [Name]));
  CheckChange(Name, SetInterfaceAddress(PChar(Name), InterfaceAddressHost(Current), PrefixLength));
end;

{ The prefix of an IPv4 address given without one: its class's, as
  ifconfig always did. }
function ClassPrefixLength(constref Address: TInternetAddress): LongWord;
begin
  if Address.Bytes[0] < 128 then
    Result := 8
  else if Address.Bytes[0] < 192 then
    Result := 16
  else
    Result := 24;
end;

{ An address operand: IPv6 is added, IPv4 replaces (0.0.0.0: removed). }
function ChangeAddress(const Name, Text: string): Boolean;
var
  Address: TInternetAddress;
  PrefixLength: LongWord;
  HasPrefix: Boolean;
begin
  Result := TextToAddressWithPrefix(Text, Address, PrefixLength, HasPrefix);
  if not Result then
    Exit;
  if Address.Family = AddressFamilyIPv6 then
    ChangeIpv6Address(Name, 'add', Text)
  else if AddressIsUnspecified(Address) then
    CheckChange(Name, RemoveInterfaceAddress(PChar(Name)))
  else
  begin
    if not HasPrefix then
      PrefixLength := ClassPrefixLength(Address);
    CheckChange(Name, SetInterfaceAddress(PChar(Name), Address, PrefixLength));
  end;
end;

procedure Configure(const Operands: TStringArray);
var
  Name: string;
  Reader: TSettingReader;
  Setting: string;
  Operation: string;
  Description: TAbiNetworkInterface;
begin
  Name := Operands[0];
  if not FindNetworkInterface(PChar(Name), Description) then
    FailNoDevice(Name);
  Reader.Operands := Operands;
  Reader.Index := 1;
  while HasMore(Reader) do
  begin
    Setting := TakeSetting(Reader);
    if Setting = 'inet6' then
    begin
      Operation := TakeValueOf(Reader, Setting);
      if (Operation = 'add') or (Operation = 'del') then
        ChangeIpv6Address(Name, Operation, TakeValueOf(Reader, Operation))
      else
        ChangeIpv6Mode(Name, Operation);
    end
    else if (Setting = 'add') or (Setting = 'del') then
      ChangeIpv6Address(Name, Setting, TakeValueOf(Reader, Setting))
    else if Setting = 'up' then
      CheckChange(Name, SetInterfaceUp(PChar(Name), True))
    else if Setting = 'down' then
      CheckChange(Name, SetInterfaceUp(PChar(Name), False))
    else if Setting = 'mtu' then
      ChangeMtu(Name, TakeValueOf(Reader, Setting))
    else if Setting = 'netmask' then
      ChangeNetmask(Name, TakeValueOf(Reader, Setting))
    else if not ChangeAddress(Name, Setting) then
      Fail(1, Format('%s: unknown setting ''%s''', [Name, Setting]));
  end;
end;

var
  CommandLine: TCommandLine;
  Code: Integer;
  Value: string;

begin
  CommandLine := TCommandLine.Create([
    CommandOption('a', 'all', False, OptionAll),
    CommandOption('s', 'short', False, OptionShort)], Usage);
  while CommandLine.NextOption(Code, Value) do
    if Code = OptionShort then
      ShortListing := True;
  case CommandLine.OperandCount of
    0: Show('');
    1: Show(CommandLine.Operands[0]);
  else
    Configure(CommandLine.Operands);
  end;
end.
