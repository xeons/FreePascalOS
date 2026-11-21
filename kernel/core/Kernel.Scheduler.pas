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

  All scheduler state, including every wait queue, is protected by the
  dispatcher lock, held at DispatchLevel.

  Thread switches happen at DispatchLevel in one of two ways:

    * Preemption. The clock interrupt and ReadyThreadLocked do not switch
      threads themselves; they request the dispatch software interrupt,
      which arrives as soon as the processor drops below DispatchLevel and
      then picks the next thread.

    * Blocking. A thread that waits or sleeps calls WaitCurrentThreadLocked
      with the dispatcher lock held, which switches away immediately.

  The dispatcher lock is held across a switch and released by whichever
  thread runs next: either where it switched away earlier, or in
  ThreadStartTrampoline when it runs for the first time.
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
  require the dispatcher lock to be held. }
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

function ContextSwitchCount: QWord;

implementation

uses
  Kernel.ProcessorPower,
  Runtime.LinkedList,
  Runtime.Memory,
  Runtime.Text,
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
  Kernel.Arch.ProcessorBlock,
  Kernel.Panic;

var
  DispatcherLock: TSpinLock;
  TerminatedThreads: TListEntry;

  SwitchCount: QWord;

  { Exponentially decayed run queue lengths, fixed point with
    LoadFractionBits bits after the point. }
  LoadAverage: array[0..2] of QWord;
  { Clock nanoseconds of the next sample (taken by the boot processor's
    clock interrupt, which comes for it even while that one idles). }
  NextLoadSampleTime: QWord;

const
  LoadFractionBits = 11;
  LoadOne = QWord(1) shl LoadFractionBits;
  LoadSampleMilliseconds = 5000;
  { exp(-5/60), exp(-5/300), exp(-5/900) in the same fixed point. }
  LoadDecay: array[0..2] of QWord = (1884, 2014, 2037);

{ --- Choosing threads -------------------------------------------------- }

{ Decides whether the running thread should give way: to a more
  important ready thread, to one of equal priority when its time slice
  is over, or because it may no longer run here. }
function RunningThreadShouldBePreempted: Boolean;
var
  Processor: PProcessor;
  Running: PThreadControlBlock;
  BestReady: Integer;
begin
  Processor := CurrentProcessor;
  Running := Processor^.RunningThread;
  if (Running <> Processor^.IdleThread) and not ThreadMayRunOn(Running, Processor) then
    Exit(True);
  BestReady := BestReadyPriorityFor(Processor);
  if BestReady < 0 then
    Exit(False);
  if Running = Processor^.IdleThread then
    Exit(True);
  if BestReady > Integer(Running^.Priority) then
    Exit(True);
  Result := Processor^.QuantumHasExpired and (BestReady = Integer(Running^.Priority));
end;

{ The next thread for this processor, or its idle thread. }
function TakeNextThreadLocked: PThreadControlBlock;
begin
  Result := TakeReadyThreadFor(CurrentProcessor);
  if Result = nil then
    Result := CurrentProcessor^.IdleThread;
end;

procedure SwitchToThreadLocked(NextThread: PThreadControlBlock);
var
  Processor: PProcessor;
  PreviousThread: PThreadControlBlock;
begin
  Processor := CurrentProcessor;
  PreviousThread := Processor^.RunningThread;
  ChargeRunningThreadLocked(Processor, ClockNanoseconds);
  NextThread^.State := ThreadStateRunning;
  NextThread^.QuantumRemaining := QuantumTicks;
  Processor^.RunningThread := NextThread;
  { The tick stopped while the processor idled (Kernel.Clock). }
  if (PreviousThread = Processor^.IdleThread) and (NextThread <> PreviousThread) then
    RestartClockTick;
  NextThread^.LastProcessorIndex := Processor^.Index;
  Inc(SwitchCount);

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
end;

{ Picks the next thread to run after the running thread stopped being
  runnable (it is waiting or terminated) and switches to it. }
procedure SwitchAwayFromBlockedThreadLocked;
begin
  SwitchToThreadLocked(TakeNextThreadLocked);
end;

{ Puts Thread, which just became ready, on a run queue and asks the
  processor of that queue to reschedule if Thread should run there now. }
