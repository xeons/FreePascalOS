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
  System clock.

  Time is kept by a fine clock from the HAL (HalClockNanoseconds, the
  time stamp counter on x86-64): the uptime, timers and timeouts are
  measured in its nanoseconds, and the tick count (ClockTickCount, in
  10 ms ticks) is derived from it.

  Every processor has a one-shot clock interrupt, set each time for the
  first of four things: its next 10 ms tick (time slices, and the time
  charged to the running thread), the first of the timers set on it
  (Kernel.Timers), the first wake-up of the threads that began a timed
  wait on it (Kernel.Scheduler) and, on the boot processor, the next
  sample of the load averages. A timer or a timeout therefore ends as
  soon as it is due rather than at the next tick. Whoever adds an
  earlier due time asks for an earlier interrupt
  (RequestClockInterruptBy).

  Tickless idle: a processor running its idle thread needs no tick (no
  time slice to end, nothing to charge), so the clock interrupt that
  finds it idle stops the tick (NextTickTime = NeverDue) and the
  processor sleeps until its next due time or a device or another
  processor wakes it. The switch to the idle thread stops it at once
  (StopClockTick), so a thread that wakes, runs briefly and waits again
  costs no tick. The switch away from the idle thread starts the
  tick again (RestartClockTick), due a whole tick later, so the thread
  it switches to gets a full time slice. Kernel option tickless=off
  keeps it on idle ones too.

  Dynamic tick: a busy processor whose running thread is alone (its
  run queues are empty) has no time slice to end either. The scheduler
  then defers the tick (DeferClockTick, from the dispatch interrupt
  under the processor's lock) to a residual tick a second later, which
  still charges the ticks that passed (for the split between user mode
  and the kernel) and looks again. Whoever puts a thread on that
  processor's queue sees the deferral under the same lock and sends it
  its dispatch interrupt, which starts the tick again
  (ResumeClockTick); so does any switch. Kernel option dynamictick=off
  (or tickless=off) keeps the 100 Hz tick on busy processors.

  The wall clock is Kernel.WallClock's.
}
unit Kernel.Clock;

{$mode objfpc}

interface

uses
  Runtime.Time;

const
  ClockTicksPerSecond = 100;
  MillisecondsPerTick = 1000 div ClockTicksPerSecond;
  NanosecondsPerMillisecond = 1000000;
  NanosecondsPerTick = MillisecondsPerTick * NanosecondsPerMillisecond;
  { A due time that never comes. }
  NeverDue = High(QWord);

{ On the boot processor, once the scheduler and timers are ready. }
procedure StartSystemClock;
{ Starts the executing processor's clock interrupt: on a secondary
  processor before it enables interrupts, and on every processor after
  waking from suspend to RAM. }
procedure StartClockOnThisProcessor;

{ Nanoseconds since startup (not counting time asleep); any processor,
  any level. }
function ClockNanoseconds: QWord;
function ClockTickCount: QWord;
function UptimeMilliseconds: QWord;
{ After suspend to RAM: the wall clock is read again (the uptime does
  not count the time asleep). }
procedure ResynchronizeWallClock;
{ Sets the date and time (CallSetWallClock) and writes it to the battery
  backed clock for the next boot. }
procedure SetWallClockTime(Time: TUnixTime);
{ Current date and time as Unix time (UTC), in whole seconds
  (Kernel.WallClock has it to the nanosecond). }
function CurrentWallClockTime: TUnixTime;
{ Converts a duration to clock ticks, rounding up so that a wait for
  that many ticks never ends early. }
function MillisecondsToTicks(Milliseconds: QWord): QWord;
{ The clock time Milliseconds from now; NeverDue if that is beyond what
  the clock counts. }
function DeadlineAfterMilliseconds(Milliseconds: QWord): QWord;

{ Makes sure the executing processor's clock interrupt comes no later
  than Deadline (a ClockNanoseconds time), for a timer or a wake-up due
  then that was just added on this processor. Any level up to
  DispatchLevel. }
