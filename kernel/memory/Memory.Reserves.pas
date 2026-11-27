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
  Memory kept back so the system stays usable when a program takes all
  it can, and what may be promised with no paging file behind it: the
  rules, as pure arithmetic for the host test
  (tools/ResponsivenessPolicyTest).

  * Commitments are backed. With no paging file, the only place a
    committed page can come from when it is first touched is RAM, so
    the system's commit limit is the RAM processes may have for their
    own pages: all of it less what the kernel holds for itself, less
    what the caches keep however short memory is (the block cache's
    minimum, the pages of the files running programs map - their code,
    which must stay resident or every program reads it again turn after
    turn), less the critical watermark. Caches beyond that count as
    available: they are given back when the promised pages are touched,
    and shrunk ahead of time when the commitments come close to the
    limit (commit pressure, below). The kernel option
    commitlimit=PERCENT scales the limit (100 by default: no
    overcommitment; above 100 promises more than can be backed, and the
    out-of-memory policy then ends a process when they are touched;
    "off" for none). The last EssentialCommitShift-th of the limit is
    only for essential processes.

  * Pages. Below the critical watermark the free pages are a reserve,
    claimed in order of need (TPageClaim): a file's page or a page
    nobody committed, for an ordinary program, stops at the watermark
    (the fault then reclaims, and if that finds nothing a process is
    ended: Processes.OutOfMemory); a page an ordinary program committed
    goes down to half of it, since the commit limit promised it and
    left the watermark for it - so a page whose commitment was granted
    is not refused while caches or the reserve can back it; an
    essential process (the display server, the session manager, the
    desktop, the task manager: Processes.PriorityClassCalls) goes down
    to a quarter, and the kernel's own allocations to the last page.
    With no commit limit nothing was promised, and committed pages are
    claimed as ordinary ones.

  * Commit pressure. Promises not touched yet (OutstandingCommitPages)
    must find free memory when they are: when the headroom left under
    the limit falls below the low watermark, memory is reported short
    (so programs that watch it give memory back, and stop asking) and
    the caches are shrunk gently until the outstanding promises and the
    low watermark are free (CommitReclaimTarget).
}
unit Memory.Reserves;

{$mode objfpc}

interface

