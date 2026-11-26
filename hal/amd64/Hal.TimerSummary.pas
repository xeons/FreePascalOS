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
  What the x86-64 HAL tells about its clocks: the boot log's lines
  (which counter the clock reads, each rate and where it came from, the
  HPET's figures) and the description programs get (HalDescribeTimers,
  Kernel.TimerDescription).
}
unit Hal.TimerSummary;

{$mode objfpc}

interface

uses
  Kernel.TimerDescription;

procedure WriteTimerSummary;
procedure DescribePlatformTimers(out Description: TTimerDescription);
{ "HPET comparator 2 (I/O APIC input 2)", or "none". }
procedure DescribeBroadcastTimer(Text: PChar; Capacity: LongWord);

implementation

uses
  Runtime.Text,
  Runtime.Memory,
  Hal.Hpet,
  Hal.HpetTable,
  Hal.HpetEventTimer,
  Hal.ClockCalibration,
  Hal.ClockSources,
  Hal.TimerFrequencies,
  Hal.TimeStampClock,
  Debug.Output;

procedure AppendText(Text: PChar; Addition: PChar; Capacity: LongWord);
var
  Used: PtrUInt;
begin
  Used := TextLength(Text);
  if Used + 1 < Capacity then
    CopyText(Text + Used, Addition, Capacity - Used);
end;

procedure DescribeBroadcastTimer(Text: PChar; Capacity: LongWord);
var
  Route: array[0..47] of Char;
  Number: TNumberText;
begin
  if not HpetEventTimerIsRunning then
  begin
    CopyText(Text, 'none', Capacity);
    Exit;
  end;
  DescribeHpetEventRoute(@Route[0], SizeOf(Route));
  CopyText(Text, 'HPET comparator ', Capacity);
  AppendText(Text, FormatDecimal(QWord(HpetEventComparator), Number), Capacity);
  AppendText(Text, ' (', Capacity);
  AppendText(Text, @Route[0], Capacity);
  AppendText(Text, ')', Capacity);
end;

{ "2899.999 MHz" }
procedure WriteMegahertz(Hertz: QWord);
var
  Number: TNumberText;
begin
  DebugWriteDecimal(Hertz div 1000000);
  DebugWrite('.');
  DebugWrite(FormatUnsigned((Hertz mod 1000000) div 1000, 10, 3, Number));
  DebugWrite(' MHz');
end;

procedure WriteCounterLine(constref Calibration: TTimerCalibration);
begin
  DebugBeginMessage;
  DebugWriteTag('hal');
  DebugWrite('Time stamp counter ');
  WriteMegahertz(Calibration.CounterHertz);
  if TimeStampCounterIsInvariant then
    DebugWrite(' (invariant)')
  else
    DebugWrite(' (not invariant)');
  DebugWrite(', rate: ');
  DebugWrite(FrequencySourceName(Calibration.CounterSource));
  if Calibration.CounterStatedHertz <> 0 then
  begin
    DebugWrite('; stated ');
    WriteMegahertz(Calibration.CounterStatedHertz);
    DebugWrite(' by the ');
    DebugWrite(FrequencySourceName(Calibration.CounterStatedSource));
  end;
  if (Calibration.CounterMeasuredHertz <> 0) and (Calibration.CounterSource <> Calibration.Reference) then
  begin
    DebugWrite(', ');
    WriteMegahertz(Calibration.CounterMeasuredHertz);
    DebugWrite(' ');
    DebugWrite(FrequencySourceName(Calibration.Reference));
  end;
  DebugWriteLine('');
  DebugEndMessage;
end;

procedure WriteLocalTimerLine(constref Calibration: TTimerCalibration);
begin
  DebugBeginMessage;
  DebugWriteTag('hal');
  DebugWrite('Local APIC timer ');
  DebugWriteDecimal(Calibration.LocalTimerHertz div 1000);
  DebugWrite(' kHz, rate: ');
  DebugWrite(FrequencySourceName(Calibration.LocalTimerSource));
  if (Calibration.LocalTimerStatedHertz <> 0) and (Calibration.LocalTimerSource = FrequencyFromTimeStampCounter) then
  begin
    DebugWrite(' (stated ');
    DebugWriteDecimal(Calibration.LocalTimerStatedHertz div 1000);
    DebugWrite(' kHz disagrees)');
  end;
  DebugWriteLine('');
  DebugEndMessage;
end;

procedure WriteHpetLine;
var
  Table: THpetTableInformation;
  Route: array[0..63] of Char;
