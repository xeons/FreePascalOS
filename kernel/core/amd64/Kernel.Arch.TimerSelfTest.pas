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
  Self tests of the x86-64 timers:
  - the HPET's counter advances at its stated period: over 50 ms it
    agrees with the kernel's clock within 2% (and 2 ms);
  - the calibration's sources agree: the time stamp counter's rate
    measured again against the reference (HPET or PIT) is within 2% of
    the rate in use, whichever source gave it;
  - the event timer's comparator fires on time: a one-shot 5 ms ahead
    arrives (never early, by construction) and less than 40 ms late;
    and periodically, where the comparator can, about once per period;
  - where the broadcast is the HPET's, the boot processor itself is
    woken on time while it waits as if its timer stopped.
  Tolerances are wide enough for an emulator on a busy host.
}
unit Kernel.Arch.TimerSelfTest;

{$mode objfpc}

interface

procedure RunTimerSelfTest;

implementation

uses
  Kernel.Arch.Cpu,
  Kernel.Clock,
  Kernel.Threads,
  Kernel.Scheduler,
  Kernel.Processors,
  Kernel.IdleStates,
  Kernel.BroadcastTimer,
  Kernel.SelfTest,
  Hal.Hpet,
  Hal.HpetMath,
  Hal.HpetEventTimer,
  Hal.ClockCalibration,
  Hal.TimerFrequencies;

const
  CounterCheckMilliseconds = 50;
  AgreementPartsPerMillion = 20000;
  AgreementSlackNanoseconds = 2 * NanosecondsPerMillisecond;
  OneShotDelayNanoseconds = 5 * NanosecondsPerMillisecond;
  OneShotWaitMilliseconds = 1000;
  LatenessLimitNanoseconds = 40 * NanosecondsPerMillisecond;
  PeriodNanoseconds = 2 * NanosecondsPerMillisecond;
  PeriodicMilliseconds = 100;
  MeasureMicroseconds = 20000;
  SleepCount = 10;
  SleepLength = 20;
  MaximumMoveYields = 1000;

procedure ReadTogether(out Ticks, Nanoseconds: QWord);
var
  WereEnabled: Boolean;
begin
  WereEnabled := SaveAndDisableInterrupts;
  Ticks := ReadHpetCounter;
  Nanoseconds := ClockNanoseconds;
  RestoreInterrupts(WereEnabled);
end;

procedure CheckCounterPeriod;
var
  StartTicks: QWord;
  StartNanoseconds: QWord;
  EndTicks: QWord;
  EndNanoseconds: QWord;
  ByHpet: QWord;
  ByClock: QWord;
  Difference: QWord;
begin
  ReadTogether(StartTicks, StartNanoseconds);
  SleepMilliseconds(CounterCheckMilliseconds);
  ReadTogether(EndTicks, EndNanoseconds);
  ByHpet := HpetTicksToNanoseconds(EndTicks - StartTicks, HpetPeriodFemtoseconds);
  ByClock := EndNanoseconds - StartNanoseconds;
  if ByHpet > ByClock then
    Difference := ByHpet - ByClock
  else
    Difference := ByClock - ByHpet;
  Check(EndTicks > StartTicks, 'HPET: the counter advances');
  Check(Difference <= ByClock div 1000000 * AgreementPartsPerMillion + AgreementSlackNanoseconds,
    'HPET: the counter advances at its stated period (it agrees with the clock)');
end;

procedure CheckCalibrationSources;
var
  Calibration: TTimerCalibration;
  Measured: QWord;
begin
  GetTimerCalibration(Calibration);
  Check(Calibration.CounterSource <> FrequencyUnknown, 'timers: the counter''s rate has a source');
  Check(Calibration.LocalTimerHertz <> 0, 'timers: the local APIC timer''s rate is known');
  if Calibration.Reference = FrequencyUnknown then
    Exit;
  Measured := MeasureCounterHertz(MeasureMicroseconds);
  Check(FrequenciesAgree(Calibration.CounterHertz, Measured, AgreementPartsPerMillion),
    'timers: the counter''s rate in use agrees with a new measurement against the reference');
