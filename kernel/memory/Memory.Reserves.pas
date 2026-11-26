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
  it can: the rules, as pure arithmetic for the host test
  (tools/SchedulerPolicyTest).

  * Pages. Below the critical watermark (Memory.PhysicalPages) the free
    pages belong to the kernel and to the essential processes (the
    display server, the session manager, the desktop, the task manager:
    Processes.PriorityClassCalls): a page for an ordinary program's
    memory, a mapped file or a section is refused there - its fault then
    reclaims, and if that finds nothing a process is ended
    (Processes.OutOfMemory) - while an essential process may go down to
    half the watermark, and the kernel's own allocations (heap, stacks,
    page tables, drivers) to the last page. So closing a window, drawing
    the task manager and ending the culprit never wait for memory the
    culprit holds.

  * Commitments. The system's commit limit is the RAM processes may use
    - all of it less what the kernel holds for itself and its reserve
    (the critical watermark) - scaled by the kernel option
    commitlimit=PERCENT (100 by default; "off" for none). A commitment
    beyond it fails with ErrorOutOfMemory: a program's allocation fails
    cleanly instead of the system degrading when it touches the memory.
    The last EssentialCommitShift-th of the limit is only for essential
    processes.
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

{ Whether a page for a process's memory may be taken with FreePages
  free, CriticalPages the critical watermark; MayUseReserve for the
  kernel's threads and essential processes. }
function UserPageAllowed(FreePages, CriticalPages: QWord; MayUseReserve: Boolean): Boolean;
{ The free pages below which an allocation of that kind is refused. }
function UserPageFloor(CriticalPages: QWord; MayUseReserve: Boolean): QWord;

{ The system's commit limit: UsablePages of RAM, KernelPages held by the
  kernel, CriticalPages kept for it, scaled by Percent. At least one
  page (0 means no limit, which only "off" gives). }
function SystemCommitLimit(UsablePages, KernelPages, CriticalPages, Percent: QWord): QWord;
{ The part of Limit only essential processes may commit. }
function EssentialCommitReserve(Limit: QWord): QWord;
{ Whether Pages more may be committed with Charged committed already
  against Limit (0: no limit). }
function CommitAllowed(Charged, Pages, Limit: QWord; MayUseReserve: Boolean): Boolean;

implementation

function UserPageFloor(CriticalPages: QWord; MayUseReserve: Boolean): QWord;
begin
  if MayUseReserve then
    Result := CriticalPages div 2
  else
    Result := CriticalPages;
end;

function UserPageAllowed(FreePages, CriticalPages: QWord; MayUseReserve: Boolean): Boolean;
begin
  Result := FreePages > UserPageFloor(CriticalPages, MayUseReserve);
end;

function SystemCommitLimit(UsablePages, KernelPages, CriticalPages, Percent: QWord): QWord;
var
  Available: QWord;
begin
  if KernelPages + CriticalPages >= UsablePages then
    Available := 1
  else
    Available := UsablePages - KernelPages - CriticalPages;
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

end.
