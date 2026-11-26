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
  Self tests of event observers and the event descriptors, run once
  during startup:

    * observers: told of every signal of an event and of a semaphore's
      release, not after detaching;
    * event counters: counts, semaphore reads, non-blocking reads and
      writes, the largest count, a bad value;
    * event polls: level and edge triggered and one shot entries, data,
      modifying and removing, a wait woken by another thread, a poll in
      a poll, loops refused, files refused, entries forgotten with the
      last handle of their object;
    * timer descriptors: a periodic timer counted, stopping, what is
      left of a setting, an absolute time already past, and absolute
      real time timers when the clock is stepped (by nothing: canceled
      with TimerCancelOnSet, still armed without).
}
unit Kernel.EventDescriptorSelfTest;

{$mode objfpc}

interface

procedure RunEventDescriptorSelfTests;

implementation

uses
  Abi.SystemCalls,
  Kernel.Threads,
  Kernel.Scheduler,
  Kernel.Events,
  Kernel.Semaphores,
  Kernel.Clock,
  Kernel.WallClock,
  Kernel.SelfTest,
  Objects.Manager,
  Objects.Events,
  Objects.EventCounters,
  Objects.TimerDescriptors,
  Processes.Handles,
  Processes.Thread,
  Processes.EventPolls;

const
  WorkerWaitMilliseconds = 30000;

var
  ObserverCalls: LongInt;
  WorkerDone: TEvent;

{ --- Observers --------------------------------------------------------------- }

procedure CountObserverCall(Observer: PEventObserver);
begin
  Inc(ObserverCalls);
end;

procedure TestObservers;
var
  Event: TEvent;
  Semaphore: TSemaphore;
  Observer: TEventObserver;
  SemaphoreObserver: TEventObserver;
  Previous: LongInt;
begin
  ObserverCalls := 0;
  InitializeEvent(Event, EventKindNotification, False);
  AttachEventObserver(Event, Observer, @CountObserverCall, nil);
  SignalEvent(Event);
  Check(ObserverCalls = 1, 'observers: told of a signal');
  SignalEvent(Event);
  Check(ObserverCalls = 2, 'observers: told of a signal of a signaled event');
  ResetEvent(Event);
  Check(ObserverCalls = 2, 'observers: not told of a reset');
  DetachEventObserver(Observer);
  SignalEvent(Event);
  Check(ObserverCalls = 2, 'observers: not told once detached');
  Check(Event.FirstObserver = nil, 'observers: none left');

  InitializeSemaphore(Semaphore, 0, 4);
  AttachEventObserver(Semaphore.Event, SemaphoreObserver, @CountObserverCall, nil);
  Check(ReleaseSemaphore(Semaphore, 1, Previous), 'observers: semaphore released');
  Check(ObserverCalls = 3, 'observers: told of a semaphore release');
  DetachEventObserver(SemaphoreObserver);
  ReportPassed('event observers');
end;

{ --- Event counters ----------------------------------------------------------- }

procedure TestEventCounters;
var
  Counter: PEventCounter;
  Value: QWord;
begin
  Counter := CreateEventCounter(0, False, True);
  Check(Counter <> nil, 'event counters: made');
  Check(EventCounterReadiness(Counter) = PollWritable, 'event counters: zero is only writable');
  Check(ReadEventCounter(Counter, Value) = ErrorWouldBlock, 'event counters: empty, non-blocking');
  Check(WriteEventCounter(Counter, 3) = ErrorNone, 'event counters: written');
  Check(WriteEventCounter(Counter, 4) = ErrorNone, 'event counters: written again');
  Check(Counter^.Readable.IsSignaled, 'event counters: readable');
  Check(ReadEventCounter(Counter, Value) = ErrorNone, 'event counters: read');
  Check(Value = 7, 'event counters: the whole count read');
  Check(not Counter^.Readable.IsSignaled, 'event counters: not readable at zero');
  Check(WriteEventCounter(Counter, High(QWord)) = ErrorInvalidArgument, 'event counters: all ones refused');
  Check(WriteEventCounter(Counter, EventCounterMaximum) = ErrorNone, 'event counters: the largest count');
  Check(EventCounterReadiness(Counter) = PollReadable, 'event counters: full is not writable');
  Check(WriteEventCounter(Counter, 1) = ErrorWouldBlock, 'event counters: no room, non-blocking');
  DereferenceObject(Counter);

  Counter := CreateEventCounter(2, True, True);
  Check(ReadEventCounter(Counter, Value) = ErrorNone, 'event counters: semaphore read');
  Check(Value = 1, 'event counters: a semaphore read takes one');
  Check(ReadEventCounter(Counter, Value) = ErrorNone, 'event counters: semaphore read again');
  Check(ReadEventCounter(Counter, Value) = ErrorWouldBlock, 'event counters: semaphore empty');
  DereferenceObject(Counter);
  ReportPassed('event counters');
