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
  Ports and channels: messages between programs, which can carry
  handles.

  A channel is a pair of connected ends; each is an object a program
  holds a handle to. A message sent on one end is queued at the other,
  up to MaximumQueuedMessages (beyond that sending fails with
  ErrorWouldBlock: a server never waits for a slow client). Receiving
  takes the oldest message, or fails with ErrorWouldBlock if there is
  none, or ErrorBrokenPipe once the other end is gone and nothing is
  left. Each end's Readable event is signaled while a receive would not
  wait, for waiting on several handles.

  A message is up to MaximumMessageBytes of data and MaximumMessageHandles
  handles. The handles travel as references of their own (taken when the
  message is sent, the sender keeps its handle), which become handles of
  the receiver when it receives the message, or are given back if the
  message is never received.

  A port is how a channel starts: a server creates a named port, a
  client connects to the name and gets one end of a new channel, the
  other end waits at the port until the server accepts it. A port's
  Pending event is signaled while connections wait.

  Each end remembers who holds the other one (TAbiChannelPeer): the
  process that connected, for the server's end, and the one that
  accepted, for the client's (the maker of a pair, for both of its
  ends), so a server can tell who asks (the service manager lets only
  root stop services).

  Both ends of a channel share a lock (in a pair record, freed with the
  second end). The names of ports are kept apart from other objects'
  with a prefix.
}
unit Processes.Channels;

{$mode objfpc}
{$pointermath on}

interface

uses
  Abi.SystemCalls,
  Runtime.LinkedList,
  Kernel.Events,
  Kernel.Mutex,
  Processes.Handles;

