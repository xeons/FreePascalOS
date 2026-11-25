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
  System calls for the objects programs work together with: events,
  semaphores, mutexes, timers, sections, ports and channels (Objects.Events,
  Objects.Semaphores, Objects.Mutexes, Objects.Timers, Objects.Sections,
  Processes.Channels). Waiting for them is in
  Processes.WaitCalls; mapping a section in Processes.MappingCalls.
}
unit Processes.ObjectCalls;

{$mode objfpc}
{$pointermath on}

interface

uses
  Processes.Handles;

function PerformCreateEvent(Flags: QWord): Int64;
function PerformSetEvent(Handle: Int64; Signal: Boolean): Int64;
function PerformCreateSemaphore(InitialCount, Limit: Int64): Int64;
function PerformReleaseSemaphore(Handle: Int64; ReleaseCount: Int64): Int64;
function PerformGetSemaphoreCount(Handle: Int64): Int64;
function PerformCreateMutex(Flags: QWord): Int64;
function PerformReleaseMutex(Handle: Int64): Int64;
function PerformCreateTimer(Flags: QWord): Int64;
function PerformSetTimer(Handle: Int64; DueMilliseconds, PeriodMilliseconds: QWord): Int64;
function PerformCreateSection(Length: QWord): Int64;
function PerformCreatePort(NameAddress: QWord): Int64;
function PerformConnectPort(NameAddress: QWord): Int64;
function PerformAcceptConnection(PortHandle: Int64): Int64;
function PerformCreateChannel(HandlesAddress: QWord): Int64;
function PerformSendMessage(Channel: Int64; MessageAddress: QWord): Int64;
function PerformReceiveMessage(Channel: Int64; MessageAddress: QWord): Int64;
function PerformGetChannelPeer(Channel: Int64; PeerAddress: QWord): Int64;

{ The object behind Handle of the current process, referenced, and its
  kind; nil if the handle is not open. }
function ReferenceHandle(Handle: Int64; out Kind: THandleKind): Pointer;
{ The same if it is of Kind; nil if not. }
function ReferenceHandleOfKind(Handle: Int64; Kind: THandleKind): Pointer;

implementation

uses
  Abi.SystemCalls,
  Kernel.Events,
  Kernel.Mutex,
  Objects.Manager,
  Objects.Events,
  Objects.Semaphores,
  Kernel.Semaphores,
  Objects.Mutexes,
  Kernel.MutexEvents,
  Objects.Timers,
  Objects.Sections,
  Processes.Process,
  Processes.Thread,
  Processes.UserAccess,
  Processes.Channels,
  Processes.Restrictions,
  Runtime.Atomic,
  Memory.Layout,
  Memory.CommitCharge,
  Processes.AddressSpace;

function Failure(Error: LongInt): Int64;
begin
  Result := -Int64(Error);
end;

function ReferenceHandle(Handle: Int64; out Kind: THandleKind): Pointer;
var
  Process: PProcess;
begin
  Process := CurrentProcess;
  AcquireMutex(Process^.Lock);
  if not LookupHandle(Process^.Handles, Handle, Kind, Result) then
    Result := nil
  else
    ReferenceObject(Result);
  ReleaseMutex(Process^.Lock);
end;

function ReferenceHandleOfKind(Handle: Int64; Kind: THandleKind): Pointer;
var
  Found: THandleKind;
begin
  Result := ReferenceHandle(Handle, Found);
  if (Result <> nil) and (Found <> Kind) then
  begin
    DereferenceObject(Result);
    Result := nil;
  end;
end;

{ A handle of the current process to ObjectBody, whose creation
  reference is given up (the handle has its own). }
function HandleForNewObject(Kind: THandleKind; ObjectBody: Pointer): Int64;
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

{ --- Events and timers ------------------------------------------------------ }

function PerformCreateEvent(Flags: QWord): Int64;
begin
  Result := HandleForNewObject(Processes.Handles.HandleKindEvent,
    CreateEventObject((Flags and EventManualReset) <> 0, (Flags and EventSignaled) <> 0));
end;

function PerformSetEvent(Handle: Int64; Signal: Boolean): Int64;
var
  EventObject: PEventObject;
