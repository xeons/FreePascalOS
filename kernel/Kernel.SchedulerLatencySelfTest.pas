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
  Regression tests for two timing windows of the scheduler that QEMU
  does not hit by chance, made deterministic with test hooks.

  The idle lost wakeup: an idle processor decides there is nothing to
  do and then waits; a wake-up sent between the two must still end the
  wait (the check and the wait are one step, Kernel.IdleStates). The
  idle window hook holds the processor in that window, interrupts off,
  while the test makes a thread pinned there ready - its dispatch
  interrupt arrives inside the window - and then lets it wait. The
  thread must run at once, not at the processor's next timer (with the
  tick stopped, seconds away).

  Priority lowering: a running thread whose priority drops below a
  ready thread's must give way at once (SetThreadPriority asks its
  processor to reschedule), not when its time slice ends. The test
  stretches the time slice (SetTimeSliceTicksForTest) far beyond what
  it waits, so a missing reschedule fails for certain instead of
  costing 20 ms.

  Both need a second processor for the threads under test; with one
  they report that there was nothing to check.
}
unit Kernel.SchedulerLatencySelfTest;

{$mode objfpc}

interface

procedure RunSchedulerLatencySelfTests;

implementation

uses
  Runtime.Atomic,
  Kernel.Threads,
  Kernel.Scheduler,
  Kernel.Events,
  Kernel.Clock,
  Kernel.Processors,
  Kernel.IdleStates,
  Kernel.InterProcessor,
  Kernel.Arch.Cpu,
  Kernel.PriorityLevel,
  Kernel.ReadyQueues,
  Objects.Manager,
  Processes.Thread,
  Kernel.SelfTest;

const
  { Generous for an emulator; a lost wake-up or a missed reschedule
    waits for seconds. }
  WakeLimitNanoseconds = 50 * NanosecondsPerMillisecond;
  WindowRounds = 5;
  { How long the hook holds a processor in the window at most. }
  WindowHoldNanoseconds = 200 * NanosecondsPerMillisecond;
  WaitLimitMilliseconds = 2000;
  { A slice no test waits out (10 000 s). }
  EndlessSliceTicks = 1000000;
  HighPriority = 12;
  LoweredPriority = 4;

var
  TestProcessor: LongWord;

function LastOnlineProcessor: LongWord;
var
  Index: LongWord;
begin
  Result := 0;
  for Index := 0 to ProcessorTotal - 1 do
    if ProcessorByIndex(Index)^.IsOnline then
      Result := Index;
end;

{ Moves the calling thread onto the test processor. }
procedure MoveToTestProcessor;
begin
  SetThreadAffinity(CurrentThread, QWord(1) shl TestProcessor);
  while CurrentProcessorIndex <> TestProcessor do
    YieldExecution;
end;

{ Keeps the calling (testing) thread off the test processor. }
procedure LeaveTestProcessor;
begin
  SetThreadAffinity(CurrentThread, AllProcessors and not (QWord(1) shl TestProcessor));
  while CurrentProcessorIndex = TestProcessor do
    YieldExecution;
end;

{ Waits until Flag is not 0, at most WaitLimitMilliseconds; False if it
  never was. }
function WaitForFlag(var Flag: PtrUInt): Boolean;
var
  Deadline: QWord;
begin
  Deadline := DeadlineAfterMilliseconds(WaitLimitMilliseconds);
  while AtomicLoad(Flag) = 0 do
  begin
    if ClockNanoseconds >= Deadline then
      Exit(False);
    SleepMilliseconds(1);
  end;
  Result := True;
end;

{ --- The idle lost wakeup ---------------------------------------------- }

var
  WindowArmed: PtrUInt;
  InWindow: PtrUInt;
  WindowReleased: PtrUInt;
  SleeperWake: TEvent;
  SleeperParked: PtrUInt;
  SleeperWokeAt: QWord;
  SleeperWoke: PtrUInt;
  StopSleeper: PtrUInt;
  SleeperFinished: TEvent;

