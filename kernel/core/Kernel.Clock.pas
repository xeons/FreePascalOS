{
  System clock.

  The HAL raises a periodic clock interrupt. Each one advances the tick
  count (the kernel's notion of time) and lets the scheduler account for
  time slices and sleeping threads.
}
unit Kernel.Clock;

{$mode objfpc}

interface

const
  ClockTicksPerSecond = 100;
  MillisecondsPerTick = 1000 div ClockTicksPerSecond;

procedure StartSystemClock;

function ClockTickCount: QWord;
function UptimeMilliseconds: QWord;

{ Converts a duration to clock ticks, rounding up so that a sleep never
  ends early. }
function MillisecondsToTicks(Milliseconds: QWord): QWord;

implementation

uses
  Hal.Platform,
  Kernel.Arch.TrapFrame,
  Kernel.Interrupts,
  Kernel.Scheduler,
  Kernel.Panic;

var
  TickCount: QWord;

procedure HandleClockInterrupt(Frame: PTrapFrame; Context: Pointer);
begin
  { Only this handler writes the tick count, and an aligned 64-bit store
    is atomic, so readers never see a torn value. }
  TickCount := TickCount + 1;
  SchedulerClockTick(TickCount);
end;

procedure StartSystemClock;
begin
  TickCount := 0;
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

function MillisecondsToTicks(Milliseconds: QWord): QWord;
begin
  Result := (Milliseconds + MillisecondsPerTick - 1) div MillisecondsPerTick;
  if Result = 0 then
    Result := 1;
end;

end.
