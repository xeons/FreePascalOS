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

  Events are protected by the dispatcher lock, like all wait queues.
}
unit Kernel.Events;

{$mode objfpc}

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
begin
  Entry := FirstListEntry(Event.Waiters);
  if Entry <> nil then
    WakeWaitingThreadLocked(ThreadFromSchedulerLink(Entry), WaitSignaled);
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

function WaitForEventWithOptions(var Event: TEvent; TimeoutMilliseconds: QWord;
  Alertable: Boolean): TWaitResult;
var
  PreviousLevel: TPriorityLevel;
  Thread: PThreadControlBlock;
begin
  PreviousLevel := AcquireDispatcherLock;

  if Event.IsSignaled then
  begin
    if Event.Kind = EventKindSynchronization then
      Event.IsSignaled := False;
    Result := WaitSignaled;
  end
  else
  begin
    Thread := CurrentThread;
    InsertAtTail(Event.Waiters, @Thread^.SchedulerLink);
    Thread^.IsOnWaitList := True;
    Result := WaitCurrentThreadWithOptionsLocked(TimeoutMilliseconds, Alertable);
  end;

  ReleaseDispatcherLock(PreviousLevel);
end;

function EventIsSignaled(var Event: TEvent): Boolean;
begin
  Result := Event.IsSignaled;
end;

end.
