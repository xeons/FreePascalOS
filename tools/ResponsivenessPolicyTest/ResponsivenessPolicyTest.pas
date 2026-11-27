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
  * the memory reserves (Memory.Reserves): which page claims are
    refused near the critical watermark, the system commit limit (less
    what the caches keep), the limits of each commit policy (strict,
    heuristic overcommitment, none), the essential processes' part of
    the limit, commit pressure and what the caches give back for it;
  * the commit policy simulated (CommitSimulation), strict accounting:
    a hog stopping when it sees memory short, on a small machine and on
    one with many untouched promises (memory found short, the caches
    give back, no committed page refused); a runaway refused by the
    limit, after which every promise is kept without taking the
    programs' code and an essential process still gets memory; no limit
    at all;
  * overcommitment simulated: a ported program that maps far more than
    it touches (refused by strict accounting with most memory free,
    granted when overcommitting); a runaway that touches what it
    commits stopped at the reserve's watermark (its fault then goes to
    the out-of-memory policy) with the reserve, the programs' code and
    an essential process's pages intact; one that only commits refused
    at the ceiling, and one commitment larger than RAM refused at once;
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
  Memory.ThrashGuard,
  CommitSimulation;

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
  Check(PageClaimAllowed(Critical + 1, Critical, PageClaimOrdinary), 'above the watermark a program gets a page');
  Check(not PageClaimAllowed(Critical, Critical, PageClaimOrdinary), 'at the watermark a program does not');
  Check(PageClaimAllowed(Critical, Critical, PageClaimCommitted), 'a page it committed does');
  Check(PageClaimAllowed(Critical div 2 + 1, Critical, PageClaimCommitted), 'down to half the watermark');
  Check(not PageClaimAllowed(Critical div 2, Critical, PageClaimCommitted), 'but not below');
  Check(PageClaimAllowed(Critical div 2, Critical, PageClaimEssential), 'an essential process goes further');
  Check(PageClaimAllowed(Critical div 4 + 1, Critical, PageClaimEssential), 'down to a quarter');
  Check(not PageClaimAllowed(Critical div 4, Critical, PageClaimEssential), 'but not below');
  Check(PageClaimAllowed(1, Critical, PageClaimKernel), 'the kernel takes the last page');
  Check(not PageClaimAllowed(0, Critical, PageClaimKernel), 'but no page that is not there');
  Check((PageClaimFloor(Critical, PageClaimOrdinary) > PageClaimFloor(Critical, PageClaimCommitted)) and
    (PageClaimFloor(Critical, PageClaimCommitted) > PageClaimFloor(Critical, PageClaimEssential)) and
    (PageClaimFloor(Critical, PageClaimEssential) > PageClaimFloor(Critical, PageClaimKernel)),
    'uncommitted pages stop first, then committed ones, then essential processes, then the kernel');
  Check(ProcessPageClaim(False, False, True) = PageClaimOrdinary, 'a page nobody committed is ordinary');
  Check(ProcessPageClaim(False, True, True) = PageClaimCommitted, 'a committed page is backed by the limit');
  Check(ProcessPageClaim(False, True, False) = PageClaimOrdinary, 'with no limit nothing was promised');
  Check(ProcessPageClaim(True, False, False) = PageClaimEssential, 'an essential process''s pages are essential');
end;

procedure TestCommitLimit;
var
  Limit: QWord;
begin
  Limit := SystemCommitLimit(131072, 10000, 0, 1024, 100);
  Check(Limit = 131072 - 10000 - 1024, 'the limit is what the kernel leaves (100%)');
  Check(SystemCommitLimit(131072, 10000, 5000, 1024, 100) = Limit - 5000, 'less what the caches keep');
  Check(SystemCommitLimit(131072, 10000, 0, 1024, 200) = 2 * Limit, '200% doubles it');
  Check(SystemCommitLimit(131072, 10000, 0, 1024, 1) = Limit * MinimumCommitLimitPercent div 100,
    'the percentage has a floor');
  Check(SystemCommitLimit(1000, 2000, 0, 10, 100) = 1, 'a kernel holding everything leaves one page');
  Check(SystemCommitLimit(1000, 100, 900, 10, 100) = 1, 'caches keeping everything leave one page');
  Check(SystemCommitLimit(1000, 100, High(QWord) - 50, 10, 100) = 1, 'huge kept counts do not wrap');
  Check(EssentialCommitReserve(32768) = 1024, 'a 32nd is for essential processes');
  Check(CommitAllowed(0, 100, 0, False), 'no limit allows anything');
  Check(CommitAllowed(32768 - 1024 - 100, 100, 32768, False), 'a program may commit up to the reserve');
  Check(not CommitAllowed(32768 - 1024 - 99, 100, 32768, False), 'but not into it');
  Check(CommitAllowed(32768 - 100, 100, 32768, True), 'an essential process may');
  Check(not CommitAllowed(32768 - 99, 100, 32768, True), 'but not past the limit');
  Check(not CommitAllowed(10, High(QWord) - 5, 32768, True), 'a huge request does not wrap');
