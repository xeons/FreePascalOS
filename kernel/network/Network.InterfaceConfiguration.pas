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
  Configuring interfaces: the address and prefix, on and off, the MTU,
  IPv6's mode and manual addresses, and how an interface is described
  to programs (ifconfig).

  Giving an interface an address replaces the one it had: the routes
  through the interface and its ARP entries are dropped, the route to
  its own network is added, and the address is announced. Turning it
  off drops what waits to be sent and its ARP entries; its routes stay
  but are not used while it is off. Turning it on or off starts or
  stops IPv6 on it (Network.Ipv6Interfaces). IPv6 addresses are added
  and removed one by one beside the others; the IPv6 options (temporary
  addresses, EUI-64 identifiers) are an interface's, the secret of the
  stable-privacy identifiers every interface's (any interface may be
  named with it). Every change is written to
  the kernel log. Under the network lock.
}
unit Network.InterfaceConfiguration;

{$mode objfpc}
{$pointermath on}

interface

uses
  Abi.SystemCalls,
  Network.Addresses,
  Network.Interfaces;

function SetInterfaceAddress(NetworkInterface: PNetworkInterface; Address: TIpv4Address;
  PrefixLength: LongWord): LongInt;
procedure RemoveInterfaceAddress(NetworkInterface: PNetworkInterface);
procedure SetInterfaceUp(NetworkInterface: PNetworkInterface; Up: Boolean);
function SetInterfaceMtu(NetworkInterface: PNetworkInterface; Mtu: LongWord): LongInt;
{ Applies a system call's configuration (Changes says what). }
function ConfigureInterface(constref Configuration: TAbiInterfaceConfiguration): LongInt;
procedure DescribeInterface(NetworkInterface: PNetworkInterface; out Description: TAbiNetworkInterface);

implementation

uses
  Runtime.Memory,
  Runtime.Text,
  Io.NetworkAdapters,
  Network.Packets,
  Network.Routing,
  Network.Arp,
  Network.Ipv6Addresses,
  Network.Ipv6Types,
  Network.Ipv6AddressList,
  Network.Ipv6Interfaces,
  Network.Ipv6,
  Debug.Output;

procedure WriteChange(NetworkInterface: PNetworkInterface; What: PChar);
var
  Text: array[0..15] of Char;
  Number: TNumberText;
begin
  DebugBeginMessage;
  DebugWriteTag('network');
  DebugWrite(@NetworkInterface^.Name[0]);
  DebugWrite(': ');
  DebugWrite(What);
  if NetworkInterface^.HasAddress then
  begin
    FormatIpv4Address(NetworkInterface^.Address, @Text[0]);
    DebugWrite(', address ');
    DebugWrite(@Text[0]);
    DebugWrite('/');
    DebugWrite(FormatDecimal(NetworkInterface^.PrefixLength, Number));
  end;
  DebugWriteLine('');
  DebugEndMessage;
end;

function SetInterfaceAddress(NetworkInterface: PNetworkInterface; Address: TIpv4Address;
  PrefixLength: LongWord): LongInt;
var
  Owner: PNetworkInterface;
begin
  if (PrefixLength > 32) or (Address = AnyAddress) or (Address = LimitedBroadcastAddress) or
     IsMulticastAddress(Address) then
    Exit(ErrorInvalidArgument);
  Owner := FindInterfaceWithAddress(Address);
  if (Owner <> nil) and (Owner <> NetworkInterface) then
    Exit(ErrorAddressInUse);
  RemoveInterfaceRoutes(NetworkInterface);
  ForgetInterfaceNeighbours(NetworkInterface);
  NetworkInterface^.HasAddress := True;
  NetworkInterface^.Address := Address;
  NetworkInterface^.PrefixLength := PrefixLength;
  AddRoute(Address and PrefixMask(PrefixLength), PrefixLength, AnyAddress, NetworkInterface,
    RouteFlagInterface, 0);
  AnnounceAddress(NetworkInterface);
  WriteChange(NetworkInterface, 'configured');
  Result := ErrorNone;
end;

procedure RemoveInterfaceAddress(NetworkInterface: PNetworkInterface);
begin
  RemoveInterfaceRoutes(NetworkInterface);
  ForgetInterfaceNeighbours(NetworkInterface);
  NetworkInterface^.HasAddress := False;
  NetworkInterface^.Address := AnyAddress;
  NetworkInterface^.PrefixLength := 0;
  WriteChange(NetworkInterface, 'address removed');
end;

procedure SetInterfaceUp(NetworkInterface: PNetworkInterface; Up: Boolean);
begin
  if NetworkInterface^.IsUp = Up then
    Exit;
  NetworkInterface^.IsUp := Up;
  if Up then
  begin
    AnnounceAddress(NetworkInterface);
    WriteChange(NetworkInterface, 'up');
  end
  else
  begin
    DiscardPacketQueue(NetworkInterface^.TransmitQueue);
    ForgetInterfaceNeighbours(NetworkInterface);
    WriteChange(NetworkInterface, 'down');
  end;
  Ipv6InterfaceChanged(NetworkInterface);
end;

function SetInterfaceMtu(NetworkInterface: PNetworkInterface; Mtu: LongWord): LongInt;
begin
  if (Mtu < MinimumMtu) or (Mtu > DefaultMtu) then
    Exit(ErrorInvalidArgument);
  NetworkInterface^.Mtu := Mtu;
  Result := ErrorNone;
end;

function Ipv6AddressOf(constref Address: TAbiInterfaceAddress): TIpv6Address;
begin
  CopyMemory(@Result[0], @Address.Address[0], Ipv6AddressLength);
end;

{ InterfaceChangeAddress: IPv4 replaces the address, IPv6 adds one. }
function ChangeAddress(NetworkInterface: PNetworkInterface; constref Address: TAbiInterfaceAddress): LongInt;
var
  Address6: TIpv6Address;
begin
  case Address.Family of
    AddressFamilyUnspecified:
      begin
        RemoveInterfaceAddress(NetworkInterface);
        Result := ErrorNone;
      end;
    AddressFamilyIPv4:
      Result := SetInterfaceAddress(NetworkInterface, ReadIpv4Address(@Address.Address[0]), Address.PrefixLength);
    AddressFamilyIPv6:
      begin
        Address6 := Ipv6AddressOf(Address);
        if NetworkInterface^.Ipv6.Mode = Ipv6ModeOff then
          Exit(ErrorNetworkUnreachable);
        if IsLinkLocalIpv6Address(Address6) or IsLoopbackIpv6Address(Address6) then
          Exit(ErrorInvalidArgument);
        Result := AddIpv6Address(NetworkInterface, Address6, Address.PrefixLength, Ipv6OriginManual, Ipv6Forever,
          Ipv6Forever);
      end;
  else
    Result := ErrorAddressFamilyNotSupported;
  end;
end;

function RemoveAddress(NetworkInterface: PNetworkInterface; constref Address: TAbiInterfaceAddress): LongInt;
begin
  case Address.Family of
    AddressFamilyIPv4:
      begin
        if not NetworkInterface^.HasAddress or
           (NetworkInterface^.Address <> ReadIpv4Address(@Address.Address[0])) then
          Exit(ErrorNotFound);
        RemoveInterfaceAddress(NetworkInterface);
        Result := ErrorNone;
      end;
    AddressFamilyIPv6:
      Result := RemoveIpv6Address(NetworkInterface, Ipv6AddressOf(Address));
  else
    Result := ErrorAddressFamilyNotSupported;
  end;
end;

function ConfigureInterface(constref Configuration: TAbiInterfaceConfiguration): LongInt;
const
  KnownChanges = InterfaceChangeAddress or InterfaceChangeUp or InterfaceChangeMtu or InterfaceChangeIpv6Mode or
    InterfaceChangeRemoveAddress or InterfaceChangeIpv6Options or InterfaceChangeStableSecret;
var
  Name: array[0..NetworkInterfaceNameCapacity - 1] of Char;
  NetworkInterface: PNetworkInterface;
begin
  CopyText(@Name[0], @Configuration.Name[0], NetworkInterfaceNameCapacity);
  NetworkInterface := FindInterfaceByName(@Name[0]);
  if NetworkInterface = nil then
    Exit(ErrorNoDevice);
  if (Configuration.Changes and not KnownChanges) <> 0 then
    Exit(ErrorInvalidArgument);
  Result := ErrorNone;
  if (Configuration.Changes and InterfaceChangeStableSecret) <> 0 then
    SetIpv6StableSecret(@Configuration.StableSecret[0]);
  if (Configuration.Changes and InterfaceChangeIpv6Options) <> 0 then
  begin
    Result := SetIpv6Options(NetworkInterface, Configuration.Ipv6Options);
    if Result <> ErrorNone then
      Exit;
  end;
  if (Configuration.Changes and InterfaceChangeMtu) <> 0 then
  begin
    Result := SetInterfaceMtu(NetworkInterface, Configuration.Mtu);
    if Result <> ErrorNone then
      Exit;
  end;
  if (Configuration.Changes and InterfaceChangeIpv6Mode) <> 0 then
  begin
    Result := SetIpv6Mode(NetworkInterface, Configuration.Ipv6Mode);
    if Result <> ErrorNone then
      Exit;
  end;
  if (Configuration.Changes and InterfaceChangeRemoveAddress) <> 0 then
  begin
    Result := RemoveAddress(NetworkInterface, Configuration.Address);
    if Result <> ErrorNone then
      Exit;
  end
  else if (Configuration.Changes and InterfaceChangeAddress) <> 0 then
  begin
    Result := ChangeAddress(NetworkInterface, Configuration.Address);
    if Result <> ErrorNone then
      Exit;
  end;
  if (Configuration.Changes and InterfaceChangeUp) <> 0 then
    SetInterfaceUp(NetworkInterface, Configuration.Up <> 0);
end;

function AddressFlags(Entry: PIpv6InterfaceAddress): LongWord;
begin
  Result := 0;
  case Entry^.State of
    Ipv6AddressTentative: Result := InterfaceAddressFlagTentative;
    Ipv6AddressDeprecated: Result := InterfaceAddressFlagDeprecated;
  end;
  case Entry^.Origin of
    Ipv6OriginAutomatic: Result := Result or InterfaceAddressFlagAutomatic;
    Ipv6OriginTemporary: Result := Result or InterfaceAddressFlagAutomatic or InterfaceAddressFlagTemporary;
    Ipv6OriginLinkLocal: Result := Result or InterfaceAddressFlagLinkLocal;
  end;
end;

{ The IPv6 part of a description: mode, addresses (after the IPv4 one),
  what routers advertised. }
procedure DescribeIpv6(NetworkInterface: PNetworkInterface; var Description: TAbiNetworkInterface);
var
  Index: Integer;
  Entry: PIpv6InterfaceAddress;
  Slot: ^TAbiInterfaceAddress;
begin
  Description.Ipv6Mode := NetworkInterface^.Ipv6.Mode;
  Description.Ipv6Options := NetworkInterface^.Ipv6.Options;
  Description.Ipv6HopLimit := NetworkInterface^.Ipv6.HopLimit;
  Description.Ipv6Mtu := Ipv6LinkMtu(NetworkInterface);
  for Index := 0 to MaximumIpv6InterfaceAddresses - 1 do
  begin
    Entry := @NetworkInterface^.Ipv6.Addresses[Index];
    if (Entry^.State = Ipv6AddressFree) or (Description.AddressCount >= MaximumInterfaceAddresses) then
      Continue;
    Slot := @Description.Addresses[Description.AddressCount];
    Slot^.Family := AddressFamilyIPv6;
    Slot^.PrefixLength := Entry^.PrefixLength;
    Slot^.Flags := AddressFlags(Entry);
    CopyMemory(@Slot^.Address[0], @Entry^.Address[0], Ipv6AddressLength);
    Inc(Description.AddressCount);
  end;
  for Index := 0 to MaximumDnsServers - 1 do
    if NetworkInterface^.Ipv6.DnsServers[Index].InUse then
    begin
      CopyMemory(@Description.Ipv6DnsServers[Description.Ipv6DnsServerCount][0],
        @NetworkInterface^.Ipv6.DnsServers[Index].Address[0], Ipv6AddressLength);
      Inc(Description.Ipv6DnsServerCount);
    end;
end;

procedure DescribeInterface(NetworkInterface: PNetworkInterface; out Description: TAbiNetworkInterface);
begin
  FillMemory(@Description, SizeOf(Description), 0);
  CopyText(@Description.Name[0], @NetworkInterface^.Name[0], NetworkInterfaceNameCapacity);
  CopyText(@Description.Description[0], @NetworkInterface^.Description[0], NetworkInterfaceDescriptionCapacity);
  if not NetworkInterface^.IsLoopback then
  begin
    CopyMemory(@Description.HardwareAddress[0], @NetworkInterface^.HardwareAddress[0], EthernetAddressLength);
    Description.HardwareAddressLength := EthernetAddressLength;
    Description.Flags := InterfaceFlagBroadcast;
  end
  else
    Description.Flags := InterfaceFlagLoopback;
  Description.Index := NetworkInterface^.Index;
  if NetworkInterface^.IsUp then
    Description.Flags := Description.Flags or InterfaceFlagUp;
  if NetworkInterface^.LinkIsUp then
    Description.Flags := Description.Flags or InterfaceFlagRunning;
  Description.Mtu := NetworkInterface^.Mtu;
  if NetworkInterface^.HasAddress then
  begin
    Description.AddressCount := 1;
    Description.Addresses[0].Family := AddressFamilyIPv4;
    Description.Addresses[0].PrefixLength := NetworkInterface^.PrefixLength;
    WriteIpv4Address(@Description.Addresses[0].Address[0], NetworkInterface^.Address);
  end;
  DescribeIpv6(NetworkInterface, Description);
  Description.Counters := NetworkInterface^.Counters;
  Description.Counters.ReceiveDrops := Description.Counters.ReceiveDrops + QWord(NetworkInterface^.QueueDrops);
end;

end.
