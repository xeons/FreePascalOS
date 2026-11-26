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
  Self tests of the clock: the dynamic tick and the clock page.

  Dynamic tick: a thread spinning alone on a processor must leave it
  almost without ticks (the residual one a second), and a second thread
  put beside it must start the tick again, so the two share the
  processor by time slices.

  A thread that wakes now and then on that processor (as system threads
  and services do) runs at once and waits again: its sleeps and the
  kernel timers it sets there must end on time although the tick is
  deferred, and once it waits the lone thread must be left without the
  tick at once, not after one more tick each time (which made a busy
  processor take a tick for every wake-up beside it).

  Clock page: the time the page gives (its arithmetic over the counter,
  as programs do it) must agree with the kernel's clock and wall clock.
}
unit Kernel.ClockSelfTest;

{$mode objfpc}

interface

procedure RunClockSelfTests;

implementation

uses
  Abi.SystemCalls,
  Runtime.Atomic,
  Runtime.ClockPage,
  Memory.Layout,
  Kernel.Arch.Cpu,
  Kernel.Threads,
  Kernel.Scheduler,
  Kernel.Events,
  Kernel.Clock,
  Kernel.ClockPage,
  Kernel.DeferredCalls,
  Kernel.Timers,
  Kernel.WallClock,
  Kernel.Processors,
  Objects.Manager,
  Processes.Thread,
  Kernel.SelfTest;

const
  SpinnerCount = 2;
  SettleMilliseconds = 100;
  QuietMilliseconds = 500;
  { Over QuietMilliseconds a periodic tick takes 50; the residual tick
    one, and a few for whatever else woke there. }
  QuietTickLimit = 10;
  ShareMilliseconds = 200;
  WaitLimitMilliseconds = 2000;
  { The waker: sleeps, then waits for kernel timers, on the processor of
    the lone spinner, at a priority above it (as system threads are). }
  WakerPriority = DefaultThreadPriority + 4;
  WakerSleeps = 25;
  WakerTimers = 10;
  WakerWaitMilliseconds = 20;
  { Over the waker's 35 wake-ups: one tick each without the immediate
    deferral; the residual tick and a few for whatever else woke there
    with it. }
  WakerTickLimit = 10;
  { A sleep or timer is late by more than this only if its clock
    interrupt waited for a tick that was deferred. }
  WakerLatenessLimitMilliseconds = 100;
  { The page's time and the kernel's, read one after the other. }
  ClockAgreementNanoseconds = 2 * NanosecondsPerMillisecond;

var
  TestProcessor: LongWord;
  StopSpinners: PtrUInt;
  SpinnerArrived: array[0..SpinnerCount - 1] of PtrUInt;
  SpinnerProgress: array[0..SpinnerCount - 1] of Int64;
  SpinnersFinished: Int64;
  StartedSpinners: Int64;
  AllSpinnersFinished: TEvent;
  WakerArrived: PtrUInt;
  WakerGo: TEvent;
  WakerFinished: TEvent;
  WakerTimerExpired: TEvent;
  WakerTimerFiredAt: QWord;
  WakerSleepLateness: QWord;
  WakerTimerLateness: QWord;

function LastOnlineProcessor: LongWord;
var
  Index: LongWord;
begin
  Result := 0;
  for Index := 0 to ProcessorTotal - 1 do
    if ProcessorByIndex(Index)^.IsOnline then
      Result := Index;
end;

function WaitForFlag(var Flag: PtrUInt): Boolean;
var
  Deadline: QWord;
begin
  Deadline := DeadlineAfterMilliseconds(WaitLimitMilliseconds);
  while AtomicLoad(Flag) = 0 do
  begin
    if ClockNanoseconds >= Deadline then
      Exit(False);
    SleepMilliseconds(1);
  end;
  Result := True;
end;

{ Spins on the test processor without ever waiting. }
procedure SpinnerMain(Context: Pointer);
var
  Index: PtrUInt;
begin
  Index := PtrUInt(Context);
  SetThreadAffinity(CurrentThread, QWord(1) shl TestProcessor);
  while CurrentProcessorIndex <> TestProcessor do
    YieldExecution;
  AtomicStore(SpinnerArrived[Index], 1);
  while AtomicLoad(StopSpinners) = 0 do
    AtomicIncrement(SpinnerProgress[Index]);
  if AtomicIncrement(SpinnersFinished) = StartedSpinners then
    SignalEvent(AllSpinnersFinished);
