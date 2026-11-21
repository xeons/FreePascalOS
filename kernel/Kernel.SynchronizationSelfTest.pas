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
  Self tests of the semaphores, the shared locks and the priority boosts,
  run once during startup after the basic ones (Kernel.SelfTest):

    * semaphores: counts, the limit, a timeout, consumers in several
      threads fed by single releases;
    * shared locks: readers and writers in several threads (readers never
      see a writer's change half done, writers are alone, recursion of
      the exclusive holder), readers really sharing, and a writer getting
      in while readers keep coming;
    * wake boosts: a thread woken by an event on a processor that a
      thread of the same priority keeps busy runs at once instead of
      after that thread's time slice.

  The starvation boost needs seconds and is checked in user mode
  (schedtest).
}
unit Kernel.SynchronizationSelfTest;

{$mode objfpc}

interface

procedure RunSynchronizationSelfTests;

implementation

uses
  Runtime.Atomic,
  Kernel.PriorityLevel,
  Kernel.Threads,
  Kernel.Scheduler,
  Kernel.Events,
  Kernel.Semaphores,
  Kernel.SharedLocks,
  Kernel.Clock,
  Kernel.DeferredCalls,
  Kernel.Timers,
  Kernel.Processors,
  Kernel.SelfTest,
  Processes.Thread;

const
  WorkerWaitMilliseconds = 30000;

procedure StartWorker(Routine: TThreadStartRoutine; Context: Pointer; Name: PChar);
begin
  Check(CreateSystemThread(Routine, Context, DefaultThreadPriority, Name, False) <> nil,
    'could not create a synchronization test thread');
end;

procedure WaitForWorkers(var Finished: TEvent; What: PChar);
begin
  Check(WaitForEventWithOptions(Finished, WorkerWaitMilliseconds, False) = WaitSignaled, What);
end;

{ --- Semaphores ---------------------------------------------------------- }

const
  ConsumerCount = 2;
  ItemsPerConsumer = 100;
  SemaphoreTestLimit = 4;

var
  TestSemaphore: TSemaphore;
  ItemsConsumed: Int64;
  ConsumersFinished: Int64;
  AllConsumersFinished: TEvent;

procedure ConsumerMain(Context: Pointer);
var
  Item: Integer;
begin
  for Item := 1 to ItemsPerConsumer do
  begin
    WaitForSemaphore(TestSemaphore, InfiniteTimeout, False);
    AtomicIncrement(ItemsConsumed);
  end;
  if AtomicIncrement(ConsumersFinished) = ConsumerCount then
    SignalEvent(AllConsumersFinished);
end;

procedure TestSemaphores;
var
  Previous: LongInt;
  Item: Integer;
begin
  InitializeSemaphore(TestSemaphore, 0, SemaphoreTestLimit);
  Check(WaitForSemaphore(TestSemaphore, 0, False) = WaitTimedOut, 'an empty semaphore was taken');
  Check(WaitForSemaphore(TestSemaphore, 5, False) = WaitTimedOut, 'a timed semaphore wait did not time out');
  Check(ReleaseSemaphore(TestSemaphore, 2, Previous) and (Previous = 0), 'a semaphore release failed');
  Check(not ReleaseSemaphore(TestSemaphore, 3, Previous), 'a semaphore went past its limit');
  Check(SemaphoreCount(TestSemaphore) = 2, 'a failed semaphore release changed the count');
  Check(WaitForSemaphore(TestSemaphore, 0, False) = WaitSignaled, 'a semaphore with a count was not taken');
  Check(WaitForSemaphore(TestSemaphore, 0, False) = WaitSignaled, 'a semaphore did not count');
  Check(SemaphoreCount(TestSemaphore) = 0, 'semaphore waits did not take the count');

  ItemsConsumed := 0;
  ConsumersFinished := 0;
  InitializeEvent(AllConsumersFinished, EventKindNotification, False);
  for Item := 1 to ConsumerCount do
    StartWorker(@ConsumerMain, nil, 'SemConsumer');
  Item := 0;
  while Item < ConsumerCount * ItemsPerConsumer do
  begin
    if ReleaseSemaphore(TestSemaphore, 1, Previous) then
      Inc(Item)
    else
      SleepMilliseconds(1);
  end;
  WaitForWorkers(AllConsumersFinished, 'semaphore consumers did not finish');
  Check(ItemsConsumed = ConsumerCount * ItemsPerConsumer, 'semaphore consumers lost items');
  Check(SemaphoreCount(TestSemaphore) = 0, 'a semaphore count was left over');
  ReportPassed('semaphores');
