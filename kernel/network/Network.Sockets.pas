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
  Sockets: the objects behind socket handles.

  A socket is an object of the object manager (type "Socket"), so
  handles, closing and passing it in messages work as for any other
  object. Its body holds what every kind of socket has - the options,
  the local and peer endpoints, a pending error, the queue of received
  datagrams (UDP, ICMP) or the TCP connection - and two notification
  events kept in step with its state: Readable (data, a connection to
  accept, the end of the stream or an error) and Writable (room to
  send, or a connection attempt that ended). CallWaitForHandles waits
  on Readable.

  All of it is used under the network lock, and the events are updated
  there (UpdateSocketReadiness), so a thread that finds a socket not
  ready, releases the lock and waits on the event cannot miss the
  change (WaitOnSocket). Waits are alertable: a program being ended or
  stopped leaves them (ErrorInterrupted).

  An IPv6 socket without Ipv6Only also carries IPv4 (v4-mapped
  addresses, RFC 4291 2.5.5.2): inside, its endpoints are then IPv4
  ones, and Network.SocketOperations shows them to programs as
  ::ffff:a.b.c.d.

  Deleting the socket (its last handle closed) closes it: a datagram
  socket leaves the multicast groups it joined and goes; a TCP connection is handed to the TCP layer,
  which ends it gracefully and frees it later.
}
unit Network.Sockets;

{$mode objfpc}
{$pointermath on}

interface

uses
  Runtime.LinkedList,
  Kernel.Events,
  Abi.SystemCalls,
  Network.Ipv6Addresses,
  Network.Addresses,
  Network.Datagrams,
  Network.Interfaces;

type
  TSocketProtocol = (SocketProtocolUdp, SocketProtocolTcp, SocketProtocolIcmpEcho, SocketProtocolIcmpRaw);

  { Who a socket belongs to, for listings (netstat -p): the user and
    the process that made it, or accepted its connection. }
  TSocketOwner = record
    UserId: LongWord;
    ProcessId: QWord;
  end;

  { A multicast group the socket joined (Network.SocketMemberships). }
  TSocketMembership = record
    InUse: Boolean;
    NetworkInterface: PNetworkInterface;
    Family: Word;
    Group6: TIpv6Address;
    Group4: TIpv4Address;
  end;

  PSocket = ^TSocket;
  TSocket = record
    { On the list of every socket. }
    Link: TListEntry;
    { AddressFamilyIPv4 or AddressFamilyIPv6: its endpoints are of this
      family, and it sees only this family's traffic. }
    Family: Word;
    { SocketKind* without the non-blocking flag. }
    Kind: LongWord;
    Protocol: TSocketProtocol;
    Owner: TSocketOwner;
    { Options. }
    NonBlocking: Boolean;
    ReceiveTimeout: LongWord;
    SendTimeout: LongWord;
    BroadcastAllowed: Boolean;
    ReuseAddress: Boolean;
    NoDelay: Boolean;
    TimeToLive: Byte;
    BoundInterface: PNetworkInterface;
    { IPv6 sockets: IPv6 traffic only (no v4-mapped IPv4). }
    Ipv6Only: Boolean;
    { Multicast: the interface sent on (nil: by the routes), the hop
      limit, and whether what is sent comes back to this machine's
      sockets too. }
    MulticastInterface: PNetworkInterface;
    MulticastHops: Byte;
    MulticastLoop: Boolean;
    Memberships: array[0..MaximumSocketMemberships - 1] of TSocketMembership;
    { TCP: keep-alives, buffer sizes asked for (0: automatic), and the
      test hook that drops every Nth arriving data segment. }
    KeepAlive: Boolean;
    KeepAliveIdleSeconds: LongWord;
    KeepAliveIntervalSeconds: LongWord;
    KeepAliveCount: LongWord;
    RequestedReceiveBuffer: LongWord;
    RequestedSendBuffer: LongWord;
    DropEvery: LongWord;
    { Endpoints. }
    IsBound: Boolean;
    Local: TNetworkEndpoint;
    IsConnected: Boolean;
    Peer: TNetworkEndpoint;
    { An error to report once (SocketOptionError, or the next call). }
    PendingError: LongInt;
    ReceivedTimeToLive: Byte;
    ReceiveIsShut: Boolean;
    SendIsShut: Boolean;
    { UDP and ICMP. }
    Datagrams: TDatagramQueue;
    { TCP: the connection (Network.TcpTypes), nil before connect or
      listen. }
    Connection: Pointer;
    Readable: TEvent;
    Writable: TEvent;
  end;

{ Registers the object type; once, while the network layer starts. }
procedure InitializeSockets;
{ A new socket (referenced once, for its first handle), on the list of
  sockets, under the lock. }
function AllocateSocket(Family: Word; Kind: LongWord; Protocol: TSocketProtocol;
  constref Owner: TSocketOwner): PSocket;
{ Every socket, for listings and for finding who gets a datagram. }
function FirstSocket: PSocket;
function NextSocket(Socket: PSocket): PSocket;

{ Sets Readable and Writable as the socket's state says (under the
  lock). }
procedure UpdateSocketReadiness(Socket: PSocket);
{ When a wait of TimeoutMilliseconds (0: as long as it takes) begun now
  ends: a NetworkNow time, or NeverDue. }
function SocketWaitDeadline(TimeoutMilliseconds: LongWord): QWord;
{ Under the lock: releases it, waits for Event until Deadline (from
  SocketWaitDeadline), and takes the lock again. ErrorNone when
  signaled, ErrorWouldBlock once the deadline passed, ErrorInterrupted
  if the thread was alerted. }
