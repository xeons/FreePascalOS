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
  and how an interface is described to programs (ifconfig).

  Giving an interface an address replaces the one it had: the routes
  through the interface and its ARP entries are dropped, the route to
  its own network is added, and the address is announced. Turning it
  off drops what waits to be sent and its ARP entries; its routes stay
  but are not used while it is off. Every change is written to the
  kernel log. Under the network lock.
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
end;

function SetInterfaceMtu(NetworkInterface: PNetworkInterface; Mtu: LongWord): LongInt;
begin
  if (Mtu < MinimumMtu) or (Mtu > DefaultMtu) then
    Exit(ErrorInvalidArgument);
  NetworkInterface^.Mtu := Mtu;
  Result := ErrorNone;
end;

function ConfigureInterface(constref Configuration: TAbiInterfaceConfiguration): LongInt;
var
  Name: array[0..NetworkInterfaceNameCapacity - 1] of Char;
  NetworkInterface: PNetworkInterface;
begin
  CopyText(@Name[0], @Configuration.Name[0], NetworkInterfaceNameCapacity);
  NetworkInterface := FindInterfaceByName(@Name[0]);
  if NetworkInterface = nil then
    Exit(ErrorNoDevice);
  if (Configuration.Changes and not (InterfaceChangeAddress or InterfaceChangeUp or InterfaceChangeMtu)) <> 0 then
    Exit(ErrorInvalidArgument);
  Result := ErrorNone;
  if (Configuration.Changes and InterfaceChangeMtu) <> 0 then
  begin
    Result := SetInterfaceMtu(NetworkInterface, Configuration.Mtu);
    if Result <> ErrorNone then
      Exit;
  end;
  if (Configuration.Changes and InterfaceChangeAddress) <> 0 then
  begin
    case Configuration.Address.Family of
      AddressFamilyUnspecified: RemoveInterfaceAddress(NetworkInterface);
      AddressFamilyIPv4:
        Result := SetInterfaceAddress(NetworkInterface, ReadIpv4Address(@Configuration.Address.Address[0]),
          Configuration.Address.PrefixLength);
    else
      Result := ErrorAddressFamilyNotSupported;
    end;
    if Result <> ErrorNone then
      Exit;
  end;
  if (Configuration.Changes and InterfaceChangeUp) <> 0 then
    SetInterfaceUp(NetworkInterface, Configuration.Up <> 0);
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
  Description.Counters := NetworkInterface^.Counters;
  Description.Counters.ReceiveDrops := Description.Counters.ReceiveDrops + QWord(NetworkInterface^.QueueDrops);
end;

end.
