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

  When the time has passed, the clock interrupt of the boot processor
  queues the timer's deferred call, which then runs at DispatchLevel.
  Cancelling cannot take back a call that is already queued, so the
  routine must check whether its reason still holds. Timers have the
  resolution of the clock tick (10 ms) and never expire early.
}
unit Kernel.Timers;

{$mode objfpc}

interface

uses
  Runtime.LinkedList,
  Kernel.DeferredCalls;

type
  PTimer = ^TTimer;
  TTimer = record
    Link: TListEntry;
    DueTick: QWord;
    Call: PDeferredCall;
    IsSet: Boolean;
  end;

procedure InitializeTimers;
procedure InitializeTimer(out Timer: TTimer);
{ Sets Timer to queue Call after Milliseconds; a timer that is already
  set is moved to the new time. Any level up to DispatchLevel. }
procedure SetTimer(var Timer: TTimer; Milliseconds: QWord; var Call: TDeferredCall);
{ Returns True if the timer was set (and now is not). }
function CancelTimer(var Timer: TTimer): Boolean;

{ Called by the clock interrupt with the new tick count. }
procedure ExpireTimers(TickCount: QWord);

implementation

uses
  Kernel.Arch.Cpu,
  Kernel.SpinLock,
  Kernel.Clock;

var
  { Ordered by due tick. Taken with interrupts disabled: the clock
    interrupt expires timers. }
  TimerQueue: TListEntry;
  TimerLock: TSpinLock;
  { The first due tick, so most clock ticks need no lock. }
  NextDueTick: QWord = High(QWord);

function TimerOfLink(Entry: PListEntry): PTimer;
begin
  Result := PTimer(ContainingRecord(Entry, FieldOffset(PTimer(nil)^.Link)));
end;

procedure UpdateNextDueTickLocked;
var
  First: PListEntry;
begin
  First := FirstListEntry(TimerQueue);
  if First = nil then
    NextDueTick := High(QWord)
  else
    NextDueTick := TimerOfLink(First)^.DueTick;
end;

procedure RemoveTimerLocked(var Timer: TTimer);
begin
  RemoveListEntry(@Timer.Link);
  Timer.IsSet := False;
end;

procedure InitializeTimers;
begin
  InitializeListHead(TimerQueue);
  InitializeSpinLock(TimerLock);
end;

procedure InitializeTimer(out Timer: TTimer);
begin
  InitializeListHead(Timer.Link);
  Timer.DueTick := 0;
  Timer.Call := nil;
  Timer.IsSet := False;
end;

procedure SetTimer(var Timer: TTimer; Milliseconds: QWord; var Call: TDeferredCall);
var
  WereEnabled: Boolean;
  Entry: PListEntry;
begin
  WereEnabled := SaveAndDisableInterrupts;
  AcquireSpinLockAtCurrentLevel(TimerLock);
  if Timer.IsSet then
    RemoveTimerLocked(Timer);
  { One tick more: the current tick may be nearly over. }
  Timer.DueTick := ClockTickCount + MillisecondsToTicks(Milliseconds) + 1;
  Timer.Call := @Call;
  Entry := TimerQueue.Next;
  while (Entry <> @TimerQueue) and (TimerOfLink(Entry)^.DueTick <= Timer.DueTick) do
    Entry := Entry^.Next;
  InsertBefore(Entry, @Timer.Link);
  Timer.IsSet := True;
  UpdateNextDueTickLocked;
  ReleaseSpinLockAtCurrentLevel(TimerLock);
  RestoreInterrupts(WereEnabled);
end;

function CancelTimer(var Timer: TTimer): Boolean;
var
  WereEnabled: Boolean;
begin
  WereEnabled := SaveAndDisableInterrupts;
  AcquireSpinLockAtCurrentLevel(TimerLock);
  Result := Timer.IsSet;
  if Result then
  begin
    RemoveTimerLocked(Timer);
    UpdateNextDueTickLocked;
  end;
  ReleaseSpinLockAtCurrentLevel(TimerLock);
  RestoreInterrupts(WereEnabled);
end;

procedure ExpireTimers(TickCount: QWord);
var
  WereEnabled: Boolean;
  Timer: PTimer;
begin
  if TickCount < NextDueTick then
    Exit;
  WereEnabled := SaveAndDisableInterrupts;
  AcquireSpinLockAtCurrentLevel(TimerLock);
  while not ListIsEmpty(TimerQueue) do
  begin
    Timer := TimerOfLink(TimerQueue.Next);
    if Timer^.DueTick > TickCount then
      Break;
    RemoveTimerLocked(Timer^);
    QueueDeferredCall(Timer^.Call^);
  end;
  UpdateNextDueTickLocked;
  ReleaseSpinLockAtCurrentLevel(TimerLock);
  RestoreInterrupts(WereEnabled);
end;

end.
