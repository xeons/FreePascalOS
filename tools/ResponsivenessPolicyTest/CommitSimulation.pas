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
  A small model of the kernel's memory for ResponsivenessPolicyTest:
  free pages, the caches (the block cache with its minimum, file pages
  nobody maps, the pages running programs map), the commit charge and
  its limit, all decided by the rules of Memory.Reserves as the kernel
  applies them:

  * a commitment is charged against the limits of the policy
    (SystemCommitAllowed), which ComputeSystemCommitLimits computes from
    the RAM, the kernel's pages, the pages the caches keep and the
    critical watermark - strict accounting at 100% unless the test sets
    the policy (SetSimulatedPolicy);
  * touching a page takes a free page of its claim; refused, the fault
    reclaims (file pages nobody maps, then the block cache down to its
    minimum - never the mapped pages, which would be thrashing) and
    tries once more, as Processes.OutOfMemory does before it ends
    anyone;
  * the memory pressure thread's look: below the low watermark it
    reclaims to the comfort level; under commit pressure it counts an
    event when that begins and, while commitments are backed, reclaims
    gently for the promises (CommitReclaimTarget);
  * a program watching the level sees the higher of the free pages'
    and the commitments'.
}
unit CommitSimulation;

{$mode objfpc}

interface

uses
  Memory.Reserves;

type
  TSimulatedMemory = record
    UsablePages: QWord;
    KernelPages: QWord;
    LowPages: QWord;
    CriticalPages: QWord;
    FreePages: QWord;
    BlockCachePages: QWord;
    BlockCacheMinimum: QWord;
    UnmappedFilePages: QWord;
    MappedFilePages: QWord;
    CommittedPages: QWord;
    ResidentPrivatePages: QWord;
    LimitPages: QWord;
    LargestRequestPages: QWord;
    Policy: TCommitPolicy;
    { What happened. }
    PressureEvents: QWord;
    InCommitPressure: Boolean;
    CachePagesGivenBack: QWord;
    RefusedPages: QWord;
    RefusedCommitments: QWord;
  end;

{ Usable RAM, the kernel's pages, the low watermark (critical: half),
  the block cache and its minimum, file pages nobody maps and mapped
  ones; the rest is free. }
procedure InitializeSimulatedMemory(out Memory: TSimulatedMemory; Usable, Kernel, Low, BlockCache,
  BlockCacheMinimum, UnmappedFiles, MappedFiles: QWord);
{ Sets the commit policy (strict at 100% after initializing) and
  recomputes the limits. }
