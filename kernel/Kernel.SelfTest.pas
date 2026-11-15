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
  Kernel self tests, run once during startup.

  They exercise the memory manager, the scheduler and the synchronization
  primitives under real conditions (threads, preemption, interrupts), so a
  regression shows up on every boot. A failing test stops the system with
  a panic that names it.
}
unit Kernel.SelfTest;

{$mode objfpc}

interface

procedure RunKernelSelfTests;

{ For other self tests: report a passed test, or stop the system with a
  panic naming the failed check. }
procedure ReportPassed(TestName: PChar);
procedure Check(Condition: Boolean; Description: PChar);

implementation

uses
  Runtime.Atomic,
  Memory.Layout,
  Memory.PhysicalPages,
  Memory.KernelHeap,
  Kernel.Threads,
  Kernel.Scheduler,
  Kernel.Events,
  Kernel.Mutex,
  Kernel.Clock,
  Kernel.DeferredCalls,
  Kernel.Timers,
  Kernel.Processors,
  Objects.Manager,
  Kernel.Panic,
  Processes.Thread,
  Kernel.Arch.UserCopy,
  Debug.Output,
  Debug.FramebufferConsole;

procedure ReportPassed(TestName: PChar);
begin
  DebugBeginMessage;
  DebugWriteTag('selftest');
  DebugWrite(TestName);
  DebugWrite(': ');
  DebugSetColor(ColorGreen);
  DebugWrite('passed');
  DebugResetColor;
  DebugWriteLine('');
  DebugEndMessage;
end;

procedure Check(Condition: Boolean; Description: PChar);
begin
  if not Condition then
  begin
    BeginKernelPanic(PanicAssertionFailed, 'kernel self test failed');
    DebugWrite('  ');
    DebugWriteLine(Description);
    FinishKernelPanic;
  end;
end;

{ --- Heap ------------------------------------------------------------ }

{ Allocates blocks of many sizes, fills each with its own pattern, checks
  that no block overwrote another, then frees them all. }
procedure ExerciseHeapOnce;
const
  BlockCount = 64;
var
  Blocks: array[0..BlockCount - 1] of PByte;
  Index: Integer;
  ByteIndex: QWord;
  BlockSize: QWord;
  LargeBlock: PQWord;
  LargeBlockWords: Integer;
begin
  for Index := 0 to BlockCount - 1 do
  begin
    BlockSize := QWord(Index) * 29 + 1;
    Blocks[Index] := PByte(AllocateKernelMemory(BlockSize));
    Check(Blocks[Index] <> nil, 'small heap allocation failed');
    Check((QWord(Blocks[Index]) and 15) = 0, 'heap block is not 16-byte aligned');
    for ByteIndex := 1 to BlockSize do
      Blocks[Index][ByteIndex - 1] := Byte(Index);
  end;

  for Index := 0 to BlockCount - 1 do
  begin
    BlockSize := QWord(Index) * 29 + 1;
    for ByteIndex := 1 to BlockSize do
      Check(Blocks[Index][ByteIndex - 1] = Byte(Index), 'heap block contents were overwritten');
    FreeKernelMemory(Blocks[Index]);
  end;

  { A large block spanning several mapped pages. }
  LargeBlockWords := Integer((5 * PageSize) div SizeOf(QWord));
  LargeBlock := PQWord(AllocateKernelMemory(5 * PageSize));
  Check(LargeBlock <> nil, 'large heap allocation failed');
  for Index := 0 to LargeBlockWords - 1 do
    LargeBlock[Index] := QWord(Index);
  for Index := 0 to LargeBlockWords - 1 do
    Check(LargeBlock[Index] = QWord(Index), 'large heap block contents were overwritten');
  FreeKernelMemory(LargeBlock);
end;

procedure TestKernelHeap;
var
  Statistics: TPhysicalMemoryStatistics;
  FreePagesAfterFirstRound: QWord;
begin
  { The first round may grow the size classes; those pages are kept for
    reuse. A second identical round must then not need any more memory. }
  ExerciseHeapOnce;
  GetPhysicalMemoryStatistics(Statistics);
  FreePagesAfterFirstRound := Statistics.FreePages;

  ExerciseHeapOnce;
  GetPhysicalMemoryStatistics(Statistics);
  Check(Statistics.FreePages = FreePagesAfterFirstRound, 'kernel heap leaked physical pages');

  ReportPassed('kernel heap');
