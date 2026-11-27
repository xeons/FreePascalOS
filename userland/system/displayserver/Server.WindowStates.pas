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
  A window's states as the user sees them: minimized, maximized or
  neither, and the commands that move between them (the title buttons,
  the shell's taskbar: RequestManageWindow).

  Minimizing hides a window (and the windows it owns) but marks it, so
  the shell keeps its taskbar button and can bring it back; its program
  hears it was hidden (EventVisibilityChanged) like any other hiding.
  Showing it again, by its program or by the shell, ends the minimized
  state.
}
unit Server.WindowStates;

{$mode objfpc}
{$H+}

interface

uses
  Server.Windows;

{ Hides the window as minimized (nothing if it is not shown). }
procedure MinimizeWindow(Window: TServerWindow);
{ Carries out a Manage* command (Windowing.Protocol) on the window. }
procedure ManageWindow(Window: TServerWindow; Command: LongWord);
{ Asks the window's program to close it (its close button, Alt+F4, the
  taskbar); a program that does not respond is offered to the shell to
  end (EventShellEndTaskOffered). }
procedure AskToClose(Window: TServerWindow);

implementation

uses
  Windowing.Protocol,
  Server.Clients,
  Server.Shell,
  Server.Actions;

procedure MinimizeWindow(Window: TServerWindow);
begin
  if not Window.Visible then
    Exit;
  ShowWindow(Window, False);
  Window.Minimized := True;
end;

{ Shown again if it was minimized (which activates it). }
procedure RestoreFromMinimized(Window: TServerWindow);
begin
  if Window.Minimized then
    ShowWindow(Window, True);
end;

procedure AskToClose(Window: TServerWindow);
var
  Message: TWindowMessage;
begin
  Message := NewMessage(EventCloseRequested, Window.Id);
  SendToProgram(Window, Message);
  { A program that does not answer its pings will not hear this either:
    the shell offers to end it, so a hung window can always be closed. }
  if Window.NotResponding and (Window.Client <> nil) and not IsShell(TClient(Window.Client)) then
  begin
    Message := NewMessage(EventShellEndTaskOffered, Window.Id);
    Message.Value := LongInt(TClient(Window.Client).ProcessId);
    SetMessageText(Message, Window.Title);
    SendToShell(Message);
  end;
end;

procedure ManageWindow(Window: TServerWindow; Command: LongWord);
begin
  case Command of
    ManageActivate:
      if Window.Minimized then
        RestoreFromMinimized(Window)
      else
        ActivateWindow(Window);
    ManageMinimize:
      MinimizeWindow(Window);
    ManageRestore:
      if Window.Minimized then
        RestoreFromMinimized(Window)
      else if Window.Maximized then
        ToggleMaximized(Window);
    ManageMaximize:
      begin
        RestoreFromMinimized(Window);
        if not Window.Maximized and ((Window.Flags and WindowResizable) <> 0) then
          ToggleMaximized(Window);
        ActivateWindow(Window);
      end;
    ManageClose:
      AskToClose(Window);
  end;
end;

end.
