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
