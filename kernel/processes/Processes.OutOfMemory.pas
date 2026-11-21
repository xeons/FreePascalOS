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
  When memory runs out: ending a process to get it back.

  A user page fault that finds no free page (Processes.UserProcess
  notices: the allocator counted a failure while it was resolved) comes
  here. The caches are asked first (Memory.Pressure.ReclaimMemory, hard)
  and the fault tried again. If there still is no page, a process is
  chosen (Processes.OutOfMemoryScores: the largest by resident and
  committed pages, Processes.MemoryCharges, with its OOM score
  adjustment; never the initial program nor one whose adjustment is
  OomScoreAdjustNever, unless it is the culprit) and ended with exit
  status 137 (ExitStatusOutOfMemory), with a line in the kernel log and
  a notification (NotificationProcessEndedForMemory) to every process
  that selected it.

  If the chosen process is the one whose fault failed, it ends right
  there: its allocation fails cleanly by ending it. Any other faulting
  thread waits for the chosen process to end and its memory to come
  back, then tries again. While one chosen process is still ending (up
  to PendingVictimMilliseconds), no second one is chosen: every thread
  short of memory waits for that one.

  Kernel allocations never end a process directly: they reclaim and
  fail. The memory pressure thread calls the policy (with no culprit)
  when memory stays critical while allocations keep failing.
}
unit Processes.OutOfMemory;

{$mode objfpc}

interface

uses
  Processes.Process;

type
  TOutOfMemoryStatistics = record
    ProcessesEnded: QWord;
    LastEndedProcessId: QWord;
    LastEndedName: array[0..63] of Char;
  end;

procedure InitializeOutOfMemoryPolicy;

