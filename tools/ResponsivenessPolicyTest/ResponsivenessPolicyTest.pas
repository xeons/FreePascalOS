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
  ResponsivenessPolicyTest

  The rules that keep the system usable whatever one program does, on
  the host:

  * priority classes (Kernel.PriorityClasses): the base priority of each
    class and nice value, the ordering display server > desktop >
    program > renderer, who may set which class, what is inherited;
  * fair share (Kernel.FairShare): the decayed run time of a group and
    the processors it says were used, the penalty, the priority after a
    used up slice; and a small simulation of a process with eight busy
    threads on four processors next to a single thread program: the
    busy one is pushed below the other's base within a second and
    comes back once it calms down;
  * the memory reserves (Memory.Reserves): which page allocations are
    refused near the critical watermark, the system commit limit and
    the essential processes' part of it;
  * the thrash guard (Memory.ThrashGuard): its rate, bucket and refill.

  Prints every failed check and exits with 1 if there was one.
}
program ResponsivenessPolicyTest;

{$mode objfpc}

uses
  SysUtils,
  Abi.SystemCalls,
  Kernel.PriorityBoosts,
  Kernel.PriorityClasses,
  Kernel.FairShare,
  Memory.Reserves,
  Memory.ThrashGuard;

const
  Millisecond = QWord(1000000);
  Second = QWord(1000) * Millisecond;

var
  Failures: Integer = 0;

procedure Check(Condition: Boolean; const What: string);
begin
  if not Condition then
  begin
    WriteLn('FAIL: ', What);
    Inc(Failures);
  end;
end;

{ --- Priority classes ---------------------------------------------------- }

procedure TestClassPriorities;
var
  PriorityClass: LongWord;
  Nice: LongInt;
  Priority: LongWord;
begin
  Check(ThreadBasePriority(PriorityClassNormal, 0) = 8, 'normal, nice 0 is 8 (as before classes)');
  Check(ThreadBasePriority(PriorityClassNormal, -20) = 13, 'normal, nice -20 is 13 (as before)');
  Check(ThreadBasePriority(PriorityClassNormal, 19) = 4, 'normal, nice 19 is 4 (as before)');
  Check(ThreadBasePriority(PriorityClassSystem, 0) = 12, 'the display server runs at 12');
  Check(ThreadBasePriority(PriorityClassInteractive, 0) = 10, 'the desktop runs at 10');
  Check(ThreadBasePriority(PriorityClassBackground, 0) = 6, 'a shown page runs at 6');
  Check(ThreadBasePriority(PriorityClassIdle, 0) = 4, 'a hidden page runs at 4');
  Check(ThreadBasePriority(PriorityClassSystem, 0) > ThreadBasePriority(PriorityClassInteractive, 0),
    'the display server above the desktop');
  Check(ThreadBasePriority(PriorityClassInteractive, 0) > ThreadBasePriority(PriorityClassNormal, 0),
    'the desktop above programs');
  Check(ThreadBasePriority(PriorityClassNormal, 0) > ThreadBasePriority(PriorityClassBackground, 0),
    'the browser window above its pages');
  { A program at nice 0 boosted by an event (+1) still stays below the
    display server's base, and below the desktop's. }
  Check(BoostedPriority(8, 8, BoostEvent) < ThreadBasePriority(PriorityClassInteractive, 0),
    'an event boost does not take a program past the desktop');
  for PriorityClass := PriorityClassIdle to PriorityClassHighest do
    for Nice := NiceLowest to NiceHighest do
    begin
      Priority := ThreadBasePriority(PriorityClass, Nice);
      Check((Priority >= 1) and (Priority <= HighestVariablePriority),
        Format('class %d nice %d left the variable class (%d)', [PriorityClass, Nice, Priority]));
    end;
  Check(ThreadBasePriority(99, 0) = 8, 'an unknown class counts as normal');
end;