function WaitOnSocket(Event: PEvent; Deadline: QWord): LongInt;
{ Takes the pending error (ErrorNone if there is none). }
function TakePendingError(Socket: PSocket): LongInt;
{ True if the socket takes traffic of Family as its local endpoint is
  now: its own family, or IPv4 too for an IPv6 socket bound to (or not
  yet bound beyond) :: without Ipv6Only. }
function SocketTakesFamily(Socket: PSocket; Family: Word): Boolean;

implementation

uses
  Kernel.Threads,
  Kernel.PriorityBoosts,
  Kernel.Scheduler,
  Kernel.Clock,
  Objects.Manager,
  Network.Core,
  Network.SocketMemberships,
  Network.TcpSockets;

var
  SocketObjectType: TObjectType;
  AllSockets: TListEntry;

procedure CloseSocketProtocol(Socket: PSocket);
begin
  case Socket^.Protocol of
    SocketProtocolTcp: CloseTcpSocket(Socket);
  else
    LeaveAllSocketGroups(Socket);
    DiscardDatagrams(Socket^.Datagrams);
  end;
end;

procedure DeleteSocket(ObjectBody: Pointer);
var
  Socket: PSocket;
begin
  Socket := PSocket(ObjectBody);
  LockNetwork;
  RemoveListEntry(@Socket^.Link);
  CloseSocketProtocol(Socket);
  UnlockNetwork;
end;

procedure InitializeSockets;
begin
  RegisterObjectType(SocketObjectType, 'Socket', SizeOf(TSocket), @DeleteSocket);
  InitializeListHead(AllSockets);
end;

function AllocateSocket(Family: Word; Kind: LongWord; Protocol: TSocketProtocol;
  constref Owner: TSocketOwner): PSocket;
begin
  Result := PSocket(CreateObject(SocketObjectType, nil));
  if Result = nil then
    Exit;
  Result^.Family := Family;
  Result^.Kind := Kind;
  Result^.Protocol := Protocol;
  Result^.Owner := Owner;
  Result^.TimeToLive := 64;
  Result^.MulticastHops := 1;
  Result^.MulticastLoop := True;
  Result^.KeepAliveIdleSeconds := 7200;
  Result^.KeepAliveIntervalSeconds := 75;
  Result^.KeepAliveCount := 9;
  Result^.Local := UnspecifiedEndpoint(Family);
  Result^.Peer := UnspecifiedEndpoint(Family);
  InitializeDatagramQueue(Result^.Datagrams);
  InitializeEvent(Result^.Readable, EventKindNotification, False);
  InitializeEvent(Result^.Writable, EventKindNotification, False);
  InsertAtTail(AllSockets, @Result^.Link);
  UpdateSocketReadiness(Result);
end;

function FirstSocket: PSocket;
begin
  if ListIsEmpty(AllSockets) then
    Exit(nil);
  Result := PSocket(ContainingRecord(AllSockets.Next, FieldOffset(PSocket(nil)^.Link)));
end;

function NextSocket(Socket: PSocket): PSocket;
begin
  if Socket^.Link.Next = @AllSockets then
    Exit(nil);
  Result := PSocket(ContainingRecord(Socket^.Link.Next, FieldOffset(PSocket(nil)^.Link)));
end;

{ Data from the network wakes its waiters with the network boost. }
procedure SetEventTo(var Event: TEvent; Signaled: Boolean);
begin
  if Signaled then
    SignalEventWithBoost(Event, BoostNetwork)
  else
    ResetEvent(Event);
end;

procedure UpdateSocketReadiness(Socket: PSocket);
var
  IsReadable: Boolean;
  IsWritable: Boolean;
begin
  if Socket^.Protocol = SocketProtocolTcp then
    DescribeTcpReadiness(Socket, IsReadable, IsWritable)
  else
  begin
    IsReadable := (Socket^.Datagrams.Count > 0) or (Socket^.PendingError <> ErrorNone) or Socket^.ReceiveIsShut;
    IsWritable := True;
  end;
  SetEventTo(Socket^.Readable, IsReadable);
  SetEventTo(Socket^.Writable, IsWritable);
end;

function SocketWaitDeadline(TimeoutMilliseconds: LongWord): QWord;
begin
  if TimeoutMilliseconds = 0 then
    Result := NeverDue
  else
    Result := NetworkNow + QWord(TimeoutMilliseconds) * NanosecondsPerMillisecond;
end;

function WaitOnSocket(Event: PEvent; Deadline: QWord): LongInt;
var
  Timeout: QWord;
  Now: QWord;
  Outcome: TWaitResult;
begin
  Timeout := InfiniteTimeout;
  if Deadline <> NeverDue then
  begin
    Now := NetworkNow;
    if Now >= Deadline then
      Exit(ErrorWouldBlock);
    { Rounded up, so the wait never ends early. }
    Timeout := (Deadline - Now + NanosecondsPerMillisecond - 1) div NanosecondsPerMillisecond;
  end;
  UnlockNetwork;
  Outcome := WaitForEventWithOptions(Event^, Timeout, True);
  LockNetwork;
  case Outcome of
    WaitSignaled: Result := ErrorNone;
    WaitTimedOut: Result := ErrorWouldBlock;
  else
    Result := ErrorInterrupted;
  end;
end;

function SocketTakesFamily(Socket: PSocket; Family: Word): Boolean;
begin
  if Socket^.Local.Family = Family then
    Exit(True);
  Result := (Family = AddressFamilyIPv4) and (Socket^.Family = AddressFamilyIPv6) and not Socket^.Ipv6Only and
    (Socket^.Local.Family = AddressFamilyIPv6) and EndpointIsUnspecified(Socket^.Local);
end;

function TakePendingError(Socket: PSocket): LongInt;
begin
  Result := Socket^.PendingError;
  Socket^.PendingError := ErrorNone;
  if Result <> ErrorNone then
    UpdateSocketReadiness(Socket);
end;

end.
