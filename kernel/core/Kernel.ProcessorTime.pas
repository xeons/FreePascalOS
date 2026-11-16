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
  Processor time: how long each thread has run, and how long each
  processor has been busy or idle.

  The time is taken at every thread switch: the processor remembers
  since when its running thread runs (RunningSince), and the switch
  charges the time since then to the thread it leaves (RunNanoseconds)
  and to the processor's busy time, or its idle time when it leaves its
  idle thread. So a thread's run time is exact to the clock rather than
  counted in 10 ms ticks: a thread that runs in short bursts between
  ticks is charged what it ran, and one the tick always catches is not
  charged whole ticks it did not use. Reading a time adds the run going
  on now, under the dispatcher lock, so a busy thread's time grows
  smoothly.

  How the run time divides between user mode and the kernel is sampled
  by the clock tick instead (UserTicks, KernelTicks: where the tick
  found the thread), since timing every system call and interrupt would
  cost every one of them something; the exact run time is split in the
  ticks' proportion (SplitRunTime).
}
unit Kernel.ProcessorTime;

{$mode objfpc}

interface

uses
  Kernel.Threads,
  Kernel.Processors;

type
  TThreadTimes = record
    RunNanoseconds: QWord;
    UserTicks: QWord;
    KernelTicks: QWord;
  end;
  PThreadTimes = ^TThreadTimes;

{ Part of a switch (dispatcher lock held): charges the time since the
  running thread began running on Processor to it and to the processor,
  and times the next run from Now. }
procedure ChargeRunningThreadLocked(Processor: PProcessor; Now: QWord);
{ The processor starts timing its runs (as it starts scheduling). }
procedure StartProcessorTime(Processor: PProcessor; Now: QWord);
{ From the clock interrupt: Ticks found Thread running, in user mode or
  in the kernel. }
procedure ChargeClockTicks(Thread: PThreadControlBlock; Ticks: QWord; InUserMode: Boolean);

{ Thread's times so far, the run going on now included. }
procedure GetThreadTimes(Thread: PThreadControlBlock; out Times: TThreadTimes);
procedure AddThreadTimes(var Total: TThreadTimes; const Times: TThreadTimes);
{ The run time divided between user mode and the kernel as the ticks
  say; all of it counts as the kernel's until a tick has been seen. }
procedure SplitRunTime(const Times: TThreadTimes; out UserNanoseconds, KernelNanoseconds: QWord);

{ How long processor Index has been busy and idle since it started (both
  zero for one that does not run), the run going on now included. }
procedure GetProcessorTimes(Index: LongWord; out BusyNanoseconds, IdleNanoseconds: QWord);

implementation

uses
  Kernel.PriorityLevel,
  Kernel.Clock,
  Kernel.Scheduler;

{ Time from Since to Now, never negative: the counters of the processors
  run together, but one may read a few cycles behind another. }
function ElapsedSince(Since, Now: QWord): QWord;
begin
  if Now > Since then
    Result := Now - Since
  else
    Result := 0;
end;

procedure ChargeRunningThreadLocked(Processor: PProcessor; Now: QWord);
var
  Elapsed: QWord;
  Thread: PThreadControlBlock;
begin
  Elapsed := ElapsedSince(Processor^.RunningSince, Now);
  Processor^.RunningSince := Now;
  Thread := Processor^.RunningThread;
  Thread^.RunNanoseconds := Thread^.RunNanoseconds + Elapsed;
  if Thread = Processor^.IdleThread then
    Processor^.IdleNanoseconds := Processor^.IdleNanoseconds + Elapsed
  else
    Processor^.BusyNanoseconds := Processor^.BusyNanoseconds + Elapsed;
end;

procedure StartProcessorTime(Processor: PProcessor; Now: QWord);
begin
  Processor^.RunningSince := Now;
  Processor^.IdleNanoseconds := 0;
  Processor^.BusyNanoseconds := 0;
end;

procedure ChargeClockTicks(Thread: PThreadControlBlock; Ticks: QWord; InUserMode: Boolean);
begin
  Thread^.RunTicks := Thread^.RunTicks + Ticks;
  if InUserMode then
    Thread^.UserTicks := Thread^.UserTicks + Ticks
  else
    Thread^.KernelTicks := Thread^.KernelTicks + Ticks;
end;

procedure GetThreadTimes(Thread: PThreadControlBlock; out Times: TThreadTimes);
var
  PreviousLevel: TPriorityLevel;
  Processor: PProcessor;
begin
  PreviousLevel := AcquireDispatcherLock;
  Times.RunNanoseconds := Thread^.RunNanoseconds;
  if Thread^.State = ThreadStateRunning then
  begin
    Processor := ProcessorByIndex(Thread^.LastProcessorIndex);
    if (Processor <> nil) and (Processor^.RunningThread = Thread) then
      Times.RunNanoseconds := Times.RunNanoseconds + ElapsedSince(Processor^.RunningSince, ClockNanoseconds);
  end;
  ReleaseDispatcherLock(PreviousLevel);
  Times.UserTicks := Thread^.UserTicks;
  Times.KernelTicks := Thread^.KernelTicks;
end;

procedure AddThreadTimes(var Total: TThreadTimes; const Times: TThreadTimes);
begin
  Total.RunNanoseconds := Total.RunNanoseconds + Times.RunNanoseconds;
  Total.UserTicks := Total.UserTicks + Times.UserTicks;
  Total.KernelTicks := Total.KernelTicks + Times.KernelTicks;
end;

procedure SplitRunTime(const Times: TThreadTimes; out UserNanoseconds, KernelNanoseconds: QWord);
var
  AllTicks: QWord;
begin
  AllTicks := Times.UserTicks + Times.KernelTicks;
  if AllTicks = 0 then
    UserNanoseconds := 0
  else
    { Whole multiples first, then the rest, so the product cannot
      overflow however long the thread ran. }
    UserNanoseconds := (Times.RunNanoseconds div AllTicks) * Times.UserTicks +
      ((Times.RunNanoseconds mod AllTicks) * Times.UserTicks) div AllTicks;
  if UserNanoseconds > Times.RunNanoseconds then
    UserNanoseconds := Times.RunNanoseconds;
  KernelNanoseconds := Times.RunNanoseconds - UserNanoseconds;
end;

procedure GetProcessorTimes(Index: LongWord; out BusyNanoseconds, IdleNanoseconds: QWord);
var
  PreviousLevel: TPriorityLevel;
  Processor: PProcessor;
  Current: QWord;
begin
  BusyNanoseconds := 0;
  IdleNanoseconds := 0;
  Processor := ProcessorByIndex(Index);
  if (Processor = nil) or not Processor^.IsOnline then
    Exit;
  PreviousLevel := AcquireDispatcherLock;
  BusyNanoseconds := Processor^.BusyNanoseconds;
  IdleNanoseconds := Processor^.IdleNanoseconds;
  Current := ElapsedSince(Processor^.RunningSince, ClockNanoseconds);
  if Processor^.RunningThread = Processor^.IdleThread then
    IdleNanoseconds := IdleNanoseconds + Current
  else
    BusyNanoseconds := BusyNanoseconds + Current;
  ReleaseDispatcherLock(PreviousLevel);
end;

end.
