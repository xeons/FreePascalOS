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
  Local (Unix domain) sockets: stream, datagram and sequenced packet
  sockets between processes of this machine.

  A socket keeps a queue of the messages sent to it. Every send is one
  message: its bytes, the objects it passes along (handles the sender
  had, each held with a reference and as an open handle while in
  flight, like a channel message's) and who sent it (the credentials,
  and the sender's name for datagrams). A datagram or packet socket
  hands each message out whole; a stream socket hands out bytes,
  joining messages, but never reads past a message that passes objects
  (so they arrive with the bytes they were sent with).

  Connected stream and packet sockets point at each other (Peer, a
  reference each way). connect makes the server's end at once and puts
  it in the listener's backlog, where accept finds it. A datagram
  socket's Peer is only where its datagrams go.

  One mutex guards every local socket (LockLocalSockets, also used by
  Processes.LocalSocketNames), and is never held while waiting: each
  socket's events are kept in step with its state under the lock -
  Readable (something to receive, a connection to accept, the end of
  the stream) and Room (its queue, or a listener's backlog, has room) -
  and senders wait for the receiver's Room.

  Sockets count their open handles (NoteLocalSocketOpened/Closed, from
  Processes.Handles, an in-flight passed handle included). When the
  last one closes the socket is released: its peer sees the end of the
  stream (reads give 0, writes ErrorBrokenPipe), the connections in its
  backlog are released too, its name is given up, and what was queued
  is dropped, closing the objects it passed. A socket passed inside a
  message queued on itself stays until the system stops (Linux collects
  such cycles; nothing here does).
}
unit Processes.LocalSockets;

{$mode objfpc}
{$pointermath on}

interface

uses
  Abi.SystemCalls,
  Kernel.Events,
  Processes.Handles;

const
  { Bytes that may wait in a stream socket before senders wait (a send
    may pass it by one piece), and the most messages and bytes waiting
    in a datagram or packet socket. }
  DefaultLocalStreamCapacity = 256 * 1024;
  MinimumLocalCapacity = 4096;
  MaximumLocalCapacity = 4 * 1024 * 1024;
  LocalQueuedMessageLimit = 128;
  DefaultLocalBacklog = 16;
  { ReceiveLocalMessage: take nothing if the next message passes objects
    (a later round of one receive). }
  LocalReceiveStopAtPassed = $1000;

type
  TLocalSocketState = (
    LocalSocketIdle,
    LocalSocketListening,
    LocalSocketConnected,
    { The peer of a connected stream or packet socket is gone. }
    LocalSocketDisconnected
  );

  TLocalPassedObject = record
    Kind: THandleKind;
    ObjectBody: Pointer;
  end;
  PLocalPassedObject = ^TLocalPassedObject;

  PLocalMessage = ^TLocalMessage;
  TLocalMessage = record
    Next: PLocalMessage;
    Length: QWord;
    { Stream: bytes already received. }
    Consumed: QWord;
    Data: PByte;
    Passed: PLocalPassedObject;
    PassedCount: LongWord;
    Sender: TAbiLocalCredentials;
    SenderName: TAbiLocalSocketName;
  end;

  PLocalSocket = ^TLocalSocket;
  TLocalSocket = record
    Kind: LongWord;
    State: TLocalSocketState;
    NonBlocking: Boolean;
    PassCredentials: Boolean;
    { Milliseconds a receive or send waits (0: as long as it takes). }
    ReceiveTimeout: QWord;
    SendTimeout: QWord;
    { shutdown: no more receiving here; no more sending from here. }
    ReadShut: Boolean;
    WriteShut: Boolean;
    OpenCount: LongWord;
    Released: Boolean;
    Peer: PLocalSocket;
    { Who made this socket, and who made (or connected) its peer. }
    Creator: TAbiLocalCredentials;
    PeerCredentials: TAbiLocalCredentials;
    QueueHead: PLocalMessage;
    QueueTail: PLocalMessage;
    QueuedBytes: QWord;
    QueuedCount: LongWord;
    Capacity: QWord;
    Readable: TEvent;
    Room: TEvent;
    { A listener's backlog: server ends connect made, not accepted yet. }
    Backlog: LongWord;
    PendingHead: PLocalSocket;
    PendingTail: PLocalSocket;
    PendingCount: LongWord;
    NextPending: PLocalSocket;
    { Its name (Length 0: none) and, for a path, the node's identity
      (Processes.LocalSocketNames). }
    Name: TAbiLocalSocketName;
    NamedByPath: Boolean;
    NameVolume: LongWord;
    NameNode: QWord;
    Bound: Boolean;
    NextBound: PLocalSocket;
  end;

  { What a receive took. }
  TLocalReceipt = record
    { Bytes put in the buffer; a datagram's whole length. }
    ByteCount: QWord;
    FullLength: QWord;
    Sender: TAbiLocalCredentials;
    SenderName: TAbiLocalSocketName;
    { Objects passed with what was received (the caller installs or
      drops them and frees the block). }
    Passed: PLocalPassedObject;
    PassedCount: LongWord;
    Truncated: Boolean;
    { Nothing came because the stream (or the connection) ended. }
    EndOfStream: Boolean;
  end;

procedure InitializeLocalSockets;

procedure LockLocalSockets;
procedure UnlockLocalSockets;

{ A new socket of Kind (LocalSocket*), owned by Creator; one reference
  for the caller. }
function CreateLocalSocket(Kind: LongWord; NonBlocking: Boolean; constref Creator: TAbiLocalCredentials;
  out Socket: PLocalSocket): LongInt;
{ Connects two new sockets to each other (socketpair). }
procedure ConnectLocalPair(First, Second: PLocalSocket);
function IsLocalSocketKind(Kind: LongWord): Boolean;

procedure NoteLocalSocketOpened(Socket: PLocalSocket);
procedure NoteLocalSocketClosed(Socket: PLocalSocket);

function ListenOnLocalSocket(Socket: PLocalSocket; Backlog: LongWord): LongInt;
{ Connects a stream or packet socket to Listener (waiting while its
  backlog is full), or sets a datagram socket's destination. Caller is
  who connects. }
function ConnectLocalSocket(Socket, Target: PLocalSocket; constref Caller: TAbiLocalCredentials): LongInt;
{ The next connection waiting in Listener's backlog (one reference for
  the caller). }
function AcceptOnLocalSocket(Listener: PLocalSocket; out Accepted: PLocalSocket): LongInt;

{ A message of Length bytes with room for PassedCount objects, its
  Data and Passed filled in; nil if memory is short. }
function AllocateLocalMessage(Length: QWord; PassedCount: LongWord): PLocalMessage;
{ Frees a message, dropping the objects it still passes. }
procedure FreeLocalMessage(Message: PLocalMessage);
{ Queues Message on the peer (or on Destination, for a datagram socket;
  nil: its connected destination), waiting for room unless DontWait or
  the socket does not wait. On success the message belongs to the
  receiver. Returns ErrorNone or an Abi error. }
function SendLocalMessage(Socket: PLocalSocket; Message: PLocalMessage; Destination: PLocalSocket;
  DontWait: Boolean): LongInt;
{ Receives into Buffer (Capacity bytes): a whole datagram or packet
  (cut to Capacity), or a stream's bytes. Flags: LocalMessagePeek,
  LocalMessageDontWait. }
function ReceiveLocalMessage(Socket: PLocalSocket; Buffer: PByte; Capacity: QWord; Flags: LongWord;
  out Receipt: TLocalReceipt): LongInt;
{ Drops the objects of a receipt not installed and frees its block. }
procedure DropReceiptObjects(var Receipt: TLocalReceipt; FirstKept: LongWord);

function ShutdownLocalSocket(Socket: PLocalSocket; How: LongWord): LongInt;
function GetLocalSocketOption(Socket: PLocalSocket; Option: LongWord; out Value: Int64): LongInt;
function SetLocalSocketOption(Socket: PLocalSocket; Option: LongWord; Value: Int64): LongInt;
{ SocketReadable and SocketWritable that hold now, waiting at most
  TimeoutMilliseconds (InfiniteWait: no limit) for one of Conditions;
  ErrorTimedOut (negated) if none came. }
function WaitForLocalSocket(Socket: PLocalSocket; Conditions: LongWord; TimeoutMilliseconds: Int64): Int64;
{ The peer's name and credentials. }
function GetLocalPeer(Socket: PLocalSocket; out Name: TAbiLocalSocketName;
  out Credentials: TAbiLocalCredentials): LongInt;

implementation

uses
  Runtime.Memory,
  Memory.KernelHeap,
  Kernel.Mutex,
  Kernel.Threads,
  Kernel.Scheduler,
  Objects.Manager,
  Processes.LocalSocketNames;

var
  LocalSocketObjectType: TObjectType;
  LocalSocketLock: TMutex;

procedure LockLocalSockets;
begin
  AcquireMutex(LocalSocketLock);
end;

procedure UnlockLocalSockets;
begin
  ReleaseMutex(LocalSocketLock);
end;

function IsLocalSocketKind(Kind: LongWord): Boolean;
begin
  Result := (Kind = LocalSocketStream) or (Kind = LocalSocketDatagram) or (Kind = LocalSocketPackets);
end;

function IsConnectionKind(Socket: PLocalSocket): Boolean;
begin
  Result := Socket^.Kind <> LocalSocketDatagram;
end;

{ --- Messages ------------------------------------------------------------ }

function AllocateLocalMessage(Length: QWord; PassedCount: LongWord): PLocalMessage;
var
  PassedBytes: QWord;
begin
  PassedBytes := QWord(PassedCount) * SizeOf(TLocalPassedObject);
  Result := PLocalMessage(AllocateZeroedKernelMemory(SizeOf(TLocalMessage) + PassedBytes + Length));
  if Result = nil then
    Exit;
  Result^.Length := Length;
  Result^.Passed := PLocalPassedObject(PByte(Result) + SizeOf(TLocalMessage));
  Result^.PassedCount := PassedCount;
  Result^.Data := PByte(Result) + SizeOf(TLocalMessage) + PassedBytes;
end;

procedure DropPassedObjects(Passed: PLocalPassedObject; First, Count: LongWord);
var
  Index: LongWord;
begin
  Index := First;
  while Index < Count do
  begin
    DropHandleReference(Passed[Index].Kind, Passed[Index].ObjectBody);
    Inc(Index);
  end;
end;

procedure FreeLocalMessage(Message: PLocalMessage);
begin
  if Message = nil then
    Exit;
  DropPassedObjects(Message^.Passed, 0, Message^.PassedCount);
  FreeKernelMemory(Message);
end;

procedure FreeMessageList(Message: PLocalMessage);
var
  Next: PLocalMessage;
begin
  while Message <> nil do
  begin
    Next := Message^.Next;
    FreeLocalMessage(Message);
    Message := Next;
  end;
end;

procedure DropReceiptObjects(var Receipt: TLocalReceipt; FirstKept: LongWord);
begin
  if Receipt.Passed = nil then
    Exit;
  DropPassedObjects(Receipt.Passed, FirstKept, Receipt.PassedCount);
  FreeKernelMemory(Receipt.Passed);
  Receipt.Passed := nil;
  Receipt.PassedCount := 0;
end;

{ --- Readiness (lock held) ------------------------------------------------ }

function QueueHasRoomLocked(Socket: PLocalSocket): Boolean;
begin
  if Socket^.Released or Socket^.ReadShut then
    Exit(True);
  if Socket^.State = LocalSocketListening then
    Exit(Socket^.PendingCount < Socket^.Backlog);
  Result := (Socket^.QueuedBytes < Socket^.Capacity) and (Socket^.QueuedCount < LocalQueuedMessageLimit);
end;

{ No more will come: the peer is gone or will send no more. }
function StreamEndedLocked(Socket: PLocalSocket): Boolean;
begin
  Result := Socket^.ReadShut or (Socket^.State = LocalSocketDisconnected) or
    (IsConnectionKind(Socket) and (Socket^.State = LocalSocketConnected) and
     ((Socket^.Peer = nil) or Socket^.Peer^.WriteShut));
end;

function IsReadableLocked(Socket: PLocalSocket): Boolean;
begin
  if Socket^.State = LocalSocketListening then
    Exit((Socket^.PendingCount > 0) or Socket^.Released);
  Result := (Socket^.QueueHead <> nil) or StreamEndedLocked(Socket);
end;

procedure UpdateReadinessLocked(Socket: PLocalSocket);
begin
  if Socket = nil then
    Exit;
  if IsReadableLocked(Socket) then
    SignalEvent(Socket^.Readable)
  else
    ResetEvent(Socket^.Readable);
  if QueueHasRoomLocked(Socket) then
    SignalEvent(Socket^.Room)
  else
    ResetEvent(Socket^.Room);
end;

{ Where a send from Socket goes now (connected sockets), or nil. }
function SendTargetLocked(Socket: PLocalSocket): PLocalSocket;
begin
  Result := Socket^.Peer;
end;

function IsWritableLocked(Socket: PLocalSocket): Boolean;
var
  Target: PLocalSocket;
begin
  if Socket^.WriteShut then
    Exit(True);
  if IsConnectionKind(Socket) and (Socket^.State <> LocalSocketConnected) then
    Exit(Socket^.State = LocalSocketDisconnected);
  Target := SendTargetLocked(Socket);
  if Target = nil then
    Exit(not IsConnectionKind(Socket));
  Result := QueueHasRoomLocked(Target);
end;

{ --- Making and releasing ------------------------------------------------- }

procedure ReleaseLocalSocket(Socket: PLocalSocket); forward;

procedure DeleteLocalSocket(ObjectBody: Pointer);
var
  Socket: PLocalSocket;
begin
  Socket := PLocalSocket(ObjectBody);
  { A socket no handle ever held (a failed call, a backlog dropped). }
  if not Socket^.Released then
    ReleaseLocalSocket(Socket);
  FreeMessageList(Socket^.QueueHead);
  Socket^.QueueHead := nil;
end;

procedure InitializeLocalSockets;
begin
  InitializeMutex(LocalSocketLock);
  RegisterObjectType(LocalSocketObjectType, 'LocalSocket', SizeOf(TLocalSocket), @DeleteLocalSocket);
end;

function CreateLocalSocket(Kind: LongWord; NonBlocking: Boolean; constref Creator: TAbiLocalCredentials;
  out Socket: PLocalSocket): LongInt;
begin
  Socket := nil;
  if not IsLocalSocketKind(Kind) then
    Exit(ErrorProtocolNotSupported);
  Socket := PLocalSocket(CreateObject(LocalSocketObjectType, nil));
  if Socket = nil then
    Exit(ErrorOutOfMemory);
  Socket^.Kind := Kind;
  Socket^.State := LocalSocketIdle;
  Socket^.NonBlocking := NonBlocking;
  Socket^.Creator := Creator;
  Socket^.Capacity := DefaultLocalStreamCapacity;
  InitializeEvent(Socket^.Readable, EventKindNotification, False);
  InitializeEvent(Socket^.Room, EventKindNotification, True);
  Result := ErrorNone;
end;

procedure ConnectLocalPair(First, Second: PLocalSocket);
begin
  LockLocalSockets;
  ReferenceObject(First);
  ReferenceObject(Second);
  First^.Peer := Second;
  Second^.Peer := First;
  First^.State := LocalSocketConnected;
  Second^.State := LocalSocketConnected;
  First^.PeerCredentials := Second^.Creator;
  Second^.PeerCredentials := First^.Creator;
  UpdateReadinessLocked(First);
  UpdateReadinessLocked(Second);
  UnlockLocalSockets;
end;

procedure NoteLocalSocketOpened(Socket: PLocalSocket);
begin
  LockLocalSockets;
  Inc(Socket^.OpenCount);
  UnlockLocalSockets;
end;

procedure NoteLocalSocketClosed(Socket: PLocalSocket);
var
  Last: Boolean;
begin
  LockLocalSockets;
  Dec(Socket^.OpenCount);
  Last := Socket^.OpenCount = 0;
  UnlockLocalSockets;
  if Last then
    ReleaseLocalSocket(Socket);
end;

{ Nobody holds Socket any more. What it held is let go outside the
  lock: messages close the objects they pass, which may release other
  sockets. }
procedure ReleaseLocalSocket(Socket: PLocalSocket);
var
  Messages: PLocalMessage;
  Pending: PLocalSocket;
  Next: PLocalSocket;
  Peer: PLocalSocket;
  PeerHeldUs: Boolean;
begin
  LockLocalSockets;
  if Socket^.Released then
  begin
    UnlockLocalSockets;
    Exit;
  end;
  Socket^.Released := True;
  Messages := Socket^.QueueHead;
  Socket^.QueueHead := nil;
  Socket^.QueueTail := nil;
  Socket^.QueuedBytes := 0;
  Socket^.QueuedCount := 0;
  Pending := Socket^.PendingHead;
  Socket^.PendingHead := nil;
  Socket^.PendingTail := nil;
  Socket^.PendingCount := 0;
  Peer := Socket^.Peer;
  Socket^.Peer := nil;
  PeerHeldUs := False;
  if (Peer <> nil) and IsConnectionKind(Socket) and (Peer^.Peer = Socket) then
  begin
    Peer^.Peer := nil;
    Peer^.State := LocalSocketDisconnected;
    PeerHeldUs := True;
    UpdateReadinessLocked(Peer);
  end;
  ForgetLocalSocketNameLocked(Socket);
  UpdateReadinessLocked(Socket);
  UnlockLocalSockets;

  FreeMessageList(Messages);
  while Pending <> nil do
  begin
    Next := Pending^.NextPending;
    Pending^.NextPending := nil;
    ReleaseLocalSocket(Pending);
    DereferenceObject(Pending);
    Pending := Next;
  end;
  if Peer <> nil then
    DereferenceObject(Peer);
  if PeerHeldUs then
    DereferenceObject(Socket);
end;

{ --- Connections ------------------------------------------------------------ }

function ListenOnLocalSocket(Socket: PLocalSocket; Backlog: LongWord): LongInt;
begin
  if not IsConnectionKind(Socket) then
    Exit(ErrorUnsupported);
  LockLocalSockets;
  if not Socket^.Bound then
    Result := ErrorInvalidArgument
  else if (Socket^.State <> LocalSocketIdle) and (Socket^.State <> LocalSocketListening) then
    Result := ErrorInvalidArgument
  else
  begin
    if Backlog < 1 then
      Backlog := 1;
    if Backlog > MaximumListenBacklog then
      Backlog := MaximumListenBacklog;
    Socket^.State := LocalSocketListening;
    Socket^.Backlog := Backlog;
    UpdateReadinessLocked(Socket);
    Result := ErrorNone;
  end;
  UnlockLocalSockets;
end;

{ Waits (without the lock) for Event, at most TimeoutMilliseconds (0:
  as long as it takes). ErrorNone, ErrorInterrupted or ErrorWouldBlock
  (timed out). }
function WaitUnlocked(var Event: TEvent; TimeoutMilliseconds: QWord): LongInt;
var
  Timeout: QWord;
begin
  Timeout := TimeoutMilliseconds;
  if Timeout = 0 then
    Timeout := InfiniteTimeout;
  case WaitForEventWithOptions(Event, Timeout, True) of
    WaitSignaled: Result := ErrorNone;
    WaitTimedOut: Result := ErrorWouldBlock;
  else
    Result := ErrorInterrupted;
  end;
end;

function ConnectDatagramLocked(Socket, Target: PLocalSocket): LongInt;
var
  Previous: PLocalSocket;
begin
  if Target^.Kind <> LocalSocketDatagram then
    Exit(ErrorProtocolNotSupported);
  if Target^.Released then
    Exit(ErrorConnectionRefused);
  Previous := Socket^.Peer;
  ReferenceObject(Target);
  Socket^.Peer := Target;
  Socket^.State := LocalSocketConnected;
  Socket^.PeerCredentials := Target^.Creator;
  if Previous <> nil then
    DereferenceObject(Previous);
  UpdateReadinessLocked(Socket);
  Result := ErrorNone;
end;

{ Makes the server's end of a connection from Socket and queues it on
  Listener. Lock held; Server is new and unshared. }
procedure QueueConnectionLocked(Socket, Listener, Server: PLocalSocket; constref Caller: TAbiLocalCredentials);
begin
  Server^.State := LocalSocketConnected;
  Server^.Capacity := Listener^.Capacity;
  Server^.Name := Listener^.Name;
  ReferenceObject(Socket);
  ReferenceObject(Server);
  Server^.Peer := Socket;
  Socket^.Peer := Server;
  Socket^.State := LocalSocketConnected;
  Server^.PeerCredentials := Caller;
  Socket^.PeerCredentials := Listener^.Creator;
  { The backlog holds the server end's first reference. }
  if Listener^.PendingTail = nil then
    Listener^.PendingHead := Server
  else
    Listener^.PendingTail^.NextPending := Server;
  Listener^.PendingTail := Server;
  Inc(Listener^.PendingCount);
  UpdateReadinessLocked(Listener);
  UpdateReadinessLocked(Socket);
  UpdateReadinessLocked(Server);
end;

function ConnectLocalSocket(Socket, Target: PLocalSocket; constref Caller: TAbiLocalCredentials): LongInt;
var
  Server: PLocalSocket;
begin
  if not IsConnectionKind(Socket) then
  begin
    LockLocalSockets;
    Result := ConnectDatagramLocked(Socket, Target);
    UnlockLocalSockets;
    Exit;
  end;
  if Target^.Kind <> Socket^.Kind then
    Exit(ErrorProtocolNotSupported);
  { Made first: no allocation under the lock. }
  Result := CreateLocalSocket(Socket^.Kind, False, Target^.Creator, Server);
  if Result <> ErrorNone then
    Exit;
  LockLocalSockets;
  repeat
    if Socket^.State = LocalSocketConnected then
      Result := ErrorAlreadyConnected
    else if Socket^.State <> LocalSocketIdle then
      Result := ErrorInvalidArgument
    else if Target^.Released or (Target^.State <> LocalSocketListening) then
      Result := ErrorConnectionRefused
    else if Target^.PendingCount < Target^.Backlog then
    begin
      QueueConnectionLocked(Socket, Target, Server, Caller);
      Server := nil;
      Result := ErrorNone;
    end
    else if Socket^.NonBlocking then
      Result := ErrorWouldBlock
    else
    begin
      UnlockLocalSockets;
      Result := WaitUnlocked(Target^.Room, Socket^.SendTimeout);
      LockLocalSockets;
      if Result = ErrorNone then
        Continue;
    end;
    Break;
  until False;
  UnlockLocalSockets;
  if Server <> nil then
    DereferenceObject(Server);
end;

function AcceptOnLocalSocket(Listener: PLocalSocket; out Accepted: PLocalSocket): LongInt;
begin
  Accepted := nil;
  LockLocalSockets;
  repeat
    if Listener^.State <> LocalSocketListening then
      Result := ErrorInvalidArgument
    else if Listener^.PendingHead <> nil then
    begin
      Accepted := Listener^.PendingHead;
      Listener^.PendingHead := Accepted^.NextPending;
      if Listener^.PendingHead = nil then
        Listener^.PendingTail := nil;
      Accepted^.NextPending := nil;
      Dec(Listener^.PendingCount);
      UpdateReadinessLocked(Listener);
      Result := ErrorNone;
    end
    else if Listener^.NonBlocking then
      Result := ErrorWouldBlock
    else
    begin
      UnlockLocalSockets;
      Result := WaitUnlocked(Listener^.Readable, Listener^.ReceiveTimeout);
      LockLocalSockets;
      if Result = ErrorNone then
        Continue;
    end;
    Break;
  until False;
  UnlockLocalSockets;
end;

{ --- Sending ------------------------------------------------------------- }

{ Where Socket's message goes, referenced; or an error. Lock held. }
function ChooseTargetLocked(Socket, Destination: PLocalSocket; out Target: PLocalSocket): LongInt;
begin
  Target := nil;
  if Socket^.WriteShut then
    Exit(ErrorBrokenPipe);
  if IsConnectionKind(Socket) then
  begin
    if Socket^.State = LocalSocketDisconnected then
      Exit(ErrorBrokenPipe);
    if Socket^.State <> LocalSocketConnected then
      Exit(ErrorNotConnected);
    Target := Socket^.Peer;
    if (Target = nil) or Target^.Released or Target^.ReadShut then
    begin
      Target := nil;
      Exit(ErrorBrokenPipe);
    end;
  end
  else
  begin
    Target := Destination;
    if Target = nil then
      Target := Socket^.Peer;
    if Target = nil then
      Exit(ErrorDestinationRequired);
    if Target^.Released or (Target^.Kind <> LocalSocketDatagram) then
    begin
      Target := nil;
      Exit(ErrorConnectionRefused);
    end;
    if Target^.ReadShut then
    begin
      Target := nil;
      Exit(ErrorBrokenPipe);
    end;
  end;
  ReferenceObject(Target);
  Result := ErrorNone;
end;

procedure AppendMessageLocked(Target: PLocalSocket; Message: PLocalMessage);
begin
  Message^.Next := nil;
  if Target^.QueueTail = nil then
    Target^.QueueHead := Message
  else
    Target^.QueueTail^.Next := Message;
  Target^.QueueTail := Message;
  Target^.QueuedBytes := Target^.QueuedBytes + Message^.Length;
  Inc(Target^.QueuedCount);
  UpdateReadinessLocked(Target);
end;

function SendLocalMessage(Socket: PLocalSocket; Message: PLocalMessage; Destination: PLocalSocket;
  DontWait: Boolean): LongInt;
var
  Target: PLocalSocket;
begin
  LockLocalSockets;
  repeat
    Result := ChooseTargetLocked(Socket, Destination, Target);
    if Result <> ErrorNone then
      Break;
    if QueueHasRoomLocked(Target) then
    begin
      AppendMessageLocked(Target, Message);
      UnlockLocalSockets;
      DereferenceObject(Target);
      Exit(ErrorNone);
    end;
    if DontWait or Socket^.NonBlocking then
      Result := ErrorWouldBlock
    else
    begin
      UnlockLocalSockets;
      Result := WaitUnlocked(Target^.Room, Socket^.SendTimeout);
      LockLocalSockets;
    end;
    DereferenceObject(Target);
    if Result <> ErrorNone then
      Break;
  until False;
  UnlockLocalSockets;
end;

{ --- Receiving ----------------------------------------------------------- }

procedure TakeQueuedMessageLocked(Socket: PLocalSocket; Message: PLocalMessage);
begin
  Socket^.QueueHead := Message^.Next;
  if Socket^.QueueHead = nil then
    Socket^.QueueTail := nil;
  Socket^.QueuedBytes := Socket^.QueuedBytes - (Message^.Length - Message^.Consumed);
  Dec(Socket^.QueuedCount);
  { Alone from now on: freed as a list of one. }
  Message^.Next := nil;
end;

{ The message's passed objects move to the receipt (Peek: nothing). }
procedure MovePassedObjects(Message: PLocalMessage; var Receipt: TLocalReceipt);
var
  Bytes: QWord;
begin
  if Message^.PassedCount = 0 then
    Exit;
  Bytes := QWord(Message^.PassedCount) * SizeOf(TLocalPassedObject);
  Receipt.Passed := PLocalPassedObject(AllocateKernelMemory(Bytes));
  if Receipt.Passed = nil then
  begin
    { No memory to hand them over: they are closed, as cut off. }
    DropPassedObjects(Message^.Passed, 0, Message^.PassedCount);
    Receipt.Truncated := True;
  end
  else
  begin
    CopyMemory(Receipt.Passed, Message^.Passed, Bytes);
    Receipt.PassedCount := Message^.PassedCount;
  end;
  Message^.PassedCount := 0;
end;

{ A datagram or packet: the first message whole. Lock held; a message
  is waiting. Returns the message taken (to free outside the lock), or
  nil when peeking. }
function ReceiveWholeLocked(Socket: PLocalSocket; Buffer: PByte; Capacity: QWord; Peek: Boolean;
  var Receipt: TLocalReceipt): PLocalMessage;
var
  Message: PLocalMessage;
  Count: QWord;
begin
  Message := Socket^.QueueHead;
  Count := Message^.Length;
  if Count > Capacity then
  begin
    Count := Capacity;
    Receipt.Truncated := True;
  end;
  CopyMemory(Buffer, Message^.Data, Count);
  Receipt.ByteCount := Count;
  Receipt.FullLength := Message^.Length;
  Receipt.Sender := Message^.Sender;
  Receipt.SenderName := Message^.SenderName;
  if Peek then
    Exit(nil);
  TakeQueuedMessageLocked(Socket, Message);
  MovePassedObjects(Message, Receipt);
  Result := Message;
end;

{ A stream: bytes from as many messages as fit, never past a later
  message that passes objects. Lock held; a message is waiting. Returns
  the messages used up (to free outside the lock). }
function ReceiveStreamLocked(Socket: PLocalSocket; Buffer: PByte; Capacity: QWord; Peek: Boolean;
  var Receipt: TLocalReceipt): PLocalMessage;
var
  Message: PLocalMessage;
  Available: QWord;
  Count: QWord;
  PeekOffset: QWord;
  UsedUp: PLocalMessage;
  UsedUpTail: PLocalMessage;
begin
  UsedUp := nil;
  UsedUpTail := nil;
  Message := Socket^.QueueHead;
  Receipt.Sender := Message^.Sender;
  Receipt.SenderName := Message^.SenderName;
  while (Message <> nil) and (Receipt.ByteCount < Capacity) do
  begin
    if (Receipt.ByteCount > 0) and (Message^.PassedCount > 0) then
      Break;
    PeekOffset := Message^.Consumed;
    Available := Message^.Length - PeekOffset;
    Count := Capacity - Receipt.ByteCount;
    if Count > Available then
      Count := Available;
    CopyMemory(Buffer + Receipt.ByteCount, Message^.Data + PeekOffset, Count);
    Receipt.ByteCount := Receipt.ByteCount + Count;
    if Peek then
    begin
      Message := Message^.Next;
      Continue;
    end;
    if Message^.PassedCount > 0 then
      MovePassedObjects(Message, Receipt);
    Message^.Consumed := Message^.Consumed + Count;
    Socket^.QueuedBytes := Socket^.QueuedBytes - Count;
    if Message^.Consumed < Message^.Length then
      Break;
    { Used up: off the queue (its bytes are counted off already). }
    Socket^.QueueHead := Message^.Next;
    if Socket^.QueueHead = nil then
      Socket^.QueueTail := nil;
    Dec(Socket^.QueuedCount);
    Message^.Next := nil;
    if UsedUpTail = nil then
      UsedUp := Message
    else
      UsedUpTail^.Next := Message;
    UsedUpTail := Message;
    Message := Socket^.QueueHead;
  end;
  Receipt.FullLength := Receipt.ByteCount;
  Result := UsedUp;
end;

function ReceiveLocalMessage(Socket: PLocalSocket; Buffer: PByte; Capacity: QWord; Flags: LongWord;
  out Receipt: TLocalReceipt): LongInt;
var
  Peek: Boolean;
  Taken: PLocalMessage;
begin
  FillMemory(@Receipt, SizeOf(Receipt), 0);
  Peek := (Flags and LocalMessagePeek) <> 0;
  Taken := nil;
  LockLocalSockets;
  repeat
    if Socket^.State = LocalSocketListening then
      Result := ErrorNotConnected
    else if (Socket^.QueueHead <> nil) and not Socket^.ReadShut and
      ((Flags and LocalReceiveStopAtPassed) <> 0) and (Socket^.QueueHead^.PassedCount > 0) and
      (Socket^.QueueHead^.Consumed = 0) then
      Result := ErrorNone
    else if (Socket^.QueueHead <> nil) and not Socket^.ReadShut then
    begin
      if IsConnectionKind(Socket) and (Socket^.Kind = LocalSocketStream) then
        Taken := ReceiveStreamLocked(Socket, Buffer, Capacity, Peek, Receipt)
      else
        Taken := ReceiveWholeLocked(Socket, Buffer, Capacity, Peek, Receipt);
      UpdateReadinessLocked(Socket);
      Result := ErrorNone;
    end
    else if StreamEndedLocked(Socket) then
    begin
      Receipt.EndOfStream := True;
      Result := ErrorNone;
    end
    else if IsConnectionKind(Socket) and (Socket^.State = LocalSocketIdle) then
      Result := ErrorNotConnected
    else if ((Flags and LocalMessageDontWait) <> 0) or Socket^.NonBlocking then
      Result := ErrorWouldBlock
    else
    begin
      UnlockLocalSockets;
      Result := WaitUnlocked(Socket^.Readable, Socket^.ReceiveTimeout);
      LockLocalSockets;
      if Result = ErrorNone then
        Continue;
    end;
    Break;
  until False;
  { Room for the senders waiting. }
  UpdateReadinessLocked(Socket);
  UnlockLocalSockets;
  FreeMessageList(Taken);
end;

{ --- Shutting down, options, waiting ------------------------------------ }

function ShutdownLocalSocket(Socket: PLocalSocket; How: LongWord): LongInt;
var
  Dropped: PLocalMessage;
begin
  if (How < SocketShutdownReceive) or (How > SocketShutdownBoth) then
    Exit(ErrorInvalidArgument);
  Dropped := nil;
  LockLocalSockets;
  if IsConnectionKind(Socket) and (Socket^.State <> LocalSocketConnected) and
     (Socket^.State <> LocalSocketDisconnected) then
    Result := ErrorNotConnected
  else
  begin
    if (How and SocketShutdownReceive) <> 0 then
    begin
      Socket^.ReadShut := True;
      Dropped := Socket^.QueueHead;
      Socket^.QueueHead := nil;
      Socket^.QueueTail := nil;
      Socket^.QueuedBytes := 0;
      Socket^.QueuedCount := 0;
    end;
    if (How and SocketShutdownSend) <> 0 then
      Socket^.WriteShut := True;
    UpdateReadinessLocked(Socket);
    if IsConnectionKind(Socket) then
      UpdateReadinessLocked(Socket^.Peer);
    Result := ErrorNone;
  end;
  UnlockLocalSockets;
  FreeMessageList(Dropped);
end;

function MillisecondsOption(Value: QWord): Int64;
begin
  Result := Int64(Value);
end;

function GetLocalSocketOption(Socket: PLocalSocket; Option: LongWord; out Value: Int64): LongInt;
begin
  Value := 0;
  Result := ErrorNone;
  LockLocalSockets;
  case Option of
    SocketOptionNonBlocking: Value := Ord(Socket^.NonBlocking);
    SocketOptionError: Value := 0;
    SocketOptionKind: Value := Socket^.Kind;
    SocketOptionReceiveBuffer, SocketOptionSendBuffer: Value := Int64(Socket^.Capacity);
    SocketOptionReceiveTimeout: Value := MillisecondsOption(Socket^.ReceiveTimeout);
    SocketOptionSendTimeout: Value := MillisecondsOption(Socket^.SendTimeout);
    SocketOptionPassCredentials: Value := Ord(Socket^.PassCredentials);
    SocketOptionListening: Value := Ord(Socket^.State = LocalSocketListening);
    SocketOptionReadableBytes:
      if Socket^.QueueHead = nil then
        Value := 0
      else if Socket^.Kind = LocalSocketStream then
        Value := Int64(Socket^.QueuedBytes)
      else
        Value := Int64(Socket^.QueueHead^.Length);
  else
    Result := ErrorUnsupported;
  end;
  UnlockLocalSockets;
end;

function SetLocalSocketOption(Socket: PLocalSocket; Option: LongWord; Value: Int64): LongInt;
begin
  Result := ErrorNone;
  LockLocalSockets;
  case Option of
    SocketOptionNonBlocking: Socket^.NonBlocking := Value <> 0;
    SocketOptionPassCredentials: Socket^.PassCredentials := Value <> 0;
    SocketOptionReceiveTimeout:
      if Value < 0 then
        Result := ErrorInvalidArgument
      else
        Socket^.ReceiveTimeout := QWord(Value);
    SocketOptionSendTimeout:
      if Value < 0 then
        Result := ErrorInvalidArgument
      else
        Socket^.SendTimeout := QWord(Value);
    SocketOptionReceiveBuffer:
      begin
        if Value < MinimumLocalCapacity then
          Value := MinimumLocalCapacity;
        if Value > MaximumLocalCapacity then
          Value := MaximumLocalCapacity;
        Socket^.Capacity := QWord(Value);
        UpdateReadinessLocked(Socket);
      end;
    { The receiver's queue bounds what waits; taken, as on Linux. }
    SocketOptionSendBuffer: ;
  else
    Result := ErrorUnsupported;
  end;
  UnlockLocalSockets;
end;

function ConditionsHoldingLocked(Socket: PLocalSocket; Conditions: LongWord): LongWord;
begin
  Result := 0;
  if ((Conditions and SocketReadable) <> 0) and IsReadableLocked(Socket) then
    Result := Result or SocketReadable;
  if ((Conditions and SocketWritable) <> 0) and IsWritableLocked(Socket) then
    Result := Result or SocketWritable;
end;

function WaitForLocalSocket(Socket: PLocalSocket; Conditions: LongWord; TimeoutMilliseconds: Int64): Int64;
var
  Events: array[0..1] of PEvent;
  Count: LongInt;
  Signaled: LongInt;
  Timeout: QWord;
  Holding: LongWord;
  Target: PLocalSocket;
  Outcome: TWaitResult;
begin
  if TimeoutMilliseconds < 0 then
    Timeout := InfiniteTimeout
  else
    Timeout := QWord(TimeoutMilliseconds);
  repeat
    Target := nil;
    LockLocalSockets;
    Holding := ConditionsHoldingLocked(Socket, Conditions);
    if (Holding = 0) and ((Conditions and SocketWritable) <> 0) then
    begin
      Target := SendTargetLocked(Socket);
      if Target <> nil then
        ReferenceObject(Target);
    end;
    UnlockLocalSockets;
    if Holding <> 0 then
      Exit(Holding);
    if Timeout = 0 then
    begin
      if Target <> nil then
        DereferenceObject(Target);
      Exit(-Int64(ErrorTimedOut));
    end;
    Count := 0;
    if (Conditions and SocketReadable) <> 0 then
    begin
      Events[Count] := @Socket^.Readable;
      Inc(Count);
    end;
    if Target <> nil then
    begin
      Events[Count] := @Target^.Room;
      Inc(Count);
    end;
    if Count = 0 then
      { Nothing to wait for that could change (an idle socket). }
      Outcome := WaitTimedOut
    else
      Outcome := WaitForAnyEvent(@Events[0], Count, Timeout, True, Signaled);
    if Target <> nil then
      DereferenceObject(Target);
    case Outcome of
      WaitTimedOut: Exit(-Int64(ErrorTimedOut));
      WaitAlerted: Exit(-Int64(ErrorInterrupted));
    end;
    { Signaled: look again (another reader may have taken it); the
      remaining time is not tracked, as for network sockets. }
  until False;
end;

function GetLocalPeer(Socket: PLocalSocket; out Name: TAbiLocalSocketName;
  out Credentials: TAbiLocalCredentials): LongInt;
begin
  FillMemory(@Name, SizeOf(Name), 0);
  FillMemory(@Credentials, SizeOf(Credentials), 0);
  LockLocalSockets;
  if (Socket^.State <> LocalSocketConnected) or (Socket^.Peer = nil) then
    Result := ErrorNotConnected
  else
  begin
    Name := Socket^.Peer^.Name;
    Credentials := Socket^.PeerCredentials;
    Result := ErrorNone;
  end;
  UnlockLocalSockets;
end;

end.
