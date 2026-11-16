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
  networktest - checks networking

  networktest [--unprivileged]

  As root (run by coretest): the loopback interface and a ping over it;
  UDP echo over loopback (a server thread), the largest datagram and
  one too large, a broadcast refused without SocketOptionBroadcast, a
  port unreachable reported to a connected socket, binding a port twice
  with and without SocketOptionReuseAddress; TCP echo over loopback with
  a megabyte each way (many windows; a sender thread and a server
  thread), a connection refused, a non-blocking connect waited for with
  WaitForSocket, a listener waited for with WaitForHandles, and the
  socket listing. Then the network card: the network setup program
  configures eth0 from /etc/settings/Network.settings (10.0.2.15/24,
  the default route through 10.0.2.2, the DNS server 10.0.2.3), QEMU's
  gateway 10.0.2.2 answers pings and appears in the ARP cache, and a TCP
  connection to 10.0.2.100 port 7 (QEMU forwards it to "cat") echoes.

  --unprivileged (run as an ordinary user): raw sockets, ports below
  1024, binding to an interface and every configuration change are
  refused, while an ICMP echo socket (ping) works.

  Each check prints a line; the exit status is 1 if any failed.
}
program NetworkTest;

{$mode objfpc}
{$pointermath on}

uses
  Abi.SystemCalls,
  Runtime.Memory,
  Runtime.Text,
  Sys.Errors,
  Sys.Format,
  Sys.InternetAddresses,
  Sys.NetworkInterfaces,
  Sys.Objects,
  Sys.Processes,
  Sys.Sockets,
  Sys.Streams,
  Sys.Threads;

const
  WaitMilliseconds = 5000;
  TransferBytes = 1024 * 1024;
  ChunkBytes = 8192;
  EchoServicePort = 7;

var
  Failures: Integer = 0;
  Checks: Integer = 0;

