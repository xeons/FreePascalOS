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

  The HAL raises a periodic clock interrupt. Each one advances the tick
  count (the kernel's notion of time) and lets the scheduler account for
  time slices and sleeping threads; the boot processor's also expires
  timers (Kernel.Timers).

  Wall clock time is the real-time clock reading taken at startup plus
  the time elapsed since, in whole seconds.
}
unit Kernel.Clock;

{$mode objfpc}

interface

uses
  Runtime.Time;

const
  ClockTicksPerSecond = 100;
  MillisecondsPerTick = 1000 div ClockTicksPerSecond;

procedure StartSystemClock;

function ClockTickCount: QWord;
function UptimeMilliseconds: QWord;

{ Current date and time as Unix time (UTC). }
function CurrentWallClockTime: TUnixTime;

{ Converts a duration to clock ticks, rounding up so that a sleep never
  ends early. }
function MillisecondsToTicks(Milliseconds: QWord): QWord;

implementation

uses
  Hal.Platform,
  Hal.RealTimeClock,
  Kernel.Arch.TrapFrame,
  Kernel.Interrupts,
  Kernel.Scheduler,
  Kernel.Processors,
  Kernel.Timers,
  Kernel.Panic;

var
  TickCount: QWord;
  WallClockAtStart: TUnixTime;

procedure HandleClockInterrupt(Frame: PTrapFrame; Context: Pointer);
begin
  { Every processor has its own clock interrupt (for its time slices);
    only the boot processor's counts time. Only it writes the tick count,
    and an aligned 64-bit store is atomic, so readers never see a torn
    value. }
  if CurrentProcessor^.Index = 0 then
  begin
    TickCount := TickCount + 1;
    ExpireTimers(TickCount);
  end;
  SchedulerClockTick(TickCount);
end;

procedure StartSystemClock;
begin
  TickCount := 0;
  WallClockAtStart := ReadRealTimeClock;
  if not RegisterInterruptHandler(HalClockInterruptVector, @HandleClockInterrupt, nil) then
    KernelPanic('clock interrupt vector is already in use');
  HalStartClock(ClockTicksPerSecond);
end;

function ClockTickCount: QWord;
begin
  Result := TickCount;
end;

function UptimeMilliseconds: QWord;
begin
  Result := TickCount * MillisecondsPerTick;
end;

function CurrentWallClockTime: TUnixTime;
begin
  Result := WallClockAtStart + TUnixTime(TickCount div ClockTicksPerSecond);
end;

function MillisecondsToTicks(Milliseconds: QWord): QWord;
begin
  Result := (Milliseconds + MillisecondsPerTick - 1) div MillisecondsPerTick;
  if Result = 0 then
    Result := 1;
end;

end.
