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
  Self tests of the network layer, on every boot, over the loopback
  interface only (no hardware needed):

    * the Internet checksum of RFC 1071's example, and of an odd length;
    * TCP sequence numbers compared across the wrap;
    * a UDP datagram sent to a socket on 127.0.0.1 arrives with its
      source;
    * TCP: a connection to a port nobody listens on is refused (the
      reset); a listener accepts a connection (the three-way handshake:
      SYN_SENT, then ESTABLISHED on both sides), data goes both ways,
      and closing one side brings the other to CLOSE_WAIT and the end
      of its stream, then LAST_ACK and gone, while the closing side
      goes through FIN_WAIT to TIME_WAIT.
}
unit Kernel.NetworkSelfTest;

{$mode objfpc}

interface

procedure RunNetworkSelfTests;

implementation

uses
  Abi.SystemCalls,
  Runtime.Memory,
  Kernel.Scheduler,
  Objects.Manager,
  Runtime.Text,
  Io.NetworkAdapters,
  Network.Addresses,
  Network.Ipv6Addresses,
  Network.Checksums,
  Network.Core,
  Network.Sockets,
  Network.SocketOperations,
  Network.TcpTypes,
  Kernel.SelfTest;

const
  TimeoutMilliseconds = 5000;
  PollMilliseconds = 2;

procedure TestChecksums;
const
  Example: array[0..7] of Byte = ($00, $01, $F2, $03, $F4, $F5, $F6, $F7);
  OddLength: array[0..2] of Byte = ($01, $02, $03);
begin
  Check(InternetChecksum(@Example[0], 8) = $220D, 'Internet checksum of the RFC 1071 example');
  { $0102 + $0300 = $0402, inverted. }
  Check(InternetChecksum(@OddLength[0], 3) = $FBFD, 'Internet checksum of an odd length');
  Check(SequenceBefore($FFFFFFF0, $00000010), 'sequence numbers compared across the wrap');
  Check(SequenceAfter($00000010, $FFFFFFF0), 'sequence numbers after the wrap');
  Check(not SequenceBefore(5, 5) and SequenceBeforeOrEqual(5, 5), 'equal sequence numbers');
  ReportPassed('network checksums and sequence numbers');
end;

