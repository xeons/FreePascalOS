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
  The thread manager of the FreePascalOS System unit: threads, threadvars,
  critical sections and events, built on kernel threads and the kernel's
  wait-on-address call. It is installed at startup, so threads work in
  every program without a separate threads unit.

  Threadvars: until the first thread starts, threadvars are ordinary
  globals. BeginThread then gives every thread its own zeroed block
  (copying the main thread's values into the main thread's block), kept
  in the runtime word of the thread control block (ThreadBlockRuntimeOffset). A thread that
  touches a threadvar without one gets it then.

  BeginThread returns the thread's handle (what WaitForThreadTerminate
  and CloseThread take) and passes back its id (what GetCurrentThreadId
  returns in that thread). WaitForThreadTerminate returns the thread's
  exit code. SuspendThread and KillThread take effect at the thread's
  next safe point in the kernel (a system call or interrupt returning to
  it); thread priorities are offsets (-15 .. 15) from the process's, and
  only root may raise one.

  Locks are one word: 0 free, 1 held, 2 held with sleepers. Critical
  sections add an owner and a depth, as they must be recursive.
}

const
  LockFree = 0;
  LockHeld = 1;
  LockHeldWithSleepers = 2;
  WaitTimedOut = -ErrorTimedOut;

var
  ThreadVarBlockSize: DWord = 0;

{ --- Waiting on a word -------------------------------------------------- }

{ Sleeps while Word = Expected, at most TimeoutMilliseconds (or
  InfiniteWait). Returns False if the time ran out. }
function WaitWhileEqual(var Word: LongInt; Expected: LongInt; TimeoutMilliseconds: Int64): Boolean;
begin
  WaitWhileEqual := SystemCall(CallWaitOnAddress, QWord(@Word), QWord(Int64(Expected)),
    QWord(TimeoutMilliseconds), 0, 0, 0) <> WaitTimedOut;
end;

procedure WakeWaiters(var Word: LongInt; Count: LongInt);
begin
  SystemCall(CallWakeAddress, QWord(@Word), QWord(Int64(Count)), 0, 0, 0, 0);
end;

procedure AcquireWordLock(var State: LongInt);
var
  Previous: LongInt;
begin
  Previous := InterlockedCompareExchange(State, LockHeld, LockFree);
  if Previous = LockFree then
    Exit;
  if Previous <> LockHeldWithSleepers then
    Previous := InterlockedExchange(State, LockHeldWithSleepers);
  while Previous <> LockFree do
  begin
    WaitWhileEqual(State, LockHeldWithSleepers, InfiniteWait);
    Previous := InterlockedExchange(State, LockHeldWithSleepers);
  end;
end;

procedure ReleaseWordLock(var State: LongInt);
begin
  if InterlockedExchange(State, LockFree) = LockHeldWithSleepers then
    WakeWaiters(State, 1);
end;

{ --- Threadvars ------------------------------------------------------------ }

procedure SysInitThreadVar(var Offset: DWord; Size: DWord);
begin
  { Aligned for anything a threadvar may hold. }
  ThreadVarBlockSize := (ThreadVarBlockSize + 15) and not DWord(15);
  Offset := ThreadVarBlockSize;
  Inc(ThreadVarBlockSize, Size);
end;

procedure SysAllocateThreadVars;
var
  Address: Int64;
begin
  if ReadRuntimeWord <> nil then
    Exit;
  { From the kernel, not the heap: the heap itself uses threadvars. Fresh
    pages are zero, as threadvars start out. The kernel frees the block
    if the thread is ended without coming back here to free it. }
  Address := SystemCall(CallAllocateMemory, ThreadVarBlockSize + 16, AllocateForThread, 0, 0, 0, 0);
  if Address <= 0 then
    RunError(226);
  WriteRuntimeWord(Pointer(Address));
end;

function SysRelocateThreadVar(Offset: DWord): Pointer;
var
  Block: Pointer;
begin
  Block := ReadRuntimeWord;
  if Block = nil then
  begin
    { A thread the RTL did not start, touching a threadvar first. }
    SysAllocateThreadVars;
    Block := ReadRuntimeWord;
    InitThread($1000000);
  end;
  SysRelocateThreadVar := Block + Offset;
end;

procedure SysReleaseThreadVars;
var
  Block: Pointer;
