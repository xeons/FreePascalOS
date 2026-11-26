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
  How fast the time stamp counter and the local APIC timer run.

  The counter's rate, the first of these that gives one:
  1. Stated by the hypervisor: leaf 4000_0010h (EAX, in kHz; VMware's
     convention, which QEMU follows with vmware-cpuid-freq), or KVM's
     paravirtual clock record (its scale, Hal.ParavirtualClock).
  2. Stated by the processor (Intel): CPUID 15h, the crystal times the
     ratio, with the crystal known by the model where ECX is 0
     (Hal.TimerFrequencies).
  3. Measured over 50 ms against the HPET (its period is stated to the
     femtosecond).
  4. Measured over 50 ms against the ACPI PM timer (3.579545 MHz, in
     every ACPI chipset; Hal.PowerManagementTimer), where there is no
     HPET.
  5. Measured over 50 ms against the PIT, if it is there (many recent
     PCs gate it off; Hal.IntervalTimer looks first).
  6. CPUID 16h's base frequency: only a nominal figure, so it comes
     after any measurement.
  A stated rate is checked against a short measurement where there is
  a reference (HPET, PM timer or PIT): if the two differ by more than 1%, the
  measurement is taken (and both are logged).

  The local APIC timer (divided by 16) runs on the bus or core crystal
  clock:
  1. Stated by the hypervisor: leaf 4000_0010h EBX (the bus, in kHz).
  2. On bare metal Intel processors with CPUID 15h's crystal: that
     crystal (Linux takes the same), since the timer runs on it.
  3. Measured against the time stamp counter, now known, over 20 ms (so
     the ratio of the two, which decides whether a clock interrupt comes
     early by the counter, is close).
  A stated rate is checked against that measurement in the same way.

  Busy waits before the kernel's clock runs (the processors' start-up
  delays, Hal.Platform) use the best reference there is: the counter
  once its rate is known, else the HPET, the PM timer or the PIT.
}
unit Hal.ClockCalibration;

{$mode objfpc}

interface

uses
  Hal.TimerFrequencies;

type
  TTimerCalibration = record
    CounterHertz: QWord;
    CounterSource: TFrequencySource;
    { The rate stated (0 if none was), and measured against the
      reference (0 without one). }
    CounterStatedHertz: QWord;
    CounterStatedSource: TFrequencySource;
    CounterMeasuredHertz: QWord;
    LocalTimerHertz: QWord;
    LocalTimerSource: TFrequencySource;
    LocalTimerStatedHertz: QWord;
    LocalTimerMeasuredHertz: QWord;
    { The reference measurements are made against: the HPET, the PIT
      or none. }
    Reference: TFrequencySource;
    CrystalHertz: QWord;
  end;

