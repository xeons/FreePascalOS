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
  Locking the screen, and how long nobody has used it.

  The display server keeps the lock itself: while a program running as
  root (the session manager) has the screen locked, only its windows
  are drawn and get input, so no other program can show itself over the
  lock screen or take the keyboard. IdleMilliseconds asks how long ago
  the last key, pointer movement or button was. RepaintDisplays has the
  server draw every display again (after waking from suspend).

  The calls that wait for the server's answer keep other events for the
  message loop (Windowing.Connection); the program must be connected.
}
unit Windowing.ScreenLock;

{$mode objfpc}

interface

{ Locks the screen for this program (Lock) or unlocks it; True if the
  screen is locked by this program afterwards (Lock) or not locked any
  more (not Lock). Only a program running as root may. }
function LockScreen(Lock: Boolean): Boolean;
{ The milliseconds since the last input; -1 if the server did not
  answer. }
function IdleMilliseconds: Int64;
{ Has the server draw every display again. }
procedure RepaintDisplays;

implementation

uses
  Windowing.Protocol,
  Windowing.Connection;

const
  ReplyTimeout = 5000;

function LockScreen(Lock: Boolean): Boolean;
var
  Message: TWindowMessage;
begin
  Message := NewMessage(RequestLockScreen, 0);
  Message.Value := Ord(Lock);
  SendRequest(Message, -1);
  if not WaitForEvent(EventScreenLock, ReplyTimeout, Message) then
    Exit(False);
  if Lock then
    Result := Message.Code <> 0
  else
    Result := Message.Value = 0;
end;

function IdleMilliseconds: Int64;
var
  Message: TWindowMessage;
begin
  Message := NewMessage(RequestDescribeIdle, 0);
  SendRequest(Message, -1);
  if not WaitForEvent(EventIdleDescribed, ReplyTimeout, Message) then
    Exit(-1);
  Result := Message.Value;
end;

procedure RepaintDisplays;
var
  Message: TWindowMessage;
begin
  Message := NewMessage(RequestRepaintDisplays, 0);
  SendRequest(Message, -1);
end;

end.
