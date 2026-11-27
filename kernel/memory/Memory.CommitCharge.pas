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
  The commit charge: how many pages of private memory processes may
  come to use - what they committed (heap, thread data, committed parts
  of reservations, the first pages of stacks) and the private copies
  their writable images and copy on write file mappings may need, and
  the sections they made - whether or not those pages were touched yet.

  Three levels, each charged before the memory is promised and each
  refusing a commitment that would go over its limit (the caller fails
  it with ErrorOutOfMemory):

  * the process (Processes.AddressSpace: CommitChargePages against
    CommitLimitPages, ProcessLimitCommit);
  * its job, if it is in one (a TCommitPool: Processes.Jobs);
  * the system, under the policy the kernel option commitlimit chooses
    (Memory.Reserves: TCommitPolicy, ComputeSystemCommitLimits), from
    the RAM processes may use - less what the kernel holds for itself
    and what the caches keep whatever happens (RegisterKeptPagesQuery:
    the block cache's minimum, the file pages running programs map) -
    recomputed as those change (RefreshSystemCommitLimit, from the
    memory pressure thread each second), the last part of the limit
    kept for essential processes. By default it overcommits: only a
    commitment larger than that RAM, or a total beyond a generous
    multiple of it, is refused. With commitlimit=PERCENT it is strict.

  The process's and the job's limits are strict under every policy. So
  a program that asks for more than it may, or than there could ever
  be, gets an error from the allocation instead of the system running
  out when it touches what it was promised; under strict accounting
  what was promised is also backed (SetCommitmentsBacked: committed
  pages may go further into the reserve, Memory.Reserves). How close
  the commitments are to the limit is Memory.CommitPressure's.
}
unit Memory.CommitCharge;

{$mode objfpc}

interface

uses
  Kernel.SpinLock,
  Memory.Reserves;

