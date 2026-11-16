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
  A process's notification queue: what the system has to tell the
  process (an end request, its terminal's new size), waiting until the
  process reads it.

  The process waits on the queue among its other handles (the
  pseudo-handle NotificationsHandle in CallWaitForHandles), so a
  program's message loop or a shell's prompt hears of a notification
  without polling and without being interrupted at an arbitrary point,
  as a Unix signal would interrupt it. ReadyEvent is a notification
  event kept signaled exactly while something waits, under the queue's
  lock, so a waiter can never miss one or wake for nothing.

  A notification of the same kind and reason as one still waiting is
  merged into it (the newer sender and value win: a terminal's latest
  size), so the queue never holds more than one of each, and a sender
  never has to wait for room or lose what it says.

  Selected holds the Notify* bits the process takes itself; what it does
  not select never reaches the queue (Processes.EndRequests acts for
  it).
}
unit Processes.NotificationQueue;

{$mode objfpc}

interface

uses
  Abi.SystemCalls,
  Kernel.SpinLock,
  Kernel.Events;

const
  { One of each end reason and the terminal's size, with room to spare. }
  NotificationQueueCapacity = 16;

type
  TNotificationQueue = record
    Lock: TSpinLock;
    Entries: array[0..NotificationQueueCapacity - 1] of TAbiNotification;
    Count: LongInt;
    { Signaled while Count > 0. }
    ReadyEvent: TEvent;
    { Notify* bits: what the process takes itself. }
    Selected: LongWord;
  end;
  PNotificationQueue = ^TNotificationQueue;

procedure InitializeNotificationQueue(out Queue: TNotificationQueue);
{ Adds a notification (merged into a waiting one of the same kind and
  reason). Any level up to DispatchLevel. }
procedure PostNotification(var Queue: TNotificationQueue; Kind, Reason: LongWord; SenderProcessId, Value: QWord);
{ Takes the oldest notification; False if none waits. }
function TakeNotification(var Queue: TNotificationQueue; out Notification: TAbiNotification): Boolean;
{ Sets what the process takes itself; returns what it took before. }
function SelectNotifications(var Queue: TNotificationQueue; Mask: LongWord): LongWord;
{ True if the process takes the notifications of bit NotifyBit (Notify*)
  itself. }
function NotificationIsSelected(var Queue: TNotificationQueue; NotifyBit: LongWord): Boolean;

implementation

uses
  Kernel.PriorityLevel;

procedure InitializeNotificationQueue(out Queue: TNotificationQueue);
begin
  InitializeSpinLock(Queue.Lock);
  Queue.Count := 0;
  Queue.Selected := 0;
  InitializeEvent(Queue.ReadyEvent, EventKindNotification, False);
end;

{ The place of a waiting notification of the same kind and reason; -1
  for none. }
function IndexOfSameLocked(var Queue: TNotificationQueue; Kind, Reason: LongWord): LongInt;
var
  Index: LongInt;
begin
  for Index := 0 to Queue.Count - 1 do
    if (Queue.Entries[Index].Kind = Kind) and (Queue.Entries[Index].Reason = Reason) then
      Exit(Index);
  Result := -1;
end;

procedure PostNotification(var Queue: TNotificationQueue; Kind, Reason: LongWord; SenderProcessId, Value: QWord);
var
  PreviousLevel: TPriorityLevel;
  Index: LongInt;
begin
  PreviousLevel := AcquireSpinLock(Queue.Lock);
  Index := IndexOfSameLocked(Queue, Kind, Reason);
  if (Index < 0) and (Queue.Count < NotificationQueueCapacity) then
  begin
    Index := Queue.Count;
    Inc(Queue.Count);
    Queue.Entries[Index].Kind := Kind;
    Queue.Entries[Index].Reason := Reason;
  end;
  if Index >= 0 then
  begin
    Queue.Entries[Index].SenderProcessId := SenderProcessId;
    Queue.Entries[Index].Value := Value;
    SignalEvent(Queue.ReadyEvent);
  end;
  ReleaseSpinLock(Queue.Lock, PreviousLevel);
end;

function TakeNotification(var Queue: TNotificationQueue; out Notification: TAbiNotification): Boolean;
var
  PreviousLevel: TPriorityLevel;
  Index: LongInt;
begin
  PreviousLevel := AcquireSpinLock(Queue.Lock);
  Result := Queue.Count > 0;
  if Result then
  begin
    Notification := Queue.Entries[0];
    for Index := 1 to Queue.Count - 1 do
      Queue.Entries[Index - 1] := Queue.Entries[Index];
    Dec(Queue.Count);
    if Queue.Count = 0 then
      ResetEvent(Queue.ReadyEvent);
  end;
  ReleaseSpinLock(Queue.Lock, PreviousLevel);
end;

function SelectNotifications(var Queue: TNotificationQueue; Mask: LongWord): LongWord;
var
  PreviousLevel: TPriorityLevel;
begin
  PreviousLevel := AcquireSpinLock(Queue.Lock);
  Result := Queue.Selected;
  Queue.Selected := Mask;
  ReleaseSpinLock(Queue.Lock, PreviousLevel);
end;

function NotificationIsSelected(var Queue: TNotificationQueue; NotifyBit: LongWord): Boolean;
begin
  Result := (Queue.Selected and NotifyBit) <> 0;
end;

end.
