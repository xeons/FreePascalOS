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
  timetest: the clocks (run by coretest, as root).
  - The nanosecond clocks (CallGetPreciseTime): the uptime never goes
    back over many reads, nor does the wall clock; the wall clock's
    seconds agree with CallGetTime's; the nanoseconds stay below 10^9.
  - Sleeps (with the tick stopped on idle processors): never early,
    and not late by more than the slack an emulator needs.
  - Now has milliseconds.
  - CallAdjustWallClock: a query without root's right is allowed and
    changing is not; a step moves the clock at once (and back); a
    gradual adjustment runs it fast (what is left shrinks) and a new
    one replaces it; steps out of 1970-2200 and gradual adjustments
    over an hour are refused.
  Prints a line per check (FAIL for a failed one) and the count last;
  exits 1 if one failed.

  timetest --watch STOPFILE: reads the uptime over and over until
  STOPFILE exists (stress-suspend.py runs it in the background across
  many suspends to RAM), then says how many reads went back; exits 1 if
  any did.
}
program TimeTest;

{$mode objfpc}{$H+}

uses
  SysUtils,
  DateUtils,
  Abi.SystemCalls,
  Sys.Kernel,
  Sys.Time;

const
  MonotonicReads = 200000;
  SleepMilliseconds = 20;
  SleepRounds = 10;
  { An emulator (TCG) on a busy host may wake a sleeper late. }
  LateSlackMilliseconds = 80;
  NanosecondsPerMillisecond = 1000000;
  NanosecondsPerSecond = 1000000000;

var
  Checks: Integer = 0;
  Failures: Integer = 0;

procedure Check(Condition: Boolean; const What: string);
begin
  Inc(Checks);
  if Condition then
    WriteLn('timetest: ', What)
  else
  begin
    WriteLn('timetest: FAIL: ', What);
    Inc(Failures);
  end;
end;

procedure TestMonotonic;
var
  Index: Integer;
  Previous: QWord;
  Now: QWord;
  WallPrevious: Int64;
  WallNow: Int64;
  BackSteps: Integer;
  WallBackSteps: Integer;
  Precise: TAbiPreciseTime;
  BadFractions: Integer;
begin
  BackSteps := 0;
  WallBackSteps := 0;
  BadFractions := 0;
  Previous := MonotonicNanoseconds;
  WallPrevious := WallClockNanoseconds;
  for Index := 1 to MonotonicReads do
  begin
    Now := MonotonicNanoseconds;
    if Now < Previous then
      Inc(BackSteps);
    Previous := Now;
    if (Index mod 16) = 0 then
    begin
      WallNow := WallClockNanoseconds;
      if WallNow < WallPrevious then
        Inc(WallBackSteps);
      WallPrevious := WallNow;
      if (KernelGetPreciseTime(TimeWallClock, Precise) <> 0) or (Precise.Nanoseconds >= NanosecondsPerSecond) then
        Inc(BadFractions);
    end;
  end;
  Check(BackSteps = 0, Format('uptime nanoseconds never go back (%d reads, %d back)', [MonotonicReads, BackSteps]));
  Check(WallBackSteps = 0, Format('wall clock nanoseconds never go back (%d back)', [WallBackSteps]));
  Check(BadFractions = 0, 'precise times have nanoseconds below one second');
  Check(Abs(WallClockNanoseconds div NanosecondsPerSecond - KernelGetTime(TimeWallClock)) <= 1,
    'the precise wall clock agrees with the seconds one');
  Check(KernelGetPreciseTime(7, Precise) = -ErrorInvalidArgument, 'an unknown clock is refused');
end;

procedure TestSleeps;
var
  Round: Integer;
  Start: QWord;
  Elapsed: QWord;
  Early: Integer;
  Late: Integer;
  Longest: QWord;
begin
  Early := 0;
  Late := 0;
  Longest := 0;
  for Round := 1 to SleepRounds do
  begin
    Start := MonotonicNanoseconds;
    Sleep(SleepMilliseconds);
    Elapsed := MonotonicNanoseconds - Start;
    if Elapsed < SleepMilliseconds * NanosecondsPerMillisecond then
      Inc(Early);
    if Elapsed > (SleepMilliseconds + LateSlackMilliseconds) * NanosecondsPerMillisecond then
      Inc(Late);
    if Elapsed > Longest then
      Longest := Elapsed;
  end;
  Check(Early = 0, Format('%d sleeps of %d ms never end early', [SleepRounds, SleepMilliseconds]));
  Check(Late = 0, Format('nor late (longest %d us)', [Longest div 1000]));
  Start := MonotonicNanoseconds;
  Sleep(1);
  Check(MonotonicNanoseconds - Start >= NanosecondsPerMillisecond, 'a sleep of 1 ms lasts at least 1 ms');