begin
  Block := ReadRuntimeWord;
  if Block = nil then
    Exit;
  WriteRuntimeWord(nil);
  SystemCall(CallFreeMemory, QWord(Block), 0, 0, 0, 0, 0);
end;

{ Switches the threadvars from globals to per-thread blocks, once. }
procedure InitMultithreading;
begin
  if fpc_threadvar_relocate_proc <> nil then
    Exit;
  InitThreadVars(@SysRelocateThreadVar);
  IsMultiThread := True;
end;

{ --- Threads --------------------------------------------------------------- }

type
  PThreadStartInformation = ^TThreadStartInformation;
  TThreadStartInformation = record
    ThreadFunction: TThreadFunc;
    Parameter: Pointer;
    StackSize: PtrUInt;
  end;

procedure SysEndThread(ExitCode: DWord);
begin
  DoneThread;
  while True do
    SystemCall(CallExitThread, QWord(ExitCode), 0, 0, 0, 0, 0);
end;

{ Where the kernel starts every thread BeginThread creates. }
procedure ThreadMain(Start: PThreadStartInformation);
var
  Information: TThreadStartInformation;
begin
  Information := Start^;
  SysAllocateThreadVars;
  InitThread(Information.StackSize);
  Dispose(Start);
  SysEndThread(DWord(Information.ThreadFunction(Information.Parameter)));
end;

function SysBeginThread(SecurityAttributes: Pointer; StackSize: PtrUInt;
  ThreadFunction: TThreadFunc; P: Pointer; CreationFlags: DWord; var ThreadId: TThreadID): TThreadID;
var
  Start: PThreadStartInformation;
  Handle: Int64;
begin
  InitMultithreading;
  New(Start);
  Start^.ThreadFunction := ThreadFunction;
  Start^.Parameter := P;
  Start^.StackSize := StackSize;
  Handle := SystemCall(CallCreateThread, QWord(@ThreadMain), QWord(Start), StackSize, 0, 0, 0);
  if Handle < 0 then
  begin
    Dispose(Start);
    SetLastSystemError(LongInt(-Handle));
    ThreadId := 0;
    SysBeginThread := 0;
    Exit;
  end;
  ThreadId := TThreadID(SystemCall(CallGetThreadId, QWord(Handle), 0, 0, 0, 0, 0));
  SysBeginThread := TThreadID(Handle);
end;

procedure SysThreadSwitch;
begin
  SystemCall(CallSleep, 0, 0, 0, 0, 0, 0);
end;

{ The result of a call returning a count, or DWord(-1) on failure. }
function CountOrFailure(CallResult: Int64): DWord;
begin
  if CallResult < 0 then
  begin
    SetLastSystemError(LongInt(-CallResult));
    CountOrFailure := DWord(-1);
  end
  else
    CountOrFailure := DWord(CallResult);
end;

{ Return the previous suspend count. }
function SysSuspendThread(ThreadHandle: TThreadID): DWord;
begin
  SysSuspendThread := CountOrFailure(SystemCall(CallSuspendThread, QWord(ThreadHandle), 0, 0, 0, 0, 0));
end;

function SysResumeThread(ThreadHandle: TThreadID): DWord;
begin
  SysResumeThread := CountOrFailure(SystemCall(CallResumeThread, QWord(ThreadHandle), 0, 0, 0, 0, 0));
end;

{ Ends the thread (exit code 0); returns 0. }
function SysKillThread(ThreadHandle: TThreadID): DWord;
begin
  SysKillThread := CountOrFailure(SystemCall(CallTerminateThread, QWord(ThreadHandle), 0, 0, 0, 0, 0));
end;

function SysCloseThread(ThreadHandle: TThreadID): DWord;
begin
  SysCloseThread := DWord(SystemCall(CallClose, QWord(ThreadHandle), 0, 0, 0, 0, 0));
end;

{ TimeoutMs 0 (or less) waits as long as it takes. Returns the thread's
  exit code, or DWord(-1) if it did not end in time. }
function SysWaitForThreadTerminate(ThreadHandle: TThreadID; TimeoutMs: LongInt): DWord;
var
  ExitCode: LongInt;
  Timeout: Int64;
begin
  if TimeoutMs <= 0 then
    Timeout := InfiniteWait
  else
    Timeout := TimeoutMs;
  ExitCode := 0;
  if SystemCall(CallWaitForThread, QWord(ThreadHandle), QWord(Timeout), QWord(@ExitCode), 0, 0, 0) < 0 then
    SysWaitForThreadTerminate := DWord(-1)
  else
    SysWaitForThreadTerminate := DWord(ExitCode);
