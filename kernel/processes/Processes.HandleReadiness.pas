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
  What an object behind a handle is ready for, as poll says it
  (PollReadable, PollWritable, PollError, PollHangUp), and the events
  that change when that changes.

  CallQueryHandleReadiness answers with HandleReadiness, and an event
  poll (Processes.EventPolls) checks it for every object it hears of,
  having attached observers (Kernel.Events) to the object's readiness
  events (HandleReadinessEvents: at most two, one that follows reading,
  one writing). It looks at the objects' state without their locks: an
  answer may be a moment old, as poll's always is.

  A file (and a directory, and a device whose driver keeps no event)
  is always ready to read and write and has no events: an event poll
  refuses it (HandleIsAlwaysReady), as other systems do.
}
unit Processes.HandleReadiness;

{$mode objfpc}

interface

uses
  Kernel.Events,
  Processes.Handles;

const
  MaximumReadinessEvents = 2;

type
  TReadinessEvents = array[0..MaximumReadinessEvents - 1] of PEvent;

function HandleReadiness(Kind: THandleKind; ObjectBody: Pointer): LongWord;
{ The events whose signals may make the object ready; returns how many. }
function HandleReadinessEvents(Kind: THandleKind; ObjectBody: Pointer; out Events: TReadinessEvents): LongInt;
function HandleIsAlwaysReady(Kind: THandleKind; ObjectBody: Pointer): Boolean;

implementation

uses
  Abi.SystemCalls,
  Io.Manager,
  Io.Pipes,
  Network.Sockets,
  FileSystem.Watches,
  FileSystem.WatchGroups,
  Objects.Events,
  Objects.Timers,
  Objects.Semaphores,
  Objects.Mutexes,
  Objects.EventCounters,
  Objects.TimerDescriptors,
  Processes.Process,
  Processes.Thread,
  Processes.Channels,
  Processes.SignalDescriptors,
  Processes.EventPolls,
  Processes.LocalSockets;

const
  ReadyBoth = PollReadable or PollWritable;

{ A device's events: what follows reading (if opened for it) and
  writing (if opened for it); nil where its driver keeps none. }
procedure DeviceEvents(OpenFile: PDeviceFile; out ForReading, ForWriting: PEvent);
begin
  ForReading := nil;
  ForWriting := nil;
  if OpenFile^.IsDirectory or (OpenFile^.Device = nil) then
    Exit;
  if (OpenFile^.OpenFlags and OpenRead) <> 0 then
    ForReading := PEvent(OpenFile^.Device^.ReadyEvent);
  if (OpenFile^.OpenFlags and OpenWrite) <> 0 then
    ForWriting := PEvent(OpenFile^.Device^.WritableEvent);
end;

function DeviceReadiness(OpenFile: PDeviceFile): LongWord;
var
  ForReading: PEvent;
  ForWriting: PEvent;
begin
  if OpenFile^.IsDirectory or (OpenFile^.Device = nil) then
    Exit(ReadyBoth);
  DeviceEvents(OpenFile, ForReading, ForWriting);
  Result := 0;
  if ((OpenFile^.OpenFlags and OpenRead) <> 0) and ((ForReading = nil) or ForReading^.IsSignaled) then
    Result := Result or PollReadable;
  if ((OpenFile^.OpenFlags and OpenWrite) <> 0) and ((ForWriting = nil) or ForWriting^.IsSignaled) then
    Result := Result or PollWritable;
end;

function PipeReadEndReadiness(Pipe: PPipe): LongWord;
begin
  Result := 0;
  if Pipe^.Readable.IsSignaled then
    Result := PollReadable;
  if Pipe^.OpenWriteEnds <= 0 then
    Result := Result or PollHangUp;
end;

function PipeWriteEndReadiness(Pipe: PPipe): LongWord;
begin
  Result := 0;
  if Pipe^.Writable.IsSignaled then
    Result := PollWritable;
  if Pipe^.OpenReadEnds <= 0 then
    Result := Result or PollError;
end;

function SocketReadiness(Socket: PSocket): LongWord;
begin
  Result := 0;
  if Socket^.Readable.IsSignaled then
    Result := PollReadable;
  if Socket^.Writable.IsSignaled then
    Result := Result or PollWritable;
  if Socket^.PendingError <> ErrorNone then
    Result := Result or PollError;
  if Socket^.ReceiveIsShut then
    Result := Result or PollReadHangUp;
  if Socket^.ReceiveIsShut and Socket^.SendIsShut then
    Result := Result or PollHangUp;
end;

{ An object with one event that says it is ready to read. }
function ReadableWhen(Event: PEvent): LongWord;
begin
  Result := 0;
  if Event^.IsSignaled then
    Result := PollReadable;
end;