{ Measures and decides both rates (the local APIC must be set up). }
procedure CalibrateTimers(out Calibration: TTimerCalibration);
{ The result. }
procedure GetTimerCalibration(out Calibration: TTimerCalibration);
{ Busy-waits Microseconds by the best reference. }
procedure CalibrationBusyWait(Microseconds: LongWord);
{ The counter's rate measured against the reference over Microseconds
  (0 without a reference): the self test's check of the sources. }
function MeasureCounterHertz(Microseconds: LongWord): QWord;

implementation

uses
  Kernel.Arch.Cpu,
  Runtime.Memory,
  Kernel.Panic,
  Hal.Hpet,
  Hal.HpetMath,
  Hal.IntervalTimer,
  Hal.PowerManagementTimer,
  Hal.LocalApic,
  Hal.ParavirtualClock;

const
  MeasureMicroseconds = 50000;
  CheckMicroseconds = 20000;
  LocalTimerMicroseconds = 20000;
  AgreementPartsPerMillion = 10000;
  LocalApicTimerDivider = 16;
  NanosecondsPerMicrosecond = 1000;
  MicrosecondsPerSecond = 1000000;
  NanosecondsPerSecond = 1000000000;
  { The longest stretch the PIT counts in one go. }
  LongestIntervalWait = 50000;

  CpuidFeatures = 1;
  FeatureHypervisorBit = LongWord(1) shl 31;
  HypervisorLeaf = $40000000;
  HypervisorTimingLeaf = $40000010;
  CrystalLeaf = $15;
  FrequencyLeaf = $16;
  { "GenuineIntel" }
  IntelEbx = $756E6547;
  IntelEdx = $49656E69;
  IntelEcx = $6C65746E;

var
  Calibrated: TTimerCalibration;
  CounterKnown: Boolean = False;

function UnderHypervisor: Boolean;
var
  Registers: TCpuidResult;
begin
  ExecuteCpuid(CpuidFeatures, 0, Registers);
  Result := (Registers.Ecx and FeatureHypervisorBit) <> 0;
end;

{ Leaf 4000_0010h: the counter's and the bus's rates in kHz (0, 0 if
  the hypervisor has no such leaf). }
procedure ReadHypervisorTiming(out CounterKilohertz, BusKilohertz: LongWord);
var
  Registers: TCpuidResult;
begin
  CounterKilohertz := 0;
  BusKilohertz := 0;
  if not UnderHypervisor then
    Exit;
  ExecuteCpuid(HypervisorLeaf, 0, Registers);
  if Registers.Eax < HypervisorTimingLeaf then
    Exit;
  ExecuteCpuid(HypervisorTimingLeaf, 0, Registers);
  CounterKilohertz := Registers.Eax;
  BusKilohertz := Registers.Ebx;
end;

function IsIntel(out MaximumLeaf: LongWord): Boolean;
var
  Registers: TCpuidResult;
begin
  ExecuteCpuid(0, 0, Registers);
  MaximumLeaf := Registers.Eax;
  Result := (Registers.Ebx = IntelEbx) and (Registers.Edx = IntelEdx) and (Registers.Ecx = IntelEcx);
end;

procedure ReadFamilyAndModel(out Family, Model: LongWord);
var
  Registers: TCpuidResult;
begin
  ExecuteCpuid(CpuidFeatures, 0, Registers);
  Family := (Registers.Eax shr 8) and $F;
  Model := (Registers.Eax shr 4) and $F;
  if (Family = 6) or (Family = 15) then
    Model := Model or (((Registers.Eax shr 16) and $F) shl 4);
  if Family = 15 then
    Family := Family + ((Registers.Eax shr 20) and $FF);
end;

{ CPUID 15h (and 16h for the crystal where needed): the counter's rate
  and the crystal's (0, 0 where it does not say). Also the nominal base
  frequency of leaf 16h. }
procedure ReadProcessorTiming(out CounterHertz, CrystalHertz, NominalHertz: QWord);
var
  MaximumLeaf: LongWord;
  Leaf15: TCpuidResult;
  Leaf16: TCpuidResult;
  Family: LongWord;
  Model: LongWord;
  BaseMegahertz: LongWord;
begin
  CounterHertz := 0;
  CrystalHertz := 0;
  NominalHertz := 0;
  if not IsIntel(MaximumLeaf) then
    Exit;
  BaseMegahertz := 0;
  if MaximumLeaf >= FrequencyLeaf then
  begin
    ExecuteCpuid(FrequencyLeaf, 0, Leaf16);
    BaseMegahertz := Leaf16.Eax and $FFFF;
    NominalHertz := QWord(BaseMegahertz) * 1000000;
  end;
  if MaximumLeaf < CrystalLeaf then
    Exit;
  ExecuteCpuid(CrystalLeaf, 0, Leaf15);
  ReadFamilyAndModel(Family, Model);
  CrystalHertz := CrystalHertzFromLeaf15(Family, Model, Leaf15.Eax, Leaf15.Ebx, Leaf15.Ecx, BaseMegahertz);
  CounterHertz := CounterHertzFromCrystal(Leaf15.Eax, Leaf15.Ebx, CrystalHertz);
end;

function ChooseReference: TFrequencySource;
begin
  if HpetIsPresent then
    Result := FrequencyFromHpet
  else if InitializePowerManagementTimer then
    Result := FrequencyFromPowerManagementTimer
  else if IntervalTimerIsPresent then
    Result := FrequencyFromIntervalTimer
  else
    Result := FrequencyUnknown;
end;

{ The counter against the HPET over about Microseconds. }
function MeasureAgainstHpet(Microseconds: LongWord): QWord;
var
  StartTicks: QWord;
  EndTicks: QWord;
  Wanted: QWord;
  StartCycles: QWord;
  Cycles: QWord;
  Nanoseconds: QWord;
begin
  Wanted := HpetNanosecondsToTicks(QWord(Microseconds) * NanosecondsPerMicrosecond, HpetPeriodFemtoseconds);
  StartTicks := ReadHpetCounter;
  StartCycles := ReadTimeStampCounter;
  repeat
    EndTicks := ReadHpetCounter;
  until EndTicks - StartTicks >= Wanted;
  Cycles := ReadTimeStampCounter - StartCycles;
  Nanoseconds := HpetTicksToNanoseconds(EndTicks - StartTicks, HpetPeriodFemtoseconds);
  if Nanoseconds = 0 then
    Exit(0);
  Result := Cycles * NanosecondsPerSecond div Nanoseconds;
end;

{ The counter against the PM timer over about Microseconds. }
function MeasureAgainstPowerManagementTimer(Microseconds: LongWord): QWord;
var
  Start: LongWord;
  Wanted: QWord;
  Ticks: QWord;
  StartCycles: QWord;
  Cycles: QWord;
begin
  Wanted := QWord(PowerManagementTimerFrequency) * Microseconds div MicrosecondsPerSecond;
  Start := ReadPowerManagementTimer;
  StartCycles := ReadTimeStampCounter;
  repeat
    Ticks := PowerManagementTicksSince(Start);
  until Ticks >= Wanted;
  Cycles := ReadTimeStampCounter - StartCycles;
  Result := Cycles * PowerManagementTimerFrequency div Ticks;
end;

procedure PowerManagementBusyWait(Microseconds: LongWord);
var
  Start: LongWord;
  Wanted: QWord;
begin
  Wanted := QWord(PowerManagementTimerFrequency) * Microseconds div MicrosecondsPerSecond;
  Start := ReadPowerManagementTimer;
  while PowerManagementTicksSince(Start) < Wanted do
    CpuRelax;
end;

function MeasureAgainstIntervalTimer(Microseconds: LongWord): QWord;
var
  StartCycles: QWord;
  Cycles: QWord;
begin
  if Microseconds > LongestIntervalWait then
    Microseconds := LongestIntervalWait;
  StartCycles := ReadTimeStampCounter;
  if not IntervalTimerBusyWait(Microseconds) then
    Exit(0);
  Cycles := ReadTimeStampCounter - StartCycles;
  Result := Cycles * MicrosecondsPerSecond div Microseconds;
end;

function MeasureWith(Reference: TFrequencySource; Microseconds: LongWord): QWord;
begin
  case Reference of
    FrequencyFromHpet: Result := MeasureAgainstHpet(Microseconds);
    FrequencyFromPowerManagementTimer: Result := MeasureAgainstPowerManagementTimer(Microseconds);
    FrequencyFromIntervalTimer: Result := MeasureAgainstIntervalTimer(Microseconds);
  else
    Result := 0;
  end;
end;

function MeasureCounterHertz(Microseconds: LongWord): QWord;
begin
  Result := MeasureWith(Calibrated.Reference, Microseconds);
end;

{ The first rate stated by the hypervisor or the processor; also the
  crystal's rate and leaf 16h's nominal one. }
procedure FindStatedCounterRate(var Calibration: TTimerCalibration; out NominalHertz: QWord);
var
  CounterKilohertz: LongWord;
  BusKilohertz: LongWord;
  Hertz: QWord;
  CrystalCounter: QWord;
begin
  ReadProcessorTiming(CrystalCounter, Calibration.CrystalHertz, NominalHertz);
  ReadHypervisorTiming(CounterKilohertz, BusKilohertz);
  if CounterKilohertz <> 0 then
  begin
    Calibration.CounterStatedHertz := QWord(CounterKilohertz) * 1000;
    Calibration.CounterStatedSource := FrequencyFromHypervisorLeaf;
    Exit;
  end;
  Hertz := ParavirtualCounterHertz;
  if Hertz <> 0 then
  begin
    Calibration.CounterStatedHertz := Hertz;
    Calibration.CounterStatedSource := FrequencyFromParavirtualClock;
    Exit;
  end;
  if CrystalCounter <> 0 then
  begin
    Calibration.CounterStatedHertz := CrystalCounter;
    Calibration.CounterStatedSource := FrequencyFromCrystalRatio;
  end;
end;

procedure DecideCounterRate(var Calibration: TTimerCalibration);
var
  NominalHertz: QWord;
begin
  FindStatedCounterRate(Calibration, NominalHertz);
  if Calibration.CounterStatedHertz <> 0 then
  begin
    Calibration.CounterMeasuredHertz := MeasureWith(Calibration.Reference, CheckMicroseconds);
    if (Calibration.CounterMeasuredHertz <> 0) and
       not FrequenciesAgree(Calibration.CounterStatedHertz, Calibration.CounterMeasuredHertz,
         AgreementPartsPerMillion) then
    begin
      Calibration.CounterHertz := Calibration.CounterMeasuredHertz;
      Calibration.CounterSource := Calibration.Reference;
    end
    else
    begin
      Calibration.CounterHertz := Calibration.CounterStatedHertz;
      Calibration.CounterSource := Calibration.CounterStatedSource;
    end;
    Exit;
  end;
  Calibration.CounterMeasuredHertz := MeasureWith(Calibration.Reference, MeasureMicroseconds);
  if Calibration.CounterMeasuredHertz <> 0 then
  begin
    Calibration.CounterHertz := Calibration.CounterMeasuredHertz;
    Calibration.CounterSource := Calibration.Reference;
    Exit;
  end;
  if NominalHertz <> 0 then
  begin
    Calibration.CounterHertz := NominalHertz;
    Calibration.CounterSource := FrequencyFromNominal;
    Exit;
  end;
  KernelPanicWithCode(PanicHardwareMissing,
    'the time stamp counter''s rate is unknown (no HPET, PM timer or PIT, no CPUID 15h or 16h)', 0, 0, 0, 0);
end;

{ The local APIC timer's ticks per second against the counter. }
function MeasureLocalTimer(CounterHertz: QWord): QWord;
var
  StartCycles: QWord;
  Cycles: QWord;
  Wanted: QWord;
  Ticks: QWord;
begin
  Wanted := CounterHertz * LocalTimerMicroseconds div MicrosecondsPerSecond;
  StartLocalApicTimerCountdown;
  StartCycles := ReadTimeStampCounter;
  repeat
    Cycles := ReadTimeStampCounter - StartCycles;
  until Cycles >= Wanted;
  Ticks := StopLocalApicTimerCountdown;
  Cycles := ReadTimeStampCounter - StartCycles;
  if Cycles = 0 then
    Exit(0);
  Result := Ticks * CounterHertz div Cycles;
end;

procedure DecideLocalTimerRate(var Calibration: TTimerCalibration);
var
  CounterKilohertz: LongWord;
  BusKilohertz: LongWord;
begin
  Calibration.LocalTimerMeasuredHertz := MeasureLocalTimer(Calibration.CounterHertz);
  if Calibration.LocalTimerMeasuredHertz = 0 then
    KernelPanicWithCode(PanicHardwareMissing, 'local APIC timer does not count', 0, 0, 0, 0);
  ReadHypervisorTiming(CounterKilohertz, BusKilohertz);
  if BusKilohertz <> 0 then
  begin
    Calibration.LocalTimerStatedHertz := QWord(BusKilohertz) * 1000 div LocalApicTimerDivider;
    Calibration.LocalTimerSource := FrequencyFromHypervisorLeaf;
  end
  else if not UnderHypervisor and (Calibration.CrystalHertz <> 0) then
  begin
    Calibration.LocalTimerStatedHertz := Calibration.CrystalHertz div LocalApicTimerDivider;
    Calibration.LocalTimerSource := FrequencyFromCrystal;
  end;
  if (Calibration.LocalTimerStatedHertz <> 0) and
     FrequenciesAgree(Calibration.LocalTimerStatedHertz, Calibration.LocalTimerMeasuredHertz,
       AgreementPartsPerMillion) then
    Calibration.LocalTimerHertz := Calibration.LocalTimerStatedHertz
  else
  begin
    Calibration.LocalTimerHertz := Calibration.LocalTimerMeasuredHertz;
    Calibration.LocalTimerSource := FrequencyFromTimeStampCounter;
  end;
end;

procedure CalibrateTimers(out Calibration: TTimerCalibration);
begin
  ZeroMemory(@Calibration, SizeOf(Calibration));
  Calibration.Reference := ChooseReference;
  DecideCounterRate(Calibration);
  if Calibration.CounterHertz = 0 then
    KernelPanicWithCode(PanicHardwareMissing, 'time stamp counter does not count', 0, 0, 0, 0);
  Calibrated := Calibration;
  CounterKnown := True;
  DecideLocalTimerRate(Calibration);
  Calibrated := Calibration;
end;

procedure GetTimerCalibration(out Calibration: TTimerCalibration);
begin
  Calibration := Calibrated;
end;

procedure CounterBusyWait(Microseconds: LongWord);
var
  StartCycles: QWord;
  Wanted: QWord;
begin
  Wanted := Calibrated.CounterHertz * Microseconds div MicrosecondsPerSecond;
  StartCycles := ReadTimeStampCounter;
  while ReadTimeStampCounter - StartCycles < Wanted do
    CpuRelax;
end;

procedure IntervalBusyWait(Microseconds: LongWord);
var
  Step: LongWord;
begin
  while Microseconds > 0 do
  begin
    Step := Microseconds;
    if Step > LongestIntervalWait then
      Step := LongestIntervalWait;
    IntervalTimerBusyWait(Step);
    Microseconds := Microseconds - Step;
  end;
end;

procedure CalibrationBusyWait(Microseconds: LongWord);
begin
  if CounterKnown then
    CounterBusyWait(Microseconds)
  else if HpetIsPresent then
    HpetBusyWait(QWord(Microseconds) * NanosecondsPerMicrosecond)
  else if PowerManagementTimerIsPresent then
    PowerManagementBusyWait(Microseconds)
  else
    IntervalBusyWait(Microseconds);
end;

end.
