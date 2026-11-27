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
  multicasttest - checks multicast sockets, v4-mapped addresses and
  IPv6 fragments over the loopback interface

  multicasttest

  Run by coretest. Multicast: a UDP socket joins 239.1.2.3 (IPv4) and
  ff12::1:2 (IPv6) on lo, another sends to the group with lo as its
  multicast interface, and the datagram arrives; joining twice, leaving
  a group not joined and joining a unicast address are refused. v4-mapped:
  an IPv6 UDP socket on :: receives IPv4 datagrams from ::ffff:127.0.0.1,
  an IPv6 TCP listener on :: accepts an IPv4 connection whose peer is
  ::ffff:127.0.0.1, an IPv6 socket connects to ::ffff:127.0.0.1, and
  SocketOptionIpv6Only decides whether an IPv4 socket may share the
  port. Fragments: a 4000-byte UDP datagram to ::1 arrives whole.

  Each check prints a line; the exit status is 1 if any failed.
}
program MulticastTest;

{$mode objfpc}
{$H+}

uses
  SysUtils,
  Abi.SystemCalls,
  Sys.InternetAddresses,
  Sys.Sockets;

const
  LoopbackIndex = 1;
  WaitMilliseconds = 3000;

var
  Checks: Integer = 0;
  Failures: Integer = 0;

procedure Check(const Name: string; Passed: Boolean);
begin
  Inc(Checks);
  if Passed then
    WriteLn('ok: ', Name)
  else
  begin
    Inc(Failures);
    WriteLn('FAIL: ', Name);
  end;
end;

function Address(const Text: string): TInternetAddress;
begin
  if not TextToAddress(Text, Result) then
    raise Exception.Create('bad address ' + Text);
end;

function OpenUdp(Family: Word): Int64;
begin
  Result := CreateSocket(Family, SocketKindDatagram, ProtocolUdp);
  SetSocketOption(Result, SocketOptionReceiveTimeout, WaitMilliseconds);
end;

function LocalPort(Socket: Int64): Word;
var
  Local: TAbiSocketAddress;
begin
  Result := 0;
  if GetLocalSocketAddress(Socket, Local) = ErrorNone then
    Result := Local.Port;
end;

{ Binds Socket to the unspecified address of its family, port 0. }
function BindAny(Socket: Int64; Family: Word; Port: Word): LongInt;
begin
  if Family = AddressFamilyIPv6 then
    Result := BindSocket(Socket, MakeSocketAddress(AnyIpv6Address, Port))
  else
    Result := BindSocket(Socket, MakeSocketAddress(AnyIpv4Address, Port));
end;

function SendText(Socket: Int64; const Text: string; constref Target: TAbiSocketAddress): Boolean;
begin
  Result := SendSocketTo(Socket, @Text[1], Length(Text), 0, Target) = Length(Text);
end;

function ReceiveText(Socket: Int64; out Source: TAbiSocketAddress): string;
var
  Buffer: array[0..255] of Char;
  Count: Int64;
begin
  Result := '';
  Count := ReceiveSocketFrom(Socket, @Buffer[0], SizeOf(Buffer), 0, Source);
  if Count > 0 then
    SetString(Result, PChar(@Buffer[0]), Count);
end;

procedure CheckGroup(Family: Word; const GroupText: string);
var
  Receiver: Int64;
  Sender: Int64;
  Group: TInternetAddress;
  Unicast: TInternetAddress;
  Hops: Int64;
  Source: TAbiSocketAddress;
  Name: string;
