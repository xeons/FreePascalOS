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
  * the system: SystemCommitLimit (Memory.Reserves) of the RAM
    processes may use, recomputed as the kernel's own use changes
    (RefreshSystemCommitLimit, from the memory pressure thread each
    second), the last part of it kept for essential processes.

  So a program that asks for more than there is gets an error from the
  allocation, while there is still memory for everything else, instead
  of the system running out when it touches what it was promised.
}
unit Memory.CommitCharge;

{$mode objfpc}

interface

uses
  Kernel.SpinLock;

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

{ Reads the kernel option commitlimit and sets the first limit. }
procedure InitializeSystemCommitLimit;
{ Recomputes the system's limit from the kernel's use of memory now. }
procedure RefreshSystemCommitLimit;
{ Charges Pages to the system if they fit under its limit (the whole
  limit if MayUseReserve, else all but the essential reserve). }
function TryChargeSystemCommit(Pages: QWord; MayUseReserve: Boolean): Boolean;
procedure UnchargeSystemCommit(Pages: QWord);
{ The pages committed by all processes together, the most there ever
  were, the limit (0: none) and the commitments it refused. }
function SystemCommittedPages: QWord;
function PeakSystemCommittedPages: QWord;
function SystemCommitLimitPages: QWord;
function SystemCommitFailures: QWord;

implementation

uses
  Kernel.PriorityLevel,
  Kernel.Options,
  Memory.PhysicalPages,
  Memory.Reserves;

var
  SystemPool: TCommitPool;
  SystemReady: Boolean = False;
  LimitPercent: QWord = DefaultCommitLimitPercent;
  LimitIsOff: Boolean = False;

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

{ The pages the kernel holds for itself (not caches it gives back, not
  processes' pages). }
function KernelHeldPages: QWord;
var
  Counts: TPageUsageCounts;
begin
  GetPageUsageCounts(Counts);
  Result := Counts[PageUsageKernelImage] + Counts[PageUsageBootData] + Counts[PageUsagePageTable] +
    Counts[PageUsageFrameDatabase] + Counts[PageUsageKernelHeap] + Counts[PageUsageKernelStack] +
    Counts[PageUsageGeneral] + Counts[PageUsageQuarantined];
end;

procedure InitializeSystemCommitLimit;
var
  Value: array[0..15] of Char;
  Number: QWord;
begin
  EnsureSystemPool;
  if GetKernelOptionValue('commitlimit', @Value[0], SizeOf(Value)) and
     (Value[0] = 'o') and (Value[1] = 'f') and (Value[2] = 'f') then
    LimitIsOff := True
  else if GetKernelOptionNumber('commitlimit', Number) then
    LimitPercent := Number;
  RefreshSystemCommitLimit;
end;

procedure RefreshSystemCommitLimit;
var
  Physical: TPhysicalMemoryStatistics;
  Low: QWord;
  Critical: QWord;
  Limit: QWord;
  PreviousLevel: TPriorityLevel;
begin
  EnsureSystemPool;
  if LimitIsOff then
    Limit := 0
  else
  begin
    GetPhysicalMemoryStatistics(Physical);
    GetMemoryWatermarks(Low, Critical);
    Limit := SystemCommitLimit(Physical.TotalUsablePages, KernelHeldPages, Critical, LimitPercent);
  end;
  PreviousLevel := AcquireSpinLock(SystemPool.Lock);
  SystemPool.LimitPages := Limit;
  ReleaseSpinLock(SystemPool.Lock, PreviousLevel);
end;

function TryChargeSystemCommit(Pages: QWord; MayUseReserve: Boolean): Boolean;
var
  PreviousLevel: TPriorityLevel;
begin
  if Pages = 0 then
    Exit(True);
  EnsureSystemPool;
  PreviousLevel := AcquireSpinLock(SystemPool.Lock);
  Result := CommitAllowed(SystemPool.ChargedPages, Pages, SystemPool.LimitPages, MayUseReserve);
  if Result then
  begin
    SystemPool.ChargedPages := SystemPool.ChargedPages + Pages;
    NotePeakLocked(@SystemPool);
  end
  else
    Inc(SystemPool.Failures);
  ReleaseSpinLock(SystemPool.Lock, PreviousLevel);
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

end.
