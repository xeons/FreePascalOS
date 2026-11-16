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
  The screen lock: a state the server owns, so no program can draw over
  the lock screen, take the keyboard or the pointer, or be raised above
  it, whatever it asks.

  A program running as root (the session manager) locks the screen
  (RequestLockScreen). While it is locked only that program's windows
  (the lock screen) are drawn, over a plain background; every other
  window is left out of composing (Server.Composer), is not under the
  pointer (Server.Windows.WindowAt), cannot be activated or capture the
  pointer (Server.Actions, Server.Input), and the shell's keys for the
  whole desktop are swallowed (Server.Hotkeys). Alt+F4 does nothing.
  Locking drops any drag or capture in progress and takes the keyboard
  from the window that had it; unlocking gives it back.

  If the program holding the lock ends, the screen stays locked (with
  nothing but the background) until a program running as root takes the
  lock over or unlocks it: a crash must not uncover the desktop.

  The server also keeps the time of the last input, which any program
  may ask for (RequestDescribeIdle): the session manager locks the
  screen after a while without any.
}
unit Server.ScreenLock;

{$mode objfpc}
{$H+}

interface

uses
  Windowing.Protocol,
  Server.Windows,
  Server.Clients;

{ The screen is locked. }
function ScreenLocked: Boolean;
{ Whether Window may be seen and take input now: any window while the
  screen is not locked; while it is, only the windows of the program
  holding the lock. }
function WindowUsable(Window: TServerWindow): Boolean;
{ Carries out RequestLockScreen, RequestDescribeIdle and
  RequestRepaintDisplays; False if Message is none of them. }
function CarryOutLockRequest(Client: TClient; var Message: TWindowMessage): Boolean;
{ Client is going: if it held the lock, the screen stays locked with
  nobody holding it. }
procedure ForgetClientInLock(Client: TClient);
{ Input has just arrived (the idle time starts again). }
procedure NoteInput;

implementation

uses
  Sys.Time,
  Server.Screen,
  Server.Composer,
  Server.Actions,
  Server.Input;

const
  RootUserId = 0;

var
  Locked: Boolean;
  { The program holding the lock (nil: it ended). }
  LockOwner: TClient;
  { The window that had the keyboard when the screen was locked. }
  ActiveBeforeLock: LongWord;
  LastInputTime: QWord;

function ScreenLocked: Boolean;
begin
  Result := Locked;
end;

function WindowUsable(Window: TServerWindow): Boolean;
begin
  Result := not Locked or ((Window <> nil) and (LockOwner <> nil) and (Window.Client = LockOwner));
end;

procedure NoteInput;
begin
  LastInputTime := UptimeMilliseconds;
end;

procedure Lock(Client: TClient);
begin
  if Locked and (LockOwner <> nil) and (LockOwner <> Client) then
    Exit;
  LockOwner := Client;
  if not Locked then
  begin
    Locked := True;
    ActiveBeforeLock := 0;
    if ActiveWindow <> nil then
      ActiveBeforeLock := ActiveWindow.Id;
    ReleasePointer;
  end;
  { The keyboard goes to the lock screen, or nowhere. }
  ActivateTopWindow;
  AddDamage(DesktopBounds);
end;

procedure Unlock(Client: TClient);
var
  Previous: TServerWindow;
begin
  if not Locked or ((LockOwner <> nil) and (LockOwner <> Client)) then
    Exit;
  Locked := False;
  LockOwner := nil;
  ReleasePointer;
  AddDamage(DesktopBounds);
  Previous := FindWindow(ActiveBeforeLock);
  if (Previous <> nil) and Previous.Visible and not Previous.Disabled then
    ActivateWindow(Previous)
  else
    ActivateTopWindow;
end;

procedure AnswerLockRequest(Client: TClient);
var
  Reply: TWindowMessage;
begin
  Reply := NewMessage(EventScreenLock, 0);
  Reply.Value := Ord(Locked);
  Reply.Code := Ord(Locked and (LockOwner = Client));
  SendToClient(Client, Reply);
end;

procedure AnswerIdleRequest(Client: TClient);
var
  Reply: TWindowMessage;
  Idle: QWord;
begin
  Idle := UptimeMilliseconds - LastInputTime;
  if Idle > QWord(High(LongInt)) then
    Idle := QWord(High(LongInt));
  Reply := NewMessage(EventIdleDescribed, 0);
  Reply.Value := LongInt(Idle);
  SendToClient(Client, Reply);
end;

function CarryOutLockRequest(Client: TClient; var Message: TWindowMessage): Boolean;
begin
  Result := True;
  case Message.Kind of
    RequestLockScreen:
      begin
        if Client.UserId = RootUserId then
          if Message.Value <> 0 then
            Lock(Client)
          else
            Unlock(Client);
        AnswerLockRequest(Client);
      end;
    RequestDescribeIdle:
      AnswerIdleRequest(Client);
    RequestRepaintDisplays:
      AddDamage(DesktopBounds);
  else
    Result := False;
  end;
end;

procedure ForgetClientInLock(Client: TClient);
begin
  if LockOwner = Client then
  begin
    LockOwner := nil;
    AddDamage(DesktopBounds);
  end;
end;

initialization
  LastInputTime := UptimeMilliseconds;
end.