function HandleReadiness(Kind: THandleKind; ObjectBody: Pointer): LongWord;
begin
  case Kind of
    Processes.Handles.HandleKindFile: Result := ReadyBoth;
    Processes.Handles.HandleKindDevice: Result := DeviceReadiness(PDeviceFile(ObjectBody));
    Processes.Handles.HandleKindPipeReadEnd: Result := PipeReadEndReadiness(PPipe(ObjectBody));
    Processes.Handles.HandleKindPipeWriteEnd: Result := PipeWriteEndReadiness(PPipe(ObjectBody));
    Processes.Handles.HandleKindSocket: Result := SocketReadiness(PSocket(ObjectBody));
    Processes.Handles.HandleKindLocalSocket: Result := LocalSocketReadiness(PLocalSocket(ObjectBody));
    Processes.Handles.HandleKindEventCounter: Result := EventCounterReadiness(PEventCounter(ObjectBody));
    Processes.Handles.HandleKindTimerDescriptor: Result := TimerDescriptorReadiness(PTimerDescriptor(ObjectBody));
    Processes.Handles.HandleKindSignalDescriptor: Result := SignalDescriptorReadiness(PSignalDescriptor(ObjectBody));
    Processes.Handles.HandleKindEventPoll: Result := EventPollReadiness(PEventPoll(ObjectBody));
    Processes.Handles.HandleKindWatchGroup: Result := WatchGroupReadiness(PWatchGroup(ObjectBody));
    Processes.Handles.HandleKindEvent: Result := ReadableWhen(@PEventObject(ObjectBody)^.Event);
    Processes.Handles.HandleKindTimer: Result := ReadableWhen(@PTimerObject(ObjectBody)^.Event);
    Processes.Handles.HandleKindSemaphore: Result := ReadableWhen(@PSemaphoreObject(ObjectBody)^.Semaphore.Event);
    Processes.Handles.HandleKindMutex: Result := ReadableWhen(@PMutexObject(ObjectBody)^.Event);
    Processes.Handles.HandleKindProcess: Result := ReadableWhen(@PProcess(ObjectBody)^.ExitEvent);
    Processes.Handles.HandleKindThread: Result := ReadableWhen(@PThread(ObjectBody)^.ExitEvent);
    Processes.Handles.HandleKindChannel: Result := ReadableWhen(@PChannelEnd(ObjectBody)^.Readable);
    Processes.Handles.HandleKindPort: Result := ReadableWhen(@PPort(ObjectBody)^.Pending);
    Processes.Handles.HandleKindWatch: Result := ReadableWhen(@PWatch(ObjectBody)^.Ready);
  else
    Result := 0;
  end;
end;

{ Adds Event (if not nil) to Events. }
procedure AddEvent(var Events: TReadinessEvents; var Count: LongInt; Event: PEvent);
begin
  if (Event = nil) or (Count >= MaximumReadinessEvents) then
    Exit;
  Events[Count] := Event;
  Inc(Count);
end;

function HandleReadinessEvents(Kind: THandleKind; ObjectBody: Pointer; out Events: TReadinessEvents): LongInt;
var
  Count: LongInt;
  ForReading: PEvent;
  ForWriting: PEvent;
begin
  Events[0] := nil;
  Events[1] := nil;
  Count := 0;
  case Kind of
    Processes.Handles.HandleKindDevice:
      begin
        DeviceEvents(PDeviceFile(ObjectBody), ForReading, ForWriting);
        AddEvent(Events, Count, ForReading);
        if ForWriting <> ForReading then
          AddEvent(Events, Count, ForWriting);
      end;
    Processes.Handles.HandleKindPipeReadEnd: AddEvent(Events, Count, @PPipe(ObjectBody)^.Readable);
    Processes.Handles.HandleKindPipeWriteEnd: AddEvent(Events, Count, @PPipe(ObjectBody)^.Writable);
    Processes.Handles.HandleKindSocket:
      begin
        AddEvent(Events, Count, @PSocket(ObjectBody)^.Readable);
        AddEvent(Events, Count, @PSocket(ObjectBody)^.Writable);
      end;
    Processes.Handles.HandleKindLocalSocket:
      begin
        AddEvent(Events, Count, @PLocalSocket(ObjectBody)^.Readable);
        AddEvent(Events, Count, @PLocalSocket(ObjectBody)^.Writable);
      end;
    Processes.Handles.HandleKindEventCounter:
      begin
        AddEvent(Events, Count, @PEventCounter(ObjectBody)^.Readable);
        AddEvent(Events, Count, @PEventCounter(ObjectBody)^.Writable);
      end;
    Processes.Handles.HandleKindTimerDescriptor: AddEvent(Events, Count, @PTimerDescriptor(ObjectBody)^.Ready);
    Processes.Handles.HandleKindSignalDescriptor: AddEvent(Events, Count, @PSignalDescriptor(ObjectBody)^.Ready);
    Processes.Handles.HandleKindEventPoll: AddEvent(Events, Count, @PEventPoll(ObjectBody)^.Ready);
    Processes.Handles.HandleKindWatchGroup: AddEvent(Events, Count, @PWatchGroup(ObjectBody)^.Ready);
    Processes.Handles.HandleKindEvent: AddEvent(Events, Count, @PEventObject(ObjectBody)^.Event);
    Processes.Handles.HandleKindTimer: AddEvent(Events, Count, @PTimerObject(ObjectBody)^.Event);
    Processes.Handles.HandleKindSemaphore: AddEvent(Events, Count, @PSemaphoreObject(ObjectBody)^.Semaphore.Event);
    Processes.Handles.HandleKindMutex: AddEvent(Events, Count, @PMutexObject(ObjectBody)^.Event);
    Processes.Handles.HandleKindProcess: AddEvent(Events, Count, @PProcess(ObjectBody)^.ExitEvent);
    Processes.Handles.HandleKindThread: AddEvent(Events, Count, @PThread(ObjectBody)^.ExitEvent);
    Processes.Handles.HandleKindChannel: AddEvent(Events, Count, @PChannelEnd(ObjectBody)^.Readable);
    Processes.Handles.HandleKindPort: AddEvent(Events, Count, @PPort(ObjectBody)^.Pending);
    Processes.Handles.HandleKindWatch: AddEvent(Events, Count, @PWatch(ObjectBody)^.Ready);
  end;
  Result := Count;
end;

function HandleIsAlwaysReady(Kind: THandleKind; ObjectBody: Pointer): Boolean;
var
  Events: TReadinessEvents;
begin
  Result := (Kind = Processes.Handles.HandleKindFile) or (HandleReadinessEvents(Kind, ObjectBody, Events) = 0);
end;

end.