begin
  EventObject := PEventObject(ReferenceHandleOfKind(Handle, Processes.Handles.HandleKindEvent));
  if EventObject = nil then
    Exit(Failure(ErrorBadHandle));
  if Signal then
    SignalEvent(EventObject^.Event)
  else
    ResetEvent(EventObject^.Event);
  DereferenceObject(EventObject);
  Result := 0;
end;

{ --- Semaphores -------------------------------------------------------------- }

function PerformCreateSemaphore(InitialCount, Limit: Int64): Int64;
begin
  if (Limit < 1) or (Limit > MaximumSemaphoreLimit) or (InitialCount < 0) or (InitialCount > Limit) then
    Exit(Failure(ErrorInvalidArgument));
  Result := HandleForNewObject(Processes.Handles.HandleKindSemaphore,
    CreateSemaphoreObject(LongInt(InitialCount), LongInt(Limit)));
end;

function PerformReleaseSemaphore(Handle: Int64; ReleaseCount: Int64): Int64;
var
  SemaphoreObject: PSemaphoreObject;
  PreviousCount: LongInt;
begin
  if (ReleaseCount < 1) or (ReleaseCount > MaximumSemaphoreLimit) then
    Exit(Failure(ErrorInvalidArgument));
  SemaphoreObject := PSemaphoreObject(ReferenceHandleOfKind(Handle, Processes.Handles.HandleKindSemaphore));
  if SemaphoreObject = nil then
    Exit(Failure(ErrorBadHandle));
  if ReleaseSemaphore(SemaphoreObject^.Semaphore, LongInt(ReleaseCount), PreviousCount) then
    Result := PreviousCount
  else
    Result := Failure(ErrorOverflow);
  DereferenceObject(SemaphoreObject);
end;

function PerformGetSemaphoreCount(Handle: Int64): Int64;
var
  SemaphoreObject: PSemaphoreObject;
begin
  SemaphoreObject := PSemaphoreObject(ReferenceHandleOfKind(Handle, Processes.Handles.HandleKindSemaphore));
  if SemaphoreObject = nil then
    Exit(Failure(ErrorBadHandle));
  Result := SemaphoreCount(SemaphoreObject^.Semaphore);
  DereferenceObject(SemaphoreObject);
end;

{ --- Mutexes ----------------------------------------------------------------- }

function PerformCreateMutex(Flags: QWord): Int64;
begin
  if (Flags and not QWord(MutexInitiallyOwned)) <> 0 then
    Exit(Failure(ErrorInvalidArgument));
  Result := HandleForNewObject(Processes.Handles.HandleKindMutex,
    CreateMutexObject((Flags and MutexInitiallyOwned) <> 0));
end;

function PerformReleaseMutex(Handle: Int64): Int64;
var
  MutexObject: PMutexObject;
  RemainingHolds: LongInt;
begin
  MutexObject := PMutexObject(ReferenceHandleOfKind(Handle, Processes.Handles.HandleKindMutex));
  if MutexObject = nil then
    Exit(Failure(ErrorBadHandle));
  if ReleaseMutexEvent(MutexObject^.Event, RemainingHolds) then
    Result := RemainingHolds
  else
    Result := Failure(ErrorNotPermitted);
  DereferenceObject(MutexObject);
end;

{ --- Timers ------------------------------------------------------------------ }

function PerformCreateTimer(Flags: QWord): Int64;
begin
  Result := HandleForNewObject(Processes.Handles.HandleKindTimer, CreateTimerObject((Flags and TimerManualReset) <> 0));
end;

function PerformSetTimer(Handle: Int64; DueMilliseconds, PeriodMilliseconds: QWord): Int64;
var
  Timer: PTimerObject;
begin
  Timer := PTimerObject(ReferenceHandleOfKind(Handle, Processes.Handles.HandleKindTimer));
  if Timer = nil then
    Exit(Failure(ErrorBadHandle));
  SetTimerObject(Timer, DueMilliseconds, PeriodMilliseconds);
  DereferenceObject(Timer);
  Result := 0;
end;

{ --- Sections ------------------------------------------------------------------ }

{ Gives back what a section charged to the process Holder. }
procedure ReleaseSectionCharge(Holder: Pointer; Pages: QWord);
var
  Process: PProcess;