end;

procedure TestCommitPolicies;
const
  Backable = 131072 - 10000 - 1024;
var
  Limit: QWord;
  Largest: QWord;
begin
  ComputeSystemCommitLimits(CommitPolicyStrict, 131072, 10000, 0, 1024, 100, Limit, Largest);
  Check((Limit = Backable) and (Largest = 0), 'strict: the backable pages, no bound on one commitment');
  ComputeSystemCommitLimits(CommitPolicyStrict, 131072, 10000, 0, 1024, 150, Limit, Largest);
  Check(Limit = Backable * 3 div 2, 'strict at 150%');
  ComputeSystemCommitLimits(CommitPolicyOvercommit, 131072, 10000, 0, 1024, 100, Limit, Largest);
  Check(Largest = Backable, 'overcommit: one commitment up to the backable pages');
  Check(Limit = Backable * OvercommitCeilingPercent div 100, 'all of them up to the ceiling');
  Check(Limit > 131072, 'which is more than the RAM');
  ComputeSystemCommitLimits(CommitPolicyOvercommit, 131072, 10000, 0, 1024, 30, Limit, Largest);
  Check(Largest = Backable, 'overcommit ignores the percentage');
  ComputeSystemCommitLimits(CommitPolicyNone, 131072, 10000, 0, 1024, 100, Limit, Largest);
  Check((Limit = 0) and (Largest = 0), 'none: no limits');
  Check(SystemCommitAllowed(0, Backable, 4 * Backable, Backable, False), 'a commitment of all the backable pages');
  Check(not SystemCommitAllowed(0, Backable + 1, 4 * Backable, Backable, True),
    'one larger is refused, even for an essential process');
  Check(SystemCommitAllowed(0, Backable + 1, 4 * Backable, 0, False), 'no bound: the limit decides');
  Check(not SystemCommitAllowed(4 * Backable - 10, 100, 4 * Backable, Backable, True), 'the ceiling still holds');
  Check(not SystemCommitAllowed(0, High(QWord), 0, Backable, True), 'with no ceiling one commitment is still bounded');
  Check(CommitPolicyBacksCommitments(CommitPolicyStrict, 100), 'strict at 100% backs its commitments');
  Check(not CommitPolicyBacksCommitments(CommitPolicyStrict, 101), 'above 100% it does not');
  Check(not CommitPolicyBacksCommitments(CommitPolicyOvercommit, 100), 'nor does overcommitment');
  Check(not CommitPolicyBacksCommitments(CommitPolicyNone, 100), 'nor no limit');
  Check(ProcessPageClaim(False, True, CommitPolicyBacksCommitments(CommitPolicyOvercommit, 100)) = PageClaimOrdinary,
    'an overcommitted page is claimed as an ordinary one');
end;

procedure TestCommitPressure;
const
  Limit = 32768;
  Ceiling = Limit - Limit div 32;
begin
  Check(OutstandingCommitPages(5000, 3000) = 2000, 'promised and not resident');
  Check(OutstandingCommitPages(3000, 5000) = 0, 'resident beyond the promises: none outstanding');
  Check(CommitPressureLevel(Ceiling - 2048, Limit, 2048, 1024) = CommitPressureNone,
    'a low watermark of room: no commit pressure');
  Check(CommitPressureLevel(Ceiling - 2047, Limit, 2048, 1024) = CommitPressureLow, 'less: low');
  Check(CommitPressureLevel(Ceiling - 1023, Limit, 2048, 1024) = CommitPressureCritical,
    'less than the critical watermark: critical');
  Check(CommitPressureLevel(Limit + 5, Limit, 2048, 1024) = CommitPressureCritical, 'over the limit: critical');
  Check(CommitPressureLevel(High(QWord), 0, 2048, 1024) = CommitPressureNone, 'no limit, no commit pressure');
  Check(CommitReclaimTarget(5000, 3000, 2048) = 4048, 'reclaim what the promises and the watermark need');
  Check(CommitReclaimTarget(100, 5000, 2048) = 0, 'nothing when free memory covers them');
