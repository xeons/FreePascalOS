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
  Timer descriptors (timerfd): a timer whose expirations are counted
  and read.

  A timer runs on one of three clocks: the real time clock (the wall
  clock, Kernel.WallClock), the monotonic clock and the boot clock (both
  the uptime, Kernel.Clock: suspend to RAM is not counted). It is armed
  with a first time (relative, or with TimerAbsolute a time of its
  clock) and a period (zero: once), in nanoseconds; each time it goes
  off the count of expirations grows (by more than one if whole periods
  went by unseen) and the Ready event is signaled. A read takes the
  count and resets it; with none it waits (or fails with ErrorWouldBlock
  when non-blocking). Arming it again forgets the count.

  An absolute timer on the real time clock follows the clock: when the
  clock is stepped (Kernel.WallClock's step routine) its deadline in
  uptime is worked out again, or, armed with TimerCancelOnSet, it is
  stopped and canceled: reads fail with ErrorCanceled (and it is ready)
  until it is armed again.

  The state is guarded by a spin lock, as the timer's deferred call
  (TimerDue, at DispatchLevel) changes it; Ready changes only under it,
  so it always says whether a read would find something. Stopping takes
  the timer off its queue and its call off the deferred call queue
  (waiting for it if a processor runs it), twice, as Objects.Timers does:
  a run that began before the stop may have armed it again.
}
unit Objects.TimerDescriptors;

{$mode objfpc}

interface

uses
  Runtime.LinkedList,
  Abi.SystemCalls,
  Kernel.SpinLock,
  Kernel.Events,
  Kernel.Timers,
  Kernel.DeferredCalls;

type
  PTimerDescriptor = ^TTimerDescriptor;
  TTimerDescriptor = record
    Lock: TSpinLock;
    Clock: LongWord;
    NonBlocking: Boolean;
    Timer: TTimer;
    Call: TDeferredCall;
    { Signaled while expirations wait or it was canceled. }
    Ready: TEvent;
    Expirations: QWord;
    { The next time it goes off, in uptime nanoseconds; 0: stopped. }
    DueTime: QWord;
    IntervalNanoseconds: QWord;
    { Absolute on the real time clock: the next time as wall clock
      nanoseconds, followed when the clock is stepped. }
    FollowsWallClock: Boolean;
    WallClockDueTime: Int64;
    CancelOnSet: Boolean;
    Canceled: Boolean;
    { Set while it is being stopped: its call does not arm it again. }
    Stopping: Boolean;
    { In the list of timers that follow the wall clock (ListLock). }
    WallClockLink: TListEntry;
    OnWallClockList: Boolean;
  end;