procedure RequestClockInterruptBy(Deadline: QWord);
{ From the switch away from the idle thread (dispatcher lock held): the
  executing processor's tick starts again if it was stopped. }
procedure RestartClockTick;
{ From the switch to the idle thread: the tick stops at once, and the
  clock interrupt set for it moves to the next due time. }
procedure StopClockTick;
{ Whether idle processors stop their tick (not tickless=off). }
function ClockIsTickless: Boolean;
{ Interrupts disabled: sets the executing processor's clock interrupt
  again from its due times, those already past included (it then comes
  at once): after its timer stopped in an idle state
  (Kernel.BroadcastTimer), whose clock interrupt time reads NeverDue. }
procedure RearmClockInterrupt;
{ Whether busy processors running one thread alone defer their tick
  (not dynamictick=off nor tickless=off). }
function ClockHasDynamicTick: Boolean;
{ From the scheduler, with the executing processor's scheduling lock
  held: its running thread is alone, so its tick waits for the residual
  tick (nothing if dynamic tick is off or the processor idles). }
procedure DeferClockTick;
{ The same: the tick starts again, a whole tick from now, if it was
  deferred; the ticks it skipped are charged to Thread (the one that ran
  alone meanwhile), in the mode the last clock interrupt found. }
procedure ResumeClockTick(Thread: Pointer);
{ Whether Processor's tick is deferred (read under its scheduling
  lock). }
function ClockTickIsDeferred(Processor: Pointer): Boolean;

implementation

uses
  Hal.Platform,
  Kernel.Arch.Cpu,
  Kernel.Arch.TrapFrame,
  Kernel.Arch.UserMode,
  Kernel.Interrupts,
  Kernel.Scheduler,
  Kernel.Processors,
  Kernel.Timers,
  Kernel.Options,
  Kernel.WallClock,
  Kernel.BroadcastTimer,
  Kernel.ClockPage,
  Kernel.Threads,
  Kernel.ProcessorTime,
  Kernel.Panic;

const
  NanosecondsPerSecond = 1000000000;
  { The tick of a processor whose thread runs alone (dynamic tick). }
  ResidualTickNanoseconds = NanosecondsPerSecond;

var
  StopsTickWhenIdle: Boolean = True;
  DefersTickWhenAlone: Boolean = True;

{ Where the clock found the processor, for the hang dump: the address,
  and in kernel mode the top of the stack (within the running thread's
  stack). }
procedure RecordInterruptedPlace(Frame: PTrapFrame);
var
  Processor: PProcessor;
  Words: QWord;
  StackTop: QWord;
  StackPointer: QWord;
  Index: LongWord;
begin
  Processor := CurrentProcessor;
  Processor^.InterruptedAddress := TrapFrameInstructionPointer(Frame);
  Processor^.InterruptedStackWords := 0;
  if ArchFrameIsFromUserMode(Frame) then
    Exit;
  StackPointer := TrapFrameStackPointer(Frame);
  StackTop := Processor^.RunningThread^.StackTop;
  if (StackPointer >= StackTop) or (StackPointer < Processor^.RunningThread^.StackBase) then
    Exit;
  Words := (StackTop - StackPointer) div 8;
  if Words > Length(Processor^.InterruptedStack) then
    Words := Length(Processor^.InterruptedStack);
  for Index := 0 to Words - 1 do
    Processor^.InterruptedStack[Index] := PQWord(StackPointer + Index * 8)^;
  Processor^.InterruptedStackWords := Words;
end;

{ Sets the processor's clock interrupt for Deadline; interrupts are
  disabled, so nothing else sets it meanwhile. }
procedure SetClockInterruptFor(Processor: PProcessor; Deadline: QWord; Now: QWord);
begin
  Processor^.ClockInterruptTime := Deadline;
  if Deadline > Now then
    HalSetClockInterruptIn(Deadline - Now)
  else
    HalSetClockInterruptIn(0);
end;