end;

{ --- Shared locks -------------------------------------------------------- }

const
  ReaderCount = 3;
  WriterCount = 2;
  LockIterations = 150;

var
  TestLock: TSharedLock;
  { Writers change both, yielding in between; readers must never see
    them differ. }
  PairFirst: Int64;
  PairSecond: Int64;
  ReadersInside: Int64;
  MostReadersInside: Int64;
  WritersInside: Int64;
  LockViolations: Int64;
  LockWorkersFinished: Int64;
  LockWorkersExpected: Int64;
  AllLockWorkersFinished: TEvent;
  StopReaders: PtrUInt;
  WriterGotIn: TEvent;

procedure NoteLockWorkerFinished;
begin
  if AtomicIncrement(LockWorkersFinished) = LockWorkersExpected then
    SignalEvent(AllLockWorkersFinished);
end;

procedure EnterAsReader;
var
  Inside: Int64;
begin
  Inside := AtomicIncrement(ReadersInside);
  while Inside > MostReadersInside do
    MostReadersInside := Inside;
  if (WritersInside <> 0) or (PairFirst <> PairSecond) then
    AtomicIncrement(LockViolations);
end;

procedure LeaveAsReader;
begin
  if (WritersInside <> 0) or (PairFirst <> PairSecond) then
    AtomicIncrement(LockViolations);
  AtomicDecrement(ReadersInside);
end;

procedure ReaderMain(Context: Pointer);
var
  Iteration: Integer;
begin
  for Iteration := 1 to LockIterations do
  begin
    AcquireSharedLockShared(TestLock);
    EnterAsReader;
    YieldExecution;
    LeaveAsReader;
    ReleaseSharedLock(TestLock);
  end;
  NoteLockWorkerFinished;
end;

procedure WriterMain(Context: Pointer);
var
  Iteration: Integer;
begin
  for Iteration := 1 to LockIterations do
  begin
    AcquireSharedLockExclusive(TestLock);
    if (AtomicIncrement(WritersInside) <> 1) or (ReadersInside <> 0) then
      AtomicIncrement(LockViolations);
    PairFirst := PairFirst + 1;
    YieldExecution;
    { The exclusive holder may acquire it again, either way. }
    AcquireSharedLockShared(TestLock);
    AcquireSharedLockExclusive(TestLock);
    PairSecond := PairSecond + 1;
    ReleaseSharedLock(TestLock);
    ReleaseSharedLock(TestLock);
    AtomicDecrement(WritersInside);
    ReleaseSharedLock(TestLock);
  end;
  NoteLockWorkerFinished;
end;

{ Holds the lock shared, yielding, over and over until told to stop, so
  that with several of these the lock is never free of readers. }
procedure EndlessReaderMain(Context: Pointer);
begin
  while AtomicLoad(StopReaders) = 0 do
  begin
    AcquireSharedLockShared(TestLock);
    EnterAsReader;
    YieldExecution;
    SleepMilliseconds(1);
    LeaveAsReader;
    ReleaseSharedLock(TestLock);
  end;
  NoteLockWorkerFinished;
end;

procedure LateWriterMain(Context: Pointer);
begin
  AcquireSharedLockExclusive(TestLock);
  if ReadersInside <> 0 then
    AtomicIncrement(LockViolations);
  SignalEvent(WriterGotIn);
  ReleaseSharedLock(TestLock);
  NoteLockWorkerFinished;
