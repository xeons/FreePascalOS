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
  Timers: a deferred call that runs once a time has passed.

  A driver that must notice when something does not happen in time (a
  device that never interrupts) sets a timer before it starts waiting
  and cancels it when the event arrives:

    InitializeTimer(Port^.Timeout);
    InitializeDeferredCall(Port^.TimedOut, @HandleTimeout, Port);
    ...
    SetTimer(Port^.Timeout, 5000, Port^.TimedOut);
    ...
    CancelTimer(Port^.Timeout);

  A timer goes on the queue of the processor that sets it, which asks
  for its clock interrupt to come when the first timer is due
  (Kernel.Clock); that interrupt queues the call, which then runs at
  DispatchLevel. Timers are as fine as the clock (well under a
  millisecond) and never expire early. Cancelling cannot take back a
  call that is already queued, so the routine must check whether its
  reason still holds.

  Each queue has a lock of its own, taken by its processor's clock
  interrupt. Setting and cancelling also take one lock shared by all
  timers, so that two of them changing the same timer at once (from
  different processors) cannot put it on two queues.
}
unit Kernel.Timers;

{$mode objfpc}

interface

uses
  Runtime.LinkedList,
  Kernel.DeferredCalls,
  Kernel.Processors;

type
  PTimer = ^TTimer;
  TTimer = record
    Link: TListEntry;
    { In clock nanoseconds (Kernel.Clock). }
    DueTime: QWord;
    Call: PDeferredCall;
    { The processor whose queue it is on while set. }
    Processor: PProcessor;
    IsSet: Boolean;
  end;

{ On the boot processor at startup; InitializeProcessorTimers for each
  other processor before it runs. }
procedure InitializeTimers;
procedure InitializeProcessorTimers(Processor: PProcessor);
procedure InitializeTimer(out Timer: TTimer);
{ Sets Timer to queue Call after Milliseconds; a timer that is already
  set is moved to the new time. Any level up to DispatchLevel. }
procedure SetTimer(var Timer: TTimer; Milliseconds: QWord; var Call: TDeferredCall);
{ The same, due at DueTime (a ClockNanoseconds time; one already past
  is due at once). }
procedure SetTimerAt(var Timer: TTimer; DueTime: QWord; var Call: TDeferredCall);
{ Returns True if the timer was set (and now is not). }
function CancelTimer(var Timer: TTimer): Boolean;

{ Called by the executing processor's clock interrupt: queues the calls
  of its timers due by Now. }
procedure ExpireTimers(Now: QWord);

implementation

uses
  Kernel.Arch.Cpu,
  Kernel.SpinLock,
  Kernel.Clock;

var
  { Serializes setting and cancelling (taken before a queue's lock). }
  TimerChangeLock: TSpinLock;

function TimerOfLink(Entry: PListEntry): PTimer;
begin
  Result := PTimer(ContainingRecord(Entry, FieldOffset(PTimer(nil)^.Link)));
end;

{ The processor's queue lock held. }
procedure UpdateNextDueTimeLocked(Processor: PProcessor);
var
  First: PListEntry;
begin
  First := FirstListEntry(Processor^.TimerQueue);
  if First = nil then
    Processor^.NextTimerDueTime := NeverDue
  else
    Processor^.NextTimerDueTime := TimerOfLink(First)^.DueTime;
end;

{ Takes the timer off its queue if it is set; the change lock held. A
  timer that went off meanwhile is no longer set. }
function RemoveSetTimer(var Timer: TTimer): Boolean;
var
  Processor: PProcessor;
begin
  Result := False;
  Processor := Timer.Processor;
  if Processor = nil then
    Exit;
  AcquireSpinLockAtCurrentLevel(Processor^.TimerQueueLock);
  if Timer.IsSet then
  begin
    RemoveListEntry(@Timer.Link);
    Timer.IsSet := False;
    UpdateNextDueTimeLocked(Processor);
    Result := True;
  end;
  ReleaseSpinLockAtCurrentLevel(Processor^.TimerQueueLock);
end;

procedure InitializeProcessorTimers(Processor: PProcessor);
begin
  InitializeListHead(Processor^.TimerQueue);
  InitializeSpinLock(Processor^.TimerQueueLock);
  Processor^.NextTimerDueTime := NeverDue;
end;

procedure InitializeTimers;
begin
  InitializeSpinLock(TimerChangeLock);
  InitializeProcessorTimers(CurrentProcessor);
end;

procedure InitializeTimer(out Timer: TTimer);
begin
  InitializeListHead(Timer.Link);
  Timer.DueTime := 0;
  Timer.Call := nil;
  Timer.Processor := nil;
  Timer.IsSet := False;
end;

procedure SetTimer(var Timer: TTimer; Milliseconds: QWord; var Call: TDeferredCall);
begin
  SetTimerAt(Timer, DeadlineAfterMilliseconds(Milliseconds), Call);
end;

procedure SetTimerAt(var Timer: TTimer; DueTime: QWord; var Call: TDeferredCall);
var
  WereEnabled: Boolean;
  Processor: PProcessor;
  Entry: PListEntry;
begin
  WereEnabled := SaveAndDisableInterrupts;
  AcquireSpinLockAtCurrentLevel(TimerChangeLock);
  RemoveSetTimer(Timer);
  Processor := CurrentProcessor;
  AcquireSpinLockAtCurrentLevel(Processor^.TimerQueueLock);
  Timer.DueTime := DueTime;
  Timer.Call := @Call;
  Timer.Processor := Processor;
  Entry := Processor^.TimerQueue.Next;
  while (Entry <> @Processor^.TimerQueue) and (TimerOfLink(Entry)^.DueTime <= DueTime) do
    Entry := Entry^.Next;
  InsertBefore(Entry, @Timer.Link);
  Timer.IsSet := True;
  UpdateNextDueTimeLocked(Processor);
  ReleaseSpinLockAtCurrentLevel(Processor^.TimerQueueLock);
  ReleaseSpinLockAtCurrentLevel(TimerChangeLock);
  { Interrupts are still off: this processor is the one to ask. }
  RequestClockInterruptBy(DueTime);
  RestoreInterrupts(WereEnabled);
end;

function CancelTimer(var Timer: TTimer): Boolean;
var
  WereEnabled: Boolean;
begin
  WereEnabled := SaveAndDisableInterrupts;
  AcquireSpinLockAtCurrentLevel(TimerChangeLock);
  Result := RemoveSetTimer(Timer);
  ReleaseSpinLockAtCurrentLevel(TimerChangeLock);
  RestoreInterrupts(WereEnabled);
end;

procedure ExpireTimers(Now: QWord);
var
  WereEnabled: Boolean;
  Processor: PProcessor;
  Timer: PTimer;
begin
  Processor := CurrentProcessor;
  { Most interrupts find nothing due and need no lock. }
  if Now < Processor^.NextTimerDueTime then
    Exit;
  WereEnabled := SaveAndDisableInterrupts;
  AcquireSpinLockAtCurrentLevel(Processor^.TimerQueueLock);
  while not ListIsEmpty(Processor^.TimerQueue) do
  begin
    Timer := TimerOfLink(Processor^.TimerQueue.Next);
    if Timer^.DueTime > Now then
      Break;
    RemoveListEntry(@Timer^.Link);
    Timer^.IsSet := False;
    QueueDeferredCall(Timer^.Call^);
  end;
  UpdateNextDueTimeLocked(Processor);
  ReleaseSpinLockAtCurrentLevel(Processor^.TimerQueueLock);
  RestoreInterrupts(WereEnabled);
end;

end.