procedure PlaceReadyThreadLocked(Thread: PThreadControlBlock);
var
  Target: PProcessor;
begin
  Target := ChooseProcessorFor(Thread);
  EnqueueReadyThread(Thread, Target);
  if (Target^.RunningThread <> Target^.IdleThread) and
     (Target^.RunningThread^.Priority >= Thread^.Priority) then
    Exit;
  if Target = CurrentProcessor then
    HalRequestSoftwareInterrupt(DispatchLevel)
  else
    RequestDispatchOnProcessor(Target);
end;

{ The running thread gives way but stays ready: back into this
  processor's queue, where an idle processor may take it, or - if it may
  no longer run here - to a processor of its own. }
procedure RequeueRunningThreadLocked(Thread: PThreadControlBlock);
var
  Idle: PProcessor;
begin
  if not ThreadMayRunOn(Thread, CurrentProcessor) then
  begin
    PlaceReadyThreadLocked(Thread);
    Exit;
  end;
  EnqueueReadyThread(Thread, CurrentProcessor);
  Idle := FindIdleProcessorFor(Thread, CurrentProcessor);
  if Idle <> nil then
    RequestDispatchOnProcessor(Idle);
end;

procedure PreemptIfNeededLocked;
var
  Processor: PProcessor;
  NextThread: PThreadControlBlock;
  Running: PThreadControlBlock;
begin
  Processor := CurrentProcessor;
  if not RunningThreadShouldBePreempted then
  begin
    if Processor^.QuantumHasExpired then
      Processor^.RunningThread^.QuantumRemaining := QuantumTicks;
    Processor^.QuantumHasExpired := False;
    Exit;
  end;

  Processor^.QuantumHasExpired := False;
  Running := Processor^.RunningThread;
  NextThread := TakeNextThreadLocked;
  if Running <> Processor^.IdleThread then
    RequeueRunningThreadLocked(Running);
  if NextThread <> Running then
    SwitchToThreadLocked(NextThread);
end;

{ --- Sleeping -------------------------------------------------------- }

{ A thread waiting with a timeout is on the sleep queue of the processor
  it began the wait on, whose clock interrupt comes when the first one is
  due (Kernel.Clock); whoever ends the wait first takes it off. }

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

{ --- Interrupt handlers ---------------------------------------------- }

procedure HandleDispatchInterrupt(Frame: PTrapFrame; Context: Pointer);
begin
  { Suspend to RAM freezes processors here, where they hold no spin lock
    (the dispatch interrupt only runs below dispatch level). }
  FreezeThisProcessorIfRequested;
  { Work handed over by interrupt handlers may ready threads, so it runs
    before the next thread is chosen. }
  RunDeferredCalls;
  AcquireSpinLockAtCurrentLevel(DispatcherLock);
  WakeExpiredSleepersLocked;
  PreemptIfNeededLocked;
  ReleaseSpinLockAtCurrentLevel(DispatcherLock);
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
  DispatchNeeded := Now >= Processor^.NextWakeUpTime;

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
  switch, so it owns the dispatcher lock and runs at DispatchLevel with
  interrupts disabled. }
procedure ThreadStartTrampoline;
var
  Thread: PThreadControlBlock;
begin
  ReleaseSpinLockAtCurrentLevel(DispatcherLock);
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
  PlaceReadyThreadLocked(Thread);
end;

procedure WakeWaitingThreadLocked(Thread: PThreadControlBlock; Result: TWaitResult);
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
begin
  if Priority > HighestThreadPriority then
    Priority := HighestThreadPriority;
  if Priority < LowestThreadPriority then
    Priority := LowestThreadPriority;
  PreviousLevel := AcquireDispatcherLock;
  if Thread^.State = ThreadStateReady then
  begin
    { Move it to the queue of its new priority. }
    RemoveReadyThread(Thread);
    Thread^.Priority := Priority;
    PlaceReadyThreadLocked(Thread);
  end
  else
    Thread^.Priority := Priority;
  ReleaseDispatcherLock(PreviousLevel);
end;

{ The processor Thread is running on, or nil. }
function ProcessorRunning(Thread: PThreadControlBlock): PProcessor;
var
  Index: LongWord;
