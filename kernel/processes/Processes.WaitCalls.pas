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
  timer object's own event, a semaphore's (signaled while its count is
  above zero; a wait it ends takes one), a process's or thread's exit event, a pipe
  read end's or channel end's Readable event, a pipe write end's
  Writable event, a port's Pending event, a watch's Ready event (change
  records waiting), a socket's Readable event, a device's ReadyEvent (if its
  driver keeps one: a terminal's says a read would not wait), or for a
  device opened only for writing its WritableEvent (a pseudo-terminal's
  master side: room to type), an event descriptor's (an event counter
  above zero, a timer descriptor that went off, a signal descriptor with
  a signal waiting, an event poll with ready entries, a watch group with
  records). A file, and a device whose driver keeps
  no such event, is always ready, as poll says of them elsewhere: a
  read of it does not wait for anyone else (so a program can wait on
  its standard input and a socket together whatever the input is). The
  pseudo-handle NotificationsHandle stands for the calling process's
  notification queue (its ReadyEvent: a notification waits). The
  objects are held for the wait, which is alertable: ending or stopping
  the process ends it (ErrorInterrupted).

  With WaitForAll the wait lasts until every handle is ready at the same
  time, and the automatic reset events and timers among them are
  consumed only then, together (Kernel.Events).

  A mutex is ready while no thread owns it, and always for its owner; a
  wait it ends makes the waiting thread its owner (Kernel.MutexEvents).
  If the wait took a mutex whose previous owner ended holding it, the
  result has WaitAbandoned added.
}
unit Processes.WaitCalls;

{$mode objfpc}
{$pointermath on}

interface

{ Once, before the first system call. }
procedure InitializeWaitCalls;
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
  Objects.Semaphores,
  Objects.Mutexes,
  Kernel.MutexEvents,
  Io.Manager,
  Io.Pipes,
  Processes.Handles,
  Processes.Process,
  Processes.Thread,
  Processes.UserAccess,
  Processes.Channels,
  Processes.ObjectCalls,
  FileSystem.Watches,
  Network.Sockets,
  Processes.LocalSockets,
  FileSystem.WatchGroups,
  Objects.EventCounters,
  Objects.TimerDescriptors,
  Processes.SignalDescriptors,
  Processes.EventPolls,
  Processes.EventDescriptorCalls;

var
  { Signaled from the start and never reset: what files wait on. }
  AlwaysReadyEvent: TEvent;

function Failure(Error: LongInt): Int64;
begin
  Result := -Int64(Error);
end;

procedure InitializeWaitCalls;
begin
  InitializeEvent(AlwaysReadyEvent, EventKindNotification, True);
end;

{ A device opened only for writing is ready when a write would not
  wait; otherwise when a read would not wait. }
function DeviceReadinessEvent(OpenFile: PDeviceFile): PEvent;
begin
  if OpenFile^.IsDirectory then
    Exit(nil);
  if ((OpenFile^.OpenFlags and OpenRead) = 0) and ((OpenFile^.OpenFlags and OpenWrite) <> 0) then
    Result := PEvent(OpenFile^.Device^.WritableEvent)
  else
    Result := PEvent(OpenFile^.Device^.ReadyEvent);
  if Result = nil then
    Result := @AlwaysReadyEvent;
end;