procedure InitializeTimerDescriptors;
{ A new stopped timer on Clock (TimerClock*) with one reference (the
  caller's); nil if memory ran out. The clock must be valid. }
function CreateTimerDescriptor(Clock: LongWord; NonBlocking: Boolean): PTimerDescriptor;
function TimerClockIsValid(Clock: QWord): Boolean;

{ What is left of its setting (zeros when stopped). }
procedure GetTimerDescriptor(Timer: PTimerDescriptor; out Current: TAbiTimerSpecification);
{ Arms or stops it (Timer* flags); ErrorInvalidArgument for a bad
  specification or flags. Below DispatchLevel. }
function SetTimerDescriptor(Timer: PTimerDescriptor; Flags: QWord;
  constref Specification: TAbiTimerSpecification): LongInt;
{ Takes the expirations: ErrorNone, ErrorCanceled, ErrorWouldBlock or
  ErrorInterrupted. }
function ReadTimerDescriptor(Timer: PTimerDescriptor; out Expirations: QWord): LongInt;
function TimerDescriptorReadiness(Timer: PTimerDescriptor): LongWord;

implementation

uses
  Kernel.PriorityLevel,
  Kernel.Mutex,
  Kernel.Threads,
  Kernel.Scheduler,
  Kernel.Clock,
  Kernel.WallClock,
  Objects.Manager;

const
  { Times beyond this many seconds are refused (about 292 years in
    nanoseconds would overflow). }
  LatestSeconds = Int64(9000000000);

var
  TimerDescriptorType: TObjectType;
  { The timers that follow the wall clock. }
  ListLock: TMutex;
  WallClockTimers: TListEntry;

function TimerFromWallClockLink(Entry: PListEntry): PTimerDescriptor;
begin
  Result := PTimerDescriptor(ContainingRecord(Entry, FieldOffset(PTimerDescriptor(nil)^.WallClockLink)));
end;

function TimerClockIsValid(Clock: QWord): Boolean;
begin
  Result := (Clock = TimerClockRealTime) or (Clock = TimerClockMonotonic) or (Clock = TimerClockBoot);
end;

{ Wall clock nanoseconds less uptime nanoseconds, now. }
function WallClockOffset: Int64;
begin
  Result := WallClockNanoseconds - Int64(ClockNanoseconds);
end;

{ The uptime deadline of a wall clock time: at once (Now) if it passed. }
function UptimeOfWallClockTime(WallClockTime: Int64): QWord;
var
  Uptime: Int64;
  Now: QWord;
begin
  Now := ClockNanoseconds;
  Uptime := WallClockTime - WallClockOffset;
  if Uptime <= Int64(Now) then
    Result := Now
  else
    Result := QWord(Uptime);
  if Result = 0 then
    Result := 1;
end;

{ --- Going off ----------------------------------------------------------- }

procedure AddExpirationsLocked(Timer: PTimerDescriptor; Count: QWord);
begin
  if Timer^.Expirations > High(QWord) - Count then
    Timer^.Expirations := High(QWord)
  else
    Timer^.Expirations := Timer^.Expirations + Count;
  SignalEvent(Timer^.Ready);
end;

procedure TimerDue(Context: Pointer);
var
  Timer: PTimerDescriptor;
  PreviousLevel: TPriorityLevel;
  Now: QWord;
  Count: QWord;
  Missed: QWord;
  Interval: QWord;
  ArmAgain: Boolean;
begin
  Timer := PTimerDescriptor(Context);
  ArmAgain := False;
  PreviousLevel := AcquireSpinLock(Timer^.Lock);
  if Timer^.Stopping or (Timer^.DueTime = 0) then
  begin
    ReleaseSpinLock(Timer^.Lock, PreviousLevel);
    Exit;
  end;
  Now := ClockNanoseconds;
  Count := 1;
  Interval := Timer^.IntervalNanoseconds;
  if Interval <> 0 then
  begin
    Missed := 0;
    if Now > Timer^.DueTime then
      Missed := (Now - Timer^.DueTime) div Interval;
    Count := Missed + 1;
    if Timer^.DueTime > NeverDue - Count * Interval then
      Timer^.DueTime := 0
    else
    begin
      Timer^.DueTime := Timer^.DueTime + Count * Interval;
      if Timer^.FollowsWallClock then
        Timer^.WallClockDueTime := Timer^.WallClockDueTime + Int64(Count * Interval);
      ArmAgain := True;
    end;
  end
  else
    Timer^.DueTime := 0;
  AddExpirationsLocked(Timer, Count);
  if ArmAgain then
    SetTimerAt(Timer^.Timer, Timer^.DueTime, Timer^.Call);
  ReleaseSpinLock(Timer^.Lock, PreviousLevel);
end;

{ Takes the timer off its queue and its call off the deferred call
  queue, twice (see the unit's comment); afterwards it is not running
  and stays unarmed until Stopping is cleared. }
procedure StopTimer(Timer: PTimerDescriptor);
var
  PreviousLevel: TPriorityLevel;
begin
  PreviousLevel := AcquireSpinLock(Timer^.Lock);
  Timer^.Stopping := True;
  ReleaseSpinLock(Timer^.Lock, PreviousLevel);
  CancelTimer(Timer^.Timer);
  CancelDeferredCall(Timer^.Call);
  CancelTimer(Timer^.Timer);
  CancelDeferredCall(Timer^.Call);
end;

{ --- The wall clock ------------------------------------------------------ }

procedure SetFollowsWallClock(Timer: PTimerDescriptor; Follows: Boolean);
begin
  AcquireMutex(ListLock);
  if Follows and not Timer^.OnWallClockList then
  begin
    InsertAtTail(WallClockTimers, @Timer^.WallClockLink);
    Timer^.OnWallClockList := True;
  end
  else if not Follows and Timer^.OnWallClockList then
  begin
    RemoveListEntry(@Timer^.WallClockLink);
    Timer^.OnWallClockList := False;
  end;
  ReleaseMutex(ListLock);
end;

{ After a step of the clock: one timer (ListLock held). }
procedure FollowClockStep(Timer: PTimerDescriptor);
var
  PreviousLevel: TPriorityLevel;
  DueTime: QWord;
begin
  StopTimer(Timer);
  PreviousLevel := AcquireSpinLock(Timer^.Lock);
  DueTime := 0;
  if Timer^.FollowsWallClock and (Timer^.DueTime <> 0) then
  begin
    if Timer^.CancelOnSet then
    begin
      Timer^.DueTime := 0;
      Timer^.Canceled := True;
      SignalEvent(Timer^.Ready);
    end
    else
    begin
      Timer^.DueTime := UptimeOfWallClockTime(Timer^.WallClockDueTime);
      DueTime := Timer^.DueTime;
    end;
  end;
  Timer^.Stopping := False;
  if DueTime <> 0 then
    SetTimerAt(Timer^.Timer, DueTime, Timer^.Call);
  ReleaseSpinLock(Timer^.Lock, PreviousLevel);
end;

procedure WallClockStepped;
var
  Entry: PListEntry;
begin
  AcquireMutex(ListLock);
  Entry := WallClockTimers.Next;
  while Entry <> @WallClockTimers do
  begin
    FollowClockStep(TimerFromWallClockLink(Entry));
    Entry := Entry^.Next;
  end;
  ReleaseMutex(ListLock);
end;

{ --- Objects --------------------------------------------------------------- }

procedure DeleteTimerDescriptor(ObjectBody: Pointer);
var
  Timer: PTimerDescriptor;
begin
  Timer := PTimerDescriptor(ObjectBody);
  SetFollowsWallClock(Timer, False);
  StopTimer(Timer);
end;

procedure InitializeTimerDescriptors;
begin
  RegisterObjectType(TimerDescriptorType, 'TimerDescriptor', SizeOf(TTimerDescriptor),
    @DeleteTimerDescriptor);
  InitializeMutex(ListLock);
  InitializeListHead(WallClockTimers);
  AddWallClockStepRoutine(@WallClockStepped);
end;

function CreateTimerDescriptor(Clock: LongWord; NonBlocking: Boolean): PTimerDescriptor;
begin
  Result := PTimerDescriptor(CreateObject(TimerDescriptorType, nil));
  if Result = nil then
    Exit;
  InitializeSpinLock(Result^.Lock);
  Result^.Clock := Clock;
  Result^.NonBlocking := NonBlocking;
  InitializeTimer(Result^.Timer);
  InitializeDeferredCall(Result^.Call, @TimerDue, Result);
  InitializeEvent(Result^.Ready, EventKindNotification, False);
end;

{ --- Setting and reading --------------------------------------------------- }

function SpecificationIsValid(constref Specification: TAbiTimerSpecification): Boolean;
begin
  Result := (Specification.IntervalSeconds >= 0) and (Specification.IntervalSeconds <= LatestSeconds) and
    (Specification.IntervalNanoseconds >= 0) and (Specification.IntervalNanoseconds < NanosecondsPerSecond) and
    (Specification.ValueSeconds >= 0) and (Specification.ValueSeconds <= LatestSeconds) and
    (Specification.ValueNanoseconds >= 0) and (Specification.ValueNanoseconds < NanosecondsPerSecond);
end;

function NanosecondsOf(Seconds, Nanoseconds: Int64): QWord;
begin
  Result := QWord(Seconds) * NanosecondsPerSecond + QWord(Nanoseconds);
end;

procedure SplitNanoseconds(Value: QWord; out Seconds, Nanoseconds: Int64);
begin
  Seconds := Int64(Value div NanosecondsPerSecond);
  Nanoseconds := Int64(Value mod NanosecondsPerSecond);
end;

procedure GetTimerDescriptor(Timer: PTimerDescriptor; out Current: TAbiTimerSpecification);
var
  PreviousLevel: TPriorityLevel;
  Now: QWord;
  Remaining: QWord;
begin
  Current.IntervalSeconds := 0;
  Current.IntervalNanoseconds := 0;
  Current.ValueSeconds := 0;
  Current.ValueNanoseconds := 0;
  PreviousLevel := AcquireSpinLock(Timer^.Lock);
  if Timer^.DueTime <> 0 then
  begin
    Now := ClockNanoseconds;
    { Due and not gone off yet: as good as now (but still armed). }
    Remaining := 1;
    if Timer^.DueTime > Now then
      Remaining := Timer^.DueTime - Now;
    SplitNanoseconds(Remaining, Current.ValueSeconds, Current.ValueNanoseconds);
    SplitNanoseconds(Timer^.IntervalNanoseconds, Current.IntervalSeconds, Current.IntervalNanoseconds);
  end;
  ReleaseSpinLock(Timer^.Lock, PreviousLevel);
end;

function SetTimerDescriptor(Timer: PTimerDescriptor; Flags: QWord;
  constref Specification: TAbiTimerSpecification): LongInt;
var
  PreviousLevel: TPriorityLevel;
  Value: QWord;
  IsAbsolute: Boolean;
  Follows: Boolean;
  DueTime: QWord;
begin
  if ((Flags and not QWord(TimerAbsolute or TimerCancelOnSet)) <> 0) or not SpecificationIsValid(Specification) then
    Exit(ErrorInvalidArgument);
  IsAbsolute := (Flags and TimerAbsolute) <> 0;
  Follows := IsAbsolute and (Timer^.Clock = TimerClockRealTime);
  Value := NanosecondsOf(Specification.ValueSeconds, Specification.ValueNanoseconds);
  StopTimer(Timer);
  PreviousLevel := AcquireSpinLock(Timer^.Lock);
  Timer^.Expirations := 0;
  Timer^.Canceled := False;
  ResetEvent(Timer^.Ready);
  Timer^.IntervalNanoseconds := NanosecondsOf(Specification.IntervalSeconds, Specification.IntervalNanoseconds);
  Timer^.FollowsWallClock := Follows and (Value <> 0);
  Timer^.CancelOnSet := Timer^.FollowsWallClock and ((Flags and TimerCancelOnSet) <> 0);
  DueTime := 0;
  if Value <> 0 then
  begin
    if Timer^.FollowsWallClock then
    begin
      Timer^.WallClockDueTime := Int64(Value);
      DueTime := UptimeOfWallClockTime(Int64(Value));
    end
    else if IsAbsolute then
    begin
      DueTime := Value;
      if DueTime < ClockNanoseconds then
        DueTime := ClockNanoseconds;
    end
    else
      DueTime := ClockNanoseconds + Value;
    if DueTime = 0 then
      DueTime := 1;
  end;
  Timer^.DueTime := DueTime;
  Timer^.Stopping := False;
  if DueTime <> 0 then
    SetTimerAt(Timer^.Timer, DueTime, Timer^.Call);
  ReleaseSpinLock(Timer^.Lock, PreviousLevel);
  SetFollowsWallClock(Timer, Timer^.FollowsWallClock);
  Result := ErrorNone;
end;

function ReadTimerDescriptor(Timer: PTimerDescriptor; out Expirations: QWord): LongInt;
var
  PreviousLevel: TPriorityLevel;
begin
  Expirations := 0;
  repeat
    PreviousLevel := AcquireSpinLock(Timer^.Lock);
    if Timer^.Canceled then
    begin
      ReleaseSpinLock(Timer^.Lock, PreviousLevel);
      Exit(ErrorCanceled);
    end;
    if Timer^.Expirations > 0 then
    begin
      Expirations := Timer^.Expirations;
      Timer^.Expirations := 0;
      ResetEvent(Timer^.Ready);
      ReleaseSpinLock(Timer^.Lock, PreviousLevel);
      Exit(ErrorNone);
    end;
    ReleaseSpinLock(Timer^.Lock, PreviousLevel);
    if Timer^.NonBlocking then
      Exit(ErrorWouldBlock);
    if WaitForEventWithOptions(Timer^.Ready, InfiniteTimeout, True) <> WaitSignaled then
      Exit(ErrorInterrupted);
  until False;
end;

function TimerDescriptorReadiness(Timer: PTimerDescriptor): LongWord;
begin
  Result := 0;
  if (Timer^.Expirations > 0) or Timer^.Canceled then
    Result := PollReadable;
end;

end.
