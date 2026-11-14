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

interface

uses
  Runtime.LinkedList;

const
  IdlePriority = 0;
  LowestThreadPriority = 1;
  DefaultThreadPriority = 8;
  HighestThreadPriority = 31;
  PriorityCount = 32;

  ThreadNameLength = 32;

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

    { Links the thread into a run queue, a wait queue, or the list of
      terminated threads. A thread is on at most one of these at a time. }
    SchedulerLink: TListEntry;

    { Links the thread into the sleep queue, ordered by WakeUpTick. }
    TimerLink: TListEntry;
    WakeUpTick: QWord;

    { Where a waiting thread is linked, so whatever ends the wait (a
      signal, the timeout or an alert) can take it off both queues. }
    IsOnWaitList: Boolean;
    IsOnSleepQueue: Boolean;
    WaitIsAlertable: Boolean;
    WaitResult: TWaitResult;
    { Set by AlertThread and never cleared: from then on alertable waits
      end at once. Used to stop threads of a process being terminated. }
    AlertPending: Boolean;

    StartRoutine: TThreadStartRoutine;
    StartContext: Pointer;

    ThreadId: QWord;
    Name: array[0..ThreadNameLength - 1] of Char;

    { The thread object that embeds this block, if any. }
    Owner: Pointer;
  end;

function ThreadFromSchedulerLink(Entry: PListEntry): PThreadControlBlock;
function ThreadFromTimerLink(Entry: PListEntry): PThreadControlBlock;

function ThreadStateName(State: TThreadState): PChar;

implementation

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
