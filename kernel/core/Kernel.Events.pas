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
  Events: the basic thread synchronization primitive.

  An event is either signaled or not. Threads that wait on a non-signaled
  event block until another thread (or an interrupt handler running at or
  below DispatchLevel) signals it. Two kinds exist:

    EventKindNotification     Stays signaled until reset explicitly and
                              releases every waiting thread.
    EventKindSynchronization  Releases exactly one waiting thread and
                              resets itself automatically.
    EventKindSemaphore        Holds a count (SignalCount) and is
                              signaled while it is above zero; each
                              waiter it releases takes one. Only
                              Kernel.Semaphores makes these.

  A thread may wait on several events at once and wake when any one of
  them is signaled (WaitForAnyEvent): it is linked into each one's
  waiters by a wait block (Kernel.Threads), and whichever event releases
  it first takes all its blocks off (the scheduler does, waking it), so
  it is released once and learns which event it was.

  Or it may wait until all of them are signaled at the same time
  (WaitForAllEvents). Each time one of its events is signaled, the
  others are looked at; only when every one is signaled is the wait
  satisfied, and only then are the synchronization events among them
  consumed - all together, in one step under the dispatcher lock. Until
  then a signaled synchronization event stays signaled and may release
  another waiter instead.

  A thread woken by a signal gets a priority boost (Kernel.PriorityBoosts):
  BoostEvent from SignalEvent, or what SignalEventWithBoost is given (an
  input driver gives BoostInput, for example).

  Events are protected by the dispatcher lock, like all wait queues.
}
unit Kernel.Events;

{$mode objfpc}
{$pointermath on}

interface

uses
  Runtime.LinkedList,
  Kernel.Threads;

type
  TEventKind = (EventKindNotification, EventKindSynchronization, EventKindSemaphore);

  TEvent = record
    Kind: TEventKind;
    IsSignaled: Boolean;
    { A semaphore's count (IsSignaled while above zero); unused by the
      other kinds. }
    SignalCount: LongInt;
    Waiters: TListEntry;
  end;
  PEvent = ^TEvent;

procedure InitializeEvent(out Event: TEvent; Kind: TEventKind; InitiallySignaled: Boolean);
procedure SignalEvent(var Event: TEvent);
{ Signals the event; the threads it releases are boosted by Boost. }
procedure SignalEventWithBoost(var Event: TEvent; Boost: LongWord);
{ Releases what waiters a signaled event (or a semaphore whose count
  just went up) can release, boosting them by Boost; dispatcher lock
  held. For Kernel.Semaphores. }
procedure ReleaseEventWaitersLocked(var Event: TEvent; Boost: LongWord);
procedure ResetEvent(var Event: TEvent);
procedure WaitForEvent(var Event: TEvent);
{ Waits at most TimeoutMilliseconds (or InfiniteTimeout); an alertable
  wait also ends when the thread is alerted (see AlertThread). }
function WaitForEventWithOptions(var Event: TEvent; TimeoutMilliseconds: QWord;
  Alertable: Boolean): TWaitResult;
function EventIsSignaled(var Event: TEvent): Boolean;

const
  MaximumWaitEvents = 64;

type
  PPEvent = ^PEvent;

{ Waits until one of Count events (Events[0..Count-1]) is signaled, at
  most TimeoutMilliseconds (InfiniteTimeout for no limit; 0 only looks).
  WaitSignaled sets Index to the event's place in the list (the first
  signaled one if several are); a synchronization event is consumed. }
function WaitForAnyEvent(Events: PPEvent; Count: LongInt; TimeoutMilliseconds: QWord; Alertable: Boolean;
  out Index: LongInt): TWaitResult;
{ Waits until all Count events are signaled at once (with the same
  timeout and alerts); then the synchronization events among them are
  consumed together. }
function WaitForAllEvents(Events: PPEvent; Count: LongInt; TimeoutMilliseconds: QWord;
  Alertable: Boolean): TWaitResult;

implementation

uses
  Kernel.PriorityLevel,
  Kernel.PriorityBoosts,
  Kernel.Scheduler;

procedure InitializeEvent(out Event: TEvent; Kind: TEventKind; InitiallySignaled: Boolean);
begin
  Event.Kind := Kind;
  Event.IsSignaled := InitiallySignaled;
  if InitiallySignaled then
    Event.SignalCount := 1
  else
    Event.SignalCount := 0;
  InitializeListHead(Event.Waiters);
