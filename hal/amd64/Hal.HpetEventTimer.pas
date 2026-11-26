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
  One HPET comparator as an event timer: the broadcast timer that wakes
  processors whose local APIC timer stops in deep idle states
  (Kernel.BroadcastTimer).

  A single shared comparator, not one per processor: the kernel keeps
  the processors' due times in its table and asks for the earliest
  (SetHpetEventAt, clock nanoseconds); the interrupt goes to the boot
  processor (on PlatformTimerInterruptVector, at the clock's level, by
  the route Hal.HpetInterrupts found) which wakes every processor due.
  Per-processor comparators would need as many comparators with
  message delivery as processors, which few chipsets have, and would
  save only the wake-up's inter-processor interrupt.

  The comparator is used one-shot: the deadline becomes a number of
  ticks (at least 192, as Linux finds some chipsets need), added to the
  counter's low half and written. If the counter is already past it (or
  within 128 ticks) when read back, the match may have been missed, so
  it is written again further ahead, doubling each time. After it fired
  and nothing else is asked for, its interrupt is turned off (a 32-bit
  comparator would match again on the counter's next wrap).

  Requests come from any processor with interrupts disabled (the idle
  loop) and from the interrupt itself: one lock, taken with interrupts
  disabled, keeps the comparator's value and configuration together.

  For the self tests (Kernel.Arch.PlatformSelfTest): a one-shot test
  deadline, taken together with the kernel's (the earlier of the two is
  programmed), whose arrival time is recorded; and a periodic run (where
  the comparator can) that counts its interrupts. While it runs, the
  kernel's requests are only noted (the periodic interrupt serves them
  anyway); afterwards the comparator goes back to one-shot at the
  kernel's deadline.

  After suspend to RAM (Hal.Hpet restores the registers) the comparator
  is set again from the kernel's deadline.
}
unit Hal.HpetEventTimer;

{$mode objfpc}

interface

type
  { Called on the boot processor, at the clock's level, with the clock's
    time. }
  THpetEventHandler = procedure(Now: QWord);

{ Picks and routes the comparator (to the executing processor: call on
  the boot processor, once device interrupts can be routed). }
function StartHpetEventTimer: Boolean;
function HpetEventTimerIsRunning: Boolean;
procedure SetHpetEventHandler(NewHandler: THpetEventHandler);
{ The next interrupt at Deadline (a clock time; NeverDue: none). }
procedure SetHpetEventAt(Deadline: QWord);
function HpetEventComparator: LongInt;
procedure DescribeHpetEventRoute(Text: PChar; Capacity: LongWord);
function HpetEventInterruptCount: QWord;
{ After waking from suspend to RAM. }
procedure ResumeHpetEventTimer;

{ The self tests. }
procedure StartHpetOneShotTest(DelayNanoseconds: QWord);
{ True once the test interrupt came, with how late it was. }
function HpetOneShotTestResult(out LatenessNanoseconds: QWord): Boolean;
procedure CancelHpetOneShotTest;
{ False if the comparator cannot run periodically. }
function StartHpetPeriodicTest(PeriodNanoseconds: QWord): Boolean;
{ Back to one-shot; the interrupts counted. }
function StopHpetPeriodicTest: QWord;

implementation

uses
  Runtime.Atomic,
  Kernel.Arch.Cpu,
  Kernel.Arch.TrapFrame,
  Kernel.Interrupts,
  Kernel.SpinLock,
  Hal.Hpet,
  Hal.HpetMath,
  Hal.HpetInterrupts,
  Hal.InterruptVectors,
  Hal.LocalApic,
  Hal.ClockSources;

