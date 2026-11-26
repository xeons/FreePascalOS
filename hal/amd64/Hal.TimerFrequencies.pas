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
  The arithmetic of the timer frequencies the processor or the
  hypervisor states, apart from reading them (Hal.ClockCalibration).

  - CPUID 15h: the time stamp counter runs at the core crystal clock
    times EBX / EAX; ECX is the crystal's frequency in hertz, or 0 where
    the processor does not say. Then it is known by the model (Intel
    family 6): 25 MHz on Goldmont D (Denverton), 19.2 MHz on Goldmont
    and Goldmont Plus; else from CPUID 16h's base frequency (EAX, in
    MHz: the counter runs at it, so the crystal is it times EAX / EBX
    of leaf 15h); else 24 MHz on Skylake and Kaby Lake client models,
    which lack leaf 16h in some steppings. As Linux does.
  - CPUID 16h alone: the base frequency in MHz, only a nominal figure.
  - KVM's paravirtual clock: its record scales counter cycles to
    nanoseconds by a 32.32 factor after a shift, so the counter's rate
    is 10^9 * 2^32 / factor, shifted the other way.
  - Two frequencies agree within a tolerance in parts per million.
  - The clock watchdog's rule (Hal.ClockSources): over one interval,
    the time stamp counter's nanoseconds and the HPET's may differ by
    at most 1% of the interval and never less than 500 us (the reads of
    the two are not quite together); a counter that stops in an idle
    state or changes its rate with the clock is far outside that.

  Plain Pascal: tools/HpetTest checks it on the host.
}
unit Hal.TimerFrequencies;

{$mode objfpc}

interface

const
  IntelFamily6 = 6;

type
  { Where a frequency came from, in the order they are tried. }
  TFrequencySource = (
    FrequencyUnknown,
    FrequencyFromHypervisorLeaf,
    FrequencyFromParavirtualClock,
    FrequencyFromCrystalRatio,
    FrequencyFromCrystal,
    FrequencyFromHpet,
    FrequencyFromPowerManagementTimer,
    FrequencyFromIntervalTimer,
    FrequencyFromTimeStampCounter,
    FrequencyFromNominal);

