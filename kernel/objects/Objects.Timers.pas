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
  Timer objects: an event that is signaled when a time comes, once or
  every so often.

  SetTimerObject arms it: due in DueMilliseconds, then (if Period is not
  zero) every Period milliseconds. Each time the timer's event is
  signaled: a manual reset timer stays signaled until reset (or armed
  again), an automatic reset one releases one waiter. The kernel's clock
  ticks every 10 ms, which is how close to its time a timer is.

  Deleting a timer stops it first: marked as going (so its call does not
  arm it again), taken off the timer queue, its call taken off the
  deferred call queue and waited for if it is running, twice, as a run
  that started before the mark may have armed it again.
}
unit Objects.Timers;

{$mode objfpc}

interface

uses
  Kernel.Events,
  Kernel.Timers,
  Kernel.DeferredCalls;

type
  PTimerObject = ^TTimerObject;
  TTimerObject = record
    Event: TEvent;
    Timer: TTimer;
    Call: TDeferredCall;
    PeriodMilliseconds: QWord;
    Deleting: Boolean;
  end;

procedure InitializeTimerObjects;
function CreateTimerObject(ManualReset: Boolean): PTimerObject;
{ Arms the timer (unsignaled until it is due); DueMilliseconds 0 stops
  it. }
procedure SetTimerObject(Timer: PTimerObject; DueMilliseconds, PeriodMilliseconds: QWord);

implementation

uses
  Objects.Manager;

var
  TimerObjectType: TObjectType;

procedure TimerDue(Context: Pointer);
var
  Timer: PTimerObject;
begin
  Timer := PTimerObject(Context);
  SignalEvent(Timer^.Event);
  if (Timer^.PeriodMilliseconds <> 0) and not Timer^.Deleting then
    SetTimer(Timer^.Timer, Timer^.PeriodMilliseconds, Timer^.Call);
end;

procedure StopTimer(Timer: PTimerObject);
begin
  CancelTimer(Timer^.Timer);
  CancelDeferredCall(Timer^.Call);
end;

procedure DeleteTimerObject(ObjectBody: Pointer);
var
  Timer: PTimerObject;
begin
  Timer := PTimerObject(ObjectBody);
  Timer^.Deleting := True;
  StopTimer(Timer);
  StopTimer(Timer);
end;

procedure InitializeTimerObjects;
begin
  RegisterObjectType(TimerObjectType, 'Timer', SizeOf(TTimerObject), @DeleteTimerObject);
end;

function CreateTimerObject(ManualReset: Boolean): PTimerObject;
begin
  Result := PTimerObject(CreateObject(TimerObjectType, nil));
  if Result = nil then
    Exit;
  if ManualReset then
    InitializeEvent(Result^.Event, EventKindNotification, False)
  else
    InitializeEvent(Result^.Event, EventKindSynchronization, False);
  InitializeTimer(Result^.Timer);
  InitializeDeferredCall(Result^.Call, @TimerDue, Result);
end;

procedure SetTimerObject(Timer: PTimerObject; DueMilliseconds, PeriodMilliseconds: QWord);
begin
  { Stopped first, so a run in progress cannot arm it with the old
    period. }
  Timer^.Deleting := True;
  StopTimer(Timer);
  StopTimer(Timer);
  Timer^.Deleting := False;
  ResetEvent(Timer^.Event);
  Timer^.PeriodMilliseconds := PeriodMilliseconds;
  if DueMilliseconds <> 0 then
    SetTimer(Timer^.Timer, DueMilliseconds, Timer^.Call);
end;

end.
