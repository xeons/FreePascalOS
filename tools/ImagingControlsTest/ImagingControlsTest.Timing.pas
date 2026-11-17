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
  Timing: the tooltips' state machine, driven by a clock of the test's
  own (milliseconds it sets), and the timers' queue.
}
unit ImagingControlsTest.Timing;

{$mode objfpc}
{$H+}

interface

procedure CheckHintTiming;
procedure CheckTimerQueue;

implementation

uses
  SysUtils,
  Controls.HintTiming,
  Controls.TimerQueue,
  ImagingControlsTest.Checks;

var
  { The fake clock. }
  Now: QWord;

{ Moves the clock on to At, ticking Timing whenever it is due on the
  way (as the hint manager's timer would); what the ticks did, the last
  that did anything. }
function RunUntil(Timing: THintTiming; At: QWord): THintAction;
var
  Due: QWord;
  Action: THintAction;
begin
  Result := HintActionNone;
  while Timing.NextDue(Due) and (Due <= At) do
  begin
    if Due > Now then
      Now := Due;
    Action := Timing.Tick(Now);
    if Action <> HintActionNone then
      Result := Action;
  end;
  Now := At;
end;

procedure CheckRestAndShow;
var
  Timing: THintTiming;
  Due: QWord;
begin
  Timing := THintTiming.Create;
  try
    Now := 1000;
    Check(Timing.TargetChanged(Now, True) = HintActionNone, 'hint: nothing at once on a target');
    Check(Timing.NextDue(Due) and (Due = 1500), 'hint: due after the initial delay');
    Check(RunUntil(Timing, 1499) = HintActionNone, 'hint: not shown before the delay');
    Check(RunUntil(Timing, 1500) = HintActionShow, 'hint: shown after the delay');
    Check(Timing.Showing, 'hint: showing');
    { The long timeout. }
    Check(RunUntil(Timing, 1500 + DefaultAutoHideHintDelay - 1) = HintActionNone, 'hint: stays until the timeout');
    Check(RunUntil(Timing, 1500 + DefaultAutoHideHintDelay) = HintActionHide, 'hint: hidden after the long timeout');
    Check(RunUntil(Timing, 60000) = HintActionNone, 'hint: not shown again on the same target');
    Check(Timing.State = HintSuppressed, 'hint: suppressed after the timeout');
    Now := 61000;
    Timing.TargetChanged(Now, True);
    Check(RunUntil(Timing, 61000 + DefaultInitialHintDelay) = HintActionShow,
      'hint: another target shows after the initial delay again');
  finally
    Timing.Free;
  end;
end;

procedure CheckRestingNeeded;
var
  Timing: THintTiming;
begin
  Timing := THintTiming.Create;
  try
    Now := 0;
    Timing.TargetChanged(Now, True);
    Now := 400;
    Timing.PointerMoved(Now);
    Check(RunUntil(Timing, 800) = HintActionNone, 'hint: moving on the target starts the wait again');
    Check(RunUntil(Timing, 900) = HintActionShow, 'hint: shown once the pointer rested long enough');
    Now := 1000;
    Check(Timing.PointerMoved(Now) = HintActionNone, 'hint: moving on a shown hint keeps it');
    Check(Timing.Showing, 'hint: still showing after moving on it');
  finally
    Timing.Free;
  end;
end;

procedure CheckDismissing;
var
  Timing: THintTiming;
begin
  Timing := THintTiming.Create;
  try
    Now := 0;
    Timing.TargetChanged(Now, True);
    RunUntil(Timing, 500);
    Now := 600;
    Check(Timing.Dismissed(Now) = HintActionHide, 'hint: a click or key hides it');
    Check(RunUntil(Timing, 5000) = HintActionNone, 'hint: not back after a click while on the same target');
    Now := 5000;
    Timing.PointerMoved(Now);
    Check(RunUntil(Timing, 9000) = HintActionNone, 'hint: not back after moving on the same target');
    { No quick reshow after a dismissal. }
    Now := 9000;
    Timing.TargetChanged(Now, True);
    Check(RunUntil(Timing, 9000 + DefaultReshowHintDelay) = HintActionNone, 'hint: no quick reshow after a click');
    Check(RunUntil(Timing, 9000 + DefaultInitialHintDelay) = HintActionShow, 'hint: the full delay after a click');
    { A click before it shows stops it showing. }
    Now := 20000;
    Timing.TargetChanged(Now, True);
    Now := 20200;
    Check(Timing.Dismissed(Now) = HintActionNone, 'hint: a click before it shows hides nothing');
    Check(RunUntil(Timing, 30000) = HintActionNone, 'hint: a click before it shows stops it');
  finally
    Timing.Free;
  end;
end;

procedure CheckMovingBetweenTargets;
var
  Timing: THintTiming;
begin
  Timing := THintTiming.Create;
  try
    Now := 0;
    Timing.TargetChanged(Now, True);
    RunUntil(Timing, 500);
    Now := 700;
    Check(Timing.TargetChanged(Now, True) = HintActionHide, 'hint: the old one goes on another target');
    Check(RunUntil(Timing, 700 + DefaultReshowHintDelay - 1) = HintActionNone, 'hint: the next not at once');
    Check(RunUntil(Timing, 700 + DefaultReshowHintDelay) = HintActionShow,
      'hint: the next shows quickly when moving from one shown');
    { Off every target, then onto one within the reshow window. }
    Now := 1000;
    Check(Timing.TargetChanged(Now, False) = HintActionHide, 'hint: hidden off every target');
    Check(Timing.State = HintIdle, 'hint: idle off every target');
    Now := 1000 + DefaultReshowHintWindow;
    Timing.TargetChanged(Now, True);
    Check(RunUntil(Timing, Now + DefaultReshowHintDelay) = HintActionShow,
      'hint: quick again within the reshow window');
    { Off, and back only after the window: the full delay. }
    Now := 3000;
    Timing.TargetChanged(Now, False);
    Now := 3000 + DefaultReshowHintWindow + 1;
    Timing.TargetChanged(Now, True);
    Check(RunUntil(Timing, Now + DefaultReshowHintDelay) = HintActionNone, 'hint: not quick after the window');
    Check(RunUntil(Timing, 3000 + DefaultReshowHintWindow + 1 + DefaultInitialHintDelay) = HintActionShow,
      'hint: the full delay after the window');
  finally
    Timing.Free;
  end;
end;

procedure CheckLeaving;
var
  Timing: THintTiming;
  Due: QWord;
begin
  Timing := THintTiming.Create;
  try
    Now := 0;
    Timing.TargetChanged(Now, True);
    Now := 200;
    Check(Timing.PointerLeft(Now) = HintActionNone, 'hint: leaving before it shows hides nothing');
    Check(not Timing.NextDue(Due), 'hint: nothing due after leaving');
    Check(RunUntil(Timing, 5000) = HintActionNone, 'hint: not shown after leaving');
    Now := 5000;
    Timing.TargetChanged(Now, True);
    RunUntil(Timing, 5500);
    Now := 5600;
    Check(Timing.PointerLeft(Now) = HintActionHide, 'hint: leaving the window hides it');
    Now := 5700;
    Timing.TargetChanged(Now, False);
    Check(RunUntil(Timing, 9000) = HintActionNone, 'hint: a target with no hint shows nothing');
    { Delays of the program's choosing. }
    Timing.InitialDelay := 100;
    Now := 20000;
    Timing.TargetChanged(Now, True);
    Check(RunUntil(Timing, 20100) = HintActionShow, 'hint: a shorter initial delay');
  finally
    Timing.Free;
  end;
end;

procedure CheckHintTiming;
begin
  CheckRestAndShow;
  CheckRestingNeeded;
  CheckDismissing;
  CheckMovingBetweenTargets;
  CheckLeaving;
end;

procedure CheckTimerQueue;
var
  Queue: TTimerQueue;
  First: TObject;
  Second: TObject;
  Third: TObject;
  Client: TObject;
  Due: QWord;
begin
  Queue := TTimerQueue.Create;
  First := TObject.Create;
  Second := TObject.Create;
  Third := TObject.Create;
  try
    Check(not Queue.NextDue(Due), 'timers: nothing due in an empty queue');
    Queue.Schedule(First, 300);
    Queue.Schedule(Second, 100);
    Queue.Schedule(Third, 200);
    Check(Queue.NextDue(Due) and (Due = 100), 'timers: the earliest is due first');
    Check(not Queue.TakeDue(99, Client), 'timers: nothing taken before it is due');
    Check(Queue.TakeDue(250, Client) and (Client = Second), 'timers: the earliest due taken first');
    Check(Queue.TakeDue(250, Client) and (Client = Third), 'timers: then the next');
    Check(not Queue.TakeDue(250, Client), 'timers: the later one not yet');
    CheckEqual(Queue.Count, 1, 'timers: taken out of the queue');
    Queue.Schedule(First, 50);
    CheckEqual(Queue.Count, 1, 'timers: scheduling again moves it, once in the queue');
    Check(Queue.NextDue(Due) and (Due = 50), 'timers: at its new time');
    Queue.Cancel(First);
    Check(not Queue.Contains(First) and not Queue.NextDue(Due), 'timers: cancelled');
    Queue.Cancel(First);
    CheckEqual(Queue.Count, 0, 'timers: cancelling twice is harmless');
    CheckEqual(NextPeriodicDue(1000, 50, 1010), 1050, 'timers: the next tick keeps the rhythm');
    CheckEqual(NextPeriodicDue(1000, 50, 1050), 1050, 'timers: a tick due now');
    CheckEqual(NextPeriodicDue(1000, 50, 1300), 1350, 'timers: ticks missed are skipped');
  finally
    First.Free;
    Second.Free;
    Third.Free;
    Queue.Free;
  end;
end;

end.
