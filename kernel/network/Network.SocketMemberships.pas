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
  The multicast groups a socket joined (SocketOptionJoinGroup and
  SocketOptionLeaveGroup: IPV6_JOIN_GROUP, IP_ADD_MEMBERSHIP and their
  leaves), at most MaximumSocketMemberships each, every one also counted
  in the interface's groups (Network.MulticastGroups), which reports
  them. The interface is the one asked for (by index, or for IPv4 by
  its address), else the one the routes give the group (IPv6: the first
  Ethernet interface with IPv6; IPv4: the default route's). An IPv6
  socket may join IPv4 groups unless it is Ipv6Only. Closing the socket
  leaves them all. Under the network lock.
}
unit Network.SocketMemberships;

{$mode objfpc}

interface

uses
  Abi.SystemCalls,
  Network.Sockets;

{ SocketOptionJoinGroup or SocketOptionLeaveGroup with the request. }
function ChangeSocketMembership(Socket: PSocket; Option: LongWord; constref Request: TAbiMulticastMembership): LongInt;
procedure LeaveAllSocketGroups(Socket: PSocket);

implementation

uses
  Runtime.Memory,
  Network.Addresses,
  Network.Ipv6Addresses,
  Network.Interfaces,
  Network.Ipv4,
  Network.Ipv6,
  Network.MulticastGroups;

{ The interface a group is joined on when the request names none. }
function DefaultGroupInterface(Family: Word; constref Group6: TIpv6Address; Group4: TIpv4Address): PNetworkInterface;
var
  NextHop4: TIpv4Address;
  Source4: TIpv4Address;
  NextHop6: TIpv6Address;
  Source6: TIpv6Address;
begin
  Result := nil;
  if Family = AddressFamilyIPv6 then
  begin
    if RouteIpv6Datagram(Group6, nil, Result, NextHop6, Source6) <> ErrorNone then
      Result := nil;
  end
  else if RouteDatagram(Group4, nil, Result, NextHop4, Source4) <> ErrorNone then
    Result := nil;
end;

function RequestedInterface(constref Request: TAbiMulticastMembership; constref Group6: TIpv6Address;
  Group4: TIpv4Address; out NetworkInterface: PNetworkInterface): LongInt;
var
  InterfaceAddress: TIpv4Address;
begin
  Result := ErrorNone;
  NetworkInterface := nil;
  if Request.InterfaceIndex <> 0 then
    NetworkInterface := FindInterfaceByIndex(Request.InterfaceIndex)
  else if Request.Family = AddressFamilyIPv4 then
  begin
    InterfaceAddress := ReadIpv4Address(@Request.InterfaceAddress[0]);
    if InterfaceAddress <> AnyAddress then
    begin
      NetworkInterface := FindInterfaceWithAddress(InterfaceAddress);
      if NetworkInterface = nil then
        Exit(ErrorAddressNotAvailable);
    end;
  end;
  if (NetworkInterface = nil) and (Request.InterfaceIndex <> 0) then
    Exit(ErrorNoDevice);
  if NetworkInterface = nil then
    NetworkInterface := DefaultGroupInterface(Request.Family, Group6, Group4);
  if NetworkInterface = nil then
    Result := ErrorNoDevice;
end;

function FindMembership(Socket: PSocket; NetworkInterface: PNetworkInterface; Family: Word;
  constref Group6: TIpv6Address; Group4: TIpv4Address): Integer;
var
  Index: Integer;
begin
  for Index := 0 to MaximumSocketMemberships - 1 do
    if Socket^.Memberships[Index].InUse and (Socket^.Memberships[Index].NetworkInterface = NetworkInterface) and
       (Socket^.Memberships[Index].Family = Family) and
       Ipv6AddressesEqual(Socket^.Memberships[Index].Group6, Group6) and
       (Socket^.Memberships[Index].Group4 = Group4) then
      Exit(Index);
  Result := -1;
end;

function JoinGroup(Socket: PSocket; NetworkInterface: PNetworkInterface; Family: Word;
  constref Group6: TIpv6Address; Group4: TIpv4Address): LongInt;
var
  Index: Integer;
begin
  if FindMembership(Socket, NetworkInterface, Family, Group6, Group4) >= 0 then
    Exit(ErrorAddressInUse);
  for Index := 0 to MaximumSocketMemberships - 1 do
    if not Socket^.Memberships[Index].InUse then
    begin
      Result := JoinMulticastGroup(NetworkInterface, Family, Group6, Group4);
      if Result <> ErrorNone then
        Exit;
      Socket^.Memberships[Index].InUse := True;
      Socket^.Memberships[Index].NetworkInterface := NetworkInterface;
      Socket^.Memberships[Index].Family := Family;
      Socket^.Memberships[Index].Group6 := Group6;
      Socket^.Memberships[Index].Group4 := Group4;
      Exit(ErrorNone);
    end;
  Result := ErrorNoSpace;
end;

procedure DropMembership(Socket: PSocket; Index: Integer);
begin
  LeaveMulticastGroup(Socket^.Memberships[Index].NetworkInterface, Socket^.Memberships[Index].Family,
    Socket^.Memberships[Index].Group6, Socket^.Memberships[Index].Group4);
  Socket^.Memberships[Index].InUse := False;
end;

function ChangeSocketMembership(Socket: PSocket; Option: LongWord; constref Request: TAbiMulticastMembership): LongInt;
var
  Group6: TIpv6Address;
  Group4: TIpv4Address;
  NetworkInterface: PNetworkInterface;
  Position: Integer;
begin
  if Socket^.Protocol <> SocketProtocolUdp then
    Exit(ErrorUnsupported);
  Group6 := UnspecifiedIpv6Address;
  Group4 := AnyAddress;
  case Request.Family of
    AddressFamilyIPv6:
      begin
        if Socket^.Family <> AddressFamilyIPv6 then
          Exit(ErrorAddressFamilyNotSupported);
        CopyMemory(@Group6[0], @Request.Group[0], Ipv6AddressLength);
        if not IsMulticastIpv6Address(Group6) then
          Exit(ErrorInvalidArgument);
      end;
    AddressFamilyIPv4:
      begin
        if (Socket^.Family = AddressFamilyIPv6) and Socket^.Ipv6Only then
          Exit(ErrorAddressFamilyNotSupported);
        Group4 := ReadIpv4Address(@Request.Group[0]);
        if not IsMulticastAddress(Group4) then
          Exit(ErrorInvalidArgument);
      end;
  else
    Exit(ErrorAddressFamilyNotSupported);
  end;
  Result := RequestedInterface(Request, Group6, Group4, NetworkInterface);
  if Result <> ErrorNone then
    Exit;
  if Option = SocketOptionJoinGroup then
    Exit(JoinGroup(Socket, NetworkInterface, Request.Family, Group6, Group4));
  Position := FindMembership(Socket, NetworkInterface, Request.Family, Group6, Group4);
  if Position < 0 then
    Exit(ErrorNotFound);
  DropMembership(Socket, Position);
  Result := ErrorNone;
end;

procedure LeaveAllSocketGroups(Socket: PSocket);
var
  Index: Integer;
begin
  for Index := 0 to MaximumSocketMemberships - 1 do
    if Socket^.Memberships[Index].InUse then
      DropMembership(Socket, Index);
end;

end.
