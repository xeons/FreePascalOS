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
  Deferred calls: work that an interrupt handler hands to dispatch level.

  Device interrupt handlers run above DispatchLevel, where the dispatcher
  lock cannot be taken, so they cannot signal events or wake threads. A
  handler instead queues a deferred call; it runs soon after, at
  DispatchLevel, from the dispatch interrupt, before the scheduler picks
  the next thread. There it may signal events.

    var KeyboardCall: TDeferredCall;
    InitializeDeferredCall(KeyboardCall, @SignalInput, nil);
    ...in the interrupt handler:
    QueueDeferredCall(KeyboardCall);

  A call already queued is not queued twice; it runs once. A call never
  runs on two processors at once: one queued again while it runs
  stays in the queue, passed over by the other processors, until the
  processor running it finishes and runs it again itself.
}
unit Kernel.DeferredCalls;

{$mode objfpc}

interface

uses
  Runtime.LinkedList;

type
  TDeferredRoutine = procedure(Context: Pointer);

  PDeferredCall = ^TDeferredCall;
  TDeferredCall = record
    Link: TListEntry;
    Routine: TDeferredRoutine;
    Context: Pointer;
    IsQueued: Boolean;
    { Processors running it now: 0 or 1 (it may be queued again while it
      runs, and then waits for that run to end). }
    RunningCount: LongInt;
  end;

procedure InitializeDeferredCalls;
procedure InitializeDeferredCall(out Call: TDeferredCall; Routine: TDeferredRoutine; Context: Pointer);

{ May be called at any priority level, from interrupt handlers too. }
procedure QueueDeferredCall(var Call: TDeferredCall);
{ Takes Call off the queue if it is there and waits until no processor
  runs it, so its memory may go. Below DispatchLevel, and not from the
  call itself; whoever might queue it again must be stopped first. }
procedure CancelDeferredCall(var Call: TDeferredCall);

{ Runs every queued call. Called by the dispatch interrupt at
  DispatchLevel. }
procedure RunDeferredCalls;

implementation

uses
  Kernel.Arch.Cpu,
  Kernel.PriorityLevel,
  Kernel.SpinLock,
  Hal.Platform;

var
  Queue: TListEntry;
  QueueLock: TSpinLock;

procedure InitializeDeferredCalls;
begin
  InitializeListHead(Queue);
  InitializeSpinLock(QueueLock);
end;

procedure InitializeDeferredCall(out Call: TDeferredCall; Routine: TDeferredRoutine; Context: Pointer);
begin
  InitializeListHead(Call.Link);
  Call.Routine := Routine;
  Call.Context := Context;
  Call.IsQueued := False;
  Call.RunningCount := 0;
end;

{ The queue is touched at any level, so its lock is taken with
  interrupts disabled. }
procedure QueueDeferredCall(var Call: TDeferredCall);
var
  WereEnabled: Boolean;
begin
  WereEnabled := SaveAndDisableInterrupts;
  AcquireSpinLockAtCurrentLevel(QueueLock);
  if not Call.IsQueued then
  begin
    InsertAtTail(Queue, @Call.Link);
    Call.IsQueued := True;
  end;
  ReleaseSpinLockAtCurrentLevel(QueueLock);
  RestoreInterrupts(WereEnabled);
  HalRequestSoftwareInterrupt(DispatchLevel);
end;

function CallOfLink(Entry: PListEntry): PDeferredCall;
begin
  Result := PDeferredCall(ContainingRecord(Entry, FieldOffset(PDeferredCall(nil)^.Link)));
end;

{ The first queued call that no processor runs now, taken off the queue
  and marked running; nil if none. }
function TakeNextCall: PDeferredCall;
var
  WereEnabled: Boolean;
  Entry: PListEntry;
begin
  WereEnabled := SaveAndDisableInterrupts;
  AcquireSpinLockAtCurrentLevel(QueueLock);
  Result := nil;
  Entry := Queue.Next;
  while Entry <> @Queue do
  begin
    if CallOfLink(Entry)^.RunningCount = 0 then
    begin
      Result := CallOfLink(Entry);
      RemoveListEntry(Entry);
      Result^.IsQueued := False;
      Inc(Result^.RunningCount);
      Break;
    end;
    Entry := Entry^.Next;
  end;
  ReleaseSpinLockAtCurrentLevel(QueueLock);
  RestoreInterrupts(WereEnabled);
end;

procedure FinishCall(var Call: TDeferredCall);
var
  WereEnabled: Boolean;
begin
  WereEnabled := SaveAndDisableInterrupts;
  AcquireSpinLockAtCurrentLevel(QueueLock);
  Dec(Call.RunningCount);
  ReleaseSpinLockAtCurrentLevel(QueueLock);
  RestoreInterrupts(WereEnabled);
end;

{ A call queued again while it ran is found by the next TakeNextCall of
  this same loop, once FinishCall marked it not running. }
procedure RunDeferredCalls;
var
  Call: PDeferredCall;
begin
  repeat
    Call := TakeNextCall;
    if Call = nil then
      Break;
    Call^.Routine(Call^.Context);
    FinishCall(Call^);
  until False;
end;

procedure CancelDeferredCall(var Call: TDeferredCall);
var
  WereEnabled: Boolean;
  Running: Boolean;
begin
  repeat
    WereEnabled := SaveAndDisableInterrupts;
    AcquireSpinLockAtCurrentLevel(QueueLock);
    if Call.IsQueued then
    begin
      RemoveListEntry(@Call.Link);
      Call.IsQueued := False;
    end;
    Running := Call.RunningCount > 0;
    ReleaseSpinLockAtCurrentLevel(QueueLock);
    RestoreInterrupts(WereEnabled);
    if Running then
      CpuRelax;
  until not Running;
end;

end.
