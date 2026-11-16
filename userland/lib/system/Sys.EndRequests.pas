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
  A handler for end requests, for programs with no loop of their own
  to wait in (a service that sleeps, computes or blocks in reads):
  HandleEndRequests takes the requests of a mask (Sys.Notifications)
  and starts a thread that waits for them and calls the handler for
  each, on that thread. The handler tidies up - writes out what it
  must, tells its children - and usually ends the program (Halt, which
  runs the unit finalizations and flushes the output in that thread);
  if it returns, the program carries on.

  The thread reads every notification of the program, so a program
  that uses it does not read its notifications itself; notifications
  that are not end requests are dropped. A program with its own wait
  (a message loop, the shell's prompt) includes NotificationsHandle in
  that wait instead.
}
unit Sys.EndRequests;

{$mode objfpc}

interface

type
  { Reason: EndReason*; SenderProcessId: who asked (0: the system). }
  TEndRequestHandler = procedure(Reason: LongWord; SenderProcessId: QWord);

{ Takes the end requests of Mask (NotifyEnd* bits) and calls Handler for
  each from a thread of its own. False if the thread could not start
  (the requests are then left to the system). Called once. }
function HandleEndRequests(Handler: TEndRequestHandler; Mask: LongWord): Boolean;

implementation

uses
  Abi.SystemCalls,
  Sys.Notifications,
  Sys.Threads;

var
  CurrentHandler: TEndRequestHandler = nil;

function WaitForEndRequests(Argument: Pointer): LongInt;
var
  Notification: TAbiNotification;
begin
  repeat
    if WaitForNotification(Notification, InfiniteWait) and
       (Notification.Kind = NotificationEndRequested) then
      CurrentHandler(Notification.Reason, Notification.SenderProcessId);
  until False;
  Result := 0;
end;

function HandleEndRequests(Handler: TEndRequestHandler; Mask: LongWord): Boolean;
var
  Thread: Int64;
begin
  CurrentHandler := Handler;
  Thread := CreateThread(@WaitForEndRequests, nil);
  Result := Thread >= 0;
  if not Result then
    Exit;
  CloseThreadHandle(Thread);
  TakeNotifications(Mask);
end;

end.