end;

{ --- Events ---------------------------------------------------------- }

const
  PingPongRounds = 50;

var
  PingEvent: TEvent;
  PongEvent: TEvent;
  PongThreadFinished: TEvent;
  PongCount: Int64;

procedure PongThreadMain(Context: Pointer);
var
  Round: Integer;
begin
  for Round := 1 to PingPongRounds do
  begin
    WaitForEvent(PingEvent);
    AtomicIncrement(PongCount);
    SignalEvent(PongEvent);
  end;
  SignalEvent(PongThreadFinished);
end;

procedure TestEventPingPong;
var
  Round: Integer;
  Thread: PThread;
begin
  InitializeEvent(PingEvent, EventKindSynchronization, False);
  InitializeEvent(PongEvent, EventKindSynchronization, False);
  InitializeEvent(PongThreadFinished, EventKindNotification, False);
  PongCount := 0;

  Thread := CreateSystemThread(@PongThreadMain, nil, DefaultThreadPriority, 'Pong', False);
  Check(Thread <> nil, 'could not create the pong thread');

  for Round := 1 to PingPongRounds do
  begin
    SignalEvent(PingEvent);
    WaitForEvent(PongEvent);
    Check(PongCount = Round, 'ping-pong rounds got out of step');
  end;

  WaitForEvent(PongThreadFinished);
  ReportPassed('event ping-pong between threads');
end;

{ --- Sleeping -------------------------------------------------------- }

procedure TestSleep;
const
  SleepDuration = 200;
var
  StartTicks: QWord;
  ElapsedMilliseconds: QWord;
begin
  StartTicks := ClockTickCount;
  SleepMilliseconds(SleepDuration);
  ElapsedMilliseconds := (ClockTickCount - StartTicks) * MillisecondsPerTick;

  Check(ElapsedMilliseconds >= SleepDuration, 'sleep returned early');
  Check(ElapsedMilliseconds <= SleepDuration + 50, 'sleep took far too long');
  ReportPassed('timed sleep');
end;

{ --- Preemption ------------------------------------------------------ }

const
  SpinnerCount = 3;

var
  SpinnerProgress: array[0..SpinnerCount - 1] of Int64;
  StopSpinners: PtrUInt;
  SpinnersFinished: Int64;
  AllSpinnersFinished: TEvent;

{ Spins without ever blocking or yielding, so other threads of the same
  priority only get to run if the clock preempts it. }
procedure SpinnerThreadMain(Context: Pointer);
var
  SpinnerIndex: PtrUInt;
begin
  SpinnerIndex := PtrUInt(Context);
  while AtomicLoad(StopSpinners) = 0 do
    AtomicIncrement(SpinnerProgress[SpinnerIndex]);

  if AtomicIncrement(SpinnersFinished) = SpinnerCount then
    SignalEvent(AllSpinnersFinished);
end;

procedure TestPreemption;
var
  Index: Integer;
  Thread: PThread;
begin
  InitializeEvent(AllSpinnersFinished, EventKindNotification, False);
  StopSpinners := 0;
  SpinnersFinished := 0;
  for Index := 0 to SpinnerCount - 1 do
    SpinnerProgress[Index] := 0;

  for Index := 0 to SpinnerCount - 1 do
  begin
    Thread := CreateSystemThread(@SpinnerThreadMain, Pointer(PtrUInt(Index)),
      DefaultThreadPriority, 'Spinner', False);
    Check(Thread <> nil, 'could not create a spinner thread');
  end;

  { This thread runs at a higher priority, so it gets the processor back
    as soon as the sleep ends, even though the spinners never block. }
  SleepMilliseconds(300);
  AtomicStore(StopSpinners, 1);
  WaitForEvent(AllSpinnersFinished);

  for Index := 0 to SpinnerCount - 1 do
    Check(SpinnerProgress[Index] > 0, 'a spinner thread never ran (no preemption)');

  ReportPassed('preemptive time slicing');
end;

{ --- Mutexes ---------------------------------------------------------- }

const
  MutexWorkerCount = 3;
  MutexIterations = 200;

