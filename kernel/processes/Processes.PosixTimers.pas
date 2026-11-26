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
  POSIX timers (timer_create and friends, CallCreatePosixTimer ..
  CallGetTimerOverrun) and the interval timers (setitimer,
  CallSetIntervalTimer).

  A process has a table of timers: MaximumPosixTimers POSIX ones (their
  ids are their places) and after them the three interval timers, made
  when first set. A timer counts on one of three clocks:

    * the uptime (CLOCK_MONOTONIC, CLOCK_BOOTTIME, CLOCK_REALTIME, whose
      absolute times are wall clock times turned into uptime when the
      timer is set; ITIMER_REAL): a kernel timer (Kernel.Timers) whose
      deferred call does what the timer does and sets the next period;
    * the processor time of the process, all of it or its part in user
      mode (CLOCK_PROCESS_CPUTIME_ID, ITIMER_PROF; ITIMER_VIRTUAL);
    * the processor time of one thread (CLOCK_THREAD_CPUTIME_ID).

  Processor time grows only while a thread runs, so those timers are
  looked at as the process's threads go back to user mode, once per
  clock tick per thread (CheckProcessorTimers, from
  DeliverPendingSignals): a thread that computes is interrupted by every
  tick. While such a timer is armed the threads of the process keep
  their tick even when they run alone (Kernel.Scheduler's dynamic tick
  would defer it for a second), so a timer is late by at most a tick.

  What a timer does when it expires: send its signal (the entry for it
  is part of the timer, Processes.SignalQueue, so it waits at most once
  and later expiries count as its overrun), signal an event handle (the
  C library's SIGEV_THREAD: a thread of its own waits for the event and
  calls the function), or nothing (SIGEV_NONE: timer_gettime only).
  Periods keep to their schedule: the next expiry is counted from the
  last due time, and periods that passed unseen add to the overrun.

  Setting and deleting take one mutex for all processes. A timer's
  deferred call is stopped before its timer changes (as Objects.Timers
  does); the checks of processor-time timers hold a timer only under the
  process's signal lock and count themselves in Users, which deleting
  waits for. A process's timers go when it ends, its POSIX timers when
  it runs another program (the interval timers stay); a forked child has
  none.
}
unit Processes.PosixTimers;

{$mode objfpc}

interface

uses
  Processes.Process,
  Processes.Thread;

procedure InitializePosixTimers;