end;

procedure ResetLockWorkers(Expected: Int64);
begin
  LockWorkersFinished := 0;
  LockWorkersExpected := Expected;
  InitializeEvent(AllLockWorkersFinished, EventKindNotification, False);
end;

procedure CheckLockIsFree;
begin
  Check((TestLock.ExclusiveOwner = nil) and (TestLock.SharedCount = 0) and
    (TestLock.ExclusiveWaiterCount = 0), 'a shared lock was still held after every release');
end;

procedure TestSharedLockTries;
begin
  Check(TryAcquireSharedLockExclusive(TestLock), 'a free shared lock could not be had exclusively');
  Check(TryAcquireSharedLockShared(TestLock), 'the exclusive holder could not acquire shared');
  Check(SharedLockIsHeldExclusivelyByCurrentThread(TestLock), 'the exclusive holder is not recorded');
  ReleaseSharedLock(TestLock);
  ReleaseSharedLock(TestLock);
  Check(TryAcquireSharedLockShared(TestLock), 'a free shared lock could not be had shared');
  Check(not TryAcquireSharedLockExclusive(TestLock), 'a lock held shared was had exclusively');
  ReleaseSharedLock(TestLock);
  CheckLockIsFree;
end;

procedure TestSharedLockContention;
var
  Index: Integer;
begin
  PairFirst := 0;
  PairSecond := 0;
  ReadersInside := 0;
  WritersInside := 0;
  MostReadersInside := 0;
  ResetLockWorkers(ReaderCount + WriterCount);
  for Index := 1 to WriterCount do
    StartWorker(@WriterMain, nil, 'LockWriter');
  for Index := 1 to ReaderCount do
    StartWorker(@ReaderMain, nil, 'LockReader');
  WaitForWorkers(AllLockWorkersFinished, 'shared lock workers did not finish');
  Check(LockViolations = 0, 'a shared lock let a reader see a writer, or two writers in');
  Check((PairFirst = WriterCount * LockIterations) and (PairSecond = PairFirst),
    'shared lock writers lost changes');
  CheckLockIsFree;
end;

procedure TestReadersShare;
var
  Index: Integer;
begin
  ReadersInside := 0;
  MostReadersInside := 0;
  ResetLockWorkers(ReaderCount);
  for Index := 1 to ReaderCount do
    StartWorker(@ReaderMain, nil, 'LockReader');
  WaitForWorkers(AllLockWorkersFinished, 'shared lock readers did not finish');
  Check(MostReadersInside >= 2, 'readers of a shared lock never held it together');
  CheckLockIsFree;
end;

procedure TestWriterIsNotStarved;
var
  Index: Integer;
begin
  StopReaders := 0;
  ReadersInside := 0;
  ResetLockWorkers(ReaderCount + 1);
  InitializeEvent(WriterGotIn, EventKindNotification, False);
  for Index := 1 to ReaderCount do
    StartWorker(@EndlessReaderMain, nil, 'LockReader');
  SleepMilliseconds(20);
  StartWorker(@LateWriterMain, nil, 'LockWriter');
  Check(WaitForEventWithOptions(WriterGotIn, 5000, False) = WaitSignaled,
    'a writer was kept out of a shared lock by readers that kept coming');
  AtomicStore(StopReaders, 1);
  WaitForWorkers(AllLockWorkersFinished, 'shared lock readers did not stop');
  Check(LockViolations = 0, 'a writer got a shared lock while readers held it');
  CheckLockIsFree;
end;

procedure TestSharedLocks;
begin
  InitializeSharedLock(TestLock);
  LockViolations := 0;
  TestSharedLockTries;
  TestSharedLockContention;
  TestReadersShare;
  TestWriterIsNotStarved;
  ReportPassed('shared locks (readers and writers)');
end;

{ --- Wake boosts ------------------------------------------------------------ }

