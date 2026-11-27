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
  networktest's IPv6 pieces: pinging over ICMPv6, UDP and TCP over ::1,
  IPv4 and IPv6 sockets on one port, and what the kernel shows of an
  interface's IPv6 (addresses, default route, neighbours, DNS servers
  from router advertisements). Each function answers one question; the
  program turns the answers into its check lines.
}
unit NetworkTest.Ipv6;

{$mode objfpc}
{$H+}

interface

uses
  Sys.InternetAddresses;

{ The address written as Text (which must be one). }
function Ipv6(const Text: string): TInternetAddress;
{ Sends Count echo requests to Address over ICMPv6; how many replies came. }
function PingIpv6(constref Address: TInternetAddress; Count: Integer): Integer;
{ A datagram to a socket on [::1] and back. }
function UdpEchoOverIpv6Loopback: Boolean;
{ A TCP connection to [::1], data each way. }
function TcpOverIpv6Loopback: Boolean;
{ An IPv4 and an IPv6 socket bound to the same port. }
function DualStackPortWorks: Boolean;
{ An IPv6 socket refuses an IPv4 address. }
function Ipv6SocketRefusesIpv4: Boolean;
{ A TCP listener on [::]:Port is in the socket listing as IPv6. }
function Ipv6ListenerIsListed: Boolean;
{ The interface has Address/PrefixLength, and (with Ready) no longer
  tentative. }
function InterfaceHasIpv6Address(const Name: string; constref Address: TInternetAddress; PrefixLength: LongWord;
  Ready: Boolean): Boolean;
{ Waits up to Milliseconds for InterfaceHasIpv6Address (or, with Wanted
  False, for the address to be gone). }
function WaitForIpv6Address(const Name: string; constref Address: TInternetAddress; PrefixLength: LongWord;
  Wanted: Boolean; Milliseconds: QWord): Boolean;
{ Waits up to Milliseconds for a ready IPv6 address of the interface in
  Prefix/64 with every flag of Required and none of Forbidden
  (InterfaceAddressFlag*); Found is it. }
function WaitForIpv6AddressLike(const Name: string; constref Prefix: TInternetAddress; Required, Forbidden: LongWord;
  Milliseconds: QWord; out Found: TInternetAddress): Boolean;
{ The interface's ready IPv6 addresses as the network service's state
  file lists them: "address/prefix" joined with commas. }