{ The earliest of the processor's next tick, first timer and first
  wake-up that is still to come. A wake-up already due is left out: the
  dispatch interrupt requested for it wakes the threads and asks for the
  next wake-up itself, and until it runs (the processor may stay above
  DispatchLevel for a while) the clock must not keep interrupting. }
function NextClockDeadline(Processor: PProcessor; Now: QWord): QWord;
var
  Housekeeping: QWord;
begin
  Result := Processor^.NextTickTime;
  if Processor^.TickDeferredUntil <> 0 then
    Result := Processor^.TickDeferredUntil;
  if (Processor^.NextTimerDueTime < Result) and (Processor^.NextTimerDueTime > Now) then
    Result := Processor^.NextTimerDueTime;
  if (Processor^.NextWakeUpTime < Result) and (Processor^.NextWakeUpTime > Now) then
    Result := Processor^.NextWakeUpTime;
  Housekeeping := SchedulerHousekeepingTime(Processor);
  if Housekeeping < Result then
    Result := Housekeeping;
  { The boot processor wakes those whose timer stops while idle. }
  if Processor^.Index = 0 then
  begin
    Housekeeping := NextBroadcastDue(Now);
    if Housekeeping < Result then
      Result := Housekeeping;
  end;
  if Result <= Now then
    Result := Now + 1;
end;

procedure RearmClockInterrupt;
var
  Processor: PProcessor;
  Now: QWord;
  Deadline: QWord;
begin
  Processor := CurrentProcessor;
  Now := ClockNanoseconds;
  Deadline := NextClockDeadline(Processor, Now);
  if Processor^.NextTimerDueTime < Deadline then
    Deadline := Processor^.NextTimerDueTime;
  if Processor^.NextWakeUpTime < Deadline then
    Deadline := Processor^.NextWakeUpTime;
  SetClockInterruptFor(Processor, Deadline, Now);
end;

{ The ticks that passed by Now, the tick schedule moved on past them.
  None while the processor idles: its tick stops (or stays stopped)
  instead. }
function TakeElapsedTicks(Processor: PProcessor; Now: QWord): QWord;
begin
  Result := 0;
  if StopsTickWhenIdle and (Processor^.RunningThread = Processor^.IdleThread) then
  begin
    Processor^.NextTickTime := NeverDue;
    Exit;
  end;
  if Processor^.NextTickTime = NeverDue then
  begin
    { Busy, but the switch from the idle thread has not started the
      tick again yet (it is about to). }
    Processor^.NextTickTime := Now + NanosecondsPerTick;
    Exit;
  end;
  if Processor^.TickDeferredUntil <> 0 then
  begin
    { Deferred: this interrupt came for a timer or a wake-up, unless
      the residual tick is due. That one counts the ticks that passed
      (below), and the scheduler decides afresh whether to defer. }
    if Now < Processor^.TickDeferredUntil then
      Exit;
    Processor^.TickDeferredUntil := 0;
  end;
  if Now >= Processor^.NextTickTime then
  begin
    { Normally one; more if the interrupt came late. }
    Result := (Now - Processor^.NextTickTime) div NanosecondsPerTick + 1;
    Processor^.NextTickTime := Processor^.NextTickTime + Result * NanosecondsPerTick;
  end;
end;

procedure HandleClockInterrupt(Frame: PTrapFrame; Context: Pointer);
var
  Processor: PProcessor;
  Now: QWord;
  ElapsedTicks: QWord;
  WereEnabled: Boolean;
begin
  RecordInterruptedPlace(Frame);
  Processor := CurrentProcessor;
  Inc(Processor^.ClockInterruptCount);
  Processor^.LastTickInUserMode := ArchFrameIsFromUserMode(Frame);
  Now := ClockNanoseconds;
  WereEnabled := SaveAndDisableInterrupts;
  ElapsedTicks := TakeElapsedTicks(Processor, Now);
  RestoreInterrupts(WereEnabled);
  if ElapsedTicks > 0 then
    Inc(Processor^.TickInterruptCount);
  if Processor^.Index = 0 then
    ServeBroadcast(Now);
  if Now >= Processor^.NextTimerDueTime then
    Inc(Processor^.TimerInterruptCount);
  if Now >= Processor^.NextWakeUpTime then
    Inc(Processor^.WakeUpInterruptCount);
  ExpireTimers(Now);
  SchedulerClockInterrupt(Now, ElapsedTicks, ArchFrameIsFromUserMode(Frame));

  WereEnabled := SaveAndDisableInterrupts;
  SetClockInterruptFor(Processor, NextClockDeadline(Processor, Now), Now);
  RestoreInterrupts(WereEnabled);
