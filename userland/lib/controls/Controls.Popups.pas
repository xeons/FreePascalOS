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

  TPopupWindow = class(TControlWindow)
  private
    FOnDismiss: TControlEvent;
    FOnPressedOutside: TPressedOutsideEvent;
    FClosing: Boolean;
  protected
    procedure PointerDown(X, Y: LongInt; Button: LongWord); override;
    procedure PointerUp(X, Y: LongInt; Button: LongWord); override;
    procedure CloseRequested; override;
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
    { Lets what the pop-up shows decide what a press outside it means (a
      menu passes a press on its menu bar's headings on, and closes the
      menus it came from too). }
    property OnPressedOutside: TPressedOutsideEvent read FOnPressedOutside write FOnPressedOutside;
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
begin
  if Message.Code = MessageFreePopup then
    TObject(Message.Parameter1).Free;
end;

constructor TPopupWindow.CreatePopup(AOwner: TControlWindow; Left, Top, Width, Height: LongInt);
begin
  { Owned by the window it pops up from, which it stays above. }
  inherited Create('', Left, Top, Width, Height, WindowTopmost or WindowNoActivate, AOwner);
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
  if OwnerWindow <> nil then
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
  if Reaper = nil then
    Reaper := TPopupReaper.Create;
  PostMessage(Reaper, MessageFreePopup, PtrInt(Self));
end;

procedure TPopupWindow.PointerDown(X, Y: LongInt; Button: LongWord);
begin
  if not ContainsPixel(X, Y) then
  begin
    if Assigned(FOnPressedOutside) and FOnPressedOutside(X, Y, Button) then
      Exit;
    Dismiss;
    Exit;
  end;
  inherited PointerDown(X, Y, Button);
end;

procedure TPopupWindow.PointerUp(X, Y: LongInt; Button: LongWord);
begin
  inherited PointerUp(X, Y, Button);
  { The window's own capture ended with the button; a pop-up keeps it. }
  if not FClosing then
    SetCapture(True);
end;

procedure TPopupWindow.CloseRequested;
begin
  Dismiss;
end;

function TPopupWindow.AcceptsInputWhileModal: Boolean;
begin
  Result := True;
end;

end.
