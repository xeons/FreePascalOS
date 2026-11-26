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
  What the HAL says about its clocks and timers (HalDescribeTimers):
  which counter the clock reads, how the counter's and the local
  timer's rates were found, and the HPET's figures on x86-64. The clock
  information call (CallGetClockInformation) passes it on to programs.
}
unit Kernel.TimerDescription;

{$mode objfpc}

interface

const
  TimerNameCapacity = 48;

  { TTimerDescription.Flags }
  TimerCounterInvariant = $0001;
  TimerHpetPresent = $0002;
  TimerHpet64Bit = $0004;
  TimerHpetLegacyCapable = $0008;
  TimerHpetLegacyInUse = $0010;
  TimerClockForced = $0020;
  TimerClockWatched = $0040;
  TimerClockFellBack = $0080;
  TimerBroadcastTimerAvailable = $0100;

type
  TTimerDescription = record
    Flags: LongWord;
    HpetComparators: LongWord;
    { The clock's counter (time stamp counter, generic timer): its rate,
      and what it measured against the reference (0 if not measured). }
    CounterHertz: QWord;
    CounterMeasuredHertz: QWord;
    { The per-processor clock interrupt's timer. }
    LocalTimerHertz: QWord;
    HpetPeriodFemtoseconds: QWord;
    HpetMinimumTick: LongWord;
    HpetVendorId: LongWord;
    HpetBaseAddress: QWord;
    { The comparator of the event timer (-1: none) and its interrupts. }
    HpetEventComparator: LongInt;
    HpetCounterBits: LongWord;
    HpetInterrupts: QWord;
    WatchdogChecks: QWord;
    WatchdogFailures: QWord;
    WatchdogLargestDriftNanoseconds: QWord;
    ClockSource: array[0..TimerNameCapacity - 1] of Char;
    CounterCalibration: array[0..TimerNameCapacity - 1] of Char;
    LocalTimerCalibration: array[0..TimerNameCapacity - 1] of Char;
    HpetRoute: array[0..TimerNameCapacity - 1] of Char;
  end;

implementation

end.
