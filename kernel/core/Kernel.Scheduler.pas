{
  Thread scheduler.

  Scheduling is preemptive and priority based. There is one run queue per
  priority level, shared by all processors; the highest priority ready
  threads run, and threads of equal priority take turns, each running for
  a time slice (quantum) of a few clock ticks. When nothing is ready for
  a processor, its idle thread runs; idle threads are never placed on a
  run queue. When a thread becomes ready, a processor that is idle (or
  runs something less important) is asked to reschedule.

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
  Kernel.Threads;

const
  QuantumTicks = 2;

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

{ Called by the clock interrupt handler at ClockLevel. }
procedure SchedulerClockTick(TickCount: QWord);

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
  Kernel.Processors,
  Kernel.InterProcessor,
  Kernel.Arch.ProcessorBlock,
  Kernel.Panic;

var
  DispatcherLock: TSpinLock;
  RunQueues: array[0..PriorityCount - 1] of TListEntry;
  { Bit N is set when RunQueues[N] is not empty. }
  ReadyPriorityMask: LongWord;
  SleepQueue: TListEntry;
  TerminatedThreads: TListEntry;

  { Tick at which the first sleeping thread wakes, or High(QWord). }
  NextWakeUpTick: QWord;

  SwitchCount: QWord;

  { Threads in the run queues. }
  ReadyThreadCount: LongWord;
  { Exponentially decayed run queue lengths, fixed point with
    LoadFractionBits bits after the point. }
  LoadAverage: array[0..2] of QWord;
  NextLoadSampleTick: QWord;

const
  LoadFractionBits = 11;
  LoadOne = QWord(1) shl LoadFractionBits;
  LoadSampleMilliseconds = 5000;
  { exp(-5/60), exp(-5/300), exp(-5/900) in the same fixed point. }
  LoadDecay: array[0..2] of QWord = (1884, 2014, 2037);

{ --- Run queues ------------------------------------------------------ }

procedure EnqueueReadyThread(Thread: PThreadControlBlock);
begin
  Inc(ReadyThreadCount);
  Thread^.State := ThreadStateReady;
  InsertAtTail(RunQueues[Thread^.Priority], @Thread^.SchedulerLink);
  ReadyPriorityMask := ReadyPriorityMask or (LongWord(1) shl Thread^.Priority);
end;

function HighestReadyPriority: Integer;
var
  Priority: Integer;
begin
  for Priority := HighestThreadPriority downto LowestThreadPriority do
  begin
    if (ReadyPriorityMask and (LongWord(1) shl Priority)) <> 0 then
      Exit(Priority);
  end;
  Result := -1;
end;

function DequeueHighestReadyThread: PThreadControlBlock;
var
  Priority: Integer;
  Entry: PListEntry;
begin
  Priority := HighestReadyPriority;
  if Priority < 0 then
    Exit(nil);

  Entry := RemoveHeadEntry(RunQueues[Priority]);
  Dec(ReadyThreadCount);
  if ListIsEmpty(RunQueues[Priority]) then
    ReadyPriorityMask := ReadyPriorityMask and not (LongWord(1) shl Priority);
  Result := ThreadFromSchedulerLink(Entry);
end;

{ --- Switching ------------------------------------------------------- }

{ Decides whether the running thread should give way to a ready one. }
function RunningThreadShouldBePreempted: Boolean;
var
  BestReady: Integer;
begin
  BestReady := HighestReadyPriority;
  if BestReady < 0 then
    Exit(False);
  if CurrentProcessor^.RunningThread = CurrentProcessor^.IdleThread then
    Exit(True);
  if BestReady > Integer(CurrentProcessor^.RunningThread^.Priority) then
    Exit(True);
  Result := CurrentProcessor^.QuantumHasExpired and (BestReady = Integer(CurrentProcessor^.RunningThread^.Priority));
end;

procedure SwitchToThreadLocked(NextThread: PThreadControlBlock);
var
  Processor: PProcessor;
  PreviousThread: PThreadControlBlock;
begin
  Processor := CurrentProcessor;
  PreviousThread := Processor^.RunningThread;
  NextThread^.State := ThreadStateRunning;
  NextThread^.QuantumRemaining := QuantumTicks;
  Processor^.RunningThread := NextThread;
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
var
  NextThread: PThreadControlBlock;
begin
  NextThread := DequeueHighestReadyThread;
  if NextThread = nil then
    NextThread := CurrentProcessor^.IdleThread;
  SwitchToThreadLocked(NextThread);
end;

{ Asks another processor to reschedule because Thread became ready: an
  idle one if there is one, else the one running the least important
  thread, if that is less important than Thread. Returns False if no
  other processor should take it. }
function OfferThreadToOtherProcessorLocked(Thread: PThreadControlBlock): Boolean;
var
  Self: PProcessor;
  Other: PProcessor;
  Target: PProcessor;
  Index: LongWord;
begin
  Result := False;
  if OnlineProcessorCount <= 1 then
    Exit;
  Self := CurrentProcessor;
  Target := nil;
  for Index := 0 to ProcessorTotal - 1 do
  begin
    Other := ProcessorByIndex(Index);
    if (Other = Self) or not Other^.IsOnline then
      Continue;
    if Other^.RunningThread = Other^.IdleThread then
    begin
      Target := Other;
      Break;
    end;
    if (Other^.RunningThread^.Priority < Thread^.Priority) and
       ((Target = nil) or (Other^.RunningThread^.Priority < Target^.RunningThread^.Priority)) then
      Target := Other;
  end;
  if Target <> nil then
  begin
    RequestDispatchOnProcessor(Target);
    Result := True;
  end;
end;

procedure PreemptIfNeededLocked;
var
  NextThread: PThreadControlBlock;
begin
  if not RunningThreadShouldBePreempted then
  begin
    if CurrentProcessor^.QuantumHasExpired then
      CurrentProcessor^.RunningThread^.QuantumRemaining := QuantumTicks;
    CurrentProcessor^.QuantumHasExpired := False;
    Exit;
  end;

  CurrentProcessor^.QuantumHasExpired := False;
  NextThread := DequeueHighestReadyThread;
  if CurrentProcessor^.RunningThread <> CurrentProcessor^.IdleThread then
  begin
    EnqueueReadyThread(CurrentProcessor^.RunningThread);
    { An idle processor may run the thread that gives way. }
    OfferThreadToOtherProcessorLocked(CurrentProcessor^.RunningThread);
  end;
  SwitchToThreadLocked(NextThread);
end;

{ --- Sleeping -------------------------------------------------------- }

procedure UpdateNextWakeUpTick;
var
  First: PListEntry;
begin
  First := FirstListEntry(SleepQueue);
  if First = nil then
    NextWakeUpTick := High(QWord)
  else
    NextWakeUpTick := ThreadFromTimerLink(First)^.WakeUpTick;
end;

procedure InsertIntoSleepQueue(Thread: PThreadControlBlock);
var
  Entry: PListEntry;
begin
  { Keep the queue ordered by wake-up time; equal times stay in order. }
  Entry := SleepQueue.Next;
  while (Entry <> @SleepQueue) and
        (ThreadFromTimerLink(Entry)^.WakeUpTick <= Thread^.WakeUpTick) do
    Entry := Entry^.Next;
  InsertBefore(Entry, @Thread^.TimerLink);
  Thread^.IsOnSleepQueue := True;
  UpdateNextWakeUpTick;
end;

procedure WakeExpiredSleepersLocked;
var
  Now: QWord;
  Entry: PListEntry;
  Thread: PThreadControlBlock;
begin
  Now := ClockTickCount;
  while not ListIsEmpty(SleepQueue) do
  begin
    Entry := SleepQueue.Next;
    Thread := ThreadFromTimerLink(Entry);
    if Thread^.WakeUpTick > Now then
      Break;
    WakeWaitingThreadLocked(Thread, WaitTimedOut);
  end;
  UpdateNextWakeUpTick;
end;

{ --- Interrupt handlers ---------------------------------------------- }

procedure HandleDispatchInterrupt(Frame: PTrapFrame; Context: Pointer);
begin
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
  Result := ReadyThreadCount;
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

procedure SchedulerClockTick(TickCount: QWord);
var
  Thread: PThreadControlBlock;
  DispatchNeeded: Boolean;
begin
  DispatchNeeded := TickCount >= NextWakeUpTick;

  Thread := CurrentProcessor^.RunningThread;
  Inc(Thread^.RunTicks);
  if (CurrentProcessor^.Index = 0) and (TickCount >= NextLoadSampleTick) then
  begin
    SampleLoad;
    NextLoadSampleTick := TickCount + MillisecondsToTicks(LoadSampleMilliseconds);
  end;
  if Thread <> CurrentProcessor^.IdleThread then
  begin
    Dec(Thread^.QuantumRemaining);
    if Thread^.QuantumRemaining <= 0 then
    begin
      CurrentProcessor^.QuantumHasExpired := True;
      DispatchNeeded := True;
    end;
  end;

  if DispatchNeeded then
    HalRequestSoftwareInterrupt(DispatchLevel);
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
var
  Processor: PProcessor;
begin
  EnqueueReadyThread(Thread);
  Processor := CurrentProcessor;
  if Processor^.RunningThread = Processor^.IdleThread then
    HalRequestSoftwareInterrupt(DispatchLevel)
  else if not OfferThreadToOtherProcessorLocked(Thread) and
     (Thread^.Priority > Processor^.RunningThread^.Priority) then
    HalRequestSoftwareInterrupt(DispatchLevel);
end;

procedure WakeWaitingThreadLocked(Thread: PThreadControlBlock; Result: TWaitResult);
begin
  if Thread^.IsOnWaitList then
  begin
    RemoveListEntry(@Thread^.SchedulerLink);
    Thread^.IsOnWaitList := False;
  end;
  if Thread^.IsOnSleepQueue then
  begin
    RemoveListEntry(@Thread^.TimerLink);
    Thread^.IsOnSleepQueue := False;
    UpdateNextWakeUpTick;
  end;
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
    if TimeoutMilliseconds = 0 then
      Exit(WaitTimedOut);
    Exit(WaitAlerted);
  end;

  Thread^.WaitIsAlertable := Alertable;
  Thread^.WaitResult := WaitSignaled;
  if TimeoutMilliseconds <> InfiniteTimeout then
  begin
    Thread^.WakeUpTick := ClockTickCount + MillisecondsToTicks(TimeoutMilliseconds);
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
    RemoveListEntry(@Thread^.SchedulerLink);
    if ListIsEmpty(RunQueues[Thread^.Priority]) then
      ReadyPriorityMask := ReadyPriorityMask and not (LongWord(1) shl Thread^.Priority);
    Dec(ReadyThreadCount);
    Thread^.Priority := Priority;
    ReadyThreadLocked(Thread);
  end
  else
    Thread^.Priority := Priority;
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
var
  Priority: Integer;
begin
  InitializeSpinLock(DispatcherLock);
  for Priority := 0 to PriorityCount - 1 do
    InitializeListHead(RunQueues[Priority]);
  ReadyPriorityMask := 0;
  InitializeListHead(SleepQueue);
  InitializeListHead(TerminatedThreads);
  NextWakeUpTick := High(QWord);
  CurrentProcessor^.QuantumHasExpired := False;
  SwitchCount := 0;

  IdleThread^.State := ThreadStateRunning;
  IdleThread^.Priority := IdlePriority;
  IdleThread^.AddressSpaceRoot := KernelPageTableRoot;
  CurrentProcessor^.IdleThread := IdleThread;
  CurrentProcessor^.RunningThread := IdleThread;
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
  IdleThread^.State := ThreadStateRunning;
  IdleThread^.Priority := IdlePriority;
  IdleThread^.AddressSpaceRoot := KernelPageTableRoot;
  Processor^.QuantumHasExpired := False;
  Processor^.IdleThread := IdleThread;
  Processor^.RunningThread := IdleThread;
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
  InitializeListHead(Thread^.SchedulerLink);
  InitializeListHead(Thread^.TimerLink);
  Thread^.WakeUpTick := 0;
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
     (HighestReadyPriority >= Integer(CurrentProcessor^.RunningThread^.Priority)) then
  begin
    NextThread := DequeueHighestReadyThread;
    EnqueueReadyThread(CurrentProcessor^.RunningThread);
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
