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
  Pop-up windows: menus and drop-down lists.

  A pop-up is a window without a frame, above every other, that never
  takes the keyboard (its owner keeps it, and gives the pop-up its keys
  while it is open: TControlWindow.Popup). While shown it holds the
  pointer (captured), so it sees a press anywhere: one outside it
  dismisses it (OnDismiss). Positions are on the screen, in logical
  units.

  A dismissed pop-up is freed later, from the message loop (posted), and
  never while one of its own events is still being handled: an item
  chosen in a menu may open a message box, whose loop would otherwise
  free the menu in the middle of the click that chose it. Each event
  method counts how deep it is (BeginEvent, EndEvent); a pop-up asked to
  be freed meanwhile is freed once the outermost event is over.
}
unit Controls.Popups;

{$mode objfpc}
{$H+}

interface

uses
  Windowing.Protocol,
  Controls.Base,
  Controls.Window;

type
  { Answers a press outside the pop-up: True when the answer is taken
    care of, False to have the pop-up simply dismissed. }
  TPressedOutsideEvent = function(X, Y: LongInt; Button: LongWord): Boolean of object;
  { The pointer moved to (X, Y) of the pop-up, outside it. }
  TPointerMovedEvent = procedure(X, Y: LongInt) of object;
  { The theme changed while the pop-up is open. }
  TPopupThemeChangedEvent = procedure of object;

  TPopupWindow = class(TControlWindow)
  private
    FOnDismiss: TControlEvent;
    FOnPressedOutside: TPressedOutsideEvent;
    FOnPointerMovedOutside: TPointerMovedEvent;
    FOnThemeChanged: TPopupThemeChangedEvent;
    FClosing: Boolean;
    FTakesKeys: Boolean;
    { How many of its event methods are running (nested loops inside
      them), and whether it is to be freed when the last one ends. }
    FEventDepth: LongInt;
    FFreeWhenEventsEnd: Boolean;
    procedure BeginEvent;
    procedure EndEvent;
    procedure PostFree;
  protected
    procedure KeyDown(Code, Character, Modifiers: LongWord); override;
    procedure KeyUp(Code, Modifiers: LongWord); override;
    procedure PointerMove(X, Y: LongInt; Buttons: LongWord); override;
    procedure PointerDown(X, Y: LongInt; Button: LongWord); override;
    procedure PointerUp(X, Y: LongInt; Button: LongWord); override;
    procedure Wheel(Steps: LongInt); override;
    procedure TimerFired(TimerId: LongWord); override;
    procedure CloseRequested; override;
    procedure ThemeChanged; override;
    { A modal window's pop-ups (a combo box's list in a dialog) work. }
    function AcceptsInputWhileModal: Boolean; override;
  public
    { At (Left, Top) on the screen, Width x Height; logical units. }
    constructor CreatePopup(AOwner: TControlWindow; Left, Top, Width, Height: LongInt);
    destructor Destroy; override;
    procedure Popup;
    { Hides it and lets the owner know (OnDismiss); it is freed later
      (posted), so a handler may close it from within its own events. }
    procedure Dismiss;
    function ContainsPixel(X, Y: LongInt): Boolean;
    { The window it opened from; nil once that window is gone. (It is the
      window system's owner link, which forgets a freed owner, so it can
      never point at a freed window.) }
    function OwnerWindow: TControlWindow;
    property OnDismiss: TControlEvent read FOnDismiss write FOnDismiss;
    { It was dismissed (and waits to be freed). }
    property Closing: Boolean read FClosing;
    { Whether its owner gives it the keys while it is open (True unless
      set): False for a list of suggestions under an edit box, which goes
      on taking the typing. }
    property TakesKeys: Boolean read FTakesKeys write FTakesKeys;
    { Lets what the pop-up shows decide what a press outside it means (a
      menu passes a press on its menu bar's headings on, and closes the
      menus it came from too). }
    property OnPressedOutside: TPressedOutsideEvent read FOnPressedOutside write FOnPressedOutside;
    { Moves outside it, which it hears while it holds the pointer (a
      menu passes them to the menus it came from and its menu bar, so
      pointing at them works as it does over the menu). Without it they
      go nowhere. }
    property OnPointerMovedOutside: TPointerMovedEvent read FOnPointerMovedOutside write FOnPointerMovedOutside;
    { The theme changed while it is open: what it shows may measure
      itself again (a menu sized by the theme's metrics). }
    property OnThemeChanged: TPopupThemeChangedEvent read FOnThemeChanged write FOnThemeChanged;
  end;

implementation

uses
  Windowing.Messages,
  Windowing.Connection;

const
  MessageFreePopup = 2;

type
  { Frees pop-ups once their events are over. }
  TPopupReaper = class(TMessageReceiver)
  public
    procedure ReceiveMessage(var Message: TPostedMessage); override;
  end;

var
  Reaper: TPopupReaper;

procedure TPopupReaper.ReceiveMessage(var Message: TPostedMessage);
var
  Popup: TPopupWindow;
begin
  if Message.Code <> MessageFreePopup then
    Exit;
  Popup := TPopupWindow(Message.Parameter1);
  { Still inside one of its events (a nested loop): later. }
  if Popup.FEventDepth > 0 then
    Popup.FFreeWhenEventsEnd := True
  else
    Popup.Free;
end;

procedure TPopupWindow.PostFree;
begin
  if Reaper = nil then
    Reaper := TPopupReaper.Create;
  PostMessage(Reaper, MessageFreePopup, PtrInt(Self));
end;

procedure TPopupWindow.BeginEvent;
begin
  Inc(FEventDepth);
end;

procedure TPopupWindow.EndEvent;
begin
  Dec(FEventDepth);
  if (FEventDepth = 0) and FFreeWhenEventsEnd then
  begin
    FFreeWhenEventsEnd := False;
    PostFree;
  end;
end;

constructor TPopupWindow.CreatePopup(AOwner: TControlWindow; Left, Top, Width, Height: LongInt);
begin
  { Owned by the window it pops up from, which it stays above. }
  inherited Create('', Left, Top, Width, Height, WindowTopmost or WindowNoActivate, AOwner);
  FTakesKeys := True;
end;

destructor TPopupWindow.Destroy;
begin
  if (OwnerWindow <> nil) and (OwnerWindow.Popup = Self) then
    OwnerWindow.Popup := nil;
  inherited Destroy;
end;

function TPopupWindow.OwnerWindow: TControlWindow;
begin
  Result := TControlWindow(Owner);
end;

function TPopupWindow.ContainsPixel(X, Y: LongInt): Boolean;
begin
  Result := (X >= 0) and (Y >= 0) and (X < PixelWidth) and (Y < PixelHeight);
end;

procedure TPopupWindow.Popup;
begin
  if FTakesKeys and (OwnerWindow <> nil) then
    OwnerWindow.Popup := Self;
  Show;
  SetCapture(True);
end;

procedure TPopupWindow.Dismiss;
begin
  if FClosing then
    Exit;
  FClosing := True;
  SetCapture(False);
  Hide;
  if (OwnerWindow <> nil) and (OwnerWindow.Popup = Self) then
    OwnerWindow.Popup := nil;
  if Assigned(FOnDismiss) then
    FOnDismiss(Root);
  PostFree;
end;

procedure TPopupWindow.KeyDown(Code, Character, Modifiers: LongWord);
begin
  BeginEvent;
  try
    inherited KeyDown(Code, Character, Modifiers);
  finally
    EndEvent;
  end;
end;

procedure TPopupWindow.KeyUp(Code, Modifiers: LongWord);
begin
  BeginEvent;
  try
    inherited KeyUp(Code, Modifiers);
  finally
    EndEvent;
  end;
end;

procedure TPopupWindow.PointerMove(X, Y: LongInt; Buttons: LongWord);
begin
  BeginEvent;
  try
    if not ContainsPixel(X, Y) and Assigned(FOnPointerMovedOutside) then
      FOnPointerMovedOutside(X, Y)
    else
      inherited PointerMove(X, Y, Buttons);
  finally
    EndEvent;
  end;
end;

procedure TPopupWindow.PointerDown(X, Y: LongInt; Button: LongWord);
begin
  BeginEvent;
  try
    if not ContainsPixel(X, Y) then
    begin
      if Assigned(FOnPressedOutside) and FOnPressedOutside(X, Y, Button) then
        Exit;
      Dismiss;
      Exit;
    end;
    inherited PointerDown(X, Y, Button);
  finally
    EndEvent;
  end;
end;

procedure TPopupWindow.PointerUp(X, Y: LongInt; Button: LongWord);
begin
  BeginEvent;
  try
    inherited PointerUp(X, Y, Button);
    { The window's own capture ended with the button; a pop-up keeps it. }
    if not FClosing then
      SetCapture(True);
  finally
    EndEvent;
  end;
end;

procedure TPopupWindow.Wheel(Steps: LongInt);
begin
  BeginEvent;
  try
    inherited Wheel(Steps);
  finally
    EndEvent;
  end;
end;

procedure TPopupWindow.TimerFired(TimerId: LongWord);
begin
  BeginEvent;
  try
    inherited TimerFired(TimerId);
  finally
    EndEvent;
  end;
end;

procedure TPopupWindow.CloseRequested;
begin
  Dismiss;
end;

procedure TPopupWindow.ThemeChanged;
begin
  inherited ThemeChanged;
  if FClosing or not Assigned(FOnThemeChanged) then
    Exit;
  BeginEvent;
  try
    FOnThemeChanged();
  finally
    EndEvent;
  end;
end;

function TPopupWindow.AcceptsInputWhileModal: Boolean;
begin
  Result := True;
end;

end.
