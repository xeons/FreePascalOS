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

  Deleting the socket (its last handle closed) closes it: a datagram
  socket simply goes; a TCP connection is handed to the TCP layer,
  which ends it gracefully and frees it later.
}
unit Network.Sockets;

{$mode objfpc}
{$pointermath on}

interface

uses
  Runtime.LinkedList,
  Kernel.Events,
  Network.Addresses,
  Network.Datagrams,
  Network.Interfaces;

type
  TSocketProtocol = (SocketProtocolUdp, SocketProtocolTcp, SocketProtocolIcmpEcho, SocketProtocolIcmpRaw);

  PSocket = ^TSocket;
  TSocket = record
    { On the list of every socket. }
    Link: TListEntry;
    { SocketKind* without the non-blocking flag. }
    Kind: LongWord;
    Protocol: TSocketProtocol;
    OwnerUserId: LongWord;
    { Options. }
    NonBlocking: Boolean;
    ReceiveTimeout: LongWord;
    SendTimeout: LongWord;
    BroadcastAllowed: Boolean;
    ReuseAddress: Boolean;
    NoDelay: Boolean;
    TimeToLive: Byte;
    BoundInterface: PNetworkInterface;
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
function AllocateSocket(Kind: LongWord; Protocol: TSocketProtocol; OwnerUserId: LongWord): PSocket;
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

implementation

uses
  Abi.SystemCalls,
  Kernel.Threads,
  Kernel.Scheduler,
  Kernel.Clock,
  Objects.Manager,
  Network.Core,
  Network.TcpSockets;

var
  SocketObjectType: TObjectType;
  AllSockets: TListEntry;

procedure CloseSocketProtocol(Socket: PSocket);
begin
  case Socket^.Protocol of
    SocketProtocolTcp: CloseTcpSocket(Socket);
  else
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

function AllocateSocket(Kind: LongWord; Protocol: TSocketProtocol; OwnerUserId: LongWord): PSocket;
begin
  Result := PSocket(CreateObject(SocketObjectType, nil));
  if Result = nil then
    Exit;
  Result^.Kind := Kind;
  Result^.Protocol := Protocol;
  Result^.OwnerUserId := OwnerUserId;
  Result^.TimeToLive := 64;
  Result^.Local := MakeEndpoint(AnyAddress, 0);
  Result^.Peer := MakeEndpoint(AnyAddress, 0);
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

procedure SetEventTo(var Event: TEvent; Signaled: Boolean);
begin
  if Signaled then
    SignalEvent(Event)
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

function TakePendingError(Socket: PSocket): LongInt;
begin
  Result := Socket^.PendingError;
  Socket^.PendingError := ErrorNone;
  if Result <> ErrorNone then
    UpdateSocketReadiness(Socket);
end;

end.
