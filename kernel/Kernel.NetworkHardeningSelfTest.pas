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
  Self tests of the network stack's defences, on every boot, with
  crafted datagrams (Kernel.NetworkPacketCrafting) handed to the stack
  as an interface would:

    * 127.0.0.0/8 and ::1 only from lo: a SYN to a listener on
      127.0.0.1 or ::1 that comes in on an Ethernet interface makes no
      connection (one that comes in on lo does); a datagram from a
      loopback source or from the subnet's broadcast address is not
      delivered; an interface without an address takes no unicast UDP
      but the DHCP client's;
    * a listener's children get no buffers before the handshake
      completes, and a flood of SYNs pushes out half-open children
      rather than growing past the backlog;
    * RFC 5961: a SYN and an in-window reset leave an established
      connection be, and data with an acknowledgment older than the
      peer's largest window is not taken; an ICMP "fragmentation needed"
      quoting a sequence number not in flight does not lower the MSS;
    * RFC 5722: overlapping IPv6 fragments give up the datagram, exact
      duplicates are dropped alone, and a first fragment without the
      whole header chain is refused;
    * router advertisements do not touch a route made by hand;
    * a user other than root has a bounded share of network change
      watchers and multicast memberships.
}
unit Kernel.NetworkHardeningSelfTest;

{$mode objfpc}
{$pointermath on}

interface

procedure RunNetworkHardeningSelfTests;

implementation

uses
  Abi.SystemCalls,
  Runtime.Memory,
  Kernel.Scheduler,
  Objects.Manager,
  Objects.Events,
  Network.Addresses,
  Network.Ipv6Addresses,
  Network.Ipv6Types,
  Network.Interfaces,
  Network.Loopback,
  Network.ByteOrder,
  Network.Checksums,
  Network.Core,
  Network.Sockets,
  Network.SocketOperations,
  Network.SocketMemberships,
  Network.ChangeWatchers,
  Network.Ipv6Routing,
  Network.TcpTypes,
  Network.TcpConnections,
  Kernel.NetworkPacketCrafting,
  Kernel.SelfTest;

const
  TimeoutMilliseconds = 5000;
  TestPeer = TIpv4Address($C0000207);
  TestBroadcast = TIpv4Address($C00002FF);
  UnprivilegedUser = 1000;
  ResetFlag = $04;
  SynFlag = $02;
  PushFlag = $08;
  AckFlag = $10;

function OwnerOf(UserId: LongWord): TSocketOwner;
begin
  Result.UserId := UserId;
  Result.ProcessId := 0;
end;

function NewSocketOf(Family: Word; Kind: LongWord; UserId: LongWord): PSocket;
begin
  Check(CreateSocket(Family, Kind, ProtocolDefault, OwnerOf(UserId), UserId = 0, Result) = ErrorNone,
    'a test socket is made');
end;

function ConnectionOf(Socket: PSocket): PTcpConnection;
begin
  Result := PTcpConnection(Socket^.Connection);
end;

function Syn(SourcePort, DestinationPort: Word; Sequence: LongWord): TCraftedTcp;
begin
  FillMemory(@Result, SizeOf(Result), 0);
  Result.SourcePort := SourcePort;
  Result.DestinationPort := DestinationPort;
  Result.Sequence := Sequence;
  Result.Flags := SynFlag;
  Result.Window := 65535;
end;

function Ipv6Text(First, Last: Byte): TIpv6Address;
begin
  FillMemory(@Result, SizeOf(Result), 0);
  Result[0] := First;
  if First = $FE then
    Result[1] := $80;
  Result[15] := Last;
end;

{ A listener on Address (port chosen), with its port. }
function OpenListener(constref Address: TNetworkEndpoint; Backlog: LongWord; out Port: Word): PSocket;
var
  Bound: TNetworkEndpoint;