begin
  Name := GroupText + ': ';
  Group := Address(GroupText);
  Receiver := OpenUdp(Family);
  Sender := OpenUdp(Family);
  try
    Check(Name + 'the receiver binds', BindAny(Receiver, Family, 0) = ErrorNone);
    Check(Name + 'it joins the group on lo',
      ChangeMulticastMembership(Receiver, True, Family, @Group.Bytes[0], LoopbackIndex) = ErrorNone);
    Check(Name + 'joining twice is refused',
      ChangeMulticastMembership(Receiver, True, Family, @Group.Bytes[0], LoopbackIndex) = ErrorAddressInUse);
    if Family = AddressFamilyIPv6 then
      Unicast := LoopbackIpv6Address
    else
      Unicast := Address('127.0.0.1');
    Check(Name + 'a unicast address is no group',
      ChangeMulticastMembership(Receiver, True, Family, @Unicast.Bytes[0], LoopbackIndex) = ErrorInvalidArgument);
    Check(Name + 'the hop limit of multicast is 1 at first',
      (GetSocketOption(Sender, SocketOptionMulticastHops, Hops) = ErrorNone) and (Hops = 1));
    Check(Name + 'the sender sends on lo',
      SetSocketOption(Sender, SocketOptionMulticastInterface, LoopbackIndex) = ErrorNone);
    Check(Name + 'a datagram goes to the group',
      SendText(Sender, 'to the group', MakeSocketAddress(Group, LocalPort(Receiver))));
    Check(Name + 'the member receives it', ReceiveText(Receiver, Source) = 'to the group');
    Check(Name + 'leaving works',
      ChangeMulticastMembership(Receiver, False, Family, @Group.Bytes[0], LoopbackIndex) = ErrorNone);
    Check(Name + 'leaving again is refused',
      ChangeMulticastMembership(Receiver, False, Family, @Group.Bytes[0], LoopbackIndex) = ErrorNotFound);
  finally
    CloseSocket(Receiver);
    CloseSocket(Sender);
  end;
end;

procedure CheckMappedDatagrams;
var
  Receiver: Int64;
  Sender: Int64;
  Source: TAbiSocketAddress;
begin
  Receiver := OpenUdp(AddressFamilyIPv6);
  Sender := OpenUdp(AddressFamilyIPv4);
  try
    Check('an IPv6 UDP socket binds ::', BindAny(Receiver, AddressFamilyIPv6, 0) = ErrorNone);
    Check('an IPv4 datagram is sent to its port',
      SendText(Sender, 'from v4', MakeSocketAddress(Address('127.0.0.1'), LocalPort(Receiver))));
    Check('the IPv6 socket receives it', ReceiveText(Receiver, Source) = 'from v4');
    Check('from ::ffff:127.0.0.1', (Source.Family = AddressFamilyIPv6) and
      (AddressToText(SocketAddressHost(Source)) = '::ffff:127.0.0.1'));
    Check('and answers there', SendText(Receiver, 'back', Source));
    Check('the IPv4 socket gets the answer', ReceiveText(Sender, Source) = 'back');
  finally
    CloseSocket(Receiver);
    CloseSocket(Sender);
  end;
end;

procedure CheckMappedStream;
var
  Listener: Int64;
  Client: Int64;
  Server: Int64;
  Peer: TAbiSocketAddress;
  Local: TAbiSocketAddress;
  Ipv6Client: Int64;
begin
  Listener := CreateSocket(AddressFamilyIPv6, SocketKindStream, ProtocolTcp);
  Client := CreateSocket(AddressFamilyIPv4, SocketKindStream, ProtocolTcp);
  Ipv6Client := CreateSocket(AddressFamilyIPv6, SocketKindStream, ProtocolTcp);
  Server := -1;
  try
    Check('an IPv6 listener on ::', (BindAny(Listener, AddressFamilyIPv6, 0) = ErrorNone) and
      (ListenOnSocket(Listener, 4) = ErrorNone));
    Check('an IPv4 client connects to it',
      ConnectSocket(Client, MakeSocketAddress(Address('127.0.0.1'), LocalPort(Listener))) = ErrorNone);
    Server := AcceptOnSocket(Listener, Peer);
    Check('the listener accepts it', Server >= 0);
    Check('its peer is ::ffff:127.0.0.1', AddressToText(SocketAddressHost(Peer)) = '::ffff:127.0.0.1');
    Check('an IPv6 socket connects to ::ffff:127.0.0.1',
      ConnectSocket(Ipv6Client, MakeSocketAddress(Address('::ffff:127.0.0.1'), LocalPort(Listener))) = ErrorNone);
    Check('from a v4-mapped address of its own', (GetLocalSocketAddress(Ipv6Client, Local) = ErrorNone) and
      (AddressToText(SocketAddressHost(Local)) = '::ffff:127.0.0.1'));
  finally
    if Server >= 0 then
      CloseSocket(Server);
    CloseSocket(Ipv6Client);
    CloseSocket(Client);
    CloseSocket(Listener);
  end;
