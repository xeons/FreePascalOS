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
  The shell: the one program (if any) that shows the desktop and the
  taskbar, and so must know every other program's windows.

  The first program to ask becomes the shell; others are refused while
  it lives. It is told about each top-level window of the other programs
  (framed, owned by no window, not a desktop): its title, whether it is
  shown, minimized, active or maximized, and the display it is on.
  Rather than every place that changes a window telling the shell,
  TellShellAboutWindows compares each window with what the shell last
  heard of it (kept in the window: ToldFlags, ToldTitle...) once per
  turn of the server's loop and sends what differs. A window going, or
  stopping being top-level, is told as gone. When the shell ends, the
  work areas it set go with it and the next shell hears everything
  again.
}
unit Server.Shell;

{$mode objfpc}

interface

uses
  Windowing.Protocol,
  Server.Clients,
  Server.Windows;

{ Makes Client the shell if there is none; False if another is. }
function RegisterShell(Client: PClient): Boolean;
function IsShell(Client: PClient): Boolean;
{ Client is going: if it is the shell, there is none any more. }
procedure ForgetClientInShell(Client: PClient);
{ The window is going: the shell hears it is gone, if it knew it. }
procedure ForgetWindowInShell(Window: PServerWindow);
{ Tells the shell what changed in the windows since it was last told. }
procedure TellShellAboutWindows;
{ Tells the shell the displays were laid out again. }
procedure TellShellDisplaysChanged;
{ Sends Message to the shell, if there is one. }
procedure SendToShell(var Message: TWindowMessage);
{ A window a taskbar or a task manager lists: framed, owned by no
  window, not a desktop. }
function IsTopLevelWindow(Window: PServerWindow): Boolean;
{ What the window is like now (ShellWindow*). }
function WindowStateFlags(Window: PServerWindow): LongWord;

implementation

uses
  Sys.Text,
  Server.Composer,
  Server.WorkAreas;

var
  ShellClient: PClient;

function IsShell(Client: PClient): Boolean;
begin
  Result := (Client <> nil) and (Client = ShellClient);
end;

procedure SendToShell(var Message: TWindowMessage);
begin
  if ShellClient <> nil then
    SendToClient(ShellClient, Message);
end;

{ Every window as if the shell had never heard of it. }
procedure ForgetWhatShellWasTold;
var
  Index: LongInt;
begin
  for Index := 0 to WindowCount - 1 do
    Windows[Index]^.ToldShell := False;
end;

function RegisterShell(Client: PClient): Boolean;
begin
  if (ShellClient <> nil) and (ShellClient <> Client) then
    Exit(False);
  ShellClient := Client;
  ForgetWhatShellWasTold;
  Result := True;
end;

procedure ForgetClientInShell(Client: PClient);
begin
  if not IsShell(Client) then
    Exit;
  ShellClient := nil;
  ForgetWhatShellWasTold;
  ClearWorkAreas;
end;

function IsTopLevelWindow(Window: PServerWindow): Boolean;
begin
  Result := IsFramed(Window) and (Window^.OwnerWindow = nil) and ((Window^.Flags and WindowDesktop) = 0);
end;

{ A window the shell shows on its taskbar: another program's top-level
  window. }
function IsListed(Window: PServerWindow): Boolean;
begin
  Result := (ShellClient <> nil) and (Window^.Client <> Pointer(ShellClient)) and IsTopLevelWindow(Window);
end;

function WindowStateFlags(Window: PServerWindow): LongWord;
begin
  Result := 0;
  if Window^.Visible then
    Result := Result or ShellWindowVisible;
  if Window^.Minimized then
    Result := Result or ShellWindowMinimized;
  { Its dialog having the keyboard counts as its own. }
  if (ActiveWindow <> nil) and ((ActiveWindow = Window) or IsOwnedBy(ActiveWindow, Window)) then
    Result := Result or ShellWindowActive;
  if Window^.Maximized then
    Result := Result or ShellWindowMaximized;
  if (Window^.Flags and WindowResizable) <> 0 then
    Result := Result or ShellWindowResizable;
end;

procedure TellWindowGone(Window: PServerWindow);
var
  Message: TWindowMessage;
begin
  Window^.ToldShell := False;
  Message := NewMessage(EventShellWindowGone, Window^.Id);
  SendToShell(Message);
end;

procedure ForgetWindowInShell(Window: PServerWindow);
begin
  if Window^.ToldShell then
    TellWindowGone(Window);
end;

procedure TellWindowState(Window: PServerWindow);
var
  Message: TWindowMessage;
  Flags: LongWord;
begin
  Flags := WindowStateFlags(Window);
  if Window^.ToldShell and (Window^.ToldFlags = Flags) and (Window^.ToldScreen = Window^.ScreenNumber) and
     (CompareText(Window^.ToldTitle, Window^.Title) = 0) then
    Exit;
  Window^.ToldShell := True;
  Window^.ToldFlags := Flags;
  Window^.ToldScreen := Window^.ScreenNumber;
  Move(Window^.Title, Window^.ToldTitle, SizeOf(Window^.ToldTitle));
  Message := NewMessage(EventShellWindowChanged, Window^.Id);
  Message.Flags := Flags;
  Message.Code := LongWord(Window^.ScreenNumber);
  Message.Value := LongInt(PClient(Window^.Client)^.ProcessId);
  Move(Window^.Title, Message.Text, SizeOf(Message.Text));
  SendToShell(Message);
end;

procedure TellShellAboutWindows;
var
  Index: LongInt;
  Window: PServerWindow;
begin
  if ShellClient = nil then
    Exit;
  for Index := 0 to WindowCount - 1 do
  begin
    Window := Windows[Index];
    if IsListed(Window) then
      TellWindowState(Window)
    else if Window^.ToldShell then
      TellWindowGone(Window);
  end;
end;

procedure TellShellDisplaysChanged;
var
  Message: TWindowMessage;
begin
  Message := NewMessage(EventDisplaysChanged, 0);
  SendToShell(Message);
end;

end.