procedure TestClassRules;
begin
  Check(MaySetPriorityClass(False, PriorityClassNormal, PriorityClassBackground), 'anyone may go below normal');
  Check(MaySetPriorityClass(False, PriorityClassIdle, PriorityClassNormal), 'anyone may come back to normal');
  Check(not MaySetPriorityClass(False, PriorityClassNormal, PriorityClassInteractive),
    'a program may not make itself interactive');
  Check(not MaySetPriorityClass(False, PriorityClassNormal, PriorityClassSystem), 'nor system');
  Check(MaySetPriorityClass(False, PriorityClassInteractive, PriorityClassInteractive),
    'the desktop may give the task manager its class');
  Check(not MaySetPriorityClass(False, PriorityClassInteractive, PriorityClassSystem),
    'but not the system class');
  Check(MaySetPriorityClass(True, PriorityClassNormal, PriorityClassSystem), 'root may set any class');
  Check(not MaySetPriorityClass(True, PriorityClassNormal, 7), 'no one may set an unknown class');
  Check(InheritedPriorityClass(PriorityClassIdle) = PriorityClassIdle, 'idle is inherited');
  Check(InheritedPriorityClass(PriorityClassBackground) = PriorityClassBackground, 'background is inherited');
  Check(InheritedPriorityClass(PriorityClassInteractive) = PriorityClassNormal,
    'what the desktop starts is an ordinary program');
  Check(InheritedPriorityClass(PriorityClassSystem) = PriorityClassNormal, 'so is what the display server starts');
  Check(IsEssentialPriorityClass(PriorityClassInteractive) and IsEssentialPriorityClass(PriorityClassSystem),
    'interactive and system are essential');
  Check(not IsEssentialPriorityClass(PriorityClassNormal), 'programs are not');
end;

{ --- Fair share ---------------------------------------------------------- }

procedure TestDecay;
var
  Usage: TFairShareUsage;
  HalfLife: QWord;
  Now: QWord;
begin
  HalfLife := FairShareHalfLifeNanoseconds;
  Usage.DecayedNanoseconds := 0;
  Usage.LastUpdate := 0;
  AddFairShareRunTime(Usage, Second, 10 * HalfLife);
  Check(Usage.DecayedNanoseconds = Second, 'run time is added');
  DecayFairShareUsage(Usage, 11 * HalfLife);
  Check(Usage.DecayedNanoseconds = Second div 2, 'halved after a half-life');
  DecayFairShareUsage(Usage, 13 * HalfLife);
  Check(Usage.DecayedNanoseconds = Second div 8, 'an eighth after three');
  DecayFairShareUsage(Usage, 200 * Second);
  Check(Usage.DecayedNanoseconds = 0, 'gone after long enough');
  Usage.DecayedNanoseconds := Second;
  Usage.LastUpdate := 0;
  DecayFairShareUsage(Usage, HalfLife div 2);
  Check((Usage.DecayedNanoseconds > Second * 70 div 100) and (Usage.DecayedNanoseconds < Second * 71 div 100),
    'half a half-life leaves about 71% (' + IntToStr(Usage.DecayedNanoseconds) + ')');
  DecayFairShareUsage(Usage, HalfLife div 4);
  Check((Usage.DecayedNanoseconds > Second * 70 div 100), 'time going back decays nothing');
  { Charges a millisecond apart still decay (the remainder is kept). }
  Usage.DecayedNanoseconds := Second;
  Usage.LastUpdate := 0;
  Now := 0;
  while Now < HalfLife do
  begin
    Now := Now + Millisecond;
    DecayFairShareUsage(Usage, Now);
  end;
  Check((Usage.DecayedNanoseconds > Second * 49 div 100) and (Usage.DecayedNanoseconds < Second * 51 div 100),
    'many small steps decay as one (' + IntToStr(Usage.DecayedNanoseconds) + ')');
end;

{ A group running on Processors processors all the time, charged every
  10 ms, settles at that many processors used. }
procedure TestSteadyState;
var
  Usage: TFairShareUsage;
  Now: QWord;
  Used: QWord;
  Processors: QWord;
begin
  for Processors := 1 to 4 do
  begin
    Usage.DecayedNanoseconds := 0;
    Usage.LastUpdate := 0;
    Now := 0;
    while Now < 20 * Second do
    begin
      Now := Now + 10 * Millisecond;
      AddFairShareRunTime(Usage, Processors * 10 * Millisecond, Now);
    end;
    Used := ProcessorsUsedThousandths(Usage, Now);
    Check((Used >= Processors * 950) and (Used <= Processors * 1050),
      Format('%d busy processors read as %d thousandths', [Processors, Used]));
  end;
end;

procedure TestPenalty;
begin
  Check(FairSharePenalty(1000, 1) = 0, 'one processor kept busy on one: no penalty');
  Check(FairSharePenalty(1000, 4) = 0, 'one processor of four: no penalty');
  Check(FairSharePenalty(2000, 4) = 0, 'half of four: no penalty');
  Check(FairSharePenalty(2100, 4) = 1, 'just over half of four: one level');
  Check(FairSharePenalty(3100, 4) = 2, 'three of four: two levels');
  Check(FairSharePenalty(4000, 4) = MaximumFairSharePenalty, 'all four: the most');
  Check(FairSharePenalty(1500, 2) = 1, 'one and a half of two: one level');
  Check(FairSharePenalty(64000, 64) = MaximumFairSharePenalty, 'all of 64: the most');
  Check(FairSharePenalty(32000, 64) = 0, 'half of 64: none');
  Check(FairSharePenalty(1000, 0) = 0, 'no processor count counts as one');
  Check(FairSharePriority(8, 8, 2) = 6, 'at its base a penalised thread goes below it');
  Check(FairSharePriority(8, 10, 2) = 10, 'a boost is kept');
  Check(FairSharePriority(8, 8, 0) = 8, 'no penalty, no change');
  Check(FairSharePriority(1, 1, 2) = 1, 'never below priority 1');
  Check(FairSharePriority(2, 2, 2) = 1, 'never below priority 1 (base 2)');
  Check(FairSharePriority(16, 16, 2) = 16, 'the real-time class has no penalty');
