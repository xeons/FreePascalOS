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
  Priority boosts: the rules, kept apart from the scheduler so they can
  be checked on the host (tools/SchedulerPolicyTest).

  The 31 thread priorities fall into two classes:

    1-15   the variable class: ordinary threads, whose priority the
           scheduler raises for a while when they have waited
    16-31  the real-time class: never boosted, never decayed

  A thread has a base priority (what SetThreadPriority set) and a
  current priority, which the scheduler queues and runs it at.

  * Wake boost. A thread whose wait ends because something it waited
    for happened is raised above its base by an amount that depends on
    what woke it (the Boost* constants below, the sizes other systems
    use): input most, since someone waits for the answer, then sound,
    the network and the display, an I/O completion or another thread's
    event or semaphore least. The boosted priority never leaves the
    variable class (at most 15), and a boost never lowers a priority
    that is already higher. A wait that ends by its timeout or an alert
    gets nothing.

  * Decay. Each time slice the thread uses up, its current priority
    drops one level, back to its base and no further. A thread that
    waits again before its slice ends keeps what it has, so threads
    that wait often (interactive ones) stay ahead of those that compute.

  * Starvation boost. A ready thread of the variable class that has not
    run for StarvationNanoseconds (about 4 seconds) is raised to the top
    of the class (15) for one time slice, after which it drops straight
    back to its base. So a thread kept off the processor by busier ones
    of higher priority still makes progress, and a lock it holds is
    released at last.
}
unit Kernel.PriorityBoosts;

{$mode objfpc}

interface

const
  { The highest priority of the variable class, and the lowest of the
    real-time class. }
  HighestVariablePriority = 15;
  LowestRealTimePriority = 16;

  { Wake boosts, by what ended the wait. }
  BoostNone = 0;
  { Another thread's event, semaphore or address wake. }
  BoostEvent = 1;
  { An I/O request completed (disks and the like). }
  BoostIoCompletion = 1;
  { The display answered (a flush or mode change finished). }
  BoostDisplay = 2;
  { Data arrived from the network. }
  BoostNetwork = 2;
  { Keyboard or mouse input arrived. }
  BoostInput = 6;
  { An audio period finished (a stream must be fed in time). }
  BoostSound = 8;

  { How long a ready thread may go without running before it gets the
    starvation boost, and how often the ready queues are looked at for
    such threads (and how many threads one look may boost at most). }
  StarvationNanoseconds = QWord(4000) * 1000 * 1000;
  StarvationScanNanoseconds = QWord(1000) * 1000 * 1000;
  StarvationScanLimit = 16;

{ Whether a thread of base priority Base is in the real-time class. }
function IsRealTimePriority(Base: LongWord): Boolean;

{ The current priority after a wake boost of Boost; Current is the
  priority the thread has now. }
function BoostedPriority(Base, Current, Boost: LongWord): LongWord;

{ The current priority after the thread used up a time slice. }
function DecayedPriority(Base, Current: LongWord): LongWord;

{ Whether a ready thread whose base is Base, at current priority
  Current, waiting since ReadySince, has starved by Now. }
function HasStarved(Base, Current: LongWord; ReadySince, Now: QWord): Boolean;

implementation

function IsRealTimePriority(Base: LongWord): Boolean;
begin
  Result := Base >= LowestRealTimePriority;
end;

function BoostedPriority(Base, Current, Boost: LongWord): LongWord;
var
  Raised: LongWord;
begin
  Result := Current;
  if IsRealTimePriority(Base) or (Boost = BoostNone) then
    Exit;
  Raised := Base + Boost;
  if Raised > HighestVariablePriority then
    Raised := HighestVariablePriority;
  if Raised > Result then
    Result := Raised;
end;

function DecayedPriority(Base, Current: LongWord): LongWord;
begin
  if Current > Base then
    Result := Current - 1
  else
    Result := Base;
end;

function HasStarved(Base, Current: LongWord; ReadySince, Now: QWord): Boolean;
begin
  if IsRealTimePriority(Base) or (Current >= HighestVariablePriority) then
    Exit(False);
  if Now < ReadySince then
    Exit(False);
  Result := Now - ReadySince >= StarvationNanoseconds;
end;

end.
