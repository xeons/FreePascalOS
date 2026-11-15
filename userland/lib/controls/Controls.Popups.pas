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
  TPopupWindow = class(TControlWindow)
  private
    FOwnerWindow: TControlWindow;
    FOnDismiss: TControlEvent;
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
    property OwnerWindow: TControlWindow read FOwnerWindow;
    property OnDismiss: TControlEvent read FOnDismiss write FOnDismiss;
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
  FOwnerWindow := AOwner;
  inherited Create('', Left, Top, Width, Height, WindowTopmost or WindowNoActivate);
end;

destructor TPopupWindow.Destroy;
begin
  if (FOwnerWindow <> nil) and (FOwnerWindow.Popup = Self) then
    FOwnerWindow.Popup := nil;
  inherited Destroy;
end;

function TPopupWindow.ContainsPixel(X, Y: LongInt): Boolean;
begin
  Result := (X >= 0) and (Y >= 0) and (X < PixelWidth) and (Y < PixelHeight);
end;

procedure TPopupWindow.Popup;
begin
  if FOwnerWindow <> nil then
    FOwnerWindow.Popup := Self;
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
  if (FOwnerWindow <> nil) and (FOwnerWindow.Popup = Self) then
    FOwnerWindow.Popup := nil;
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
