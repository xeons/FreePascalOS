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
  The system calls of notifications: choosing which ones a process takes
  itself, reading them, and asking processes to end
  (Processes.NotificationQueue, Processes.EndRequests). Waiting for one
  is CallWaitForHandles with the pseudo-handle NotificationsHandle
  (Processes.WaitCalls).
}
unit Processes.NotificationCalls;

{$mode objfpc}

interface

function PerformSelectNotifications(Mask: QWord): Int64;
function PerformReceiveNotification(NotificationAddress: QWord): Int64;
function PerformRequestEnd(TargetKind, TargetId, Reason: QWord): Int64;

implementation

uses
  Abi.SystemCalls,
  Processes.Process,
  Processes.Thread,
  Processes.NotificationQueue,
  Processes.EndRequests,
  Processes.UserAccess;

function PerformSelectNotifications(Mask: QWord): Int64;
begin
  if (Mask and not QWord(NotifyEverything)) <> 0 then
    Exit(-Int64(ErrorInvalidArgument));
  Result := SelectNotifications(CurrentProcess^.Notifications, LongWord(Mask));
end;

function PerformReceiveNotification(NotificationAddress: QWord): Int64;
var
  Notification: TAbiNotification;
  Queue: PNotificationQueue;
begin
  Queue := @CurrentProcess^.Notifications;
  if not TakeNotification(Queue^, Notification) then
    Exit(-Int64(ErrorWouldBlock));
  Result := -Int64(CopyToUser(NotificationAddress, @Notification, SizeOf(Notification)));
  { A notification the program could not take is not lost. }
  if Result <> 0 then
    PostNotification(Queue^, Notification.Kind, Notification.Reason, Notification.SenderProcessId,
      Notification.Value);
end;

function PerformRequestEnd(TargetKind, TargetId, Reason: QWord): Int64;
begin
  Result := RequestEnd(TargetKind, TargetId, Reason);
end;

end.