var
  TestMutex: TMutex;
  ProtectedCounter: Int64;
  MutexWorkersFinished: Int64;
  AllMutexWorkersFinished: TEvent;

{ Reads the counter, yields the processor, then writes it back. Without
  mutual exclusion other workers would run in between and updates would
  be lost. }
procedure MutexWorkerMain(Context: Pointer);
var
  Iteration: Integer;
  ValueRead: Int64;
begin
  for Iteration := 1 to MutexIterations do
  begin
    AcquireMutex(TestMutex);
    AcquireMutex(TestMutex); { recursive acquisition by the owner }
    ValueRead := ProtectedCounter;
    YieldExecution;
    ProtectedCounter := ValueRead + 1;
    ReleaseMutex(TestMutex);
    ReleaseMutex(TestMutex);
  end;

  if AtomicIncrement(MutexWorkersFinished) = MutexWorkerCount then
    SignalEvent(AllMutexWorkersFinished);
end;

procedure TestMutualExclusion;
var
  Index: Integer;
  Thread: PThread;
begin
  InitializeMutex(TestMutex);
  InitializeEvent(AllMutexWorkersFinished, EventKindNotification, False);
  ProtectedCounter := 0;
  MutexWorkersFinished := 0;

  for Index := 1 to MutexWorkerCount do
  begin
    Thread := CreateSystemThread(@MutexWorkerMain, nil, DefaultThreadPriority, 'MutexWorker', False);
    Check(Thread <> nil, 'could not create a mutex worker thread');
  end;

  WaitForEvent(AllMutexWorkersFinished);
  Check(ProtectedCounter = MutexWorkerCount * MutexIterations, 'mutex did not provide mutual exclusion');
  Check(TestMutex.Owner = nil, 'mutex still has an owner after all releases');
  ReportPassed('mutex mutual exclusion');
end;

{ --- Thread exit ----------------------------------------------------- }

procedure ShortLivedThreadMain(Context: Pointer);
begin
  { Returning from the start routine terminates the thread. }
end;

procedure TestThreadExitAndCleanup;
const
  ThreadCount = 20;
var
  Statistics: TPhysicalMemoryStatistics;
  FreePagesBefore: QWord;
  Index: Integer;
  Thread: PThread;
begin
  { Let threads from earlier tests finish and be cleaned up first. }
  SleepMilliseconds(50);
  GetPhysicalMemoryStatistics(Statistics);
  FreePagesBefore := Statistics.FreePages;

  for Index := 1 to ThreadCount do
  begin
    Thread := CreateSystemThread(@ShortLivedThreadMain, nil, DefaultThreadPriority,
      'ShortLived', False);
    Check(Thread <> nil, 'could not create a short lived thread');
  end;

  { The idle thread cleans up exited threads; give it a chance to run. }
  SleepMilliseconds(100);

  GetPhysicalMemoryStatistics(Statistics);
  Check(Statistics.FreePages + 8 >= FreePagesBefore,
    'exited threads did not release their stacks');
  ReportPassed('thread exit and cleanup');
end;

{ --- Copies to user memory that is not there --------------------------- }

{ A kernel thread has no user mappings at all, so copying to or from a
  user address faults; the copy must fail instead of stopping the
  system. }
procedure TestUserCopyFault;
const
  UnmappedUserAddress = QWord($10000);
var
  Buffer: array[0..63] of Char;
begin
  Buffer[0] := 'x';
  Check(ArchCopyUserMemory(Pointer(UnmappedUserAddress), @Buffer[0], SizeOf(Buffer)) = UserCopyFaulted,
    'a copy to unmapped user memory did not fail');
  Check(ArchCopyUserMemory(@Buffer[0], Pointer(UnmappedUserAddress), SizeOf(Buffer)) = UserCopyFaulted,
    'a copy from unmapped user memory did not fail');
  Check(ArchCopyUserString(@Buffer[0], PChar(UnmappedUserAddress), SizeOf(Buffer)) = UserCopyFaulted,
    'a string copy from unmapped user memory did not fail');
  Check(not CurrentThread^.UserCopyActive, 'the copy mark was left set');
  ReportPassed('copies to missing user memory fail safely');
end;

{ --- Timers ------------------------------------------------------------ }

var
  TimerFiredTick: QWord;
  TimerFiredCount: Int64;