{ The kernel's own sockets belong to root and to no process. }
function KernelOwner: TSocketOwner;
begin
  Result.UserId := 0;
  Result.ProcessId := 0;
end;

function NewSocketOf(Family: Word; Kind: LongWord): PSocket;
begin
  Check(CreateSocket(Family, Kind, ProtocolDefault, KernelOwner, True, Result) = ErrorNone, 'a socket is made');
end;

function NewSocket(Kind: LongWord): PSocket;
begin
  Result := NewSocketOf(AddressFamilyIPv4, Kind);
end;

function TcpStateOf(Socket: PSocket): TTcpState;
begin
  LockNetwork;
  if Socket^.Connection = nil then
    Result := TcpClosed
  else
    Result := PTcpConnection(Socket^.Connection)^.State;
  UnlockNetwork;
end;

{ Waits (the network thread does the work) until Socket's connection is
  in State. }
function WaitForTcpState(Socket: PSocket; State: TTcpState): Boolean;
var
  Waited: LongWord;
begin
  Waited := 0;
  while TcpStateOf(Socket) <> State do
  begin
    if Waited >= TimeoutMilliseconds then
      Exit(False);
    SleepMilliseconds(PollMilliseconds);
    Waited := Waited + PollMilliseconds;
  end;
  Result := True;
end;

procedure TestUdp;
var
  Receiver: PSocket;
  Sender: PSocket;
  Bound: TNetworkEndpoint;
  Source: TNetworkEndpoint;
  Text: array[0..15] of Byte;
  Received: Int64;
begin
  Receiver := NewSocket(SocketKindDatagram);
  Sender := NewSocket(SocketKindDatagram);
  Check(BindSocket(Receiver, MakeEndpoint(LoopbackAddress, 0), True) = ErrorNone, 'a UDP socket binds');
  Check(GetSocketEndpoint(Receiver, SocketAddressLocal, Bound) = ErrorNone, 'its address is known');
  Check(SetSocketOption(Receiver, SocketOptionReceiveTimeout, TimeoutMilliseconds, True) = ErrorNone,
    'a receive timeout is set');
  Text[0] := Ord('u');
  Text[1] := Ord('d');
  Text[2] := Ord('p');
  Check(SendOnSocket(Sender, @Text[0], 3, 0, @Bound) = 3, 'a UDP datagram is sent over lo');
  FillMemory(@Text[0], SizeOf(Text), 0);
  Received := ReceiveOnSocket(Receiver, @Text[0], SizeOf(Text), 0, Source);
  Check((Received = 3) and (Text[0] = Ord('u')) and (Text[2] = Ord('p')), 'the UDP datagram arrives');
  Check(Source.Address = LoopbackAddress, 'with the sender''s address');
  DereferenceObject(Sender);
  DereferenceObject(Receiver);
  ReportPassed('network UDP over loopback');
end;

procedure TestRefusedConnection;
var
  Client: PSocket;
  Unused: PSocket;
  Closed: TNetworkEndpoint;
begin
  { A port nobody has: bind one, then let it go. }
  Unused := NewSocket(SocketKindStream);
  Check(BindSocket(Unused, MakeEndpoint(LoopbackAddress, 0), True) = ErrorNone, 'a TCP socket binds');
  GetSocketEndpoint(Unused, SocketAddressLocal, Closed);
  DereferenceObject(Unused);
  Client := NewSocket(SocketKindStream);
  SetSocketOption(Client, SocketOptionSendTimeout, TimeoutMilliseconds, True);
  Check(ConnectSocket(Client, Closed) = ErrorConnectionRefused, 'a connection to a closed port is refused');
  DereferenceObject(Client);
  ReportPassed('network TCP connection refused');
end;

procedure TestTcpConnection;
var
  Listener: PSocket;
  Client: PSocket;
  Server: PSocket;
  Address: TNetworkEndpoint;
  Peer: TNetworkEndpoint;
  Source: TNetworkEndpoint;
  Data: array[0..63] of Byte;
  Count: Int64;
begin
  Listener := NewSocket(SocketKindStream);
  Check(BindSocket(Listener, MakeEndpoint(LoopbackAddress, 0), True) = ErrorNone, 'a listener binds');
  Check(ListenOnSocket(Listener, 4) = ErrorNone, 'it listens');
  Check(TcpStateOf(Listener) = TcpListen, 'in LISTEN');
  GetSocketEndpoint(Listener, SocketAddressLocal, Address);
  SetSocketOption(Listener, SocketOptionReceiveTimeout, TimeoutMilliseconds, True);

  Client := NewSocket(SocketKindStream or SocketKindNonBlocking);
  Check(ConnectSocket(Client, Address) = ErrorInProgress, 'a non-blocking connect is under way');
  Check(TcpStateOf(Client) in [TcpSynSent, TcpEstablished], 'the client sent its SYN');
  Check(AcceptOnSocket(Listener, KernelOwner, Server, Peer) = ErrorNone, 'the listener accepts the connection');
  Check(Peer.Address = LoopbackAddress, 'from 127.0.0.1');
  Check(WaitForTcpState(Client, TcpEstablished), 'the client is ESTABLISHED');
  Check(TcpStateOf(Server) = TcpEstablished, 'the server side is ESTABLISHED');
  SetSocketOption(Client, SocketOptionNonBlocking, 0, True);
  SetSocketOption(Client, SocketOptionReceiveTimeout, TimeoutMilliseconds, True);
  SetSocketOption(Server, SocketOptionReceiveTimeout, TimeoutMilliseconds, True);

  Data[0] := Ord('h');
  Data[1] := Ord('i');
  Check(SendOnSocket(Client, @Data[0], 2, 0, nil) = 2, 'the client sends');
  FillMemory(@Data[0], SizeOf(Data), 0);
  Count := ReceiveOnSocket(Server, @Data[0], SizeOf(Data), 0, Source);
  Check((Count = 2) and (Data[0] = Ord('h')) and (Data[1] = Ord('i')), 'the server receives it');
  Data[0] := Ord('o');
  Check(SendOnSocket(Server, @Data[0], 1, 0, nil) = 1, 'the server answers');
  Count := ReceiveOnSocket(Client, @Data[0], SizeOf(Data), 0, Source);
  Check((Count = 1) and (Data[0] = Ord('o')), 'the client receives the answer');

  { The client closes its side: FIN, the server sees the end. }
  Check(ShutdownSocket(Client, SocketShutdownSend) = ErrorNone, 'the client shuts its side');
  Check(WaitForTcpState(Server, TcpCloseWait), 'the server goes to CLOSE_WAIT');
  Count := ReceiveOnSocket(Server, @Data[0], SizeOf(Data), 0, Source);
  Check(Count = 0, 'the server reads the end of the stream');
  Check(WaitForTcpState(Client, TcpFinWait2), 'the client waits in FIN_WAIT_2');
  { The server closes: LAST_ACK, then the client reaches TIME_WAIT. }
  DereferenceObject(Server);
  Check(WaitForTcpState(Client, TcpTimeWait), 'the client reaches TIME_WAIT');
  Count := ReceiveOnSocket(Client, @Data[0], SizeOf(Data), 0, Source);
  Check(Count = 0, 'the client reads the end of the stream');
  DereferenceObject(Client);
  DereferenceObject(Listener);
  ReportPassed('network TCP handshake, data and close over loopback');
end;

procedure TestIpv6Addresses;
const
  Hardware: TEthernetAddress = ($52, $54, $00, $12, $34, $56);
  ExpectedLinkLocal: TIpv6Address = ($FE, $80, 0, 0, 0, 0, 0, 0, $50, $54, $00, $FF, $FE, $12, $34, $56);
  ExpectedSolicited: TIpv6Address = ($FF, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, $FF, $12, $34, $56);
var
  LinkLocal: TIpv6Address;
  Text: array[0..Ipv6AddressTextCapacity - 1] of Char;
  Group: TEthernetAddress;
begin
  LinkLocal := LinkLocalAddressFor(Hardware);
  Check(Ipv6AddressesEqual(LinkLocal, ExpectedLinkLocal), 'the EUI-64 link-local address of 52:54:00:12:34:56');
  Check(Ipv6AddressesEqual(SolicitedNodeAddress(LinkLocal), ExpectedSolicited), 'its solicited-node group');
  Group := MulticastEthernetAddress(ExpectedSolicited);
  Check((Group[0] = $33) and (Group[1] = $33) and (Group[2] = $FF) and (Group[5] = $56),
    'the group''s Ethernet address');
  FormatIpv6Address(LinkLocal, @Text[0]);
  Check(TextIsEqual(@Text[0], 'fe80::5054:ff:fe12:3456'), 'an IPv6 address written as RFC 5952 says');
  FormatIpv6Address(LoopbackIpv6Address, @Text[0]);
  Check(TextIsEqual(@Text[0], '::1'), '::1 written');
  Check(CommonIpv6PrefixLength(LinkLocal, ExpectedSolicited) = 7, 'the common prefix of two addresses');
  Check(SameIpv6Prefix(LinkLocal, Ipv6PrefixOf(LinkLocal, 64), 64), 'an address shares its own prefix');
  ReportPassed('network IPv6 addresses');
end;

procedure TestIpv6Loopback;
var
  Receiver: PSocket;
  Sender: PSocket;
  Listener: PSocket;
  Client: PSocket;
  Server: PSocket;
  Bound: TNetworkEndpoint;
  Source: TNetworkEndpoint;
  Peer: TNetworkEndpoint;
  Text: array[0..15] of Byte;
begin
  Receiver := NewSocketOf(AddressFamilyIPv6, SocketKindDatagram);
  Sender := NewSocketOf(AddressFamilyIPv6, SocketKindDatagram);
  Check(BindSocket(Receiver, LoopbackEndpoint(AddressFamilyIPv6, 0), True) = ErrorNone, 'a UDP socket binds ::1');
  Check(BindSocket(Sender, MakeEndpoint(LoopbackAddress, 0), True) = ErrorAddressFamilyNotSupported,
    'an IPv6 socket takes no IPv4 address');
  GetSocketEndpoint(Receiver, SocketAddressLocal, Bound);
  SetSocketOption(Receiver, SocketOptionReceiveTimeout, TimeoutMilliseconds, True);
  Text[0] := Ord('v');
  Text[1] := Ord('6');
  Check(SendOnSocket(Sender, @Text[0], 2, 0, @Bound) = 2, 'a UDP datagram is sent to ::1');
  FillMemory(@Text[0], SizeOf(Text), 0);
  Check((ReceiveOnSocket(Receiver, @Text[0], SizeOf(Text), 0, Source) = 2) and (Text[1] = Ord('6')),
    'the UDP datagram arrives over IPv6');
  Check((Source.Family = AddressFamilyIPv6) and IsLoopbackIpv6Address(Source.Address6), 'from ::1');
  DereferenceObject(Sender);
  DereferenceObject(Receiver);

  Listener := NewSocketOf(AddressFamilyIPv6, SocketKindStream);
  Check(BindSocket(Listener, UnspecifiedEndpoint(AddressFamilyIPv6), True) = ErrorNone, 'a TCP listener binds ::');
  Check(ListenOnSocket(Listener, 2) = ErrorNone, 'it listens');
  GetSocketEndpoint(Listener, SocketAddressLocal, Bound);
  SetSocketOption(Listener, SocketOptionReceiveTimeout, TimeoutMilliseconds, True);
  Client := NewSocketOf(AddressFamilyIPv6, SocketKindStream);
  SetSocketOption(Client, SocketOptionSendTimeout, TimeoutMilliseconds, True);
  Check(ConnectSocket(Client, LoopbackEndpoint(AddressFamilyIPv6, Bound.Port)) = ErrorNone,
    'a TCP connection to [::1] is made');
  Check(AcceptOnSocket(Listener, KernelOwner, Server, Peer) = ErrorNone, 'and accepted');
  Check((Peer.Family = AddressFamilyIPv6) and IsLoopbackIpv6Address(Peer.Address6), 'from ::1');
  DereferenceObject(Server);
  DereferenceObject(Client);
  DereferenceObject(Listener);
  ReportPassed('network UDP and TCP over IPv6 loopback');
end;

procedure RunNetworkSelfTests;
begin
  TestChecksums;
  TestUdp;
  TestRefusedConnection;
  TestTcpConnection;
  TestIpv6Addresses;
  TestIpv6Loopback;
end;

end.
