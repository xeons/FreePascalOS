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
  System calls for event descriptors (260-269): event counters
  (Objects.EventCounters), timer descriptors (Objects.TimerDescriptors),
  signal descriptors (Processes.SignalDescriptors), event polls
  (Processes.EventPolls) and watch groups (FileSystem.WatchGroups), and
  what CallRead, CallWrite and CallControlHandle do with their handles
  (Processes.FileCalls hands them here).

  Every one of them is ready for CallWaitForHandles like the other
  objects (Processes.WaitCalls) and can go into an event poll.
}
unit Processes.EventDescriptorCalls;

{$mode objfpc}

interface

uses
  Processes.Handles;

{ Once, before the first system call. }
procedure InitializeEventDescriptorCalls;

function PerformCreateEventCounter(InitialValue, Flags: QWord): Int64;
function PerformCreateTimerDescriptor(Clock, Flags: QWord): Int64;
function PerformSetTimerDescriptor(Handle: Int64; Flags, NewAddress, OldAddress: QWord): Int64;
function PerformQueryHandleReadiness(Handle: Int64): Int64;
function PerformSetSignalDescriptor(Handle: Int64; Mask, Flags: QWord): Int64;
function PerformCreateEventPoll(Flags: QWord): Int64;
function PerformControlEventPoll(PollHandle: Int64; Operation: QWord; Handle: Int64; EventAddress: QWord): Int64;
function PerformWaitEventPoll(PollHandle: Int64; EventsAddress, Capacity: QWord; Timeout: Int64): Int64;
function PerformCreateWatchGroup(Flags: QWord): Int64;
function PerformChangeGroupWatch(GroupHandle: Int64; Operation, PathOrDescriptor, Mask: QWord): Int64;

{ Whether Kind is one of the event descriptor kinds. }
function IsEventDescriptorKind(Kind: THandleKind): Boolean;
{ CallRead and CallWrite on one (BufferAddress checked by the caller). }
function ReadEventDescriptor(Kind: THandleKind; ObjectBody: Pointer; BufferAddress, ByteCount: QWord): Int64;
function WriteEventDescriptor(Kind: THandleKind; ObjectBody: Pointer; BufferAddress, ByteCount: QWord): Int64;
{ CallControlHandle on one. }
function ControlEventDescriptor(Kind: THandleKind; ObjectBody: Pointer; Request, Argument: QWord): Int64;
{ Before a wait on its readiness event: brings it up to date. }
procedure PrepareEventDescriptorWait(Kind: THandleKind; ObjectBody: Pointer);

implementation

uses
  Runtime.Memory,
  Abi.SystemCalls,
  Memory.KernelHeap,
  Kernel.Mutex,
  Kernel.Threads,
  Kernel.Scheduler,
  Objects.Manager,
  Objects.EventCounters,
  Objects.TimerDescriptors,
  FileSystem.Types,
  FileSystem.Files,
  FileSystem.WatchGroups,
  Processes.Process,
  Processes.Thread,
  Processes.UserAccess,
  Processes.Paths,
  Processes.ObjectCalls,
  Processes.WatchCalls,
  Processes.HandleReadiness,
  Processes.SignalDescriptors,
  Processes.EventPolls;

const
  { Watch group records are read through a kernel buffer of this size at
    most (a record with the longest name fits). }
  GroupReadBufferSize = 8192;

type
  TPathBuffer = array[0..ProcessPathCapacity - 1] of Char;

function Failure(Error: LongInt): Int64;
begin
  Result := -Int64(Error);
end;

procedure InitializeEventDescriptorCalls;
begin
  InitializeEventCounters;
  InitializeTimerDescriptors;
  InitializeSignalDescriptors;
  InitializeEventPolls;
  InitializeWatchGroups;
end;

{ A handle of the current process to a new object, whose creation
  reference is given up (the handle has its own). }
function HandleForNew(Kind: THandleKind; ObjectBody: Pointer): Int64;
var
  Process: PProcess;