end;

{ Four processors; process A has eight threads that never wait, process
  B one thread at the same base that also never waits. Each 10 ms tick
  every processor runs the most important ready thread (round robin
  among equals); a thread whose slice (two ticks) is used up has its
  priority recomputed as the scheduler does. }
procedure TestBusyProcessBesideAnother;
const
  Processors = 4;
  BusyThreads = 8;
  Tick = 10 * Millisecond;
  Base = 8;
var
  Usage: TFairShareUsage;
  Priorities: array[0..BusyThreads] of LongWord;
  Runs: array[0..BusyThreads] of QWord;
  Slices: array[0..BusyThreads] of Integer;
  Order: array[0..BusyThreads] of Integer;
  Now: QWord;
  Thread: Integer;
  Chosen: Integer;
  Slot: Integer;
  Best: Integer;
  Candidate: Integer;
  Next: Integer;
  Taken: array[0..BusyThreads] of Boolean;
  BusyRanThisTick: QWord;
  Penalty: LongWord;
  LoneShareBefore: QWord;
  LoneRunsAtStart: QWord;
  WasBelowBase: Boolean;
begin
  Usage.DecayedNanoseconds := 0;
  Usage.LastUpdate := 0;
  for Thread := 0 to BusyThreads do
  begin
    Priorities[Thread] := Base;
    Runs[Thread] := 0;
    Slices[Thread] := 0;
    Order[Thread] := Thread;
  end;
  Next := 0;
  Now := 0;
  WasBelowBase := False;
  LoneRunsAtStart := 0;
  LoneShareBefore := 0;
  { Thread BusyThreads is process B's. }
  while Now < 4 * Second do
  begin
    Now := Now + Tick;
    for Thread := 0 to BusyThreads do
      Taken[Thread] := False;
    BusyRanThisTick := 0;
    for Slot := 0 to Processors - 1 do
    begin
      Best := -1;
      for Chosen := 0 to BusyThreads do
      begin
        Candidate := Order[(Next + Chosen) mod (BusyThreads + 1)];
        if Taken[Candidate] then
          Continue;
        if (Best < 0) or (Priorities[Candidate] > Priorities[Best]) then
          Best := Candidate;
      end;
      Taken[Best] := True;
      Inc(Runs[Best]);
      if Best < BusyThreads then
        Inc(BusyRanThisTick);
    end;
    Next := (Next + Processors) mod (BusyThreads + 1);
    AddFairShareRunTime(Usage, BusyRanThisTick * Tick, Now);
    Penalty := FairSharePenalty(ProcessorsUsedThousandths(Usage, Now), Processors);
    for Thread := 0 to BusyThreads do
      if Taken[Thread] then
      begin
        Inc(Slices[Thread]);
        if Slices[Thread] >= 2 then
        begin
          Slices[Thread] := 0;
          if Thread < BusyThreads then
            Priorities[Thread] := FairSharePriority(Base, DecayedPriority(Base, Priorities[Thread]), Penalty)
          else
            Priorities[Thread] := DecayedPriority(Base, Priorities[Thread]);
        end;
      end;
    if Priorities[0] < Base then
      WasBelowBase := True;
    if Now = Second then
    begin
      LoneRunsAtStart := Runs[BusyThreads];
      Check(WasBelowBase, 'the busy process went below its base within a second');
    end;
  end;
  { From the second second on, process B's thread should run every tick
    (it is above every penalised thread). }
  LoneShareBefore := Runs[BusyThreads] - LoneRunsAtStart;
  Check(LoneShareBefore >= 3 * Second div Tick * 9 div 10,
    Format('the single thread program ran %d of %d ticks beside the busy one', [LoneShareBefore,
      3 * Second div Tick]));
  { Without fair share it would have had about 4/9 of them. }
  Check(LoneShareBefore > 3 * Second div Tick * 4 div 9 + 50, 'more than its share without fair share');
  { The busy process still used the other three processors. }
  Check(Runs[0] + Runs[1] + Runs[2] + Runs[3] + Runs[4] + Runs[5] + Runs[6] + Runs[7] >=
    3 * (4 * Second div Tick) * 9 div 10, 'the busy process still gets the processors left over');
  { It calms down (waits): the decayed usage falls and so does the
    penalty. }
  Now := Now + 3 * Second;
  Check(FairSharePenalty(ProcessorsUsedThousandths(Usage, Now), Processors) = 0,
    'three quiet seconds later there is no penalty');
end;

{ --- Memory reserves ----------------------------------------------------- }

procedure TestPageReserve;
const
  Critical = 1024;
begin
  Check(UserPageAllowed(Critical + 1, Critical, False), 'above the watermark a program gets a page');
  Check(not UserPageAllowed(Critical, Critical, False), 'at the watermark a program does not');
  Check(UserPageAllowed(Critical, Critical, True), 'an essential process does');
  Check(UserPageAllowed(Critical div 2 + 1, Critical, True), 'down to half the watermark');
  Check(not UserPageAllowed(Critical div 2, Critical, True), 'but not below');
  Check(UserPageFloor(Critical, False) > UserPageFloor(Critical, True), 'programs stop before essential ones');
end;

procedure TestCommitLimit;
var
  Limit: QWord;
begin
  Limit := SystemCommitLimit(131072, 10000, 1024, 100);
  Check(Limit = 131072 - 10000 - 1024, 'the limit is what the kernel leaves (100%)');
  Check(SystemCommitLimit(131072, 10000, 1024, 200) = 2 * Limit, '200% doubles it');
  Check(SystemCommitLimit(131072, 10000, 1024, 1) = Limit * MinimumCommitLimitPercent div 100,
    'the percentage has a floor');
  Check(SystemCommitLimit(1000, 2000, 10, 100) = 1, 'a kernel holding everything leaves one page');
  Check(EssentialCommitReserve(32768) = 1024, 'a 32nd is for essential processes');
  Check(CommitAllowed(0, 100, 0, False), 'no limit allows anything');
  Check(CommitAllowed(32768 - 1024 - 100, 100, 32768, False), 'a program may commit up to the reserve');
  Check(not CommitAllowed(32768 - 1024 - 99, 100, 32768, False), 'but not into it');
  Check(CommitAllowed(32768 - 100, 100, 32768, True), 'an essential process may');
  Check(not CommitAllowed(32768 - 99, 100, 32768, True), 'but not past the limit');
  Check(not CommitAllowed(10, High(QWord) - 5, 32768, True), 'a huge request does not wrap');
end;

{ --- Thrash guard -------------------------------------------------------- }

procedure TestThrashGuard;
var
  Guard: TThrashGuard;
  Granted: QWord;
begin
  Check(ThrashGuardRate(131072) = 2048, 'a 64th of RAM a second');
  Check(ThrashGuardRate(1000) = MinimumThrashGuardRate, 'at least the minimum');
  InitializeThrashGuard(Guard, 1000, 0);
  Granted := TakeThrashGuardPages(Guard, 600, 0);
  Check(Granted = 600, 'a full bucket grants what it holds');
  Granted := TakeThrashGuardPages(Guard, 600, 0);
  Check(Granted = 400, 'then only what is left');
  Check(Guard.Refused = 200, 'the rest is counted as refused');
  Granted := TakeThrashGuardPages(Guard, 600, Second div 10);
  Check(Granted = 100, 'a tenth of a second earns a tenth of the rate');
  ReturnThrashGuardPages(Guard, 50);
  Check(TakeThrashGuardPages(Guard, 600, Second div 10) = 50, 'unused grants come back');
  Check(TakeThrashGuardPages(Guard, 5000, 10 * Second) = 1000, 'the bucket holds at most a second''s worth');
  InitializeThrashGuard(Guard, 1000, 0);
  TakeThrashGuardPages(Guard, 1000, 0);
  Check(TakeThrashGuardPages(Guard, 10, 100) = 0, 'too little time earns nothing');
  Check(TakeThrashGuardPages(Guard, 10, Millisecond * 5) = 5, 'the time is kept until it earns a page');
end;

begin
  TestClassPriorities;
  TestClassRules;
  TestDecay;
  TestSteadyState;
  TestPenalty;
  TestBusyProcessBesideAnother;
  TestPageReserve;
  TestCommitLimit;
  TestThrashGuard;
  if Failures > 0 then
  begin
    WriteLn('RESPONSIVENESS POLICY TEST FAILED: ', Failures, ' checks');
    Halt(1);
  end;
  WriteLn('RESPONSIVENESS POLICY TEST PASSED');
end.
