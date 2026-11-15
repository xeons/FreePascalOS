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

  A thread may wait on several events at once and wake when any one of
  them is signaled (WaitForAnyEvent): it is linked into each one's
  waiters by a wait block (Kernel.Threads), and whichever event releases
  it first takes all its blocks off (the scheduler does, waking it), so
  it is released once and learns which event it was.

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
  TEventKind = (EventKindNotification, EventKindSynchronization);

  TEvent = record
    Kind: TEventKind;
    IsSignaled: Boolean;
    Waiters: TListEntry;
  end;
  PEvent = ^TEvent;

procedure InitializeEvent(out Event: TEvent; Kind: TEventKind; InitiallySignaled: Boolean);
procedure SignalEvent(var Event: TEvent);
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

implementation

uses
  Kernel.PriorityLevel,
  Kernel.Scheduler;

procedure InitializeEvent(out Event: TEvent; Kind: TEventKind; InitiallySignaled: Boolean);
begin
  Event.Kind := Kind;
  Event.IsSignaled := InitiallySignaled;
  InitializeListHead(Event.Waiters);
end;

procedure ReleaseOneWaiterLocked(var Event: TEvent);
var
  Entry: PListEntry;
  Block: PWaitBlock;
begin
  Entry := FirstListEntry(Event.Waiters);
  if Entry = nil then
    Exit;
  Block := PWaitBlock(Entry);
  Block^.Thread^.SatisfiedWaitIndex := Block^.Index;
  { Takes every block of the thread off its event, this one included. }
  WakeWaitingThreadLocked(Block^.Thread, WaitSignaled);
end;

procedure SignalEvent(var Event: TEvent);
var
  PreviousLevel: TPriorityLevel;
begin
  PreviousLevel := AcquireDispatcherLock;

  if Event.Kind = EventKindNotification then
  begin
    Event.IsSignaled := True;
    while not ListIsEmpty(Event.Waiters) do
      ReleaseOneWaiterLocked(Event);
  end
  else if ListIsEmpty(Event.Waiters) then
    Event.IsSignaled := True
  else
    { The signal is consumed by the released waiter. }
    ReleaseOneWaiterLocked(Event);

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

{ The wait itself, with one wait block per event provided by the caller
  (on its stack: a single wait needs only one). }
function WaitWithBlocks(Events: PPEvent; Count: LongInt; Blocks: PWaitBlock; TimeoutMilliseconds: QWord;
  Alertable: Boolean; out Index: LongInt): TWaitResult;
var
  PreviousLevel: TPriorityLevel;
  Thread: PThreadControlBlock;
  Event: PEvent;
  Position: LongInt;
begin
  Index := -1;
  PreviousLevel := AcquireDispatcherLock;
  { Already signaled: no wait. }
  for Position := 0 to Count - 1 do
  begin
    Event := Events[Position];
    if Event^.IsSignaled then
    begin
      if Event^.Kind = EventKindSynchronization then
        Event^.IsSignaled := False;
      ReleaseDispatcherLock(PreviousLevel);
      Index := Position;
      Exit(WaitSignaled);
    end;
  end;
  Thread := CurrentThread;
  for Position := 0 to Count - 1 do
  begin
    Blocks[Position].Thread := Thread;
    Blocks[Position].Index := Position;
    Blocks[Position].IsLinked := True;
    InsertAtTail(Events[Position]^.Waiters, @Blocks[Position].Link);
  end;
  Thread^.WaitBlocks := Blocks;
  Thread^.WaitBlockCount := Count;
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
  Result := WaitWithBlocks(@Single, 1, @Block, TimeoutMilliseconds, Alertable, Index);
end;

function WaitForAnyEvent(Events: PPEvent; Count: LongInt; TimeoutMilliseconds: QWord; Alertable: Boolean;
  out Index: LongInt): TWaitResult;
var
  Blocks: array[0..MaximumWaitEvents - 1] of TWaitBlock;
begin
  Index := -1;
  if (Count <= 0) or (Count > MaximumWaitEvents) then
    Exit(WaitTimedOut);
  Result := WaitWithBlocks(Events, Count, @Blocks[0], TimeoutMilliseconds, Alertable, Index);
end;

function EventIsSignaled(var Event: TEvent): Boolean;
begin
  Result := Event.IsSignaled;
end;

end.
