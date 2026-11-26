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
  Event polls (epoll): a set of objects to wait on together, of any
  size, that says which are ready without looking at all of them.

  A poll holds registrations (entries), one per handle number and object
  added, with the events wanted (PollReadable, PollWritable; PollError and
  PollHangUp always) and a value of the program's. Each entry holds a
  reference to its object and has an observer (Kernel.Events) on each of
  the object's readiness events (Processes.HandleReadiness): whenever one
  is signaled the observer puts the entry on the poll's ready list and
  signals the poll's Ready event, at whatever level the signal came,
  with the event lock (the dispatcher lock) held, which guards the ready
  list too.

  A wait (EventPollWait) takes entries off the ready list and asks each
  object what it is ready for now; what it was registered for is
  reported. A level triggered entry still ready goes back on the list (so
  the next wait looks again and reports it as long as it stays ready),
  an edge triggered one waits for the next signal, a one shot one is
  disabled until modified. A wait that finds nothing resets Ready (only
  while the list is empty, under the event lock, so no signal is lost)
  and waits on it. An entry put back during a wait is not taken twice in
  it.

  Entries are added with the list already holding them (they are checked
  once at once). A registration lasts until removed, until the poll
  goes, or until the last handle of its object is closed, in any process
  (ForgetObjectInEventPolls, called by Processes.Handles: the object
  header counts handles): so closing a socket's last descriptor really
  closes it, as on other systems. Each object keeps the list of the
  entries on it in its header (ObjectPollRegistrationsOf).

  Polls can hold polls (a poll's Ready is its readiness event), at most
  PollMaximumNesting deep and never in a loop.

  Locking: one mutex (EventPollLock) guards every poll's entries and the
  objects' registration lists; the ready lists and the entries' IsQueued
  are the event lock's. Objects are dereferenced (and entries freed)
  after the mutex is let go, so a delete routine never runs under it.
}
unit Processes.EventPolls;

{$mode objfpc}
{$pointermath on}

interface

uses
  Runtime.LinkedList,
  Abi.SystemCalls,
  Kernel.Events,
  Processes.Handles,
  Processes.HandleReadiness;

const
  EventPollBucketCount = 64;

type
  PEventPoll = ^TEventPoll;
  PEventPollEntry = ^TEventPollEntry;
  TEventPollEntry = record
    Poll: PEventPoll;
    HandleNumber: Int64;
    Kind: THandleKind;
    ObjectBody: Pointer;
    { Poll* events and flags. }
    Requested: LongWord;
    Data: QWord;
    { A one shot entry that reported (until modified). }
    Disabled: Boolean;
    Observers: array[0..MaximumReadinessEvents - 1] of TEventObserver;
    ObserverCount: LongInt;
    { In the poll's list of entries, its bucket, and the object's list. }
    InterestLink: TListEntry;
    NextInBucket: PEventPollEntry;
    NextOfObject: PEventPollEntry;
    { On the ready list (event lock). }
    ReadyLink: TListEntry;
    IsQueued: Boolean;
    { The wait that last took it off the ready list. }
    SeenGeneration: QWord;
  end;

  TEventPoll = record
    { Signaled while the ready list is not empty. }
    Ready: TEvent;
    Interest: TListEntry;
    Buckets: array[0..EventPollBucketCount - 1] of PEventPollEntry;
    EntryCount: LongInt;
    ReadyList: TListEntry;
    Generation: QWord;
  end;