end;

procedure CheckOneShot;
var
  Lateness: QWord;
  Waited: Integer;
  Before: QWord;
begin
  Before := HpetEventInterruptCount;
  StartHpetOneShotTest(OneShotDelayNanoseconds);
  Waited := 0;
  while not HpetOneShotTestResult(Lateness) and (Waited < OneShotWaitMilliseconds) do
  begin
    SleepMilliseconds(1);
    Inc(Waited);
  end;
  CancelHpetOneShotTest;
  Check(HpetOneShotTestResult(Lateness), 'HPET: the comparator''s one-shot interrupt comes');
  Check(HpetEventInterruptCount > Before, 'HPET: its interrupts are counted');
  Check(Lateness <= LatenessLimitNanoseconds, 'HPET: the one-shot interrupt comes on time');
end;

procedure CheckPeriodic;
var
  Start: QWord;
  Elapsed: QWord;
  Count: QWord;
  Expected: QWord;
begin
  Start := ClockNanoseconds;
  if not StartHpetPeriodicTest(PeriodNanoseconds) then
    Exit;
  SleepMilliseconds(PeriodicMilliseconds);
  Count := StopHpetPeriodicTest;
  Elapsed := ClockNanoseconds - Start;
  Expected := Elapsed div PeriodNanoseconds;
  Check(Count >= Expected div 4, 'HPET: the periodic comparator interrupts once per period (too few)');
  Check(Count <= Expected + Expected div 2 + 5, 'HPET: the periodic comparator interrupts once per period (too many)');
end;

{ The boot processor waits as if its timer stopped; the HPET wakes it. }
procedure CheckBootProcessorBroadcast;
var
  Thread: PThreadControlBlock;
  OldMask: QWord;
  Yields: Integer;
  Before: QWord;
  Start: QWord;
  Elapsed: QWord;
  Longest: QWord;
  Index: Integer;
  WasForced: Boolean;
begin
  Thread := CurrentThread;
  OldMask := ExchangeThreadAffinity(Thread, 1);
  Yields := 0;
  while (CurrentProcessor^.Index <> 0) and (Yields < MaximumMoveYields) do
  begin
    YieldExecution;
    Inc(Yields);
  end;
  Check(CurrentProcessor^.Index = 0, 'HPET broadcast: the test thread did not move');
  WasForced := ForcedBroadcastIsOn;
  SetForcedBroadcast(True);
  Before := BroadcastWakeCount;
  Longest := 0;
  for Index := 1 to SleepCount do
  begin
    Start := ClockNanoseconds;
    SleepMilliseconds(SleepLength);
    Elapsed := ClockNanoseconds - Start;
    if Elapsed > Longest then
      Longest := Elapsed;
  end;
  SetForcedBroadcast(WasForced);
  ExchangeThreadAffinity(Thread, OldMask);
  Check(Longest <= SleepLength * NanosecondsPerMillisecond + LatenessLimitNanoseconds,
    'HPET broadcast: a sleep on the boot processor ended late (the HPET did not wake it)');
  Check(BroadcastWakeCount > Before, 'HPET broadcast: the boot processor was never woken by it');
end;

procedure RunTimerSelfTest;
begin
  CheckCalibrationSources;
  if not HpetIsPresent then
  begin
    ReportPassed('timers (no HPET; the calibration sources agree)');
    Exit;
  end;
  CheckCounterPeriod;
  if HpetEventTimerIsRunning then
  begin
    CheckOneShot;
    CheckPeriodic;
  end;
  if BroadcastUsesDevice then
    CheckBootProcessorBroadcast;
  ReportPassed('HPET (counter period, calibration sources, comparator one-shot and periodic, broadcast)');
end;

end.