procedure SetSimulatedPolicy(var Memory: TSimulatedMemory; Policy: TCommitPolicy);
{ Whether committed pages are backed under the policy. }
function SimulatedCommitmentsBacked(const Memory: TSimulatedMemory): Boolean;
{ The claim of an ordinary program's committed page under the policy. }
function SimulatedCommittedClaim(const Memory: TSimulatedMemory): TPageClaim;
{ Recomputes the limit (the pressure thread does each second). }
procedure RefreshSimulatedLimit(var Memory: TSimulatedMemory);
{ Charges Pages (refused: counted, False). }
function SimulatedCommit(var Memory: TSimulatedMemory; Pages: QWord; Essential: Boolean): Boolean;
{ Touches Pages committed pages (each a fault taking a page of the
  claim); returns how many found no page. }
function SimulatedTouch(var Memory: TSimulatedMemory; Pages: QWord; Claim: TPageClaim): QWord;
{ Frees Pages of resident private memory and their charge (a process
  ending). }
procedure SimulatedRelease(var Memory: TSimulatedMemory; Pages: QWord);
{ One look of the memory pressure thread. }
procedure SimulatedPressureLook(var Memory: TSimulatedMemory);
{ The level a program sees: 0 none, 1 low, 2 critical. }
function SimulatedReportedLevel(const Memory: TSimulatedMemory): Integer;

implementation

procedure InitializeSimulatedMemory(out Memory: TSimulatedMemory; Usable, Kernel, Low, BlockCache,
  BlockCacheMinimum, UnmappedFiles, MappedFiles: QWord);
begin
  FillChar(Memory, SizeOf(Memory), 0);
  Memory.UsablePages := Usable;
  Memory.KernelPages := Kernel;
  Memory.LowPages := Low;
  Memory.CriticalPages := Low div 2;
  Memory.BlockCachePages := BlockCache;
  Memory.BlockCacheMinimum := BlockCacheMinimum;
  Memory.UnmappedFilePages := UnmappedFiles;
  Memory.MappedFilePages := MappedFiles;
  Memory.FreePages := Usable - Kernel - BlockCache - UnmappedFiles - MappedFiles;
  Memory.Policy := CommitPolicyStrict;
  RefreshSimulatedLimit(Memory);
end;

procedure SetSimulatedPolicy(var Memory: TSimulatedMemory; Policy: TCommitPolicy);
begin
  Memory.Policy := Policy;
  RefreshSimulatedLimit(Memory);
end;

function SimulatedCommitmentsBacked(const Memory: TSimulatedMemory): Boolean;
begin
  Result := CommitPolicyBacksCommitments(Memory.Policy, DefaultCommitLimitPercent);
end;

function SimulatedCommittedClaim(const Memory: TSimulatedMemory): TPageClaim;
begin
  Result := ProcessPageClaim(False, True, SimulatedCommitmentsBacked(Memory));
end;

procedure RefreshSimulatedLimit(var Memory: TSimulatedMemory);
var
  Kept: QWord;
begin
  Kept := Memory.MappedFilePages;
  if Memory.BlockCachePages < Memory.BlockCacheMinimum then
    Kept := Kept + Memory.BlockCachePages
  else
    Kept := Kept + Memory.BlockCacheMinimum;
  ComputeSystemCommitLimits(Memory.Policy, Memory.UsablePages, Memory.KernelPages, Kept, Memory.CriticalPages,
    DefaultCommitLimitPercent, Memory.LimitPages, Memory.LargestRequestPages);
end;

{ Clean cache pages given back: file pages nobody maps first, then the
  block cache down to its minimum. }
function SimulatedReclaim(var Memory: TSimulatedMemory; Wanted: QWord): QWord;
var
  Taken: QWord;
begin
  Result := 0;
  Taken := Wanted;
  if Taken > Memory.UnmappedFilePages then
    Taken := Memory.UnmappedFilePages;
  Memory.UnmappedFilePages := Memory.UnmappedFilePages - Taken;
  Result := Result + Taken;
  if (Result < Wanted) and (Memory.BlockCachePages > Memory.BlockCacheMinimum) then
  begin
    Taken := Wanted - Result;
    if Taken > Memory.BlockCachePages - Memory.BlockCacheMinimum then
      Taken := Memory.BlockCachePages - Memory.BlockCacheMinimum;
    Memory.BlockCachePages := Memory.BlockCachePages - Taken;
    Result := Result + Taken;
  end;
  Memory.FreePages := Memory.FreePages + Result;
  Memory.CachePagesGivenBack := Memory.CachePagesGivenBack + Result;
end;

function ShortOfComfort(const Memory: TSimulatedMemory): QWord;
var
  Comfort: QWord;
begin
  Comfort := Memory.LowPages + Memory.LowPages div 2;
  if Memory.FreePages >= Comfort then
    Result := 0
  else
    Result := Comfort - Memory.FreePages;
end;

function TakePage(var Memory: TSimulatedMemory; Claim: TPageClaim): Boolean;
begin
  Result := PageClaimAllowed(Memory.FreePages, Memory.CriticalPages, Claim);
  if not Result then
  begin
    { The fault's reclaim, then once more. }
    SimulatedReclaim(Memory, ShortOfComfort(Memory) + 1);
    Result := PageClaimAllowed(Memory.FreePages, Memory.CriticalPages, Claim);
  end;
  if Result then
    Dec(Memory.FreePages);
end;

function SimulatedCommit(var Memory: TSimulatedMemory; Pages: QWord; Essential: Boolean): Boolean;
begin
  Result := SystemCommitAllowed(Memory.CommittedPages, Pages, Memory.LimitPages, Memory.LargestRequestPages,
    Essential);
  if Result then
    Memory.CommittedPages := Memory.CommittedPages + Pages
  else
    Inc(Memory.RefusedCommitments);
end;

function SimulatedTouch(var Memory: TSimulatedMemory; Pages: QWord; Claim: TPageClaim): QWord;
var
  Index: QWord;
begin
  Result := 0;
  Index := 0;
  while Index < Pages do
  begin
    if TakePage(Memory, Claim) then
      Inc(Memory.ResidentPrivatePages)
    else
      Inc(Result);
    Inc(Index);
  end;
  Memory.RefusedPages := Memory.RefusedPages + Result;
end;

procedure SimulatedRelease(var Memory: TSimulatedMemory; Pages: QWord);
begin
  if Pages > Memory.ResidentPrivatePages then
    Pages := Memory.ResidentPrivatePages;
  Memory.ResidentPrivatePages := Memory.ResidentPrivatePages - Pages;
  Memory.FreePages := Memory.FreePages + Pages;
  if Pages > Memory.CommittedPages then
    Memory.CommittedPages := 0
  else
    Memory.CommittedPages := Memory.CommittedPages - Pages;
end;

procedure SimulatedPressureLook(var Memory: TSimulatedMemory);
var
  UnderPressure: Boolean;
  Wanted: QWord;
begin
  if Memory.FreePages < Memory.LowPages then
  begin
    Inc(Memory.PressureEvents);
    SimulatedReclaim(Memory, ShortOfComfort(Memory));
  end;
  RefreshSimulatedLimit(Memory);
  UnderPressure := CommitPressureLevel(Memory.CommittedPages, Memory.LimitPages, Memory.LowPages,
    Memory.CriticalPages) <> CommitPressureNone;
  if UnderPressure and not Memory.InCommitPressure then
    Inc(Memory.PressureEvents);
  Memory.InCommitPressure := UnderPressure;
  if UnderPressure and SimulatedCommitmentsBacked(Memory) then
  begin
    Wanted := CommitReclaimTarget(OutstandingCommitPages(Memory.CommittedPages, Memory.ResidentPrivatePages),
      Memory.FreePages, Memory.LowPages);
    if Wanted > 0 then
      SimulatedReclaim(Memory, Wanted);
  end;
end;

function SimulatedReportedLevel(const Memory: TSimulatedMemory): Integer;
var
  CommitLevel: Integer;
begin
  if Memory.FreePages < Memory.CriticalPages then
    Result := 2
  else if Memory.FreePages < Memory.LowPages then
    Result := 1
  else
    Result := 0;
  CommitLevel := Ord(CommitPressureLevel(Memory.CommittedPages, Memory.LimitPages, Memory.LowPages,
    Memory.CriticalPages));
  if CommitLevel > Result then
    Result := CommitLevel;
end;

end.