end;

function StartSpinner(Index: PtrUInt): PThread;
begin
  AtomicIncrement(StartedSpinners);
  Result := CreateSystemThread(@SpinnerMain, Pointer(Index), DefaultThreadPriority, 'TickSpinner', True);
  Check(Result <> nil, 'could not create a dynamic tick spinner');
  Check(WaitForFlag(SpinnerArrived[Index]), 'a dynamic tick spinner did not reach its processor');
end;

procedure NoteWakerTimer(Context: Pointer);
begin
  WakerTimerFiredAt := ClockNanoseconds;
  SignalEvent(WakerTimerExpired);
end;

function LatenessAfter(Start: QWord; Finish: QWord): QWord;
var
  Wanted: QWord;
begin
  Wanted := Start + WakerWaitMilliseconds * NanosecondsPerMillisecond;
  if Finish > Wanted then
    Result := Finish - Wanted
  else
    Result := 0;
end;

{ On the spinner's processor: sleeps, then sets kernel timers there and
  waits for them, noting how late each ended. }
procedure WakerMain(Context: Pointer);
var
  Round: Integer;
  Start: QWord;
  Lateness: QWord;
  Timer: TTimer;
  Call: TDeferredCall;
begin
  SetThreadAffinity(CurrentThread, QWord(1) shl TestProcessor);
  while CurrentProcessorIndex <> TestProcessor do
    YieldExecution;
  AtomicStore(WakerArrived, 1);
  WaitForEvent(WakerGo);
  WakerSleepLateness := 0;
  WakerTimerLateness := 0;
  for Round := 1 to WakerSleeps do
  begin
    Start := ClockNanoseconds;
    SleepMilliseconds(WakerWaitMilliseconds);
    Lateness := LatenessAfter(Start, ClockNanoseconds);
    if Lateness > WakerSleepLateness then
      WakerSleepLateness := Lateness;
  end;
  InitializeTimer(Timer);
  InitializeDeferredCall(Call, @NoteWakerTimer, nil);
  for Round := 1 to WakerTimers do
  begin
    Start := ClockNanoseconds;
    { Set on this processor's timer queue, whose tick is deferred while
      this thread waits. }
    SetTimer(Timer, WakerWaitMilliseconds, Call);
    WaitForEvent(WakerTimerExpired);
    Lateness := LatenessAfter(Start, WakerTimerFiredAt);
    if Lateness > WakerTimerLateness then
      WakerTimerLateness := Lateness;
  end;
  { The call lives on this stack: no processor may still be in it. }
  CancelDeferredCall(Call);
  SignalEvent(WakerFinished);
end;

{ A thread waking now and then beside the lone spinner: its waits end
  on time, and the spinner is left without the tick each time it waits. }
procedure CheckWakerBesideLoneThread(Processor: PProcessor);
var
  Waker: PThread;
  TicksBefore: QWord;
  Ticks: QWord;
begin
  WakerArrived := 0;
  InitializeEvent(WakerGo, EventKindNotification, False);
  InitializeEvent(WakerFinished, EventKindNotification, False);
  InitializeEvent(WakerTimerExpired, EventKindSynchronization, False);
  Waker := CreateSystemThread(@WakerMain, nil, WakerPriority, 'TickWaker', True);
  Check(Waker <> nil, 'could not create the dynamic tick waker');
  Check(WaitForFlag(WakerArrived), 'the dynamic tick waker did not reach its processor');
  { Let the spinner's tick be deferred again after the waker's arrival. }
  SleepMilliseconds(SettleMilliseconds);
  TicksBefore := Processor^.TickInterruptCount;
  SignalEvent(WakerGo);
  WaitForEvent(WakerFinished);
  Ticks := Processor^.TickInterruptCount - TicksBefore;
  DereferenceObject(Waker);
  Check(WakerSleepLateness <= WakerLatenessLimitMilliseconds * NanosecondsPerMillisecond,
    'a sleep on a processor whose tick was deferred ended far too late');
  Check(WakerTimerLateness <= WakerLatenessLimitMilliseconds * NanosecondsPerMillisecond,
    'a timer set on a processor whose tick was deferred expired far too late');
  Check(Ticks <= WakerTickLimit,
    'a lone thread took a tick for every wake-up of a thread beside it (the tick was not deferred when it waited)');
end;