begin
  if ObjectBody = nil then
    Exit(Failure(ErrorOutOfMemory));
  Process := CurrentProcess;
  AcquireMutex(Process^.Lock);
  Result := InsertHandle(Process^.Handles, Kind, ObjectBody, 0);
  ReleaseMutex(Process^.Lock);
  DereferenceObject(ObjectBody);
  if Result < 0 then
    Result := Failure(ErrorTooManyHandles);
end;

function NonBlockingOf(Flags: QWord): Boolean;
begin
  Result := (Flags and EventDescriptorNonBlocking) <> 0;
end;

{ --- Event counters ------------------------------------------------------- }

function PerformCreateEventCounter(InitialValue, Flags: QWord): Int64;
begin
  if (Flags and not QWord(EventCounterSemaphore or EventDescriptorNonBlocking)) <> 0 then
    Exit(Failure(ErrorInvalidArgument));
  Result := HandleForNew(Processes.Handles.HandleKindEventCounter,
    CreateEventCounter(InitialValue, (Flags and EventCounterSemaphore) <> 0, NonBlockingOf(Flags)));
end;

function ReadCounter(Counter: PEventCounter; BufferAddress, ByteCount: QWord): Int64;
var
  Value: QWord;
  Error: LongInt;
begin
  if ByteCount < SizeOf(QWord) then
    Exit(Failure(ErrorInvalidArgument));
  Error := ReadEventCounter(Counter, Value);
  if Error = ErrorNone then
    Error := CopyToUser(BufferAddress, @Value, SizeOf(Value));
  if Error <> ErrorNone then
    Exit(Failure(Error));
  Result := SizeOf(QWord);
end;

function WriteCounter(Counter: PEventCounter; BufferAddress, ByteCount: QWord): Int64;
var
  Value: QWord;
  Error: LongInt;
begin
  if ByteCount < SizeOf(QWord) then
    Exit(Failure(ErrorInvalidArgument));
  Error := CopyFromUser(@Value, BufferAddress, SizeOf(Value));
  if Error = ErrorNone then
    Error := WriteEventCounter(Counter, Value);
  if Error <> ErrorNone then
    Exit(Failure(Error));
  Result := SizeOf(QWord);
end;

{ --- Timer descriptors ------------------------------------------------------ }

function PerformCreateTimerDescriptor(Clock, Flags: QWord): Int64;
begin
  if not TimerClockIsValid(Clock) or ((Flags and not QWord(EventDescriptorNonBlocking)) <> 0) then
    Exit(Failure(ErrorInvalidArgument));
  Result := HandleForNew(Processes.Handles.HandleKindTimerDescriptor, CreateTimerDescriptor(LongWord(Clock), NonBlockingOf(Flags)));
end;

function PerformSetTimerDescriptor(Handle: Int64; Flags, NewAddress, OldAddress: QWord): Int64;
var
  Timer: PTimerDescriptor;
  Setting: TAbiTimerSpecification;
  Previous: TAbiTimerSpecification;
  Error: LongInt;
begin
  Timer := PTimerDescriptor(ReferenceHandleOfKind(Handle, Processes.Handles.HandleKindTimerDescriptor));
  if Timer = nil then
    Exit(Failure(ErrorBadHandle));
  Error := ErrorNone;
  if NewAddress <> 0 then
    Error := CopyFromUser(@Setting, NewAddress, SizeOf(Setting));
  if (Error = ErrorNone) and (OldAddress <> 0) and not UserRangeIsValid(OldAddress, SizeOf(Previous), True) then
    Error := ErrorBadAddress;
  if Error = ErrorNone then
  begin
    GetTimerDescriptor(Timer, Previous);
    if NewAddress <> 0 then
      Error := SetTimerDescriptor(Timer, Flags, Setting);
  end;
  if (Error = ErrorNone) and (OldAddress <> 0) then
    Error := CopyToUser(OldAddress, @Previous, SizeOf(Previous));
  DereferenceObject(Timer);
  if Error <> ErrorNone then
    Exit(Failure(Error));
  Result := 0;
end;

function ReadTimer(Timer: PTimerDescriptor; BufferAddress, ByteCount: QWord): Int64;
var
  Expirations: QWord;
  Error: LongInt;
