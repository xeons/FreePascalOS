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
  Thread scheduler.

  Scheduling is preemptive and priority based. Every processor has a run
  queue per priority level (Kernel.ReadyQueues); the highest priority
  ready threads run, and threads of equal priority take turns, each
  running for a time slice (quantum) of a few clock ticks. When nothing
  is ready for a processor, its idle thread runs; idle threads are never
  placed on a run queue. A thread that becomes ready goes to the queue of
  a processor chosen for it (preferably the one it last ran on), which is
  asked to reschedule if it is idle or runs something less important;
  a processor looking for work also takes threads from the queues of the
  others. Threads may be limited to some processors (SetThreadAffinity).
  Threads woken from waits get priority boosts (Kernel.PriorityBoosts).

  Locks, both taken at DispatchLevel, in this order:

    1. The dispatcher lock: every wait queue (events, mutexes, shared
       locks, semaphores), the sleep queues of timed waits, alerts, the
       list of terminated threads, and a thread's change into or out of
       ThreadStateWaiting.

    2. Each processor's scheduling lock (Kernel.ReadyQueues): its run
       queues, the thread it runs, its time slice and processor time. A
       processor holding its own takes another's only if it is free
       (TryLockProcessor), so two processors never wait for each other.

  So a processor that preempts its thread (time slice over, a more
  important thread ready, a yield) takes only its own lock; only waits
  and wake-ups take the dispatcher lock.

  Thread switches happen at DispatchLevel in one of two ways:

    * Preemption. The clock interrupt and ReadyThreadLocked do not switch
      threads themselves; they request the dispatch software interrupt,
      which arrives as soon as the processor drops below DispatchLevel and
      then picks the next thread, under the processor's lock only.

    * Blocking. A thread that waits or sleeps calls WaitCurrentThreadLocked
      with the dispatcher lock held, which switches away immediately.

  The processor's scheduling lock is held across a switch, and so is the
  dispatcher lock when a thread blocks or ends; both are released by
  whichever thread runs next (FinishThreadSwitch), where it switched away
  earlier or in ThreadStartTrampoline when it runs for the first time. So
  a thread is never run elsewhere before its registers are saved: until
  then it is in no queue another processor may take it from (its own
  processor's queue is locked), and a blocked thread cannot be woken (the
  dispatcher lock is held). A preempted thread that should go to another
  processor (it may no longer run here, or one is idle) is placed there
  by the next thread, once the switch is over.
}
unit Kernel.Scheduler;

{$mode objfpc}

interface

uses
  Kernel.PriorityLevel,
  Kernel.Processors,
  Kernel.Threads;

const
  QuantumTicks = 2;

{ Limits Thread to the processors in Mask (bit N: the processor with
  index N; AllProcessors for any). A thread running or queued where it
  may no longer run moves at once. }
procedure SetThreadAffinity(Thread: PThreadControlBlock; Mask: QWord);

{ Turns the currently executing boot code into the idle thread, described
  by IdleThread, and enables scheduling. }
procedure InitializeScheduler(IdleThread: PThreadControlBlock);
{ The same for a secondary processor, whose start-up code becomes its
  idle thread. }
procedure StartSchedulingOnThisProcessor(IdleThread: PThreadControlBlock);

{ Prepares a thread control block to start running StartRoutine(Context)
  on the given stack. The thread does not run until StartThread. }
procedure InitializeThreadControlBlock(Thread: PThreadControlBlock;
  StackBase, StackTop: QWord; StartRoutine: TThreadStartRoutine;
  StartContext: Pointer; Priority: LongWord; Name: PChar);

procedure StartThread(Thread: PThreadControlBlock);

function CurrentThread: PThreadControlBlock;

{ Gives up the rest of the time slice to other threads of equal priority. }
procedure YieldExecution;

const
  InfiniteTimeout = High(QWord);

procedure SleepMilliseconds(Milliseconds: QWord);
{ Like SleepMilliseconds, but ends early (returning False) if the thread
  is alerted. }
function SleepAlertable(Milliseconds: QWord): Boolean;

{ Makes every alertable wait of Thread end, now and in the future. }
procedure AlertThread(Thread: PThreadControlBlock);
{ Forgets an alert of the current thread, so its alertable waits block
  again (a stopped thread does this before it waits to be continued). }
procedure ClearCurrentThreadAlert;

{ Changes the priority of a thread, moving it between run queues if it
  is ready. }
procedure SetThreadPriority(Thread: PThreadControlBlock; Priority: LongWord);

{ Average number of runnable threads over the last 1, 5 and 15 minutes,
  in hundredths, and the number right now. }
procedure GetLoadAverages(out OneMinute, FiveMinutes, FifteenMinutes: LongWord);
function RunnableThreadCount: LongWord;
function TicksToMilliseconds(Ticks: QWord): QWord;

procedure TerminateCurrentThread; noreturn;

{ Removes one terminated thread from the scheduler's terminated list,
  or returns nil. Its stack is no longer in use and may be freed. }
function TakeTerminatedThread: PThreadControlBlock;

