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
  The clock's watchdog: where the HAL wants its clock watched (x86-64's
  time stamp counter against the HPET, Hal.ClockSources), a kernel
  timer runs HalWatchClock once a second, in a deferred call. When the
  HAL moved the clock to another counter, the clock page is published
  again (its programs then make the system call instead of reading the
  counter). Only while watching is wanted: a machine without an HPET,
  or whose clock is not the counter, takes no such wake-up.
}
unit Kernel.ClockWatchdog;

{$mode objfpc}

interface

{ Once the clock and the timers run. }
procedure StartClockWatchdog;

implementation

uses
  Hal.Platform,
  Kernel.DeferredCalls,
  Kernel.Timers,
  Kernel.ClockPage,
  Debug.Output;

const
  CheckMilliseconds = 1000;

var
  WatchTimer: TTimer;
  WatchCall: TDeferredCall;

procedure CheckClock(Context: Pointer);
begin
  if HalWatchClock then
  begin
    PublishClockPage;
    DebugBeginMessage;
    DebugWriteTag('clock');
    DebugWrite('the clock is now read from the ');
    DebugWriteLine(HalClockSourceName);
    DebugEndMessage;
  end;
  if HalClockNeedsWatching then
    SetTimer(WatchTimer, CheckMilliseconds, WatchCall);
end;

procedure StartClockWatchdog;
begin
  if not HalClockNeedsWatching then
    Exit;
  InitializeTimer(WatchTimer);
  InitializeDeferredCall(WatchCall, @CheckClock, nil);
  SetTimer(WatchTimer, CheckMilliseconds, WatchCall);
end;

end.