const
  NeverDue = High(QWord);
  MinimumTicks = 192;
  MissMarginTicks = 128;
  { 2^30 ticks: well within a 32-bit comparator's reach. }
  MaximumTicks = QWord(1) shl 30;
  ProgramAttempts = 8;
  CheckDelayNanoseconds = 1000000;
  CheckWaitNanoseconds = 50000000;
  CheckRounds = 3;
  TimelyNanoseconds = 2000000;

var
  Running: Boolean = False;
  Route: THpetRoute;
  EventLock: TSpinLock;
  Handler: THpetEventHandler = nil;
  { The comparator's configuration with its interrupt off. }
  BaseConfiguration: LongWord = 0;
  InterruptOn: Boolean = False;
  KernelDeadline: QWord = NeverDue;
  TestDeadline: QWord = NeverDue;
  TestRequested: QWord = 0;
  TestArrival: QWord = 0;
  TestFired: Boolean = False;
  PeriodicRunning: Boolean = False;
  PeriodicCount: Int64 = 0;
  InterruptCount: Int64 = 0;

procedure TurnInterruptOff;
begin
  if InterruptOn then
  begin
    WriteHpetComparatorConfiguration(Route.Comparator, BaseConfiguration);
    InterruptOn := False;
  end;
end;

{ The comparator's next match Ticks from now, written again further on
  while it may have been missed. }
procedure ArmInTicks(Ticks: QWord);
var
  Attempt: Integer;
  Target: LongWord;
begin
  if Ticks < MinimumTicks then
    Ticks := MinimumTicks;
  if Ticks > MaximumTicks then
    Ticks := MaximumTicks;
  for Attempt := 1 to ProgramAttempts do
  begin
    Target := LongWord((QWord(ReadHpetCounterLow) + Ticks) and $FFFFFFFF);
    WriteHpetComparator(Route.Comparator, Target);
    if not InterruptOn then
    begin
      WriteHpetComparatorConfiguration(Route.Comparator, BaseConfiguration or ComparatorInterruptEnable);
      InterruptOn := True;
    end;
    if not ComparatorWasMissed(Target, ReadHpetCounterLow, MissMarginTicks) then
      Exit;
    Ticks := Ticks * 2;
  end;
end;

{ Programs the earlier of the kernel's and the test's deadlines; the
  lock is held. }
procedure ProgramLocked;
var
  Deadline: QWord;
  Now: QWord;
begin
  if PeriodicRunning then
    Exit;
  Deadline := KernelDeadline;
  if TestDeadline < Deadline then
    Deadline := TestDeadline;
  if Deadline = NeverDue then
  begin
    TurnInterruptOff;
    Exit;
  end;
  Now := ClockSourceNanoseconds;
  if Deadline > Now then
    ArmInTicks(HpetNanosecondsToTicks(Deadline - Now, HpetPeriodFemtoseconds))
  else
    ArmInTicks(MinimumTicks);
end;

function Lock: Boolean;
begin
  Result := SaveAndDisableInterrupts;
  AcquireSpinLockAtCurrentLevel(EventLock);
end;

procedure Unlock(WereEnabled: Boolean);
begin
  ReleaseSpinLockAtCurrentLevel(EventLock);
  RestoreInterrupts(WereEnabled);
end;

procedure HandleEventInterrupt(Frame: PTrapFrame; Context: Pointer);
var
  Now: QWord;
  WereEnabled: Boolean;
  Current: THpetEventHandler;
begin
  AtomicIncrement(InterruptCount);
  Now := ClockSourceNanoseconds;
  WereEnabled := Lock;
  if PeriodicRunning then
    Inc(PeriodicCount);
  if (TestDeadline <> NeverDue) and (Now >= TestDeadline) then
  begin
    TestArrival := Now;
    TestFired := True;
    TestDeadline := NeverDue;
  end;
  { The kernel asks again for what is still to come. }
  KernelDeadline := NeverDue;
  ProgramLocked;
  Unlock(WereEnabled);
  Current := Handler;
  if Assigned(Current) then
    Current(Now);
end;

{ One match CheckDelayNanoseconds ahead on the route set up: True if
  its interrupt came within CheckWaitNanoseconds, and how late. }
function CheckOnce(out LatenessNanoseconds: QWord): Boolean;
var
  Deadline: QWord;
  WereEnabled: Boolean;
begin
  WereEnabled := Lock;
  TestFired := False;
  TestDeadline := ClockSourceNanoseconds + CheckDelayNanoseconds;
  TestRequested := TestDeadline;
  ProgramLocked;
  Unlock(WereEnabled);
  Deadline := TestRequested + CheckWaitNanoseconds;
  while not TestFired and (ClockSourceNanoseconds < Deadline) do
    CpuRelax;
  WereEnabled := Lock;
  Result := TestFired;
  LatenessNanoseconds := TestArrival - TestRequested;
  TestFired := False;
  TestDeadline := NeverDue;
  ProgramLocked;
  Unlock(WereEnabled);
end;

{ A way to route the comparator, set up (Hal.HpetInterrupts): its
  interrupt must come, and when Strict, CheckRounds times no more than
  TimelyNanoseconds late. With interrupts off it cannot be checked, and
  is taken as it is. }
function CheckRoute(constref Candidate: THpetRoute; Strict: Boolean): Boolean;
var
  Round: Integer;
  Lateness: QWord;
begin
  if not InterruptsAreEnabled then
    Exit(True);
  Route := Candidate;
  BaseConfiguration := Candidate.ConfigurationBits;
  WriteHpetComparatorConfiguration(Route.Comparator, BaseConfiguration);
  InterruptOn := False;
  for Round := 1 to CheckRounds do
  begin
    if not CheckOnce(Lateness) then
      Exit(False);
    if not Strict then
      Exit(True);
    if Lateness > TimelyNanoseconds then
      Exit(False);
  end;
  Result := True;
end;

function StartHpetEventTimer: Boolean;
begin
  Result := False;
  if Running or not HpetIsPresent then
    Exit(Running);
  InitializeSpinLock(EventLock);
  if not RegisterInterruptHandler(PlatformTimerInterruptVector, @HandleEventInterrupt, nil) then
    Exit;
  if not RouteHpetEventComparator(PlatformTimerInterruptVector, LocalApicId, @CheckRoute, Route) then
  begin
    UnregisterInterruptHandler(PlatformTimerInterruptVector);
    Exit;
  end;
  BaseConfiguration := Route.ConfigurationBits;
  WriteHpetComparatorConfiguration(Route.Comparator, BaseConfiguration);
  InterruptOn := False;
  Running := True;
  Result := True;
end;

function HpetEventTimerIsRunning: Boolean;
begin
  Result := Running;
end;

procedure SetHpetEventHandler(NewHandler: THpetEventHandler);
begin
  Handler := NewHandler;
end;

procedure SetHpetEventAt(Deadline: QWord);
var
  WereEnabled: Boolean;
begin
  if not Running then
    Exit;
  WereEnabled := Lock;
  KernelDeadline := Deadline;
  ProgramLocked;
  Unlock(WereEnabled);
end;

function HpetEventComparator: LongInt;
begin
  if Running then
    Result := LongInt(Route.Comparator)
  else
    Result := -1;
end;

procedure DescribeHpetEventRoute(Text: PChar; Capacity: LongWord);
begin
  DescribeHpetRoute(Route, Text, Capacity);
end;

function HpetEventInterruptCount: QWord;
begin
  Result := QWord(AtomicFetchAndAdd(InterruptCount, 0));
end;

procedure ResumeHpetEventTimer;
var
  WereEnabled: Boolean;
begin
  if not Running then
    Exit;
  WereEnabled := Lock;
  PeriodicRunning := False;
  { Restored as it was saved; set afresh. }
  WriteHpetComparatorConfiguration(Route.Comparator, BaseConfiguration);
  InterruptOn := False;
  if Route.Kind = HpetRouteLegacy then
    SetHpetLegacyReplacement(True);
  ProgramLocked;
  Unlock(WereEnabled);
end;

procedure StartHpetOneShotTest(DelayNanoseconds: QWord);
var
  WereEnabled: Boolean;
begin
  if not Running then
    Exit;
  WereEnabled := Lock;
  TestFired := False;
  TestDeadline := ClockSourceNanoseconds + DelayNanoseconds;
  TestRequested := TestDeadline;
  ProgramLocked;
  Unlock(WereEnabled);
end;

function HpetOneShotTestResult(out LatenessNanoseconds: QWord): Boolean;
var
  WereEnabled: Boolean;
begin
  LatenessNanoseconds := 0;
  WereEnabled := Lock;
  Result := TestFired;
  if Result then
    LatenessNanoseconds := TestArrival - TestRequested;
  Unlock(WereEnabled);
end;

procedure CancelHpetOneShotTest;
var
  WereEnabled: Boolean;
begin
  if not Running then
    Exit;
  WereEnabled := Lock;
  TestDeadline := NeverDue;
  ProgramLocked;
  Unlock(WereEnabled);
end;

function StartHpetPeriodicTest(PeriodNanoseconds: QWord): Boolean;
var
  WereEnabled: Boolean;
  Ticks: QWord;
  Configuration: LongWord;
begin
  Result := Running and ((HpetComparatorConfiguration(Route.Comparator) and ComparatorPeriodicCapable) <> 0);
  if not Result then
    Exit;
  Ticks := HpetNanosecondsToTicks(PeriodNanoseconds, HpetPeriodFemtoseconds);
  if Ticks < MinimumTicks then
    Ticks := MinimumTicks;
  if Ticks > MaximumTicks then
    Ticks := MaximumTicks;
  WereEnabled := Lock;
  PeriodicCount := 0;
  PeriodicRunning := True;
  { Value set: the first write is the first match, the second the
    period added after each. }
  Configuration := BaseConfiguration or ComparatorInterruptEnable or ComparatorPeriodic or ComparatorValueSet;
  WriteHpetComparatorConfiguration(Route.Comparator, Configuration);
  WriteHpetComparator(Route.Comparator, LongWord((QWord(ReadHpetCounterLow) + Ticks) and $FFFFFFFF));
  WriteHpetComparator(Route.Comparator, LongWord(Ticks));
  InterruptOn := True;
  Unlock(WereEnabled);
end;

function StopHpetPeriodicTest: QWord;
var
  WereEnabled: Boolean;
begin
  WereEnabled := Lock;
  Result := QWord(PeriodicCount);
  if PeriodicRunning then
  begin
    PeriodicRunning := False;
    WriteHpetComparatorConfiguration(Route.Comparator, BaseConfiguration);
    InterruptOn := False;
    ProgramLocked;
  end;
  Unlock(WereEnabled);
end;

end.