function ReadyIpv6AddressesText(const Name: string): string;
{ An IPv6 default route through Gateway leaves by the interface. }
function HasIpv6DefaultRoute(const Name: string; constref Gateway: TInternetAddress): Boolean;
{ The neighbour cache knows Address's Ethernet address. }
function NeighborIsKnown(constref Address: TInternetAddress): Boolean;
{ A router advertised Address as a DNS server on the interface. }
function InterfaceHasIpv6DnsServer(const Name: string; constref Address: TInternetAddress): Boolean;
{ The interface's IPv6 mode is Mode. }
function InterfaceIpv6ModeIs(const Name: string; Mode: LongWord): Boolean;
{ Waits up to Milliseconds until it is. }
function WaitForIpv6Mode(const Name: string; Mode: LongWord; Milliseconds: QWord): Boolean;

implementation

uses
  Abi.SystemCalls,
  SysUtils,
  Sys.Errors,
  Sys.Sockets,
  Sys.Processes,
  Sys.NetworkInterfaces,
  Sys.AddressText,
  Sys.InterfaceText;

const
  WaitMilliseconds = 5000;
  PollMilliseconds = 100;
  IcmpHeaderBytes = 8;
  EchoRequestType = 128;
  EchoReplyType = 129;

function Ipv6(const Text: string): TInternetAddress;
begin
  if not TextToAddress(Text, Result) then
    Result := AnyIpv6Address;
end;

function LocalPortOf(Socket: Int64): Word;
var
  Address: TAbiSocketAddress;
begin
  Result := 0;
  if GetLocalSocketAddress(Socket, Address) = ErrorNone then
    Result := Address.Port;
end;

function Loopback6(Port: Word): TAbiSocketAddress;
begin
  Result := MakeSocketAddress(LoopbackIpv6Address, Port);
end;

{ Waits for the reply to request Sequence; True if it came. }
function ReceiveEchoReply(Socket: Int64; Sequence: Byte; Size: Int64): Boolean;
var
  Reply: array[0..1023] of Byte;
  Source: TAbiSocketAddress;
  Length: Int64;
begin
  repeat
    Length := ReceiveSocketFrom(Socket, @Reply[0], SizeOf(Reply), 0, Source);
  until (Length < 0) or ((Length = Size) and (Reply[0] = EchoReplyType) and (Reply[7] = Sequence));
  Result := Length = Size;
end;

function PingIpv6(constref Address: TInternetAddress; Count: Integer): Integer;
var
  Socket: Int64;
  Request: array[0..63] of Byte;
  Sequence: Integer;
begin
  Result := 0;
  Socket := CreateSocket(AddressFamilyIPv6, SocketKindDatagram, ProtocolIcmpv6);
  if Socket < 0 then
    Exit;
  SetSocketOption(Socket, SocketOptionReceiveTimeout, 1000);
  for Sequence := 1 to Count do
  begin
    FillChar(Request, SizeOf(Request), Byte(Sequence));
    Request[0] := EchoRequestType;
    Request[1] := 0;
    Request[6] := 0;
    Request[7] := Byte(Sequence);
    if SendSocketTo(Socket, @Request[0], SizeOf(Request), 0, MakeSocketAddress(Address, 0)) <> SizeOf(Request) then
      Continue;
    if ReceiveEchoReply(Socket, Byte(Sequence), SizeOf(Request)) then
      Inc(Result);
  end;
  CloseSocket(Socket);
end;

function UdpEchoOverIpv6Loopback: Boolean;
const
  Message: string = 'over ipv6';
var
  Server: Int64;
  Client: Int64;
  Buffer: array[0..63] of Char;
  Source: TAbiSocketAddress;
  Received: Int64;
  Text: string;
begin
  Result := False;
  Server := CreateSocket(AddressFamilyIPv6, SocketKindDatagram, ProtocolUdp);
  Client := CreateSocket(AddressFamilyIPv6, SocketKindDatagram, ProtocolUdp);
  try
    if (Server < 0) or (Client < 0) or (BindSocket(Server, Loopback6(0)) <> ErrorNone) then
      Exit;
    SetSocketOption(Server, SocketOptionReceiveTimeout, WaitMilliseconds);
    SetSocketOption(Client, SocketOptionReceiveTimeout, WaitMilliseconds);
    if SendSocketTo(Client, PChar(Message), Length(Message), 0, Loopback6(LocalPortOf(Server))) <> Length(Message) then
      Exit;
    Received := ReceiveSocketFrom(Server, @Buffer[0], SizeOf(Buffer), 0, Source);
    if (Received <> Length(Message)) or (Source.Family <> AddressFamilyIPv6) then
      Exit;
    SendSocketTo(Server, @Buffer[0], QWord(Received), 0, Source);
    Received := ReceiveSocketFrom(Client, @Buffer[0], SizeOf(Buffer), 0, Source);
    if Received <> Length(Message) then
      Exit;
    SetString(Text, PChar(@Buffer[0]), Received);
    Result := (Text = Message) and (Source.Port = LocalPortOf(Server));
  finally
    CloseSocket(Server);
    CloseSocket(Client);
  end;
end;

function TcpOverIpv6Loopback: Boolean;
var
  Listener: Int64;
  Client: Int64;
  Accepted: Int64;
  Peer: TAbiSocketAddress;
  Data: Byte;
begin
  Result := False;
  Accepted := -1;
  Listener := CreateSocket(AddressFamilyIPv6, SocketKindStream, ProtocolTcp);
  Client := CreateSocket(AddressFamilyIPv6, SocketKindStream or SocketKindNonBlocking, ProtocolTcp);
  try
    if (Listener < 0) or (Client < 0) or (BindSocket(Listener, Loopback6(0)) <> ErrorNone) or
       (ListenOnSocket(Listener, 2) <> ErrorNone) then
      Exit;
    SetSocketOption(Listener, SocketOptionReceiveTimeout, WaitMilliseconds);
    if ConnectSocket(Client, Loopback6(LocalPortOf(Listener))) <> ErrorInProgress then
      Exit;
    Accepted := AcceptOnSocket(Listener, Peer);
    if (Accepted < 0) or (Peer.Family <> AddressFamilyIPv6) then
      Exit;
    if WaitForSocket(Client, SocketWritable, WaitMilliseconds) <> SocketWritable then
      Exit;
    SetSocketOption(Client, SocketOptionNonBlocking, 0);
    SetSocketOption(Client, SocketOptionReceiveTimeout, WaitMilliseconds);
    SetSocketOption(Accepted, SocketOptionReceiveTimeout, WaitMilliseconds);
    Data := Ord('6');
    if SendAll(Client, @Data, 1) <> ErrorNone then
      Exit;
    Data := 0;
    if (ReceiveOnSocket(Accepted, @Data, 1, 0) <> 1) or (Data <> Ord('6')) then
      Exit;
    Data := Ord('!');
    SendAll(Accepted, @Data, 1);
    Data := 0;
    Result := (ReceiveOnSocket(Client, @Data, 1, 0) = 1) and (Data = Ord('!'));
  finally
    if Accepted >= 0 then
      CloseSocket(Accepted);
    CloseSocket(Client);
    CloseSocket(Listener);
  end;
end;

function DualStackPortWorks: Boolean;
var
  Ipv4Socket: Int64;
  Ipv6Socket: Int64;
  Port: Word;
begin
  Ipv4Socket := CreateSocket(AddressFamilyIPv4, SocketKindStream, ProtocolTcp);
  Ipv6Socket := CreateSocket(AddressFamilyIPv6, SocketKindStream, ProtocolTcp);
  try
    Result := (BindSocket(Ipv4Socket, MakeSocketAddress(AnyIpv4Address, 0)) = ErrorNone);
    Port := LocalPortOf(Ipv4Socket);
    { A dual-stack IPv6 socket would have the IPv4 port too. }
    Result := Result and (SetSocketOption(Ipv6Socket, SocketOptionIpv6Only, 1) = ErrorNone);
    Result := Result and (BindSocket(Ipv6Socket, MakeSocketAddress(AnyIpv6Address, Port)) = ErrorNone);
  finally
    CloseSocket(Ipv4Socket);
    CloseSocket(Ipv6Socket);
  end;
end;

function Ipv6SocketRefusesIpv4: Boolean;
var
  Socket: Int64;
begin
  Socket := CreateSocket(AddressFamilyIPv6, SocketKindDatagram, ProtocolUdp);
  Result := BindSocket(Socket, MakeSocketAddress(LoopbackIpv4Address, 0)) = ErrorAddressFamilyNotSupported;
  CloseSocket(Socket);
end;

function Ipv6ListenerIsListed: Boolean;
var
  Listener: Int64;
  Entries: TSocketInformationList;
  Entry: TAbiSocketInformation;
  Port: Word;
begin
  Result := False;
  Listener := CreateSocket(AddressFamilyIPv6, SocketKindStream, ProtocolTcp);
  try
    if (BindSocket(Listener, MakeSocketAddress(AnyIpv6Address, 0)) <> ErrorNone) or
       (ListenOnSocket(Listener, 1) <> ErrorNone) then
      Exit;
    Port := LocalPortOf(Listener);
    if ListSockets(Entries) <> ErrorNone then
      Exit;
    for Entry in Entries do
      if (Entry.Family = AddressFamilyIPv6) and (Entry.Protocol = ProtocolTcp) and
         (Entry.State = TcpStateListen) and (Entry.LocalAddress.Port = Port) and
         (Entry.LocalAddress.Family = AddressFamilyIPv6) then
        Result := True;
  finally
    CloseSocket(Listener);
  end;
end;

function FindDescription(const Name: string; out Description: TAbiNetworkInterface): Boolean;
begin
  Result := FindNetworkInterface(PChar(Name), Description);
end;

function InterfaceHasIpv6Address(const Name: string; constref Address: TInternetAddress; PrefixLength: LongWord;
  Ready: Boolean): Boolean;
var
  Description: TAbiNetworkInterface;
  Index: LongWord;
begin
  Result := False;
  if not FindDescription(Name, Description) then
    Exit;
  Index := 0;
  while (Index < Description.AddressCount) and (Index < MaximumInterfaceAddresses) do
  begin
    if AddressesAreEqual(InterfaceAddressHost(Description.Addresses[Index]), Address) and
       (Description.Addresses[Index].PrefixLength = PrefixLength) then
      Exit(not Ready or ((Description.Addresses[Index].Flags and InterfaceAddressFlagTentative) = 0));
    Inc(Index);
  end;
end;

function FindIpv6AddressLike(const Name: string; constref Prefix: TInternetAddress; Required, Forbidden: LongWord;
  out Found: TInternetAddress): Boolean;
var
  Description: TAbiNetworkInterface;
  Index: LongWord;
  Entry: TAbiInterfaceAddress;
begin
  Result := False;
  Found := Prefix;
  if not FindDescription(Name, Description) then
    Exit;
  Index := 0;
  while (Index < Description.AddressCount) and (Index < MaximumInterfaceAddresses) do
  begin
    Entry := Description.Addresses[Index];
    Inc(Index);
    if (Entry.Family <> AddressFamilyIPv6) or ((Entry.Flags and InterfaceAddressFlagTentative) <> 0) or
       ((Entry.Flags and Required) <> Required) or ((Entry.Flags and Forbidden) <> 0) or
       not AddressesSharePrefix(InterfaceAddressHost(Entry), Prefix, 64) then
      Continue;
    Found := InterfaceAddressHost(Entry);
    Exit(True);
  end;
end;

function WaitForIpv6AddressLike(const Name: string; constref Prefix: TInternetAddress; Required, Forbidden: LongWord;
  Milliseconds: QWord; out Found: TInternetAddress): Boolean;
var
  Waited: QWord;
begin
  Waited := 0;
  repeat
    if FindIpv6AddressLike(Name, Prefix, Required, Forbidden, Found) then
      Exit(True);
    SleepMilliseconds(PollMilliseconds);
    Waited := Waited + PollMilliseconds;
  until Waited >= Milliseconds;
  Result := False;
end;

function ReadyIpv6AddressesText(const Name: string): string;
var
  Description: TAbiNetworkInterface;
  Index: LongWord;
  Entry: TAbiInterfaceAddress;
begin
  Result := '';
  if not FindDescription(Name, Description) then
    Exit;
  Index := 0;
  while (Index < Description.AddressCount) and (Index < MaximumInterfaceAddresses) do
  begin
    Entry := Description.Addresses[Index];
    Inc(Index);
    if (Entry.Family <> AddressFamilyIPv6) or ((Entry.Flags and InterfaceAddressFlagTentative) <> 0) then
      Continue;
    if Result <> '' then
      Result := Result + ',';
    Result := Result + AddressToText(InterfaceAddressHost(Entry)) + '/' + IntToStr(Entry.PrefixLength);
  end;
end;

function WaitForIpv6Address(const Name: string; constref Address: TInternetAddress; PrefixLength: LongWord;
  Wanted: Boolean; Milliseconds: QWord): Boolean;
var
  Waited: QWord;
begin
  Waited := 0;
  repeat
    if InterfaceHasIpv6Address(Name, Address, PrefixLength, Wanted) = Wanted then
      Exit(True);
    SleepMilliseconds(PollMilliseconds);
    Waited := Waited + PollMilliseconds;
  until Waited >= Milliseconds;
  Result := False;
end;

function HasIpv6DefaultRoute(const Name: string; constref Gateway: TInternetAddress): Boolean;
var
  Routes: TRouteList;
  Route: TAbiRoute;
begin
  Result := False;
  if ListRoutes(Routes) <> ErrorNone then
    Exit;
  for Route in Routes do
    if (Route.Destination.Family = AddressFamilyIPv6) and (Route.Destination.PrefixLength = 0) and
       AddressesAreEqual(RouteGateway(Route), Gateway) and (InterfaceNameToText(Route.InterfaceName) = Name) then
      Exit(True);
end;

function NeighborIsKnown(constref Address: TInternetAddress): Boolean;
var
  Entries: TNeighborEntryList;
  Entry: TAbiNeighborEntry;
  Neighbor: TInternetAddress;
begin
  Result := False;
  if ListNeighbors(Entries) <> ErrorNone then
    Exit;
  for Entry in Entries do
  begin
    Neighbor := AnyIpv6Address;
    Move(Entry.Address[0], Neighbor.Bytes[0], 16);
    if AddressesAreEqual(Neighbor, Address) and (Entry.State <> NeighborStateIncomplete) then
      Exit(True);
  end;
end;

function InterfaceHasIpv6DnsServer(const Name: string; constref Address: TInternetAddress): Boolean;
var
  Description: TAbiNetworkInterface;
  Index: LongWord;
  Server: TInternetAddress;
begin
  Result := False;
  if not FindDescription(Name, Description) then
    Exit;
  Index := 0;
  while (Index < Description.Ipv6DnsServerCount) and (Index < MaximumDnsServers) do
  begin
    Server := AnyIpv6Address;
    Move(Description.Ipv6DnsServers[Index][0], Server.Bytes[0], 16);
    if AddressesAreEqual(Server, Address) then
      Exit(True);
    Inc(Index);
  end;
end;

function InterfaceIpv6ModeIs(const Name: string; Mode: LongWord): Boolean;
var
  Description: TAbiNetworkInterface;
begin
  Result := FindDescription(Name, Description) and (Description.Ipv6Mode = Mode);
end;

function WaitForIpv6Mode(const Name: string; Mode: LongWord; Milliseconds: QWord): Boolean;
var
  Waited: QWord;
begin
  Waited := 0;
  repeat
    if InterfaceIpv6ModeIs(Name, Mode) then
      Exit(True);
    SleepMilliseconds(PollMilliseconds);
    Waited := Waited + PollMilliseconds;
  until Waited >= Milliseconds;
  Result := False;
end;

end.