{ The core crystal's frequency where leaf 15h's ECX is 0: by the model,
  or from leaf 16h's base frequency (Leaf16BaseMegahertz, 0 if absent)
  and leaf 15h's ratio. 0 if not known. }
function DefaultCrystalHertz(Family, Model: LongWord; Denominator, Numerator: LongWord;
  Leaf16BaseMegahertz: LongWord): QWord;
{ The crystal's frequency from leaf 15h (ECX, or the default above). }
function CrystalHertzFromLeaf15(Family, Model: LongWord; Denominator, Numerator, CrystalHertz: LongWord;
  Leaf16BaseMegahertz: LongWord): QWord;
{ The time stamp counter's rate from leaf 15h (EAX = Denominator, EBX =
  Numerator) and the crystal's; 0 if leaf 15h gives no ratio. }
function CounterHertzFromCrystal(Denominator, Numerator: LongWord; CrystalHertz: QWord): QWord;
{ The counter's rate from KVM's paravirtual clock record (0 if the
  factor is 0). }
function CounterHertzFromParavirtualScale(Multiplier: LongWord; Shift: ShortInt): QWord;
{ A and B differ by at most PartsPerMillion of B (both non-zero). }
function FrequenciesAgree(A, B: QWord; PartsPerMillion: LongWord): Boolean;
{ How far A is from B, in parts per million of B. }
function FrequencyDifferencePartsPerMillion(A, B: QWord): QWord;
{ The watchdog's rule: the counter measured Measured nanoseconds over
  an interval the reference measured as Reference. }
function ClockDriftIsExcessive(Measured, Reference: QWord): Boolean;
{ "CPUID 15h crystal ratio", "HPET", "interval timer" ... }
function FrequencySourceName(Source: TFrequencySource): PChar;

implementation

const
  ModelGoldmont = $5C;
  ModelGoldmontD = $5F;
  ModelGoldmontPlus = $7A;
  ModelSkylakeMobile = $4E;
  ModelSkylakeDesktop = $5E;
  ModelKabyLakeMobile = $8E;
  ModelKabyLakeDesktop = $9E;

function DefaultCrystalHertz(Family, Model: LongWord; Denominator, Numerator: LongWord;
  Leaf16BaseMegahertz: LongWord): QWord;
begin
  Result := 0;
  if Family <> IntelFamily6 then
    Exit;
  case Model of
    ModelGoldmontD:
      Exit(25000000);
    ModelGoldmont, ModelGoldmontPlus:
      Exit(19200000);
  end;
  if (Leaf16BaseMegahertz <> 0) and (Denominator <> 0) and (Numerator <> 0) then
    Exit(QWord(Leaf16BaseMegahertz) * 1000000 * Denominator div Numerator);
  case Model of
    ModelSkylakeMobile, ModelSkylakeDesktop, ModelKabyLakeMobile, ModelKabyLakeDesktop:
      Result := 24000000;
  end;
end;

function CrystalHertzFromLeaf15(Family, Model: LongWord; Denominator, Numerator, CrystalHertz: LongWord;
  Leaf16BaseMegahertz: LongWord): QWord;
begin
  if CrystalHertz <> 0 then
    Result := CrystalHertz
  else
    Result := DefaultCrystalHertz(Family, Model, Denominator, Numerator, Leaf16BaseMegahertz);
end;

function CounterHertzFromCrystal(Denominator, Numerator: LongWord; CrystalHertz: QWord): QWord;
begin
  if (Denominator = 0) or (Numerator = 0) or (CrystalHertz = 0) then
    Exit(0);
  Result := CrystalHertz * Numerator div Denominator;
end;

function CounterHertzFromParavirtualScale(Multiplier: LongWord; Shift: ShortInt): QWord;
const
  { 10^9 * 2^32 still fits in 64 bits. }
  ScaledNanosecondsPerSecond = QWord(1000000000) shl 32;
begin
  if Multiplier = 0 then
    Exit(0);
  Result := ScaledNanosecondsPerSecond div Multiplier;
  if Shift < 0 then
    Result := Result shl (-Shift)
  else
    Result := Result shr Shift;
end;

function FrequencyDifferencePartsPerMillion(A, B: QWord): QWord;
var
  Difference: QWord;
begin
  if B = 0 then
    Exit(High(QWord));
  if A > B then
    Difference := A - B
  else
    Difference := B - A;
  { Rates stay far below 2^44 Hz, so times 10^6 fits. }
  Result := Difference * 1000000 div B;
end;

function FrequenciesAgree(A, B: QWord; PartsPerMillion: LongWord): Boolean;
begin
  Result := (A <> 0) and (B <> 0) and (FrequencyDifferencePartsPerMillion(A, B) <= PartsPerMillion);
end;

function ClockDriftIsExcessive(Measured, Reference: QWord): Boolean;
const
  SmallestAllowanceNanoseconds = 500000;
  AllowancePercent = 1;
var
  Difference: QWord;
  Allowance: QWord;
begin
  if Measured > Reference then
    Difference := Measured - Reference
  else
    Difference := Reference - Measured;
  Allowance := Reference div 100 * AllowancePercent;
  if Allowance < SmallestAllowanceNanoseconds then
    Allowance := SmallestAllowanceNanoseconds;
  Result := Difference > Allowance;
end;

function FrequencySourceName(Source: TFrequencySource): PChar;
begin
  case Source of
    FrequencyFromHypervisorLeaf: Result := 'hypervisor leaf 40000010h';
    FrequencyFromParavirtualClock: Result := 'KVM paravirtual clock';
    FrequencyFromCrystalRatio: Result := 'CPUID 15h crystal ratio';
    FrequencyFromCrystal: Result := 'CPUID 15h core crystal';
    FrequencyFromHpet: Result := 'measured against the HPET';
    FrequencyFromPowerManagementTimer: Result := 'measured against the ACPI PM timer';
    FrequencyFromIntervalTimer: Result := 'measured against the interval timer';
    FrequencyFromTimeStampCounter: Result := 'measured against the time stamp counter';
    FrequencyFromNominal: Result := 'CPUID 16h base frequency';
  else
    Result := 'unknown';
  end;
end;

end.
