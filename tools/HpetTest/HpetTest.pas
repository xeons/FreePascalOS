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
  Host test of the x86-64 HAL's timer arithmetic (make hpet-test):
  - the ACPI HPET table (Hal.HpetTable): QEMU's table, a 32-bit block
    with many comparators, and tables that must be refused (short, not
    HPET, registers in I/O space, unaligned or zero address);
  - the HPET's registers and units (Hal.HpetMath): the capability
    fields, ticks to nanoseconds and back (100 MHz and 14.318 MHz,
    rounding up, large counts), the 32-bit wrap extension and the
    missed-comparator rule;
  - the stated frequencies (Hal.TimerFrequencies): CPUID 15h's ratio,
    the crystal by model or from CPUID 16h where ECX is 0, KVM's
    paravirtual scale, agreement in parts per million and the clock
    watchdog's drift rule;
  - the calibration's samples (Hal.CalibrationSamples): bracketed reads
    (middle, width, the narrowest kept), a sample's cycles, uncertainty
    and rate, a vCPU stall between the reads made visible and refused,
    the steadier of two, and the median that leaves outliers out.
  Prints each failure and exits 1 if there was one.
}
program HpetTest;

{$mode objfpc}{$H+}

uses
  SysUtils,
  Hal.HpetTable,
  Hal.HpetMath,
  Hal.TimerFrequencies,
  Hal.CalibrationSamples;

var
  Failures: Integer = 0;
  Checks: Integer = 0;

procedure Check(Condition: Boolean; const What: string);
begin
  Inc(Checks);
  if not Condition then
  begin
    WriteLn('FAIL: ', What);
    Inc(Failures);
  end;
end;

type
  TTableBytes = array[0..63] of Byte;

procedure PutLongWord(var Table: TTableBytes; Offset: Integer; Value: LongWord);
begin
  Table[Offset] := Byte(Value);
  Table[Offset + 1] := Byte(Value shr 8);
  Table[Offset + 2] := Byte(Value shr 16);
  Table[Offset + 3] := Byte(Value shr 24);
end;

procedure PutQWord(var Table: TTableBytes; Offset: Integer; Value: QWord);
begin
  PutLongWord(Table, Offset, LongWord(Value and $FFFFFFFF));
  PutLongWord(Table, Offset + 4, LongWord(Value shr 32));
end;

