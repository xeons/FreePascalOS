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
  Thread objects.

  A thread object embeds the scheduler's thread control block and adds
  what the rest of the system needs: the owning process, the kernel stack
  allocation, and object manager bookkeeping (name, reference count).

  Reference ownership: a running thread holds one reference to its own
  object, which is dropped by ReapTerminatedThreads after the thread has
  exited. CreateSystemThread can return an additional reference to the
  caller, who must eventually dereference it.

  Thread objects are not entered in the object namespace, since thread
  names need not be unique; the name is kept in the control block.
}
unit Processes.Thread;

{$mode objfpc}

interface

uses
  Runtime.LinkedList,
  Memory.KernelStacks,
  Kernel.Threads,
  Kernel.ProcessorTime,
  Kernel.Events,
  Objects.Manager,
  Processes.Process,
  Processes.PosixState;

type
  PThread = ^TThread;
  TThread = record
    ControlBlock: TThreadControlBlock;
    Process: PProcess;
    ProcessLink: TListEntry;
    KernelStack: TKernelStack;
    OwnsKernelStack: Boolean;

    { Threads of user processes (see Processes.UserThread): the user
      memory that belongs to this thread alone, released when it exits. }
    IsUserThread: Boolean;
    UserStackStart: QWord;
    ThreadDataStart: QWord;
    { Its latest CallAllocateMemory with AllocateForThread (its threadvar
      block), released when it exits unless freed before. }
    OwnedAllocationStart: QWord;
    { It made more than one such allocation (dynamic TLS blocks): all of
      them are looked for when it exits. }
    HasSeveralOwnedAllocations: Boolean;
    { Set when the thread has exited; waiting on a thread handle waits
      for ExitEvent and then reads ExitCode. }
    ExitCode: LongInt;
    ExitEvent: TEvent;
    { Kernel threads: what they run (started through RunSystemThread,
      which signals ExitEvent when it returns). }
    SystemStartRoutine: TThreadStartRoutine;
    SystemStartContext: Pointer;

    { Suspending, ending and prioritizing it from another thread
      (Processes.ThreadControl). Guarded by the process's StopLock. }
    SuspendCount: LongInt;
    { Signaled while the thread is not suspended. }
    ResumeEvent: TEvent;
    ExitRequested: Boolean;
    RequestedExitCode: LongInt;
    { Added to the priority its process's nice value gives. }
    PriorityOffset: LongInt;
    { Sent to the exception dispatcher, which has not yet said it took
      over (Processes.UserExceptions). }
    IsDispatchingException: Boolean;
    { The start of the stack region whose reserve a stack overflow opened,
      0 if none (Processes.UserExceptions). }
    OpenedStackReserve: QWord;
    { The kernel ran into the reserve copying a system call's data; the
      stack overflow is raised as the call returns. }
    StackOverflowPending: Boolean;
    PendingOverflowAddress: QWord;
    { The page fault being handled was the first touch of a guard page:
      it is raised as ExceptionGuardPage (Processes.UserExceptions). }
    GuardPageHit: Boolean;
    { The frame of the system call the thread is in (its user registers),
      nil outside system calls. }
    SystemCallFrame: Pointer;
    { Its signal mask and the signals sent to it (Processes.Signals). }
    Posix: TThreadPosixState;
  end;

var
  ThreadObjectType: TObjectType;

procedure InitializeThreadManager;

{ Wraps the code that is currently running (the boot path) in a thread
  object, so the idle thread looks like any other thread. }
function CreateIdleThreadFromBootContext(BootStackBase, BootStackTop: QWord): PThread;

{ Creates and starts a kernel thread in the system process. If
  ReturnReference is True the caller receives a referenced pointer to the
  thread object; otherwise the result must not be used after the thread
  may have exited. StackSize is its kernel stack's size (for work that
  recurses deeply). Returns nil on failure. }
function CreateSystemThread(StartRoutine: TThreadStartRoutine; StartContext: Pointer;
  Priority: LongWord; Name: PChar; ReturnReference: Boolean;
  StackSize: QWord = DefaultKernelStackSize): PThread;

{ Creates and starts a thread in Process, running on the process's
  address space. The thread starts in kernel mode at StartRoutine. }
function CreateThreadInProcess(Process: PProcess; StartRoutine: TThreadStartRoutine;
  StartContext: Pointer; Priority: LongWord; Name: PChar; ReturnReference: Boolean;
  StackSize: QWord = DefaultKernelStackSize): PThread;

{ The thread object and process of the running thread. }
function CurrentThreadObject: PThread;
function CurrentProcess: PProcess;

{ Alerts every thread of Process, ending their alertable waits. }
procedure AlertProcessThreads(Process: PProcess);

{ --- Priority and accounting (used by Processes.Security) --- }

procedure SetProcessThreadPriorities(Process: PProcess; Priority: LongWord);

type
  TThreadVisitor = procedure(Thread: PThread; Context: Pointer);

{ Calls Visit for every thread of Process, under its thread list lock
  (Visit must not block). }
procedure VisitProcessThreads(Process: PProcess; Visit: TThreadVisitor; Context: Pointer);
{ Base moved by Offset, kept within the thread priorities. }
function OffsetPriority(Base: LongWord; Offset: LongInt): LongWord;
procedure SetProcessThreadAffinity(Process: PProcess; Mask: QWord);
{ The processor time of Process: its threads', the ones that ended
  included. }
procedure GetProcessTimes(Process: PProcess; out Times: TThreadTimes);
{ True if a thread of Process is running or ready to run. }
function ProcessIsRunnable(Process: PProcess): Boolean;

{ Releases the resources of threads that have exited. Must be called at
  PassiveLevel by a thread that may wait (the last reference to a
  process deletes it): the thread reaper (Processes.ThreadReaper). }
procedure ReapTerminatedThreads;

function ThreadFromControlBlock(ControlBlock: PThreadControlBlock): PThread;

implementation

uses
  Runtime.Text,
  Kernel.SpinLock,
  Kernel.PriorityLevel,
  Kernel.Scheduler,
  Kernel.Panic;

function ThreadFromProcessLink(Entry: PListEntry): PThread;
begin
  Result := PThread(ContainingRecord(Entry, FieldOffset(PThread(nil)^.ProcessLink)));
end;

function ThreadFromControlBlock(ControlBlock: PThreadControlBlock): PThread;
begin
  Result := PThread(ControlBlock^.Owner);
end;

procedure DeleteThread(ObjectBody: Pointer);
var
  Thread: PThread;
begin
  Thread := PThread(ObjectBody);
  if Thread^.OwnsKernelStack then
    FreeKernelStack(Thread^.KernelStack);
end;

procedure InitializeThreadManager;
begin
  RegisterObjectType(ThreadObjectType, 'Thread', SizeOf(TThread), @DeleteThread);
end;

procedure AttachToProcess(Thread: PThread; Process: PProcess);
var
  PreviousLevel: TPriorityLevel;
begin
  ReferenceObject(Process);
  Thread^.Process := Process;
  PreviousLevel := AcquireSpinLock(Process^.ThreadListLock);
  InsertAtTail(Process^.Threads, @Thread^.ProcessLink);
  Inc(Process^.ThreadCount);
  ReleaseSpinLock(Process^.ThreadListLock, PreviousLevel);
end;

procedure DetachFromProcess(Thread: PThread);
var
  PreviousLevel: TPriorityLevel;
  Process: PProcess;
  Times: TThreadTimes;
begin
  Process := Thread^.Process;
  { It has ended, so its times are final; they stay the process's. }
  GetThreadTimes(@Thread^.ControlBlock, Times);
  PreviousLevel := AcquireSpinLock(Process^.ThreadListLock);
  AddThreadTimes(Process^.EndedThreadTimes, Times);
  RemoveListEntry(@Thread^.ProcessLink);
  Dec(Process^.ThreadCount);
  ReleaseSpinLock(Process^.ThreadListLock, PreviousLevel);
  Thread^.Process := nil;
  DereferenceObject(Process);
end;

function CreateIdleThreadFromBootContext(BootStackBase, BootStackTop: QWord): PThread;
var
  Thread: PThread;
begin
  Thread := PThread(CreateObject(ThreadObjectType, nil));
  if Thread = nil then
    KernelPanicWithCode(PanicInitializationFailed, 'could not create the idle thread', 0, 0, 0, 0);

  Thread^.OwnsKernelStack := False;
  Thread^.KernelStack.Base := BootStackBase;
  Thread^.KernelStack.Top := BootStackTop;

  Thread^.ControlBlock.StackBase := BootStackBase;
  Thread^.ControlBlock.StackTop := BootStackTop;
  Thread^.ControlBlock.ThreadId := 0;
  Thread^.ControlBlock.Owner := Thread;
  CopyText(@Thread^.ControlBlock.Name[0], 'Idle', ThreadNameLength);
  InitializeListHead(Thread^.ControlBlock.SchedulerLink);
  InitializeListHead(Thread^.ControlBlock.TimerLink);

  AttachToProcess(Thread, SystemProcess);
  Result := Thread;
end;

function CreateSystemThread(StartRoutine: TThreadStartRoutine; StartContext: Pointer;
  Priority: LongWord; Name: PChar; ReturnReference: Boolean; StackSize: QWord): PThread;
begin
  Result := CreateThreadInProcess(SystemProcess, StartRoutine, StartContext, Priority, Name,
    ReturnReference, StackSize);
end;

function CurrentThreadObject: PThread;
begin
  Result := ThreadFromControlBlock(CurrentThread);
end;

function CurrentProcess: PProcess;
var
  Thread: PThread;
begin
  Thread := CurrentThreadObject;
  if Thread = nil then
    Result := SystemProcess
  else
    Result := Thread^.Process;
end;

{ A kernel thread's routine, then its exit event (the thread holds a
  reference to itself until it ends). }
procedure RunSystemThread(Context: Pointer);
var
  Thread: PThread;
begin
  Thread := PThread(Context);
  Thread^.SystemStartRoutine(Thread^.SystemStartContext);
  SignalEvent(Thread^.ExitEvent);
end;

function CreateThreadInProcess(Process: PProcess; StartRoutine: TThreadStartRoutine;
  StartContext: Pointer; Priority: LongWord; Name: PChar; ReturnReference: Boolean; StackSize: QWord): PThread;
var
  Thread: PThread;
begin
  Thread := PThread(CreateObject(ThreadObjectType, nil));
  if Thread = nil then
    Exit(nil);
  InitializeEvent(Thread^.ExitEvent, EventKindNotification, False);
  InitializeEvent(Thread^.ResumeEvent, EventKindNotification, True);

  if not AllocateKernelStack(StackSize, Thread^.KernelStack) then
  begin
    DereferenceObject(Thread);
    Exit(nil);
  end;
  Thread^.OwnsKernelStack := True;

  if Process = SystemProcess then
  begin
    { Started through RunSystemThread, so whoever waits hears the end. }
    Thread^.SystemStartRoutine := StartRoutine;
    Thread^.SystemStartContext := StartContext;
    InitializeThreadControlBlock(@Thread^.ControlBlock, Thread^.KernelStack.Base,
      Thread^.KernelStack.Top, @RunSystemThread, Thread, Priority, Name);
  end
  else
    InitializeThreadControlBlock(@Thread^.ControlBlock, Thread^.KernelStack.Base,
      Thread^.KernelStack.Top, StartRoutine, StartContext, Priority, Name);
  Thread^.ControlBlock.ThreadId := AllocateProcessOrThreadId;
  Thread^.ControlBlock.Owner := Thread;
  Thread^.ControlBlock.AddressSpaceRoot := Process^.PageTableRoot;
  { Set before it starts: once started it may run (and end) at once. }
  Thread^.ControlBlock.AffinityMask := Process^.Credentials.AffinityMask;

  AttachToProcess(Thread, Process);

  { The creation reference becomes the thread's reference to itself. }
  if ReturnReference then
    ReferenceObject(Thread);

  StartThread(@Thread^.ControlBlock);
  Result := Thread;
end;

procedure AlertProcessThreads(Process: PProcess);
var
  PreviousLevel: TPriorityLevel;
  Entry: PListEntry;
begin
  PreviousLevel := AcquireSpinLock(Process^.ThreadListLock);
  Entry := Process^.Threads.Next;
  while Entry <> @Process^.Threads do
  begin
    AlertThread(@ThreadFromProcessLink(Entry)^.ControlBlock);
    Entry := Entry^.Next;
  end;
  ReleaseSpinLock(Process^.ThreadListLock, PreviousLevel);
end;

{ --- Priority and accounting ------------------------------------------ }

procedure VisitProcessThreads(Process: PProcess; Visit: TThreadVisitor; Context: Pointer);
var
  PreviousLevel: TPriorityLevel;
  Entry: PListEntry;
begin
  PreviousLevel := AcquireSpinLock(Process^.ThreadListLock);
  Entry := Process^.Threads.Next;
  while Entry <> @Process^.Threads do
  begin
    Visit(ThreadFromProcessLink(Entry), Context);
    Entry := Entry^.Next;
  end;
  ReleaseSpinLock(Process^.ThreadListLock, PreviousLevel);
end;

procedure AddTimesOfThread(Thread: PThread; Context: Pointer);
var
  Times: TThreadTimes;
begin
  GetThreadTimes(@Thread^.ControlBlock, Times);
  AddThreadTimes(PThreadTimes(Context)^, Times);
end;

procedure GetProcessTimes(Process: PProcess; out Times: TThreadTimes);
var
  PreviousLevel: TPriorityLevel;
  Entry: PListEntry;
begin
  { One lock over the ended threads' times and the list, so a thread
    ending meanwhile is counted exactly once. }
  PreviousLevel := AcquireSpinLock(Process^.ThreadListLock);
  Times := Process^.EndedThreadTimes;
  Entry := Process^.Threads.Next;
  while Entry <> @Process^.Threads do
  begin
    AddTimesOfThread(ThreadFromProcessLink(Entry), @Times);
    Entry := Entry^.Next;
  end;
  ReleaseSpinLock(Process^.ThreadListLock, PreviousLevel);
end;

procedure NoteRunnable(Thread: PThread; Context: Pointer);
begin
  if Thread^.ControlBlock.State in [ThreadStateReady, ThreadStateRunning] then
    PBoolean(Context)^ := True;
end;

function ProcessIsRunnable(Process: PProcess): Boolean;
begin
  Result := False;
  VisitProcessThreads(Process, @NoteRunnable, @Result);
end;

{ Thread priorities cannot change under the thread list lock (the
  scheduler's lock is taken inside), so the threads are collected first. }
type
  TThreadChange = (ChangePriority, ChangeAffinity);

{ Changes the priority or affinity of every thread of Process. }
procedure ChangeProcessThreads(Process: PProcess; Change: TThreadChange; Value: QWord);
const
  MaximumThreads = 64;
var
  PreviousLevel: TPriorityLevel;
  Entry: PListEntry;
  Threads: array[0..MaximumThreads - 1] of PThread;
  Count: Integer;
  Index: Integer;
begin
  Count := 0;
  PreviousLevel := AcquireSpinLock(Process^.ThreadListLock);
  Entry := Process^.Threads.Next;
  while (Entry <> @Process^.Threads) and (Count < MaximumThreads) do
  begin
    Threads[Count] := ThreadFromProcessLink(Entry);
    ReferenceObject(Threads[Count]);
    Inc(Count);
    Entry := Entry^.Next;
  end;
  ReleaseSpinLock(Process^.ThreadListLock, PreviousLevel);
  for Index := 0 to Count - 1 do
  begin
    if Change = ChangePriority then
      SetThreadPriority(@Threads[Index]^.ControlBlock,
        OffsetPriority(LongWord(Value), Threads[Index]^.PriorityOffset))
    else
      SetThreadAffinity(@Threads[Index]^.ControlBlock, Value);
    DereferenceObject(Threads[Index]);
  end;
end;

function OffsetPriority(Base: LongWord; Offset: LongInt): LongWord;
var
  Priority: LongInt;
begin
  Priority := LongInt(Base) + Offset;
  if Priority < LowestThreadPriority then
    Priority := LowestThreadPriority;
  if Priority > HighestThreadPriority then
    Priority := HighestThreadPriority;
  Result := LongWord(Priority);
end;

procedure SetProcessThreadPriorities(Process: PProcess; Priority: LongWord);
begin
  ChangeProcessThreads(Process, ChangePriority, Priority);
end;

procedure SetProcessThreadAffinity(Process: PProcess; Mask: QWord);
begin
  ChangeProcessThreads(Process, ChangeAffinity, Mask);
end;

procedure ReapTerminatedThreads;
var
  ControlBlock: PThreadControlBlock;
  Thread: PThread;
begin
  repeat
    ControlBlock := TakeTerminatedThread;
    if ControlBlock = nil then
      Break;
    Thread := ThreadFromControlBlock(ControlBlock);
    DetachFromProcess(Thread);
    DereferenceObject(Thread);
  until False;
end;

end.
