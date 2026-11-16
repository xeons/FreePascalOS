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
  first of three things: its next 10 ms tick (time slices, and the time
  charged to the running thread), the first of the timers set on it
  (Kernel.Timers) and the first wake-up of the threads that began a
  timed wait on it (Kernel.Scheduler). A timer or a timeout therefore
  ends as soon as it is due rather than at the next tick, while the
  scheduler keeps its steady 100 Hz tick. Whoever adds an earlier due
  time asks for an earlier interrupt (RequestClockInterruptBy).

  Wall clock time is the real-time clock reading taken at startup plus
  the uptime, in whole seconds.
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

{ Current date and time as Unix time (UTC). }
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

implementation

uses
  Hal.Platform,
  Hal.RealTimeClock,
  Kernel.Arch.Cpu,
  Kernel.Arch.TrapFrame,
  Kernel.Interrupts,
  Kernel.Scheduler,
  Kernel.Processors,
  Kernel.Timers,
  Kernel.Panic;

const
  NanosecondsPerSecond = 1000000000;

var
  WallClockAtStart: TUnixTime;

{ Where the clock found the processor, for the hang dump: the address,
  and in kernel mode the top of the stack (within the running thread's
  stack). }
procedure RecordInterruptedPlace(Frame: PTrapFrame);
const
  KernelModeMask = 3;
var
  Processor: PProcessor;
  Words: QWord;
  StackTop: QWord;
  Index: LongWord;
begin
  Processor := CurrentProcessor;
  Processor^.InterruptedAddress := Frame^.Rip;
  Processor^.InterruptedStackWords := 0;
  if (Frame^.Cs and KernelModeMask) <> 0 then
    Exit;
  StackTop := Processor^.RunningThread^.StackTop;
  if (Frame^.Rsp >= StackTop) or (Frame^.Rsp < Processor^.RunningThread^.StackBase) then
    Exit;
  Words := (StackTop - Frame^.Rsp) div 8;
  if Words > Length(Processor^.InterruptedStack) then
    Words := Length(Processor^.InterruptedStack);
  for Index := 0 to Words - 1 do
    Processor^.InterruptedStack[Index] := PQWord(Frame^.Rsp + Index * 8)^;
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
begin
  Result := Processor^.NextTickTime;
  if (Processor^.NextTimerDueTime < Result) and (Processor^.NextTimerDueTime > Now) then
    Result := Processor^.NextTimerDueTime;
  if (Processor^.NextWakeUpTime < Result) and (Processor^.NextWakeUpTime > Now) then
    Result := Processor^.NextWakeUpTime;
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
  Now := ClockNanoseconds;
  ElapsedTicks := 0;
  if Now >= Processor^.NextTickTime then
  begin
    { Normally one; more if the interrupt came late. }
    ElapsedTicks := (Now - Processor^.NextTickTime) div NanosecondsPerTick + 1;
    Processor^.NextTickTime := Processor^.NextTickTime + ElapsedTicks * NanosecondsPerTick;
  end;
  ExpireTimers(Now);
  SchedulerClockInterrupt(Now, ElapsedTicks);

  WereEnabled := SaveAndDisableInterrupts;
  SetClockInterruptFor(Processor, NextClockDeadline(Processor, Now), Now);
  RestoreInterrupts(WereEnabled);
end;

procedure StartClockOnThisProcessor;
var
  Processor: PProcessor;
  WereEnabled: Boolean;
begin
  WereEnabled := SaveAndDisableInterrupts;
  Processor := CurrentProcessor;
  Processor^.NextTickTime := ClockNanoseconds + NanosecondsPerTick;
  { The first interrupt comes right away and sets the next one. }
  Processor^.ClockInterruptTime := 0;
  HalStartClockOnThisProcessor;
  RestoreInterrupts(WereEnabled);
end;

procedure StartSystemClock;
begin
  WallClockAtStart := ReadRealTimeClock;
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

function UptimeSeconds: QWord;
begin
  Result := ClockNanoseconds div NanosecondsPerSecond;
end;

procedure ResynchronizeWallClock;
begin
  WallClockAtStart := ReadRealTimeClock - TUnixTime(UptimeSeconds);
end;

procedure SetWallClockTime(Time: TUnixTime);
begin
  WallClockAtStart := Time - TUnixTime(UptimeSeconds);
  WriteRealTimeClock(Time);
end;

function ClockTickCount: QWord;
begin
  Result := ClockNanoseconds div NanosecondsPerTick;
end;

function UptimeMilliseconds: QWord;
begin
  Result := ClockNanoseconds div NanosecondsPerMillisecond;
end;

function CurrentWallClockTime: TUnixTime;
begin
  Result := WallClockAtStart + TUnixTime(UptimeSeconds);
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