{ An HPET table as QEMU's q35 machine builds it. }
procedure MakeTable(out Table: TTableBytes; BlockId: LongWord; Address: QWord; SpaceId: Byte);
begin
  FillChar(Table, SizeOf(Table), 0);
  Table[0] := Ord('H');
  Table[1] := Ord('P');
  Table[2] := Ord('E');
  Table[3] := Ord('T');
  PutLongWord(Table, 4, HpetTableMinimumLength);
  PutLongWord(Table, 36, BlockId);
  Table[40] := SpaceId;
  Table[41] := 64;
  PutQWord(Table, 44, Address);
  Table[52] := 0;
  Table[53] := $80;
  Table[54] := $00;
  Table[55] := 0;
end;

procedure TestTable;
var
  Table: TTableBytes;
  Information: THpetTableInformation;
begin
  MakeTable(Table, $8086A201, $FED00000, AddressSpaceSystemMemory);
  Check(ParseHpetTable(@Table[0], HpetTableMinimumLength, Information), 'table: QEMU''s table is read');
  Check(Information.BaseAddress = $FED00000, 'table: base address');
  Check(Information.ComparatorCount = 3, 'table: three comparators');
  Check(Information.CounterIs64Bit, 'table: 64-bit counter');
  Check(Information.LegacyReplacementCapable, 'table: legacy replacement capable');
  Check(Information.VendorId = $8086, 'table: vendor');
  Check(Information.HardwareRevision = 1, 'table: revision');
  Check(Information.MinimumTick = $80, 'table: minimum tick');

  MakeTable(Table, $10DE1F01, $FEB00000, AddressSpaceSystemMemory);
  Check(ParseHpetTable(@Table[0], HpetTableMinimumLength, Information), 'table: a 32-bit block is read');
  Check(Information.ComparatorCount = 32, 'table: 32 comparators');
  Check(not Information.CounterIs64Bit and not Information.LegacyReplacementCapable,
    'table: 32-bit counter without legacy replacement');

  MakeTable(Table, $8086A201, $FED00000, AddressSpaceSystemMemory);
  Check(not ParseHpetTable(@Table[0], HpetTableMinimumLength - 1, Information), 'table: too short is refused');
  Check(not ParseHpetTable(nil, HpetTableMinimumLength, Information), 'table: nil is refused');
  Table[0] := Ord('A');
  Check(not ParseHpetTable(@Table[0], HpetTableMinimumLength, Information), 'table: another signature is refused');
  MakeTable(Table, $8086A201, $FED00000, 1);
  Check(not ParseHpetTable(@Table[0], HpetTableMinimumLength, Information), 'table: I/O space is refused');
  MakeTable(Table, $8086A201, $FED00010, AddressSpaceSystemMemory);
  Check(not ParseHpetTable(@Table[0], HpetTableMinimumLength, Information), 'table: an unaligned address is refused');
  MakeTable(Table, $8086A201, 0, AddressSpaceSystemMemory);
  Check(not ParseHpetTable(@Table[0], HpetTableMinimumLength, Information), 'table: address 0 is refused');
end;

procedure TestRegisters;
const
  { QEMU: period 10 ns, 3 comparators, 64-bit, legacy, Intel. }
  QemuCapabilities = (QWord(10000000) shl 32) or $8086A201;
  ChipsetPeriod = 69841279;
var
  Ticks: QWord;
begin
  Check(HpetPeriodOf(QemuCapabilities) = 10000000, 'registers: period');
  Check(HpetComparatorCountOf(QemuCapabilities) = 3, 'registers: comparators');
  Check(HpetCounterIs64BitOf(QemuCapabilities), 'registers: 64-bit counter');
  Check(HpetLegacyCapableOf(QemuCapabilities), 'registers: legacy replacement');
  Check(HpetVendorOf(QemuCapabilities) = $8086, 'registers: vendor');
  Check(HpetPeriodIsValid(10000000) and HpetPeriodIsValid(MaximumHpetPeriodFemtoseconds) and
    not HpetPeriodIsValid(0) and not HpetPeriodIsValid(MaximumHpetPeriodFemtoseconds + 1),
    'registers: valid periods');

  Check(HpetTicksToNanoseconds(1, 10000000) = 10, 'units: a 100 MHz tick is 10 ns');
  Check(HpetTicksToNanoseconds(100000000, 10000000) = 1000000000, 'units: 10^8 ticks at 100 MHz are a second');
  Check(HpetTicksToNanoseconds(QWord(1) shl 40, 10000000) = (QWord(1) shl 40) * 10, 'units: large counts');
  Ticks := HpetTicksToNanoseconds(14318180, ChipsetPeriod);
  Check((Ticks > 999999000) and (Ticks < 1000001000), 'units: 14.318 MHz for a second');
  Check(HpetNanosecondsToTicks(15, 10000000) = 2, 'units: nanoseconds to ticks rounds up');
  Check(HpetNanosecondsToTicks(20, 10000000) = 2, 'units: exact nanoseconds to ticks');
  Check(HpetNanosecondsToTicks(4000000000, 10000000) = 400000000, 'units: 4 s at 100 MHz');
  Ticks := HpetNanosecondsToTicks(1000000000, ChipsetPeriod);
  Check((Ticks >= 14318179) and (Ticks <= 14318181), 'units: a second at 14.318 MHz');
  Check(HpetFrequencyOf(10000000) = 100000000, 'units: 100 MHz');
  Check(HpetFrequencyOf(ChipsetPeriod) = 14318180, 'units: 14.318180 MHz');

  Check(ExtendCounterReading($00000000FFFFFFF0, $10) = $0000000100000010, 'wrap: one wrap counted');
  Check(ExtendCounterReading($0000000500000010, $20) = $0000000500000020, 'wrap: no wrap');
  Check(ExtendCounterReading($0000000500000010, $10) = $0000000500000010, 'wrap: the same reading');
  Check(ExtendCounterReading($00000005FFFFFFFF, 0) = $0000000600000000, 'wrap: to zero');

  Check(not ComparatorWasMissed(100, 50, 10), 'comparator: well ahead');
  Check(ComparatorWasMissed(100, 95, 10), 'comparator: too close');
  Check(ComparatorWasMissed(100, 120, 10), 'comparator: passed');
  Check(not ComparatorWasMissed($10, $FFFFFFF0, 16), 'comparator: ahead across the wrap');
  Check(ComparatorWasMissed($FFFFFFF0, $10, 16), 'comparator: passed across the wrap');
end;

procedure TestFrequencies;
var
  Hertz: QWord;
begin
  Check(CounterHertzFromCrystal(2, 176, 24000000) = 2112000000, 'CPUID 15h: 24 MHz times 176/2');
  Check(CounterHertzFromCrystal(0, 176, 24000000) = 0, 'CPUID 15h: no ratio');
  Check(CounterHertzFromCrystal(2, 176, 0) = 0, 'CPUID 15h: no crystal');
  Check(CrystalHertzFromLeaf15(IntelFamily6, $8E, 2, 176, 38400000, 0) = 38400000, 'CPUID 15h: ECX wins');
  Check(CrystalHertzFromLeaf15(IntelFamily6, $5F, 1, 100, 0, 0) = 25000000, 'CPUID 15h: Goldmont D at 25 MHz');
  Check(CrystalHertzFromLeaf15(IntelFamily6, $5C, 1, 100, 0, 0) = 19200000, 'CPUID 15h: Goldmont at 19.2 MHz');
  Check(CrystalHertzFromLeaf15(IntelFamily6, $8E, 2, 175, 0, 2100) = 24000000,
    'CPUID 15h: the crystal from CPUID 16h''s base frequency');
  Check(CrystalHertzFromLeaf15(IntelFamily6, $5E, 2, 176, 0, 0) = 24000000, 'CPUID 15h: Skylake at 24 MHz');
  Check(CrystalHertzFromLeaf15(IntelFamily6, $2A, 2, 176, 0, 0) = 0, 'CPUID 15h: unknown otherwise');
  Check(CrystalHertzFromLeaf15(15, $5E, 2, 176, 0, 0) = 0, 'CPUID 15h: only Intel family 6 by model');

  Hertz := CounterHertzFromParavirtualScale(2863311530, -1);
  Check((Hertz >= 2999999990) and (Hertz <= 3000000010), 'kvmclock: 3 GHz from its scale');
  Hertz := CounterHertzFromParavirtualScale(4294967295, 0);
  Check((Hertz >= 999999999) and (Hertz <= 1000000001), 'kvmclock: 1 GHz from its scale');
  Check(CounterHertzFromParavirtualScale(0, 0) = 0, 'kvmclock: no scale');

  Check(FrequenciesAgree(2900000000, 2901000000, 1000), 'agreement: within 1000 ppm');
  Check(not FrequenciesAgree(2900000000, 2940000000, 10000), 'agreement: 1.4% is not within 1%');
  Check(not FrequenciesAgree(0, 2900000000, 10000), 'agreement: 0 never agrees');
  Check(FrequencyDifferencePartsPerMillion(1001000, 1000000) = 1000, 'agreement: parts per million');

  Check(not ClockDriftIsExcessive(1004000000, 1000000000), 'watchdog: 0.4% over a second is fine');
  Check(ClockDriftIsExcessive(1020000000, 1000000000), 'watchdog: 2% over a second is not');
  Check(ClockDriftIsExcessive(980000000, 1000000000), 'watchdog: nor 2% slow');
  Check(not ClockDriftIsExcessive(10400000, 10000000), 'watchdog: 400 us over 10 ms is within the floor');
  Check(ClockDriftIsExcessive(10600000, 10000000), 'watchdog: 600 us over 10 ms is not');

  Check(StrComp(FrequencySourceName(FrequencyFromHpet), 'measured against the HPET') = 0, 'names: HPET');
end;

procedure MakeRead(out Read: TBracketedRead; Before, After, Ticks: QWord);
begin
  Read.CounterBefore := Before;
  Read.CounterAfter := After;
  Read.ReferenceTicks := Ticks;
end;

procedure TestCalibrationSamples;
const
  { A 3 GHz counter against a reference read as nanoseconds. }
  Hertz = 3000000000;
var
  Best: TBracketedRead;
  Candidate: TBracketedRead;
  HaveBest: Boolean;
  Start: TBracketedRead;
  Finish: TBracketedRead;
  Sample: TCalibrationSample;
  Stalled: TCalibrationSample;
  Rates: TSampleRates;
begin
  MakeRead(Candidate, 1000, 1300, 7);
  Check(BracketWidth(Candidate) = 300, 'brackets: width');
  Check(BracketMiddle(Candidate) = 1150, 'brackets: middle');
  HaveBest := False;
  KeepNarrowerBracket(Best, HaveBest, Candidate);
  Check(HaveBest and (Best.ReferenceTicks = 7), 'brackets: the first read is kept');
  MakeRead(Candidate, 2000, 2100, 8);
  KeepNarrowerBracket(Best, HaveBest, Candidate);
  Check(Best.ReferenceTicks = 8, 'brackets: a narrower read replaces it');
  MakeRead(Candidate, 3000, 9000, 9);
  KeepNarrowerBracket(Best, HaveBest, Candidate);
  Check(Best.ReferenceTicks = 8, 'brackets: a wider read does not');

  { 10 ms: 30,000,000 cycles between the middles. }
  MakeRead(Start, 1000000, 1000200, 0);
  MakeRead(Finish, 31000000, 31000200, 0);
  MakeCalibrationSample(Start, Finish, 10000000, Sample);
  Check(Sample.Cycles = 30000000, 'samples: cycles between the middles');
  Check(Sample.UncertaintyCycles = 201, 'samples: half of each width');
  Check(SampleHertz(Sample) = Hertz, 'samples: the rate');
  Check(SampleIsSteady(Sample, 1000), 'samples: narrow brackets are steady');

  { The processor was held up 3 ms inside the start's bracket (between
    the reference read and the counter read): the bracket shows it. }
  MakeRead(Start, 1000000, 10000200, 0);
  MakeCalibrationSample(Start, Finish, 10000000, Stalled);
  Check(not SampleIsSteady(Stalled, 1000), 'samples: a stall between the reads is refused');
  Check(SampleIsSteadier(Sample, Stalled), 'samples: the narrow one is steadier');
  Check(not SampleIsSteadier(Stalled, Sample), 'samples: the stalled one is not');
  Check(UncertaintyIsWithin(1000000, 1000, 1000), 'samples: 1000 ppm is within 1000 ppm');
  Check(not UncertaintyIsWithin(1000000, 1001, 1000), 'samples: past 1000 ppm is not');
  Check(not UncertaintyIsWithin(0, 0, 1000), 'samples: no cycles is never within');
  Sample.ReferenceNanoseconds := 0;
  Check(SampleHertz(Sample) = 0, 'samples: no time measured, no rate');
  Check(not SampleIsSteady(Sample, 1000), 'samples: no time measured is not steady');
  { Large counts do not overflow: 100 s at 3 GHz. }
  MakeRead(Start, 0, 0, 0);
  MakeRead(Finish, QWord(300000000000), QWord(300000000000), 0);
  MakeCalibrationSample(Start, Finish, QWord(100000000000), Sample);
  Check(SampleHertz(Sample) = Hertz, 'samples: a long sample');

  Rates[0] := 2918000000;
  Rates[1] := 2214000000;
  Rates[2] := 2917000000;
  Rates[3] := 3500000000;
  Rates[4] := 2919000000;
  Check(MedianRate(Rates, 5) = 2918000000, 'median: two outliers of five are left out');
  Check(Rates[0] = 2214000000, 'median: sorted in place');
  Rates[0] := 10;
  Rates[1] := 21;
  Check(MedianRate(Rates, 2) = 15, 'median: the mean of the middle two');
  Rates[0] := 7;
  Check(MedianRate(Rates, 1) = 7, 'median: of one');
  Check(MedianRate(Rates, 0) = 0, 'median: of none');
end;

begin
  TestTable;
  TestRegisters;
  TestFrequencies;
  TestCalibrationSamples;
  if Failures > 0 then
  begin
    WriteLn(Format('HPET TEST FAILED: %d of %d checks', [Failures, Checks]));
    Halt(1);
  end;
  WriteLn(Format('HPET TEST PASSED: %d checks', [Checks]));
end.