const
  { The default share of the processes' RAM that may be committed. }
  DefaultCommitLimitPercent = 100;
  MinimumCommitLimitPercent = 10;
  MaximumCommitLimitPercent = 10000;
  { 1/32 of the commit limit is for essential processes alone. }
  EssentialCommitShift = 5;

type
  { Who asks for a page of process memory, the most entitled first. }
  TPageClaim = (
    { The kernel's own allocations (and kernel threads): every page. }
    PageClaimKernel,
    { An essential process: down to a quarter of the critical watermark. }
    PageClaimEssential,
    { A page an ordinary program committed, under a commit limit: down to
      half of it. }
    PageClaimCommitted,
    { A file's page, a page nobody committed, or any page with no commit
      limit: down to the watermark. }
    PageClaimOrdinary);

  { How close the commitments are to the limit (as the memory pressure
    levels: none, low, critical). }
  TCommitPressure = (CommitPressureNone, CommitPressureLow, CommitPressureCritical);

{ The claim of a page of process memory: for an essential process, or a
  committed page while commitments are backed by a limit. }
function ProcessPageClaim(IsEssential, IsCommitted, CommitmentsBacked: Boolean): TPageClaim;
{ The free pages below which a page of that claim is refused. }
function PageClaimFloor(CriticalPages: QWord; Claim: TPageClaim): QWord;
{ Whether a page of that claim may be taken with FreePages free. }
function PageClaimAllowed(FreePages, CriticalPages: QWord; Claim: TPageClaim): Boolean;

{ The system's commit limit: UsablePages of RAM, KernelPages held by the
  kernel, KeptPages the caches keep whatever happens, CriticalPages kept
  as the reserve, scaled by Percent. At least one page (0 means no
  limit, which only "off" gives). }
function SystemCommitLimit(UsablePages, KernelPages, KeptPages, CriticalPages, Percent: QWord): QWord;
{ The part of Limit only essential processes may commit. }
function EssentialCommitReserve(Limit: QWord): QWord;
{ Whether Pages more may be committed with Charged committed already
  against Limit (0: no limit). }
function CommitAllowed(Charged, Pages, Limit: QWord; MayUseReserve: Boolean): Boolean;

{ The promised pages not resident yet: Committed less the pages of
  processes' own memory resident now. }
function OutstandingCommitPages(CommittedPages, ResidentPrivatePages: QWord): QWord;
{ Commit pressure: low with less than LowPages of headroom under what
  ordinary programs may commit, critical with less than CriticalPages;
  none without a limit (0). }
function CommitPressureLevel(CommittedPages, Limit, LowPages, CriticalPages: QWord): TCommitPressure;
{ The pages to reclaim so the outstanding promises and the low
  watermark are free (0 when they are). }
function CommitReclaimTarget(OutstandingPages, FreePages, LowPages: QWord): QWord;

implementation

function ProcessPageClaim(IsEssential, IsCommitted, CommitmentsBacked: Boolean): TPageClaim;
begin
  if IsEssential then
    Result := PageClaimEssential
  else if IsCommitted and CommitmentsBacked then
    Result := PageClaimCommitted
  else
    Result := PageClaimOrdinary;
end;

function PageClaimFloor(CriticalPages: QWord; Claim: TPageClaim): QWord;
begin
  case Claim of
    PageClaimKernel: Result := 0;
    PageClaimEssential: Result := CriticalPages div 4;
    PageClaimCommitted: Result := CriticalPages div 2;
  else
    Result := CriticalPages;
  end;
end;

function PageClaimAllowed(FreePages, CriticalPages: QWord; Claim: TPageClaim): Boolean;
begin
  Result := FreePages > PageClaimFloor(CriticalPages, Claim);
end;

function SystemCommitLimit(UsablePages, KernelPages, KeptPages, CriticalPages, Percent: QWord): QWord;
var
  Available: QWord;
begin
  { Taken away one at a time: no sum can wrap. }
  Available := UsablePages;
  if KernelPages >= Available then
    Available := 0
  else
    Available := Available - KernelPages;
  if KeptPages >= Available then
    Available := 0
  else
    Available := Available - KeptPages;
  if CriticalPages >= Available then
    Available := 1
  else
    Available := Available - CriticalPages;
  if Percent < MinimumCommitLimitPercent then
    Percent := MinimumCommitLimitPercent;
  if Percent > MaximumCommitLimitPercent then
    Percent := MaximumCommitLimitPercent;
  Result := Available * Percent div 100;
  if Result = 0 then
    Result := 1;
end;

function EssentialCommitReserve(Limit: QWord): QWord;
begin
  Result := Limit shr EssentialCommitShift;
end;

function CommitAllowed(Charged, Pages, Limit: QWord; MayUseReserve: Boolean): Boolean;
var
  Ceiling: QWord;
begin
  if Limit = 0 then
    Exit(True);
  Ceiling := Limit;
  if not MayUseReserve then
    Ceiling := Limit - EssentialCommitReserve(Limit);
  Result := (Pages <= Ceiling) and (Charged <= Ceiling - Pages);
end;

function OutstandingCommitPages(CommittedPages, ResidentPrivatePages: QWord): QWord;
begin
  if CommittedPages > ResidentPrivatePages then
    Result := CommittedPages - ResidentPrivatePages
  else
    Result := 0;
end;

function CommitPressureLevel(CommittedPages, Limit, LowPages, CriticalPages: QWord): TCommitPressure;
var
  Ceiling: QWord;
  Headroom: QWord;
begin
  if Limit = 0 then
    Exit(CommitPressureNone);
  Ceiling := Limit - EssentialCommitReserve(Limit);
  if CommittedPages >= Ceiling then
    Headroom := 0
  else
    Headroom := Ceiling - CommittedPages;
  if Headroom < CriticalPages then
    Result := CommitPressureCritical
  else if Headroom < LowPages then
    Result := CommitPressureLow
  else
    Result := CommitPressureNone;
end;

function CommitReclaimTarget(OutstandingPages, FreePages, LowPages: QWord): QWord;
var
  Wanted: QWord;
begin
  Wanted := OutstandingPages + LowPages;
  if Wanted > FreePages then
    Result := Wanted - FreePages
  else
    Result := 0;
end;

end.