const
  LatencyRounds = 20;
  LatencyTimerMilliseconds = 2;
  { Well under the busy thread's time slice (QuantumTicks, 20 ms): an
    unboosted wake would wait out most of it. }
  LatencyLimitNanoseconds = 5 * NanosecondsPerMillisecond;

var
  BusyProcessorMask: QWord;
  StopBusy: PtrUInt;
  BusyRunning: TEvent;
  LatencyWake: TEvent;
  LatencyTimer: TTimer;
  LatencyCall: TDeferredCall;
  SignalTime: QWord;
  SlowWakes: Int64;
  WorstLatency: QWord;
  BoostWorkersFinished: Int64;
  AllBoostWorkersFinished: TEvent;

procedure NoteBoostWorkerFinished;
begin
  if AtomicIncrement(BoostWorkersFinished) = 2 then
    SignalEvent(AllBoostWorkersFinished);
end;

procedure SignalLatencyWake(Context: Pointer);
begin
  SignalTime := ClockNanoseconds;
  SignalEvent(LatencyWake);
end;

{ Computes on the test processor without ever waiting. }
procedure BusyMain(Context: Pointer);
var
  Spins: Int64;
begin
  SetThreadAffinity(CurrentThread, BusyProcessorMask);
  YieldExecution;
  SignalEvent(BusyRunning);
  Spins := 0;
  while AtomicLoad(StopBusy) = 0 do
    AtomicIncrement(Spins);
  NoteBoostWorkerFinished;
end;

{ Waits for an event a timer signals, again and again, on the same
  processor, and measures how soon after the signal it runs. }
procedure InteractiveMain(Context: Pointer);
var
  Round: Integer;
  Latency: QWord;
begin
  SetThreadAffinity(CurrentThread, BusyProcessorMask);
  YieldExecution;
  for Round := 1 to LatencyRounds do
  begin
    SetTimer(LatencyTimer, LatencyTimerMilliseconds, LatencyCall);
    WaitForEvent(LatencyWake);
    Latency := ClockNanoseconds - SignalTime;
    if Latency > WorstLatency then
      WorstLatency := Latency;
    if Latency > LatencyLimitNanoseconds then
      AtomicIncrement(SlowWakes);
  end;
  AtomicStore(StopBusy, 1);
  NoteBoostWorkerFinished;
end;

function LastOnlineProcessorIndex: LongWord;
var
  Index: LongWord;
begin
  Result := 0;
  for Index := 0 to ProcessorTotal - 1 do
    if ProcessorByIndex(Index)^.IsOnline then
      Result := Index;
end;

procedure TestWakeBoost;
begin
  BusyProcessorMask := QWord(1) shl LastOnlineProcessorIndex;
  StopBusy := 0;
  SlowWakes := 0;
  WorstLatency := 0;
  BoostWorkersFinished := 0;
  InitializeEvent(BusyRunning, EventKindNotification, False);
  InitializeEvent(LatencyWake, EventKindSynchronization, False);
  InitializeEvent(AllBoostWorkersFinished, EventKindNotification, False);
  InitializeTimer(LatencyTimer);
  InitializeDeferredCall(LatencyCall, @SignalLatencyWake, nil);

  StartWorker(@BusyMain, nil, 'BoostBusy');
  Check(WaitForEventWithOptions(BusyRunning, WorkerWaitMilliseconds, False) = WaitSignaled,
    'the busy thread of the boost test did not start');
  StartWorker(@InteractiveMain, nil, 'BoostWaiter');
  WaitForWorkers(AllBoostWorkersFinished, 'the boost test threads did not finish');
  CancelTimer(LatencyTimer);
  CancelDeferredCall(LatencyCall);
  { Some room for an emulator that falls behind now and then. }
  Check(SlowWakes <= LatencyRounds div 4,
    'a thread woken by an event waited for a busy thread of its priority (no wake boost)');
  ReportPassed('wake boost (an event wakes a thread at once)');
end;

procedure RunSynchronizationSelfTests;
begin
  TestSemaphores;
  TestSharedLocks;
  TestWakeBoost;
end;

end.
