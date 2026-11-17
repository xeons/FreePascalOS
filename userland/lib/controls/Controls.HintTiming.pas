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
  Hint timing: when a tooltip shows and when it goes, as a state
  machine over a clock it is given (milliseconds), so it can be tried
  without windows or a real clock.

  The pointer coming to rest on something with a hint (a target) waits
  InitialDelay, then shows the hint; moving on the same target before
  then starts the wait again (the pointer has to rest). A hint shown
  goes after AutoHideDelay, or when the pointer moves to another
  target, leaves the window, or a button or key is pressed. After a
  click, a key or the long timeout it stays away until the pointer
  moves to another target. Moving from a hint shown (or one just hidden
  by leaving its target, within ReshowWindow) to another target shows
  the new one after only ReshowDelay, so running the pointer along a
  toolbar shows each button's hint almost at once.

  Each method returns what to do with the tooltip now; NextDue tells
  when Tick should next be called.
}
unit Controls.HintTiming;

{$mode objfpc}

interface

const
  { Milliseconds. }
  DefaultInitialHintDelay = 500;
  DefaultReshowHintDelay = 50;
  DefaultReshowHintWindow = 500;
  DefaultAutoHideHintDelay = 10000;

type
  THintAction = (HintActionNone, HintActionShow, HintActionHide);

  THintTimingState = (
    HintIdle,        { nothing to show here }
    HintWaiting,     { resting on a target, its hint to show when due }
    HintShowing,     { the hint shown, to go when due }
    HintSuppressed   { dismissed: nothing until another target }
  );

  THintTiming = class
  private
    FState: THintTimingState;
    FDue: QWord;
    { When a shown hint last went because the pointer left its target,
      and whether that may make the next one quick. }
    FHiddenAt: QWord;
    FQuickReshow: Boolean;
    FWaitDelay: LongWord;
    FInitialDelay: LongWord;
    FReshowDelay: LongWord;
    FReshowWindow: LongWord;
    FAutoHideDelay: LongWord;
    function HideShown(Now: QWord; MayReshowQuickly: Boolean): THintAction;
    procedure StartWaiting(Now: QWord);
  public
    constructor Create;
    { The pointer is over a new target (HasHint: it has a hint to show). }
    function TargetChanged(Now: QWord; HasHint: Boolean): THintAction;
    { The pointer moved within the same target. }
    function PointerMoved(Now: QWord): THintAction;
    { A button or a key was pressed. }
    function Dismissed(Now: QWord): THintAction;
    { The pointer left the window (or the window went away). }
    function PointerLeft(Now: QWord): THintAction;
    { The clock moved on (when due, or at any time). }
    function Tick(Now: QWord): THintAction;
    { True, with when Tick should be called, while anything waits. }
    function NextDue(out Due: QWord): Boolean;
    function Showing: Boolean;
    property State: THintTimingState read FState;
    property InitialDelay: LongWord read FInitialDelay write FInitialDelay;
    property ReshowDelay: LongWord read FReshowDelay write FReshowDelay;
    property ReshowWindow: LongWord read FReshowWindow write FReshowWindow;
    property AutoHideDelay: LongWord read FAutoHideDelay write FAutoHideDelay;
  end;

implementation

constructor THintTiming.Create;
begin
  inherited Create;
  FState := HintIdle;
  FInitialDelay := DefaultInitialHintDelay;
  FReshowDelay := DefaultReshowHintDelay;
  FReshowWindow := DefaultReshowHintWindow;
  FAutoHideDelay := DefaultAutoHideHintDelay;
end;

function THintTiming.HideShown(Now: QWord; MayReshowQuickly: Boolean): THintAction;
begin
  Result := HintActionNone;
  if FState <> HintShowing then
    Exit;
  Result := HintActionHide;
  FHiddenAt := Now;
  FQuickReshow := MayReshowQuickly;
end;

procedure THintTiming.StartWaiting(Now: QWord);
begin
  if FQuickReshow and (Now - FHiddenAt <= FReshowWindow) then
    FWaitDelay := FReshowDelay
  else
    FWaitDelay := FInitialDelay;
  FState := HintWaiting;
  FDue := Now + FWaitDelay;
end;

function THintTiming.TargetChanged(Now: QWord; HasHint: Boolean): THintAction;
begin
  Result := HideShown(Now, True);
  if HasHint then
    StartWaiting(Now)
  else
    FState := HintIdle;
end;

function THintTiming.PointerMoved(Now: QWord): THintAction;
begin
  Result := HintActionNone;
  if FState = HintWaiting then
    FDue := Now + FWaitDelay;
end;

function THintTiming.Dismissed(Now: QWord): THintAction;
begin
  Result := HideShown(Now, False);
  FQuickReshow := False;
  if FState <> HintIdle then
    FState := HintSuppressed;
end;

function THintTiming.PointerLeft(Now: QWord): THintAction;
begin
  Result := HideShown(Now, True);
  FState := HintIdle;
end;

function THintTiming.Tick(Now: QWord): THintAction;
begin
  Result := HintActionNone;
  if Now < FDue then
    Exit;
  case FState of
    HintWaiting:
      begin
        FState := HintShowing;
        FDue := Now + FAutoHideDelay;
        Result := HintActionShow;
      end;
    HintShowing:
      begin
        Result := HideShown(Now, False);
        FState := HintSuppressed;
      end;
  end;
end;

function THintTiming.NextDue(out Due: QWord): Boolean;
begin
  Due := FDue;
  Result := FState in [HintWaiting, HintShowing];
end;

function THintTiming.Showing: Boolean;
begin
  Result := FState = HintShowing;
end;

end.