end;

{ --- The commit policy, simulated -------------------------------------------- }

{ A hog taking a MiB at a time and touching it, the pressure thread
  looking every fourth step; with UntilPressure it stops when it sees
  memory short (memorytest hog --until-pressure). Returns whether a
  commitment was refused. }
function RunSimulatedHog(var Memory: TSimulatedMemory; UntilPressure: Boolean; out HogPages: QWord;
  out SawPressure: Boolean): Boolean;
const
  Step = 256;
var
  Steps: Integer;
begin
  HogPages := 0;
  SawPressure := False;
  Result := False;
  Steps := 0;
  while Steps < 100000 do
  begin
    if not SimulatedCommit(Memory, Step, False) then
      Exit(True);
    SimulatedTouch(Memory, Step, SimulatedCommittedClaim(Memory));
    HogPages := HogPages + Step;
    Inc(Steps);
    if Steps mod 4 = 0 then
      SimulatedPressureLook(Memory);
    if UntilPressure and (SimulatedReportedLevel(Memory) <> 0) then
    begin
      SawPressure := True;
      Exit;
    end;
  end;
end;

{ Other processes: Resident pages committed and touched, Outstanding
  committed and not touched yet. }
procedure AddOtherProcesses(var Memory: TSimulatedMemory; Resident, Outstanding: QWord);
begin
  Check(SimulatedCommit(Memory, Resident + Outstanding, False), 'the other processes commit');
  Check(SimulatedTouch(Memory, Resident, SimulatedCommittedClaim(Memory)) = 0, 'and touch what they use');
end;

procedure CheckHogUntilPressure(const Name: string; var Memory: TSimulatedMemory);
var
  HogPages: QWord;
  SawPressure: Boolean;
  Refused: Boolean;
  EventsBefore: QWord;
begin
  EventsBefore := Memory.PressureEvents;
  Refused := RunSimulatedHog(Memory, True, HogPages, SawPressure);
  SimulatedPressureLook(Memory);
  Check(not Refused and SawPressure, Name + ': the hog sees memory short before the limit refuses it');
  Check(Memory.RefusedPages = 0, Name + ': no page it committed was refused');
  Check(Memory.PressureEvents > EventsBefore, Name + ': memory was found short');
  Check(Memory.CachePagesGivenBack > 0, Name + ': the caches gave memory back');
  Check(Memory.BlockCachePages >= Memory.BlockCacheMinimum, Name + ': the block cache kept its minimum');
  Check(HogPages > 0, Name + ': the hog got memory');
end;

{ 512 MiB, few untouched promises: memory runs short of free pages. }
procedure TestSimulatedSmallMachine;
var
  Memory: TSimulatedMemory;
begin
  InitializeSimulatedMemory(Memory, 131072, 12000, 2048, 20000, 4096, 8000, 6000);
  AddOtherProcesses(Memory, 15000, 2000);
  CheckHogUntilPressure('512 MiB', Memory);
end;

{ 1 GiB, many promises nobody touched yet: the commitments come close
  to the limit while free pages are plentiful - the caches must still
  make room for the promises, and the hog must see it. }
procedure TestSimulatedUntouchedPromises;
var
  Memory: TSimulatedMemory;
begin
  InitializeSimulatedMemory(Memory, 262144, 14000, 4096, 40000, 16384, 10000, 8000);
  AddOtherProcesses(Memory, 10000, 60000);
  CheckHogUntilPressure('1 GiB with untouched promises', Memory);
end;

{ A hog without end: refused by the limit; then every promise is
  touched - none may be refused, the mapped pages (code) are never
  needed, an essential process still gets pages, and the hog's end
  brings free memory back. }
procedure TestSimulatedRunaway;
var
  Memory: TSimulatedMemory;
  HogPages: QWord;
  SawPressure: Boolean;
  Outstanding: QWord;
  MappedBefore: QWord;
  Rounds: Integer;
