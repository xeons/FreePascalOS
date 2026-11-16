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
  Other programs' windows for a program that is not the shell: a task
  manager listing the programs with windows (RequestListWindows), and
  switching to or closing them (RequestManageWindow).

  A program sees and manages the windows of the programs of its own
  user, and root those of every program, much as the kernel lets a user
  end only their own processes: another user's window titles may say
  what that user is doing. The shell manages every window anyway.
}
unit Server.WindowList;

{$mode objfpc}

interface

uses
  Server.Clients,
  Server.Windows;

{ Sends Client an EventWindowListed for each top-level window of the
  other programs it may see, then the one that ends the list. }
procedure ListWindowsFor(Client: PClient);
{ Whether Client may activate, minimize, close... Window. }
function MayManageWindow(Client: PClient; Window: PServerWindow): Boolean;

implementation

uses
  Windowing.Protocol,
  Server.Shell;

const
  RootUserId = 0;

{ Client may see what the program behind Window does. }
function MaySeeProgramOf(Client: PClient; Window: PServerWindow): Boolean;
var
  Owner: PClient;
begin
  Owner := PClient(Window^.Client);
  Result := (Owner = Client) or (Client^.UserId = RootUserId) or (Owner^.UserId = Client^.UserId);
end;

procedure ListWindowsFor(Client: PClient);
var
  Index: LongInt;
  Window: PServerWindow;
  Message: TWindowMessage;
begin
  for Index := 0 to WindowCount - 1 do
  begin
    Window := Windows[Index];
    if (Window^.Client = Pointer(Client)) or not IsTopLevelWindow(Window) or not MaySeeProgramOf(Client, Window) then
      Continue;
    Message := NewMessage(EventWindowListed, Window^.Id);
    Message.Flags := WindowStateFlags(Window);
    Message.Code := LongWord(Window^.ScreenNumber);
    Message.Value := LongInt(PClient(Window^.Client)^.ProcessId);
    Move(Window^.Title, Message.Text, SizeOf(Message.Text));
    SendToClient(Client, Message);
  end;
  Message := NewMessage(EventWindowListed, 0);
  SendToClient(Client, Message);
end;

function MayManageWindow(Client: PClient; Window: PServerWindow): Boolean;
begin
  if (Window^.Client = Pointer(Client)) or IsShell(Client) then
    Exit(True);
  Result := IsTopLevelWindow(Window) and MaySeeProgramOf(Client, Window);
end;

end.