end;

{ Takes the signal a released waiter used: a synchronization event
  resets itself, a semaphore gives one of its count. (A semaphore listed
  twice in one wait for all is taken once if it holds only one.) }
procedure ConsumeSignalLocked(Event: PEvent);
begin
  case Event^.Kind of
    EventKindSynchronization:
      Event^.IsSignaled := False;
    EventKindSemaphore:
      begin
        if Event^.SignalCount > 0 then
          Dec(Event^.SignalCount);
        Event^.IsSignaled := Event^.SignalCount > 0;
      end;
  end;
end;

function AllEventsSignaledLocked(Events: PPEvent; Count: LongInt): Boolean;
var
  Position: LongInt;
begin
  for Position := 0 to Count - 1 do
    if not Events[Position]^.IsSignaled then
      Exit(False);
  Result := True;
end;

{ Whether every event of a thread's wait for all is signaled. }
function AllWaitBlocksSignaledLocked(Thread: PThreadControlBlock): Boolean;
var
  Position: LongInt;
begin
  for Position := 0 to Thread^.WaitBlockCount - 1 do
    if not PEvent(Thread^.WaitBlocks[Position].Event)^.IsSignaled then
      Exit(False);
  Result := True;
end;

{ Whether the (signaled) event of Block may release its thread now. }
function WaitBlockIsSatisfiedLocked(Block: PWaitBlock): Boolean;
begin
  if Block^.Thread^.WaitsForAll then
    Result := AllWaitBlocksSignaledLocked(Block^.Thread)
  else
    Result := True;
end;

{ Ends the wait of Block's thread, consuming what satisfied it, and
  boosts it by Boost. }
procedure SatisfyWaitLocked(Block: PWaitBlock; Boost: LongWord);
var
  Thread: PThreadControlBlock;
  Position: LongInt;
begin
  Thread := Block^.Thread;
  if Thread^.WaitsForAll then
  begin
    for Position := 0 to Thread^.WaitBlockCount - 1 do
      ConsumeSignalLocked(PEvent(Thread^.WaitBlocks[Position].Event));
    Thread^.SatisfiedWaitIndex := 0;
  end
  else
  begin
    ConsumeSignalLocked(PEvent(Block^.Event));
    Thread^.SatisfiedWaitIndex := Block^.Index;
  end;
  { Takes every block of the thread off its event, this one included. }
  WakeWaitingThreadWithBoostLocked(Thread, WaitSignaled, Boost);
end;

{ The first waiter of a signaled event that it may release, or nil. }
function FirstSatisfiedWaiterLocked(var Event: TEvent): PWaitBlock;
var
  Entry: PListEntry;
begin
  Entry := Event.Waiters.Next;
  while Entry <> @Event.Waiters do
  begin
    if WaitBlockIsSatisfiedLocked(PWaitBlock(Entry)) then
      Exit(PWaitBlock(Entry));
    Entry := Entry^.Next;
  end;
  Result := nil;
end;

{ Releases waiters of a signaled event, in order, while it stays
  signaled: a notification event releases everyone it can, a
  synchronization event the first it can (which consumes it). Waiters
  for all whose other events are not signaled stay. }
procedure ReleaseEventWaitersLocked(var Event: TEvent; Boost: LongWord);
var
  Block: PWaitBlock;
begin
  while Event.IsSignaled do
  begin
    Block := FirstSatisfiedWaiterLocked(Event);
    if Block = nil then
      Break;
    SatisfyWaitLocked(Block, Boost);
  end;
end;

procedure SignalEvent(var Event: TEvent);
begin
  SignalEventWithBoost(Event, BoostEvent);
end;

procedure SignalEventWithBoost(var Event: TEvent; Boost: LongWord);
var
  PreviousLevel: TPriorityLevel;
begin
  PreviousLevel := AcquireDispatcherLock;
  Event.IsSignaled := True;
  ReleaseEventWaitersLocked(Event, Boost);
  ReleaseDispatcherLock(PreviousLevel);
end;

procedure ResetEvent(var Event: TEvent);
var
  PreviousLevel: TPriorityLevel;
begin
  PreviousLevel := AcquireDispatcherLock;
  Event.IsSignaled := False;
  ReleaseDispatcherLock(PreviousLevel);
end;

procedure WaitForEvent(var Event: TEvent);
begin
  WaitForEventWithOptions(Event, InfiniteTimeout, False);
end;

{ Ends a wait at once if it is already satisfied: for any event, the
  first one signaled; for all, if every one is. }
function TrySatisfyAtOnceLocked(Events: PPEvent; Count: LongInt; WaitForAll: Boolean;
  out Index: LongInt): Boolean;
var
  Position: LongInt;
begin
  Index := -1;
  if WaitForAll then
  begin
    if not AllEventsSignaledLocked(Events, Count) then
      Exit(False);
    for Position := 0 to Count - 1 do
      ConsumeSignalLocked(Events[Position]);
    Index := 0;
    Exit(True);
  end;
  for Position := 0 to Count - 1 do
    if Events[Position]^.IsSignaled then
    begin
      ConsumeSignalLocked(Events[Position]);
      Index := Position;
      Exit(True);
    end;
  Result := False;
end;

{ The wait itself, with one wait block per event provided by the caller
  (on its stack: a single wait needs only one). }
function WaitWithBlocks(Events: PPEvent; Count: LongInt; Blocks: PWaitBlock; WaitForAll: Boolean;
  TimeoutMilliseconds: QWord; Alertable: Boolean; out Index: LongInt): TWaitResult;
var
  PreviousLevel: TPriorityLevel;
  Thread: PThreadControlBlock;
  Position: LongInt;
begin
  PreviousLevel := AcquireDispatcherLock;
  if TrySatisfyAtOnceLocked(Events, Count, WaitForAll, Index) then
  begin
    ReleaseDispatcherLock(PreviousLevel);
    Exit(WaitSignaled);
  end;
  Thread := CurrentThread;
  for Position := 0 to Count - 1 do
  begin
    Blocks[Position].Thread := Thread;
    Blocks[Position].Index := Position;
    Blocks[Position].Event := Events[Position];
    Blocks[Position].IsLinked := True;
    InsertAtTail(Events[Position]^.Waiters, @Blocks[Position].Link);
  end;
  Thread^.WaitBlocks := Blocks;
  Thread^.WaitBlockCount := Count;
  Thread^.WaitsForAll := WaitForAll;
  Thread^.SatisfiedWaitIndex := -1;
  Result := WaitCurrentThreadWithOptionsLocked(TimeoutMilliseconds, Alertable);
  { Whatever ended the wait took the blocks off. }
  Index := Thread^.SatisfiedWaitIndex;
  ReleaseDispatcherLock(PreviousLevel);
end;

function WaitForEventWithOptions(var Event: TEvent; TimeoutMilliseconds: QWord;
  Alertable: Boolean): TWaitResult;
var
  Single: PEvent;
  Block: TWaitBlock;
  Index: LongInt;
begin
  Single := @Event;
  Result := WaitWithBlocks(@Single, 1, @Block, False, TimeoutMilliseconds, Alertable, Index);
end;

function WaitForAnyEvent(Events: PPEvent; Count: LongInt; TimeoutMilliseconds: QWord; Alertable: Boolean;
  out Index: LongInt): TWaitResult;
var
  Blocks: array[0..MaximumWaitEvents - 1] of TWaitBlock;
begin
  Index := -1;
  if (Count <= 0) or (Count > MaximumWaitEvents) then
    Exit(WaitTimedOut);
  Result := WaitWithBlocks(Events, Count, @Blocks[0], False, TimeoutMilliseconds, Alertable, Index);
end;

function WaitForAllEvents(Events: PPEvent; Count: LongInt; TimeoutMilliseconds: QWord;
  Alertable: Boolean): TWaitResult;
var
  Blocks: array[0..MaximumWaitEvents - 1] of TWaitBlock;
  Index: LongInt;
begin
  if (Count <= 0) or (Count > MaximumWaitEvents) then
    Exit(WaitTimedOut);
  Result := WaitWithBlocks(Events, Count, @Blocks[0], True, TimeoutMilliseconds, Alertable, Index);
end;

function EventIsSignaled(var Event: TEvent): Boolean;
begin
  Result := Event.IsSignaled;
end;

end.
