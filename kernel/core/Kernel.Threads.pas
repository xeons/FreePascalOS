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
  The scheduler's view of a thread.

  A TThreadControlBlock holds exactly what the kernel core needs to run,
  suspend and resume a thread: its saved stack pointer, its stack, its
  scheduling state and the list links used by run queues, wait queues and
  timers. Higher level information (owning process, object name, handles)
  lives in the thread object of the process manager, which embeds one of
  these records.
}
unit Kernel.Threads;

{$mode objfpc}
{$pointermath on}

interface

uses
  Runtime.LinkedList,
  Kernel.Arch.ContextSwitch;

const
  IdlePriority = 0;
  LowestThreadPriority = 1;
  DefaultThreadPriority = 8;
  HighestThreadPriority = 31;
  PriorityCount = 32;

  ThreadNameLength = 32;

  { An affinity mask that allows every processor. }
  AllProcessors = High(QWord);

  { The floating point and SIMD register image (x86-64: FXSAVE's, 512
    bytes; AArch64: V0-V31, FPCR, FPSR), which needs 16-byte alignment;
    the field holds 15 spare bytes to align it in. }
  FpuStateSize = ArchFpuStateSize;

type
  TThreadState = (
    ThreadStateInitialized,
    ThreadStateReady,
    ThreadStateRunning,
    ThreadStateWaiting,
    ThreadStateTerminated
  );

  { How a wait ended. }
  TWaitResult = (
    WaitSignaled,
    WaitTimedOut,
    { An alertable wait was cut short by AlertThread. }
    WaitAlerted
  );

  TThreadStartRoutine = procedure(Context: Pointer);

  PThreadControlBlock = ^TThreadControlBlock;

  { A thread waiting on an event is linked into the event's waiters by a
    wait block, one per event it waits on (Kernel.Events), so it can wait
    on several at once; the blocks live on its stack for the wait. Link
    comes first: a waiter list entry is the block. }
  PWaitBlock = ^TWaitBlock;
  TWaitBlock = record
    Link: TListEntry;
    Thread: PThreadControlBlock;
    { Which of the thread's events this is, and the event (a PEvent). }
    Index: LongInt;
    Event: Pointer;
    IsLinked: Boolean;
  end;

  TThreadControlBlock = record
    { Stack pointer saved by the context switch while not running. }
    SavedStackPointer: QWord;

    StackBase: QWord;
    StackTop: QWord;

    { Physical address of the top level page table the thread runs on:
      the kernel's for kernel threads, its process's for user threads. }
    AddressSpaceRoot: QWord;

    { The user thread pointer (the FS base on x86-64), loaded whenever
      the thread is switched to. Zero for kernel threads. }
    UserThreadPointer: QWord;

    State: TThreadState;
    Priority: LongWord;
    QuantumRemaining: LongInt;

    { The processors the thread may run on, one bit per processor index;
      AllProcessors for any (Kernel.ReadyQueues). }
    AffinityMask: QWord;
    { Where it last ran (it prefers to go back there, its data may still
      be in that cache), and whose run queue it is in while ready. }
    LastProcessorIndex: LongWord;
    QueuedProcessorIndex: LongWord;

    { Links the thread into a run queue, a wait queue, or the list of
      terminated threads. A thread is on at most one of these at a time. }
    SchedulerLink: TListEntry;

    { Links the thread into the sleep queue of the processor it began a
      timed wait on (SleepProcessorIndex), ordered by WakeUpTime (in
      clock nanoseconds). }
    TimerLink: TListEntry;
    WakeUpTime: QWord;
    SleepProcessorIndex: LongWord;

    { Where a waiting thread is linked, so whatever ends the wait (a
      signal, the timeout or an alert) can take it off both queues. }
    IsOnWaitList: Boolean;
    { The wait blocks of a wait on events, and which one ended it. A wait
      for all of them (WaitsForAll) ends only when every one is signaled
      at the same time. }
    WaitBlocks: PWaitBlock;
    WaitBlockCount: LongInt;
    SatisfiedWaitIndex: LongInt;
    WaitsForAll: Boolean;
    IsOnSleepQueue: Boolean;
    WaitIsAlertable: Boolean;
    WaitResult: TWaitResult;
    { Set by AlertThread: from then on alertable waits end at once. Used
      to get the threads of a process being ended or stopped out of their
      waits; only a stopped thread clears it (ClearCurrentThreadAlert). }
    AlertPending: Boolean;

    { Clock ticks spent running (the hang dump shows them). }
    RunTicks: QWord;
    { Time spent running, in clock nanoseconds: charged at every switch
      away from the thread, so it is exact rather than counted in ticks
      (Kernel.ProcessorTime). }
    RunNanoseconds: QWord;
    { The clock ticks that found the thread in user mode and in the
      kernel: how its run time divides between the two. }
    UserTicks: QWord;
    KernelTicks: QWord;

    { Inside a routine copying to or from user memory, whose faults on
      user addresses are survivable (Kernel.Arch.UserCopy). }
    UserCopyActive: Boolean;

    { The thread's floating point and SSE registers while it does not
      run (see FpuStateArea). }
    FpuState: array[0..FpuStateSize + 15] of Byte;

    StartRoutine: TThreadStartRoutine;
    StartContext: Pointer;

    ThreadId: QWord;
    Name: array[0..ThreadNameLength - 1] of Char;

    { The thread object that embeds this block, if any. }
    Owner: Pointer;
  end;

{ The 16-byte aligned FXSAVE area inside Thread^.FpuState. }
function FpuStateArea(Thread: PThreadControlBlock): Pointer;

function ThreadFromSchedulerLink(Entry: PListEntry): PThreadControlBlock;
function ThreadFromTimerLink(Entry: PListEntry): PThreadControlBlock;

function ThreadStateName(State: TThreadState): PChar;
{ Takes the thread's wait blocks off their events' lists (dispatcher
  lock held). }
procedure UnlinkWaitBlocksLocked(Thread: PThreadControlBlock);

implementation

procedure UnlinkWaitBlocksLocked(Thread: PThreadControlBlock);
var
  Index: LongInt;
  Block: PWaitBlock;
begin
  for Index := 0 to Thread^.WaitBlockCount - 1 do
  begin
    Block := Thread^.WaitBlocks + Index;
    if Block^.IsLinked then
    begin
      RemoveListEntry(@Block^.Link);
      Block^.IsLinked := False;
    end;
  end;
  Thread^.WaitBlockCount := 0;
  Thread^.WaitBlocks := nil;
end;

function FpuStateArea(Thread: PThreadControlBlock): Pointer;
begin
  Result := Pointer((PtrUInt(@Thread^.FpuState[0]) + 15) and not PtrUInt(15));
end;

function ThreadFromSchedulerLink(Entry: PListEntry): PThreadControlBlock;
begin
  Result := PThreadControlBlock(ContainingRecord(Entry,
    FieldOffset(PThreadControlBlock(nil)^.SchedulerLink)));
end;

function ThreadFromTimerLink(Entry: PListEntry): PThreadControlBlock;
begin
  Result := PThreadControlBlock(ContainingRecord(Entry,
    FieldOffset(PThreadControlBlock(nil)^.TimerLink)));
end;

function ThreadStateName(State: TThreadState): PChar;
begin
  case State of
    ThreadStateInitialized: Result := 'initialized';
    ThreadStateReady: Result := 'ready';
    ThreadStateRunning: Result := 'running';
    ThreadStateWaiting: Result := 'waiting';
    ThreadStateTerminated: Result := 'terminated';
  else
    Result := 'unknown';
  end;
end;

end.