begin
  if ByteCount < SizeOf(QWord) then
    Exit(Failure(ErrorInvalidArgument));
  Error := ReadTimerDescriptor(Timer, Expirations);
  if Error = ErrorNone then
    Error := CopyToUser(BufferAddress, @Expirations, SizeOf(Expirations));
  if Error <> ErrorNone then
    Exit(Failure(Error));
  Result := SizeOf(QWord);
end;

{ --- Readiness ------------------------------------------------------------- }

function PerformQueryHandleReadiness(Handle: Int64): Int64;
var
  Kind: THandleKind;
  ObjectBody: Pointer;
begin
  ObjectBody := ReferenceHandle(Handle, Kind);
  if ObjectBody = nil then
    Exit(Failure(ErrorBadHandle));
  Result := HandleReadiness(Kind, ObjectBody);
  DereferenceObject(ObjectBody);
end;

{ --- Signal descriptors ---------------------------------------------------- }

function PerformSetSignalDescriptor(Handle: Int64; Mask, Flags: QWord): Int64;
var
  Descriptor: PSignalDescriptor;
begin
  if (Flags and not QWord(EventDescriptorNonBlocking)) <> 0 then
    Exit(Failure(ErrorInvalidArgument));
  if Handle = -1 then
    Exit(HandleForNew(Processes.Handles.HandleKindSignalDescriptor,
      CreateSignalDescriptor(CurrentProcess, Mask, NonBlockingOf(Flags))));
  Descriptor := PSignalDescriptor(ReferenceHandleOfKind(Handle, Processes.Handles.HandleKindSignalDescriptor));
  if Descriptor = nil then
    Exit(Failure(ErrorInvalidArgument));
  SetSignalDescriptorMask(Descriptor, Mask);
  DereferenceObject(Descriptor);
  Result := Handle;
end;

function ReadSignals(Descriptor: PSignalDescriptor; BufferAddress, ByteCount: QWord): Int64;
var
  Buffer: Pointer;
  Capacity: QWord;
  Error: LongInt;
begin
  Capacity := ByteCount;
  if Capacity > 16 * SizeOf(TAbiSignalDescriptorRecord) then
    Capacity := 16 * SizeOf(TAbiSignalDescriptorRecord);
  Buffer := AllocateKernelMemory(16 * SizeOf(TAbiSignalDescriptorRecord));
  if Buffer = nil then
    Exit(Failure(ErrorOutOfMemory));
  Result := ReadSignalDescriptor(Descriptor, Buffer, Capacity);
  if Result > 0 then
  begin
    Error := CopyToUser(BufferAddress, Buffer, QWord(Result));
    if Error <> ErrorNone then
      Result := Failure(Error);
  end;
  FreeKernelMemory(Buffer);
end;

{ --- Event polls ------------------------------------------------------------ }

function PerformCreateEventPoll(Flags: QWord): Int64;
begin
  if Flags <> 0 then
    Exit(Failure(ErrorInvalidArgument));
  Result := HandleForNew(Processes.Handles.HandleKindEventPoll, CreateEventPoll);
end;

function PerformControlEventPoll(PollHandle: Int64; Operation: QWord; Handle: Int64; EventAddress: QWord): Int64;
var
  Poll: PEventPoll;
  Kind: THandleKind;
  ObjectBody: Pointer;
  Registration: TAbiPollEvent;
  Error: LongInt;
begin
  if (Operation < PollAdd) or (Operation > PollModify) then
    Exit(Failure(ErrorInvalidArgument));
  Registration.Events := 0;
  Registration.Data := 0;
  if Operation <> PollRemove then
  begin
    Error := CopyFromUser(@Registration, EventAddress, SizeOf(Registration));
    if Error <> ErrorNone then
      Exit(Failure(Error));
  end;
  Poll := PEventPoll(ReferenceHandleOfKind(PollHandle, Processes.Handles.HandleKindEventPoll));
  if Poll = nil then
    Exit(Failure(ErrorBadHandle));
  ObjectBody := ReferenceHandle(Handle, Kind);
  if ObjectBody = nil then
  begin
    DereferenceObject(Poll);
    Exit(Failure(ErrorBadHandle));
  end;
  case Operation of
    PollAdd:
      Error := EventPollAdd(Poll, Handle, Kind, ObjectBody, Registration.Events, Registration.Data, True);
    PollModify:
      Error := EventPollModify(Poll, Handle, ObjectBody, Registration.Events, Registration.Data);
  else
    Error := EventPollRemove(Poll, Handle, ObjectBody);
  end;
  DereferenceObject(ObjectBody);
  DereferenceObject(Poll);
  if Error <> ErrorNone then
    Exit(Failure(Error));
  Result := 0;