end;

procedure TestNow;
var
  First: System.TDateTime;
  Second: System.TDateTime;
  Difference: Int64;
begin
  First := Now;
  Sleep(50);
  Second := Now;
  Difference := MilliSecondsBetween(Second, First);
  Check((Difference >= 45) and (Difference < 50 + LateSlackMilliseconds * 2),
    Format('Now counts milliseconds (%d ms for a sleep of 50)', [Difference]));
end;

procedure TestAdjust;
var
  Remaining: Int64;
  Before: Int64;
  After: Int64;
  Left: Int64;
begin
  Check(KernelAdjustWallClock(0, AdjustQueryOnly, Remaining) = 0, 'a query of the adjustment works');
  Check(KernelAdjustWallClock(0, $80, Remaining) = -ErrorInvalidArgument, 'unknown flags are refused');
  { A step forward and back. }
  Before := WallClockNanoseconds;
  Check(KernelAdjustWallClock(NanosecondsPerSecond, 0, Remaining) = 0, 'a step of one second');
  After := WallClockNanoseconds;
  Check((After - Before >= NanosecondsPerSecond) and (After - Before < 2 * NanosecondsPerSecond),
    Format('moved the clock at once (%d ms)', [(After - Before) div NanosecondsPerMillisecond]));
  KernelAdjustWallClock(-NanosecondsPerSecond, 0, Remaining);
  Check(Abs(WallClockNanoseconds - Before) < NanosecondsPerSecond div 2, 'a step back undid it');
  { Gradually: 10 ms at 0.05 % takes 20 s, so 0.2 s moves 0.1 ms. }
  Check(KernelAdjustWallClock(10 * NanosecondsPerMillisecond, AdjustGradually, Remaining) = 0,
    'a gradual adjustment of 10 ms');
  Check((Remaining > 9 * NanosecondsPerMillisecond) and (Remaining <= 10 * NanosecondsPerMillisecond),
    Format('is under way (%d us left)', [Remaining div 1000]));
  Sleep(200);
  KernelAdjustWallClock(0, AdjustQueryOnly, Left);
  Check((Left < Remaining) and (Left > 9 * NanosecondsPerMillisecond),
    Format('runs the clock fast (%d us left)', [Left div 1000]));
  KernelAdjustWallClock(0, AdjustGradually, Remaining);
  Check(Remaining = 0, 'a new adjustment replaces it');
  { Out of range: the clock must not overflow (nor go to the battery
    backed clock). }
  Before := WallClockNanoseconds;
  Check(KernelAdjustWallClock(High(Int64) - 1, 0, Remaining) = -ErrorInvalidArgument,
    'a step past the year 2200 is refused');
  Check(KernelAdjustWallClock(-Before - NanosecondsPerSecond, 0, Remaining) = -ErrorInvalidArgument,
    'a step before 1970 is refused');
  Check(KernelAdjustWallClock(Int64(2) * 3600 * NanosecondsPerSecond, AdjustGradually, Remaining) =
    -ErrorInvalidArgument, 'a gradual adjustment of two hours is refused');
  Check(Abs(WallClockNanoseconds - Before) < NanosecondsPerSecond, 'the refused ones left the clock alone');
end;

{ Counts the uptime reads that went back until StopFile appears. }
procedure WatchUptime(const StopFile: string);
const
  ReadsBetweenLooks = 20000;
var
  Reads: QWord;
  BackSteps: QWord;
  LargestStep: QWord;
  Previous: QWord;
  Now: QWord;
  Index: Integer;
begin
  Reads := 0;
  BackSteps := 0;
  LargestStep := 0;
  Previous := MonotonicNanoseconds;
  while not FileExists(StopFile) do
  begin
    for Index := 1 to ReadsBetweenLooks do
    begin
      Now := MonotonicNanoseconds;
      if Now < Previous then
      begin
        Inc(BackSteps);
        if Previous - Now > LargestStep then
          LargestStep := Previous - Now;
      end;
      Previous := Now;
    end;
    Inc(Reads, ReadsBetweenLooks);
    { Leave the processor to others now and then. }
    Sleep(1);
  end;
  WriteLn(Format('timetest: watch: %d uptime reads, %d went back (by up to %d ns)',
    [Reads, BackSteps, LargestStep]));
  if BackSteps > 0 then
    Halt(1);
end;

begin
  if (ParamCount = 2) and (ParamStr(1) = '--watch') then
  begin
    WatchUptime(ParamStr(2));
    Exit;
  end;
  TestMonotonic;
  TestSleeps;
  TestNow;
  TestAdjust;
  WriteLn(Format('timetest: %d of %d checks passed', [Checks - Failures, Checks]));
  if Failures > 0 then
    Halt(1);
end.