begin
  DebugBeginMessage;
  DebugWriteTag('hal');
  if not HpetIsPresent then
  begin
    DebugWriteLine('No HPET');
    DebugEndMessage;
    Exit;
  end;
  GetHpetTableInformation(Table);
  DebugWrite('HPET at 0x');
  DebugWriteHex(Table.BaseAddress, 8);
  DebugWrite(': ');
  WriteMegahertz(HpetFrequencyHertz);
  DebugWrite(' (period ');
  DebugWriteDecimal(HpetPeriodFemtoseconds);
  DebugWrite(' fs), ');
  if HpetCounterIs64Bit then
    DebugWrite('64-bit')
  else
    DebugWrite('32-bit');
  DebugWrite(' counter, ');
  DebugWriteDecimal(HpetComparatorTotal);
  DebugWrite(' comparators');
  if HpetIsLegacyCapable then
    DebugWrite(', legacy replacement capable');
  DebugWriteLine('');
  DebugEndMessage;
  if not HpetEventTimerIsRunning then
    Exit;
  DescribeBroadcastTimer(@Route[0], SizeOf(Route));
  DebugBeginMessage;
  DebugWriteTag('hal');
  DebugWrite('Event timer: ');
  DebugWriteLine(@Route[0]);
  DebugEndMessage;
end;

procedure WriteClockLine;
begin
  DebugBeginMessage;
  DebugWriteTag('hal');
  DebugWrite('Clock: ');
  DebugWrite(ClockSourceName);
  if ClockSourceWasForced then
    DebugWrite(' (clocksource option)');
  if ClockSourceIsWatched then
    DebugWrite(', watched against the HPET');
  DebugWriteLine('');
  DebugEndMessage;
end;

procedure WriteTimerSummary;
var
  Calibration: TTimerCalibration;
begin
  GetTimerCalibration(Calibration);
  WriteHpetLine;
  WriteCounterLine(Calibration);
  WriteLocalTimerLine(Calibration);
  WriteClockLine;
end;

procedure DescribePlatformTimers(out Description: TTimerDescription);
var
  Calibration: TTimerCalibration;
  Table: THpetTableInformation;
  Checks: QWord;
  Failures: QWord;
  Largest: QWord;
  FellBack: Boolean;
begin
  ZeroMemory(@Description, SizeOf(Description));
  GetTimerCalibration(Calibration);
  Description.CounterHertz := Calibration.CounterHertz;
  Description.CounterMeasuredHertz := Calibration.CounterMeasuredHertz;
  Description.LocalTimerHertz := Calibration.LocalTimerHertz;
  if TimeStampCounterIsInvariant then
    Description.Flags := Description.Flags or TimerCounterInvariant;
  if ClockSourceWasForced then
    Description.Flags := Description.Flags or TimerClockForced;
  if ClockSourceIsWatched then
    Description.Flags := Description.Flags or TimerClockWatched;
  GetClockWatchdogFigures(Checks, Failures, Largest, FellBack);
  if FellBack then
    Description.Flags := Description.Flags or TimerClockFellBack;
  Description.WatchdogChecks := Checks;
  Description.WatchdogFailures := Failures;
  Description.WatchdogLargestDriftNanoseconds := Largest;
  CopyText(@Description.ClockSource[0], ClockSourceName, TimerNameCapacity);
  CopyText(@Description.CounterCalibration[0], FrequencySourceName(Calibration.CounterSource), TimerNameCapacity);
  CopyText(@Description.LocalTimerCalibration[0], FrequencySourceName(Calibration.LocalTimerSource),
    TimerNameCapacity);
  Description.HpetEventComparator := HpetEventComparator;
  CopyText(@Description.HpetRoute[0], 'none', TimerNameCapacity);
  if not HpetIsPresent then
    Exit;
  GetHpetTableInformation(Table);
  Description.Flags := Description.Flags or TimerHpetPresent;
  if HpetCounterIs64Bit then
  begin
    Description.Flags := Description.Flags or TimerHpet64Bit;
    Description.HpetCounterBits := 64;
  end
  else
    Description.HpetCounterBits := 32;
  if HpetIsLegacyCapable then
    Description.Flags := Description.Flags or TimerHpetLegacyCapable;
  if HpetLegacyReplacementIsOn then
    Description.Flags := Description.Flags or TimerHpetLegacyInUse;
  if HpetEventTimerIsRunning then
  begin
    Description.Flags := Description.Flags or TimerBroadcastTimerAvailable;
    DescribeHpetEventRoute(@Description.HpetRoute[0], TimerNameCapacity);
  end;
  Description.HpetComparators := HpetComparatorTotal;
  Description.HpetPeriodFemtoseconds := HpetPeriodFemtoseconds;
  Description.HpetMinimumTick := Table.MinimumTick;
  Description.HpetVendorId := Table.VendorId;
  Description.HpetBaseAddress := Table.BaseAddress;
  Description.HpetInterrupts := HpetEventInterruptCount;
end;

end.