procedure NoteTimerFired(Context: Pointer);
begin
  TimerFiredTick := ClockTickCount;
  AtomicIncrement(TimerFiredCount);
end;

{ A timer runs its call once, not before its time; a cancelled timer
  does not run it. }
procedure TestTimers;
const
  DelayMilliseconds = 50;
var
  Timer: TTimer;
  CancelledTimer: TTimer;
  Call: TDeferredCall;
  SetTick: QWord;
begin
  TimerFiredCount := 0;
  InitializeTimer(Timer);
  InitializeTimer(CancelledTimer);
  InitializeDeferredCall(Call, @NoteTimerFired, nil);
  SetTick := ClockTickCount;
  SetTimer(CancelledTimer, DelayMilliseconds div 2, Call);
  SetTimer(Timer, DelayMilliseconds, Call);
  Check(CancelTimer(CancelledTimer), 'a set timer could not be cancelled');
  Check(not CancelTimer(CancelledTimer), 'a cancelled timer was still set');
  SleepMilliseconds(DelayMilliseconds * 4);
  Check(TimerFiredCount = 1, 'a timer did not run its call exactly once');
  Check(TimerFiredTick - SetTick >= MillisecondsToTicks(DelayMilliseconds),
    'a timer ran its call early');
  Check(not CancelTimer(Timer), 'an expired timer was still set');
  { The call lives on this stack: no processor may still be in it. }
  CancelDeferredCall(Call);
  ReportPassed('timers');
end;

{ --- Processor affinity ------------------------------------------------ }

var
  PinnedWanted: Int64;
  PinnedMisplaced: Int64;
  PinnedChecks: Int64;
  PinnedStop: Int64;
  PinnedFinished: TEvent;

{ Keeps checking that it runs where it is pinned (PinnedWanted, -1 while
  the pin changes), giving the scheduler chances to move it. }
procedure PinnedThreadMain(Context: Pointer);
var
  Wanted: Int64;
begin
  while PinnedStop = 0 do
  begin
    Wanted := PinnedWanted;
    if Wanted >= 0 then
    begin
      if Int64(CurrentProcessorIndex) <> Wanted then
        AtomicIncrement(PinnedMisplaced);
      AtomicIncrement(PinnedChecks);
    end;
    if (PinnedChecks and 63) = 0 then
      YieldExecution;
  end;
  SignalEvent(PinnedFinished);
end;

{ Pins a busy thread to the last processor, then moves it to the first
  while it runs; it must never be seen anywhere else. }
procedure TestAffinity;
const
  CheckMilliseconds = 100;
var
  Thread: PThread;
  Last: LongWord;
begin
  if OnlineProcessorCount < 2 then
  begin
    ReportPassed('processor affinity (one processor: nothing to check)');
    Exit;
  end;
  Last := ProcessorTotal - 1;
  PinnedWanted := -1;
  PinnedMisplaced := 0;
  PinnedChecks := 0;
  PinnedStop := 0;
  InitializeEvent(PinnedFinished, EventKindNotification, False);
  Thread := CreateSystemThread(@PinnedThreadMain, nil, DefaultThreadPriority, 'Pinned', True);
  Check(Thread <> nil, 'could not create the pinned thread');

  SetThreadAffinity(@Thread^.ControlBlock, QWord(1) shl Last);
  { The move happens at its processor's next dispatch. }
  SleepMilliseconds(20);
  PinnedWanted := Last;
  SleepMilliseconds(CheckMilliseconds);

  PinnedWanted := -1;
  SetThreadAffinity(@Thread^.ControlBlock, 1);
  SleepMilliseconds(20);
  PinnedWanted := 0;
  SleepMilliseconds(CheckMilliseconds);

  PinnedStop := 1;
  WaitForEvent(PinnedFinished);
  DereferenceObject(Thread);
  Check(PinnedChecks > 0, 'the pinned thread never ran');
  Check(PinnedMisplaced = 0, 'a pinned thread ran on another processor');
  ReportPassed('processor affinity');
end;

procedure RunKernelSelfTests;
begin
  TestKernelHeap;
  TestEventPingPong;
  TestSleep;
  TestPreemption;
  TestMutualExclusion;
  TestThreadExitAndCleanup;
  TestUserCopyFault;
  TestTimers;
  TestAffinity;
end;

end.