procedure TestDynamicTick;
var
  Processor: PProcessor;
  Threads: array[0..SpinnerCount - 1] of PThread;
  Index: Integer;
  TicksBefore: QWord;
  Quiet: QWord;
  ProgressBefore: Int64;
begin
  if not ClockHasDynamicTick then
  begin
    ReportPassed('dynamic tick (off: nothing to check)');
    Exit;
  end;
  if OnlineProcessorCount < 2 then
  begin
    ReportPassed('dynamic tick (one processor: nothing to check)');
    Exit;
  end;
  TestProcessor := LastOnlineProcessor;
  Processor := ProcessorByIndex(TestProcessor);
  SetThreadAffinity(CurrentThread, AllProcessors and not (QWord(1) shl TestProcessor));
  while CurrentProcessorIndex = TestProcessor do
    YieldExecution;
  StopSpinners := 0;
  SpinnersFinished := 0;
  StartedSpinners := 0;
  for Index := 0 to SpinnerCount - 1 do
  begin
    SpinnerArrived[Index] := 0;
    SpinnerProgress[Index] := 0;
  end;
  InitializeEvent(AllSpinnersFinished, EventKindNotification, False);

  { Alone: hardly a tick. }
  Threads[0] := StartSpinner(0);
  SleepMilliseconds(SettleMilliseconds);
  TicksBefore := Processor^.TickInterruptCount;
  SleepMilliseconds(QuietMilliseconds);
  Quiet := Processor^.TickInterruptCount - TicksBefore;
  Check(Processor^.TickDeferralCount > 0, 'the tick of a processor with one thread was never deferred');
  Check(Quiet <= QuietTickLimit, 'a thread running alone still took the periodic tick (no dynamic tick)');

  CheckWakerBesideLoneThread(Processor);

  { A second thread beside it: the tick is back and they share. }
  TicksBefore := Processor^.TickInterruptCount;
  Threads[1] := StartSpinner(1);
  ProgressBefore := AtomicLoad(PtrUInt(SpinnerProgress[0]));
  AtomicStore(PtrUInt(SpinnerProgress[1]), 0);
  SleepMilliseconds(ShareMilliseconds);
  Check(AtomicLoad(PtrUInt(SpinnerProgress[1])) > 0, 'a thread put beside a lone one never ran (the tick stayed deferred)');
  Check(AtomicLoad(PtrUInt(SpinnerProgress[0])) > ProgressBefore, 'the first thread stopped running once a second joined it');
  Check(Processor^.TickInterruptCount - TicksBefore > Quiet, 'the tick did not start again for two threads');

  AtomicStore(StopSpinners, 1);
  WaitForEvent(AllSpinnersFinished);
  for Index := 0 to SpinnerCount - 1 do
    DereferenceObject(Threads[Index]);
  SetThreadAffinity(CurrentThread, AllProcessors);
  ReportPassed('dynamic tick (a lone thread takes no tick, nor for threads waking beside it, whose sleeps and timers end on time; a second one brings it back)');
end;

function Distance(First, Second: Int64): QWord;
begin
  if First > Second then
    Result := QWord(First - Second)
  else
    Result := QWord(Second - First);
end;

procedure TestClockPage;
var
  Page: PAbiClockPage;
  Uptime: QWord;
  KernelTime: QWord;
  Wall: Int64;
begin
  Check(ClockPagePhysicalAddress <> 0, 'there is no clock page');
  Page := PAbiClockPage(PhysicalToVirtual(ClockPagePhysicalAddress));
  Check((Page^.Sequence and 1) = 0, 'the clock page is left half written');
  if Page^.Mode <> ClockPageModeCounter then
  begin
    ReportPassed('clock page (the clock is not a counter programs read: system calls)');
    Exit;
  end;
  Uptime := ClockPageUptimeAt(Page^, ReadTimeStampCounter);
  KernelTime := ClockNanoseconds;
  Check(Distance(Int64(Uptime), Int64(KernelTime)) < ClockAgreementNanoseconds,
    'the clock page''s uptime disagrees with the kernel''s clock');
  Wall := ClockPageWallClockAt(Page^, ClockNanoseconds);
  Check(Distance(Wall, WallClockNanoseconds) < ClockAgreementNanoseconds,
    'the clock page''s wall clock disagrees with the kernel''s');
  ReportPassed('clock page (its time is the kernel''s)');
end;

procedure RunClockSelfTests;
begin
  TestClockPage;
  TestDynamicTick;
end;

end.