{ Called by the executing processor's clock interrupt at ClockLevel, at
  clock time Now, with the number of 10 ms ticks that passed since the
  last tick (usually 0 or 1), found in user mode or not: charges them to
  the running thread and its time slice, and asks the dispatch interrupt
  to wake the threads whose timeout is due. }
procedure SchedulerClockInterrupt(Now: QWord; ElapsedTicks: QWord; InUserMode: Boolean);
{ When Processor's clock interrupt must come for the scheduler's own
  work even with its tick stopped (the boot processor samples the load
  averages every 5 seconds); NeverDue for none. }
function SchedulerHousekeepingTime(Processor: PProcessor): QWord;

{ Building blocks for synchronization objects. All "Locked" routines
  require the dispatcher lock to be held (and no processor's scheduling
  lock). }
function AcquireDispatcherLock: TPriorityLevel;
procedure ReleaseDispatcherLock(PreviousLevel: TPriorityLevel);
procedure ReadyThreadLocked(Thread: PThreadControlBlock);

{ Marks the current thread as waiting and switches to another thread.
  The caller must already have put the thread on some wait queue. Returns
  (with the dispatcher lock held again) once the thread has been readied
  and scheduled. }
procedure WaitCurrentThreadLocked;

{ Waits with a timeout (in milliseconds, or InfiniteTimeout) and,
  if Alertable, until alerted. If the caller put the thread on a wait
  list it must have set IsOnWaitList; whoever ends the wait takes it off
  every queue. }
function WaitCurrentThreadWithOptionsLocked(TimeoutMilliseconds: QWord;
  Alertable: Boolean): TWaitResult;

{ Ends the wait of Thread with Result: takes it off its wait list and
  the sleep queue and makes it ready. }
procedure WakeWaitingThreadLocked(Thread: PThreadControlBlock; Result: TWaitResult);
{ The same, raising the thread's priority by Boost for a while
  (Kernel.PriorityBoosts: the Boost* constants say how much for what). }
procedure WakeWaitingThreadWithBoostLocked(Thread: PThreadControlBlock; Result: TWaitResult;
  Boost: LongWord);

function ContextSwitchCount: QWord;
{ How many starvation boosts were given since start. }
function StarvationBoostTotal: QWord;