begin
  Result := NewSocketOf(Address.Family, SocketKindStream, 0);
  Check(BindSocket(Result, Address, True) = ErrorNone, 'a test listener binds');
  Check(ListenOnSocket(Result, Backlog) = ErrorNone, 'a test listener listens');
  GetSocketEndpoint(Result, SocketAddressLocal, Bound);
  Port := Bound.Port;
end;

{ --- 127.0.0.0/8 and ::1 only from lo -------------------------------------- }

procedure TestLoopbackListenersUnreachable;
var
  Listener: PSocket;
  Listener6: PSocket;
  Port: Word;
  Port6: Word;
  Ethernet: PNetworkInterface;
  Child: PTcpConnection;
begin
  Listener := OpenListener(MakeEndpoint(LoopbackAddress, 0), 4, Port);
  Ethernet := TestEthernetInterface(True);
  LockNetwork;
  InjectTcp(Ethernet, MakeEndpoint(TestPeer, 40000), MakeEndpoint(LoopbackAddress, Port), Syn(40000, Port, 1000));
  Check(ConnectionOf(Listener)^.ChildCount = 0, 'a SYN to 127.0.0.1 from an Ethernet interface makes no connection');
  InjectTcp(Ethernet, MakeEndpoint(LoopbackAddress, 40000), MakeEndpoint(LoopbackAddress, Port),
    Syn(40000, Port, 1000));
  Check(ConnectionOf(Listener)^.ChildCount = 0, 'nor does one from 127.0.0.1 itself');
  { The same SYN on lo is answered: the check is the interface. }
  InjectTcp(LoopbackInterface, MakeEndpoint($7F000005, 40001), MakeEndpoint(LoopbackAddress, Port),
    Syn(40001, Port, 2000));
  Check(ConnectionOf(Listener)^.ChildCount = 1, 'the same SYN on lo makes a child');
  Child := OldestHalfOpenChild(ConnectionOf(Listener));
  Check((Child <> nil) and Child^.IsHalfOpen and (Child^.ReceiveBuffer.Data = nil) and
    (Child^.SendBuffer.Data = nil), 'a half-open child has no buffers yet');
  UnlockNetwork;
  DereferenceObject(Listener);

  Listener6 := OpenListener(LoopbackEndpoint(AddressFamilyIPv6, 0), 4, Port6);
  LockNetwork;
  InjectTcp(Ethernet, MakeIpv6Endpoint(Ipv6Text($FE, 7), 40002, Ethernet^.Index),
    LoopbackEndpoint(AddressFamilyIPv6, Port6), Syn(40002, Port6, 3000));
  Check(ConnectionOf(Listener6)^.ChildCount = 0, 'a SYN to ::1 from an Ethernet interface makes no connection');
  UnlockNetwork;
  DereferenceObject(Listener6);
  ReportPassed('network: 127.0.0.1 and ::1 are not reachable from Ethernet');
end;

{ True if a datagram waits on the (non-blocking) socket; takes it. }
function TakeDatagram(Socket: PSocket): Boolean;
var
  Buffer: array[0..63] of Byte;
  Source: TNetworkEndpoint;
begin
  Result := ReceiveOnSocket(Socket, @Buffer[0], SizeOf(Buffer), 0, Source) > 0;
end;

procedure TestMartianSources;
var
  Receiver: PSocket;
  Bound: TNetworkEndpoint;
  Text: array[0..3] of Byte;
  Ethernet: PNetworkInterface;