begin
  InitializeSimulatedMemory(Memory, 131072, 12000, 2048, 30000, 4096, 12000, 9000);
  MappedBefore := Memory.MappedFilePages;
  AddOtherProcesses(Memory, 12000, 20000);
  Check(RunSimulatedHog(Memory, False, HogPages, SawPressure), 'a hog without end is refused by the limit');
  Check(Memory.RefusedPages = 0, 'every page the hog committed was there when touched');
  Outstanding := OutstandingCommitPages(Memory.CommittedPages, Memory.ResidentPrivatePages);
  Check(SimulatedTouch(Memory, Outstanding, PageClaimCommitted) = 0,
    Format('then every other promise (%d pages) is kept', [Outstanding]));
  Check(Memory.MappedFilePages = MappedBefore, 'without taking the running programs'' code');
  Check(Memory.FreePages >= Memory.CriticalPages, Format('the reserve is still there (%d free of %d)',
    [Memory.FreePages, Memory.CriticalPages]));
  Check(SimulatedCommit(Memory, 64, True), 'an essential process may still commit');
  Check(SimulatedTouch(Memory, 64, PageClaimEssential) = 0, 'and touch it');
  SimulatedRelease(Memory, HogPages);
  for Rounds := 1 to 3 do
    SimulatedPressureLook(Memory);
  Check(Memory.FreePages > Memory.LowPages, 'the hog ended, free memory came back');
  Check(SimulatedReportedLevel(Memory) = 0, 'and memory is no longer short');
end;

{ With no commit limit nothing is promised: the hog runs into the
  reserve's watermark and its fault fails (the out-of-memory policy then
  ends it), while an essential process still gets pages below it. }
procedure TestSimulatedNoLimit;
var
  Memory: TSimulatedMemory;
  Refused: QWord;
begin
  InitializeSimulatedMemory(Memory, 65536, 8000, 1024, 8000, 2048, 4000, 3000);
  SetSimulatedPolicy(Memory, CommitPolicyNone);
  Check(Memory.LimitPages = 0, 'no limit at all');
  Refused := 0;
  while (Refused = 0) and (Memory.ResidentPrivatePages < 65536) do
    Refused := SimulatedTouch(Memory, 256, ProcessPageClaim(False, True, False));
  Check(Refused > 0, 'without a limit the hog meets the watermark');
  Check(Memory.FreePages <= Memory.CriticalPages, 'having taken the caches and the free pages down to it');
  Check(SimulatedTouch(Memory, 16, PageClaimEssential) = 0, 'an essential process still gets pages');
end;

{ --- Overcommitment, simulated ------------------------------------------------ }