end;

{ Prio is an offset from the process's priority, -15 .. 15 (0 normal). }
function SysThreadSetPriority(ThreadHandle: TThreadID; Prio: LongInt): Boolean;
var
  CallResult: Int64;
begin
  CallResult := SystemCall(CallSetThreadPriority, QWord(ThreadHandle), QWord(Int64(Prio)), 0, 0, 0, 0);
  if CallResult < 0 then
    SetLastSystemError(LongInt(-CallResult));
  SysThreadSetPriority := CallResult = 0;
end;

function SysThreadGetPriority(ThreadHandle: TThreadID): LongInt;
var
  CallResult: Int64;
begin
  CallResult := SystemCall(CallGetThreadPriority, QWord(ThreadHandle), 0, 0, 0, 0, 0);
  if CallResult < 0 then
    SysThreadGetPriority := 0
  else
    SysThreadGetPriority := LongInt(CallResult) - ThreadPriorityOffsetBias;
end;

function SysGetCurrentThreadId: TThreadID;
begin
  SysGetCurrentThreadId := TThreadID(KernelThreadId);
end;

procedure SysSetThreadDebugNameA(ThreadHandle: TThreadID; const ThreadName: AnsiString);
begin
end;

procedure SysSetThreadDebugNameU(ThreadHandle: TThreadID; const ThreadName: UnicodeString);
begin
end;

{ --- Critical sections ------------------------------------------------------ }

procedure SysInitCriticalSection(var CS);
begin
  FillChar(CS, SizeOf(TRTLCriticalSection), 0);
end;

procedure SysDoneCriticalSection(var CS);
begin
end;

procedure SysEnterCriticalSection(var CS);
var
  Me: QWord;
begin
  Me := KernelThreadId;
  with TRTLCriticalSection(CS) do
  begin
    if (State <> LockFree) and (Owner = Me) then
    begin
      Inc(Depth);
      Exit;
    end;
    AcquireWordLock(State);
    Owner := Me;
    Depth := 1;
  end;
end;

function SysTryEnterCriticalSection(var CS): LongInt;
var
  Me: QWord;
begin
  Me := KernelThreadId;
  with TRTLCriticalSection(CS) do
  begin
    if (State <> LockFree) and (Owner = Me) then
    begin
      Inc(Depth);
      Exit(1);
    end;
    if InterlockedCompareExchange(State, LockHeld, LockFree) <> LockFree then
      Exit(0);
    Owner := Me;
    Depth := 1;
  end;
  SysTryEnterCriticalSection := 1;
end;

procedure SysLeaveCriticalSection(var CS);
begin
  with TRTLCriticalSection(CS) do
  begin
    Dec(Depth);
    if Depth > 0 then
      Exit;
    Owner := 0;
    ReleaseWordLock(State);
  end;
end;

{ --- Events ----------------------------------------------------------------- }

type
  { 0 not signaled, 1 signaled. }
  PEventWord = ^TEventWord;
  TEventWord = record
    Signaled: LongInt;
    ManualReset: Boolean;
  end;

{ Waits for Event; an automatic one is reset by the waiter that gets it.
  Returns False if TimeoutMilliseconds (or InfiniteWait) ran out. }
function WaitForEventWord(Event: PEventWord; TimeoutMilliseconds: Int64): Boolean;
begin
  repeat
    if Event^.ManualReset then
    begin
      if Event^.Signaled <> 0 then
        Exit(True);
    end
    else if InterlockedCompareExchange(Event^.Signaled, 0, 1) = 1 then
      Exit(True);
    if not WaitWhileEqual(Event^.Signaled, 0, TimeoutMilliseconds) then
      Exit(Event^.Signaled <> 0);
  until False;
end;

procedure SignalEventWord(Event: PEventWord);
begin
  InterlockedExchange(Event^.Signaled, 1);
  if Event^.ManualReset then
    WakeWaiters(Event^.Signaled, High(LongInt))
  else
    WakeWaiters(Event^.Signaled, 1);
end;

function IntBasicEventCreate(EventAttributes: Pointer; AManualReset, InitialState: Boolean;
  const Name: AnsiString): PEventState;
var
  Event: PEventWord;
begin
  New(Event);
  Event^.Signaled := Ord(InitialState);
  Event^.ManualReset := AManualReset;
  IntBasicEventCreate := PEventState(Event);
end;

procedure IntBasicEventDestroy(State: PEventState);
begin
  Dispose(PEventWord(State));
end;

procedure IntBasicEventResetEvent(State: PEventState);
begin
  InterlockedExchange(PEventWord(State)^.Signaled, 0);
end;

procedure IntBasicEventSetEvent(State: PEventState);
begin
  SignalEventWord(PEventWord(State));
end;

{ Returns wrSignaled (0) or wrTimeout (1). }
function IntBasicEventWaitFor(Timeout: Cardinal; State: PEventState): LongInt;
var
  Milliseconds: Int64;
begin
  if Timeout = $FFFFFFFF then
    Milliseconds := InfiniteWait
  else
    Milliseconds := Timeout;
  if WaitForEventWord(PEventWord(State), Milliseconds) then
    IntBasicEventWaitFor := 0
  else
    IntBasicEventWaitFor := 1;
end;

function IntRTLEventCreate: PRTLEvent;
begin
  IntRTLEventCreate := PRTLEvent(IntBasicEventCreate(nil, False, False, ''));
end;

procedure IntRTLEventDestroy(AEvent: PRTLEvent);
begin
  Dispose(PEventWord(AEvent));
end;

procedure IntRTLEventSetEvent(AEvent: PRTLEvent);
begin
  SignalEventWord(PEventWord(AEvent));
end;

procedure IntRTLEventResetEvent(AEvent: PRTLEvent);
begin
  InterlockedExchange(PEventWord(AEvent)^.Signaled, 0);
end;

procedure IntRTLEventWaitFor(AEvent: PRTLEvent);
begin
  WaitForEventWord(PEventWord(AEvent), InfiniteWait);
end;

procedure IntRTLEventWaitForTimeout(AEvent: PRTLEvent; Timeout: LongInt);
begin
  WaitForEventWord(PEventWord(AEvent), Timeout);
end;

{ --- Installation ----------------------------------------------------------- }

procedure InitSystemThreads;
var
  Manager: TThreadManager;
begin
  with Manager do
  begin
    InitManager := nil;
    DoneManager := nil;
    BeginThread := @SysBeginThread;
    EndThread := @SysEndThread;
    SuspendThread := @SysSuspendThread;
    ResumeThread := @SysResumeThread;
    KillThread := @SysKillThread;
    ThreadSwitch := @SysThreadSwitch;
    CloseThread := @SysCloseThread;
    WaitForThreadTerminate := @SysWaitForThreadTerminate;
    ThreadSetPriority := @SysThreadSetPriority;
    ThreadGetPriority := @SysThreadGetPriority;
    GetCurrentThreadId := @SysGetCurrentThreadId;
    SetThreadDebugNameA := @SysSetThreadDebugNameA;
    SetThreadDebugNameU := @SysSetThreadDebugNameU;
    InitCriticalSection := @SysInitCriticalSection;
    DoneCriticalSection := @SysDoneCriticalSection;
    EnterCriticalSection := @SysEnterCriticalSection;
    TryEnterCriticalSection := @SysTryEnterCriticalSection;
    LeaveCriticalSection := @SysLeaveCriticalSection;
    InitThreadVar := @SysInitThreadVar;
    RelocateThreadVar := @SysRelocateThreadVar;
    AllocateThreadVars := @SysAllocateThreadVars;
    ReleaseThreadVars := @SysReleaseThreadVars;
    BasicEventCreate := @IntBasicEventCreate;
    BasicEventDestroy := @IntBasicEventDestroy;
    BasicEventResetEvent := @IntBasicEventResetEvent;
    BasicEventSetEvent := @IntBasicEventSetEvent;
    BasicEventWaitFor := @IntBasicEventWaitFor;
    RTLEventCreate := @IntRTLEventCreate;
    RTLEventDestroy := @IntRTLEventDestroy;
    RTLEventSetEvent := @IntRTLEventSetEvent;
    RTLEventResetEvent := @IntRTLEventResetEvent;
    RTLEventWaitFor := @IntRTLEventWaitFor;
    RTLEventWaitForTimeout := @IntRTLEventWaitForTimeout;
  end;
  SetThreadManager(Manager);
  ThreadID := SysGetCurrentThreadId;
end;