type
  { Pages charged against a limit (a job's). }
  PCommitPool = ^TCommitPool;
  TCommitPool = record
    Lock: TSpinLock;
    ChargedPages: QWord;
    PeakPages: QWord;
    { 0: no limit. }
    LimitPages: QWord;
    { Charges refused for the limit. }
    Failures: QWord;
  end;

procedure InitializeCommitPool(out Pool: TCommitPool);
{ Charges Pages if that keeps the pool within its limit. }
function TryChargeCommitPool(Pool: PCommitPool; Pages: QWord): Boolean;
{ Charges Pages whatever the limit (memory moving into the pool that is
  committed already). }
procedure ForceChargeCommitPool(Pool: PCommitPool; Pages: QWord);
procedure UnchargeCommitPool(Pool: PCommitPool; Pages: QWord);
{ Sets the pool's limit (0: none); returns the one before. }
function SetCommitPoolLimit(Pool: PCommitPool; LimitPages: QWord): QWord;

type
  { Pages a cache keeps however short memory is (not available to
    commit). Passive level. }
  TKeptPagesQuery = function: QWord;

  { Runs when a charge leaves less than the low watermark of headroom
    under the system's limit, or is refused. Any level up to dispatch
    (it may only queue a deferred call). }
  TCommitPressureCallback = procedure;

{ Adds a cache's kept pages to what the system's limit leaves out. }
procedure RegisterKeptPagesQuery(Query: TKeptPagesQuery);
procedure SetCommitPressureCallback(Callback: TCommitPressureCallback);

{ Reads the kernel option commitlimit (absent or "overcommit": heuristic
  overcommitment; a number: strict accounting against that percentage;
  "off": no limit) and sets the first limits. }
procedure InitializeSystemCommitLimit;
{ Recomputes the system's limit from the kernel's use of memory now. }
procedure RefreshSystemCommitLimit;
{ Charges Pages to the system if the policy allows them: no larger than
  the largest commitment it allows, and under its limit (the whole limit
  if MayUseReserve, else all but the essential reserve). }
function TryChargeSystemCommit(Pages: QWord; MayUseReserve: Boolean): Boolean;
procedure UnchargeSystemCommit(Pages: QWord);
{ The pages committed by all processes together, the most there ever
  were, the limit (0: none) and the commitments it refused. }
function SystemCommittedPages: QWord;
function PeakSystemCommittedPages: QWord;
function SystemCommitLimitPages: QWord;
function SystemCommitFailures: QWord;
{ The policy, the most one commitment may be (0: no bound of its own),
  the pages of the last commitment refused, and whether commitments are
  backed (strict accounting at no more than 100%). }
function SystemCommitPolicy: TCommitPolicy;
function LargestSystemCommitPages: QWord;
function LastRefusedCommitPages: QWord;
function SystemCommitmentsBacked: Boolean;
{ The pages the caches keep, as last summed for the limit. }
function KeptCachePages: QWord;
{ The pages the kernel holds for itself (not caches it gives back, not
  processes' pages, not free pages held back for the heap checks). }
function KernelHeldPages: QWord;

implementation

uses
  Runtime.Text,
  Kernel.PriorityLevel,
  Kernel.Options,
  Memory.Layout,
  Memory.PhysicalPages,
  Debug.Output;

const
  MaximumKeptPagesQueries = 4;

var
  SystemPool: TCommitPool;
  SystemReady: Boolean = False;
  Policy: TCommitPolicy = CommitPolicyOvercommit;
  LimitPercent: QWord = DefaultCommitLimitPercent;
  { The most one commitment may be (0: no bound of its own); under the
    pool's lock. }
  LargestRequestPages: QWord = 0;
  LastRefusedPages: QWord = 0;
  KeptPagesQueries: array[0..MaximumKeptPagesQueries - 1] of TKeptPagesQuery;
  KeptPagesQueryCount: Integer = 0;
  LastKeptPages: QWord = 0;
  PressureCallback: TCommitPressureCallback = nil;

procedure InitializeCommitPool(out Pool: TCommitPool);
begin
  InitializeSpinLock(Pool.Lock);
  Pool.ChargedPages := 0;
  Pool.PeakPages := 0;
  Pool.LimitPages := 0;
  Pool.Failures := 0;
end;

procedure NotePeakLocked(Pool: PCommitPool);
begin
  if Pool^.ChargedPages > Pool^.PeakPages then
    Pool^.PeakPages := Pool^.ChargedPages;
end;

function TryChargeCommitPool(Pool: PCommitPool; Pages: QWord): Boolean;
var
  PreviousLevel: TPriorityLevel;
begin
  if (Pool = nil) or (Pages = 0) then
    Exit(True);
  PreviousLevel := AcquireSpinLock(Pool^.Lock);
  Result := CommitAllowed(Pool^.ChargedPages, Pages, Pool^.LimitPages, True);
  if Result then
  begin
    Pool^.ChargedPages := Pool^.ChargedPages + Pages;
    NotePeakLocked(Pool);
  end
  else
    Inc(Pool^.Failures);
  ReleaseSpinLock(Pool^.Lock, PreviousLevel);
end;

procedure ForceChargeCommitPool(Pool: PCommitPool; Pages: QWord);
var
  PreviousLevel: TPriorityLevel;
begin
  if (Pool = nil) or (Pages = 0) then
    Exit;
  PreviousLevel := AcquireSpinLock(Pool^.Lock);
  Pool^.ChargedPages := Pool^.ChargedPages + Pages;
  NotePeakLocked(Pool);
  ReleaseSpinLock(Pool^.Lock, PreviousLevel);
end;

procedure UnchargeCommitPool(Pool: PCommitPool; Pages: QWord);
var
  PreviousLevel: TPriorityLevel;
begin
  if (Pool = nil) or (Pages = 0) then
    Exit;
  PreviousLevel := AcquireSpinLock(Pool^.Lock);
  if Pages > Pool^.ChargedPages then
    Pool^.ChargedPages := 0
  else
    Pool^.ChargedPages := Pool^.ChargedPages - Pages;
  ReleaseSpinLock(Pool^.Lock, PreviousLevel);
end;

function SetCommitPoolLimit(Pool: PCommitPool; LimitPages: QWord): QWord;
var
  PreviousLevel: TPriorityLevel;
begin
  PreviousLevel := AcquireSpinLock(Pool^.Lock);
  Result := Pool^.LimitPages;
  Pool^.LimitPages := LimitPages;
  ReleaseSpinLock(Pool^.Lock, PreviousLevel);
end;

{ --- The system ------------------------------------------------------- }

procedure EnsureSystemPool;
begin
  if SystemReady then
    Exit;
  InitializeCommitPool(SystemPool);
  SystemReady := True;
end;

{ Held back freed pages (PageUsageQuarantined) count as free: the
  allocator lets them go as soon as the free list runs dry. }
function KernelHeldPages: QWord;
var
  Counts: TPageUsageCounts;
begin
  GetPageUsageCounts(Counts);
  Result := Counts[PageUsageKernelImage] + Counts[PageUsageBootData] + Counts[PageUsagePageTable] +
    Counts[PageUsageFrameDatabase] + Counts[PageUsageKernelHeap] + Counts[PageUsageKernelStack] +
    Counts[PageUsageGeneral];
end;

procedure RegisterKeptPagesQuery(Query: TKeptPagesQuery);
begin
  if KeptPagesQueryCount >= MaximumKeptPagesQueries then
    Exit;
  KeptPagesQueries[KeptPagesQueryCount] := Query;
  Inc(KeptPagesQueryCount);
end;

function SumKeptPages: QWord;
var
  Index: Integer;
begin
  Result := 0;
  for Index := 0 to KeptPagesQueryCount - 1 do
    Result := Result + KeptPagesQueries[Index]();
end;

function KeptCachePages: QWord;
begin
  Result := LastKeptPages;
end;

procedure SetCommitPressureCallback(Callback: TCommitPressureCallback);
begin
  PressureCallback := Callback;
end;

{ After a charge (outside the pool's lock): the callback, if the charge
  was refused or left little headroom. }
procedure NoteSystemCharge(Charged, Limit: QWord; Refused: Boolean);
var
  Callback: TCommitPressureCallback;
  Low: QWord;
  Critical: QWord;
begin
  Callback := PressureCallback;
  if not Assigned(Callback) or (Limit = 0) then
    Exit;
  GetMemoryWatermarks(Low, Critical);
  if Refused or (CommitPressureLevel(Charged, Limit, Low, Critical) <> CommitPressureNone) then
    Callback;
end;

procedure ReadCommitLimitOption;
var
  Value: array[0..15] of Char;
  Number: QWord;
begin
  if not GetKernelOptionValue('commitlimit', @Value[0], SizeOf(Value)) then
    Exit;
  if TextIsEqual(@Value[0], 'off') then
    Policy := CommitPolicyNone
  else if GetKernelOptionNumber('commitlimit', Number) then
  begin
    Policy := CommitPolicyStrict;
    LimitPercent := Number;
  end;
  { "overcommit" (or anything else) keeps the default. }
end;

procedure LogCommitPolicy;
var
  Limit: QWord;
  Largest: QWord;
begin
  Limit := SystemPool.LimitPages;
  Largest := LargestRequestPages;
  DebugBeginMessage;
  DebugWriteTag('memory');
  case Policy of
    CommitPolicyNone:
      DebugWriteLine('commit policy: no limit (commitlimit=off)');
    CommitPolicyStrict:
      begin
        DebugWrite('commit policy: strict, ');
        DebugWriteDecimal(LimitPercent);
        DebugWrite('% of the RAM processes may use: ');
        DebugWriteSize(Limit * PageSize);
        DebugWriteLine('');
      end;
    CommitPolicyOvercommit:
      begin
        DebugWrite('commit policy: overcommit, one commitment up to ');
        DebugWriteSize(Largest * PageSize);
        DebugWrite(', all together up to ');
        DebugWriteSize(Limit * PageSize);
        DebugWriteLine('');
      end;
  end;
  DebugEndMessage;
end;

procedure InitializeSystemCommitLimit;
begin
  EnsureSystemPool;
  ReadCommitLimitOption;
  { Only strict accounting at no more than 100% backs what it promises:
    otherwise committed pages are claimed like any other. }
  SetCommitmentsBacked(CommitPolicyBacksCommitments(Policy, LimitPercent));
  RefreshSystemCommitLimit;
  LogCommitPolicy;
end;

procedure RefreshSystemCommitLimit;
var
  Physical: TPhysicalMemoryStatistics;
  Low: QWord;
  Critical: QWord;
  Limit: QWord;
  Largest: QWord;
  PreviousLevel: TPriorityLevel;
begin
  EnsureSystemPool;
  Limit := 0;
  Largest := 0;
  if Policy <> CommitPolicyNone then
  begin
    GetPhysicalMemoryStatistics(Physical);
    GetMemoryWatermarks(Low, Critical);
    LastKeptPages := SumKeptPages;
    ComputeSystemCommitLimits(Policy, Physical.TotalUsablePages, KernelHeldPages, LastKeptPages, Critical,
      LimitPercent, Limit, Largest);
  end;
  PreviousLevel := AcquireSpinLock(SystemPool.Lock);
  SystemPool.LimitPages := Limit;
  LargestRequestPages := Largest;
  ReleaseSpinLock(SystemPool.Lock, PreviousLevel);
end;

function TryChargeSystemCommit(Pages: QWord; MayUseReserve: Boolean): Boolean;
var
  PreviousLevel: TPriorityLevel;
  Charged: QWord;
  Limit: QWord;
begin
  if Pages = 0 then
    Exit(True);
  EnsureSystemPool;
  PreviousLevel := AcquireSpinLock(SystemPool.Lock);
  Result := SystemCommitAllowed(SystemPool.ChargedPages, Pages, SystemPool.LimitPages, LargestRequestPages,
    MayUseReserve);
  if Result then
  begin
    SystemPool.ChargedPages := SystemPool.ChargedPages + Pages;
    NotePeakLocked(@SystemPool);
  end
  else
  begin
    Inc(SystemPool.Failures);
    LastRefusedPages := Pages;
  end;
  Charged := SystemPool.ChargedPages;
  Limit := SystemPool.LimitPages;
  ReleaseSpinLock(SystemPool.Lock, PreviousLevel);
  NoteSystemCharge(Charged, Limit, not Result);
end;

procedure UnchargeSystemCommit(Pages: QWord);
begin
  EnsureSystemPool;
  UnchargeCommitPool(@SystemPool, Pages);
end;

function SystemCommittedPages: QWord;
begin
  Result := SystemPool.ChargedPages;
end;

function PeakSystemCommittedPages: QWord;
begin
  Result := SystemPool.PeakPages;
end;

function SystemCommitLimitPages: QWord;
begin
  Result := SystemPool.LimitPages;
end;

function SystemCommitFailures: QWord;
begin
  Result := SystemPool.Failures;
end;

function SystemCommitPolicy: TCommitPolicy;
begin
  Result := Policy;
end;

function LargestSystemCommitPages: QWord;
begin
  Result := LargestRequestPages;
end;

function LastRefusedCommitPages: QWord;
begin
  Result := LastRefusedPages;
end;

function SystemCommitmentsBacked: Boolean;
begin
  Result := CommitPolicyBacksCommitments(Policy, LimitPercent);
end;

end.