{ For the idle loop: True if work was found for this processor (a
  thread it may run, left in another's queue when a steal found that
  queue's lock taken), in which case it is dispatched before this
  returns; False if the processor may halt. }
function IdleProcessorFoundWork: Boolean;

implementation

uses
  Kernel.ProcessorPower,
  Runtime.LinkedList,
  Runtime.Memory,
  Runtime.Text,
  Runtime.Atomic,
  Hal.Platform,
  Kernel.Arch.Cpu,
  Kernel.Arch.TrapFrame,
  Kernel.Arch.ContextSwitch,
  Memory.Arch.PageTables,
  Kernel.SpinLock,
  Kernel.Interrupts,
  Kernel.Clock,
  Kernel.DeferredCalls,
  Kernel.InterProcessor,
  Kernel.ReadyQueues,
  Kernel.ProcessorTime,
  Kernel.PriorityBoosts,
  Kernel.Arch.ProcessorBlock,
  Kernel.Panic;

type
  { What a processor's switch leaves for the thread that runs next to
    finish (FinishThreadSwitch); under the processor's lock. }
  TSwitchHandover = record
    { The dispatcher lock is held across the switch (the old thread
      blocked or ended). }
    HandsOverDispatcherLock: Boolean;
    { The old thread, ready, to be placed on some processor once its
      registers are saved. }
    ThreadToPlace: PThreadControlBlock;
  end;

var
  DispatcherLock: TSpinLock;
  TerminatedThreads: TListEntry;
  Handovers: array[0..MaximumProcessors - 1] of TSwitchHandover;

  SwitchCount: Int64;
  StarvationBoostCount: Int64;

  { Exponentially decayed run queue lengths, fixed point with
    LoadFractionBits bits after the point. }
  LoadAverage: array[0..2] of QWord;
  { Clock nanoseconds of the next sample (taken by the boot processor's
    clock interrupt, which comes for it even while that one idles). }
  NextLoadSampleTime: QWord;

  { When the ready queues are next looked at for starved threads (clock
    nanoseconds); changed under the dispatcher lock, read without it by
    the clock and dispatch interrupts. }
  NextStarvationScanTime: QWord;

const
  LoadFractionBits = 11;
  LoadOne = QWord(1) shl LoadFractionBits;
  LoadSampleMilliseconds = 5000;
  { exp(-5/60), exp(-5/300), exp(-5/900) in the same fixed point. }
  LoadDecay: array[0..2] of QWord = (1884, 2014, 2037);

procedure RequestDispatchOn(Target: PProcessor);
begin
  if Target = CurrentProcessor then
    HalRequestSoftwareInterrupt(DispatchLevel)
  else
    RequestDispatchOnProcessor(Target);
end;

{ --- Placing ready threads ---------------------------------------------- }

{ Puts Thread, which just became ready (and is in no queue), on the run
  queue of a processor chosen for it, and asks that processor to
  reschedule if Thread should run there now. No scheduling lock may be
  held; the dispatcher lock may be. }
procedure PlaceReadyThread(Thread: PThreadControlBlock);
var
  Target: PProcessor;
  ShouldRunNow: Boolean;
begin
  Target := ChooseProcessorFor(Thread);
  LockProcessor(Target);
  EnqueueReadyThread(Thread, Target);
  ShouldRunNow := (Target^.RunningThread = Target^.IdleThread) or
    (RunningPriorityOf(Target) < Thread^.Priority);
  UnlockProcessor(Target);
  if ShouldRunNow then
    RequestDispatchOn(Target);
end;

{ --- Switching ---------------------------------------------------------- }

{ Run by the thread a switch went to, first thing: releases what the
  switching thread held across the switch and places the thread it left
  if that one is to go elsewhere. }
procedure FinishThreadSwitch;
var
  Processor: PProcessor;
  Handover: ^TSwitchHandover;
  ReleaseDispatcher: Boolean;
  ThreadToPlace: PThreadControlBlock;
begin
  Processor := CurrentProcessor;
  Handover := @Handovers[Processor^.Index];
  ReleaseDispatcher := Handover^.HandsOverDispatcherLock;
  ThreadToPlace := Handover^.ThreadToPlace;
  Handover^.HandsOverDispatcherLock := False;
  Handover^.ThreadToPlace := nil;
  UnlockProcessor(Processor);
  if ReleaseDispatcher then
    ReleaseSpinLockAtCurrentLevel(DispatcherLock);
  if ThreadToPlace <> nil then
    PlaceReadyThread(ThreadToPlace);
end;

{ Switches this processor to NextThread. The processor's lock is held
  (and the dispatcher lock if HandsOverDispatcherLock); the thread that
  runs next releases them. Returns, holding neither, once the current
  thread runs again - maybe on another processor. }
procedure SwitchToThread(NextThread: PThreadControlBlock; HandsOverDispatcherLock: Boolean);
var
  Processor: PProcessor;
  PreviousThread: PThreadControlBlock;
begin
  Processor := CurrentProcessor;
  PreviousThread := Processor^.RunningThread;
  Handovers[Processor^.Index].HandsOverDispatcherLock := HandsOverDispatcherLock;
  ChargeRunningThreadLocked(Processor, ClockNanoseconds);
  NextThread^.State := ThreadStateRunning;
  NextThread^.QuantumRemaining := QuantumTicks;
  Processor^.RunningThread := NextThread;
  SetRunningPriority(Processor, NextThread^.Priority);
  { The tick stopped while the processor idled (Kernel.Clock). }
  if (PreviousThread = Processor^.IdleThread) and (NextThread <> PreviousThread) then
    RestartClockTick
  else if (NextThread = Processor^.IdleThread) and (NextThread <> PreviousThread) then
    StopClockTick;
  NextThread^.LastProcessorIndex := Processor^.Index;
  AtomicIncrement(SwitchCount);

  ArchSaveFpuState(FpuStateArea(PreviousThread));
  ArchRestoreFpuState(FpuStateArea(NextThread));

  ArchSetThreadInterruptStack(NextThread^.StackTop);
  if NextThread^.AddressSpaceRoot <> PreviousThread^.AddressSpaceRoot then
    ActivateAddressSpace(NextThread^.AddressSpaceRoot);
  { Each user thread has its own thread pointer (FS base). }
  if NextThread^.UserThreadPointer <> PreviousThread^.UserThreadPointer then
    ArchSetUserThreadPointer(NextThread^.UserThreadPointer);
  ArchSwitchContext(@PreviousThread^.SavedStackPointer, NextThread^.SavedStackPointer);

  { Execution continues here when PreviousThread is scheduled again. }
  FinishThreadSwitch;
end;

{ The running thread gives way but stays ready: back into this
  processor's queue (still locked, so no one takes it before the switch
  is over) - or, if it may no longer run here or another processor it
  may run on is idle, to be placed once the switch is over. }
procedure RequeueRunningThreadLocked(Processor: PProcessor; Thread: PThreadControlBlock);
begin
  if ThreadMayRunOn(Thread, Processor) and (FindIdleProcessorFor(Thread, Processor) = nil) then
    EnqueueReadyThread(Thread, Processor)
  else
  begin
    Thread^.State := ThreadStateReady;
    Thread^.QueuedProcessorIndex := NotQueued;
    Handovers[Processor^.Index].ThreadToPlace := Thread;
  end;
end;

{ The running thread used up its time slice: a boost loses a level, a
  starvation boost all of it (Kernel.PriorityBoosts). }
procedure DecayRunningThreadPriority(Processor: PProcessor; Thread: PThreadControlBlock);
begin
  if Thread^.StarvationBoosted then
  begin
    Thread^.StarvationBoosted := False;
    Thread^.Priority := Thread^.BasePriority;
  end
  else
    Thread^.Priority := DecayedPriority(Thread^.BasePriority, Thread^.Priority);
  SetRunningPriority(Processor, Thread^.Priority);
end;

{ Gives the processor to a more important ready thread, to one of equal
  priority when the time slice is over, or to any if the running thread
  may no longer run here. The processor's lock is held; it is released
  (by the next thread if there was a switch) before this returns. }
procedure PreemptIfNeededLocked(Processor: PProcessor);
var
  Running: PThreadControlBlock;
  NextThread: PThreadControlBlock;
  MustLeave: Boolean;
  MinimumPriority: Integer;
  SliceOver: Boolean;
begin
  Running := Processor^.RunningThread;
  SliceOver := Processor^.QuantumHasExpired;
  Processor^.QuantumHasExpired := False;
  if Running = Processor^.IdleThread then
  begin
    MustLeave := False;
    MinimumPriority := LowestThreadPriority;
  end
  else
  begin
    if SliceOver then
      DecayRunningThreadPriority(Processor, Running);
    MustLeave := not ThreadMayRunOn(Running, Processor);
    if MustLeave then
      MinimumPriority := LowestThreadPriority
    else if SliceOver then
      MinimumPriority := Integer(Running^.Priority)
    else
      MinimumPriority := Integer(Running^.Priority) + 1;
  end;

  NextThread := TakeReadyThreadFor(Processor, MinimumPriority);
  if (NextThread = nil) and MustLeave then
    NextThread := Processor^.IdleThread;
  if NextThread = nil then
  begin
    if SliceOver then
      Running^.QuantumRemaining := QuantumTicks;
    UnlockProcessor(Processor);
    Exit;
  end;
  if Running <> Processor^.IdleThread then
    RequeueRunningThreadLocked(Processor, Running);
  SwitchToThread(NextThread, False);
end;

{ The current thread stopped being runnable (it waits or ended); the
  dispatcher lock is held. Switches to the next thread, handing over
  both locks. }
procedure SwitchAwayFromBlockedThreadLocked;
var
  Processor: PProcessor;
  NextThread: PThreadControlBlock;
begin
  Processor := CurrentProcessor;
  LockProcessor(Processor);
  NextThread := TakeReadyThreadFor(Processor, LowestThreadPriority);
  if NextThread = nil then
    NextThread := Processor^.IdleThread;
  SwitchToThread(NextThread, True);
end;

{ --- Sleeping -------------------------------------------------------- }

{ A thread waiting with a timeout is on the sleep queue of the processor
  it began the wait on, whose clock interrupt comes when the first one is
  due (Kernel.Clock); whoever ends the wait first takes it off. All of
  this is under the dispatcher lock. }

procedure InitializeSleepQueue(Processor: PProcessor);
begin
  InitializeListHead(Processor^.SleepQueue);
  Processor^.NextWakeUpTime := NeverDue;
end;

procedure UpdateNextWakeUpTime(Processor: PProcessor);
var
  First: PListEntry;
begin
  First := FirstListEntry(Processor^.SleepQueue);
  if First = nil then
    Processor^.NextWakeUpTime := NeverDue
  else
    Processor^.NextWakeUpTime := ThreadFromTimerLink(First)^.WakeUpTime;
end;

procedure InsertIntoSleepQueue(Thread: PThreadControlBlock);
var
  Processor: PProcessor;
  Entry: PListEntry;
begin
  Processor := CurrentProcessor;
  { Keep the queue ordered by wake-up time; equal times stay in order. }
  Entry := Processor^.SleepQueue.Next;
  while (Entry <> @Processor^.SleepQueue) and
        (ThreadFromTimerLink(Entry)^.WakeUpTime <= Thread^.WakeUpTime) do
    Entry := Entry^.Next;
  InsertBefore(Entry, @Thread^.TimerLink);
  Thread^.IsOnSleepQueue := True;
  Thread^.SleepProcessorIndex := Processor^.Index;
  UpdateNextWakeUpTime(Processor);
  RequestClockInterruptBy(Thread^.WakeUpTime);
end;

procedure RemoveFromSleepQueue(Thread: PThreadControlBlock);
begin
  RemoveListEntry(@Thread^.TimerLink);
  Thread^.IsOnSleepQueue := False;
  UpdateNextWakeUpTime(ProcessorByIndex(Thread^.SleepProcessorIndex));
end;

{ Wakes the threads on this processor's sleep queue whose time has come,
  and asks for the clock interrupt of the next one. }
procedure WakeExpiredSleepersLocked;
var
  Processor: PProcessor;
  Now: QWord;
  Thread: PThreadControlBlock;
begin
  Processor := CurrentProcessor;
  if ListIsEmpty(Processor^.SleepQueue) then
    Exit;
  Now := ClockNanoseconds;
  while not ListIsEmpty(Processor^.SleepQueue) do
  begin
    Thread := ThreadFromTimerLink(Processor^.SleepQueue.Next);
    if Thread^.WakeUpTime > Now then
      Break;
    WakeWaitingThreadLocked(Thread, WaitTimedOut);
  end;
  RequestClockInterruptBy(Processor^.NextWakeUpTime);
end;

{ --- Starvation ------------------------------------------------------- }

{ Gives the threads that have been ready for StarvationNanoseconds
  without running the top priority of their class for one time slice
  (Kernel.PriorityBoosts); at most StarvationScanLimit at a time. The
  dispatcher lock is held, no scheduling lock. }
procedure BoostStarvedThreadsLocked;
var
  Now: QWord;
  Thread: PThreadControlBlock;
  Boosted: Integer;
begin
  Now := ClockNanoseconds;
  if Now < NextStarvationScanTime then
    Exit;
  NextStarvationScanTime := Now + StarvationScanNanoseconds;
  Boosted := 0;
  while Boosted < StarvationScanLimit do
  begin
    Thread := TakeStarvedReadyThread(Now);
    if Thread = nil then
      Break;
    Thread^.Priority := HighestVariablePriority;
    Thread^.StarvationBoosted := True;
    AtomicIncrement(StarvationBoostCount);
    PlaceReadyThread(Thread);
    Inc(Boosted);
  end;
end;

function StarvationBoostTotal: QWord;
begin
  Result := QWord(StarvationBoostCount);
end;

{ --- Interrupt handlers ---------------------------------------------- }

procedure HandleDispatchInterrupt(Frame: PTrapFrame; Context: Pointer);
var
  Processor: PProcessor;
  Now: QWord;
begin
  { Suspend to RAM freezes processors here, where they hold no spin lock
    (the dispatch interrupt only runs below dispatch level). }
  FreezeThisProcessorIfRequested;
  { Work handed over by interrupt handlers may ready threads, so it runs
    before the next thread is chosen. }
  RunDeferredCalls;
  Processor := CurrentProcessor;
  Now := ClockNanoseconds;
  { Timeouts and starvation need the dispatcher lock; most dispatches
    (time slices, wake-ups from elsewhere) do not take it at all. }
  if (Now >= Processor^.NextWakeUpTime) or (Now >= NextStarvationScanTime) then
  begin
    AcquireSpinLockAtCurrentLevel(DispatcherLock);
    WakeExpiredSleepersLocked;
    BoostStarvedThreadsLocked;
    ReleaseSpinLockAtCurrentLevel(DispatcherLock);
  end;
  LockProcessor(Processor);
  PreemptIfNeededLocked(Processor);
end;

function RunnableThreadCount: LongWord;
var
  Index: LongWord;
  Processor: PProcessor;
begin
  Result := ReadyThreadTotal;
  for Index := 0 to ProcessorTotal - 1 do
  begin
    Processor := ProcessorByIndex(Index);
    if Processor^.IsOnline and (Processor^.RunningThread <> Processor^.IdleThread) then
      Inc(Result);
  end;
end;

{ Runs at clock level every few seconds; only integer arithmetic. }
procedure SampleLoad;
var
  Runnable: QWord;
  Index: Integer;
begin
  Runnable := QWord(RunnableThreadCount) * LoadOne;
  for Index := 0 to 2 do
    LoadAverage[Index] := (LoadAverage[Index] * LoadDecay[Index] +
      Runnable * (LoadOne - LoadDecay[Index])) shr LoadFractionBits;
end;

procedure GetLoadAverages(out OneMinute, FiveMinutes, FifteenMinutes: LongWord);
begin
  OneMinute := LongWord((LoadAverage[0] * 100 + LoadOne div 2) shr LoadFractionBits);
  FiveMinutes := LongWord((LoadAverage[1] * 100 + LoadOne div 2) shr LoadFractionBits);
  FifteenMinutes := LongWord((LoadAverage[2] * 100 + LoadOne div 2) shr LoadFractionBits);
end;

procedure SchedulerClockInterrupt(Now: QWord; ElapsedTicks: QWord; InUserMode: Boolean);
var
  Processor: PProcessor;
  Thread: PThreadControlBlock;
  DispatchNeeded: Boolean;
begin
  Processor := CurrentProcessor;
  DispatchNeeded := (Now >= Processor^.NextWakeUpTime) or (Now >= NextStarvationScanTime);

  if (Processor^.Index = 0) and (Now >= NextLoadSampleTime) then
  begin
    SampleLoad;
    NextLoadSampleTime := Now + LoadSampleMilliseconds * NanosecondsPerMillisecond;
  end;

  if ElapsedTicks > 0 then
  begin
    Thread := Processor^.RunningThread;
    ChargeClockTicks(Thread, ElapsedTicks, InUserMode);
    if Thread <> Processor^.IdleThread then
    begin
      Thread^.QuantumRemaining := Thread^.QuantumRemaining - LongInt(ElapsedTicks);
      if Thread^.QuantumRemaining <= 0 then
      begin
        Processor^.QuantumHasExpired := True;
        DispatchNeeded := True;
      end;
    end;
  end;

  if DispatchNeeded then
    HalRequestSoftwareInterrupt(DispatchLevel);
end;

function SchedulerHousekeepingTime(Processor: PProcessor): QWord;
begin
  if Processor^.Index = 0 then
    Result := NextLoadSampleTime
  else
    Result := NeverDue;
end;

{ --- Thread start and exit ------------------------------------------- }

{ First code run by every new thread. It arrives here from a context
  switch, at DispatchLevel with interrupts disabled, holding what the
  switch handed over. }
procedure ThreadStartTrampoline;
var
  Thread: PThreadControlBlock;
begin
  FinishThreadSwitch;
  LowerPriorityLevel(PassiveLevel);
  EnableInterrupts;

  Thread := CurrentThread;
  Thread^.StartRoutine(Thread^.StartContext);
  TerminateCurrentThread;
end;

procedure TerminateCurrentThread; noreturn;
var
  Thread: PThreadControlBlock;
begin
  AcquireDispatcherLock;
  Thread := CurrentProcessor^.RunningThread;
  if Thread = CurrentProcessor^.IdleThread then
    KernelPanic('the idle thread tried to terminate');

  Thread^.State := ThreadStateTerminated;
  { Taken off the list (and its stack freed) only once the dispatcher
    lock is released, after the switch away from it. }
  InsertAtTail(TerminatedThreads, @Thread^.SchedulerLink);
  SwitchAwayFromBlockedThreadLocked;

  KernelPanicWithCode(PanicSchedulerFailure, 'a terminated thread was resumed',
    QWord(Thread), 0, 0, 0);
end;

function TakeTerminatedThread: PThreadControlBlock;
var
  PreviousLevel: TPriorityLevel;
  Entry: PListEntry;
begin
  PreviousLevel := AcquireDispatcherLock;
  Entry := RemoveHeadEntry(TerminatedThreads);
  ReleaseDispatcherLock(PreviousLevel);

  if Entry = nil then
    Result := nil
  else
    Result := ThreadFromSchedulerLink(Entry);
end;

{ --- Finding a thread's processor ------------------------------------ }

{ Locks the processor whose queue Thread is in (if ready) or which runs
  it (if running) and returns it; nil (nothing locked) if it is neither.
  The dispatcher lock is held, so a waiting thread stays waiting; a
  thread moving between queues and processors is waited for. }
function LockProcessorOfThreadLocked(Thread: PThreadControlBlock): PProcessor;
var
  Index: LongWord;
begin
  repeat
    case Thread^.State of
      ThreadStateReady:
        begin
          Index := Thread^.QueuedProcessorIndex;
          if Index <> NotQueued then
          begin
            Result := ProcessorByIndex(Index);
            LockProcessor(Result);
            if (Thread^.State = ThreadStateReady) and (Thread^.QueuedProcessorIndex = Index) then
              Exit;
            UnlockProcessor(Result);
          end;
        end;
      ThreadStateRunning:
        begin
          Result := ProcessorByIndex(Thread^.LastProcessorIndex);
          LockProcessor(Result);
          if Result^.RunningThread = Thread then
            Exit;
          UnlockProcessor(Result);
        end;
    else
      Exit(nil);
    end;
    CpuRelax;
  until False;
end;

{ --- Public interface ------------------------------------------------ }

function AcquireDispatcherLock: TPriorityLevel;
begin
  Result := AcquireSpinLock(DispatcherLock);
end;

procedure ReleaseDispatcherLock(PreviousLevel: TPriorityLevel);
begin
  ReleaseSpinLock(DispatcherLock, PreviousLevel);
end;

procedure ReadyThreadLocked(Thread: PThreadControlBlock);
begin
  PlaceReadyThread(Thread);
end;

procedure WakeWaitingThreadLocked(Thread: PThreadControlBlock; Result: TWaitResult);
begin
  WakeWaitingThreadWithBoostLocked(Thread, Result, BoostNone);
end;

procedure WakeWaitingThreadWithBoostLocked(Thread: PThreadControlBlock; Result: TWaitResult;
  Boost: LongWord);
begin
  if Thread^.IsOnWaitList then
  begin
    RemoveListEntry(@Thread^.SchedulerLink);
    Thread^.IsOnWaitList := False;
  end;
  UnlinkWaitBlocksLocked(Thread);
  if Thread^.IsOnSleepQueue then
    RemoveFromSleepQueue(Thread);
  Thread^.WaitResult := Result;
  Thread^.WaitIsAlertable := False;
  if Result = WaitSignaled then
    Thread^.Priority := BoostedPriority(Thread^.BasePriority, Thread^.Priority, Boost);
  ReadyThreadLocked(Thread);
end;

function WaitCurrentThreadWithOptionsLocked(TimeoutMilliseconds: QWord;
  Alertable: Boolean): TWaitResult;
var
  Thread: PThreadControlBlock;
begin
  Thread := CurrentProcessor^.RunningThread;
  if (Alertable and Thread^.AlertPending) or (TimeoutMilliseconds = 0) then
  begin
    { The wait ends before it starts. }
    if Thread^.IsOnWaitList then
    begin
      RemoveListEntry(@Thread^.SchedulerLink);
      Thread^.IsOnWaitList := False;
    end;
    UnlinkWaitBlocksLocked(Thread);
    if TimeoutMilliseconds = 0 then
      Exit(WaitTimedOut);
    Exit(WaitAlerted);
  end;

  Thread^.WaitIsAlertable := Alertable;
  Thread^.WaitResult := WaitSignaled;
  if TimeoutMilliseconds <> InfiniteTimeout then
  begin
    Thread^.WakeUpTime := DeadlineAfterMilliseconds(TimeoutMilliseconds);
    if Thread^.WakeUpTime <> NeverDue then
      InsertIntoSleepQueue(Thread);
  end;
  WaitCurrentThreadLocked;
  Result := Thread^.WaitResult;
end;

procedure SetThreadPriority(Thread: PThreadControlBlock; Priority: LongWord);
var
  PreviousLevel: TPriorityLevel;
  Processor: PProcessor;
begin
  if Priority > HighestThreadPriority then
    Priority := HighestThreadPriority;
  if Priority < LowestThreadPriority then
    Priority := LowestThreadPriority;
  PreviousLevel := AcquireDispatcherLock;
  Processor := LockProcessorOfThreadLocked(Thread);
  { A new base priority ends any boost. }
  Thread^.BasePriority := Priority;
  Thread^.StarvationBoosted := False;
  if Processor = nil then
    Thread^.Priority := Priority
  else if Thread^.State = ThreadStateReady then
  begin
    { Move it to the queue of its new priority. }
    RemoveReadyThread(Thread);
    Thread^.Priority := Priority;
    UnlockProcessor(Processor);
    PlaceReadyThread(Thread);
  end
  else
  begin
    Thread^.Priority := Priority;
    SetRunningPriority(Processor, Priority);
    UnlockProcessor(Processor);
  end;
  ReleaseDispatcherLock(PreviousLevel);
end;

procedure SetThreadAffinity(Thread: PThreadControlBlock; Mask: QWord);
var
  PreviousLevel: TPriorityLevel;
  Processor: PProcessor;
begin
  if Mask = 0 then
    Mask := AllProcessors;
  PreviousLevel := AcquireDispatcherLock;
  Processor := LockProcessorOfThreadLocked(Thread);
  Thread^.AffinityMask := Mask;
  if Processor <> nil then
  begin
    if ThreadMayRunOn(Thread, Processor) then
      UnlockProcessor(Processor)
    else if Thread^.State = ThreadStateReady then
    begin
      RemoveReadyThread(Thread);
      UnlockProcessor(Processor);
      PlaceReadyThread(Thread);
    end
    else
    begin
      { Its processor reschedules, and it gives way (PreemptIfNeeded). }
      UnlockProcessor(Processor);
      RequestDispatchOn(Processor);
    end;
  end;
  ReleaseDispatcherLock(PreviousLevel);
end;

function TicksToMilliseconds(Ticks: QWord): QWord;
begin
  Result := Ticks * 1000 div ClockTicksPerSecond;
end;

procedure AlertThread(Thread: PThreadControlBlock);
var
  PreviousLevel: TPriorityLevel;
begin
  PreviousLevel := AcquireDispatcherLock;
  Thread^.AlertPending := True;
  if (Thread^.State = ThreadStateWaiting) and Thread^.WaitIsAlertable then
    WakeWaitingThreadLocked(Thread, WaitAlerted);
  ReleaseDispatcherLock(PreviousLevel);
end;

procedure ClearCurrentThreadAlert;
var
  PreviousLevel: TPriorityLevel;
begin
  PreviousLevel := AcquireDispatcherLock;
  CurrentProcessor^.RunningThread^.AlertPending := False;
  ReleaseDispatcherLock(PreviousLevel);
end;

procedure WaitCurrentThreadLocked;
var
  Thread: PThreadControlBlock;
begin
  Thread := CurrentProcessor^.RunningThread;
  if Thread = CurrentProcessor^.IdleThread then
    KernelPanic('the idle thread tried to wait');
  { A starvation boost is for one time slice of running only. }
  if Thread^.StarvationBoosted then
  begin
    Thread^.StarvationBoosted := False;
    Thread^.Priority := Thread^.BasePriority;
  end;
  Thread^.State := ThreadStateWaiting;
  SwitchAwayFromBlockedThreadLocked;
  { Readied and run again: the switch released the dispatcher lock,
    which the caller still expects to hold. }
  AcquireSpinLockAtCurrentLevel(DispatcherLock);
end;

function IdleProcessorFoundWork: Boolean;
var
  PreviousLevel: TPriorityLevel;
  Processor: PProcessor;
begin
  PreviousLevel := RaisePriorityLevel(DispatchLevel);
  Processor := CurrentProcessor;
  Result := StealWasRefused(Processor) and PullThreadForIdleProcessor(Processor);
  if Result then
    HalRequestSoftwareInterrupt(DispatchLevel);
  { The dispatch interrupt, if requested, comes as the level drops. }
  LowerPriorityLevel(PreviousLevel);
end;

procedure StartProcessorScheduling(Processor: PProcessor; IdleThread: PThreadControlBlock);
begin
  InitializeSleepQueue(Processor);
  Handovers[Processor^.Index].HandsOverDispatcherLock := False;
  Handovers[Processor^.Index].ThreadToPlace := nil;
  IdleThread^.State := ThreadStateRunning;
  IdleThread^.Priority := IdlePriority;
  IdleThread^.BasePriority := IdlePriority;
  IdleThread^.AddressSpaceRoot := KernelPageTableRoot;
  Processor^.QuantumHasExpired := False;
  Processor^.IdleThread := IdleThread;
  Processor^.RunningThread := IdleThread;
  SetRunningPriority(Processor, IdlePriority);
  StartProcessorTime(Processor, ClockNanoseconds);
  ArchSetThreadInterruptStack(IdleThread^.StackTop);
  MarkProcessorOnline(Processor);
end;

procedure InitializeScheduler(IdleThread: PThreadControlBlock);
begin
  InitializeSpinLock(DispatcherLock);
  InitializeReadyQueues;
  InitializeListHead(TerminatedThreads);
  SwitchCount := 0;
  StarvationBoostCount := 0;
  NextStarvationScanTime := ClockNanoseconds + StarvationScanNanoseconds;
  StartProcessorScheduling(CurrentProcessor, IdleThread);

  if not RegisterInterruptHandler(HalDispatchInterruptVector, @HandleDispatchInterrupt, nil) then
    KernelPanic('dispatch interrupt vector is already in use');
end;

procedure StartSchedulingOnThisProcessor(IdleThread: PThreadControlBlock);
begin
  StartProcessorScheduling(CurrentProcessor, IdleThread);
end;

procedure InitializeThreadControlBlock(Thread: PThreadControlBlock;
  StackBase, StackTop: QWord; StartRoutine: TThreadStartRoutine;
  StartContext: Pointer; Priority: LongWord; Name: PChar);
begin
  if (Priority < LowestThreadPriority) or (Priority > HighestThreadPriority) then
    KernelPanicWithCode(PanicSchedulerFailure, 'invalid thread priority', Priority, 0, 0, 0);

  Thread^.StackBase := StackBase;
  Thread^.StackTop := StackTop;
  Thread^.State := ThreadStateInitialized;
  Thread^.Priority := Priority;
  Thread^.BasePriority := Priority;
  Thread^.StarvationBoosted := False;
  Thread^.ReadySince := 0;
  Thread^.QuantumRemaining := QuantumTicks;
  Thread^.AffinityMask := AllProcessors;
  Thread^.LastProcessorIndex := CurrentProcessorIndexOrZero;
  Thread^.QueuedProcessorIndex := NotQueued;
  InitializeListHead(Thread^.SchedulerLink);
  InitializeListHead(Thread^.TimerLink);
  Thread^.WakeUpTime := 0;
  Thread^.StartRoutine := StartRoutine;
  Thread^.StartContext := StartContext;
  CopyText(@Thread^.Name[0], Name, ThreadNameLength);
  { Kernel threads use the kernel address space; the process manager
    changes this for threads of user processes. }
  Thread^.AddressSpaceRoot := KernelPageTableRoot;
  Thread^.UserThreadPointer := 0;
  ArchInitializeFpuState(FpuStateArea(Thread));
  Thread^.SavedStackPointer := ArchPrepareInitialStack(StackTop, @ThreadStartTrampoline);
end;

procedure StartThread(Thread: PThreadControlBlock);
var
  PreviousLevel: TPriorityLevel;
begin
  if Thread^.State <> ThreadStateInitialized then
    KernelPanicWithCode(PanicSchedulerFailure, 'starting a thread twice', QWord(Thread), 0, 0, 0);

  PreviousLevel := AcquireDispatcherLock;
  ReadyThreadLocked(Thread);
  ReleaseDispatcherLock(PreviousLevel);
end;

function CurrentThread: PThreadControlBlock;
begin
  { One load: the thread cannot move to another processor halfway. }
  Result := PThreadControlBlock(ArchCurrentThreadBlock);
end;

procedure YieldExecution;
var
  PreviousLevel: TPriorityLevel;
  Processor: PProcessor;
  Running: PThreadControlBlock;
  NextThread: PThreadControlBlock;
begin
  PreviousLevel := RaisePriorityLevel(DispatchLevel);
  Processor := CurrentProcessor;
  LockProcessor(Processor);
  Running := Processor^.RunningThread;
  NextThread := nil;
  if Running <> Processor^.IdleThread then
    NextThread := TakeReadyThreadFor(Processor, Integer(Running^.Priority));
  if NextThread = nil then
    UnlockProcessor(Processor)
  else
  begin
    RequeueRunningThreadLocked(Processor, Running);
    SwitchToThread(NextThread, False);
  end;
  LowerPriorityLevel(PreviousLevel);
end;

procedure SleepMilliseconds(Milliseconds: QWord);
var
  PreviousLevel: TPriorityLevel;
begin
  PreviousLevel := AcquireDispatcherLock;
  WaitCurrentThreadWithOptionsLocked(Milliseconds, False);
  ReleaseDispatcherLock(PreviousLevel);
end;

function SleepAlertable(Milliseconds: QWord): Boolean;
var
  PreviousLevel: TPriorityLevel;
begin
  PreviousLevel := AcquireDispatcherLock;
  Result := WaitCurrentThreadWithOptionsLocked(Milliseconds, True) <> WaitAlerted;
  ReleaseDispatcherLock(PreviousLevel);
end;

function ContextSwitchCount: QWord;
begin
  Result := QWord(SwitchCount);
end;

end.