end;

procedure CheckIpv6Only;
var
  Dual: Int64;
  Ipv4: Int64;
  Only: Int64;
  Value: Int64;
  Port: Word;
begin
  Dual := CreateSocket(AddressFamilyIPv6, SocketKindStream, ProtocolTcp);
  Ipv4 := CreateSocket(AddressFamilyIPv4, SocketKindStream, ProtocolTcp);
  Only := CreateSocket(AddressFamilyIPv6, SocketKindStream, ProtocolTcp);
  try
    Check('IPv6-only is off at first', (GetSocketOption(Dual, SocketOptionIpv6Only, Value) = ErrorNone) and
      (Value = 0));
    BindAny(Dual, AddressFamilyIPv6, 0);
    Port := LocalPort(Dual);
    Check('an IPv4 socket cannot share the port of :: (dual stack)',
      BindAny(Ipv4, AddressFamilyIPv4, Port) = ErrorAddressInUse);
    CloseSocket(Dual);
    Dual := -1;
    Check('an IPv4 socket binds the port alone', BindAny(Ipv4, AddressFamilyIPv4, Port) = ErrorNone);
    Check('IPv6-only is set', SetSocketOption(Only, SocketOptionIpv6Only, 1) = ErrorNone);
    Check('an IPv6-only socket shares the port with it', BindAny(Only, AddressFamilyIPv6, Port) = ErrorNone);
    Check('an IPv6-only socket cannot reach ::ffff:127.0.0.1',
      ConnectSocket(Only, MakeSocketAddress(Address('::ffff:127.0.0.1'), Port)) = ErrorNetworkUnreachable);
  finally
    if Dual >= 0 then
      CloseSocket(Dual);
    CloseSocket(Ipv4);
    CloseSocket(Only);
  end;
end;

procedure CheckFragments;
const
  DatagramBytes = 4000;
var
  Receiver: Int64;
  Sender: Int64;
  Sent: array[0..DatagramBytes - 1] of Byte;
  Received: array[0..DatagramBytes + 99] of Byte;
  Source: TAbiSocketAddress;
  Count: Int64;
  Index: Integer;
begin
  for Index := 0 to DatagramBytes - 1 do
    Sent[Index] := Byte(Index * 13);
  Receiver := OpenUdp(AddressFamilyIPv6);
  Sender := OpenUdp(AddressFamilyIPv6);
  try
    BindSocket(Receiver, MakeSocketAddress(LoopbackIpv6Address, 0));
    Check('a 4000-byte datagram is sent to ::1 (in fragments)', SendSocketTo(Sender, @Sent[0], DatagramBytes, 0,
      MakeSocketAddress(LoopbackIpv6Address, LocalPort(Receiver))) = DatagramBytes);
    Count := ReceiveSocketFrom(Receiver, @Received[0], SizeOf(Received), 0, Source);
    Check('it arrives whole', (Count = DatagramBytes) and CompareMem(@Sent[0], @Received[0], DatagramBytes));
  finally
    CloseSocket(Receiver);
    CloseSocket(Sender);
  end;
end;

begin
  CheckGroup(AddressFamilyIPv4, '239.1.2.3');
  CheckGroup(AddressFamilyIPv6, 'ff12::1:2');
  CheckMappedDatagrams;
  CheckMappedStream;
  CheckIpv6Only;
  CheckFragments;
  WriteLn(Format('multicasttest: %d of %d checks passed', [Checks - Failures, Checks]));
  if Failures > 0 then
    Halt(1);
end.