const
  { (The message and queue limits are the Abi's.) }
  MaximumPendingConnections = 16;

type
  PChannelMessage = ^TChannelMessage;
  TChannelMessage = record
    Link: TListEntry;
    Length: LongWord;
    HandleCount: LongWord;
    Kinds: array[0..MaximumMessageHandles - 1] of THandleKind;
    Bodies: array[0..MaximumMessageHandles - 1] of Pointer;
    { Length bytes follow. }
    Data: array[0..0] of Byte;
  end;

  PChannelPair = ^TChannelPair;
  PChannelEnd = ^TChannelEnd;
  TChannelEnd = record
    Pair: PChannelPair;
    Incoming: TListEntry;
    IncomingCount: LongInt;
    PeerClosed: Boolean;
    Readable: TEvent;
    { Waiting at a port to be accepted. }
    PendingLink: TListEntry;
    { Who holds the other end, once known. }
    Peer: TAbiChannelPeer;
    HasPeer: Boolean;
  end;

  TChannelPair = record
    Lock: TMutex;
    Ends: array[0..1] of PChannelEnd;
  end;

  PPort = ^TPort;
  TPort = record
    Lock: TMutex;
    PendingEnds: TListEntry;
    PendingCount: LongInt;
    Pending: TEvent;
  end;

procedure InitializeChannels;

{ Two connected ends, each with one reference (the caller's). }
function CreateChannel(out First, Second: PChannelEnd): LongInt;
{ Records Holder as the one holding the other end of Channel. }
procedure SetChannelPeer(Channel: PChannelEnd; const Holder: TAbiChannelPeer);
{ Who holds the other end of Channel; False while it is not known (a
  connection not yet accepted). }
function GetChannelPeer(Channel: PChannelEnd; out Holder: TAbiChannelPeer): Boolean;
{ A message of Length bytes with HandleCount handles (whose references
  the caller has taken; on failure they are the caller's still). }
function NewMessage(Length, HandleCount: LongWord): PChannelMessage;
procedure FreeMessage(Message: PChannelMessage);
{ Queues Message at the other end (it belongs to the channel then).
  ErrorNone, ErrorBrokenPipe or ErrorWouldBlock. }
function SendMessage(Channel: PChannelEnd; Message: PChannelMessage): LongInt;
{ Takes the oldest message if it fits in Capacity bytes and
  HandleCapacity handles; else ErrorMessageTooLong with Needed and
  NeededHandles set (the message stays). ErrorWouldBlock, ErrorBrokenPipe. }
function ReceiveMessage(Channel: PChannelEnd; Capacity, HandleCapacity: LongWord; out Message: PChannelMessage;
  out Needed, NeededHandles: LongWord): LongInt;

{ A port named Name (the caller's reference), \Ports\<Name> in the
  object namespace, owned by OwnerId and GroupId; ErrorExists if taken. }
function CreatePort(Name: PChar; OwnerId, GroupId: LongWord; out Port: PPort): LongInt;
{ Connects Client to the port named Name: the client's end (the
  caller's reference). ErrorNotFound, ErrorBusy (too many waiting). }
function ConnectToPort(Name: PChar; const Client: TAbiChannelPeer; out Channel: PChannelEnd): LongInt;
{ The oldest waiting connection's end (the caller's reference), whose
  client learns that Server accepted it; or ErrorWouldBlock. }
function AcceptConnection(Port: PPort; const Server: TAbiChannelPeer; out Channel: PChannelEnd): LongInt;

implementation

uses
  Runtime.Memory,
  Runtime.Text,
  Memory.KernelHeap,
  Objects.Manager,
  Objects.Namespace;

const
  PortNamePrefix: PChar = '\Ports\';
  PortPathCapacity = 8 + MaximumPortNameLength + 1;
  { Anyone may connect (the server checks its peers). }
  PortNameMode = $1B6; { rw-rw-rw- }

var
  ChannelObjectType: TObjectType;
  PortObjectType: TObjectType;

function MessageOfLink(Entry: PListEntry): PChannelMessage;
begin
  Result := PChannelMessage(Entry);
end;

function EndOfPendingLink(Entry: PListEntry): PChannelEnd;
begin
  Result := PChannelEnd(ContainingRecord(Entry, FieldOffset(PChannelEnd(nil)^.PendingLink)));
end;

function NewMessage(Length, HandleCount: LongWord): PChannelMessage;
begin
  Result := nil;
  if (Length > MaximumMessageBytes) or (HandleCount > MaximumMessageHandles) then
    Exit;
  Result := PChannelMessage(AllocateZeroedKernelMemory(SizeOf(TChannelMessage) + Length));
  if Result = nil then
    Exit;
  Result^.Length := Length;
  Result^.HandleCount := HandleCount;
end;

procedure FreeMessage(Message: PChannelMessage);
begin
  FreeKernelMemory(Message);
end;

{ A message never received: its handles' references go back. }
procedure DiscardMessage(Message: PChannelMessage);
var
  Index: LongWord;
begin
  for Index := 1 to Message^.HandleCount do
    DropHandleReference(Message^.Kinds[Index - 1], Message^.Bodies[Index - 1]);
  FreeMessage(Message);
end;

{ The other end of Channel; nil if it is gone. Pair lock held. }
function PeerOf(Channel: PChannelEnd): PChannelEnd;
begin
  if Channel^.Pair^.Ends[0] = Channel then
    Result := Channel^.Pair^.Ends[1]
  else
    Result := Channel^.Pair^.Ends[0];
end;

{ Readable follows the end's state. Pair lock held. }
procedure UpdateReadableLocked(Channel: PChannelEnd);
begin
  if (Channel^.IncomingCount > 0) or Channel^.PeerClosed then
    SignalEvent(Channel^.Readable)
  else
    ResetEvent(Channel^.Readable);
end;

procedure DeleteChannelEnd(ObjectBody: Pointer);
var
  Channel: PChannelEnd;
  Pair: PChannelPair;
  Peer: PChannelEnd;
  Unread: TListEntry;
  Entry: PListEntry;
  LastEnd: Boolean;
begin
  Channel := PChannelEnd(ObjectBody);
  Pair := Channel^.Pair;
  if Pair = nil then
    Exit;
  InitializeListHead(Unread);
  AcquireMutex(Pair^.Lock);
  Peer := PeerOf(Channel);
  if Peer <> nil then
  begin
    Peer^.PeerClosed := True;
    UpdateReadableLocked(Peer);
  end;
  { Moved out, to be given back once the lock is free: a message may
    hold the last reference to another channel's end. }
  while not ListIsEmpty(Channel^.Incoming) do
    InsertAtTail(Unread, RemoveHeadEntry(Channel^.Incoming));
  Channel^.IncomingCount := 0;
  if Pair^.Ends[0] = Channel then
    Pair^.Ends[0] := nil
  else
    Pair^.Ends[1] := nil;
  LastEnd := (Pair^.Ends[0] = nil) and (Pair^.Ends[1] = nil);
  ReleaseMutex(Pair^.Lock);
  if LastEnd then
    FreeKernelMemory(Pair);
  repeat
    Entry := RemoveHeadEntry(Unread);
    if Entry <> nil then
      DiscardMessage(MessageOfLink(Entry));
  until Entry = nil;
end;

procedure DeletePort(ObjectBody: Pointer);
var
  Port: PPort;
  Entry: PListEntry;
begin
  Port := PPort(ObjectBody);
  repeat
    AcquireMutex(Port^.Lock);
    Entry := RemoveHeadEntry(Port^.PendingEnds);
    ReleaseMutex(Port^.Lock);
    if Entry <> nil then
      DereferenceObject(EndOfPendingLink(Entry));
  until Entry = nil;
end;

procedure InitializeChannels;
begin
  RegisterObjectType(ChannelObjectType, 'Channel', SizeOf(TChannelEnd), @DeleteChannelEnd);
  RegisterObjectType(PortObjectType, 'Port', SizeOf(TPort), @DeletePort);
end;

function NewEnd(Pair: PChannelPair): PChannelEnd;
begin
  Result := PChannelEnd(CreateObject(ChannelObjectType, nil));
  if Result = nil then
    Exit;
  Result^.Pair := Pair;
  InitializeListHead(Result^.Incoming);
  InitializeListHead(Result^.PendingLink);
  InitializeEvent(Result^.Readable, EventKindNotification, False);
  Result^.HasPeer := False;
end;

procedure SetChannelPeer(Channel: PChannelEnd; const Holder: TAbiChannelPeer);
begin
  AcquireMutex(Channel^.Pair^.Lock);
  Channel^.Peer := Holder;
  Channel^.HasPeer := True;
  ReleaseMutex(Channel^.Pair^.Lock);
end;

function GetChannelPeer(Channel: PChannelEnd; out Holder: TAbiChannelPeer): Boolean;
begin
  AcquireMutex(Channel^.Pair^.Lock);
  Holder := Channel^.Peer;
  Result := Channel^.HasPeer;
  ReleaseMutex(Channel^.Pair^.Lock);
end;

function CreateChannel(out First, Second: PChannelEnd): LongInt;
var
  Pair: PChannelPair;
begin
  First := nil;
  Second := nil;
  Pair := PChannelPair(AllocateZeroedKernelMemory(SizeOf(TChannelPair)));
  if Pair = nil then
    Exit(ErrorOutOfMemory);
  InitializeMutex(Pair^.Lock);
  First := NewEnd(Pair);
  if First = nil then
  begin
    FreeKernelMemory(Pair);
    Exit(ErrorOutOfMemory);
  end;
  Pair^.Ends[0] := First;
  Second := NewEnd(Pair);
  if Second = nil then
  begin
    { Deleting the first end frees the pair. }
    DereferenceObject(First);
    First := nil;
    Exit(ErrorOutOfMemory);
  end;
  Pair^.Ends[1] := Second;
  Result := ErrorNone;
end;

function SendMessage(Channel: PChannelEnd; Message: PChannelMessage): LongInt;
var
  Peer: PChannelEnd;
begin
  AcquireMutex(Channel^.Pair^.Lock);
  Peer := PeerOf(Channel);
  if Peer = nil then
    Result := ErrorBrokenPipe
  else if Peer^.IncomingCount >= MaximumQueuedMessages then
    Result := ErrorWouldBlock
  else
  begin
    InsertAtTail(Peer^.Incoming, @Message^.Link);
    Inc(Peer^.IncomingCount);
    UpdateReadableLocked(Peer);
    Result := ErrorNone;
  end;
  ReleaseMutex(Channel^.Pair^.Lock);
end;

function ReceiveMessage(Channel: PChannelEnd; Capacity, HandleCapacity: LongWord; out Message: PChannelMessage;
  out Needed, NeededHandles: LongWord): LongInt;
var
  Oldest: PChannelMessage;
begin
  Message := nil;
  Needed := 0;
  NeededHandles := 0;
  AcquireMutex(Channel^.Pair^.Lock);
  if Channel^.IncomingCount = 0 then
  begin
    if Channel^.PeerClosed then
      Result := ErrorBrokenPipe
    else
      Result := ErrorWouldBlock;
  end
  else
  begin
    Oldest := MessageOfLink(FirstListEntry(Channel^.Incoming));
    Needed := Oldest^.Length;
    NeededHandles := Oldest^.HandleCount;
    if (Oldest^.Length > Capacity) or (Oldest^.HandleCount > HandleCapacity) then
      Result := ErrorMessageTooLong
    else
    begin
      RemoveListEntry(@Oldest^.Link);
      Dec(Channel^.IncomingCount);
      UpdateReadableLocked(Channel);
      Message := Oldest;
      Result := ErrorNone;
    end;
  end;
  ReleaseMutex(Channel^.Pair^.Lock);
end;

{ --- Ports -------------------------------------------------------------- }

{ The port's path in the object namespace, \Ports\ and Name, into
  Buffer; False if Name is empty, too long or has a backslash. }
function PortObjectName(Name: PChar; Buffer: PChar): Boolean;
var
  Length: PtrUInt;
  Index: PtrUInt;
begin
  Length := TextLength(Name);
  if (Length = 0) or (Length > MaximumPortNameLength) then
    Exit(False);
  for Index := 1 to Length do
    if Name[Index - 1] = '\' then
      Exit(False);
  CopyMemory(Buffer, PortNamePrefix, TextLength(PortNamePrefix));
  CopyMemory(Buffer + TextLength(PortNamePrefix), Name, Length + 1);
  Result := True;
end;

function CreatePort(Name: PChar; OwnerId, GroupId: LongWord; out Port: PPort): LongInt;
var
  ObjectName: array[0..PortPathCapacity - 1] of Char;
begin
  Port := nil;
  if not PortObjectName(Name, @ObjectName[0]) then
    Exit(ErrorInvalidArgument);
  Port := PPort(CreateObject(PortObjectType, nil));
  if Port = nil then
    Exit(ErrorOutOfMemory);
  InitializeMutex(Port^.Lock);
  InitializeListHead(Port^.PendingEnds);
  InitializeEvent(Port^.Pending, EventKindNotification, False);
  { Named only once ready: whoever finds it may connect at once. }
  Result := InsertObjectName(Port, @ObjectName[0], OwnerId, GroupId, PortNameMode, KernelNamespaceCaller);
  if Result <> ErrorNone then
  begin
    DereferenceObject(Port);
    Port := nil;
  end;
end;

function ConnectToPort(Name: PChar; const Client: TAbiChannelPeer; out Channel: PChannelEnd): LongInt;
var
  ObjectName: array[0..PortPathCapacity - 1] of Char;
  Port: PPort;
  ServerEnd: PChannelEnd;
begin
  Channel := nil;
  if not PortObjectName(Name, @ObjectName[0]) then
    Exit(ErrorInvalidArgument);
  Port := PPort(LookupObjectByName(@ObjectName[0], @PortObjectType));
  if Port = nil then
    Exit(ErrorNotFound);
  Result := CreateChannel(Channel, ServerEnd);
  if Result <> ErrorNone then
  begin
    DereferenceObject(Port);
    Exit;
  end;
  { Known before the server can accept it. }
  ServerEnd^.Peer := Client;
  ServerEnd^.HasPeer := True;
  AcquireMutex(Port^.Lock);
  if Port^.PendingCount >= MaximumPendingConnections then
    Result := ErrorBusy
  else
  begin
    { The port keeps the server end's reference until it is accepted. }
    InsertAtTail(Port^.PendingEnds, @ServerEnd^.PendingLink);
    Inc(Port^.PendingCount);
    SignalEvent(Port^.Pending);
  end;
  ReleaseMutex(Port^.Lock);
  if Result <> ErrorNone then
  begin
    DereferenceObject(ServerEnd);
    DereferenceObject(Channel);
    Channel := nil;
  end;
  DereferenceObject(Port);
end;

function AcceptConnection(Port: PPort; const Server: TAbiChannelPeer; out Channel: PChannelEnd): LongInt;
var
  Entry: PListEntry;
  ClientEnd: PChannelEnd;
begin
  Channel := nil;
  AcquireMutex(Port^.Lock);
  Entry := RemoveHeadEntry(Port^.PendingEnds);
  if Entry <> nil then
  begin
    Dec(Port^.PendingCount);
    Channel := EndOfPendingLink(Entry);
  end;
  if Port^.PendingCount = 0 then
    ResetEvent(Port^.Pending);
  ReleaseMutex(Port^.Lock);
  if Channel = nil then
    Exit(ErrorWouldBlock);
  AcquireMutex(Channel^.Pair^.Lock);
  ClientEnd := PeerOf(Channel);
  if ClientEnd <> nil then
  begin
    ClientEnd^.Peer := Server;
    ClientEnd^.HasPeer := True;
  end;
  ReleaseMutex(Channel^.Pair^.Lock);
  Result := ErrorNone;
end;

end.