{ The idle window hook: on the test processor, once per arming, says it
  is in the window and stays there until released (interrupts are off,
  so the dispatch interrupt sent meanwhile stays pending). }
procedure HoldInIdleWindow(ProcessorIndex: LongWord);
var
  Deadline: QWord;
begin
  if (ProcessorIndex <> TestProcessor) or (AtomicExchange(WindowArmed, 0) = 0) then
    Exit;
  Deadline := ClockNanoseconds + WindowHoldNanoseconds;
  AtomicStore(InWindow, 1);
  while (AtomicLoad(WindowReleased) = 0) and (ClockNanoseconds < Deadline) do
    CpuRelax;
end;

{ Waits on the test processor for wake-ups and notes when each came. }
procedure SleeperMain(Context: Pointer);
begin
  MoveToTestProcessor;
  while AtomicLoad(StopSleeper) = 0 do
  begin
    AtomicStore(SleeperParked, 1);
    WaitForEvent(SleeperWake);
    SleeperWokeAt := ClockNanoseconds;
    AtomicStore(SleeperWoke, 1);
  end;
  SignalEvent(SleeperFinished);
end;

procedure TestIdleWakeupInWindow;
var
  Thread: PThread;
  Round: Integer;
  SignaledAt: QWord;
  SlowWakes: Integer;
begin
  InitializeEvent(SleeperWake, EventKindSynchronization, False);
  InitializeEvent(SleeperFinished, EventKindNotification, False);
  StopSleeper := 0;
  SleeperParked := 0;
  Thread := CreateSystemThread(@SleeperMain, nil, DefaultThreadPriority, 'IdleSleeper', True);
  Check(Thread <> nil, 'could not create the idle wake-up thread');
  SetIdleWindowHookForTest(@HoldInIdleWindow);
  SlowWakes := 0;
  for Round := 1 to WindowRounds do
  begin
    Check(WaitForFlag(SleeperParked), 'the idle wake-up thread did not wait');
    { Let the processor go idle, then hold it in the window: its
      dispatch interrupt takes it through the idle loop once more. }
    SleepMilliseconds(10);
    AtomicStore(InWindow, 0);
    AtomicStore(WindowReleased, 0);
    AtomicStore(SleeperWoke, 0);
    AtomicStore(SleeperParked, 0);
    AtomicStore(WindowArmed, 1);
    RequestDispatchOnProcessor(ProcessorByIndex(TestProcessor));
    Check(WaitForFlag(InWindow), 'the idle processor never reached the window');
    SignaledAt := ClockNanoseconds;
    SignalEvent(SleeperWake);
    AtomicStore(WindowReleased, 1);
    Check(WaitForFlag(SleeperWoke), 'a thread woken in the idle window never ran (lost wake-up)');
    if SleeperWokeAt - SignaledAt > WakeLimitNanoseconds then
      Inc(SlowWakes);
  end;
  SetIdleWindowHookForTest(nil);
  AtomicStore(WindowArmed, 0);
  AtomicStore(StopSleeper, 1);
  SignalEvent(SleeperWake);
  WaitForEvent(SleeperFinished);
  DereferenceObject(Thread);
  { One slow round may be the emulator falling behind; a lost wake-up
    is slow every time. }
  Check(SlowWakes <= 1, 'a wake-up sent between the idle check and the wait waited for a later interrupt');
  ReportPassed('idle wake-up in the window between check and wait');
end;

{ --- A steal refused in the idle window ------------------------------------ }

{ The case the atomic check and wait was made for: the idle processor's
  dispatch interrupt, arriving in the window, tries to take a thread
  from a busy processor whose queue lock is held at that moment, and is
  refused. The idle loop must notice the refusal and pull the thread
  once the lock is free, rather than sleep with work to take. }

const
  QueuedPriority = 4;
  LockHoldNanoseconds = 5 * NanosecondsPerMillisecond;

var
  OtherProcessor: LongWord;
  StopOccupier: PtrUInt;
  OccupierRunning: PtrUInt;
  OccupierFinished: TEvent;
  QueuedWake: TEvent;
  QueuedParked: PtrUInt;
  QueuedRanAt: QWord;
  QueuedRanOn: PtrUInt;
  QueuedRan: PtrUInt;
  QueuedFinished: TEvent;