begin
  Receiver := NewSocketOf(AddressFamilyIPv4, SocketKindDatagram or SocketKindNonBlocking, 0);
  Check(BindSocket(Receiver, MakeEndpoint(AnyAddress, 0), True) = ErrorNone, 'a UDP socket on 0.0.0.0');
  GetSocketEndpoint(Receiver, SocketAddressLocal, Bound);
  Text[0] := Ord('m');
  Ethernet := TestEthernetInterface(True);
  InjectUdp(Ethernet, MakeEndpoint(LoopbackAddress, 5000), MakeEndpoint(LimitedBroadcastAddress, Bound.Port),
    @Text[0], 1);
  Check(not TakeDatagram(Receiver), 'a datagram from 127.0.0.1 on Ethernet is dropped');
  InjectUdp(Ethernet, MakeEndpoint(TestBroadcast, 5000), MakeEndpoint(LimitedBroadcastAddress, Bound.Port),
    @Text[0], 1);
  Check(not TakeDatagram(Receiver), 'a datagram from the subnet''s broadcast address is dropped');
  InjectUdp(Ethernet, MakeEndpoint(TestPeer, 5000), MakeEndpoint(LimitedBroadcastAddress, Bound.Port), @Text[0], 1);
  Check(TakeDatagram(Receiver), 'a broadcast from a neighbour arrives');
  Ethernet := TestEthernetInterface(False);
  InjectUdp(Ethernet, MakeEndpoint(TestPeer, 5000), MakeEndpoint($0A090909, Bound.Port), @Text[0], 1);
  Check(not TakeDatagram(Receiver), 'an interface without an address takes no unicast UDP but DHCP''s');
  DereferenceObject(Receiver);
  ReportPassed('network: martian sources dropped');
end;

{ --- Half-open children ---------------------------------------------------- }

procedure TestHalfOpenChildren;
var
  Listener: PSocket;
  Port: Word;
  Index: Word;
  Oldest: PTcpConnection;
begin
  Listener := OpenListener(MakeEndpoint(LoopbackAddress, 0), 2, Port);
  LockNetwork;
  for Index := 0 to 4 do
    InjectTcp(LoopbackInterface, MakeEndpoint($7F000009, 41000 + Index), MakeEndpoint(LoopbackAddress, Port),
      Syn(41000 + Index, Port, 5000));
  Check(ConnectionOf(Listener)^.ChildCount = 2, 'a SYN flood stays within the backlog');
  Oldest := OldestHalfOpenChild(ConnectionOf(Listener));
  Check((Oldest <> nil) and (Oldest^.Remote.Port = 41003), 'the oldest half-open children gave way to new ones');
  UnlockNetwork;
  DereferenceObject(Listener);
  ReportPassed('network: half-open children bounded, without buffers');
end;

{ --- RFC 5961 and ICMP ----------------------------------------------------- }

procedure ConnectPair(out Listener, Client, Server: PSocket);
var
  Port: Word;
  Peer: TNetworkEndpoint;
begin
  Listener := OpenListener(MakeEndpoint(LoopbackAddress, 0), 2, Port);
  SetSocketOption(Listener, SocketOptionReceiveTimeout, TimeoutMilliseconds, True);
  Client := NewSocketOf(AddressFamilyIPv4, SocketKindStream, 0);
  SetSocketOption(Client, SocketOptionSendTimeout, TimeoutMilliseconds, True);
  SetSocketOption(Client, SocketOptionReceiveTimeout, TimeoutMilliseconds, True);
  Check(ConnectSocket(Client, MakeEndpoint(LoopbackAddress, Port)) = ErrorNone, 'a test connection is made');
  Check(AcceptOnSocket(Listener, OwnerOf(0), Server, Peer) = ErrorNone, 'and accepted');
  SetSocketOption(Server, SocketOptionReceiveTimeout, TimeoutMilliseconds, True);
end;

{ An ICMP "fragmentation needed" (next-hop MTU Mtu) quoting a TCP
  segment from Local to Remote with Sequence, as lo brings it. }
procedure InjectFragmentationNeeded(constref Local, Remote: TNetworkEndpoint; Sequence: LongWord; Mtu: Word);
var
  Quoted: TCraftedDatagram;
  Segment: TCraftedTcp;
  Payload: array[0..63] of Byte;
  Message: array[0..63] of Byte;
  Datagram: TCraftedDatagram;
