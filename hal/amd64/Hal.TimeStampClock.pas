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
  A clock in nanoseconds from the processor's time stamp counter.

  The time stamp counter counts at a fixed rate, measured once at start
  (against the interval timer, see Hal.Platform), and is read in a few
  cycles on any processor without a lock, which makes it the kernel's
  fine clock: the uptime, timers and timeouts are all measured with it.

  The counters of all processors are taken to run together (they do on
  machines with an invariant counter, and in virtual machines). An
  invariant counter (CPUID 8000_0007h EDX bit 8) also runs at the same
  rate in every power state; one that is not may stop in deep idle
  states, so Kernel.Arch.IdleStates then keeps to HLT, and under KVM
  the paravirtual clock is the kernel's clock instead (Hal.Platform,
  Hal.ParavirtualClock). Suspend
  to RAM turns the counter off and may start it again from zero, so the
  clock is paused before sleeping and continues from where it stopped
  after waking: like the uptime, it does not count the time asleep.
}
unit Hal.TimeStampClock;

{$mode objfpc}

interface

{ Starts the clock at zero, with the counter running at CyclesPerSecond. }
procedure StartTimeStampClock(CyclesPerSecond: QWord);

{ CPUID says the counter is invariant: a constant rate in every
  power and performance state. }
function TimeStampCounterIsInvariant: Boolean;

{ Nanoseconds since the clock started (0 before it did). }
function TimeStampClockNanoseconds: QWord;

{ Before sleeping: remembers the time. After waking (before any other
  processor runs): continues from it, whatever the counter says now. }
procedure PauseTimeStampClock;
procedure ContinueTimeStampClock;

implementation

uses
  Kernel.Arch.Cpu;

const
  NanosecondsPerSecond = 1000000000;

var
  Frequency: QWord = 0;
  { The counter's value when the clock read StartNanoseconds. }
  StartCount: QWord = 0;
  StartNanoseconds: QWord = 0;
  PausedNanoseconds: QWord = 0;

function TimeStampCounterIsInvariant: Boolean;
const
  PowerManagementLeaf = $80000007;
  InvariantCounterBit = LongWord(1) shl 8;
var
  Registers: TCpuidResult;
begin
  ExecuteCpuid($80000000, 0, Registers);
  if Registers.Eax < PowerManagementLeaf then
    Exit(False);
  ExecuteCpuid(PowerManagementLeaf, 0, Registers);
  Result := (Registers.Edx and InvariantCounterBit) <> 0;
end;

procedure StartTimeStampClock(CyclesPerSecond: QWord);
begin
  StartCount := ReadTimeStampCounter;
  StartNanoseconds := 0;
  Frequency := CyclesPerSecond;
end;

function TimeStampClockNanoseconds: QWord;
var
  Count: QWord;
  Elapsed: QWord;
begin
  if Frequency = 0 then
    Exit(0);
  Count := ReadTimeStampCounter;
  { Another processor's counter may be a few cycles behind the one the
    start was read on. }
  if Count <= StartCount then
    Exit(StartNanoseconds);
  Elapsed := Count - StartCount;
  { In two parts, so that the multiplication cannot overflow: whole
    seconds, then the rest (less than one second's cycles, times 10^9,
    fits in 64 bits for any counter below 18 GHz). }
  Result := StartNanoseconds + (Elapsed div Frequency) * NanosecondsPerSecond +
    ((Elapsed mod Frequency) * NanosecondsPerSecond) div Frequency;
end;

procedure PauseTimeStampClock;
begin
  PausedNanoseconds := TimeStampClockNanoseconds;
end;

procedure ContinueTimeStampClock;
begin
  StartCount := ReadTimeStampCounter;
  StartNanoseconds := PausedNanoseconds;
end;

end.
