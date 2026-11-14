{
  Thread scheduler.

  Scheduling is preemptive and priority based. There is one run queue per
  priority level; the highest priority ready thread always runs, and
  threads of equal priority take turns, each running for a time slice
  (quantum) of a few clock ticks. When nothing is ready, the idle thread
  runs; it is never placed on a run queue.

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

{ Prepares a thread control block to start running StartRoutine(Context)
  on the given stack. The thread does not run until StartThread. }
procedure InitializeThreadControlBlock(Thread: PThreadControlBlock;
  StackBase, StackTop: QWord; StartRoutine: TThreadStartRoutine;
  StartContext: Pointer; Priority: LongWord; Name: PChar);

procedure StartThread(Thread: PThreadControlBlock);

function CurrentThread: PThreadControlBlock;

{ Gives up the rest of the time slice to other threads of equal priority. }
procedure YieldExecution;

procedure SleepMilliseconds(Milliseconds: QWord);

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
  Kernel.SpinLock,
  Kernel.Interrupts,
  Kernel.Clock,
  Kernel.Panic;

var
  DispatcherLock: TSpinLock;
  RunQueues: array[0..PriorityCount - 1] of TListEntry;
  { Bit N is set when RunQueues[N] is not empty. }
  ReadyPriorityMask: LongWord;
  SleepQueue: TListEntry;
  TerminatedThreads: TListEntry;

  RunningThread: PThreadControlBlock;
  IdleThreadBlock: PThreadControlBlock;

  { Set by the clock interrupt; read and cleared under the dispatcher
    lock by the dispatch interrupt. }
  QuantumHasExpired: Boolean;

  { Tick at which the first sleeping thread wakes, or High(QWord). }
  NextWakeUpTick: QWord;

  SwitchCount: QWord;

{ --- Run queues ------------------------------------------------------ }

procedure EnqueueReadyThread(Thread: PThreadControlBlock);
begin
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
  if RunningThread = IdleThreadBlock then
    Exit(True);
  if BestReady > Integer(RunningThread^.Priority) then
    Exit(True);
  Result := QuantumHasExpired and (BestReady = Integer(RunningThread^.Priority));
end;

procedure SwitchToThreadLocked(NextThread: PThreadControlBlock);
var
  PreviousThread: PThreadControlBlock;
begin
  PreviousThread := RunningThread;
  NextThread^.State := ThreadStateRunning;
  NextThread^.QuantumRemaining := QuantumTicks;
  RunningThread := NextThread;
  Inc(SwitchCount);

  ArchSetThreadInterruptStack(NextThread^.StackTop);
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
    NextThread := IdleThreadBlock;
  SwitchToThreadLocked(NextThread);
end;

procedure PreemptIfNeededLocked;
var
  NextThread: PThreadControlBlock;
begin
  if not RunningThreadShouldBePreempted then
  begin
    if QuantumHasExpired then
      RunningThread^.QuantumRemaining := QuantumTicks;
    QuantumHasExpired := False;
    Exit;
  end;

  QuantumHasExpired := False;
  NextThread := DequeueHighestReadyThread;
  if RunningThread <> IdleThreadBlock then
    EnqueueReadyThread(RunningThread);
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
    RemoveListEntry(Entry);
    EnqueueReadyThread(Thread);
  end;
  UpdateNextWakeUpTick;
end;

{ --- Interrupt handlers ---------------------------------------------- }

procedure HandleDispatchInterrupt(Frame: PTrapFrame; Context: Pointer);
begin
  AcquireSpinLockAtCurrentLevel(DispatcherLock);
  WakeExpiredSleepersLocked;
  PreemptIfNeededLocked;
  ReleaseSpinLockAtCurrentLevel(DispatcherLock);
end;

procedure SchedulerClockTick(TickCount: QWord);
var
  Thread: PThreadControlBlock;
  DispatchNeeded: Boolean;
begin
  DispatchNeeded := TickCount >= NextWakeUpTick;

  Thread := RunningThread;
  if Thread <> IdleThreadBlock then
  begin
    Dec(Thread^.QuantumRemaining);
    if Thread^.QuantumRemaining <= 0 then
    begin
      QuantumHasExpired := True;
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

  Thread := RunningThread;
  Thread^.StartRoutine(Thread^.StartContext);
  TerminateCurrentThread;
end;

procedure TerminateCurrentThread; noreturn;
var
  Thread: PThreadControlBlock;
begin
  AcquireDispatcherLock;
  Thread := RunningThread;
  if Thread = IdleThreadBlock then
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
  EnqueueReadyThread(Thread);
  if (RunningThread = IdleThreadBlock) or (Thread^.Priority > RunningThread^.Priority) then
    HalRequestSoftwareInterrupt(DispatchLevel);
end;

procedure WaitCurrentThreadLocked;
begin
  if RunningThread = IdleThreadBlock then
    KernelPanic('the idle thread tried to wait');
  RunningThread^.State := ThreadStateWaiting;
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
  QuantumHasExpired := False;
  SwitchCount := 0;

  IdleThread^.State := ThreadStateRunning;
  IdleThread^.Priority := IdlePriority;
  IdleThreadBlock := IdleThread;
  RunningThread := IdleThread;
  ArchSetThreadInterruptStack(IdleThread^.StackTop);

  if not RegisterInterruptHandler(HalDispatchInterruptVector, @HandleDispatchInterrupt, nil) then
    KernelPanic('dispatch interrupt vector is already in use');
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
  Result := RunningThread;
end;

procedure YieldExecution;
var
  PreviousLevel: TPriorityLevel;
  NextThread: PThreadControlBlock;
begin
  PreviousLevel := AcquireDispatcherLock;
  if (RunningThread <> IdleThreadBlock) and
     (HighestReadyPriority >= Integer(RunningThread^.Priority)) then
  begin
    NextThread := DequeueHighestReadyThread;
    EnqueueReadyThread(RunningThread);
    SwitchToThreadLocked(NextThread);
  end;
  ReleaseDispatcherLock(PreviousLevel);
end;

procedure SleepMilliseconds(Milliseconds: QWord);
var
  PreviousLevel: TPriorityLevel;
  Thread: PThreadControlBlock;
begin
  PreviousLevel := AcquireDispatcherLock;
  Thread := RunningThread;
  Thread^.WakeUpTick := ClockTickCount + MillisecondsToTicks(Milliseconds);
  InsertIntoSleepQueue(Thread);
  WaitCurrentThreadLocked;
  ReleaseDispatcherLock(PreviousLevel);
end;

function ContextSwitchCount: QWord;
begin
  Result := SwitchCount;
end;

end.
