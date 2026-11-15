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
  read end's or channel end's Readable event, a pipe write end's
  Writable event, a port's Pending event, a device's ReadyEvent (if its
  driver keeps one: the console's says a read would not wait). The
  objects are held for the wait, which is alertable: ending or stopping
  the process ends it (ErrorInterrupted).

  With WaitForAll the wait lasts until every handle is ready at the same
  time, and the automatic reset events and timers among them are
  consumed only then, together (Kernel.Events).
}
unit Processes.WaitCalls;

{$mode objfpc}
{$pointermath on}

interface

function PerformWaitForHandles(HandlesAddress: QWord; Count: QWord; Timeout: Int64; Flags: QWord): Int64;

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
    HandleKindPipeWriteEnd: Result := @PPipe(ObjectBody)^.Writable;
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

{ Waits on the events of the handles; the result as the call returns it. }
function WaitForEvents(Events: PPEvent; Count: LongInt; TimeoutMilliseconds: QWord; WaitForAll: Boolean): Int64;
var
  WaitResult: TWaitResult;
  Signaled: LongInt;
begin
  Signaled := 0;
  if WaitForAll then
    WaitResult := WaitForAllEvents(Events, Count, TimeoutMilliseconds, True)
  else
    WaitResult := WaitForAnyEvent(Events, Count, TimeoutMilliseconds, True, Signaled);
  case WaitResult of
    WaitSignaled: Result := Signaled;
    WaitTimedOut: Result := Failure(ErrorTimedOut);
  else
    Result := Failure(ErrorInterrupted);
  end;
end;

function PerformWaitForHandles(HandlesAddress: QWord; Count: QWord; Timeout: Int64; Flags: QWord): Int64;
var
  Handles: array[0..MaximumWaitHandles - 1] of Int64;
  Bodies: array[0..MaximumWaitHandles - 1] of Pointer;
  Events: array[0..MaximumWaitHandles - 1] of PEvent;
  Held: LongInt;
  Index: LongInt;
  Kind: THandleKind;
  Error: LongInt;
  TimeoutMilliseconds: QWord;
begin
  if (Count = 0) or (Count > MaximumWaitHandles) or ((Flags and not WaitForAll) <> 0) then
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
    Result := WaitForEvents(@Events[0], LongInt(Count), TimeoutMilliseconds,
      (Flags and WaitForAll) <> 0);
  end
  else
    Result := Failure(Error);
  for Index := 0 to Held - 1 do
    DereferenceObject(Bodies[Index]);
end;

end.
