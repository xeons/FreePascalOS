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

  A call already queued is not queued twice; it runs once.
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
  end;

procedure InitializeDeferredCalls;
procedure InitializeDeferredCall(out Call: TDeferredCall; Routine: TDeferredRoutine; Context: Pointer);

{ May be called at any priority level, from interrupt handlers too. }
procedure QueueDeferredCall(var Call: TDeferredCall);

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

function TakeNextCall: PDeferredCall;
var
  WereEnabled: Boolean;
  Entry: PListEntry;
begin
  WereEnabled := SaveAndDisableInterrupts;
  AcquireSpinLockAtCurrentLevel(QueueLock);
  Entry := RemoveHeadEntry(Queue);
  Result := nil;
  if Entry <> nil then
  begin
    Result := PDeferredCall(ContainingRecord(Entry, FieldOffset(PDeferredCall(nil)^.Link)));
    Result^.IsQueued := False;
  end;
  ReleaseSpinLockAtCurrentLevel(QueueLock);
  RestoreInterrupts(WereEnabled);
end;

procedure RunDeferredCalls;
var
  Call: PDeferredCall;
begin
  repeat
    Call := TakeNextCall;
    if Call = nil then
      Break;
    Call^.Routine(Call^.Context);
  until False;
end;

end.
