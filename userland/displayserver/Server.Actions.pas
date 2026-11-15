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
  the user (Server.Input): activating, showing, moving, resizing and
  destroying it, and telling its program what happened.
}
unit Server.Actions;

{$mode objfpc}

interface

uses
  Drawing.Rectangles,
  Windowing.Protocol,
  Server.Windows;

{ Sends Message (its Window set to Window's) to the window's program. }
procedure SendToOwner(Window: PServerWindow; var Message: TWindowMessage);
{ Brings the window to the front and gives it the keyboard (nil: none). }
procedure ActivateWindow(Window: PServerWindow);
procedure ShowWindow(Window: PServerWindow; Show: Boolean);
procedure MoveWindowTo(Window: PServerWindow; ClientLeft, ClientTop: LongInt);
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
  Server.Composer,
  Server.Clients,
  Server.Input;

procedure SendToOwner(Window: PServerWindow; var Message: TWindowMessage);
begin
  Message.Window := Window^.Id;
  SendToClient(PClient(Window^.Owner), Message);
end;

procedure SendActivated(Window: PServerWindow; Active: Boolean);
var
  Message: TWindowMessage;
begin
  Message := NewMessage(EventActivated, Window^.Id);
  Message.Value := Ord(Active);
  SendToOwner(Window, Message);
end;

procedure ActivateWindow(Window: PServerWindow);
var
  Previous: PServerWindow;
begin
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
    if (Windows[Index] <> Excluded) and Windows[Index]^.Visible and
       ((Windows[Index]^.Flags and WindowNoActivate) = 0) then
      Exit(Windows[Index]);
  Result := nil;
end;

procedure ShowWindow(Window: PServerWindow; Show: Boolean);
begin
  if Window^.Visible = Show then
    Exit;
  Window^.Visible := Show;
  DamageWindow(Window);
  if Show then
    ActivateWindow(Window)
  else if ActiveWindow = Window then
    ActivateWindow(NextActivatable(Window));
end;

procedure MoveWindowTo(Window: PServerWindow; ClientLeft, ClientTop: LongInt);
begin
  if Window^.Visible then
    DamageWindow(Window);
  Window^.ClientLeft := ClientLeft;
  Window^.ClientTop := ClientTop;
  if Window^.Visible then
    DamageWindow(Window);
end;

procedure RequestResize(Window: PServerWindow; const Bounds: TRectangle);
var
  Message: TWindowMessage;
begin
  MoveWindowTo(Window, Bounds.Left, Bounds.Top);
  Message := NewMessage(EventResized, Window^.Id);
  Message.SurfaceWidth := RectangleWidth(Bounds);
  Message.SurfaceHeight := RectangleHeight(Bounds);
  SendToOwner(Window, Message);
end;

procedure ToggleMaximized(Window: PServerWindow);
var
  Title: LongInt;
begin
  if Window^.Maximized then
  begin
    Window^.Maximized := False;
    RequestResize(Window, Window^.RestoreBounds);
    Exit;
  end;
  Window^.RestoreBounds := ClientRectangle(Window);
  Window^.Maximized := True;
  { The client area fills the screen below the title bar; the frame's
    borders lie just off the screen. }
  Title := ScaledMetric(Theme.TitleHeight);
  RequestResize(Window, MakeRectangle(0, Title, RectangleWidth(ScreenBounds), RectangleHeight(ScreenBounds) - Title));
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