end;

procedure RestartClockTick;
var
  Processor: PProcessor;
  WereEnabled: Boolean;
begin
  WereEnabled := SaveAndDisableInterrupts;
  Processor := CurrentProcessor;
  if Processor^.NextTickTime = NeverDue then
  begin
    Processor^.NextTickTime := ClockNanoseconds + NanosecondsPerTick;
    { NeverDue: its timer may have stopped in an idle state (or nothing
      was due): set in full. }
    if Processor^.ClockInterruptTime = NeverDue then
      RearmClockInterrupt
    else if Processor^.NextTickTime < Processor^.ClockInterruptTime then
      SetClockInterruptFor(Processor, Processor^.NextTickTime, ClockNanoseconds);
  end;
  RestoreInterrupts(WereEnabled);
end;

procedure StopClockTick;
var
  Processor: PProcessor;
  WereEnabled: Boolean;
  Now: QWord;
  Deadline: QWord;
begin
  if not StopsTickWhenIdle then
    Exit;
  WereEnabled := SaveAndDisableInterrupts;
  Processor := CurrentProcessor;
  if Processor^.NextTickTime <> NeverDue then
  begin
    Processor^.NextTickTime := NeverDue;
    Now := ClockNanoseconds;
    Deadline := NextClockDeadline(Processor, Now);
    { Only later: an earlier interrupt (for a timer, a wake-up) stays. }
    if Deadline > Processor^.ClockInterruptTime then
      SetClockInterruptFor(Processor, Deadline, Now);
  end;
  RestoreInterrupts(WereEnabled);
end;

function ClockIsTickless: Boolean;
begin
  Result := StopsTickWhenIdle;
end;

function ClockHasDynamicTick: Boolean;
begin
  Result := StopsTickWhenIdle and DefersTickWhenAlone;
end;

procedure DeferClockTick;
var
  Processor: PProcessor;
  WereEnabled: Boolean;
  Now: QWord;
  Deadline: QWord;
begin
  if not (StopsTickWhenIdle and DefersTickWhenAlone) then
    Exit;
  WereEnabled := SaveAndDisableInterrupts;
  Processor := CurrentProcessor;
  if (Processor^.NextTickTime <> NeverDue) and (Processor^.TickDeferredUntil = 0) then
  begin
    Now := ClockNanoseconds;
    Processor^.TickDeferredUntil := Now + ResidualTickNanoseconds;
    Inc(Processor^.TickDeferralCount);
    Deadline := NextClockDeadline(Processor, Now);
    { Only later: an earlier interrupt (for a timer, a wake-up) stays. }
    if Deadline > Processor^.ClockInterruptTime then
      SetClockInterruptFor(Processor, Deadline, Now);
  end;
  RestoreInterrupts(WereEnabled);
end;

procedure ResumeClockTick(Thread: Pointer);
var
  Processor: PProcessor;
  WereEnabled: Boolean;
  Now: QWord;
  Skipped: QWord;