{ A user mode page fault of Process failed for want of memory: reclaims,
  ends a process if it must, and resolves the fault. True if it was
  resolved; False if it turned out not to be about memory (the fault is
  the program's). Does not return if Process itself is ended. Passive
  level, interrupts on. }
function ResolveFaultWithoutMemory(Process: PProcess; FaultAddress, ErrorCode: QWord): Boolean;

procedure GetOutOfMemoryStatistics(out Statistics: TOutOfMemoryStatistics);

implementation

uses
  Runtime.Text,
  Abi.SystemCalls,
  Memory.Layout,
  Memory.PhysicalPages,
  Memory.Pressure,
  Kernel.Mutex,
  Kernel.Events,
  Kernel.Clock,
  Kernel.Scheduler,
  Objects.Manager,
  Processes.AddressSpace,
  Processes.NotificationQueue,
  Processes.MemoryCharges,
  Processes.OutOfMemoryScores,
  Processes.Termination,
  Processes.UserProcess,
  Debug.Output;

const
  PendingVictimMilliseconds = 5000;
  VictimExitWaitMilliseconds = 3000;
  MemoryReturnWaitMilliseconds = 1000;
  MemoryReturnPollMilliseconds = 20;
  MaximumRounds = 16;

type
  TVictimSearch = record
    Culprit: PProcess;
    TotalPages: QWord;
    Best: PProcess;
    BestScore: Int64;
    BestFootprint: QWord;
  end;
  PVictimSearch = ^TVictimSearch;

var
  PolicyLock: TMutex;
  { The process chosen last, referenced, while it may still be ending. }
  PendingVictim: PProcess;
  PendingSince: QWord;
  Counters: TOutOfMemoryStatistics;

function HandleCriticalMemory: Boolean; forward;

procedure InitializeOutOfMemoryPolicy;
begin
  InitializeMutex(PolicyLock);
  SetOutOfMemoryHandler(@HandleCriticalMemory);
end;

procedure GetOutOfMemoryStatistics(out Statistics: TOutOfMemoryStatistics);
begin
  AcquireMutex(PolicyLock);
  Statistics := Counters;
  ReleaseMutex(PolicyLock);
end;

function TotalPages: QWord;
var
  Physical: TPhysicalMemoryStatistics;
begin
  GetPhysicalMemoryStatistics(Physical);
  Result := Physical.TotalUsablePages;
end;

{ --- Choosing (registry lock held) ------------------------------------- }

procedure ConsiderProcess(Process: PProcess; Context: Pointer);
var
  Search: PVictimSearch;
  Candidate: TOomCandidate;
  Score: Int64;
begin
  Search := PVictimSearch(Context);
  if not Process^.IsUserProcess or Process^.HasExited or (Process^.AddressSpace = nil) then
    Exit;
  Candidate.FootprintPages := ProcessFootprintPages(Process);
  Candidate.ScoreAdjust := Process^.OomScoreAdjust;
  Candidate.IsProtected := Process^.NeverEndForMemory;
  Candidate.IsCulprit := Process = Search^.Culprit;
  Candidate.IsEnding := Process^.TerminationRequested;
  Score := OomScore(Candidate, Search^.TotalPages);
  if OomBeatsBest(Score, Candidate.FootprintPages, Search^.BestScore, Search^.BestFootprint) then
  begin
    Search^.Best := Process;
    Search^.BestScore := Score;
    Search^.BestFootprint := Candidate.FootprintPages;
  end;
end;

procedure NotifyIfSelected(Process: PProcess; Context: Pointer);
begin
  if Process^.IsUserProcess and not Process^.HasExited and
     NotificationIsSelected(Process^.Notifications, NotifyProcessEndedForMemory) then
    PostNotification(Process^.Notifications, NotificationProcessEndedForMemory, 0, 0, PQWord(Context)^);
end;

procedure ReportVictim(Victim, Culprit: PProcess; FootprintPages: QWord);
begin
  DebugBeginMessage;
  DebugWriteTag('memory');
  DebugWrite('Out of memory: ended ');
  DebugWrite(@Victim^.Name[0]);
  DebugWrite(' (');
  DebugWriteDecimal(Victim^.ProcessId);
  DebugWrite('), ');
  DebugWriteSize(FootprintPages * PageSize);
  DebugWrite(' resident and committed');
  if Culprit = Victim then
    DebugWrite(', the process asking')
  else if Culprit <> nil then
  begin
    DebugWrite(', for ');
    DebugWrite(@Culprit^.Name[0]);
    DebugWrite(' (');
    DebugWriteDecimal(Culprit^.ProcessId);
    DebugWrite(')');
  end;
  DebugWriteLine(', exit status 137');
  DebugEndMessage;
end;

{ Chooses and ends a process (policy lock held); returns it referenced,
  or nil if none may go. }
function EndChosenProcessLocked(Culprit: PProcess): PProcess;
var
  Search: TVictimSearch;
  VictimId: QWord;
begin
  Search.Culprit := Culprit;
  Search.TotalPages := TotalPages;
  Search.Best := nil;
  Search.BestScore := OomNotEligible;
  Search.BestFootprint := 0;
  LockProcessRegistry;
  VisitRunningProcessesLocked(@ConsiderProcess, @Search);
  Result := Search.Best;
  if Result <> nil then
  begin
    ReferenceObject(Result);
    RequestProcessTerminationLocked(Result, ExitStatusOutOfMemory);
    VictimId := Result^.ProcessId;
    VisitRunningProcessesLocked(@NotifyIfSelected, @VictimId);
  end;
  UnlockProcessRegistry;
  if Result = nil then
    Exit;
  ReportVictim(Result, Culprit, Search.BestFootprint);
  Inc(Counters.ProcessesEnded);
  Counters.LastEndedProcessId := Result^.ProcessId;
  CopyText(@Counters.LastEndedName[0], @Result^.Name[0], SizeOf(Counters.LastEndedName));
end;

{ The process chosen before, referenced for the caller, if it is still
  ending (policy lock held); otherwise nil, and it is let go. }
function StillEndingVictimLocked: PProcess;
begin
  Result := nil;
  if PendingVictim = nil then
    Exit;
  if not PendingVictim^.HasExited and (UptimeMilliseconds - PendingSince < PendingVictimMilliseconds) then
  begin
    ReferenceObject(PendingVictim);
    Exit(PendingVictim);
  end;
  DereferenceObject(PendingVictim);
  PendingVictim := nil;
end;

{ A process to wait for, referenced: the one still ending, or a newly
  chosen one (which may be Culprit itself); nil if none may go. }
function ProcessToWaitFor(Culprit: PProcess): PProcess;
begin
  AcquireMutex(PolicyLock);
  Result := StillEndingVictimLocked;
  if Result = nil then
  begin
    Result := EndChosenProcessLocked(Culprit);
    if Result <> nil then
    begin
      ReferenceObject(Result);
      PendingVictim := Result;
      PendingSince := UptimeMilliseconds;
    end;
  end;
  ReleaseMutex(PolicyLock);
end;

{ The memory pressure thread's last resort. }
function HandleCriticalMemory: Boolean;
var
  Victim: PProcess;
begin
  Victim := ProcessToWaitFor(nil);
  Result := Victim <> nil;
  if Victim <> nil then
    DereferenceObject(Victim);
end;

{ --- Faults ------------------------------------------------------------ }

{ After Victim ended: waits a little for its pages to reach the free
  list (the critical watermark free again). }
procedure WaitForMemoryToReturn;
var
  Waited: QWord;
begin
  Waited := 0;
  while (CurrentMemoryPressure = MemoryPressureCritical) and (Waited < MemoryReturnWaitMilliseconds) do
  begin
    SleepMilliseconds(MemoryReturnPollMilliseconds);
    Waited := Waited + MemoryReturnPollMilliseconds;
  end;
end;

function ResolveFaultWithoutMemory(Process: PProcess; FaultAddress, ErrorCode: QWord): Boolean;
var
  Round: Integer;
  Failures: QWord;
  Victim: PProcess;
begin
  for Round := 1 to MaximumRounds do
  begin
    { Chosen meanwhile (by another thread of it, or the pressure
      thread): its allocation fails by ending it. }
    if Process^.TerminationRequested then
      ExitCurrentProcess(Process^.TerminationCode);
    ReclaimMemory(PagesShortOfComfort + 1, ShrinkHard);
    Failures := FailedPageAllocationCount;
    if ResolveUserPageFault(Process^.AddressSpace, FaultAddress, ErrorCode) then
      Exit(True);
    { No allocation failed this time: the fault is the program's. }
    if FailedPageAllocationCount = Failures then
      Exit(False);
    Victim := ProcessToWaitFor(Process);
    if (Victim = nil) or (Victim = Process) then
    begin
      if Victim <> nil then
        DereferenceObject(Victim);
      ExitCurrentProcess(ExitStatusOutOfMemory);
    end;
    WaitForEventWithOptions(Victim^.ExitEvent, VictimExitWaitMilliseconds, False);
    DereferenceObject(Victim);
    WaitForMemoryToReturn;
  end;
  { Others were ended and memory still did not come back. }
  ExitCurrentProcess(ExitStatusOutOfMemory);
  Result := False;
end;

end.
