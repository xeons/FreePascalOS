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
  Requests to end a program with windows: someone asked (kill), its
  service is stopped, the system shuts down, the user logs off.

  Once its message loop runs, a program takes those requests
  (Sys.Notifications, NotifyEndRequests) and the loop waits for them
  along with everything else. A request is handled as if the user had
  closed every window of the program that no other window owns: each
  gets CloseRequested, so a program asks to save its changes, or simply
  goes, exactly as when its close button is clicked (Notepad asks about
  unsaved text; the last window gone ends the loop). A program that
  wants something else sets OnEndRequested (the desktop, the session
  manager). One that would rather be ended by the system, as programs
  without windows are, sets TakeEndRequests to False before its loop
  runs.

  Nobody waits forever for a program asked to end: whoever asked may end
  it outright after a while (the service manager after the service's
  stop-timeout, the session manager when logging off, the shutdown).

  A request that comes while one is being handled (the program is
  asking its user whether to save) is dropped: the question already on
  the screen answers it.
}
unit Windowing.EndRequests;

{$mode objfpc}

interface

type
  { Reason: EndReason*. }
  TEndRequestedEvent = procedure(Reason: LongWord) of object;

var
  { Called for each end request (in the message loop); nil: the
    program's windows are asked to close. }
  OnEndRequested: TEndRequestedEvent = nil;
  { False: the program does not take end requests, and the system ends
    it for one, as it ends programs without windows. Read when the
    message loop first runs. }
  TakeEndRequests: Boolean = True;

{ For the message loop: True if it waits for notifications (taking the
  end requests the first time it is asked). }
function LoopWaitsForNotifications: Boolean;
{ For the message loop: notifications are waiting. }
procedure ServeNotifications;

implementation

uses
  Abi.SystemCalls,
  Sys.Notifications,
  Windowing.Windows;

var
  Decided: Boolean = False;
  Taken: Boolean = False;
  Handling: Boolean = False;

function LoopWaitsForNotifications: Boolean;
begin
  if not Decided then
  begin
    Decided := True;
    Taken := TakeEndRequests;
    if Taken then
      TakeNotifications(NotifyEndRequests);
  end;
  Result := Taken;
end;

procedure HandleEndRequest(Reason: LongWord);
begin
  if Handling then
    Exit;
  Handling := True;
  try
    if Assigned(OnEndRequested) then
      OnEndRequested(Reason)
    else
      AskWindowsToClose;
  finally
    Handling := False;
  end;
end;

procedure ServeNotifications;
var
  Notification: TAbiNotification;
begin
  while ReceiveNotification(Notification) do
    if Notification.Kind = NotificationEndRequested then
      HandleEndRequest(Notification.Reason);
end;

end.