begin
  FillMemory(@Segment, SizeOf(Segment), 0);
  Segment.SourcePort := Local.Port;
  Segment.DestinationPort := Remote.Port;
  Segment.Sequence := Sequence;
  Segment.Flags := AckFlag;
  CraftTcp(@Payload[0], Local, Remote, Segment);
  CraftIpv4(Quoted, Local.Address, Remote.Address, 6, @Payload[0], 20);
  FillMemory(@Message[0], SizeOf(Message), 0);
  Message[0] := 3;
  Message[1] := 4;
  WriteBigEndian16(@Message[6], Mtu);
  CopyMemory(@Message[8], @Quoted.Bytes[0], 28);
  WriteBigEndian16(@Message[2], InternetChecksum(@Message[0], 36));
  CraftIpv4(Datagram, LoopbackAddress, LoopbackAddress, 1, @Message[0], 36);
  InjectIpv4(LoopbackInterface, Datagram);
end;

procedure TestBlindAttacks;
var
  Listener: PSocket;
  Client: PSocket;
  Server: PSocket;
  Connection: PTcpConnection;
  Local: TNetworkEndpoint;
  Remote: TNetworkEndpoint;
  ReceiveNext: LongWord;
  OldAck: LongWord;
  Segment: TCraftedTcp;
  Data: array[0..7] of Byte;
  Source: TNetworkEndpoint;
  Segmentsize: LongWord;
begin
  ConnectPair(Listener, Client, Server);
  LockNetwork;
  Connection := ConnectionOf(Server);
  Local := Connection^.Local;
  Remote := Connection^.Remote;
  ReceiveNext := Connection^.ReceiveNext;
  Segment := Syn(Remote.Port, Local.Port, ReceiveNext + 100);
  InjectTcp(LoopbackInterface, Remote, Local, Segment);
  Check(Connection^.State = TcpEstablished, 'an in-window SYN does not reset a connection (RFC 5961 4)');
  Segment.Flags := ResetFlag;
  InjectTcp(LoopbackInterface, Remote, Local, Segment);
  Check(Connection^.State = TcpEstablished, 'an in-window reset off RCV.NXT does not either (RFC 5961 3)');
  Data[0] := Ord('z');
  Data[1] := Ord('z');
  Segment.Flags := AckFlag or PushFlag;
  Segment.Sequence := ReceiveNext;
  OldAck := LongWord(QWord(Connection^.SendUnacknowledged) - Connection^.LargestSendWindow - 1000);
  Segment.Acknowledgment := OldAck;
  Segment.Data := @Data[0];
  Segment.DataLength := 2;
  InjectTcp(LoopbackInterface, Remote, Local, Segment);
  Check(Connection^.ReceiveNext = ReceiveNext, 'data with a too old acknowledgment is not taken (RFC 5961 5)');
  Segmentsize := Connection^.MaximumSegment;
  InjectFragmentationNeeded(Local, Remote, Connection^.SendMaximum + 50000, 576);
  Check(Connection^.MaximumSegment = Segmentsize,
    'a fragmentation needed quoting a sequence number not in flight is ignored');
  UnlockNetwork;

  Data[0] := Ord('o');
  Data[1] := Ord('k');
  Check(SendOnSocket(Client, @Data[0], 2, 0, nil) = 2, 'the connection still sends');
  FillMemory(@Data[0], SizeOf(Data), 0);
  Check((ReceiveOnSocket(Server, @Data[0], SizeOf(Data), 0, Source) = 2) and (Data[0] = Ord('o')),
    'and the data arrives');
  DereferenceObject(Server);
  DereferenceObject(Client);
  DereferenceObject(Listener);
  ReportPassed('network: RFC 5961 checks and ICMP validation');
end;

{ --- IPv6 fragments --------------------------------------------------------- }

{ A fragment of datagram Identification from ::1 to ::1: Length bytes of
  Piece at Offset of the fragmentable part, whose first header is
  NextHeader. }
procedure InjectFragment(Identification: LongWord; Offset: Word; More: Boolean; NextHeader: Byte; Piece: PByte;
  Length: LongWord);
var
  Payload: array[0..127] of Byte;
  Datagram: TCraftedDatagram;
  Field: Word;