procedure InitializeEventPolls;
{ A new empty poll with one reference (the caller's), or nil. }
function CreateEventPoll: PEventPoll;

{ Registers the object Kind/ObjectBody (named by HandleNumber) for
  Events (Poll* events and flags) with Data. With RequireOpenHandle the
  object must still have a handle once registered (ErrorBadHandle
  otherwise): a handle closed meanwhile would never take it out again.
  Returns an Abi error. }
function EventPollAdd(Poll: PEventPoll; HandleNumber: Int64; Kind: THandleKind; ObjectBody: Pointer;
  Events: LongWord; Data: QWord; RequireOpenHandle: Boolean): LongInt;
function EventPollModify(Poll: PEventPoll; HandleNumber: Int64; ObjectBody: Pointer; Events: LongWord;
  Data: QWord): LongInt;
function EventPollRemove(Poll: PEventPoll; HandleNumber: Int64; ObjectBody: Pointer): LongInt;
{ Waits up to TimeoutMilliseconds (InfiniteTimeout: no limit, 0: only
  looks) for ready entries and writes up to Capacity of them into Events
  (kernel memory): how many, or a negative Abi error (ErrorInterrupted). }
function EventPollWait(Poll: PEventPoll; Events: PAbiPollEvent; Capacity: LongInt;
  TimeoutMilliseconds: QWord): Int64;
function EventPollReadiness(Poll: PEventPoll): LongWord;

{ From Processes.Handles: the last handle of ObjectBody was closed. }
procedure ForgetObjectInEventPolls(ObjectBody: Pointer);

implementation

uses
  Runtime.Atomic,
  Memory.KernelHeap,
  Kernel.PriorityLevel,
  Kernel.Mutex,
  Kernel.Threads,
  Kernel.Scheduler,
  Kernel.Clock,
  Objects.Manager;

const
  { The events that may be asked for; PollError and PollHangUp come
    whatever is asked. }
  WantableEvents = PollReadable or PollWritable or PollPriority or PollReadHangUp or PollError or PollHangUp;
  AlwaysWanted = PollError or PollHangUp;
  RegistrationFlags = PollExclusive or PollWakeUp or PollOneShot or PollEdgeTriggered;

var
  EventPollType: TObjectType;
  EventPollLock: TMutex;
  { Entries in every poll: while there are none, closing a handle need
    not look for registrations. }
  LiveEntryCount: Int64 = 0;

function EntryFromInterestLink(Entry: PListEntry): PEventPollEntry;
begin
  Result := PEventPollEntry(ContainingRecord(Entry, FieldOffset(PEventPollEntry(nil)^.InterestLink)));
end;

function EntryFromReadyLink(Entry: PListEntry): PEventPollEntry;
begin
  Result := PEventPollEntry(ContainingRecord(Entry, FieldOffset(PEventPollEntry(nil)^.ReadyLink)));
end;

function BucketOf(HandleNumber: Int64): LongInt;
begin
  Result := LongInt(QWord(HandleNumber) mod EventPollBucketCount);
end;

{ --- The ready list (event lock) -------------------------------------------- }

{ Puts Entry on its poll's ready list (if it is not there) and signals
  the poll's Ready; event lock held. }
procedure QueueEntryLocked(Entry: PEventPollEntry);
var
  Poll: PEventPoll;
begin
  if Entry^.IsQueued then
    Exit;
  Poll := Entry^.Poll;
  InsertAtTail(Poll^.ReadyList, @Entry^.ReadyLink);
  Entry^.IsQueued := True;
  if not Poll^.Ready.IsSignaled then
    SignalEventLocked(Poll^.Ready);
end;

{ The observer's routine: one of the object's readiness events was
  signaled. }
procedure EntrySignaled(Observer: PEventObserver);
begin
  QueueEntryLocked(PEventPollEntry(Observer^.Context));
end;

procedure QueueEntry(Entry: PEventPollEntry);
var
  PreviousLevel: TPriorityLevel;
begin
  PreviousLevel := AcquireEventLock;
  QueueEntryLocked(Entry);
  ReleaseEventLock(PreviousLevel);
end;

procedure UnqueueEntry(Entry: PEventPollEntry);
var
  PreviousLevel: TPriorityLevel;
begin
  PreviousLevel := AcquireEventLock;
  if Entry^.IsQueued then
  begin
    RemoveListEntry(@Entry^.ReadyLink);
    Entry^.IsQueued := False;
  end;
  ReleaseEventLock(PreviousLevel);
end;

{ --- Entries (EventPollLock held) --------------------------------------------- }

function FindEntry(Poll: PEventPoll; HandleNumber: Int64; ObjectBody: Pointer): PEventPollEntry;
begin
  Result := Poll^.Buckets[BucketOf(HandleNumber)];
  while (Result <> nil) and ((Result^.HandleNumber <> HandleNumber) or (Result^.ObjectBody <> ObjectBody)) do
    Result := Result^.NextInBucket;
end;

procedure UnlinkFromBucket(Entry: PEventPollEntry);
var
  Link: ^PEventPollEntry;
begin
  Link := @Entry^.Poll^.Buckets[BucketOf(Entry^.HandleNumber)];
  while (Link^ <> nil) and (Link^ <> Entry) do
    Link := @Link^^.NextInBucket;
  if Link^ = Entry then
    Link^ := Entry^.NextInBucket;
  Entry^.NextInBucket := nil;
end;

procedure UnlinkFromObject(Entry: PEventPollEntry);
var
  Link: ^PEventPollEntry;
begin
  Link := Pointer(ObjectPollRegistrationsOf(Entry^.ObjectBody));
  while (Link^ <> nil) and (Link^ <> Entry) do
    Link := @Link^^.NextOfObject;
  if Link^ = Entry then
    Link^ := Entry^.NextOfObject;
  Entry^.NextOfObject := nil;
end;

procedure AttachObservers(Entry: PEventPollEntry);
var
  Events: TReadinessEvents;
  Index: LongInt;
begin
  Entry^.ObserverCount := HandleReadinessEvents(Entry^.Kind, Entry^.ObjectBody, Events);
  for Index := 0 to Entry^.ObserverCount - 1 do
    AttachEventObserver(Events[Index]^, Entry^.Observers[Index], @EntrySignaled, Entry);
end;

procedure DetachObservers(Entry: PEventPollEntry);
var
  Index: LongInt;
begin
  for Index := 0 to Entry^.ObserverCount - 1 do
    DetachEventObserver(Entry^.Observers[Index]);
  Entry^.ObserverCount := 0;
end;

{ Takes Entry out of everything; the caller frees it (FreeEntries) once
  EventPollLock is let go. }
procedure TakeOutEntry(Entry: PEventPollEntry);
begin
  DetachObservers(Entry);
  UnqueueEntry(Entry);
  RemoveListEntry(@Entry^.InterestLink);
  UnlinkFromBucket(Entry);
  UnlinkFromObject(Entry);
  Dec(Entry^.Poll^.EntryCount);
  AtomicDecrement(LiveEntryCount);
end;

{ Entries taken out, chained by NextOfObject: their objects are
  dereferenced and they are freed (EventPollLock not held). }
procedure FreeEntries(First: PEventPollEntry);
var
  Following: PEventPollEntry;
begin
  while First <> nil do
  begin
    Following := First^.NextOfObject;
    DereferenceObject(First^.ObjectBody);
    FreeKernelMemory(First);
    First := Following;
  end;
end;

{ --- Nesting (EventPollLock held) ----------------------------------------------- }

{ How deep polls go below Poll (0: it holds none), up to Limit. }
function DepthBelow(Poll: PEventPoll; Limit: LongInt): LongInt;
var
  Link: PListEntry;
  Entry: PEventPollEntry;
  Depth: LongInt;
begin
  Result := 0;
  if Limit <= 0 then
    Exit;
  Link := Poll^.Interest.Next;
  while Link <> @Poll^.Interest do
  begin
    Entry := EntryFromInterestLink(Link);
    if Entry^.Kind = HandleKindEventPoll then
    begin
      Depth := 1 + DepthBelow(PEventPoll(Entry^.ObjectBody), Limit - 1);
      if Depth > Result then
        Result := Depth;
    end;
    Link := Link^.Next;
  end;
end;

{ How deep Poll is inside other polls (0: in none), up to Limit. }
function DepthAbove(Poll: PEventPoll; Limit: LongInt): LongInt;
var
  Entry: PEventPollEntry;
  Depth: LongInt;
begin
  Result := 0;
  if Limit <= 0 then
    Exit;
  Entry := PEventPollEntry(ObjectPollRegistrationsOf(Poll)^);
  while Entry <> nil do
  begin
    Depth := 1 + DepthAbove(Entry^.Poll, Limit - 1);
    if Depth > Result then
      Result := Depth;
    Entry := Entry^.NextOfObject;
  end;
end;

{ Whether Target is Poll or inside it, looking at most Limit deep. }
function Contains(Poll, Target: PEventPoll; Limit: LongInt): Boolean;
var
  Link: PListEntry;
  Entry: PEventPollEntry;
begin
  if Poll = Target then
    Exit(True);
  Result := False;
  if Limit <= 0 then
    Exit;
  Link := Poll^.Interest.Next;
  while Link <> @Poll^.Interest do
  begin
    Entry := EntryFromInterestLink(Link);
    if (Entry^.Kind = HandleKindEventPoll) and Contains(PEventPoll(Entry^.ObjectBody), Target, Limit - 1) then
      Exit(True);
    Link := Link^.Next;
  end;
end;

{ ErrorNone if Inner may go into Outer. }
function CheckNesting(Outer, Inner: PEventPoll): LongInt;
begin
  if Contains(Inner, Outer, PollMaximumNesting + 1) then
    Exit(ErrorTooManyLinks);
  if DepthAbove(Outer, PollMaximumNesting + 1) + 1 + DepthBelow(Inner, PollMaximumNesting + 1) >
     PollMaximumNesting then
    Exit(ErrorTooManyLinks);
  Result := ErrorNone;
end;

{ --- Objects ------------------------------------------------------------------ }

procedure DeleteEventPoll(ObjectBody: Pointer);
var
  Poll: PEventPoll;
  Entry: PEventPollEntry;
  Taken: PEventPollEntry;
begin
  Poll := PEventPoll(ObjectBody);
  Taken := nil;
  AcquireMutex(EventPollLock);
  while not ListIsEmpty(Poll^.Interest) do
  begin
    Entry := EntryFromInterestLink(Poll^.Interest.Next);
    TakeOutEntry(Entry);
    Entry^.NextOfObject := Taken;
    Taken := Entry;
  end;
  ReleaseMutex(EventPollLock);
  FreeEntries(Taken);
end;

procedure InitializeEventPolls;
begin
  RegisterObjectType(EventPollType, 'EventPoll', SizeOf(TEventPoll), @DeleteEventPoll);
  InitializeMutex(EventPollLock);
end;

function CreateEventPoll: PEventPoll;
begin
  Result := PEventPoll(CreateObject(EventPollType, nil));
  if Result = nil then
    Exit;
  InitializeEvent(Result^.Ready, EventKindNotification, False);
  InitializeListHead(Result^.Interest);
  InitializeListHead(Result^.ReadyList);
end;

function RequestIsValid(Events: LongWord): Boolean;
begin
  Result := (Events and not (WantableEvents or RegistrationFlags)) = 0;
end;

function EventPollAdd(Poll: PEventPoll; HandleNumber: Int64; Kind: THandleKind; ObjectBody: Pointer;
  Events: LongWord; Data: QWord; RequireOpenHandle: Boolean): LongInt;
var
  Entry: PEventPollEntry;
begin
  if not RequestIsValid(Events) or (ObjectBody = Pointer(Poll)) then
    Exit(ErrorInvalidArgument);
  if HandleIsAlwaysReady(Kind, ObjectBody) then
    Exit(ErrorNotPermitted);
  AcquireMutex(EventPollLock);
  if FindEntry(Poll, HandleNumber, ObjectBody) <> nil then
  begin
    ReleaseMutex(EventPollLock);
    Exit(ErrorExists);
  end;
  if Kind = HandleKindEventPoll then
  begin
    Result := CheckNesting(Poll, PEventPoll(ObjectBody));
    if Result <> ErrorNone then
    begin
      ReleaseMutex(EventPollLock);
      Exit;
    end;
  end;
  Entry := PEventPollEntry(AllocateZeroedKernelMemory(SizeOf(TEventPollEntry)));
  if Entry = nil then
  begin
    ReleaseMutex(EventPollLock);
    Exit(ErrorOutOfMemory);
  end;
  ReferenceObject(ObjectBody);
  Entry^.Poll := Poll;
  Entry^.HandleNumber := HandleNumber;
  Entry^.Kind := Kind;
  Entry^.ObjectBody := ObjectBody;
  Entry^.Requested := Events;
  Entry^.Data := Data;
  InsertAtTail(Poll^.Interest, @Entry^.InterestLink);
  Entry^.NextInBucket := Poll^.Buckets[BucketOf(HandleNumber)];
  Poll^.Buckets[BucketOf(HandleNumber)] := Entry;
  Entry^.NextOfObject := PEventPollEntry(ObjectPollRegistrationsOf(ObjectBody)^);
  ObjectPollRegistrationsOf(ObjectBody)^ := Entry;
  Inc(Poll^.EntryCount);
  AtomicIncrement(LiveEntryCount);
  { Counted before the handles are looked at: a last handle closed from
    now on finds the entry (Objects.Manager orders its side). }
  FullMemoryBarrier;
  if RequireOpenHandle and (ObjectHandleCount(ObjectBody) <= 0) then
  begin
    TakeOutEntry(Entry);
    ReleaseMutex(EventPollLock);
    Entry^.NextOfObject := nil;
    FreeEntries(Entry);
    Exit(ErrorBadHandle);
  end;
  AttachObservers(Entry);
  QueueEntry(Entry);
  ReleaseMutex(EventPollLock);
  Result := ErrorNone;
end;

function EventPollModify(Poll: PEventPoll; HandleNumber: Int64; ObjectBody: Pointer; Events: LongWord;
  Data: QWord): LongInt;
var
  Entry: PEventPollEntry;
begin
  if not RequestIsValid(Events) or ((Events and PollExclusive) <> 0) then
    Exit(ErrorInvalidArgument);
  AcquireMutex(EventPollLock);
  Entry := FindEntry(Poll, HandleNumber, ObjectBody);
  if Entry = nil then
    Result := ErrorNotFound
  else if (Entry^.Requested and PollExclusive) <> 0 then
    Result := ErrorInvalidArgument
  else
  begin
    Entry^.Requested := Events;
    Entry^.Data := Data;
    Entry^.Disabled := False;
    QueueEntry(Entry);
    Result := ErrorNone;
  end;
  ReleaseMutex(EventPollLock);
end;

function EventPollRemove(Poll: PEventPoll; HandleNumber: Int64; ObjectBody: Pointer): LongInt;
var
  Entry: PEventPollEntry;
begin
  AcquireMutex(EventPollLock);
  Entry := FindEntry(Poll, HandleNumber, ObjectBody);
  if Entry <> nil then
    TakeOutEntry(Entry);
  ReleaseMutex(EventPollLock);
  if Entry = nil then
    Exit(ErrorNotFound);
  Entry^.NextOfObject := nil;
  FreeEntries(Entry);
  Result := ErrorNone;
end;

procedure ForgetObjectInEventPolls(ObjectBody: Pointer);
var
  Entry: PEventPollEntry;
  Taken: PEventPollEntry;
begin
  if AtomicFetchAndAdd(LiveEntryCount, 0) = 0 then
    Exit;
  Taken := nil;
  AcquireMutex(EventPollLock);
  { A handle opened again meanwhile keeps the registrations. }
  if ObjectHandleCount(ObjectBody) <= 0 then
  begin
    Entry := PEventPollEntry(ObjectPollRegistrationsOf(ObjectBody)^);
    while Entry <> nil do
    begin
      TakeOutEntry(Entry);
      Entry^.NextOfObject := Taken;
      Taken := Entry;
      Entry := PEventPollEntry(ObjectPollRegistrationsOf(ObjectBody)^);
    end;
  end;
  ReleaseMutex(EventPollLock);
  FreeEntries(Taken);
end;

{ --- Waiting ---------------------------------------------------------------------- }

{ The next entry of the ready list not taken in this wait yet (taken
  off the list), or nil. }
function TakeReadyEntry(Poll: PEventPoll; Generation: QWord): PEventPollEntry;
var
  PreviousLevel: TPriorityLevel;
begin
  Result := nil;
  PreviousLevel := AcquireEventLock;
  if not ListIsEmpty(Poll^.ReadyList) then
  begin
    Result := EntryFromReadyLink(Poll^.ReadyList.Next);
    if Result^.SeenGeneration = Generation then
      Result := nil
    else
    begin
      RemoveListEntry(@Result^.ReadyLink);
      Result^.IsQueued := False;
    end;
  end;
  ReleaseEventLock(PreviousLevel);
end;

{ Puts the level triggered entries reported back on the list, and resets
  Ready if the list is empty. }
procedure FinishHarvest(Poll: PEventPoll; Requeued: PPointer; RequeuedCount: LongInt);
var
  PreviousLevel: TPriorityLevel;
  Index: LongInt;
begin
  PreviousLevel := AcquireEventLock;
  for Index := 0 to RequeuedCount - 1 do
    QueueEntryLocked(PEventPollEntry(Requeued[Index]));
  if ListIsEmpty(Poll^.ReadyList) then
    ResetEventLocked(Poll^.Ready);
  ReleaseEventLock(PreviousLevel);
end;

{ Reports what is ready (EventPollLock held): how many. }
function Harvest(Poll: PEventPoll; Events: PAbiPollEvent; Capacity: LongInt; Requeued: PPointer): LongInt;
var
  Entry: PEventPollEntry;
  Ready: LongWord;
  RequeuedCount: LongInt;
begin
  Result := 0;
  RequeuedCount := 0;
  Inc(Poll^.Generation);
  while Result < Capacity do
  begin
    Entry := TakeReadyEntry(Poll, Poll^.Generation);
    if Entry = nil then
      Break;
    Entry^.SeenGeneration := Poll^.Generation;
    if Entry^.Disabled then
      Continue;
    Ready := HandleReadiness(Entry^.Kind, Entry^.ObjectBody) and
      ((Entry^.Requested and WantableEvents) or AlwaysWanted);
    if Ready = 0 then
      Continue;
    Events[Result].Events := Ready;
    Events[Result].Reserved := 0;
    Events[Result].Data := Entry^.Data;
    Inc(Result);
    if (Entry^.Requested and PollOneShot) <> 0 then
      Entry^.Disabled := True
    else if (Entry^.Requested and PollEdgeTriggered) = 0 then
    begin
      Requeued[RequeuedCount] := Entry;
      Inc(RequeuedCount);
    end;
  end;
  FinishHarvest(Poll, Requeued, RequeuedCount);
end;

function EventPollWait(Poll: PEventPoll; Events: PAbiPollEvent; Capacity: LongInt;
  TimeoutMilliseconds: QWord): Int64;
var
  Requeued: PPointer;
  Deadline: QWord;
  Now: QWord;
  Remaining: QWord;
  WaitResult: TWaitResult;
begin
  if Capacity <= 0 then
    Exit(-Int64(ErrorInvalidArgument));
  Requeued := PPointer(AllocateKernelMemory(QWord(Capacity) * SizeOf(Pointer)));
  if Requeued = nil then
    Exit(-Int64(ErrorOutOfMemory));
  Deadline := InfiniteTimeout;
  if TimeoutMilliseconds <> InfiniteTimeout then
    Deadline := UptimeMilliseconds + TimeoutMilliseconds;
  repeat
    AcquireMutex(EventPollLock);
    Result := Harvest(Poll, Events, Capacity, Requeued);
    ReleaseMutex(EventPollLock);
    if (Result > 0) or (TimeoutMilliseconds = 0) then
      Break;
    Remaining := InfiniteTimeout;
    if Deadline <> InfiniteTimeout then
    begin
      Now := UptimeMilliseconds;
      if Now >= Deadline then
        Break;
      Remaining := Deadline - Now;
    end;
    WaitResult := WaitForEventWithOptions(Poll^.Ready, Remaining, True);
    if WaitResult = WaitTimedOut then
      Continue;
    if WaitResult <> WaitSignaled then
    begin
      Result := -Int64(ErrorInterrupted);
      Break;
    end;
  until False;
  FreeKernelMemory(Requeued);
end;

function EventPollReadiness(Poll: PEventPoll): LongWord;
begin
  Result := 0;
  if not ListIsEmpty(Poll^.ReadyList) then
    Result := PollReadable;
end;

end.
