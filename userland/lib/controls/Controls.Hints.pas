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
  Hints: the tooltips of a control window's controls (their Hint
  texts), shown and hidden at the right moments.

  Every control window has one (TControlWindow.Hints), told where the
  pointer is and when a button or key is pressed. The hint under the
  pointer is the deepest control's that has one (TControl.HintAt: a
  control with parts says which part's), else its parent's, and so on;
  a control with ShowHint False shows none. When it shows, and when it
  goes, is Controls.HintTiming's: after the pointer rests half a second,
  gone when it moves to something else, leaves, a button or key is
  pressed, or after ten seconds; quickly again when moving from one
  hint to the next. The tooltip (Controls.Tooltips) goes above the part
  it is about, at the pointer, or below the pointer when there is no
  room above.

  The timing runs on a timer of its own (Controls.Timers), so a window
  with hints takes none of the message loop's window timers.
}
unit Controls.Hints;

{$mode objfpc}
{$H+}

interface

uses
  Drawing.Rectangles,
  Windowing.Windows,
  Controls.Base,
  Controls.Timers,
  Controls.HintTiming;

type
  THintShownEvent = procedure(Sender: TControl; const Text: string) of object;

  TWindowHints = class
  private
    FWindow: TWindow;
    FTiming: THintTiming;
    FTimer: TTimer;
    FEnabled: Boolean;
    { The hint under the pointer: whose, its text, the part it is about
      (window pixels); FControl nil when there is none. }
    FControl: TControl;
    FText: string;
    FArea: TRectangle;
    FShown: Boolean;
    { Where the pointer is (window pixels). }
    FPointerX: LongInt;
    FPointerY: LongInt;
    FOnShown: THintShownEvent;
    procedure TimerTicked(Sender: TTimer);
    procedure Apply(Action: THintAction);
    procedure ScheduleTimer;
    procedure ShowCurrent;
    procedure HideCurrent;
    procedure SetEnabled(Value: Boolean);
  public
    constructor Create(Window: TWindow);
    destructor Destroy; override;
    { The pointer is at (X, Y), window pixels, over Target (nil: none). }
    procedure PointerMoved(Target: TControl; X, Y: LongInt);
    { A button or key was pressed: the hint goes and stays away until
      the pointer moves to another. }
    procedure Dismiss;
    { The pointer left the window. }
    procedure PointerLeft;
    { Control is going away. }
    procedure ControlRemoved(Control: TControl);
    { The delays (milliseconds). }
    property Timing: THintTiming read FTiming;
    { False: no hints in this window (True unless set). }
    property Enabled: Boolean read FEnabled write SetEnabled;
    { A hint was shown (Sender: whose). }
    property OnShown: THintShownEvent read FOnShown write FOnShown;
  end;

{ The hint at (X, Y) of the window's pixels, from Target up through its
  parents: its text ('' for none), the control it is Owner's and the part
  it is about (window pixels). }
function FindHint(Target: TControl; X, Y: LongInt; out Owner: TControl; out Area: TRectangle): string;

implementation

uses
  Windowing.Connection,
  Controls.Tooltips;

const
  { Logical units: how far above the pointer a tooltip may go to sit
    over the part it is about, and the pointer's height (to go below). }
  ReachAbovePointer = 24;
  PointerHeight = 20;

function FindHint(Target: TControl; X, Y: LongInt; out Owner: TControl; out Area: TRectangle): string;
var
  Control: TControl;
begin
  Result := '';
  Owner := nil;
  Area := MakeRectangle(0, 0, 0, 0);
  Control := Target;
  while Control <> nil do
  begin
    if not Control.ShowHint then
      Exit;
    Result := Control.HintAt(X - Control.PixelBounds.Left, Y - Control.PixelBounds.Top, Area);
    if Result <> '' then
    begin
      Owner := Control;
      Area := OffsetRectangle(Area, Control.PixelBounds.Left, Control.PixelBounds.Top);
      Exit;
    end;
    Control := Control.Parent;
  end;
end;

constructor TWindowHints.Create(Window: TWindow);
begin
  inherited Create;
  FWindow := Window;
  FEnabled := True;
  FTiming := THintTiming.Create;
  FTimer := TTimer.Create(Window);
  FTimer.Enabled := False;
  FTimer.OnTimer := @TimerTicked;
end;

destructor TWindowHints.Destroy;
begin
  HideCurrent;
  FTimer.Free;
  FTiming.Free;
  inherited Destroy;
end;

procedure TWindowHints.SetEnabled(Value: Boolean);
begin
  if FEnabled = Value then
    Exit;
  FEnabled := Value;
  if not Value then
    PointerLeft;
end;

procedure TWindowHints.ShowCurrent;
var
  AboveY: LongInt;
begin
  if (FControl = nil) or (FText = '') then
    Exit;
  FWindow.PrepareToReceive;
  AboveY := FPointerY - Scaled(ReachAbovePointer);
  if FArea.Top > AboveY then
    AboveY := FArea.Top;
  ShowTooltipNear(FWindow, FText, FWindow.ScreenLeft + Unscaled(FPointerX), FWindow.ScreenTop + Unscaled(AboveY),
    FWindow.ScreenTop + Unscaled(FPointerY + Scaled(PointerHeight)));
  FShown := True;
  if Assigned(FOnShown) then
    FOnShown(FControl, FText);
end;

procedure TWindowHints.HideCurrent;
begin
  if not FShown then
    Exit;
  FShown := False;
  HideTooltip;
end;

procedure TWindowHints.Apply(Action: THintAction);
begin
  case Action of
    HintActionShow: ShowCurrent;
    HintActionHide: HideCurrent;
  end;
  ScheduleTimer;
end;

{ The timer set for when the timing next needs to hear the clock. }
procedure TWindowHints.ScheduleTimer;
var
  Due: QWord;
  Now: QWord;
begin
  if not FTiming.NextDue(Due) then
  begin
    FTimer.Stop;
    Exit;
  end;
  Now := TimerClock;
  if Due > Now then
    FTimer.Interval := Due - Now
  else
    FTimer.Interval := 1;
  FTimer.Start;
end;

procedure TWindowHints.TimerTicked(Sender: TTimer);
begin
  FTimer.Stop;
  Apply(FTiming.Tick(TimerClock));
end;

procedure TWindowHints.PointerMoved(Target: TControl; X, Y: LongInt);
var
  Owner: TControl;
  Area: TRectangle;
  Text: string;
begin
  if not FEnabled then
    Exit;
  FPointerX := X;
  FPointerY := Y;
  Text := FindHint(Target, X, Y, Owner, Area);
  if (Owner = FControl) and (Text = FText) and RectanglesAreEqual(Area, FArea) then
  begin
    Apply(FTiming.PointerMoved(TimerClock));
    Exit;
  end;
  FControl := Owner;
  FText := Text;
  FArea := Area;
  Apply(FTiming.TargetChanged(TimerClock, Text <> ''));
end;

procedure TWindowHints.Dismiss;
begin
  Apply(FTiming.Dismissed(TimerClock));
end;

procedure TWindowHints.PointerLeft;
begin
  FControl := nil;
  FText := '';
  Apply(FTiming.PointerLeft(TimerClock));
end;

procedure TWindowHints.ControlRemoved(Control: TControl);
begin
  if Control = FControl then
    PointerLeft;
end;

end.
