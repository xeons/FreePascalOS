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

  * Commitments. With no paging file, the only place a committed page
    can come from when it is first touched is RAM: the RAM processes may
    have for their own pages is all of it less what the kernel holds
    for itself, less what the caches keep however short memory is (the
    block cache's minimum, the pages of the files running programs map
    - their code, which must stay resident or every program reads it
    again turn after turn), less the critical watermark
    (SystemCommitLimit at 100%: the backable pages). Caches beyond that
    count as available: they are given back when the promised pages are
    touched. The kernel option commitlimit chooses the policy
    (TCommitPolicy, ComputeSystemCommitLimits):

    - by default (or commitlimit=overcommit), heuristic overcommitment,
      as Unix programs expect: they map far more than they touch
      (allocators' arenas, thread stacks, buffers sized for the worst
      case) and a strict limit refuses them while most of the memory is
      free. Only what can never be satisfied is refused: one commitment
      larger than the backable pages, or a total beyond
      OvercommitCeilingPercent of them (4 times: generous enough for
      programs' untouched reservations, and still a stop for a runaway
      that commits without end). A page touched when none is left goes
      to the fault's reclaim and then the out-of-memory policy, which
      ends a process (never the kernel, never an essential process
      before the others: Processes.OutOfMemory);
    - commitlimit=PERCENT, strict accounting against PERCENT of the
      backable pages: at 100 nothing is promised that cannot be backed,
      so a committed page is never refused when touched (above 100 more
      is promised, and the out-of-memory policy settles it);
    - commitlimit=off: no system limit at all.

    The last EssentialCommitShift-th of the limit is only for essential
    processes. A job's and a process's own commit limits are strict
    under every policy: they are caps someone chose (the browser's
    content processes, ProcessLimitCommit), and they count what was
    promised, touched or not, so a runaway page is stopped at its cap
    before it can take the system's memory.

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
    Unless commitments are backed (strict accounting at no more than
    100%) nothing was promised, and committed pages are claimed as
    ordinary ones.

  * Commit pressure. When the headroom left under the limit falls below
    the low watermark, memory is reported short (so programs that watch
    it give memory back, and stop asking). While commitments are backed
    the promises not touched yet (OutstandingCommitPages) must find free
    memory when they are, so the caches are also shrunk gently until
    the outstanding promises and the low watermark are free
    (CommitReclaimTarget); overcommitted promises are not expected to be
    touched, and the free pages' own pressure looks after the caches.
}
unit Memory.Reserves;

{$mode objfpc}

interface

const
  { The share of the backable pages commitlimit=PERCENT allows when no
    number is given with it. }
  DefaultCommitLimitPercent = 100;
  { Heuristic overcommitment: all commitments together up to this share
    of the backable pages. }
  OvercommitCeilingPercent = 400;
  MinimumCommitLimitPercent = 10;
  MaximumCommitLimitPercent = 10000;
  { 1/32 of the commit limit is for essential processes alone. }
  EssentialCommitShift = 5;

type
  { What the system's commit limit is (the kernel option commitlimit), in
    the order of AbiCommitPolicy*. }
  TCommitPolicy = (
    { commitlimit=off: none. }
    CommitPolicyNone,
    { commitlimit=PERCENT: strict accounting against that share of the
      backable pages. }
    CommitPolicyStrict,
    { The default: refuse only what can never be satisfied. }
    CommitPolicyOvercommit);

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
{ The system's limits under Policy (Percent for the strict one): Limit
  on all commitments together and LargestRequest on any one of them (0:
  none). }
procedure ComputeSystemCommitLimits(Policy: TCommitPolicy; UsablePages, KernelPages, KeptPages, CriticalPages,
  Percent: QWord; out Limit, LargestRequest: QWord);
{ Whether the policy promises only what RAM can back (so committed pages
  may go further into the reserve). }
function CommitPolicyBacksCommitments(Policy: TCommitPolicy; Percent: QWord): Boolean;
{ The part of Limit only essential processes may commit. }
function EssentialCommitReserve(Limit: QWord): QWord;
{ Whether Pages more may be committed with Charged committed already
  against Limit (0: no limit). }
function CommitAllowed(Charged, Pages, Limit: QWord; MayUseReserve: Boolean): Boolean;

{ CommitAllowed, and Pages no more than LargestRequest (0: any). }
function SystemCommitAllowed(Charged, Pages, Limit, LargestRequest: QWord; MayUseReserve: Boolean): Boolean;

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

procedure ComputeSystemCommitLimits(Policy: TCommitPolicy; UsablePages, KernelPages, KeptPages, CriticalPages,
  Percent: QWord; out Limit, LargestRequest: QWord);
var
  Backable: QWord;
begin
  Limit := 0;
  LargestRequest := 0;
  case Policy of
    CommitPolicyStrict:
      Limit := SystemCommitLimit(UsablePages, KernelPages, KeptPages, CriticalPages, Percent);
    CommitPolicyOvercommit:
      begin
        Backable := SystemCommitLimit(UsablePages, KernelPages, KeptPages, CriticalPages, 100);
        LargestRequest := Backable;
        Limit := Backable * OvercommitCeilingPercent div 100;
      end;
  end;
end;

function CommitPolicyBacksCommitments(Policy: TCommitPolicy; Percent: QWord): Boolean;
begin
  Result := (Policy = CommitPolicyStrict) and (Percent <= 100);
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

function SystemCommitAllowed(Charged, Pages, Limit, LargestRequest: QWord; MayUseReserve: Boolean): Boolean;
begin
  Result := ((LargestRequest = 0) or (Pages <= LargestRequest)) and CommitAllowed(Charged, Pages, Limit, MayUseReserve);
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
