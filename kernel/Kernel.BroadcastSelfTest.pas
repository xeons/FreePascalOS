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
  Self test of the broadcast timer (Kernel.BroadcastTimer), which wakes
  processors whose own timer stops in deep idle states. Test machines
  have no such states, so for the test every idle wait of the other
  processors is made one (as with idlebroadcast=force: their timer left
  at its longest, 4 s): this thread, pinned to the last processor,
  sleeps 20 ms ten times, and each sleep must end on time - only the
  boot processor's clock interrupt can wake that processor then - and
  the broadcast must have woken it at least that often.
}
unit Kernel.BroadcastSelfTest;

{$mode objfpc}

interface

procedure RunBroadcastSelfTest;

implementation

uses
  Kernel.Clock,
  Kernel.Threads,
  Kernel.Scheduler,
  Kernel.Processors,
  Kernel.IdleStates,
  Kernel.BroadcastTimer,
  Kernel.SelfTest;

const
  SleepCount = 10;
  SleepLength = 20;
  { Late by more than this: the broadcast did not wake it (the
    processor's own stopped timer would take seconds). }
  LatenessLimitNanoseconds = 40 * NanosecondsPerMillisecond;
  MaximumMoveYields = 1000;

procedure RunBroadcastSelfTest;
var
  Thread: PThreadControlBlock;
  OldMask: QWord;
  Target: LongWord;
  Yields: Integer;
  Before: QWord;
  Start: QWord;
  Elapsed: QWord;
  Longest: QWord;
  Index: Integer;
  WasForced: Boolean;
begin
  if OnlineProcessorCount < 2 then
  begin
    ReportPassed('broadcast timer (one processor: nothing to check)');
    Exit;
  end;
  Target := ProcessorTotal - 1;
  Thread := CurrentThread;
  OldMask := ExchangeThreadAffinity(Thread, QWord(1) shl Target);
  Yields := 0;
  while (CurrentProcessor^.Index <> Target) and (Yields < MaximumMoveYields) do
  begin
    YieldExecution;
    Inc(Yields);
  end;
  Check(CurrentProcessor^.Index = Target, 'broadcast timer: the test thread did not move');
  WasForced := ForcedBroadcastIsOn;
  SetForcedBroadcast(True);
  Before := BroadcastWakeCount;
  Longest := 0;
  for Index := 1 to SleepCount do
  begin
    Start := ClockNanoseconds;
    SleepMilliseconds(SleepLength);
    Elapsed := ClockNanoseconds - Start;
    Check(Elapsed >= SleepLength * NanosecondsPerMillisecond, 'broadcast timer: a sleep ended early');
    if Elapsed > Longest then
      Longest := Elapsed;
  end;
  SetForcedBroadcast(WasForced);
  ExchangeThreadAffinity(Thread, OldMask);
  Check(Longest <= SleepLength * NanosecondsPerMillisecond + LatenessLimitNanoseconds,
    'broadcast timer: a sleep ended late (the boot processor did not wake its processor)');
  Check(BroadcastWakeCount - Before >= SleepCount, 'broadcast timer: the boot processor woke the processor too rarely');
  ReportPassed('broadcast timer (idle processors whose timer stops are woken on time)');
end;

end.
