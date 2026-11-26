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
  Scheduling groups: the threads of one process, as the scheduler sees
  them for fair share (Kernel.FairShare). A process embeds one; each of
  its threads points at it (TThreadControlBlock.SchedulingGroup; kernel
  threads have none). Every switch charges the time the thread ran to
  its group (Kernel.ProcessorTime), and a thread that used up its time
  slice is placed below its base priority while its group uses more
  than its share of the processors (Kernel.Scheduler).

  The group's lock is taken at dispatch level, inside a processor's
  scheduling lock, and nothing is taken inside it.
}
unit Kernel.SchedulingGroups;

{$mode objfpc}

interface

uses
  Kernel.SpinLock,
  Kernel.FairShare;

type
  PSchedulingGroup = ^TSchedulingGroup;
  TSchedulingGroup = record
    Lock: TSpinLock;
    Usage: TFairShareUsage;
  end;

procedure InitializeSchedulingGroup(out Group: TSchedulingGroup);
{ Charges Elapsed nanoseconds the group's thread ran until Now. }
procedure ChargeSchedulingGroup(Group: PSchedulingGroup; Elapsed, Now: QWord);
{ How many levels the group's threads lose now (Kernel.FairShare), with
  ProcessorCount processors running. }
function SchedulingGroupPenalty(Group: PSchedulingGroup; Now: QWord; ProcessorCount: LongWord): LongWord;
{ The processors the group used lately, in thousandths. }
function SchedulingGroupProcessorsUsed(Group: PSchedulingGroup; Now: QWord): QWord;

implementation

uses
  Kernel.PriorityLevel;

procedure InitializeSchedulingGroup(out Group: TSchedulingGroup);
begin
  InitializeSpinLock(Group.Lock);
  Group.Usage.DecayedNanoseconds := 0;
  Group.Usage.LastUpdate := 0;
end;

procedure ChargeSchedulingGroup(Group: PSchedulingGroup; Elapsed, Now: QWord);
var
  PreviousLevel: TPriorityLevel;
begin
  if (Group = nil) or (Elapsed = 0) then
    Exit;
  PreviousLevel := AcquireSpinLock(Group^.Lock);
  AddFairShareRunTime(Group^.Usage, Elapsed, Now);
  ReleaseSpinLock(Group^.Lock, PreviousLevel);
end;

function SchedulingGroupProcessorsUsed(Group: PSchedulingGroup; Now: QWord): QWord;
var
  PreviousLevel: TPriorityLevel;
begin
  if Group = nil then
    Exit(0);
  PreviousLevel := AcquireSpinLock(Group^.Lock);
  Result := ProcessorsUsedThousandths(Group^.Usage, Now);
  ReleaseSpinLock(Group^.Lock, PreviousLevel);
end;

function SchedulingGroupPenalty(Group: PSchedulingGroup; Now: QWord; ProcessorCount: LongWord): LongWord;
begin
  if Group = nil then
    Exit(0);
  Result := FairSharePenalty(SchedulingGroupProcessorsUsed(Group, Now), ProcessorCount);
end;

end.
