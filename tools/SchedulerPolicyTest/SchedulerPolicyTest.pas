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
  SchedulerPolicyTest

  The priority boost rules (Kernel.PriorityBoosts) on the host: wake
  boosts by reason, never past the variable class, never lowering a
  higher priority, nothing for the real-time class; decay one level per
  time slice back to the base; the starvation threshold. Then every
  base, current priority and boost: the result always lies between the
  base and the class ceiling.

  Prints every failed check and exits with 1 if there was one.
}
program SchedulerPolicyTest;

{$mode objfpc}

uses
  SysUtils,
  Kernel.PriorityBoosts;

var
  Failures: Integer = 0;

procedure Check(Condition: Boolean; const What: string);
begin
  if not Condition then
  begin
    WriteLn('FAIL: ', What);
    Inc(Failures);
  end;
end;

procedure TestWakeBoosts;
begin
  Check(BoostedPriority(8, 8, BoostEvent) = 9, 'an event raises one level');
  Check(BoostedPriority(8, 8, BoostInput) = 14, 'input raises six levels');
  Check(BoostedPriority(8, 8, BoostSound) = 15, 'sound raises to the top of the class');
  Check(BoostedPriority(12, 12, BoostInput) = 15, 'a boost stops at the top of the variable class');
  Check(BoostedPriority(8, 13, BoostEvent) = 13, 'a smaller boost does not lower a larger one');
  Check(BoostedPriority(8, 9, BoostInput) = 14, 'a larger boost replaces a smaller one');
  Check(BoostedPriority(8, 8, BoostNone) = 8, 'no boost leaves the priority');
  Check(BoostedPriority(16, 16, BoostInput) = 16, 'the real-time class is never boosted');
  Check(BoostedPriority(31, 31, BoostSound) = 31, 'the top priority is never boosted');
  Check(BoostedPriority(15, 15, BoostInput) = 15, 'the top of the variable class stays');
  Check(BoostedPriority(1, 1, BoostDisplay) = 3, 'the lowest priority is boosted too');
  Check(BoostDisplay > BoostIoCompletion, 'the display boost is above the disk boost');
  Check(BoostInput > BoostNetwork, 'the input boost is above the network boost');
end;

procedure TestDecay;
var
  Priority: LongWord;
  Slices: Integer;
begin
  Check(DecayedPriority(8, 14) = 13, 'a slice takes one level');
  Check(DecayedPriority(8, 8) = 8, 'decay stops at the base');
  Check(DecayedPriority(20, 20) = 20, 'a real-time thread does not decay');
  Priority := BoostedPriority(8, 8, BoostInput);
  Slices := 0;
  while Priority > 8 do
  begin
    Priority := DecayedPriority(8, Priority);
    Inc(Slices);
  end;
  Check(Slices = BoostInput, 'an input boost lasts as many slices as levels');
end;

procedure TestStarvation;
const
  Second = QWord(1000000000);
begin
  Check(not HasStarved(8, 8, 10 * Second, 13 * Second), 'three seconds ready is not starving');
  Check(HasStarved(8, 8, 10 * Second, 14 * Second), 'four seconds ready is starving');
  Check(HasStarved(1, 1, 0, 100 * Second), 'the lowest priority starves too');
  Check(not HasStarved(8, 15, 0, 100 * Second), 'a thread at the top of its class has not starved');
  Check(not HasStarved(16, 16, 0, 100 * Second), 'the real-time class is never starvation boosted');
  Check(not HasStarved(8, 8, 20 * Second, 10 * Second), 'a ready time in the future is not starving');
end;

procedure TestEveryCombination;
var
  Base: LongWord;
  Current: LongWord;
  Boost: LongWord;
  Priority: LongWord;
begin
  for Base := 1 to 31 do
    for Current := Base to 31 do
      for Boost := 0 to 10 do
      begin
        Priority := BoostedPriority(Base, Current, Boost);
        Check(Priority >= Current, Format('boost lowered %d/%d by %d', [Base, Current, Boost]));
        if Base >= LowestRealTimePriority then
          Check(Priority = Current, Format('real-time %d boosted', [Base]))
        else
          Check((Priority <= HighestVariablePriority) or (Priority = Current),
            Format('boost of %d/%d by %d left the class', [Base, Current, Boost]));
        Priority := DecayedPriority(Base, Current);
        Check((Priority >= Base) and (Priority <= Current), Format('decay of %d/%d out of range', [Base, Current]));
      end;
end;

begin
  TestWakeBoosts;
  TestDecay;
  TestStarvation;
  TestEveryCombination;
  if Failures > 0 then
  begin
    WriteLn('SCHEDULER POLICY TEST FAILED: ', Failures, ' checks');
    Halt(1);
  end;
  WriteLn('SCHEDULER POLICY TEST PASSED');
end.
