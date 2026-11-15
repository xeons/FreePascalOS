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
  Being the shell: the program that shows the desktop and the taskbar.

  RegisterAsShell asks the display server for the role (one program has
  it at a time). From then on the server tells the shell about every
  other program's top-level windows, the displays being laid out again
  and the notification icons; the message loop (Windowing.Windows)
  hands those events to OnShellEvent, as they are about no window of the
  shell's own. The shell sets each display's work area (what its
  taskbar leaves) and manages other programs' windows; ManageWindow is
  also how any program minimizes or maximizes its own windows.
}
unit Windowing.Shell;

{$mode objfpc}

interface

uses
  Windowing.Protocol;

type
  TShellEventHandler = procedure(const Message: TWindowMessage) of object;

var
  { Gets EventShellWindowChanged, EventShellWindowGone,
    EventDisplaysChanged and EventNotificationIconChanged. }
  OnShellEvent: TShellEventHandler;

{ Asks to be the shell; False if another program is (or no answer). The
  program must be connected (ConnectToDisplay). }
function RegisterAsShell: Boolean;
{ Makes Left, Top, Width, Height (logical units of the desktop) the work
  area of display Number; only the shell may. }
procedure SetWorkArea(Number: LongInt; Left, Top, Width, Height: LongInt);
{ Carries out a Manage* command on window Id (any program's for the
  shell, else one of this program's own). }
procedure ManageWindow(Id: LongWord; Command: LongWord);
{ Whether an event of Kind is for the shell (and OnShellEvent). }
function IsShellEvent(Kind: LongWord): Boolean;
{ Hands Message to OnShellEvent, if set. }
procedure DeliverShellEvent(const Message: TWindowMessage);

implementation

uses
  Windowing.Connection;

const
  ReplyTimeout = 5000;

function RegisterAsShell: Boolean;
var
  Message: TWindowMessage;
begin
  Message := NewMessage(RequestRegisterShell, 0);
  SendRequest(Message, -1);
  Result := WaitForEvent(EventShellRegistered, ReplyTimeout, Message) and (Message.Value <> 0);
end;

procedure SetWorkArea(Number: LongInt; Left, Top, Width, Height: LongInt);
var
  Message: TWindowMessage;
begin
  Message := NewMessage(RequestSetWorkArea, 0);
  Message.Code := LongWord(Number);
  Message.Left := Left;
  Message.Top := Top;
  Message.Width := Width;
  Message.Height := Height;
  SendRequest(Message, -1);
end;

procedure ManageWindow(Id: LongWord; Command: LongWord);
var
  Message: TWindowMessage;
begin
  if Id = 0 then
    Exit;
  Message := NewMessage(RequestManageWindow, Id);
  Message.Code := Command;
  SendRequest(Message, -1);
end;

function IsShellEvent(Kind: LongWord): Boolean;
begin
  Result := (Kind = EventShellWindowChanged) or (Kind = EventShellWindowGone) or (Kind = EventDisplaysChanged) or
    (Kind = EventNotificationIconChanged);
end;

procedure DeliverShellEvent(const Message: TWindowMessage);
begin
  if Assigned(OnShellEvent) then
    OnShellEvent(Message);
end;

end.