begin
  FillMemory(@Payload[0], 8, 0);
  Payload[0] := NextHeader;
  Field := Offset and $FFF8;
  if More then
    Field := Field or 1;
  WriteBigEndian16(@Payload[2], Field);
  WriteBigEndian32(@Payload[4], Identification);
  CopyMemory(@Payload[8], Piece, Length);
  CraftIpv6(Datagram, LoopbackIpv6Address, LoopbackIpv6Address, 44, @Payload[0], 8 + Length);
  InjectIpv6(LoopbackInterface, Datagram);
end;

procedure TestIpv6Fragments;
var
  Receiver: PSocket;
  Bound: TNetworkEndpoint;
  Data: array[0..39] of Byte;
  Udp: array[0..63] of Byte;
  Chain: array[0..63] of Byte;
  Index: Integer;
  Buffer: array[0..63] of Byte;
  Source: TNetworkEndpoint;
begin
  Receiver := NewSocketOf(AddressFamilyIPv6, SocketKindDatagram or SocketKindNonBlocking, 0);
  Check(BindSocket(Receiver, LoopbackEndpoint(AddressFamilyIPv6, 0), True) = ErrorNone, 'a UDP socket on ::1');
  GetSocketEndpoint(Receiver, SocketAddressLocal, Bound);
  for Index := 0 to High(Data) do
    Data[Index] := Index;
  CraftUdp(@Udp[0], LoopbackEndpoint(AddressFamilyIPv6, 5555), Bound, @Data[0], SizeOf(Data));

  InjectFragment($5A000001, 0, True, 17, @Udp[0], 32);
  InjectFragment($5A000001, 32, False, 17, @Udp[32], 16);
  Check((ReceiveOnSocket(Receiver, @Buffer[0], SizeOf(Buffer), 0, Source) = 40) and (Buffer[39] = 39),
    'two fragments put together arrive');

  InjectFragment($5A000002, 0, True, 17, @Udp[0], 32);
  InjectFragment($5A000002, 24, False, 17, @Udp[24], 24);
  InjectFragment($5A000002, 32, False, 17, @Udp[32], 16);
  Check(not TakeDatagram(Receiver), 'overlapping fragments give up the datagram (RFC 5722)');

  InjectFragment($5A000003, 0, True, 17, @Udp[0], 32);
  InjectFragment($5A000003, 0, True, 17, @Udp[0], 32);
  InjectFragment($5A000003, 32, False, 17, @Udp[32], 16);
  Check(TakeDatagram(Receiver), 'an exact duplicate fragment is dropped alone');

  { Destination options (8 bytes of padding) alone in the first
    fragment, the UDP header in the second. }
  FillMemory(@Chain[0], SizeOf(Chain), 0);
  Chain[0] := 17;
  Chain[2] := 1;
  Chain[3] := 4;
  CopyMemory(@Chain[8], @Udp[0], 48);
  InjectFragment($5A000004, 0, True, 60, @Chain[0], 8);
  InjectFragment($5A000004, 8, False, 60, @Chain[8], 48);
  Check(not TakeDatagram(Receiver), 'a first fragment without the upper-layer header is refused (RFC 8200 4.5)');
  DereferenceObject(Receiver);
  ReportPassed('network: IPv6 reassembly refuses overlaps');
end;

{ --- Routes ------------------------------------------------------------------ }

procedure TestRoutesKeptFromRouters;
var
  Prefix: TIpv6Address;
  Flags: LongWord;
  ExpiresAt: QWord;
