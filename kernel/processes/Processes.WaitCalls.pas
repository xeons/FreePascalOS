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
  Waiting on several handles at once (CallWaitForHandles).

  Each handle stands for an event that says it is ready: an event or
  timer object's own event, a process's or thread's exit event, a pipe
  read end's or channel end's Readable event, a port's Pending event, a
  device's ReadyEvent (if its driver keeps one). The objects are held
  for the wait, which is alertable: ending or stopping the process ends
  it (ErrorInterrupted).
}
unit Processes.WaitCalls;

{$mode objfpc}
{$pointermath on}

interface

function PerformWaitForHandles(HandlesAddress: QWord; Count: QWord; Timeout: Int64): Int64;

implementation

uses
  Abi.SystemCalls,
  Kernel.Events,
  Kernel.Threads,
  Kernel.Scheduler,
  Objects.Manager,
  Objects.Events,
  Objects.Timers,
  Io.Manager,
  Io.Pipes,
  Processes.Handles,
  Processes.Process,
  Processes.Thread,
  Processes.UserAccess,
  Processes.Channels,
  Processes.ObjectCalls;

function Failure(Error: LongInt): Int64;
begin
  Result := -Int64(Error);
end;

{ The event that says the object is ready; nil if it cannot be waited on. }
function ReadinessEvent(Kind: THandleKind; ObjectBody: Pointer): PEvent;
begin
  case Kind of
    HandleKindEvent: Result := @PEventObject(ObjectBody)^.Event;
    HandleKindTimer: Result := @PTimerObject(ObjectBody)^.Event;
    HandleKindProcess: Result := @PProcess(ObjectBody)^.ExitEvent;
    HandleKindThread: Result := @PThread(ObjectBody)^.ExitEvent;
    HandleKindPipeReadEnd: Result := @PPipe(ObjectBody)^.Readable;
    HandleKindChannel: Result := @PChannelEnd(ObjectBody)^.Readable;
    HandleKindPort: Result := @PPort(ObjectBody)^.Pending;
    HandleKindDevice:
      if PDeviceFile(ObjectBody)^.IsDirectory then
        Result := nil
      else
        Result := PEvent(PDeviceFile(ObjectBody)^.Device^.ReadyEvent);
  else
    Result := nil;
  end;
end;

function PerformWaitForHandles(HandlesAddress: QWord; Count: QWord; Timeout: Int64): Int64;
var
  Handles: array[0..MaximumWaitHandles - 1] of Int64;
  Bodies: array[0..MaximumWaitHandles - 1] of Pointer;
  Events: array[0..MaximumWaitHandles - 1] of PEvent;
  Held: LongInt;
  Index: LongInt;
  Kind: THandleKind;
  Error: LongInt;
  TimeoutMilliseconds: QWord;
  Signaled: LongInt;
begin
  if (Count = 0) or (Count > MaximumWaitHandles) then
    Exit(Failure(ErrorInvalidArgument));
  Error := CopyFromUser(@Handles[0], HandlesAddress, Count * SizeOf(Int64));
  if Error <> ErrorNone then
    Exit(Failure(Error));
  Held := 0;
  while (Error = ErrorNone) and (QWord(Held) < Count) do
  begin
    Bodies[Held] := ReferenceHandle(Handles[Held], Kind);
    if Bodies[Held] = nil then
      Error := ErrorBadHandle
    else
    begin
      Events[Held] := ReadinessEvent(Kind, Bodies[Held]);
      Inc(Held);
      if Events[Held - 1] = nil then
        Error := ErrorUnsupported;
    end;
  end;
  if Error = ErrorNone then
  begin
    if Timeout < 0 then
      TimeoutMilliseconds := InfiniteTimeout
    else
      TimeoutMilliseconds := QWord(Timeout);
    case WaitForAnyEvent(@Events[0], LongInt(Count), TimeoutMilliseconds, True, Signaled) of
      WaitSignaled: Result := Signaled;
      WaitTimedOut: Result := Failure(ErrorTimedOut);
    else
      Result := Failure(ErrorInterrupted);
    end;
  end
  else
    Result := Failure(Error);
  for Index := 0 to Held - 1 do
    DereferenceObject(Bodies[Index]);
end;

end.