{ The event that says the object is ready; nil if it cannot be waited on. }
function ReadinessEvent(Kind: THandleKind; ObjectBody: Pointer): PEvent;
begin
  case Kind of
    HandleKindFile: Result := @AlwaysReadyEvent;
    HandleKindEvent: Result := @PEventObject(ObjectBody)^.Event;
    HandleKindTimer: Result := @PTimerObject(ObjectBody)^.Event;
    { Signaled while its count is above zero; a wait it ends takes one. }
    HandleKindSemaphore: Result := @PSemaphoreObject(ObjectBody)^.Semaphore.Event;
    { Free, or owned by the waiting thread; a wait it ends takes it. }
    HandleKindMutex: Result := @PMutexObject(ObjectBody)^.Event;
    HandleKindProcess: Result := @PProcess(ObjectBody)^.ExitEvent;
    HandleKindThread: Result := @PThread(ObjectBody)^.ExitEvent;
    HandleKindPipeReadEnd: Result := @PPipe(ObjectBody)^.Readable;
    HandleKindPipeWriteEnd: Result := @PPipe(ObjectBody)^.Writable;
    HandleKindChannel: Result := @PChannelEnd(ObjectBody)^.Readable;
    HandleKindPort: Result := @PPort(ObjectBody)^.Pending;
    HandleKindWatch: Result := @PWatch(ObjectBody)^.Ready;
    { Data, a connection to accept, the end of the stream or an error. }
    HandleKindSocket: Result := @PSocket(ObjectBody)^.Readable;
    HandleKindLocalSocket: Result := @PLocalSocket(ObjectBody)^.Readable;
    HandleKindDevice:
      Result := DeviceReadinessEvent(PDeviceFile(ObjectBody));
    { Event descriptors: ready to read. }
    HandleKindEventCounter: Result := @PEventCounter(ObjectBody)^.Readable;
    HandleKindTimerDescriptor: Result := @PTimerDescriptor(ObjectBody)^.Ready;
    HandleKindSignalDescriptor: Result := @PSignalDescriptor(ObjectBody)^.Ready;
    HandleKindEventPoll: Result := @PEventPoll(ObjectBody)^.Ready;
    HandleKindWatchGroup: Result := @PWatchGroup(ObjectBody)^.Ready;
  else
    Result := nil;
  end;
end;

{ Takes a reference to what Handle names, and the event that says it
  is ready: Event is nil for a handle that cannot be waited on, and
  the result nil for no such handle. }
function ReferenceWaitable(Handle: Int64; out Event: PEvent): Pointer;
var
  Kind: THandleKind;
  Process: PProcess;
begin
  Event := nil;
  if Handle = NotificationsHandle then
  begin
    Process := CurrentProcess;
    ReferenceObject(Process);
    Event := @Process^.Notifications.ReadyEvent;
    Exit(Process);
  end;
  Result := ReferenceHandle(Handle, Kind);
  if Result <> nil then
  begin
    PrepareEventDescriptorWait(Kind, Result);
    Event := ReadinessEvent(Kind, Result);
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

{ Whether the wait that just ended took a mutex its previous owner
  abandoned (each such mark is taken, so it is told once): the
  Signaled one, or for a wait for all any of them. }
function TookAbandonedMutex(Events: PPEvent; Count: LongInt; Signaled: Int64; WaitForAll: Boolean): Boolean;
var
  Position: LongInt;
begin
  Result := False;
  for Position := 0 to Count - 1 do
    if (WaitForAll or (Position = Signaled)) and (Events[Position]^.Kind = EventKindMutex) then
      if TakeAbandonedMark(Events[Position]^) then
        Result := True;
end;

function PerformWaitForHandles(HandlesAddress: QWord; Count: QWord; Timeout: Int64; Flags: QWord): Int64;
var
  Handles: array[0..MaximumWaitHandles - 1] of Int64;
  Bodies: array[0..MaximumWaitHandles - 1] of Pointer;
  Events: array[0..MaximumWaitHandles - 1] of PEvent;
  Held: LongInt;
  Index: LongInt;
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
    Bodies[Held] := ReferenceWaitable(Handles[Held], Events[Held]);
    if Bodies[Held] = nil then
      Error := ErrorBadHandle
    else
    begin
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
    if (Result >= 0) and TookAbandonedMutex(@Events[0], LongInt(Count), Result,
      (Flags and WaitForAll) <> 0) then
      Result := Result + WaitAbandoned;
  end
  else
    Result := Failure(Error);
  for Index := 0 to Held - 1 do
    DereferenceObject(Bodies[Index]);
end;

end.
