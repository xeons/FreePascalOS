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
  Which counter the kernel's clock is read from, and the watch kept on
  the time stamp counter.

  The choice at start:
  - the time stamp counter where it is invariant (CPUID 8000_0007h), or
    in a virtual machine without KVM's paravirtual clock (hypervisors
    keep their guests' counters together, they just do not say so);
  - KVM's paravirtual clock where the counter is not said to be
    invariant and KVM offers it;
  - the HPET (Hal.HpetClock) on bare metal where the counter is not
    invariant: it may stop in idle states or change its rate with the
    processor's clock;
  - kernel option clocksource=tsc, clocksource=hpet or
    clocksource=kvmclock takes that one where it exists (clock= is the
    older spelling).

  The watchdog: while the counter is the clock and there is an HPET, the
  kernel calls WatchClockSource about once a second (Kernel.Clock-
  Watchdog). It reads the two together (again if an interrupt or the
  hypervisor came between the reads) and compares how far each moved
  since the last check (Hal.TimerFrequencies' rule: 1% or 500 us). Two
  failed checks in a row and the clock moves to the HPET, continuing
  from the counter's time (so it does not step back on this processor),
  and the change is logged; the clock page then tells programs to make
  the system call. With clocksource=tsc the failures are logged but the
  counter stays. Kernel option clockdrifttest makes the watchdog see the
  counter run 5% fast from its third check on (the test of the
  fallback, on machines whose counter is sound).
}
unit Hal.ClockSources;

{$mode objfpc}

interface

type
  TClockSource = (ClockTimeStampCounter, ClockParavirtual, ClockHpet);

{ After the rates are known and the HPET was looked for. }
procedure ChooseClockSource;
function ClockSourceNanoseconds: QWord;
function CurrentClockSource: TClockSource;
function ClockSourceName: PChar;
{ The clock was chosen by the kernel option. }
function ClockSourceWasForced: Boolean;
{ The time stamp counter's parameters for the clock page; False when
  the clock is not the counter. }
