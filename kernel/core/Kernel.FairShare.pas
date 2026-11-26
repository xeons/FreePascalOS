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
  Fair share between processes: a process with many busy threads must
  not get many times the processor time of one with a single thread
  at the same priority. The arithmetic, kept apart from the scheduler
  so it can be checked on the host (tools/SchedulerPolicyTest).

  Each process (its scheduling group, Kernel.Threads) keeps the time its
  threads ran, decayed by half every FairShareHalfLifeNanoseconds. A
  group running on K processors all the time settles at K * H / ln 2
  (H the half-life), so the decayed time says how many processors the
  group has been using lately (ProcessorsUsedThousandths).

  A group using more than its allowance - one processor, or half of
  them when there are more than two - has its threads that use up
  their time slices run below their base priority: one level for going
  over, one more for every further quarter of the processors, at most
  MaximumFairSharePenalty levels and never below priority 1. The
  penalty applies only to threads of the variable class, only after a
  slice was used up (a thread that waits keeps its wake boosts) and is
  looked at again at every slice, so it goes as soon as the group uses
  less. A busy process still gets every processor nobody else wants;
  it only stops crowding out the others.
}
unit Kernel.FairShare;

{$mode objfpc}

interface

const
  FairShareHalfLifeNanoseconds = QWord(500) * 1000 * 1000;
  MaximumFairSharePenalty = 2;
  { One processor, in thousandths. }
  OneProcessor = 1000;

type
  { A group's decayed run time. }
  TFairShareUsage = record
    DecayedNanoseconds: QWord;
    { When it was last decayed (clock nanoseconds). }
    LastUpdate: QWord;
  end;

{ Usage decayed to Now. }
procedure DecayFairShareUsage(var Usage: TFairShareUsage; Now: QWord);
{ Charges Elapsed nanoseconds of run time at Now. }
procedure AddFairShareRunTime(var Usage: TFairShareUsage; Elapsed, Now: QWord);
{ How many processors the group has used lately, in thousandths. }
function ProcessorsUsedThousandths(var Usage: TFairShareUsage; Now: QWord): QWord;
{ The levels a group using UsedThousandths of ProcessorCount
  processors loses (0 within its allowance). }
function FairSharePenalty(UsedThousandths: QWord; ProcessorCount: LongWord): LongWord;
{ The priority of a thread of base Base that used up its slice, after
  the boost decay left it at Decayed (Kernel.PriorityBoosts), with the
  group's Penalty: a boost is kept, at the base the penalty applies. }
function FairSharePriority(Base, Decayed, Penalty: LongWord): LongWord;

implementation

uses
  Kernel.PriorityBoosts;

const
  { 2^(-i/16), i = 0..15, in 16.16 fixed point. }
  FractionalHalving: array[0..15] of QWord = (
    65536, 62757, 60097, 57548, 55109, 52773, 50535, 48393,
    46341, 44376, 42495, 40693, 38968, 37316, 35734, 34219);
  { ln 2 in thousandths. }
  NaturalLogTwoThousandths = 693;
  DecayStepNanoseconds = FairShareHalfLifeNanoseconds div 16;

procedure DecayFairShareUsage(var Usage: TFairShareUsage; Now: QWord);
var
  Steps: QWord;
begin
  if Now <= Usage.LastUpdate then
    Exit;
  { Decayed in sixteenths of a half-life; time short of one is kept for
    the next call (charges come every few milliseconds). }
  Steps := (Now - Usage.LastUpdate) div DecayStepNanoseconds;
  if Steps = 0 then
    Exit;
  Usage.LastUpdate := Usage.LastUpdate + Steps * DecayStepNanoseconds;
  if Steps >= 64 * 16 then
  begin
    Usage.DecayedNanoseconds := 0;
    Exit;
  end;
  Usage.DecayedNanoseconds := Usage.DecayedNanoseconds shr (Steps div 16);
  Usage.DecayedNanoseconds := (Usage.DecayedNanoseconds * FractionalHalving[Steps mod 16]) shr 16;
end;

procedure AddFairShareRunTime(var Usage: TFairShareUsage; Elapsed, Now: QWord);
begin
  DecayFairShareUsage(Usage, Now);
  Usage.DecayedNanoseconds := Usage.DecayedNanoseconds + Elapsed;
end;

function ProcessorsUsedThousandths(var Usage: TFairShareUsage; Now: QWord): QWord;
begin
  DecayFairShareUsage(Usage, Now);
  Result := (Usage.DecayedNanoseconds div 1000) * NaturalLogTwoThousandths div
    (FairShareHalfLifeNanoseconds div 1000);
end;

function FairSharePenalty(UsedThousandths: QWord; ProcessorCount: LongWord): LongWord;
var
  Allowance: QWord;
  Step: QWord;
  Over: QWord;
begin
  if ProcessorCount = 0 then
    ProcessorCount := 1;
  Allowance := QWord(ProcessorCount) * OneProcessor div 2;
  if Allowance < OneProcessor then
    Allowance := OneProcessor;
  if UsedThousandths <= Allowance then
    Exit(0);
  Step := QWord(ProcessorCount) * OneProcessor div 4;
  if Step < OneProcessor then
    Step := OneProcessor;
  Over := UsedThousandths - Allowance;
  Result := 1 + LongWord(Over div Step);
  if Result > MaximumFairSharePenalty then
    Result := MaximumFairSharePenalty;
end;

function FairSharePriority(Base, Decayed, Penalty: LongWord): LongWord;
begin
  if IsRealTimePriority(Base) or (Decayed > Base) or (Penalty = 0) then
    Exit(Decayed);
  if Base <= Penalty then
    Exit(1);
  Result := Base - Penalty;
end;

end.
