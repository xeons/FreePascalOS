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
  Notifications: what the system tells a program - a request to end
  (with its reason: someone asked, the service is stopped, the system
  shuts down, the user logs off, the terminal hung up, Ctrl-C), or its
  terminal's new size - and asking other programs to end.

  A program takes the notifications it is ready for (TakeNotifications)
  and leaves the rest to the system, which ends the program for an end
  request it did not take, with the status it always had (143; 129 for
  a hang-up, 130 for Ctrl-C). A taken notification waits in the
  program's queue: the program includes NotificationsHandle in the
  handles it waits for (Sys.Objects.WaitForHandles) and reads it with
  ReceiveNotification once it is ready. A program that would rather
  not wait for them itself can have a thread do it (Sys.EndRequests).

  What the program takes is remembered here, so taking more adds to it
  without a moment in which nothing is taken.
}
unit Sys.Notifications;

{$mode objfpc}

interface

uses
  Abi.SystemCalls;

{ Takes the notifications of Mask (Notify*) besides those taken already;
  returns what was taken before. }
function TakeNotifications(Mask: LongWord): LongWord;
{ Leaves the notifications of Mask to the system again. }
function LeaveNotifications(Mask: LongWord): LongWord;
{ What the program takes itself. }
function TakenNotifications: LongWord;

{ Takes the oldest waiting notification; False if none waits. }
function ReceiveNotification(out Notification: TAbiNotification): Boolean;
{ Waits up to Timeout milliseconds (InfiniteWait: no limit) for a
  notification and takes it; False if none came. }
function WaitForNotification(out Notification: TAbiNotification; Timeout: Int64): Boolean;

{ Asks process ProcessId (0: this one) to end for Reason (EndReason*):
  ErrorNone, ErrorNoSuchProcess or ErrorNotPermitted. }
function AskProcessToEnd(ProcessId: QWord; Reason: LongWord): LongInt;
{ Asks every process of a group or a session (0: this program's own)
  but this one: how many were asked, or minus an error. }
function AskGroupToEnd(GroupId: QWord; Reason: LongWord): Int64;
function AskSessionToEnd(SessionId: QWord; Reason: LongWord): Int64;

{ "asked", "service-stop", "shutdown", "log-off", "hang-up",
  "interrupt"; "unknown" for anything else. }
function EndReasonName(Reason: LongWord): PChar;
{ The status the system ends a program with for an end request of
  Reason it did not take; a program that takes one and simply ends may
  end with it too. }
function EndStatusOf(Reason: LongWord): LongInt;

implementation

uses
  Sys.Kernel,
  Sys.Errors,
  Sys.Locks;

var
  Taken: LongWord = 0;
  TakenLock: TLock;

function SelectTaken(NewMask: LongWord): LongWord;
begin
  Result := Taken;
  if KernelSelectNotifications(NewMask) >= 0 then
    Taken := NewMask;
end;

function TakeNotifications(Mask: LongWord): LongWord;
begin
  AcquireLock(TakenLock);
  Result := SelectTaken(Taken or Mask);
  ReleaseLock(TakenLock);
end;

function LeaveNotifications(Mask: LongWord): LongWord;
begin
  AcquireLock(TakenLock);
  Result := SelectTaken(Taken and not Mask);
  ReleaseLock(TakenLock);
end;

function TakenNotifications: LongWord;
begin
  Result := Taken;
end;

function ReceiveNotification(out Notification: TAbiNotification): Boolean;
begin
  Result := KernelReceiveNotification(Notification) = 0;
end;

function WaitForNotification(out Notification: TAbiNotification; Timeout: Int64): Boolean;
var
  Handle: Int64;
begin
  Handle := NotificationsHandle;
  Result := (KernelWaitForHandles(@Handle, 1, Timeout, 0) = 0) and ReceiveNotification(Notification);
end;

function AskProcessToEnd(ProcessId: QWord; Reason: LongWord): LongInt;
begin
  Result := ErrorCodeOf(KernelRequestEnd(EndTargetProcess, ProcessId, Reason));
end;

function AskGroupToEnd(GroupId: QWord; Reason: LongWord): Int64;
begin
  Result := KernelRequestEnd(EndTargetGroup, GroupId, Reason);
end;

function AskSessionToEnd(SessionId: QWord; Reason: LongWord): Int64;
begin
  Result := KernelRequestEnd(EndTargetSession, SessionId, Reason);
end;

function EndReasonName(Reason: LongWord): PChar;
begin
  case Reason of
    EndReasonAsked: Result := 'asked';
    EndReasonServiceStop: Result := 'service-stop';
    EndReasonShutdown: Result := 'shutdown';
    EndReasonLogOff: Result := 'log-off';
    EndReasonHangUp: Result := 'hang-up';
    EndReasonInterrupt: Result := 'interrupt';
  else
    Result := 'unknown';
  end;
end;

function EndStatusOf(Reason: LongWord): LongInt;
begin
  case Reason of
    EndReasonHangUp: Result := EndStatusHangUp;
    EndReasonInterrupt: Result := EndStatusInterrupted;
  else
    Result := EndStatusRequested;
  end;
end;

end.