end;

{ --- Event polls ---------------------------------------------------------------- }

function WaitPoll(Poll: PEventPoll; out Item: TAbiPollEvent; Timeout: QWord): Int64;
begin
  Item.Events := 0;
  Item.Data := 0;
  Result := EventPollWait(Poll, @Item, 1, Timeout);
end;

procedure SignalLater(Context: Pointer);
begin
  SleepMilliseconds(20);
  SignalEvent(PEventObject(Context)^.Event);
  SignalEvent(WorkerDone);
end;

procedure TestLevelTriggered(Poll: PEventPoll; Event: PEventObject);
var
  Item: TAbiPollEvent;
begin
  Check(EventPollAdd(Poll, 100, HandleKindEvent, Event, PollReadable, 1234, False) = ErrorNone,
    'event polls: an event added');
  Check(EventPollAdd(Poll, 100, HandleKindEvent, Event, PollReadable, 1, False) = ErrorExists,
    'event polls: added twice');
  Check(WaitPoll(Poll, Item, 0) = 0, 'event polls: nothing ready');
  Check(not Poll^.Ready.IsSignaled, 'event polls: not ready');
  SignalEvent(Event^.Event);
  Check(EventPollReadiness(Poll) = PollReadable, 'event polls: ready');
  Check(WaitPoll(Poll, Item, 0) = 1, 'event polls: the event reported');
  Check((Item.Events = PollReadable) and (Item.Data = 1234), 'event polls: events and data');
  Check(WaitPoll(Poll, Item, 0) = 1, 'event polls: level triggered, reported again');
  ResetEvent(Event^.Event);
  Check(WaitPoll(Poll, Item, 0) = 0, 'event polls: no longer ready');
  Check(EventPollModify(Poll, 100, Event, PollReadable or PollOneShot, 99) = ErrorNone,
    'event polls: modified to one shot');
  SignalEvent(Event^.Event);
  Check((WaitPoll(Poll, Item, 0) = 1) and (Item.Data = 99), 'event polls: one shot reported');
  Check(WaitPoll(Poll, Item, 0) = 0, 'event polls: one shot only once');
  Check(EventPollModify(Poll, 100, Event, PollReadable or PollEdgeTriggered, 5) = ErrorNone,
    'event polls: modified to edge triggered');
  Check(WaitPoll(Poll, Item, 0) = 1, 'event polls: edge triggered, ready when modified');
  Check(WaitPoll(Poll, Item, 0) = 0, 'event polls: edge triggered, once per change');
  SignalEvent(Event^.Event);
  Check(WaitPoll(Poll, Item, 0) = 1, 'event polls: edge triggered, a new signal');
  Check(EventPollRemove(Poll, 100, Event) = ErrorNone, 'event polls: removed');
  Check(EventPollRemove(Poll, 100, Event) = ErrorNotFound, 'event polls: removed twice');
  Check(WaitPoll(Poll, Item, 0) = 0, 'event polls: nothing after removing');
end;

procedure TestCounterInPoll(Poll: PEventPoll);
var
  Counter: PEventCounter;
  Item: TAbiPollEvent;
  Value: QWord;
begin
  Counter := CreateEventCounter(0, False, True);
  Check(EventPollAdd(Poll, 7, HandleKindEventCounter, Counter, PollReadable or PollWritable, 7, False) = ErrorNone,
    'event polls: a counter added');
  Check((WaitPoll(Poll, Item, 0) = 1) and (Item.Events = PollWritable), 'event polls: a counter writable');
  WriteEventCounter(Counter, 1);
  Check((WaitPoll(Poll, Item, 0) = 1) and (Item.Events = PollReadable or PollWritable),
    'event polls: a counter readable');
  ReadEventCounter(Counter, Value);
  Check(EventPollRemove(Poll, 7, Counter) = ErrorNone, 'event polls: the counter removed');
  DereferenceObject(Counter);
end;

procedure TestBlockingWait(Poll: PEventPoll; Event: PEventObject);
var
  Item: TAbiPollEvent;