procedure Check(Name: PChar; Passed: Boolean);
begin
  Inc(Checks);
  if Passed then
    WriteFormatted(StandardOutput, 'networktest: pass: %s'#10, [ArgumentText(Name)])
  else
  begin
    WriteFormatted(StandardOutput, 'networktest: FAIL: %s'#10, [ArgumentText(Name)]);
    Inc(Failures);
  end;
  FlushStream(StandardOutput);
end;

function PatternByte(Position: QWord): Byte;
begin
  Result := Byte(Position * 7 + (Position shr 11));
end;

function NewSocket(Kind, Protocol: LongWord): Int64;
begin
  Result := CreateSocket(AddressFamilyIPv4, Kind, Protocol);
end;

function LocalPort(Socket: Int64): Word;
var
  Address: TAbiSocketAddress;
begin
  Result := 0;
  if GetLocalSocketAddress(Socket, Address) = ErrorNone then
    Result := Address.Port;
end;

function Loopback(Port: Word): TAbiSocketAddress;
begin
  Result := MakeSocketAddress(LoopbackIpv4Address, Port);
end;

{ A port on 127.0.0.1 that nobody has bound. }
function ClosedPort(Kind: LongWord): Word;
var
  Socket: Int64;
begin
  Socket := NewSocket(Kind, ProtocolDefault);
  BindSocket(Socket, Loopback(0));
  Result := LocalPort(Socket);
  CloseSocket(Socket);
end;

{ --- ICMP ------------------------------------------------------------------ }

{ Sends Count echo requests to Address; returns how many replies came. }
function Ping(constref Address: TInternetAddress; Count: Integer): Integer;
var
  Socket: Int64;
  Request: array[0..63] of Byte;
  Reply: array[0..1023] of Byte;
  Source: TAbiSocketAddress;
  Sequence: Integer;
  Length: Int64;
begin
  Result := 0;
  Socket := NewSocket(SocketKindDatagram, ProtocolIcmp);
  if Socket < 0 then
    Exit;
  SetSocketOption(Socket, SocketOptionReceiveTimeout, 1000);
  for Sequence := 1 to Count do
  begin
    FillMemory(@Request[0], SizeOf(Request), Byte(Sequence));
    Request[0] := 8;
    Request[1] := 0;
    Request[6] := 0;
    Request[7] := Byte(Sequence);
    if SendSocketTo(Socket, @Request[0], SizeOf(Request), 0, MakeSocketAddress(Address, 0)) <> SizeOf(Request) then
      Continue;
    repeat
      Length := ReceiveSocketFrom(Socket, @Reply[0], SizeOf(Reply), 0, Source);
    until (Length < 0) or ((Length = SizeOf(Request)) and (Reply[0] = 0) and (Reply[7] = Byte(Sequence)));
    if Length = SizeOf(Request) then
      Inc(Result);
  end;
  CloseSocket(Socket);
end;

procedure TestLoopbackInterface;
var
  Description: TAbiNetworkInterface;
  Found: Boolean;
begin
  Found := FindNetworkInterface('lo', Description);
  Check('the loopback interface lo is there', Found);
  Check('lo is up, running and a loopback interface',
    Found and (Description.Flags and (InterfaceFlagUp or InterfaceFlagRunning or InterfaceFlagLoopback) =
      InterfaceFlagUp or InterfaceFlagRunning or InterfaceFlagLoopback));
  Check('lo has 127.0.0.1/8', Found and (Description.AddressCount = 1) and
    AddressesAreEqual(InterfaceAddressHost(Description.Addresses[0]), LoopbackIpv4Address) and
    (Description.Addresses[0].PrefixLength = 8));
  Check('ping 127.0.0.1: three replies', Ping(LoopbackIpv4Address, 3) = 3);
end;

{ --- UDP ------------------------------------------------------------------- }

var
  UdpServerSocket: Int64;

function RunUdpEchoServer(Argument: Pointer): LongInt;
var
  Buffer: array[0..2047] of Byte;
  Source: TAbiSocketAddress;
  Length: Int64;
begin
  repeat
    Length := ReceiveSocketFrom(UdpServerSocket, @Buffer[0], SizeOf(Buffer), 0, Source);
    if Length < 0 then
      Exit(1);
    if (Length = 4) and MemoryIsEqual(@Buffer[0], PChar('quit'), 4) then
      Exit(0);
    SendSocketTo(UdpServerSocket, @Buffer[0], QWord(Length), 0, Source);
  until False;
end;

function UdpRoundTrip(Client: Int64; constref Server: TAbiSocketAddress; Size: LongWord): Boolean;
var
  Sent: array[0..1471] of Byte;
  Received: array[0..2047] of Byte;
  Index: LongWord;
  Source: TAbiSocketAddress;
begin
  for Index := 1 to Size do
    Sent[Index - 1] := PatternByte(Index + Size);
  if SendSocketTo(Client, @Sent[0], Size, 0, Server) <> Size then
    Exit(False);
  Result := (ReceiveSocketFrom(Client, @Received[0], SizeOf(Received), 0, Source) = Size) and
    MemoryIsEqual(@Sent[0], @Received[0], Size) and (Source.Port = Server.Port);
end;

procedure TestUdp;
var
  Client: Int64;
  Server: TAbiSocketAddress;
  Thread: Int64;
  ExitCode: LongInt;
  Large: array[0..1472] of Byte;
  Connected: Int64;
  Buffer: array[0..15] of Byte;
  First: Int64;
  Second: Int64;
  Port: Word;
begin
  UdpServerSocket := NewSocket(SocketKindDatagram, ProtocolDefault);
  Check('a UDP server binds 127.0.0.1', BindSocket(UdpServerSocket, Loopback(0)) = ErrorNone);
  SetSocketOption(UdpServerSocket, SocketOptionReceiveTimeout, WaitMilliseconds);
  Server := Loopback(LocalPort(UdpServerSocket));
  Thread := CreateThread(@RunUdpEchoServer, nil);
  Client := NewSocket(SocketKindDatagram, ProtocolDefault);
  SetSocketOption(Client, SocketOptionReceiveTimeout, WaitMilliseconds);
  Check('UDP echo of 1 byte', UdpRoundTrip(Client, Server, 1));
  Check('UDP echo of 512 bytes', UdpRoundTrip(Client, Server, 512));
  Check('UDP echo of the largest datagram (1472 bytes)', UdpRoundTrip(Client, Server, 1472));
  FillMemory(@Large[0], SizeOf(Large), 1);
  Check('a datagram of 1473 bytes is too long (no fragments are sent)',
    SendSocketTo(Client, @Large[0], 1473, 0, Server) = -ErrorMessageTooLong);
  Check('a broadcast needs SocketOptionBroadcast',
    SendSocketTo(Client, @Large[0], 4, 0, MakeSocketAddress(BroadcastIpv4Address, 9)) = -ErrorAccessDenied);
  SendSocketTo(Client, PChar('quit'), 4, 0, Server);
  Check('the UDP echo server ends', (WaitForThread(Thread, WaitMilliseconds, ExitCode) = 0) and (ExitCode = 0));
  CloseThreadHandle(Thread);
  CloseSocket(Client);
  CloseSocket(UdpServerSocket);

  Connected := NewSocket(SocketKindDatagram, ProtocolDefault);
  SetSocketOption(Connected, SocketOptionReceiveTimeout, WaitMilliseconds);
  ConnectSocket(Connected, Loopback(ClosedPort(SocketKindDatagram)));
  SendOnSocket(Connected, PChar('anyone?'), 7, 0);
  Check('a connected UDP socket hears of the port unreachable',
    ReceiveOnSocket(Connected, @Buffer[0], SizeOf(Buffer), 0) = -ErrorConnectionRefused);
  CloseSocket(Connected);

  First := NewSocket(SocketKindDatagram, ProtocolDefault);
  Second := NewSocket(SocketKindDatagram, ProtocolDefault);
  BindSocket(First, Loopback(0));
  Port := LocalPort(First);
  Check('a UDP port bound twice is in use', BindSocket(Second, Loopback(Port)) = ErrorAddressInUse);
  CloseSocket(First);
  CloseSocket(Second);
  First := NewSocket(SocketKindDatagram, ProtocolDefault);
  Second := NewSocket(SocketKindDatagram, ProtocolDefault);
  SetSocketOption(First, SocketOptionReuseAddress, 1);
  SetSocketOption(Second, SocketOptionReuseAddress, 1);
  BindSocket(First, Loopback(Port));
  Check('with SocketOptionReuseAddress on both it may be shared', BindSocket(Second, Loopback(Port)) = ErrorNone);
  CloseSocket(First);
  CloseSocket(Second);
end;

{ --- TCP ------------------------------------------------------------------- }

var
  TcpListener: Int64;
  TcpClient: Int64;

{ Accepts one connection and sends back everything until the end. }
function RunTcpEchoServer(Argument: Pointer): LongInt;
var
  Connection: Int64;
  Peer: TAbiSocketAddress;
  Buffer: array[0..ChunkBytes - 1] of Byte;
  Length: Int64;
begin
  Connection := AcceptOnSocket(TcpListener, Peer);
  if Connection < 0 then
    Exit(1);
  SetSocketOption(Connection, SocketOptionReceiveTimeout, WaitMilliseconds);
  Result := 0;
  repeat
    Length := ReceiveOnSocket(Connection, @Buffer[0], SizeOf(Buffer), 0);
    if Length < 0 then
      Result := 2
    else if (Length > 0) and (SendAll(Connection, @Buffer[0], QWord(Length)) <> ErrorNone) then
      Result := 3;
  until Length <= 0;
  CloseSocket(Connection);
end;

{ Sends the megabyte, then shuts the sending side. }
function RunTcpSender(Argument: Pointer): LongInt;
var
  Buffer: array[0..ChunkBytes - 1] of Byte;
  Done: QWord;
  Index: QWord;
begin
  Done := 0;
  while Done < TransferBytes do
  begin
    for Index := 0 to ChunkBytes - 1 do
      Buffer[Index] := PatternByte(Done + Index);
    if SendAll(TcpClient, @Buffer[0], ChunkBytes) <> ErrorNone then
      Exit(1);
    Done := Done + ChunkBytes;
  end;
  ShutdownSocket(TcpClient, SocketShutdownSend);
  Result := 0;
end;

{ Reads the echo back; True if all of it came, in order. }
function ReceiveEcho: Boolean;
var
  Buffer: array[0..ChunkBytes - 1] of Byte;
  Received: QWord;
  Length: Int64;
  Index: Int64;
begin
  Received := 0;
  Result := True;
  repeat
    Length := ReceiveOnSocket(TcpClient, @Buffer[0], SizeOf(Buffer), 0);
    if Length < 0 then
      Exit(False);
    for Index := 0 to Length - 1 do
      if Buffer[Index] <> PatternByte(Received + QWord(Index)) then
        Result := False;
    Received := Received + QWord(Length);
  until Length = 0;
  Result := Result and (Received = TransferBytes);
end;

procedure TestTcpEcho;
var
  Server: Int64;
  Sender: Int64;
  ServerCode: LongInt;
  SenderCode: LongInt;
  Peer: TAbiSocketAddress;
begin
  TcpListener := NewSocket(SocketKindStream, ProtocolDefault);
  Check('a TCP listener binds 127.0.0.1', BindSocket(TcpListener, Loopback(0)) = ErrorNone);
  Check('it listens', ListenOnSocket(TcpListener, 4) = ErrorNone);
  SetSocketOption(TcpListener, SocketOptionReceiveTimeout, WaitMilliseconds);
  Server := CreateThread(@RunTcpEchoServer, nil);
  TcpClient := NewSocket(SocketKindStream, ProtocolDefault);
  SetSocketOption(TcpClient, SocketOptionReceiveTimeout, WaitMilliseconds);
  Check('a TCP client connects', ConnectSocket(TcpClient, Loopback(LocalPort(TcpListener))) = ErrorNone);
  Check('its peer is the listener', (GetPeerSocketAddress(TcpClient, Peer) = ErrorNone) and
    (Peer.Port = LocalPort(TcpListener)));
  Sender := CreateThread(@RunTcpSender, nil);
  Check('a megabyte comes back through the TCP echo, in order', ReceiveEcho);
  Check('the sender thread sent it all', (WaitForThread(Sender, WaitMilliseconds, SenderCode) = 0) and
    (SenderCode = 0));
  Check('the echo server saw the end and closed', (WaitForThread(Server, WaitMilliseconds, ServerCode) = 0) and
    (ServerCode = 0));
  CloseThreadHandle(Sender);
  CloseThreadHandle(Server);
  CloseSocket(TcpClient);
  CloseSocket(TcpListener);
end;

procedure TestTcpRefusedAndWaits;
var
  Client: Int64;
  Listener: Int64;
  Accepted: Int64;
  Peer: TAbiSocketAddress;
  Error: Int64;
  Entries: TSocketInformationList;
  Index: Integer;
  Listed: Boolean;
begin
  Client := NewSocket(SocketKindStream, ProtocolDefault);
  Check('a connection to a closed port is refused',
    ConnectSocket(Client, Loopback(ClosedPort(SocketKindStream))) = ErrorConnectionRefused);
  CloseSocket(Client);

  Listener := NewSocket(SocketKindStream, ProtocolDefault);
  BindSocket(Listener, Loopback(0));
  ListenOnSocket(Listener, 2);
  Check('nothing to accept yet: the listener is not ready', WaitForHandles([Listener], 0) = -ErrorTimedOut);
  Client := NewSocket(SocketKindStream or SocketKindNonBlocking, ProtocolDefault);
  Check('a non-blocking connect is under way',
    ConnectSocket(Client, Loopback(LocalPort(Listener))) = ErrorInProgress);
  Check('it becomes writable once connected',
    WaitForSocket(Client, SocketWritable, WaitMilliseconds) = SocketWritable);
  Check('and reports no error', (GetSocketOption(Client, SocketOptionError, Error) = ErrorNone) and (Error = 0));
  Check('the listener is ready to accept (WaitForHandles)', WaitForHandles([Listener], WaitMilliseconds) = 0);
  Accepted := AcceptOnSocket(Listener, Peer);
  Check('the connection is accepted', Accepted >= 0);
  Listed := False;
  if ListSockets(Entries) = ErrorNone then
    for Index := 0 to High(Entries) do
      if (Entries[Index].Protocol = ProtocolTcp) and (Entries[Index].State = TcpStateListen) and
         (Entries[Index].LocalAddress.Port = LocalPort(Listener)) then
        Listed := True;
  Check('the socket listing shows the listener', Listed);
  CloseSocket(Accepted);
  CloseSocket(Client);
  CloseSocket(Listener);
end;

{ --- The network card -------------------------------------------------------- }

function RunNetworkSetup: LongInt;
var
  Arguments: array[0..1] of PChar;
  Options: TProcessOptions;
  Process: Int64;
begin
  Arguments[0] := 'networksetup';
  Arguments[1] := nil;
  DefaultProcessOptions(Options);
  Process := StartProgram('/bin/networksetup', @Arguments[0], Options);
  if Process < 0 then
    Exit(LongInt(Process));
  Result := WaitForProgram(Process);
end;

function HasDefaultRouteThrough(constref Gateway: TInternetAddress): Boolean;
var
  Routes: TRouteList;
  Index: Integer;
begin
  Result := False;
  if ListRoutes(Routes) <> ErrorNone then
    Exit;
  for Index := 0 to High(Routes) do
    if (Routes[Index].Destination.PrefixLength = 0) and
       MemoryIsEqual(@Routes[Index].Gateway[0], @Gateway.Bytes[0], 4) and
       TextIsEqual(@Routes[Index].InterfaceName[0], 'eth0') then
      Exit(True);
end;

function GatewayIsInArpCache(constref Gateway: TInternetAddress): Boolean;
var
  Entries: TArpEntryList;
  Index: Integer;
begin
  Result := False;
  if ListArpEntries(Entries) <> ErrorNone then
    Exit;
  for Index := 0 to High(Entries) do
    if MemoryIsEqual(@Entries[Index].Address[0], @Gateway.Bytes[0], 4) and
       (Entries[Index].State = ArpStateReachable) then
      Exit(True);
end;

function EchoServiceAnswers: Boolean;
const
  Message: PChar = 'hello network'#10;
var
  Socket: Int64;
  Buffer: array[0..63] of Byte;
  Received: Int64;
  Length: Int64;
begin
  Result := False;
  Socket := NewSocket(SocketKindStream, ProtocolDefault);
  SetSocketOption(Socket, SocketOptionSendTimeout, WaitMilliseconds);
  SetSocketOption(Socket, SocketOptionReceiveTimeout, WaitMilliseconds);
  if ConnectSocket(Socket, MakeSocketAddress(Ipv4Address(10, 0, 2, 100), EchoServicePort)) <> ErrorNone then
  begin
    CloseSocket(Socket);
    Exit;
  end;
  if SendAll(Socket, Message, TextLength(Message)) = ErrorNone then
  begin
    Received := 0;
    repeat
      Length := ReceiveOnSocket(Socket, @Buffer[Received], QWord(SizeOf(Buffer) - Received), 0);
      if Length > 0 then
        Received := Received + Length;
    until (Length <= 0) or (Received >= Int64(TextLength(Message)));
    Result := (Received = Int64(TextLength(Message))) and MemoryIsEqual(@Buffer[0], Message, Received);
  end;
  CloseSocket(Socket);
end;

procedure TestNetworkCard;
var
  Description: TAbiNetworkInterface;
  Gateway: TInternetAddress;
  Servers: TAbiDnsServers;
begin
  if not FindNetworkInterface('eth0', Description) then
  begin
    Check('there is a network card (eth0)', False);
    Exit;
  end;
  Gateway := Ipv4Address(10, 0, 2, 2);
  Check('networksetup applies /etc/settings/Network.settings', RunNetworkSetup = 0);
  Check('eth0 is up with 10.0.2.15/24', FindNetworkInterface('eth0', Description) and
    ((Description.Flags and InterfaceFlagUp) <> 0) and (Description.AddressCount = 1) and
    AddressesAreEqual(InterfaceAddressHost(Description.Addresses[0]), Ipv4Address(10, 0, 2, 15)) and
    (Description.Addresses[0].PrefixLength = 24));
  Check('the default route goes through 10.0.2.2 on eth0', HasDefaultRouteThrough(Gateway));
  Check('the DNS server is 10.0.2.3', (GetDnsServers(Servers) = ErrorNone) and (Servers.Count = 1) and
    AddressesAreEqual(SocketAddressHost(Servers.Servers[0]), Ipv4Address(10, 0, 2, 3)));
  Check('ping 10.0.2.2 (QEMU''s gateway) answers', Ping(Gateway, 3) > 0);
  Check('10.0.2.2 is in the ARP cache', GatewayIsInArpCache(Gateway));
  Check('ping 10.0.2.15 (our own address) answers', Ping(Ipv4Address(10, 0, 2, 15), 1) = 1);
  Check('a TCP connection to 10.0.2.100 port 7 echoes', EchoServiceAnswers);
  Check('eth0 counted what went through it', FindNetworkInterface('eth0', Description) and
    (Description.Counters.ReceivedPackets > 0) and (Description.Counters.SentPackets > 0));
end;

{ --- What an ordinary user may not do ------------------------------------------ }

procedure TestUnprivileged;
var
  Socket: Int64;
  Servers: TAbiDnsServers;
begin
  Check('a raw ICMP socket is root''s',
    NewSocket(SocketKindRaw, ProtocolIcmp) = -ErrorNotPermitted);
  Socket := NewSocket(SocketKindStream, ProtocolDefault);
  Check('binding a port below 1024 is root''s', BindSocket(Socket, Loopback(80)) = ErrorAccessDenied);
  Check('binding to an interface is root''s',
    SetSocketOption(Socket, SocketOptionInterface, 1) = ErrorNotPermitted);
  CloseSocket(Socket);
  Check('an ICMP echo socket is anyone''s: ping 127.0.0.1 answers', Ping(LoopbackIpv4Address, 1) = 1);
  Check('turning an interface off is root''s', SetInterfaceUp('lo', False) = ErrorNotPermitted);
  Check('giving an interface an address is root''s',
    SetInterfaceAddress('lo', Ipv4Address(127, 0, 0, 2), 8) = ErrorNotPermitted);
  Check('adding a route is root''s',
    AddRoute(Ipv4Address(10, 9, 0, 0), 16, AnyIpv4Address, 'lo', 0) = ErrorNotPermitted);
  FillMemory(@Servers, SizeOf(Servers), 0);
  Check('setting the DNS servers is root''s', SetDnsServers(Servers) = ErrorNotPermitted);
end;

begin
  if (ParamCount = 1) and TextIsEqual(PChar(ParamStr(1)), '--unprivileged') then
    TestUnprivileged
  else
  begin
    TestLoopbackInterface;
    TestUdp;
    TestTcpEcho;
    TestTcpRefusedAndWaits;
    TestNetworkCard;
  end;
  WriteFormatted(StandardOutput, 'networktest: %d of %d checks passed'#10, [ArgumentNumber(Checks - Failures),
    ArgumentNumber(Checks)]);
  if Failures > 0 then
    Halt(1);
end.