{ The machine of the report that led to overcommitment: 512 MiB, 29 MiB
  for the kernel, 20 MiB kept by the caches; other programs with 100
  MiB committed, then a ported program (Mesa's softpipe) committing
  384 MiB in 16 MiB pieces and touching two fifths of it. }
procedure RunPortedProgram(Policy: TCommitPolicy; out Memory: TSimulatedMemory; out ProgramPages: QWord);
const
  Piece = 4096;
  Wanted = 24 * Piece;
begin
  InitializeSimulatedMemory(Memory, 131072, 7500, 2048, 8000, 4096, 4000, 1000);
  SetSimulatedPolicy(Memory, Policy);
  AddOtherProcesses(Memory, 15000, 10600);
  ProgramPages := 0;
  while (ProgramPages < Wanted) and SimulatedCommit(Memory, Piece, False) do
    ProgramPages := ProgramPages + Piece;
  SimulatedTouch(Memory, ProgramPages * 2 div 5, SimulatedCommittedClaim(Memory));
  SimulatedPressureLook(Memory);
end;

procedure TestSimulatedPortedProgram;
var
  Memory: TSimulatedMemory;
  ProgramPages: QWord;
begin
  RunPortedProgram(CommitPolicyStrict, Memory, ProgramPages);
  Check(Memory.RefusedCommitments > 0, 'strict accounting refuses the ported program');
  Check(Memory.FreePages > 131072 div 3, Format('while a third of the memory is free (%d pages)',
    [Memory.FreePages]));
  RunPortedProgram(CommitPolicyOvercommit, Memory, ProgramPages);
  Check(Memory.RefusedCommitments = 0, 'overcommitment grants it');
  Check(ProgramPages = 24 * 4096, Format('all of it (%d pages)', [ProgramPages]));
  Check(Memory.CommittedPages > Memory.LargestRequestPages, 'more than the RAM processes may use is promised');
  Check(Memory.RefusedPages = 0, 'and every page it touched was there');
  Check(Memory.CachePagesGivenBack = 0, 'the caches were not shrunk for promises nobody touched');
  Check(SimulatedReportedLevel(Memory) = 0, 'memory is not reported short');
end;

{ A runaway touching all it commits: no commitment is refused, but the
  pages run out at the reserve's watermark - its fault then goes to the
  out-of-memory policy, which ends it. Until then the reserve, the
  programs' code and the block cache's minimum stay, and an essential
  process still gets pages. }
procedure TestSimulatedOvercommitRunaway;
const
  Step = 256;
var
  Memory: TSimulatedMemory;
  HogPages: QWord;
  Refused: QWord;
  MappedBefore: QWord;
  Rounds: Integer;
begin
  InitializeSimulatedMemory(Memory, 131072, 12000, 2048, 30000, 4096, 12000, 9000);
  SetSimulatedPolicy(Memory, CommitPolicyOvercommit);
  MappedBefore := Memory.MappedFilePages;
  AddOtherProcesses(Memory, 12000, 20000);
  HogPages := 0;
  Refused := 0;
  while (Refused = 0) and (HogPages < 4 * 131072) do
  begin
    Check(SimulatedCommit(Memory, Step, False), 'overcommitment grants the runaway''s commitments');
    Refused := SimulatedTouch(Memory, Step, SimulatedCommittedClaim(Memory));
    HogPages := HogPages + Step - Refused;
    if (HogPages div Step) mod 4 = 0 then
      SimulatedPressureLook(Memory);
  end;
  Check(Refused > 0, 'its pages run out (the out-of-memory policy takes over)');
  Check(Memory.FreePages = Memory.CriticalPages, Format('at the watermark: the reserve is still there (%d free of %d)',
    [Memory.FreePages, Memory.CriticalPages]));
  Check(Memory.MappedFilePages = MappedBefore, 'the running programs'' code was not taken');
  Check(Memory.BlockCachePages >= Memory.BlockCacheMinimum, 'the block cache kept its minimum');
  Check(SimulatedReportedLevel(Memory) = 1, 'memory is reported short');
  Check(SimulatedCommit(Memory, 64, True), 'an essential process may still commit');
  Check(SimulatedTouch(Memory, 64, PageClaimEssential) = 0, 'and touch it');
  { The out-of-memory policy ends the runaway. }
  SimulatedRelease(Memory, HogPages);
  for Rounds := 1 to 3 do
    SimulatedPressureLook(Memory);
  Check(Memory.FreePages > Memory.LowPages, 'the runaway ended, free memory came back');
  Check(SimulatedReportedLevel(Memory) = 0, 'and memory is no longer short');
end;

{ Commitments nobody touches: refused at the ceiling, an essential
  process keeping its part; one commitment larger than the RAM
  processes may use is refused at once. }
procedure TestSimulatedOvercommitCeiling;
var
  Memory: TSimulatedMemory;
  Granted: QWord;
begin
  InitializeSimulatedMemory(Memory, 131072, 12000, 2048, 30000, 4096, 12000, 9000);
  SetSimulatedPolicy(Memory, CommitPolicyOvercommit);
  Check(not SimulatedCommit(Memory, Memory.LargestRequestPages + 1, False),
    'one commitment larger than the RAM processes may use is refused');
  Check(Memory.CommittedPages = 0, 'and nothing was charged');
  Check(SimulatedCommit(Memory, Memory.LargestRequestPages, False), 'one of all of it is granted');
  Granted := Memory.LargestRequestPages;
  while SimulatedCommit(Memory, 4096, False) do
    Granted := Granted + 4096;
  Check(Memory.RefusedCommitments = 2, 'commitments without end are refused at the ceiling');
  Check(Granted > 3 * Memory.LargestRequestPages, Format('after more than three times the RAM (%d of %d pages)',
    [Granted, Memory.LargestRequestPages]));
  Check(Memory.CommittedPages <= Memory.LimitPages - EssentialCommitReserve(Memory.LimitPages),
    'ordinary programs stop short of the essential part');
  Check(SimulatedCommit(Memory, 4096, True), 'an essential process may still commit');
  Check(SimulatedReportedLevel(Memory) = 2, 'commit pressure is reported');
  SimulatedPressureLook(Memory);
  Check(Memory.CachePagesGivenBack = 0, 'but the caches are not shrunk for overcommitted promises');
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
  TestCommitPolicies;
  TestCommitPressure;
  TestSimulatedSmallMachine;
  TestSimulatedUntouchedPromises;
  TestSimulatedRunaway;
  TestSimulatedNoLimit;
  TestSimulatedPortedProgram;
  TestSimulatedOvercommitRunaway;
  TestSimulatedOvercommitCeiling;
  TestThrashGuard;
  if Failures > 0 then
  begin
    WriteLn('RESPONSIVENESS POLICY TEST FAILED: ', Failures, ' checks');
    Halt(1);
  end;
  WriteLn('RESPONSIVENESS POLICY TEST PASSED');
end.