end;

function PerformWaitEventPoll(PollHandle: Int64; EventsAddress, Capacity: QWord; Timeout: Int64): Int64;
var
  Poll: PEventPoll;
  Events: PAbiPollEvent;
  TimeoutMilliseconds: QWord;
  Error: LongInt;
begin
  if (Capacity = 0) or (Capacity > High(LongInt)) then
    Exit(Failure(ErrorInvalidArgument));
  if Capacity > PollMaximumEvents then
    Capacity := PollMaximumEvents;
  { Checked first: events taken from the poll must reach the program. }
  if not UserRangeIsValid(EventsAddress, Capacity * SizeOf(TAbiPollEvent), True) then
    Exit(Failure(ErrorBadAddress));
  Poll := PEventPoll(ReferenceHandleOfKind(PollHandle, Processes.Handles.HandleKindEventPoll));
  if Poll = nil then
    Exit(Failure(ErrorBadHandle));
  Events := PAbiPollEvent(AllocateKernelMemory(Capacity * SizeOf(TAbiPollEvent)));
  if Events = nil then
  begin
    DereferenceObject(Poll);
    Exit(Failure(ErrorOutOfMemory));
  end;
  if Timeout < 0 then
    TimeoutMilliseconds := InfiniteTimeout
  else
    TimeoutMilliseconds := QWord(Timeout);
  Result := EventPollWait(Poll, Events, LongInt(Capacity), TimeoutMilliseconds);
  if Result > 0 then
  begin
    Error := CopyToUser(EventsAddress, Events, QWord(Result) * SizeOf(TAbiPollEvent));
    if Error <> ErrorNone then
      Result := Failure(Error);
  end;
  FreeKernelMemory(Events);
  DereferenceObject(Poll);
end;

{ --- Watch groups ----------------------------------------------------------- }

function PerformCreateWatchGroup(Flags: QWord): Int64;
begin
  if (Flags and not QWord(EventDescriptorNonBlocking)) <> 0 then
    Exit(Failure(ErrorInvalidArgument));
  Result := HandleForNew(Processes.Handles.HandleKindWatchGroup, CreateWatchGroup(NonBlockingOf(Flags)));
end;

function AddWatchToGroup(Group: PWatchGroup; PathAddress, Mask: QWord): Int64;
var
  UserPath: TPathBuffer;
  KernelPath: TPathBuffer;
  Descriptor: LongInt;
  Status: TFileSystemStatus;
  Error: LongInt;
begin
  if ((Mask and GroupWatchAllEvents) = 0) or (Mask > High(LongWord)) or
     ((Mask and (GroupWatchIsDirectory or GroupWatchIgnored or GroupWatchQueueOverflow or GroupWatchUnmount)) <> 0) then
    Exit(Failure(ErrorInvalidArgument));
  Error := CopyStringFromUser(PathAddress, @UserPath[0], ProcessPathCapacity);
  if Error <> ErrorNone then
    Exit(Failure(Error));
  if IsDevicePath(@UserPath[0]) then
    Exit(Failure(ErrorUnsupported));
  Error := TranslateUserPath(CurrentProcess, @UserPath[0], @KernelPath[0], ProcessPathCapacity);
  if Error <> ErrorNone then
    Exit(Failure(Error));
  Status := WatchPathForGroup(@KernelPath[0], Group, LongWord(Mask), Descriptor);
  if Status <> StatusSuccess then
    Exit(Failure(ErrorFromStatus(Status)));
  Result := Descriptor;
end;

function PerformChangeGroupWatch(GroupHandle: Int64; Operation, PathOrDescriptor, Mask: QWord): Int64;
var
  Group: PWatchGroup;
