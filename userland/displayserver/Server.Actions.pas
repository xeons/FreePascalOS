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
  What can be done to a window, by its program (Server.Clients) or by
  the user (Server.Input): activating, showing, enabling, moving,
  resizing and destroying it, and telling its program what happened.

  A disabled window (the owner of a modal dialog) is never activated:
  whatever would activate it activates the topmost enabled window it
  owns instead (the dialog), after bringing both forward. Hiding a
  window hides the windows it owns, and showing it shows them again.
  The program hears whenever one of its windows is shown or hidden
  (EventVisibilityChanged), whoever did it, so it knows what is on the
  screen. A window moved keeps what of it stays visible on the screen:
  those pixels are copied to the new place (Server.WindowMoves).
}
unit Server.Actions;

{$mode objfpc}

interface

uses
  Drawing.Rectangles,
  Windowing.Protocol,
  Server.Windows;

{ Sends Message (its Window set to Window's) to the window's program. }
procedure SendToProgram(Window: PServerWindow; var Message: TWindowMessage);
{ Brings the window to the front and gives it the keyboard (nil: none).
  A disabled window gives it to its topmost enabled owned window. }
procedure ActivateWindow(Window: PServerWindow);
procedure ShowWindow(Window: PServerWindow; Show: Boolean);
{ A disabled window is not activated and gets no input. }
procedure EnableWindow(Window: PServerWindow; Enable: Boolean);
{ Gives the window another owner (nil: none); see ChangeOwner. }
procedure SetWindowOwner(Window, Owner: PServerWindow);
procedure MoveWindowTo(Window: PServerWindow; ClientLeft, ClientTop: LongInt);
{ Tells the program where its window is (logical units: EventMoved). }
procedure TellWindowPlace(Window: PServerWindow);
{ Tells the program the scale and DPI its window is at (EventScaleChanged
  for the window), so it gives it a surface for them. }
procedure TellWindowScale(Window: PServerWindow);
{ Asks the program for a surface of a new size (it answers with
  RequestSetSurface), moving the client area to Bounds' top left. }
procedure RequestResize(Window: PServerWindow; const Bounds: TRectangle);
procedure ToggleMaximized(Window: PServerWindow);
{ Unmaps and closes the window's surface section. }
procedure ReleaseSurface(Window: PServerWindow);
procedure DestroyWindow(Window: PServerWindow);

implementation

uses
  Windowing.Theme,
  Sys.Objects,
  Server.Theme,
  Server.Screen,
  Server.Desktop,
  Server.Composer,
  Server.Clients,
  Server.Input,
  Server.WindowMoves;

procedure SendToProgram(Window: PServerWindow; var Message: TWindowMessage);
begin
  Message.Window := Window^.Id;
  SendToClient(PClient(Window^.Client), Message);
end;

procedure SendVisibilityChanged(Window: PServerWindow);
var
  Message: TWindowMessage;
begin
  Message := NewMessage(EventVisibilityChanged, Window^.Id);
  Message.Value := Ord(Window^.Visible);
  SendToProgram(Window, Message);
end;

procedure SendActivated(Window: PServerWindow; Active: Boolean);
var
  Message: TWindowMessage;
begin
  Message := NewMessage(EventActivated, Window^.Id);
  Message.Value := Ord(Active);
  SendToProgram(Window, Message);
end;

function TakesKeyboard(Window: PServerWindow): Boolean;
begin
  Result := Window^.Visible and not Window^.Disabled and ((Window^.Flags and WindowNoActivate) = 0);
end;

{ The topmost window owned by Owner (directly or not) that can take the
  keyboard, or nil. }
function EnabledOwnedWindow(Owner: PServerWindow): PServerWindow;
var
  Index: LongInt;
begin
  for Index := WindowCount - 1 downto 0 do
    if IsOwnedBy(Windows[Index], Owner) and TakesKeyboard(Windows[Index]) then
      Exit(Windows[Index]);
  Result := nil;
end;

procedure ActivateWindow(Window: PServerWindow);
var
  Previous: PServerWindow;
begin
  if (Window <> nil) and Window^.Disabled then
  begin
    { It comes forward with what it owns; the keyboard goes to its
      dialog, or stays where it is if it has none. }
    RaiseWindow(Window);
    DamageWindow(Window);
    Window := EnabledOwnedWindow(Window);
    if Window = nil then
      Exit;
  end;
  if Window <> nil then
  begin
    RaiseWindow(Window);
    DamageWindow(Window);
    if (Window^.Flags and WindowNoActivate) <> 0 then
      Exit;
  end;
  Previous := ActiveWindow;
  if Previous = Window then
    Exit;
  ActiveWindow := Window;
  if Previous <> nil then
  begin
    DamageWindow(Previous);
    SendActivated(Previous, False);
  end;
  if Window <> nil then
    SendActivated(Window, True);
end;

{ The topmost visible window that takes the keyboard, other than Excluded. }
function NextActivatable(Excluded: PServerWindow): PServerWindow;
var
  Index: LongInt;
begin
  for Index := WindowCount - 1 downto 0 do
    if (Windows[Index] <> Excluded) and TakesKeyboard(Windows[Index]) then
      Exit(Windows[Index]);
  Result := nil;
end;

{ The windows Owner owns directly, bottom first. Taken as a list first:
  hiding and showing them may change the stacking order. }
procedure CollectOwnedWindows(Owner: PServerWindow; var Owned: array of PServerWindow; out Count: LongInt);
var
  Index: LongInt;
begin
  Count := 0;
  for Index := 0 to WindowCount - 1 do
    if Windows[Index]^.OwnerWindow = Owner then
    begin
      Owned[Count] := Windows[Index];
      Inc(Count);
    end;
end;

{ Hides the windows Owner owns (and so theirs), marked to come back
  with it. }
procedure HideOwnedWindows(Owner: PServerWindow);
var
  Owned: array[0..MaximumWindows - 1] of PServerWindow;
  Count: LongInt;
  Index: LongInt;
begin
  CollectOwnedWindows(Owner, Owned, Count);
  for Index := 0 to Count - 1 do
    if Owned[Index]^.Visible then
    begin
      ShowWindow(Owned[Index], False);
      Owned[Index]^.HiddenWithOwner := True;
    end;
end;

{ Shows again what HideOwnedWindows hid (they are raised with Owner). }
procedure ShowOwnedWindows(Owner: PServerWindow);
var
  Owned: array[0..MaximumWindows - 1] of PServerWindow;
  Count: LongInt;
  Index: LongInt;
begin
  CollectOwnedWindows(Owner, Owned, Count);
  for Index := 0 to Count - 1 do
    if Owned[Index]^.HiddenWithOwner then
    begin
      Owned[Index]^.HiddenWithOwner := False;
      Owned[Index]^.Visible := True;
      DamageWindow(Owned[Index]);
      SendVisibilityChanged(Owned[Index]);
      ShowOwnedWindows(Owned[Index]);
    end;
end;

procedure ShowWindow(Window: PServerWindow; Show: Boolean);
begin
  { Shown or hidden on purpose now, not along with its owner. }
  Window^.HiddenWithOwner := False;
  if Window^.Visible = Show then
    Exit;
  Window^.Visible := Show;
  DamageWindow(Window);
  SendVisibilityChanged(Window);
  if Show then
  begin
    ShowOwnedWindows(Window);
    ActivateWindow(Window);
    Exit;
  end;
  HideOwnedWindows(Window);
  if (ActiveWindow = Window) or ((ActiveWindow <> nil) and not ActiveWindow^.Visible) then
    ActivateWindow(NextActivatable(Window));
end;

procedure EnableWindow(Window: PServerWindow; Enable: Boolean);
begin
  if Window^.Disabled = not Enable then
    Exit;
  Window^.Disabled := not Enable;
  if Enable then
    Exit;
  { No drag, capture or hover goes on with it; the keyboard goes to its
    dialog, or nowhere. }
  ForgetWindowInInput(Window);
  if ActiveWindow = Window then
    ActivateWindow(EnabledOwnedWindow(Window));
end;

procedure TellWindowPlace(Window: PServerWindow);
var
  Message: TWindowMessage;
begin
  Message := NewMessage(EventMoved, Window^.Id);
  DesktopToLogical(Window^.ClientLeft, Window^.ClientTop, Message.Left, Message.Top);
  SendToProgram(Window, Message);
end;

procedure TellWindowScale(Window: PServerWindow);
var
  Message: TWindowMessage;
  Screen: PScreen;
begin
  Screen := WindowScreen(Window);
  Message := NewMessage(EventScaleChanged, Window^.Id);
  Message.Width := Screen^.Device.Width;
  Message.Height := Screen^.Device.Height;
  Message.Value := Screen^.Dpi;
  Message.Code := Screen^.ScalePercent;
  SendToProgram(Window, Message);
end;

procedure SetWindowOwner(Window, Owner: PServerWindow);
begin
  if Window^.OwnerWindow = Owner then
    Exit;
  ChangeOwner(Window, Owner);
  if Window^.OwnerWindow <> Owner then
    Exit;
  if Window^.Visible then
    DamageWindow(Window);
  { Hidden along with its old owner: it comes back now, unless the new
    owner is hidden too (then it comes back with that one). }
  if Window^.HiddenWithOwner and ((Owner = nil) or Owner^.Visible) then
  begin
    Window^.HiddenWithOwner := False;
    Window^.Visible := True;
    DamageWindow(Window);
    SendVisibilityChanged(Window);
    ShowOwnedWindows(Window);
  end;
end;

procedure MoveWindowTo(Window: PServerWindow; ClientLeft, ClientTop: LongInt);
var
  OldFrame: TRectangle;
begin
  if (Window^.ClientLeft = ClientLeft) and (Window^.ClientTop = ClientTop) then
    Exit;
  OldFrame := FrameRectangle(Window);
  Window^.ClientLeft := ClientLeft;
  Window^.ClientTop := ClientTop;
  if Window^.Visible then
    MoveWindowPixels(Window, OldFrame);
  { The program knows where its window is (to place pop-ups). }
  TellWindowPlace(Window);
end;

procedure RequestResize(Window: PServerWindow; const Bounds: TRectangle);
var
  Message: TWindowMessage;
begin
  MoveWindowTo(Window, Bounds.Left, Bounds.Top);
  Message := NewMessage(EventResized, Window^.Id);
  Message.SurfaceWidth := RectangleWidth(Bounds);
  Message.SurfaceHeight := RectangleHeight(Bounds);
  SendToProgram(Window, Message);
end;

procedure ToggleMaximized(Window: PServerWindow);
var
  Title: LongInt;
  Bounds: TRectangle;
begin
  if Window^.Maximized then
  begin
    Window^.Maximized := False;
    RequestResize(Window, Window^.RestoreBounds);
    Exit;
  end;
  Window^.RestoreBounds := ClientRectangle(Window);
  Window^.Maximized := True;
  { The client area fills its screen below the title bar; the frame's
    borders lie just off the screen. }
  Title := WindowMetric(Window, Theme.TitleHeight);
  Bounds := WindowScreen(Window)^.Bounds;
  RequestResize(Window, MakeRectangle(Bounds.Left, Bounds.Top + Title, RectangleWidth(Bounds),
    RectangleHeight(Bounds) - Title));
end;

procedure ReleaseSurface(Window: PServerWindow);
begin
  if Window^.Surface.Pixels <> nil then
    UnmapSection(Window^.Surface.Pixels);
  Window^.Surface.Pixels := nil;
  if Window^.Section >= 0 then
    CloseHandle(Window^.Section);
  Window^.Section := -1;
end;

procedure DestroyWindow(Window: PServerWindow);
var
  WasActive: Boolean;
begin
  if Window^.Visible then
    DamageWindow(Window);
  WasActive := ActiveWindow = Window;
  if WasActive then
    ActiveWindow := nil;
  ForgetWindowInInput(Window);
  ReleaseSurface(Window);
  RemoveWindow(Window);
  if WasActive then
    ActivateWindow(NextActivatable(nil));
end;

end.