begin
  FillMemory(@Prefix, SizeOf(Prefix), 0);
  Prefix[0] := $20;
  Prefix[1] := $01;
  Prefix[2] := $0D;
  Prefix[3] := $B8;
  Prefix[5] := $77;
  LockNetwork;
  Check(AddIpv6Route(Prefix, 48, UnspecifiedIpv6Address, LoopbackInterface, 0, 5, Ipv6Forever) = ErrorNone,
    'a route is added by hand');
  Check(AddIpv6Route(Prefix, 48, UnspecifiedIpv6Address, LoopbackInterface, RouteFlagAutomatic, 1,
    NetworkNow + 1000) = ErrorExists, 'a router does not renew it');
  Check(FindIpv6RouteFlags(Prefix, 48, UnspecifiedIpv6Address, LoopbackInterface, Flags, ExpiresAt) and
    ((Flags and RouteFlagAutomatic) = 0) and (ExpiresAt = Ipv6Forever), 'it keeps its lifetime');
  Check(RemoveAutomaticIpv6Route(Prefix, 48, UnspecifiedIpv6Address, LoopbackInterface) = ErrorNotFound,
    'a router''s lifetime of 0 does not remove it');
  Check(RemoveIpv6Route(Prefix, 48, UnspecifiedIpv6Address, LoopbackInterface) = ErrorNone, 'it is removed by hand');
  UnlockNetwork;
  ReportPassed('network: router advertisements leave static routes alone');
end;

{ --- Per-user shares --------------------------------------------------------- }

procedure TestPerUserLimits;
const
  SocketCount = MaximumUserMemberships + 1;
var
  Watchers: array[0..MaximumWatchersPerUser] of PEventObject;
  RootWatcher: PEventObject;
  Index: Integer;
  Sockets: array[0..SocketCount - 1] of PSocket;
  RootSocket: PSocket;
  Request: TAbiMulticastMembership;
begin
  for Index := 0 to MaximumWatchersPerUser - 1 do
  begin
    Watchers[Index] := CreateNetworkChangeWatcher(UnprivilegedUser);
    Check(Watchers[Index] <> nil, 'a user gets network change watchers');
  end;
  Watchers[MaximumWatchersPerUser] := CreateNetworkChangeWatcher(UnprivilegedUser);
  Check(Watchers[MaximumWatchersPerUser] = nil, 'but only its share of them');
  RootWatcher := CreateNetworkChangeWatcher(0);
  Check(RootWatcher <> nil, 'root still gets one');
  DereferenceObject(RootWatcher);
  for Index := 0 to MaximumWatchersPerUser - 1 do
    DereferenceObject(Watchers[Index]);
  Watchers[0] := CreateNetworkChangeWatcher(UnprivilegedUser);
  Check(Watchers[0] <> nil, 'watchers let go of give the share back');
  DereferenceObject(Watchers[0]);

  FillMemory(@Request, SizeOf(Request), 0);
  Request.Family := AddressFamilyIPv4;
  Request.InterfaceIndex := LoopbackInterface^.Index;
  WriteIpv4Address(@Request.Group[0], TIpv4Address($E0000001));
  for Index := 0 to SocketCount - 1 do
    Sockets[Index] := NewSocketOf(AddressFamilyIPv4, SocketKindDatagram, UnprivilegedUser);
  RootSocket := NewSocketOf(AddressFamilyIPv4, SocketKindDatagram, 0);
  LockNetwork;
  for Index := 0 to SocketCount - 2 do
    Check(ChangeSocketMembership(Sockets[Index], SocketOptionJoinGroup, Request) = ErrorNone,
      'a user joins multicast groups');
  Check(ChangeSocketMembership(Sockets[SocketCount - 1], SocketOptionJoinGroup, Request) = ErrorNoSpace,
    'but only its share of memberships');
  Check(ChangeSocketMembership(RootSocket, SocketOptionJoinGroup, Request) = ErrorNone, 'root still joins');
  UnlockNetwork;
  for Index := 0 to SocketCount - 1 do
    DereferenceObject(Sockets[Index]);
  DereferenceObject(RootSocket);
  ReportPassed('network: per-user shares of watchers and memberships');
end;

procedure RunNetworkHardeningSelfTests;
begin
  TestLoopbackListenersUnreachable;
  TestMartianSources;
  TestHalfOpenChildren;
  TestBlindAttacks;
  TestIpv6Fragments;
  TestRoutesKeptFromRouters;
  TestPerUserLimits;
end;

end.