function DescribeUserClockSource(out Origin, OriginNanoseconds, CountsPerSecond: QWord): Boolean;
procedure PauseClockSource;
procedure ContinueClockSource;
{ The kernel's clock keeps counting in deep idle states. }
function ClockKeepsRunningInDeepIdle: Boolean;

{ The watchdog. }
function ClockSourceIsWatched: Boolean;
{ One check; True if the clock moved to the HPET. }
function WatchClockSource: Boolean;
{ After waking: the next check starts afresh. }
procedure RestartClockWatchdog;
procedure GetClockWatchdogFigures(out Checks, Failures, LargestDriftNanoseconds: QWord; out FellBack: Boolean);

implementation

uses
  Runtime.Text,
  Kernel.Arch.Cpu,
  Kernel.Options,
  Hal.Hpet,
  Hal.HpetMath,
  Hal.HpetClock,
  Hal.TimeStampClock,
  Hal.ParavirtualClock,
  Hal.ClockCalibration,
  Hal.TimerFrequencies,
  Debug.Output;

const
  NanosecondsPerSecond = 1000000000;
  FailuresBeforeFallback = 2;
  PairReadAttempts = 4;
  { Reads of the two further apart than this are taken again. }
  PairReadLimitNanoseconds = 50000;

var
  Source: TClockSource = ClockTimeStampCounter;
  Forced: Boolean = False;
  CounterInvariant: Boolean = False;
  Watched: Boolean = False;
  WatchStarted: Boolean = False;
  LastCycles: QWord = 0;
  LastHpetTicks: QWord = 0;
  ConsecutiveFailures: LongWord = 0;
  CheckCount: QWord = 0;
  FailureCount: QWord = 0;
  LargestDrift: QWord = 0;
  FellBackToHpet: Boolean = False;
  DriftTest: Boolean = False;

function UnderHypervisor: Boolean;
var
  Registers: TCpuidResult;
begin
  ExecuteCpuid(1, 0, Registers);
  Result := (Registers.Ecx and (LongWord(1) shl 31)) <> 0;
end;

{ What the option asks for (False if nothing). }
function WantedSource(out Wanted: TClockSource): Boolean;
var
  Value: array[0..15] of Char;
begin
  Wanted := ClockTimeStampCounter;
  Result := GetKernelOptionValue('clocksource', @Value[0], SizeOf(Value)) or
    GetKernelOptionValue('clock', @Value[0], SizeOf(Value));
  if not Result then
    Exit;
  if TextIsEqual(@Value[0], 'tsc') then
    Wanted := ClockTimeStampCounter
  else if TextIsEqual(@Value[0], 'kvmclock') then
    Wanted := ClockParavirtual
  else if TextIsEqual(@Value[0], 'hpet') then
    Wanted := ClockHpet
  else
    Result := False;
end;

function StartSource(Wanted: TClockSource): Boolean;
begin
  case Wanted of
    ClockTimeStampCounter:
      Result := True;
    ClockParavirtual:
      Result := StartParavirtualClock;
    ClockHpet:
      begin
        Result := HpetIsPresent;
        if Result then
          StartHpetClock(TimeStampClockNanoseconds);
      end;
  else
    Result := False;
  end;
end;

procedure ChooseClockSource;
var
  Wanted: TClockSource;
begin
  CounterInvariant := TimeStampCounterIsInvariant;
  Source := ClockTimeStampCounter;
  if WantedSource(Wanted) then
  begin
    Forced := StartSource(Wanted);
    if Forced then
      Source := Wanted;
  end;
  if not Forced and not CounterInvariant then
  begin
    if StartSource(ClockParavirtual) then
      Source := ClockParavirtual
    else if not UnderHypervisor and StartSource(ClockHpet) then
      Source := ClockHpet;
  end;
  Watched := (Source = ClockTimeStampCounter) and HpetIsPresent;
  DriftTest := KernelOptionIsSet('clockdrifttest');
end;

function ClockSourceNanoseconds: QWord;
begin
  case Source of
    ClockParavirtual: Result := ParavirtualClockNanoseconds;
    ClockHpet: Result := HpetClockNanoseconds;
  else
    Result := TimeStampClockNanoseconds;
  end;
end;

function CurrentClockSource: TClockSource;
begin
  Result := Source;
end;

function ClockSourceName: PChar;
begin
  case Source of
    ClockParavirtual: Result := 'KVM paravirtual clock';
    ClockHpet: Result := 'HPET';
  else
    Result := 'time stamp counter';
  end;
end;

function ClockSourceWasForced: Boolean;
begin
  Result := Forced;
end;

function DescribeUserClockSource(out Origin, OriginNanoseconds, CountsPerSecond: QWord): Boolean;
begin
  Origin := 0;
  OriginNanoseconds := 0;
  CountsPerSecond := 0;
  Result := (Source = ClockTimeStampCounter) and
    DescribeTimeStampClock(Origin, OriginNanoseconds, CountsPerSecond);
end;

procedure PauseClockSource;
begin
  PauseTimeStampClock;
  case Source of
    ClockParavirtual: PauseParavirtualClock;
    ClockHpet: PauseHpetClock;
  end;
end;

procedure ContinueClockSource;
begin
  ContinueTimeStampClock;
  case Source of
    ClockParavirtual: ContinueParavirtualClock;
    ClockHpet: ContinueHpetClock;
  end;
  RestartClockWatchdog;
end;

function ClockKeepsRunningInDeepIdle: Boolean;
begin
  Result := CounterInvariant or (Source = ClockHpet);
end;

function ClockSourceIsWatched: Boolean;
begin
  Result := Watched;
end;

procedure RestartClockWatchdog;
begin
  WatchStarted := False;
  ConsecutiveFailures := 0;
end;

{ The counter and the HPET read together; False if every attempt was
  spread too far. }
function ReadPair(out Cycles, HpetTicks: QWord): Boolean;
var
  Calibration: TTimerCalibration;
  Limit: QWord;
  Before: QWord;
  After: QWord;
  Attempt: Integer;
  WereEnabled: Boolean;
begin
  GetTimerCalibration(Calibration);
  Limit := Calibration.CounterHertz * PairReadLimitNanoseconds div NanosecondsPerSecond;
  for Attempt := 1 to PairReadAttempts do
  begin
    WereEnabled := SaveAndDisableInterrupts;
    Before := ReadTimeStampCounter;
    HpetTicks := ReadHpetCounter;
    After := ReadTimeStampCounter;
    RestoreInterrupts(WereEnabled);
    Cycles := Before + (After - Before) div 2;
    if After - Before <= Limit then
      Exit(True);
  end;
  Result := False;
end;

procedure SwitchToHpet;
var
  WereEnabled: Boolean;
begin
  WereEnabled := SaveAndDisableInterrupts;
  StartHpetClock(TimeStampClockNanoseconds);
  Source := ClockHpet;
  RestoreInterrupts(WereEnabled);
  Watched := False;
  FellBackToHpet := True;
end;

procedure ReportDrift(CounterNanoseconds, HpetNanoseconds: QWord; Switching: Boolean);
begin
  DebugBeginMessage;
  DebugWriteTag('clock');
  DebugWrite('time stamp counter drifts from the HPET: ');
  DebugWriteDecimal(CounterNanoseconds div 1000);
  DebugWrite(' us against ');
  DebugWriteDecimal(HpetNanoseconds div 1000);
  if Switching then
    DebugWriteLine(' us; the clock is the HPET from now on')
  else if Forced then
    DebugWriteLine(' us (clocksource=tsc keeps it)')
  else
    DebugWriteLine(' us');
  DebugEndMessage;
end;

function WatchClockSource: Boolean;
var
  Calibration: TTimerCalibration;
  Cycles: QWord;
  HpetTicks: QWord;
  CounterNanoseconds: QWord;
  HpetNanoseconds: QWord;
  Drift: QWord;
  Switching: Boolean;
begin
  Result := False;
  if not Watched or not ReadPair(Cycles, HpetTicks) then
    Exit;
  if not WatchStarted then
  begin
    LastCycles := Cycles;
    LastHpetTicks := HpetTicks;
    WatchStarted := True;
    Exit;
  end;
  GetTimerCalibration(Calibration);
  CounterNanoseconds := (Cycles - LastCycles) div Calibration.CounterHertz * NanosecondsPerSecond +
    ((Cycles - LastCycles) mod Calibration.CounterHertz) * NanosecondsPerSecond div Calibration.CounterHertz;
  HpetNanoseconds := HpetTicksToNanoseconds(HpetTicks - LastHpetTicks, HpetPeriodFemtoseconds);
  LastCycles := Cycles;
  LastHpetTicks := HpetTicks;
  Inc(CheckCount);
  if DriftTest and (CheckCount >= 3) then
    CounterNanoseconds := CounterNanoseconds + CounterNanoseconds div 20;
  if CounterNanoseconds > HpetNanoseconds then
    Drift := CounterNanoseconds - HpetNanoseconds
  else
    Drift := HpetNanoseconds - CounterNanoseconds;
  if Drift > LargestDrift then
    LargestDrift := Drift;
  if not ClockDriftIsExcessive(CounterNanoseconds, HpetNanoseconds) then
  begin
    ConsecutiveFailures := 0;
    Exit;
  end;
  Inc(FailureCount);
  Inc(ConsecutiveFailures);
  Switching := (ConsecutiveFailures >= FailuresBeforeFallback) and not Forced;
  ReportDrift(CounterNanoseconds, HpetNanoseconds, Switching);
  if Switching then
  begin
    SwitchToHpet;
    Result := True;
  end;
end;

procedure GetClockWatchdogFigures(out Checks, Failures, LargestDriftNanoseconds: QWord; out FellBack: Boolean);
begin
  Checks := CheckCount;
  Failures := FailureCount;
  LargestDriftNanoseconds := LargestDrift;
  FellBack := FellBackToHpet;
end;

end.