begin
  Process := PProcess(Holder);
  AtomicFetchAndAdd(Process^.SectionChargePages, -Int64(Pages));
  ChangeSystemCommitCharge(-Int64(Pages));
  DereferenceObject(Process);
end;

{ Charges Pages of a new section to the calling process: refused over
  its commit limit (what its space has charged and its sections
  together). }
function ChargeSection(Process: PProcess; Pages: QWord): LongInt;
var
  Usage: TAddressSpaceUsage;
begin
  GetAddressSpaceUsage(Process^.AddressSpace, Usage);
  if (Usage.CommitLimitPages <> 0) and
     (Usage.CommitChargePages + QWord(Process^.SectionChargePages) + Pages > Usage.CommitLimitPages) then
    Exit(ErrorOutOfMemory);
  AtomicFetchAndAdd(Process^.SectionChargePages, Int64(Pages));
  ChangeSystemCommitCharge(Int64(Pages));
  ReferenceObject(Process);
  Result := ErrorNone;
end;

function PerformCreateSection(Length: QWord): Int64;
var
  Process: PProcess;
  Pages: QWord;
  Section: PSectionObject;
  Error: LongInt;
begin
  if (Length = 0) or (Length > MaximumSectionBytes) then
    Exit(Failure(ErrorInvalidArgument));
  Process := CurrentProcess;
  Pages := RoundUpToPage(Length) shr PageShift;
  Error := ChargeSection(Process, Pages);
  if Error <> ErrorNone then
    Exit(Failure(Error));
  Section := CreateSectionObject(Length);
  if Section = nil then
  begin
    ReleaseSectionCharge(Process, Pages);
    Exit(Failure(ErrorOutOfMemory));
  end;
  Section^.ChargeHolder := Process;
  Section^.ReleaseCharge := @ReleaseSectionCharge;
  Result := HandleForNewObject(Processes.Handles.HandleKindSection, Section);
end;

{ --- Ports and channels -------------------------------------------------------- }

procedure DescribeCaller(out Holder: TAbiChannelPeer); forward;

function FetchPortName(NameAddress: QWord; Name: PChar): LongInt;
begin
  Result := CopyStringFromUser(NameAddress, Name, MaximumPortNameLength + 1);
end;

function PerformCreatePort(NameAddress: QWord): Int64;
var
  Name: array[0..MaximumPortNameLength] of Char;
  Port: PPort;
  Error: LongInt;
  Holder: TAbiChannelPeer;
begin
  if CallerRestricted(RestrictPortConnections) then
    Exit(Failure(ErrorAccessDenied));
  Error := FetchPortName(NameAddress, @Name[0]);
  DescribeCaller(Holder);
  if Error = ErrorNone then
    Error := CreatePort(@Name[0], Holder.UserId, Holder.GroupId, Port);
  if Error <> ErrorNone then
    Exit(Failure(Error));
  Result := HandleForNewObject(Processes.Handles.HandleKindPort, Port);
end;