begin
  ResetEvent(Event^.Event);
  Check(EventPollAdd(Poll, 101, HandleKindEvent, Event, PollReadable, 42, False) = ErrorNone,
    'event polls: added for a wait');
  Check(WaitPoll(Poll, Item, 10) = 0, 'event polls: a wait times out');
  ResetEvent(WorkerDone);
  Check(CreateSystemThread(@SignalLater, Event, DefaultThreadPriority, 'PollTest', False) <> nil,
    'event polls: a helper thread');
  Check((WaitPoll(Poll, Item, WorkerWaitMilliseconds) = 1) and (Item.Data = 42),
    'event polls: a wait woken by another thread');
  Check(WaitForEventWithOptions(WorkerDone, WorkerWaitMilliseconds, False) = WaitSignaled,
    'event polls: the helper finished');
  Check(EventPollRemove(Poll, 101, Event) = ErrorNone, 'event polls: removed after the wait');
end;

procedure TestNesting(Poll: PEventPoll; Event: PEventObject);
var
  Outer: PEventPoll;
  Item: TAbiPollEvent;
begin
  Outer := CreateEventPoll;
  Check(Outer <> nil, 'event polls: an outer poll');
  ResetEvent(Event^.Event);
  Check(EventPollAdd(Poll, 102, HandleKindEvent, Event, PollReadable, 1, False) = ErrorNone,
    'event polls: inner entry');
  Check(EventPollAdd(Outer, 200, HandleKindEventPoll, Poll, PollReadable, 2, False) = ErrorNone,
    'event polls: a poll in a poll');
  Check(EventPollAdd(Poll, 201, HandleKindEventPoll, Outer, PollReadable, 3, False) = ErrorTooManyLinks,
    'event polls: a loop refused');
  Check(EventPollAdd(Poll, 202, HandleKindEventPoll, Poll, PollReadable, 3, False) = ErrorInvalidArgument,
    'event polls: a poll in itself refused');
  WaitPoll(Outer, Item, 0);
  SignalEvent(Event^.Event);
  Check((WaitPoll(Outer, Item, 0) = 1) and (Item.Data = 2), 'event polls: the outer poll hears of the inner one');
  Check(EventPollRemove(Poll, 102, Event) = ErrorNone, 'event polls: inner entry removed');
  DereferenceObject(Outer);
end;

procedure TestForgetting(Poll: PEventPoll);
var
  Event: PEventObject;
  Item: TAbiPollEvent;
begin
  Event := CreateEventObject(True, True);
  NoteObjectHandleOpened(Event);
  Check(EventPollAdd(Poll, 103, HandleKindEvent, Event, PollReadable, 1, True) = ErrorNone,
    'event polls: added with a handle');
  Check(Poll^.EntryCount = 1, 'event polls: one entry');
  Check(NoteObjectHandleClosed(Event), 'event polls: the last handle');
  ForgetObjectInEventPolls(Event);
  Check(Poll^.EntryCount = 0, 'event polls: forgotten with the last handle');
  Check(WaitPoll(Poll, Item, 0) = 0, 'event polls: nothing reported once forgotten');
  Check(EventPollAdd(Poll, 103, HandleKindEvent, Event, PollReadable, 1, True) = ErrorBadHandle,
    'event polls: no handle, not added');
  Check(EventPollAdd(Poll, 104, HandleKindFile, Event, PollReadable, 1, False) = ErrorNotPermitted,
    'event polls: files refused');
  DereferenceObject(Event);
end;

procedure TestEventPolls;
var
  Poll: PEventPoll;
  Event: PEventObject;
begin
  InitializeEvent(WorkerDone, EventKindNotification, False);
  Poll := CreateEventPoll;
  Event := CreateEventObject(True, False);
  Check((Poll <> nil) and (Event <> nil), 'event polls: made');
  TestLevelTriggered(Poll, Event);
  TestCounterInPoll(Poll);
  TestBlockingWait(Poll, Event);
  TestNesting(Poll, Event);
  TestForgetting(Poll);
  DereferenceObject(Event);
  DereferenceObject(Poll);
  ReportPassed('event polls');
end;

{ --- Timer descriptors ------------------------------------------------------------ }

procedure SetSpecification(out Specification: TAbiTimerSpecification; ValueNanoseconds, IntervalNanoseconds: Int64);
begin
  Specification.ValueSeconds := ValueNanoseconds div 1000000000;
  Specification.ValueNanoseconds := ValueNanoseconds mod 1000000000;
  Specification.IntervalSeconds := IntervalNanoseconds div 1000000000;
  Specification.IntervalNanoseconds := IntervalNanoseconds mod 1000000000;
end;

procedure TestPeriodicTimer;
var
  Timer: PTimerDescriptor;
  Setting: TAbiTimerSpecification;
  Left: TAbiTimerSpecification;
  Expirations: QWord;