begin
  Group := PWatchGroup(ReferenceHandleOfKind(GroupHandle, Processes.Handles.HandleKindWatchGroup));
  if Group = nil then
    Exit(Failure(ErrorBadHandle));
  case Operation of
    GroupWatchAdd:
      Result := AddWatchToGroup(Group, PathOrDescriptor, Mask);
    GroupWatchRemove:
      Result := Failure(RemoveGroupWatch(Group, LongInt(PathOrDescriptor)));
  else
    Result := Failure(ErrorInvalidArgument);
  end;
  DereferenceObject(Group);
end;

function ReadGroup(Group: PWatchGroup; BufferAddress, ByteCount: QWord): Int64;
var
  Buffer: PByte;
  Capacity: QWord;
  Error: LongInt;
begin
  Capacity := ByteCount;
  if Capacity > GroupReadBufferSize then
    Capacity := GroupReadBufferSize;
  Buffer := PByte(AllocateKernelMemory(GroupReadBufferSize));
  if Buffer = nil then
    Exit(Failure(ErrorOutOfMemory));
  Result := ReadWatchGroup(Group, Buffer, Capacity);
  if Result > 0 then
  begin
    Error := CopyToUser(BufferAddress, Buffer, QWord(Result));
    if Error <> ErrorNone then
      Result := Failure(Error);
  end;
  FreeKernelMemory(Buffer);
end;

{ --- Reads, writes and control ------------------------------------------------ }

function IsEventDescriptorKind(Kind: THandleKind): Boolean;
begin
  Result := Kind in [Processes.Handles.HandleKindEventCounter, Processes.Handles.HandleKindTimerDescriptor, Processes.Handles.HandleKindSignalDescriptor,
    Processes.Handles.HandleKindEventPoll, Processes.Handles.HandleKindWatchGroup];
end;

function ReadEventDescriptor(Kind: THandleKind; ObjectBody: Pointer; BufferAddress, ByteCount: QWord): Int64;
begin
  case Kind of
    Processes.Handles.HandleKindEventCounter: Result := ReadCounter(PEventCounter(ObjectBody), BufferAddress, ByteCount);
    Processes.Handles.HandleKindTimerDescriptor: Result := ReadTimer(PTimerDescriptor(ObjectBody), BufferAddress, ByteCount);
    Processes.Handles.HandleKindSignalDescriptor: Result := ReadSignals(PSignalDescriptor(ObjectBody), BufferAddress, ByteCount);
    Processes.Handles.HandleKindWatchGroup: Result := ReadGroup(PWatchGroup(ObjectBody), BufferAddress, ByteCount);
  else
    Result := Failure(ErrorInvalidArgument);
  end;
end;

function WriteEventDescriptor(Kind: THandleKind; ObjectBody: Pointer; BufferAddress, ByteCount: QWord): Int64;
begin
  if Kind = Processes.Handles.HandleKindEventCounter then
    Result := WriteCounter(PEventCounter(ObjectBody), BufferAddress, ByteCount)
  else
    Result := Failure(ErrorInvalidArgument);
end;

function ControlEventDescriptor(Kind: THandleKind; ObjectBody: Pointer; Request, Argument: QWord): Int64;
var
  NonBlocking: Boolean;
begin
  if Request <> ControlSetNonBlocking then
    Exit(Failure(ErrorUnsupported));
  NonBlocking := Argument <> 0;
  case Kind of
    Processes.Handles.HandleKindEventCounter: PEventCounter(ObjectBody)^.NonBlocking := NonBlocking;
    Processes.Handles.HandleKindTimerDescriptor: PTimerDescriptor(ObjectBody)^.NonBlocking := NonBlocking;
    Processes.Handles.HandleKindSignalDescriptor: PSignalDescriptor(ObjectBody)^.NonBlocking := NonBlocking;
    Processes.Handles.HandleKindWatchGroup: PWatchGroup(ObjectBody)^.NonBlocking := NonBlocking;
  end;
  Result := 0;
end;

procedure PrepareEventDescriptorWait(Kind: THandleKind; ObjectBody: Pointer);
begin
  if Kind = Processes.Handles.HandleKindSignalDescriptor then
    RefreshSignalDescriptor(PSignalDescriptor(ObjectBody));
end;

end.