{ The calling process, as the holder of a channel's end. }
procedure DescribeCaller(out Holder: TAbiChannelPeer);
var
  Process: PProcess;
begin
  Process := CurrentProcess;
  Holder.ProcessId := Process^.ProcessId;
  AcquireMutex(Process^.Lock);
  Holder.UserId := Process^.Credentials.EffectiveUserId;
  Holder.GroupId := Process^.Credentials.EffectiveGroupId;
  ReleaseMutex(Process^.Lock);
end;

function PerformConnectPort(NameAddress: QWord): Int64;
var
  Holder: TAbiChannelPeer;
  Name: array[0..MaximumPortNameLength] of Char;
  Channel: PChannelEnd;
  Error: LongInt;
begin
  if CallerRestricted(RestrictPortConnections) then
    Exit(Failure(ErrorAccessDenied));
  Error := FetchPortName(NameAddress, @Name[0]);
  DescribeCaller(Holder);
  if Error = ErrorNone then
    Error := ConnectToPort(@Name[0], Holder, Channel);
  if Error <> ErrorNone then
    Exit(Failure(Error));
  Result := HandleForNewObject(Processes.Handles.HandleKindChannel, Channel);
end;

function PerformAcceptConnection(PortHandle: Int64): Int64;
var
  Holder: TAbiChannelPeer;
  Port: PPort;
  Channel: PChannelEnd;
  Error: LongInt;
begin
  Port := PPort(ReferenceHandleOfKind(PortHandle, Processes.Handles.HandleKindPort));
  if Port = nil then
    Exit(Failure(ErrorBadHandle));
  DescribeCaller(Holder);
  Error := AcceptConnection(Port, Holder, Channel);
  DereferenceObject(Port);
  if Error <> ErrorNone then
    Exit(Failure(Error));
  Result := HandleForNewObject(Processes.Handles.HandleKindChannel, Channel);
end;

function PerformCreateChannel(HandlesAddress: QWord): Int64;
var
  First: PChannelEnd;
  Second: PChannelEnd;
  Handles: array[0..1] of Int64;
  Error: LongInt;
  Process: PProcess;
  Holder: TAbiChannelPeer;
begin
  if not UserRangeIsValid(HandlesAddress, SizeOf(Handles), True) then
    Exit(Failure(ErrorBadAddress));
  Error := CreateChannel(First, Second);
  if Error <> ErrorNone then
    Exit(Failure(Error));
  DescribeCaller(Holder);
  SetChannelPeer(First, Holder);
  SetChannelPeer(Second, Holder);
  Handles[0] := HandleForNewObject(Processes.Handles.HandleKindChannel, First);
  Handles[1] := HandleForNewObject(Processes.Handles.HandleKindChannel, Second);
  if (Handles[0] < 0) or (Handles[1] < 0) then
  begin
    Process := CurrentProcess;
    AcquireMutex(Process^.Lock);
    if Handles[0] >= 0 then
      CloseHandle(Process^.Handles, Handles[0]);
    if Handles[1] >= 0 then
      CloseHandle(Process^.Handles, Handles[1]);
    ReleaseMutex(Process^.Lock);
    Exit(Failure(ErrorTooManyHandles));
  end;
  Result := -Int64(CopyToUser(HandlesAddress, @Handles[0], SizeOf(Handles)));
end;

function PerformSendMessage(Channel: Int64; MessageAddress: QWord): Int64;
var
  Description: TAbiMessage;
  ChannelEnd: PChannelEnd;
  Message: PChannelMessage;
  Handles: array[0..MaximumMessageHandles - 1] of Int64;
  Taken: LongWord;
  Index: LongWord;
  Error: LongInt;
  Body: Pointer;
begin
  Error := CopyFromUser(@Description, MessageAddress, SizeOf(Description));
  if Error <> ErrorNone then
    Exit(Failure(Error));
  if (Description.Length > MaximumMessageBytes) or (Description.HandleCount > MaximumMessageHandles) then
    Exit(Failure(ErrorMessageTooLong));
  if Description.HandleCount > 0 then
  begin
    Error := CopyFromUser(@Handles[0], Description.Handles, Description.HandleCount * SizeOf(Int64));
    if Error <> ErrorNone then
      Exit(Failure(Error));
  end;
  ChannelEnd := PChannelEnd(ReferenceHandleOfKind(Channel, Processes.Handles.HandleKindChannel));
  if ChannelEnd = nil then
    Exit(Failure(ErrorBadHandle));
  Message := NewMessage(LongWord(Description.Length), LongWord(Description.HandleCount));
  Error := ErrorOutOfMemory;
  Taken := 0;
  if Message <> nil then
  begin
    Error := CopyFromUser(@Message^.Data[0], Description.Data, Description.Length);
    { Each handle travels as a reference of its own. }
    while (Error = ErrorNone) and (Taken < Message^.HandleCount) do
    begin
      Body := ReferenceHandle(Handles[Taken], Message^.Kinds[Taken]);
      if Body = nil then
        Error := ErrorBadHandle
      { A thread handle stands for a thread of the sender: it means
        nothing to another process (as for fork and passed handles). }
      else if Message^.Kinds[Taken] = Processes.Handles.HandleKindThread then
      begin
        DereferenceObject(Body);
        Error := ErrorInvalidArgument;
      end
      else
      begin
        TakeHandleReference(Message^.Kinds[Taken], Body);
        DereferenceObject(Body);
        Message^.Bodies[Taken] := Body;
        Inc(Taken);
      end;
    end;
    if Error = ErrorNone then
      Error := SendMessage(ChannelEnd, Message);
    if Error <> ErrorNone then
    begin
      for Index := 1 to Taken do
        DropHandleReference(Message^.Kinds[Index - 1], Message^.Bodies[Index - 1]);
      FreeMessage(Message);
    end;
  end;
  DereferenceObject(ChannelEnd);
  if Error <> ErrorNone then
    Exit(Failure(Error));
  Result := 0;
end;

function PerformReceiveMessage(Channel: Int64; MessageAddress: QWord): Int64;
var
  Description: TAbiMessage;
  ChannelEnd: PChannelEnd;
  Message: PChannelMessage;
  Handles: array[0..MaximumMessageHandles - 1] of Int64;
  Needed: LongWord;
  NeededHandles: LongWord;
  Index: LongWord;
  Error: LongInt;
  Process: PProcess;
begin
  Error := CopyFromUser(@Description, MessageAddress, SizeOf(Description));
  if Error <> ErrorNone then
    Exit(Failure(Error));
  if not UserRangeIsValid(Description.Data, Description.Length, True) or
     not UserRangeIsValid(Description.Handles, Description.HandleCount * SizeOf(Int64), True) then
    Exit(Failure(ErrorBadAddress));
  ChannelEnd := PChannelEnd(ReferenceHandleOfKind(Channel, Processes.Handles.HandleKindChannel));
  if ChannelEnd = nil then
    Exit(Failure(ErrorBadHandle));
  if Description.Length > MaximumMessageBytes then
    Description.Length := MaximumMessageBytes;
  if Description.HandleCount > MaximumMessageHandles then
    Description.HandleCount := MaximumMessageHandles;
  Error := ReceiveMessage(ChannelEnd, LongWord(Description.Length), LongWord(Description.HandleCount), Message,
    Needed, NeededHandles);
  DereferenceObject(ChannelEnd);
  if Error = ErrorMessageTooLong then
  begin
    Description.Length := Needed;
    Description.HandleCount := NeededHandles;
    CopyToUser(MessageAddress, @Description, SizeOf(Description));
  end;
  if Error <> ErrorNone then
    Exit(Failure(Error));
  { The message's handles become handles of the receiver; any that do
    not fit in its table are given back (and stand as -1). }
  Process := CurrentProcess;
  AcquireMutex(Process^.Lock);
  for Index := 1 to Message^.HandleCount do
    Handles[Index - 1] := InsertHandle(Process^.Handles, Message^.Kinds[Index - 1], Message^.Bodies[Index - 1], 0);
  ReleaseMutex(Process^.Lock);
  for Index := 1 to Message^.HandleCount do
    DropHandleReference(Message^.Kinds[Index - 1], Message^.Bodies[Index - 1]);
  Error := CopyToUser(Description.Data, @Message^.Data[0], Message^.Length);
  if (Error = ErrorNone) and (Message^.HandleCount > 0) then
    Error := CopyToUser(Description.Handles, @Handles[0], Message^.HandleCount * SizeOf(Int64));
  Description.Length := Message^.Length;
  Description.HandleCount := Message^.HandleCount;
  if Error = ErrorNone then
    Error := CopyToUser(MessageAddress, @Description, SizeOf(Description));
  Result := Message^.Length;
  FreeMessage(Message);
  if Error <> ErrorNone then
    Result := Failure(Error);
end;

function PerformGetChannelPeer(Channel: Int64; PeerAddress: QWord): Int64;
var
  ChannelEnd: PChannelEnd;
  Holder: TAbiChannelPeer;
  Known: Boolean;
begin
  ChannelEnd := PChannelEnd(ReferenceHandleOfKind(Channel, Processes.Handles.HandleKindChannel));
  if ChannelEnd = nil then
    Exit(Failure(ErrorBadHandle));
  Known := GetChannelPeer(ChannelEnd, Holder);
  DereferenceObject(ChannelEnd);
  if not Known then
    Exit(Failure(ErrorNotFound));
  Result := -Int64(CopyToUser(PeerAddress, @Holder, SizeOf(Holder)));
end;

end.
