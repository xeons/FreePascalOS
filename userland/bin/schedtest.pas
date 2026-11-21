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
  schedtest - checks the scheduler's fairness and its synchronization

  schedtest [--stress-only]

  Run by coretest. With the process held to one processor:

    * interactive latency: a thread computing without pause and this
      thread, of the same priority, waiting again and again for a timer
      a few milliseconds off: the wake boost lets it in at once, not
      after the busy thread's 20 ms time slice;
    * starvation: a thread one priority below the busy one does not run
      at first, but within some seconds (the starvation boost, after
      about 4 s ready) it does.

  Then, on every processor (the stress run, alone with --stress-only):
  threads in a ring each wait for their semaphore and release the
  next's, many rounds over, together with pairs ping-ponging an event,
  so wake-ups cross processors all the time; every hand-over must
  arrive and the counts must add up.

  Prints a line per check and "schedtest: N of M checks passed"; the exit
  status is 1 if any failed.
}
program SchedTest;

{$mode objfpc}

uses
  Abi.SystemCalls,
  SysUtils,
  Sys.Kernel,
  Sys.Objects,
  Sys.Processes,
  Sys.Streams,
  Sys.Threads,
  Sys.Time;

const
  LatencyRounds = 30;
  LatencyTimerMilliseconds = 3;
  { Well under the busy thread's time slice (20 ms). }
  LatencyLimitNanoseconds = 5 * 1000 * 1000;
  { Starvation boost after about 4 s ready; it must not come long
    before, and must have come well after. }
  StarvationQuietMilliseconds = 2000;
  StarvationWaitMilliseconds = 9000;

  RingThreadCount = 12;
  RingRounds = 400;
  PingPongPairs = 3;
  PingPongRounds = 2000;
  StressWaitMilliseconds = 120000;

var
  Failures: Integer = 0;
  Checks: Integer = 0;

procedure Check(const Name: string; Passed: Boolean);
begin
  Inc(Checks);
  if Passed then
    WriteString(StandardOutput, Format('schedtest: pass: %s'#10, [Name]))
  else
  begin
    WriteString(StandardOutput, Format('schedtest: FAIL: %s'#10, [Name]));
    Inc(Failures);
  end;
  FlushStream(StandardOutput);
end;

procedure Note(const Text: string);
begin
  WriteString(StandardOutput, 'schedtest: ' + Text + #10);
  FlushStream(StandardOutput);
end;

function UptimeNanoseconds: QWord;
begin
  Result := QWord(KernelGetTime(TimeUptimeNanoseconds));
end;

function LowerCurrentThreadPriority(Offset: LongInt): Boolean;
begin
  Result := ThreadSetPriority(TThreadID(CurrentThreadHandle), Offset);
end;

{ --- One processor: latency and starvation --- }

var
  StopBusy: LongInt = 0;
  BusySpins: QWord = 0;
  LowLowered: LongInt = 0;
  LowSpins: QWord = 0;

function BusyMain(Argument: Pointer): LongInt;
begin
  while InterlockedCompareExchange(StopBusy, 0, 0) = 0 do
    Inc(BusySpins);
  Result := 0;
end;

function LowMain(Argument: Pointer): LongInt;
begin
  LowerCurrentThreadPriority(-1);
  InterlockedExchange(LowLowered, 1);
  while InterlockedCompareExchange(StopBusy, 0, 0) = 0 do
    Inc(LowSpins);
  Result := 0;
end;

function ReadLowSpins: QWord;
begin
  ReadBarrier;
  Result := LowSpins;
end;

procedure TestInteractiveLatency;
var
  Timer: Int64;
  Round: Integer;
  Started: QWord;
  Latency: Int64;
  Slow: Integer;
  Worst: Int64;
begin
  Timer := CreateTimer(False);
  Slow := 0;
  Worst := 0;
  for Round := 1 to LatencyRounds do
  begin
    Started := UptimeNanoseconds;
    SetTimer(Timer, LatencyTimerMilliseconds, 0);
    if WaitForHandle(Timer, 5000) <> ErrorNone then
    begin
      Inc(Slow);
      Continue;
    end;
    Latency := Int64(UptimeNanoseconds - Started) - Int64(LatencyTimerMilliseconds) * 1000 * 1000;
    if Latency > Worst then
      Worst := Latency;
    if Latency > LatencyLimitNanoseconds then
      Inc(Slow);
  end;
  CloseHandle(Timer);
  Note(Format('interactive wakes: %d of %d late, the worst %d us after due', [Slow, LatencyRounds,
    Worst div 1000]));
  Check('an interactive thread runs at once beside a busy one', Slow <= LatencyRounds div 4);
end;

procedure TestStarvation;
var
  Low: Int64;
  Waited: Integer;
  QuietSpins: QWord;
  ExitCode: LongInt;
begin
  Low := CreateThread(@LowMain, nil);
  Check('the low priority thread started', Low >= 0);
  Waited := 0;
  while (InterlockedCompareExchange(LowLowered, 0, 0) = 0) and (Waited < 10000) do
  begin
    SleepMilliseconds(10);
    Inc(Waited, 10);
  end;
  Check('the low priority thread lowered its priority', LowLowered = 1);
  SleepMilliseconds(100);
  QuietSpins := ReadLowSpins;
  SleepMilliseconds(StarvationQuietMilliseconds);
  Check('a lower priority thread waits while a busy one runs', ReadLowSpins = QuietSpins);
  Waited := StarvationQuietMilliseconds;
  while (ReadLowSpins = QuietSpins) and (Waited < StarvationWaitMilliseconds) do
  begin
    SleepMilliseconds(100);
    Inc(Waited, 100);
  end;
  Note(Format('the starved thread ran after about %d ms', [Waited + 100]));
  Check('a starved thread runs at last (starvation boost)', ReadLowSpins <> QuietSpins);
  InterlockedExchange(StopBusy, 1);
  if Low >= 0 then
  begin
    WaitForThread(Low, 10000, ExitCode);
    CloseThreadHandle(Low);
  end;
end;

procedure TestOnOneProcessor;
var
  Busy: Int64;
  ExitCode: LongInt;
begin
  Check('held to one processor', KernelSetAffinity(0, 1) >= 0);
  StopBusy := 0;
  Busy := CreateThread(@BusyMain, nil);
  Check('the busy thread started', Busy >= 0);
  SleepMilliseconds(50);
  TestInteractiveLatency;
  TestStarvation;
  InterlockedExchange(StopBusy, 1);
  if Busy >= 0 then
  begin
    WaitForThread(Busy, 10000, ExitCode);
    CloseThreadHandle(Busy);
  end;
  KernelSetAffinity(0, High(QWord));
end;

{ --- Every processor: wake-ups crossing processors --- }

var
  RingSemaphores: array[0..RingThreadCount - 1] of Int64;
  RingPasses: array[0..RingThreadCount - 1] of LongInt;
  RingFailures: LongInt = 0;
  PingEvents: array[0..PingPongPairs * 2 - 1] of Int64;
  PingCounts: array[0..PingPongPairs * 2 - 1] of LongInt;
  PingFailures: LongInt = 0;

{ Waits for its semaphore, then releases the next one's, RingRounds
  times. Thread 0's semaphore starts with one count: the token. }
function RingMain(Argument: Pointer): LongInt;
var
  Index: PtrInt;
  Next: PtrInt;
  Round: Integer;
  Previous: LongInt;
begin
  Index := PtrInt(Argument);
  Next := (Index + 1) mod RingThreadCount;
  for Round := 1 to RingRounds do
  begin
    if WaitForHandle(RingSemaphores[Index], StressWaitMilliseconds) <> ErrorNone then
    begin
      InterlockedIncrement(RingFailures);
      Exit(1);
    end;
    Inc(RingPasses[Index]);
    if ReleaseSemaphore(RingSemaphores[Next], 1, Previous) <> ErrorNone then
      InterlockedIncrement(RingFailures);
  end;
  Result := 0;
end;

{ One side of a pair: waits for its event, signals the other's. The
  even side starts by signaling. }
function PingMain(Argument: Pointer): LongInt;
var
  Index: PtrInt;
  Partner: PtrInt;
  Round: Integer;
begin
  Index := PtrInt(Argument);
  Partner := Index xor 1;
  if (Index and 1) = 0 then
    SetEvent(PingEvents[Partner]);
  for Round := 1 to PingPongRounds do
  begin
    if WaitForHandle(PingEvents[Index], StressWaitMilliseconds) <> ErrorNone then
    begin
      InterlockedIncrement(PingFailures);
      Exit(1);
    end;
    Inc(PingCounts[Index]);
    if not (((Index and 1) = 0) and (Round = PingPongRounds)) then
      SetEvent(PingEvents[Partner]);
  end;
  Result := 0;
end;

procedure TestCrossProcessorStress;
var
  Threads: array[0..RingThreadCount + PingPongPairs * 2 - 1] of Int64;
  Index: Integer;
  ExitCode: LongInt;
  AllEnded: Boolean;
  Total: Int64;
  Started: QWord;
begin
  Started := UptimeNanoseconds;
  for Index := 0 to RingThreadCount - 1 do
  begin
    if Index = 0 then
      RingSemaphores[Index] := CreateSemaphore(1, 1)
    else
      RingSemaphores[Index] := CreateSemaphore(0, 1);
    RingPasses[Index] := 0;
  end;
  for Index := 0 to PingPongPairs * 2 - 1 do
  begin
    PingEvents[Index] := CreateEvent(False, False);
    PingCounts[Index] := 0;
  end;
  for Index := 0 to RingThreadCount - 1 do
    Threads[Index] := CreateThread(@RingMain, Pointer(PtrInt(Index)));
  for Index := 0 to PingPongPairs * 2 - 1 do
    Threads[RingThreadCount + Index] := CreateThread(@PingMain, Pointer(PtrInt(Index)));

  AllEnded := True;
  for Index := 0 to High(Threads) do
  begin
    if (Threads[Index] < 0) or (WaitForThread(Threads[Index], StressWaitMilliseconds, ExitCode) <> 0) or
       (ExitCode <> 0) then
      AllEnded := False;
    if Threads[Index] >= 0 then
      CloseThreadHandle(Threads[Index]);
  end;
  Check('stress: every thread ended', AllEnded);
  Check('stress: every ring hand-over arrived', RingFailures = 0);
  Total := 0;
  for Index := 0 to RingThreadCount - 1 do
    Inc(Total, RingPasses[Index]);
  Check('stress: the token went round every time', Total = RingThreadCount * RingRounds);
  Check('stress: the token is back where it started', GetSemaphoreCount(RingSemaphores[0]) = 1);
  Check('stress: every ping was answered', PingFailures = 0);
  Total := 0;
  for Index := 0 to PingPongPairs * 2 - 1 do
    Inc(Total, PingCounts[Index]);
  Check('stress: the pings add up', Total = PingPongPairs * 2 * PingPongRounds);
  for Index := 0 to RingThreadCount - 1 do
    CloseHandle(RingSemaphores[Index]);
  for Index := 0 to PingPongPairs * 2 - 1 do
    CloseHandle(PingEvents[Index]);
  Note(Format('stress: %d hand-overs in %d ms', [RingThreadCount * RingRounds + PingPongPairs * 2 * PingPongRounds,
    (UptimeNanoseconds - Started) div 1000000]));
end;

begin
  if not ((ParamCount = 1) and (ParamStr(1) = '--stress-only')) then
    TestOnOneProcessor;
  TestCrossProcessorStress;
  WriteString(StandardOutput, Format('schedtest: %d of %d checks passed'#10, [Checks - Failures, Checks]));
  FlushStream(StandardOutput);
  if Failures > 0 then
    Halt(1);
end.