begin
  WereEnabled := SaveAndDisableInterrupts;
  Processor := CurrentProcessor;
  if Processor^.TickDeferredUntil <> 0 then
  begin
    Processor^.TickDeferredUntil := 0;
    Now := ClockNanoseconds;
    { The ticks skipped go to the thread that ran alone, so the split of
      its time between user mode and the kernel still has its samples;
      then a fresh schedule, so whoever runs next gets a whole tick. }
    if Processor^.NextTickTime <> NeverDue then
    begin
      if (Thread <> nil) and (Now >= Processor^.NextTickTime) then
      begin
        Skipped := (Now - Processor^.NextTickTime) div NanosecondsPerTick + 1;
        ChargeClockTicks(PThreadControlBlock(Thread), Skipped, Processor^.LastTickInUserMode);
      end;
      Processor^.NextTickTime := Now + NanosecondsPerTick;
    end;
    { NeverDue: its timer may have stopped in an idle state
      (Kernel.BroadcastTimer): set in full, due times past included. }
    if Processor^.ClockInterruptTime = NeverDue then
      RearmClockInterrupt
    else if Processor^.NextTickTime < Processor^.ClockInterruptTime then
      SetClockInterruptFor(Processor, Processor^.NextTickTime, Now);
  end;
  RestoreInterrupts(WereEnabled);
end;

function ClockTickIsDeferred(Processor: Pointer): Boolean;
begin
  Result := PProcessor(Processor)^.TickDeferredUntil <> 0;
end;

procedure StartClockOnThisProcessor;
var
  Processor: PProcessor;
  WereEnabled: Boolean;
begin
  WereEnabled := SaveAndDisableInterrupts;
  Processor := CurrentProcessor;
  Processor^.NextTickTime := ClockNanoseconds + NanosecondsPerTick;
  Processor^.TickDeferredUntil := 0;
  { The first interrupt comes right away and sets the next one. }
  Processor^.ClockInterruptTime := 0;
  HalStartClockOnThisProcessor;
  RestoreInterrupts(WereEnabled);
end;

procedure StartSystemClock;
var
  Value: array[0..7] of Char;
begin
  if GetKernelOptionValue('tickless', @Value[0], SizeOf(Value)) and
     (Value[0] = 'o') and (Value[1] = 'f') then
    StopsTickWhenIdle := False;
  if GetKernelOptionValue('dynamictick', @Value[0], SizeOf(Value)) and
     (Value[0] = 'o') and (Value[1] = 'f') then
    DefersTickWhenAlone := False;
  StartWallClock;
  InitializeClockPage;
  if not RegisterInterruptHandler(HalClockInterruptVector, @HandleClockInterrupt, nil) then
    KernelPanic('clock interrupt vector is already in use');
  StartClockOnThisProcessor;
end;

procedure RequestClockInterruptBy(Deadline: QWord);
var
  Processor: PProcessor;
  WereEnabled: Boolean;
begin
  if Deadline = NeverDue then
    Exit;
  WereEnabled := SaveAndDisableInterrupts;
  Processor := CurrentProcessor;
  if Deadline < Processor^.ClockInterruptTime then
    SetClockInterruptFor(Processor, Deadline, ClockNanoseconds);
  RestoreInterrupts(WereEnabled);
end;

function ClockNanoseconds: QWord;
begin
  Result := HalClockNanoseconds;
end;

procedure ResynchronizeWallClock;
begin
  ReadWallClockFromHardware;
end;

procedure SetWallClockTime(Time: TUnixTime);
begin
  StepWallClockTo(Time);
end;

function CurrentWallClockTime: TUnixTime;
begin
  Result := WallClockSeconds;
end;

function ClockTickCount: QWord;
begin
  Result := ClockNanoseconds div NanosecondsPerTick;
end;

function UptimeMilliseconds: QWord;
begin
  Result := ClockNanoseconds div NanosecondsPerMillisecond;
end;

function MillisecondsToTicks(Milliseconds: QWord): QWord;
begin
  Result := (Milliseconds + MillisecondsPerTick - 1) div MillisecondsPerTick;
  if Result = 0 then
    Result := 1;
end;

function DeadlineAfterMilliseconds(Milliseconds: QWord): QWord;
var
  Now: QWord;
begin
  Now := ClockNanoseconds;
  if Milliseconds >= (NeverDue - Now) div NanosecondsPerMillisecond then
    Exit(NeverDue);
  Result := Now + Milliseconds * NanosecondsPerMillisecond;
end;

end.