{ From DeliverPendingSignals, with interrupts enabled: the expired
  processor-time timers of Process (those of Thread's clock among them)
  do what they do. }
procedure CheckProcessorTimers(Process: PProcess; Thread: PThread);
{ The process has ended: every timer goes. }
procedure DeleteProcessTimers(Process: PProcess);
{ exec: the POSIX timers go, the interval timers stay. }
procedure DeletePosixTimersForExec(Process: PProcess);

function PerformCreatePosixTimer(ClockId: Int64; EventAddress: QWord): Int64;
function PerformSetPosixTimer(TimerId: Int64; Flags, NewAddress, OldAddress: QWord): Int64;
function PerformGetPosixTimer(TimerId: Int64; SpecAddress: QWord): Int64;
function PerformDeletePosixTimer(TimerId: Int64): Int64;
function PerformGetTimerOverrun(TimerId: Int64): Int64;
function PerformSetIntervalTimer(Which, NewAddress, OldAddress: QWord): Int64;

implementation

uses
  Runtime.Memory,
  Runtime.Atomic,
  Runtime.LinkedList,
  Abi.SystemCalls,
  Memory.KernelHeap,
  Kernel.PriorityLevel,
  Kernel.SpinLock,
  Kernel.Mutex,
  Kernel.Events,
  Kernel.Timers,
  Kernel.DeferredCalls,
  Kernel.Clock,
  Kernel.WallClock,
  Kernel.Scheduler,
  Objects.Manager,
  Objects.Events,
  Processes.Handles,
  Processes.ObjectCalls,
  Processes.PosixState,
  Processes.Signals,
  Processes.SignalQueue,
  Processes.ProcessorClocks,
  Processes.TimerSchedules,
  Processes.UserAccess;

const
  IntervalTimerSlots = 3;
  TimerSlotCount = MaximumPosixTimers + IntervalTimerSlots;

type
  TTimerClock = (TimerClockUptime, TimerClockProcessTime, TimerClockProcessUserTime, TimerClockThreadTime);

  PPosixTimer = ^TPosixTimer;
  TPosixTimer = record
    Process: PProcess;
    Clock: TTimerClock;
    { CLOCK_REALTIME: absolute times are wall clock times. }
    CountsWallTime: Boolean;
    { TimerClockThreadTime: whose. }
    ThreadId: QWord;
    { TimerNotify*. }
    Notify: LongWord;
    { TimerNotifyEvent: the event object, referenced. }
    EventObject: PEventObject;
    EventPosted: Boolean;
    EventOverrun: QWord;
    { Under the signal lock: armed, due (uptime or processor time in
      nanoseconds) and the period (0: once). }
    Armed: Boolean;
    DueTime: QWord;
    Interval: QWord;
    { Its signal: Information has its signal, value, id and SignalFrom*. }
    Entry: TQueuedSignal;
    { The uptime clock's kernel timer and its call. }
    KernelTimer: TTimer;
    Call: TDeferredCall;
    Stopping: Boolean;
    { An absolute CLOCK_REALTIME setting: on the list of timers that follow
      a step of the wall clock, with the wall clock's offset from the
      uptime when it was last placed. Under the timer mutex. }
    WallLink: TListEntry;
    FollowsWallClock: Boolean;
    WallOffset: Int64;
    { Processor-time checks holding the timer just now. }
    Users: Int64;
  end;

  TPosixTimerTable = array[0..TimerSlotCount - 1] of PPosixTimer;
  PPosixTimerTable = ^TPosixTimerTable;

  { An expiry found under the lock, acted on after it. }
  TExpiry = record
    Timer: PPosixTimer;
    Missed: QWord;
  end;

var
  TimerMutex: TMutex;
  { The timers that follow a step of the wall clock. }
  WallClockTimers: TListEntry;

function Failure(Error: LongInt): Int64;
begin
  Result := -Int64(Error);
end;

function TableOf(Process: PProcess): PPosixTimerTable;
begin
  Result := PPosixTimerTable(Process^.Posix.Timers);
end;

function IsProcessorClock(Clock: TTimerClock): Boolean;
begin
  Result := Clock <> TimerClockUptime;
end;

{ --- Doing what a timer does ---------------------------------------------- }

procedure PostEvent(Timer: PPosixTimer; Missed: QWord);
var
  PreviousLevel: TPriorityLevel;
  MustSignal: Boolean;
begin
  PreviousLevel := AcquireSpinLock(Timer^.Process^.Posix.SignalLock);
  MustSignal := not Timer^.EventPosted;
  if MustSignal then
    Timer^.EventOverrun := AddOverrun(Timer^.EventOverrun, Missed)
  else
    Timer^.EventOverrun := AddOverrun(Timer^.EventOverrun, Missed + 1);
  Timer^.EventPosted := True;
  ReleaseSpinLock(Timer^.Process^.Posix.SignalLock, PreviousLevel);
  if MustSignal then
    SignalEvent(Timer^.EventObject^.Event);
end;

procedure Fire(Timer: PPosixTimer; Missed: QWord; AtThreadReturn: Boolean);
begin
  case Timer^.Notify of
    TimerNotifySignal: PostTimerSignal(Timer^.Process, @Timer^.Entry, Missed, AtThreadReturn);
    TimerNotifyEvent: PostEvent(Timer, Missed);
  end;
end;

{ The deferred call of an uptime timer. }
procedure UptimeTimerDue(Context: Pointer);
var
  Timer: PPosixTimer;
  PreviousLevel: TPriorityLevel;
  Missed: QWord;
  Next: QWord;
begin
  Timer := PPosixTimer(Context);
  if Timer^.Stopping then
    Exit;
  Missed := 0;
  Next := 0;
  PreviousLevel := AcquireSpinLock(Timer^.Process^.Posix.SignalLock);
  if Timer^.Armed then
  begin
    if Timer^.Interval = 0 then
      Timer^.Armed := False
    else
    begin
      Next := NextDueTime(Timer^.DueTime, Timer^.Interval, ClockNanoseconds, Missed);
      Timer^.DueTime := Next;
    end;
  end;
  ReleaseSpinLock(Timer^.Process^.Posix.SignalLock, PreviousLevel);
  if Next <> 0 then
    SetTimerAt(Timer^.KernelTimer, Next, Timer^.Call);
  Fire(Timer, Missed, False);
end;

{ --- Keeping the tick for processor-time timers ---------------------------- }

procedure KeepTickOfThread(Thread: PThread; Context: Pointer);
begin
  SetThreadNeedsClockTick(@Thread^.ControlBlock, Context <> nil);
end;

procedure KeepProcessTick(Process: PProcess; Keep: Boolean);
begin
  if Keep then
    VisitProcessThreads(Process, @KeepTickOfThread, Process)
  else
    VisitProcessThreads(Process, @KeepTickOfThread, nil);
end;

{ Arms or disarms Timer under the signal lock, keeping the count of armed
  processor-time timers; returns how that count changed to or from 0
  (+1 armed the first, -1 disarmed the last). }
function SetArmedLocked(Timer: PPosixTimer; Armed: Boolean): Integer;
var
  Posix: ^TProcessPosixState;
begin
  Result := 0;
  Posix := @Timer^.Process^.Posix;
  if IsProcessorClock(Timer^.Clock) and (Timer^.Armed <> Armed) then
  begin
    if Armed then
    begin
      Inc(Posix^.ArmedProcessorTimers);
      if Posix^.ArmedProcessorTimers = 1 then
        Result := 1;
    end
    else
    begin
      Dec(Posix^.ArmedProcessorTimers);
      if Posix^.ArmedProcessorTimers = 0 then
        Result := -1;
    end;
  end;
  Timer^.Armed := Armed;
end;

procedure ApplyTickChange(Process: PProcess; Change: Integer);
begin
  if Change > 0 then
    KeepProcessTick(Process, True)
  else if Change < 0 then
    KeepProcessTick(Process, False);
end;

{ --- Processor-time timers ------------------------------------------------- }

type
  TProcessorReadings = record
    ProcessRun: QWord;
    ProcessUser: QWord;
    ThreadRun: QWord;
    ThreadId: QWord;
  end;

function ReadingFor(Timer: PPosixTimer; const Readings: TProcessorReadings; out Now: QWord): Boolean;
begin
  Result := True;
  case Timer^.Clock of
    TimerClockProcessTime: Now := Readings.ProcessRun;
    TimerClockProcessUserTime: Now := Readings.ProcessUser;
    TimerClockThreadTime:
      begin
        Now := Readings.ThreadRun;
        Result := Timer^.ThreadId = Readings.ThreadId;
      end;
  else
    Now := 0;
    Result := False;
  end;
end;

procedure CheckProcessorTimers(Process: PProcess; Thread: PThread);
var
  Table: PPosixTimerTable;
  Readings: TProcessorReadings;
  Expiries: array[0..TimerSlotCount - 1] of TExpiry;
  ExpiryCount: LongInt;
  Index: LongInt;
  Timer: PPosixTimer;
  Now: QWord;
  Missed: QWord;
  PreviousLevel: TPriorityLevel;
  TickChange: Integer;
  Tick: QWord;
begin
  Tick := ClockTickCount;
  if Thread^.Posix.ProcessorTimersCheckedTick = Tick then
    Exit;
  Thread^.Posix.ProcessorTimersCheckedTick := Tick;
  { A thread started after the timers were armed keeps its tick too. }
  if not Thread^.ControlBlock.NeedsClockTick then
    SetThreadNeedsClockTick(@Thread^.ControlBlock, True);
  ReadProcessTimes(Process, Readings.ProcessRun, Readings.ProcessUser);
  Readings.ThreadRun := ReadThreadTime(Thread);
  Readings.ThreadId := Thread^.ControlBlock.ThreadId;

  ExpiryCount := 0;
  TickChange := 0;
  PreviousLevel := AcquireSpinLock(Process^.Posix.SignalLock);
  Table := TableOf(Process);
  if Table <> nil then
    for Index := 0 to TimerSlotCount - 1 do
    begin
      Timer := Table^[Index];
      if (Timer = nil) or not Timer^.Armed or not ReadingFor(Timer, Readings, Now) or (Now < Timer^.DueTime) then
        Continue;
      Missed := 0;
      if Timer^.Interval = 0 then
        TickChange := TickChange + SetArmedLocked(Timer, False)
      else
        Timer^.DueTime := NextDueTime(Timer^.DueTime, Timer^.Interval, Now, Missed);
      AtomicIncrement(Timer^.Users);
      Expiries[ExpiryCount].Timer := Timer;
      Expiries[ExpiryCount].Missed := Missed;
      Inc(ExpiryCount);
    end;
  ReleaseSpinLock(Process^.Posix.SignalLock, PreviousLevel);

  Index := 0;
  while Index < ExpiryCount do
  begin
    Fire(Expiries[Index].Timer, Expiries[Index].Missed, True);
    AtomicDecrement(Expiries[Index].Timer^.Users);
    Inc(Index);
  end;
  ApplyTickChange(Process, TickChange);
end;

{ --- Making, stopping and freeing timers ----------------------------------- }

procedure StopKernelTimer(Timer: PPosixTimer);
begin
  CancelTimer(Timer^.KernelTimer);
  CancelDeferredCall(Timer^.Call);
end;

{ --- Following steps of the wall clock ------------------------------------- }

function WallClockOffset: Int64;
begin
  Result := WallClockNanoseconds - Int64(ClockNanoseconds);
end;

{ Puts Timer on the list of timers that follow the wall clock, or takes
  it off. The timer mutex held. }
procedure SetFollowsWallClock(Timer: PPosixTimer; Follows: Boolean);
begin
  if Timer^.FollowsWallClock = Follows then
    Exit;
  if Follows then
  begin
    Timer^.WallOffset := WallClockOffset;
    InsertAtTail(WallClockTimers, @Timer^.WallLink);
  end
  else
    RemoveListEntry(@Timer^.WallLink);
  Timer^.FollowsWallClock := Follows;
end;

function TimerFromWallLink(Entry: PListEntry): PPosixTimer;
begin
  Result := PPosixTimer(ContainingRecord(Entry, FieldOffset(PPosixTimer(nil)^.WallLink)));
end;

{ Moves an armed timer's due time by the step: as much earlier as the
  wall clock went forward. }
procedure FollowClockStep(Timer: PPosixTimer);
var
  Offset: Int64;
  Step: Int64;
  DueTime: Int64;
  PreviousLevel: TPriorityLevel;
  Armed: Boolean;
begin
  Offset := WallClockOffset;
  Step := Offset - Timer^.WallOffset;
  Timer^.WallOffset := Offset;
  if (Step = 0) or (Timer^.DueTime > QWord(High(Int64))) then
    Exit;
  Timer^.Stopping := True;
  StopKernelTimer(Timer);
  StopKernelTimer(Timer);
  PreviousLevel := AcquireSpinLock(Timer^.Process^.Posix.SignalLock);
  Armed := Timer^.Armed;
  DueTime := Int64(Timer^.DueTime) - Step;
  if DueTime < 0 then
    DueTime := 0;
  if Armed then
    Timer^.DueTime := QWord(DueTime);
  ReleaseSpinLock(Timer^.Process^.Posix.SignalLock, PreviousLevel);
  Timer^.Stopping := False;
  if Armed then
    SetTimerAt(Timer^.KernelTimer, QWord(DueTime), Timer^.Call);
end;

procedure WallClockStepped;
var
  Entry: PListEntry;
begin
  AcquireMutex(TimerMutex);
  Entry := WallClockTimers.Next;
  while Entry <> @WallClockTimers do
  begin
    FollowClockStep(TimerFromWallLink(Entry));
    Entry := Entry^.Next;
  end;
  ReleaseMutex(TimerMutex);
end;

{ Stops Timer and disarms it: its call is not running and will not run
  until it is armed again. The timer mutex held. }
procedure StopTimer(Timer: PPosixTimer);
var
  PreviousLevel: TPriorityLevel;
  TickChange: Integer;
begin
  Timer^.Stopping := True;
  if Timer^.Clock = TimerClockUptime then
  begin
    { Twice: a call that began before the mark may have set it again. }
    StopKernelTimer(Timer);
    StopKernelTimer(Timer);
  end;
  PreviousLevel := AcquireSpinLock(Timer^.Process^.Posix.SignalLock);
  TickChange := SetArmedLocked(Timer, False);
  ReleaseSpinLock(Timer^.Process^.Posix.SignalLock, PreviousLevel);
  ApplyTickChange(Timer^.Process, TickChange);
  Timer^.Stopping := False;
end;

{ Takes the timer in Slot out of its table and frees it. The timer
  mutex held. }
procedure DeleteTimerInSlot(Process: PProcess; Slot: LongInt);
var
  Table: PPosixTimerTable;
  Timer: PPosixTimer;
  PreviousLevel: TPriorityLevel;
begin
  Table := TableOf(Process);
  if Table = nil then
    Exit;
  Timer := Table^[Slot];
  if Timer = nil then
    Exit;
  StopTimer(Timer);
  SetFollowsWallClock(Timer, False);
  Timer^.Stopping := True;
  PreviousLevel := AcquireSpinLock(Process^.Posix.SignalLock);
  Table^[Slot] := nil;
  RemoveQueuedSignalLocked(Process, @Timer^.Entry);
  ReleaseSpinLock(Process^.Posix.SignalLock, PreviousLevel);
  { A processor-time check may still hold it. }
  while AtomicFetchAndAdd(Timer^.Users, 0) <> 0 do
    YieldExecution;
  if Timer^.EventObject <> nil then
    DereferenceObject(Timer^.EventObject);
  FreeKernelMemory(Timer);
end;

{ The table of the calling process, made if it has none; nil if memory
  is short. The timer mutex held. }
function ObtainTable(Process: PProcess): PPosixTimerTable;
var
  Table: PPosixTimerTable;
  PreviousLevel: TPriorityLevel;
begin
  Result := TableOf(Process);
  if Result <> nil then
    Exit;
  Table := PPosixTimerTable(AllocateZeroedKernelMemory(SizeOf(TPosixTimerTable)));
  if Table = nil then
    Exit;
  PreviousLevel := AcquireSpinLock(Process^.Posix.SignalLock);
  Process^.Posix.Timers := Table;
  ReleaseSpinLock(Process^.Posix.SignalLock, PreviousLevel);
  Result := Table;
end;

function NewTimer(Process: PProcess; Slot: LongInt; Clock: TTimerClock): PPosixTimer;
begin
  Result := PPosixTimer(AllocateZeroedKernelMemory(SizeOf(TPosixTimer)));
  if Result = nil then
    Exit;
  Result^.Process := Process;
  Result^.Clock := Clock;
  Result^.Entry.Timer := Result;
  Result^.Entry.Information.TimerId := LongWord(Slot);
  Result^.Entry.Information.Code := SignalFromTimer;
  InitializeTimer(Result^.KernelTimer);
  InitializeDeferredCall(Result^.Call, @UptimeTimerDue, Result);
end;

procedure InstallTimer(Process: PProcess; Slot: LongInt; Timer: PPosixTimer);
var
  PreviousLevel: TPriorityLevel;
begin
  PreviousLevel := AcquireSpinLock(Process^.Posix.SignalLock);
  TableOf(Process)^[Slot] := Timer;
  ReleaseSpinLock(Process^.Posix.SignalLock, PreviousLevel);
end;

procedure DeleteTimersInSlots(Process: PProcess; First, Last: LongInt);
var
  Slot: LongInt;
begin
  if TableOf(Process) = nil then
    Exit;
  AcquireMutex(TimerMutex);
  for Slot := First to Last do
    DeleteTimerInSlot(Process, Slot);
  ReleaseMutex(TimerMutex);
end;

procedure DeleteProcessTimers(Process: PProcess);
var
  Table: PPosixTimerTable;
  PreviousLevel: TPriorityLevel;
begin
  DeleteTimersInSlots(Process, 0, TimerSlotCount - 1);
  PreviousLevel := AcquireSpinLock(Process^.Posix.SignalLock);
  Table := TableOf(Process);
  Process^.Posix.Timers := nil;
  ReleaseSpinLock(Process^.Posix.SignalLock, PreviousLevel);
  if Table <> nil then
    FreeKernelMemory(Table);
end;

procedure DeletePosixTimersForExec(Process: PProcess);
begin
  DeleteTimersInSlots(Process, 0, MaximumPosixTimers - 1);
end;

{ --- Reading and setting --------------------------------------------------- }

{ The clock Timer counts on, now; False if it cannot be read (the thread
  is gone). }
function ReadTimerClock(Timer: PPosixTimer; out Now: QWord): Boolean;
var
  ProcessRun: QWord;
  ProcessUser: QWord;
begin
  Result := True;
  case Timer^.Clock of
    TimerClockUptime: Now := ClockNanoseconds;
    TimerClockThreadTime: Result := ReadOwnThreadTime(Timer^.ThreadId, Now);
  else
    begin
      ReadProcessTimes(Timer^.Process, ProcessRun, ProcessUser);
      if Timer^.Clock = TimerClockProcessTime then
        Now := ProcessRun
      else
        Now := ProcessUser;
    end;
  end;
end;

procedure DescribeTimer(Timer: PPosixTimer; out Spec: TAbiTimerSpec);
var
  Now: QWord;
  PreviousLevel: TPriorityLevel;
  Armed: Boolean;
  DueTime: QWord;
begin
  if not ReadTimerClock(Timer, Now) then
    Now := 0;
  PreviousLevel := AcquireSpinLock(Timer^.Process^.Posix.SignalLock);
  Armed := Timer^.Armed;
  DueTime := Timer^.DueTime;
  Spec.IntervalNanoseconds := Timer^.Interval;
  ReleaseSpinLock(Timer^.Process^.Posix.SignalLock, PreviousLevel);
  Spec.ValueNanoseconds := 0;
  if Armed then
  begin
    if DueTime > Now then
      Spec.ValueNanoseconds := DueTime - Now
    else
      { Due, but its expiry is not handled yet: a nanosecond left. }
      Spec.ValueNanoseconds := 1;
  end;
end;

{ The due time on the timer's clock for a requested first expiry. }
function DueTimeFor(Timer: PPosixTimer; const Spec: TAbiTimerSpec; Absolute: Boolean; out DueTime: QWord): Boolean;
var
  Now: QWord;
  WallNow: Int64;
  Ahead: Int64;
begin
  Result := ReadTimerClock(Timer, Now);
  if not Result then
    Exit;
  if not Absolute then
  begin
    if Spec.ValueNanoseconds > High(QWord) - Now then
      DueTime := High(QWord)
    else
      DueTime := Now + Spec.ValueNanoseconds;
  end
  else if Timer^.CountsWallTime then
  begin
    WallNow := WallClockNanoseconds;
    if Spec.ValueNanoseconds > QWord(High(Int64)) then
      Ahead := High(Int64)
    else
      Ahead := Int64(Spec.ValueNanoseconds) - WallNow;
    if Ahead <= 0 then
      DueTime := Now
    else
      DueTime := Now + QWord(Ahead);
  end
  else
    DueTime := Spec.ValueNanoseconds;
end;

{ Sets Timer as Spec says; the timer mutex held. }
function ArmTimer(Timer: PPosixTimer; const Spec: TAbiTimerSpec; Absolute: Boolean): LongInt;
var
  DueTime: QWord;
  PreviousLevel: TPriorityLevel;
  TickChange: Integer;
begin
  StopTimer(Timer);
  SetFollowsWallClock(Timer, False);
  if Spec.ValueNanoseconds = 0 then
    Exit(ErrorNone);
  if not DueTimeFor(Timer, Spec, Absolute, DueTime) then
    Exit(ErrorNotFound);
  { An absolute real-time expiry stays at its wall clock time when the
    clock is stepped. }
  if Absolute and Timer^.CountsWallTime then
    SetFollowsWallClock(Timer, True);
  PreviousLevel := AcquireSpinLock(Timer^.Process^.Posix.SignalLock);
  Timer^.DueTime := DueTime;
  Timer^.Interval := Spec.IntervalNanoseconds;
  TickChange := SetArmedLocked(Timer, True);
  ReleaseSpinLock(Timer^.Process^.Posix.SignalLock, PreviousLevel);
  ApplyTickChange(Timer^.Process, TickChange);
  if Timer^.Clock = TimerClockUptime then
    SetTimerAt(Timer^.KernelTimer, DueTime, Timer^.Call);
  Result := ErrorNone;
end;

function ReadSpec(Address: QWord; out Spec: TAbiTimerSpec): LongInt;
begin
  Result := CopyFromUser(@Spec, Address, SizeOf(Spec));
  if (Result = ErrorNone) and (Spec.ValueNanoseconds = 0) then
    Spec.IntervalNanoseconds := 0;
end;

{ The POSIX timer TimerId of the calling process; the timer mutex held. }
function FindPosixTimer(TimerId: Int64): PPosixTimer;
var
  Table: PPosixTimerTable;
begin
  Result := nil;
  if (TimerId < 0) or (TimerId >= MaximumPosixTimers) then
    Exit;
  Table := TableOf(CurrentProcess);
  if Table <> nil then
    Result := Table^[TimerId];
end;

{ The clock and thread a new timer counts on. }
function ClockOfId(ClockId: Int64; out Clock: TTimerClock; out CountsWallTime: Boolean;
  out ThreadId: QWord): LongInt;
var
  Kind: TProcessorClockKind;
  Id: QWord;
  Ignored: QWord;
begin
  Result := ErrorNone;
  Clock := TimerClockUptime;
  CountsWallTime := False;
  ThreadId := 0;
  case ClockId of
    PosixClockRealTime, PosixClockRealTimeCoarse:
      CountsWallTime := True;
    PosixClockMonotonic, PosixClockMonotonicRaw, PosixClockMonotonicCoarse, PosixClockBootTime:
      ;
  else
    if not DecodeProcessorClock(ClockId, Kind, Id) then
      Exit(ErrorInvalidArgument);
    if Kind = ProcessorClockProcess then
    begin
      if (Id <> 0) and (Id <> CurrentProcess^.ProcessId) then
        Exit(ErrorUnsupported);
      Clock := TimerClockProcessTime;
    end
    else
    begin
      if Id = 0 then
        Id := CurrentThreadObject^.ControlBlock.ThreadId;
      if not ReadOwnThreadTime(Id, Ignored) then
        Exit(ErrorUnsupported);
      Clock := TimerClockThreadTime;
      ThreadId := Id;
    end;
  end;
end;

{ What a new timer does, from the caller's TAbiTimerEvent. }
function ApplyEvent(Timer: PPosixTimer; EventAddress: QWord; TimerId: LongInt): LongInt;
var
  Event: TAbiTimerEvent;
begin
  if EventAddress = 0 then
  begin
    Timer^.Notify := TimerNotifySignal;
    Timer^.Entry.Information.Signal := SignalAlarm;
    Timer^.Entry.Information.Value := TimerId;
    Exit(ErrorNone);
  end;
  Result := CopyFromUser(@Event, EventAddress, SizeOf(Event));
  if Result <> ErrorNone then
    Exit;
  Timer^.Notify := Event.Notify;
  case Event.Notify of
    TimerNotifySignal:
      begin
        if (Event.Signal < 1) or (Event.Signal > HighestSignal) then
          Exit(ErrorInvalidArgument);
        Timer^.Entry.Information.Signal := Event.Signal;
        Timer^.Entry.Information.Value := Event.Value;
      end;
    TimerNotifyNone:
      ;
    TimerNotifyEvent:
      begin
        Timer^.EventObject := PEventObject(ReferenceHandleOfKind(Event.EventHandle,
          Processes.Handles.HandleKindEvent));
        if Timer^.EventObject = nil then
          Exit(ErrorBadHandle);
      end;
  else
    Exit(ErrorInvalidArgument);
  end;
end;

function PerformCreatePosixTimer(ClockId: Int64; EventAddress: QWord): Int64;
var
  Process: PProcess;
  Table: PPosixTimerTable;
  Timer: PPosixTimer;
  Clock: TTimerClock;
  CountsWallTime: Boolean;
  ThreadId: QWord;
  Slot: LongInt;
  Error: LongInt;
begin
  Error := ClockOfId(ClockId, Clock, CountsWallTime, ThreadId);
  if Error <> ErrorNone then
    Exit(Failure(Error));
  Process := CurrentProcess;
  AcquireMutex(TimerMutex);
  Table := ObtainTable(Process);
  if Table = nil then
  begin
    ReleaseMutex(TimerMutex);
    Exit(Failure(ErrorOutOfMemory));
  end;
  Slot := 0;
  while (Slot < MaximumPosixTimers) and (Table^[Slot] <> nil) do
    Inc(Slot);
  if Slot = MaximumPosixTimers then
  begin
    ReleaseMutex(TimerMutex);
    Exit(Failure(ErrorWouldBlock));
  end;
  Timer := NewTimer(Process, Slot, Clock);
  if Timer = nil then
  begin
    ReleaseMutex(TimerMutex);
    Exit(Failure(ErrorOutOfMemory));
  end;
  Timer^.CountsWallTime := CountsWallTime;
  Timer^.ThreadId := ThreadId;
  Error := ApplyEvent(Timer, EventAddress, Slot);
  if Error <> ErrorNone then
  begin
    if Timer^.EventObject <> nil then
      DereferenceObject(Timer^.EventObject);
    FreeKernelMemory(Timer);
    ReleaseMutex(TimerMutex);
    Exit(Failure(Error));
  end;
  InstallTimer(Process, Slot, Timer);
  ReleaseMutex(TimerMutex);
  Result := Slot;
end;

function PerformSetPosixTimer(TimerId: Int64; Flags, NewAddress, OldAddress: QWord): Int64;
var
  Timer: PPosixTimer;
  Spec: TAbiTimerSpec;
  Previous: TAbiTimerSpec;
  Error: LongInt;
begin
  if (Flags and not QWord(TimerAbsolute)) <> 0 then
    Exit(Failure(ErrorInvalidArgument));
  Error := ReadSpec(NewAddress, Spec);
  if Error <> ErrorNone then
    Exit(Failure(Error));
  AcquireMutex(TimerMutex);
  Timer := FindPosixTimer(TimerId);
  if Timer = nil then
  begin
    ReleaseMutex(TimerMutex);
    Exit(Failure(ErrorInvalidArgument));
  end;
  DescribeTimer(Timer, Previous);
  Error := ArmTimer(Timer, Spec, (Flags and TimerAbsolute) <> 0);
  ReleaseMutex(TimerMutex);
  if Error <> ErrorNone then
    Exit(Failure(Error));
  if OldAddress <> 0 then
  begin
    Error := CopyToUser(OldAddress, @Previous, SizeOf(Previous));
    if Error <> ErrorNone then
      Exit(Failure(Error));
  end;
  Result := 0;
end;

function PerformGetPosixTimer(TimerId: Int64; SpecAddress: QWord): Int64;
var
  Timer: PPosixTimer;
  Spec: TAbiTimerSpec;
begin
  AcquireMutex(TimerMutex);
  Timer := FindPosixTimer(TimerId);
  if Timer <> nil then
    DescribeTimer(Timer, Spec);
  ReleaseMutex(TimerMutex);
  if Timer = nil then
    Exit(Failure(ErrorInvalidArgument));
  Result := -Int64(CopyToUser(SpecAddress, @Spec, SizeOf(Spec)));
end;

function PerformDeletePosixTimer(TimerId: Int64): Int64;
begin
  AcquireMutex(TimerMutex);
  if FindPosixTimer(TimerId) = nil then
  begin
    ReleaseMutex(TimerMutex);
    Exit(Failure(ErrorInvalidArgument));
  end;
  DeleteTimerInSlot(CurrentProcess, LongInt(TimerId));
  ReleaseMutex(TimerMutex);
  Result := 0;
end;

function PerformGetTimerOverrun(TimerId: Int64): Int64;
var
  Timer: PPosixTimer;
  PreviousLevel: TPriorityLevel;
begin
  Result := Failure(ErrorInvalidArgument);
  AcquireMutex(TimerMutex);
  Timer := FindPosixTimer(TimerId);
  if Timer <> nil then
  begin
    PreviousLevel := AcquireSpinLock(Timer^.Process^.Posix.SignalLock);
    if Timer^.Notify = TimerNotifyEvent then
    begin
      Result := Int64(Timer^.EventOverrun);
      Timer^.EventOverrun := 0;
      Timer^.EventPosted := False;
    end
    else
      Result := Int64(Timer^.Entry.DeliveredOverrun);
    ReleaseSpinLock(Timer^.Process^.Posix.SignalLock, PreviousLevel);
  end;
  ReleaseMutex(TimerMutex);
end;

{ --- Interval timers --------------------------------------------------------- }

function IntervalTimerClock(Which: QWord): TTimerClock;
begin
  case Which of
    IntervalTimerVirtual: Result := TimerClockProcessUserTime;
    IntervalTimerProfile: Result := TimerClockProcessTime;
  else
    Result := TimerClockUptime;
  end;
end;

function IntervalTimerSignal(Which: QWord): LongWord;
begin
  case Which of
    IntervalTimerVirtual: Result := SignalVirtualAlarm;
    IntervalTimerProfile: Result := SignalProfile;
  else
    Result := SignalAlarm;
  end;
end;

{ The interval timer Which of the calling process, made if Make and it
  has none; the timer mutex held. }
function ObtainIntervalTimer(Which: QWord; Make: Boolean): PPosixTimer;
var
  Process: PProcess;
  Table: PPosixTimerTable;
  Slot: LongInt;
begin
  Result := nil;
  Process := CurrentProcess;
  Slot := MaximumPosixTimers + LongInt(Which);
  Table := TableOf(Process);
  if Table <> nil then
    Result := Table^[Slot];
  if (Result <> nil) or not Make then
    Exit;
  Table := ObtainTable(Process);
  if Table = nil then
    Exit;
  Result := NewTimer(Process, Slot, IntervalTimerClock(Which));
  if Result = nil then
    Exit;
  Result^.Notify := TimerNotifySignal;
  Result^.Entry.Information.Signal := IntervalTimerSignal(Which);
  Result^.Entry.Information.Code := SignalFromKernel;
  Result^.Entry.Information.TimerId := 0;
  InstallTimer(Process, Slot, Result);
end;

function PerformSetIntervalTimer(Which, NewAddress, OldAddress: QWord): Int64;
var
  Timer: PPosixTimer;
  Spec: TAbiTimerSpec;
  Previous: TAbiTimerSpec;
  Error: LongInt;
begin
  if Which > IntervalTimerProfile then
    Exit(Failure(ErrorInvalidArgument));
  ZeroMemory(@Spec, SizeOf(Spec));
  if NewAddress <> 0 then
  begin
    Error := ReadSpec(NewAddress, Spec);
    if Error <> ErrorNone then
      Exit(Failure(Error));
  end;
  ZeroMemory(@Previous, SizeOf(Previous));
  Error := ErrorNone;
  AcquireMutex(TimerMutex);
  Timer := ObtainIntervalTimer(Which, (NewAddress <> 0) and (Spec.ValueNanoseconds <> 0));
  if Timer <> nil then
  begin
    DescribeTimer(Timer, Previous);
    if NewAddress <> 0 then
      Error := ArmTimer(Timer, Spec, False);
  end
  else if (NewAddress <> 0) and (Spec.ValueNanoseconds <> 0) then
    Error := ErrorOutOfMemory;
  ReleaseMutex(TimerMutex);
  if Error <> ErrorNone then
    Exit(Failure(Error));
  if OldAddress <> 0 then
  begin
    Error := CopyToUser(OldAddress, @Previous, SizeOf(Previous));
    if Error <> ErrorNone then
      Exit(Failure(Error));
  end;
  Result := 0;
end;

procedure InitializePosixTimers;
begin
  InitializeMutex(TimerMutex);
  InitializeListHead(WallClockTimers);
  AddWallClockStepRoutine(@WallClockStepped);
end;

end.
