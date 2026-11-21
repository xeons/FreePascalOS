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
  How much memory a process is charged with, for the out-of-memory
  policy (Processes.OutOfMemory) and CallGetMemoryPressure.

  A process's footprint is the pages it has resident plus those
  committed to it that are not resident yet. Resident pages are counted
  by its address space; commitments are counted by the virtual memory
  calls (reserve and commit), which set the counters here
  (SetCommitCounters) when they start. Until then a process is charged
  with what it has resident, and the system's commitment is the pages
  processes have of their own.
}
unit Processes.MemoryCharges;

{$mode objfpc}

interface

uses
  Processes.Process;

type
  { Pages committed to Process beyond those it has resident. Called with
    the process registry lock held: it must not take that lock. }
  TProcessCommitCounter = function(Process: PProcess): QWord;
  { Pages committed in the whole system, resident or not. }
  TSystemCommitCounter = function: QWord;

procedure SetCommitCounters(ProcessCounter: TProcessCommitCounter; SystemCounter: TSystemCommitCounter);

{ Resident plus committed pages (the process registered and running). }
function ProcessFootprintPages(Process: PProcess): QWord;
function SystemCommittedPages: QWord;

implementation

uses
  Memory.PhysicalPages,
  Processes.AddressSpace;

var
  ProcessCommits: TProcessCommitCounter;
  SystemCommits: TSystemCommitCounter;

procedure SetCommitCounters(ProcessCounter: TProcessCommitCounter; SystemCounter: TSystemCommitCounter);
begin
  ProcessCommits := ProcessCounter;
  SystemCommits := SystemCounter;
end;

function ProcessFootprintPages(Process: PProcess): QWord;
begin
  Result := 0;
  if Process^.AddressSpace <> nil then
    Result := Process^.AddressSpace^.CommittedPages;
  if Assigned(ProcessCommits) then
    Result := Result + ProcessCommits(Process);
end;

function SystemCommittedPages: QWord;
var
  Counts: TPageUsageCounts;
begin
  if Assigned(SystemCommits) then
    Exit(SystemCommits());
  GetPageUsageCounts(Counts);
  Result := Counts[PageUsageUserMemory];
end;

end.