{ Keeps the other processor busy, so a thread queued there stays queued. }
procedure OccupierMain(Context: Pointer);
begin
  SetThreadAffinity(CurrentThread, QWord(1) shl OtherProcessor);
  while CurrentProcessorIndex <> OtherProcessor do
    YieldExecution;
  AtomicStore(OccupierRunning, 1);
  while AtomicLoad(StopOccupier) = 0 do
    CpuRelax;
  SignalEvent(OccupierFinished);
end;

{ Waits until woken, then notes where and when it ran. }
procedure QueuedMain(Context: Pointer);
begin
  AtomicStore(QueuedParked, 1);
  WaitForEvent(QueuedWake);
  QueuedRanAt := ClockNanoseconds;
  AtomicStore(QueuedRanOn, CurrentProcessorIndex);
  AtomicStore(QueuedRan, 1);
  SignalEvent(QueuedFinished);
end;

procedure TestRefusedStealInWindow;
var
  Occupier: PThread;
  Queued: PThread;
  PreviousLevel: TPriorityLevel;
  ReleasedAt: QWord;
  Deadline: QWord;
begin
  if TestProcessor = 0 then
    OtherProcessor := 1
  else
    OtherProcessor := 0;
  StopOccupier := 0;
  OccupierRunning := 0;
  QueuedParked := 0;
  QueuedRan := 0;
  InitializeEvent(OccupierFinished, EventKindNotification, False);
  InitializeEvent(QueuedWake, EventKindNotification, False);
  InitializeEvent(QueuedFinished, EventKindNotification, False);
  Occupier := CreateSystemThread(@OccupierMain, nil, DefaultThreadPriority, 'StealOccupier', True);
  Check(Occupier <> nil, 'could not create the steal test''s busy thread');
  Check(WaitForFlag(OccupierRunning), 'the steal test''s busy thread did not reach its processor');
  Queued := CreateSystemThread(@QueuedMain, nil, QueuedPriority, 'StealQueued', True);
  Check(Queued <> nil, 'could not create the thread to steal');
  Check(WaitForFlag(QueuedParked), 'the thread to steal did not wait');
  SetThreadAffinity(@Queued^.ControlBlock, QWord(1) shl OtherProcessor);
  SleepMilliseconds(5);

  { The idle processor into the window first: woken earlier, it would
    take the thread before the test begins. }
  AtomicStore(InWindow, 0);
  AtomicStore(WindowReleased, 0);
  SetIdleWindowHookForTest(@HoldInIdleWindow);
  AtomicStore(WindowArmed, 1);
  RequestDispatchOnProcessor(ProcessorByIndex(TestProcessor));
  Check(WaitForFlag(InWindow), 'the idle processor never reached the window');
  { Woken while it may only go to the busy processor, it waits in that
    processor's queue; then it may also run on the idle one. }
  SignalEvent(QueuedWake);
  SetThreadAffinity(@Queued^.ControlBlock, (QWord(1) shl OtherProcessor) or (QWord(1) shl TestProcessor));
  { The idle processor's dispatch interrupt comes as it leaves the
    window, and finds the busy processor's queue locked. }
  PreviousLevel := LockProcessorAtDispatchLevel(ProcessorByIndex(OtherProcessor));
  RequestDispatchOnProcessor(ProcessorByIndex(TestProcessor));
  AtomicStore(WindowReleased, 1);
  Deadline := ClockNanoseconds + LockHoldNanoseconds;
  while ClockNanoseconds < Deadline do
    CpuRelax;
  ReleasedAt := ClockNanoseconds;
  UnlockProcessorAndLower(ProcessorByIndex(OtherProcessor), PreviousLevel);
  SetIdleWindowHookForTest(nil);
  AtomicStore(WindowArmed, 0);

  Check(WaitForFlag(QueuedRan), 'a thread left in a busy processor''s queue never ran');
  Check(AtomicLoad(QueuedRanOn) = TestProcessor, 'the idle processor did not take the waiting thread');
  Check((QueuedRanAt >= ReleasedAt) and (QueuedRanAt - ReleasedAt <= WakeLimitNanoseconds),
    'an idle processor refused a steal in its window and slept with work to take');
  WaitForEvent(QueuedFinished);
  AtomicStore(StopOccupier, 1);
  WaitForEvent(OccupierFinished);
  DereferenceObject(Queued);
  DereferenceObject(Occupier);
  ReportPassed('a steal refused in the idle window is taken up again');
end;

{ --- Priority lowering --------------------------------------------------- }

var
  StopSpinners: PtrUInt;
  HighRunning: PtrUInt;
  LowStarted: PtrUInt;
  LowStartedAt: QWord;
  SpinnersFinished: Int64;
  AllSpinnersFinished: TEvent;

procedure NoteSpinnerFinished;
begin
  if AtomicIncrement(SpinnersFinished) = 2 then
    SignalEvent(AllSpinnersFinished);
end;

{ The more important thread: spins on the test processor. }
procedure HighSpinnerMain(Context: Pointer);
begin
  MoveToTestProcessor;
  AtomicStore(HighRunning, 1);
  while AtomicLoad(StopSpinners) = 0 do
    CpuRelax;
  NoteSpinnerFinished;
end;

{ The less important one: moves to the test processor, where it waits
  behind the spinner, notes when it first runs there, then spins. }
procedure LowSpinnerMain(Context: Pointer);
begin
  MoveToTestProcessor;
  LowStartedAt := ClockNanoseconds;
  AtomicStore(LowStarted, 1);
  while AtomicLoad(StopSpinners) = 0 do
    CpuRelax;
  NoteSpinnerFinished;
end;

procedure TestPriorityLoweringLatency;
var
  HighThread: PThread;
  LowThread: PThread;
  LoweredAt: QWord;
begin
  StopSpinners := 0;
  HighRunning := 0;
  LowStarted := 0;
  SpinnersFinished := 0;
  InitializeEvent(AllSpinnersFinished, EventKindNotification, False);
  SetTimeSliceTicksForTest(EndlessSliceTicks);
  HighThread := CreateSystemThread(@HighSpinnerMain, nil, HighPriority, 'HighSpinner', True);
  Check(HighThread <> nil, 'could not create the high priority spinner');
  Check(WaitForFlag(HighRunning), 'the high priority spinner did not reach its processor');
  { It moves itself to the test processor, where it can only wait
    behind the spinner. }
  LowThread := CreateSystemThread(@LowSpinnerMain, nil, DefaultThreadPriority, 'LowSpinner', True);
  Check(LowThread <> nil, 'could not create the low priority spinner');
  SleepMilliseconds(50);
  Check(AtomicLoad(LowStarted) = 0, 'a less important thread ran beside a more important spinning one');
  LoweredAt := ClockNanoseconds;
  SetThreadPriority(@HighThread^.ControlBlock, LoweredPriority);
  Check(WaitForFlag(LowStarted), 'a ready thread never ran after the running one was lowered below it');
  Check(LowStartedAt - LoweredAt <= WakeLimitNanoseconds,
    'lowering a running thread''s priority did not reschedule its processor at once');
  AtomicStore(StopSpinners, 1);
  WaitForEvent(AllSpinnersFinished);
  SetTimeSliceTicksForTest(0);
  DereferenceObject(HighThread);
  DereferenceObject(LowThread);
  ReportPassed('a lowered priority gives way at once');
end;

procedure RunSchedulerLatencySelfTests;
begin
  if OnlineProcessorCount < 2 then
  begin
    ReportPassed('scheduler latency windows (one processor: nothing to check)');
    Exit;
  end;
  TestProcessor := LastOnlineProcessor;
  LeaveTestProcessor;
  TestIdleWakeupInWindow;
  TestRefusedStealInWindow;
  TestPriorityLoweringLatency;
  SetThreadAffinity(CurrentThread, AllProcessors);
end;

end.