begin
  Timer := CreateTimerDescriptor(TimerClockMonotonic, True);
  Check(Timer <> nil, 'timer descriptors: made');
  Check(ReadTimerDescriptor(Timer, Expirations) = ErrorWouldBlock, 'timer descriptors: nothing yet');
  SetSpecification(Setting, 5000000, 5000000);
  Check(SetTimerDescriptor(Timer, 0, Setting) = ErrorNone, 'timer descriptors: armed');
  GetTimerDescriptor(Timer, Left);
  Check((Left.IntervalNanoseconds = 5000000) and (Left.ValueSeconds = 0) and (Left.ValueNanoseconds > 0),
    'timer descriptors: what is left');
  Check(WaitForEventWithOptions(Timer^.Ready, WorkerWaitMilliseconds, False) = WaitSignaled,
    'timer descriptors: went off');
  SleepMilliseconds(30);
  Check(ReadTimerDescriptor(Timer, Expirations) = ErrorNone, 'timer descriptors: read');
  Check(Expirations >= 2, 'timer descriptors: periods counted');
  Check(TimerDescriptorReadiness(Timer) = 0, 'timer descriptors: not ready once read');
  SetSpecification(Setting, 0, 0);
  Check(SetTimerDescriptor(Timer, 0, Setting) = ErrorNone, 'timer descriptors: stopped');
  GetTimerDescriptor(Timer, Left);
  Check((Left.ValueSeconds = 0) and (Left.ValueNanoseconds = 0), 'timer descriptors: nothing left when stopped');
  SleepMilliseconds(15);
  Check(ReadTimerDescriptor(Timer, Expirations) = ErrorWouldBlock, 'timer descriptors: quiet when stopped');
  SetSpecification(Setting, 1, 0);
  Check(SetTimerDescriptor(Timer, TimerAbsolute, Setting) = ErrorNone, 'timer descriptors: an absolute time past');
  Check(WaitForEventWithOptions(Timer^.Ready, WorkerWaitMilliseconds, False) = WaitSignaled,
    'timer descriptors: a past time goes off at once');
  Check((ReadTimerDescriptor(Timer, Expirations) = ErrorNone) and (Expirations = 1),
    'timer descriptors: once');
  Setting.ValueNanoseconds := 1000000000;
  Check(SetTimerDescriptor(Timer, 0, Setting) = ErrorInvalidArgument, 'timer descriptors: bad nanoseconds');
  DereferenceObject(Timer);
end;

procedure TestWallClockTimers;
var
  Canceled: PTimerDescriptor;
  Followed: PTimerDescriptor;
  Setting: TAbiTimerSpecification;
  Left: TAbiTimerSpecification;
  Expirations: QWord;
begin
  Canceled := CreateTimerDescriptor(TimerClockRealTime, True);
  Followed := CreateTimerDescriptor(TimerClockRealTime, True);
  { An hour from now on the wall clock. }
  SetSpecification(Setting, WallClockNanoseconds + Int64(3600) * 1000000000, 0);
  Check(SetTimerDescriptor(Canceled, TimerAbsolute or TimerCancelOnSet, Setting) = ErrorNone,
    'timer descriptors: canceled on set, armed');
  Check(SetTimerDescriptor(Followed, TimerAbsolute, Setting) = ErrorNone,
    'timer descriptors: following the clock, armed');
  { A step by nothing is a step all the same. }
  Check(AdjustWallClock(0, False), 'timer descriptors: the clock stepped');
  Check(ReadTimerDescriptor(Canceled, Expirations) = ErrorCanceled, 'timer descriptors: canceled by the step');
  Check(TimerDescriptorReadiness(Canceled) = PollReadable, 'timer descriptors: ready when canceled');
  GetTimerDescriptor(Followed, Left);
  Check(Left.ValueSeconds >= 3500, 'timer descriptors: still armed after the step');
  Check(ReadTimerDescriptor(Followed, Expirations) = ErrorWouldBlock, 'timer descriptors: not gone off');
  SetSpecification(Setting, 0, 0);
  SetTimerDescriptor(Canceled, 0, Setting);
  Check(ReadTimerDescriptor(Canceled, Expirations) = ErrorWouldBlock, 'timer descriptors: set again, not canceled');
  DereferenceObject(Canceled);
  DereferenceObject(Followed);
end;

procedure TestTimerDescriptors;
begin
  TestPeriodicTimer;
  TestWallClockTimers;
  ReportPassed('timer descriptors');
end;

procedure RunEventDescriptorSelfTests;
begin
  TestObservers;
  TestEventCounters;
  TestEventPolls;
  TestTimerDescriptors;
end;

end.