begin
  for Index := 0 to ProcessorTotal - 1 do
  begin
    Result := ProcessorByIndex(Index);
    if Result^.IsOnline and (Result^.RunningThread = Thread) then
      Exit;
  end;
  Result := nil;
end;

procedure SetThreadAffinity(Thread: PThreadControlBlock; Mask: QWord);
var
  PreviousLevel: TPriorityLevel;
  Processor: PProcessor;
begin
  if Mask = 0 then
    Mask := AllProcessors;
  PreviousLevel := AcquireDispatcherLock;
  Thread^.AffinityMask := Mask;
  if Thread^.State = ThreadStateReady then
  begin
    if not ThreadMayRunOn(Thread, ProcessorByIndex(Thread^.QueuedProcessorIndex)) then
    begin
      RemoveReadyThread(Thread);
      PlaceReadyThreadLocked(Thread);
    end;
  end
  else if Thread^.State = ThreadStateRunning then
  begin
    { Its processor reschedules, and it gives way (PreemptIfNeeded). }
    Processor := ProcessorRunning(Thread);
    if (Processor <> nil) and not ThreadMayRunOn(Thread, Processor) then
    begin
      if Processor = CurrentProcessor then
        HalRequestSoftwareInterrupt(DispatchLevel)
      else
        RequestDispatchOnProcessor(Processor);
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
begin
  if CurrentProcessor^.RunningThread = CurrentProcessor^.IdleThread then
    KernelPanic('the idle thread tried to wait');
  CurrentProcessor^.RunningThread^.State := ThreadStateWaiting;
  SwitchAwayFromBlockedThreadLocked;
end;

procedure InitializeScheduler(IdleThread: PThreadControlBlock);
begin
  InitializeSpinLock(DispatcherLock);
  InitializeReadyQueues;
  InitializeSleepQueue(CurrentProcessor);
  InitializeListHead(TerminatedThreads);
  CurrentProcessor^.QuantumHasExpired := False;
  SwitchCount := 0;

  IdleThread^.State := ThreadStateRunning;
  IdleThread^.Priority := IdlePriority;
  IdleThread^.AddressSpaceRoot := KernelPageTableRoot;
  CurrentProcessor^.IdleThread := IdleThread;
  CurrentProcessor^.RunningThread := IdleThread;
  StartProcessorTime(CurrentProcessor, ClockNanoseconds);
  ArchSetThreadInterruptStack(IdleThread^.StackTop);
  MarkProcessorOnline(CurrentProcessor);

  if not RegisterInterruptHandler(HalDispatchInterruptVector, @HandleDispatchInterrupt, nil) then
    KernelPanic('dispatch interrupt vector is already in use');
end;

procedure StartSchedulingOnThisProcessor(IdleThread: PThreadControlBlock);
var
  Processor: PProcessor;
begin
  Processor := CurrentProcessor;
  InitializeSleepQueue(Processor);
  IdleThread^.State := ThreadStateRunning;
  IdleThread^.Priority := IdlePriority;
  IdleThread^.AddressSpaceRoot := KernelPageTableRoot;
  Processor^.QuantumHasExpired := False;
  Processor^.IdleThread := IdleThread;
  Processor^.RunningThread := IdleThread;
  StartProcessorTime(Processor, ClockNanoseconds);
  ArchSetThreadInterruptStack(IdleThread^.StackTop);
  MarkProcessorOnline(Processor);
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
  Thread^.QuantumRemaining := QuantumTicks;
  Thread^.AffinityMask := AllProcessors;
  Thread^.LastProcessorIndex := CurrentProcessorIndexOrZero;
  Thread^.QueuedProcessorIndex := 0;
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
  NextThread: PThreadControlBlock;
begin
  PreviousLevel := AcquireDispatcherLock;
  if (CurrentProcessor^.RunningThread <> CurrentProcessor^.IdleThread) and
     (BestReadyPriorityFor(CurrentProcessor) >= Integer(CurrentProcessor^.RunningThread^.Priority)) then
  begin
    NextThread := TakeNextThreadLocked;
    RequeueRunningThreadLocked(CurrentProcessor^.RunningThread);
    SwitchToThreadLocked(NextThread);
  end;
  ReleaseDispatcherLock(PreviousLevel);
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
  Result := SwitchCount;
end;

end.
