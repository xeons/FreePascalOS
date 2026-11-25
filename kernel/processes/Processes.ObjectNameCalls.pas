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
  System calls for the object namespace (Objects.Namespace): directories
  (CallCreateObjectDirectory), naming an object a program holds
  (CallNameObject), opening one by name (CallOpenNamedObject), listing
  (CallListObjectDirectory), removing names (CallRemoveObjectName) and
  their owners and modes (CallSetObjectSecurity).

  Every call is checked as the calling process: its effective user and
  groups judge the permission bits (root passes every check), and its
  umask applies to what it names. A process restricted from port
  connections may use none of them.
}
unit Processes.ObjectNameCalls;

{$mode objfpc}
{$pointermath on}

interface

function PerformCreateObjectDirectory(PathAddress, Mode: QWord): Int64;
function PerformNameObject(Handle: Int64; PathAddress, Mode: QWord): Int64;
function PerformOpenNamedObject(PathAddress, Kind: QWord): Int64;
function PerformListObjectDirectory(PathAddress, BufferAddress, Capacity, FirstIndex: QWord): Int64;
function PerformRemoveObjectName(PathAddress: QWord): Int64;
function PerformSetObjectSecurity(PathAddress: QWord; Mode, OwnerId, GroupId: Int64): Int64;

implementation

uses
  Abi.SystemCalls,
  Memory.KernelHeap,
  Kernel.Mutex,
  Objects.Manager,
  Objects.Namespace,
  Processes.Handles,
  Processes.Process,
  Processes.Thread,
  Processes.Security,
  Processes.Restrictions,
  Processes.UserAccess,
  Processes.ObjectCalls;

const
  RootUser = 0;
  { Entries listed per call at most (the rest by FirstIndex). }
  MaximumListedEntries = 64;

type
  TObjectPath = array[0..MaximumObjectPathLength - 1] of Char;
  PProcessCredentials = ^TProcessCredentials;

function Failure(Error: LongInt): Int64;
begin
  Result := -Int64(Error);
end;

{ --- The caller ---------------------------------------------------------- }

function CredentialsMayAccessName(Credentials: Pointer; OwnerId, GroupId, Mode, Access: LongWord): Boolean;
var
  Holder: PProcessCredentials;
  Granted: LongWord;
begin
  Holder := PProcessCredentials(Credentials);
  if Holder^.EffectiveUserId = RootUser then
    Exit(True);
  if Holder^.EffectiveUserId = OwnerId then
    Granted := (Mode shr 6) and 7
  else if IsInGroup(Holder^, GroupId) then
    Granted := (Mode shr 3) and 7
  else
    Granted := Mode and 7;
  Result := (Access and not Granted) = 0;
end;

function CredentialsInGroup(Credentials: Pointer; GroupId: LongWord): Boolean;
begin
  Result := IsInGroup(PProcessCredentials(Credentials)^, GroupId);
end;

{ The calling process as the namespace judges it. Its credentials are
  read without its lock, as the file system's checks read them: only
  the process itself changes them. }
procedure DescribeCaller(Process: PProcess; out Caller: TNamespaceCaller);
begin
  Caller.Checked := Process^.IsUserProcess;
  Caller.UserId := Process^.Credentials.EffectiveUserId;
  Caller.Credentials := @Process^.Credentials;
  Caller.MayAccess := @CredentialsMayAccessName;
  Caller.IsInGroup := @CredentialsInGroup;
end;

{ The path argument, and the caller; or why not. }
function BeginCall(PathAddress: QWord; out Path: TObjectPath; out Caller: TNamespaceCaller): LongInt;
begin
  if CallerRestricted(RestrictPortConnections) then
    Exit(ErrorAccessDenied);
  Result := CopyStringFromUser(PathAddress, @Path[0], SizeOf(Path));
  DescribeCaller(CurrentProcess, Caller);
end;

{ Mode as the caller asked for it, less its umask (the sticky bit
  stays). }
function MaskedMode(Mode: QWord): LongWord;
begin
  Result := LongWord(Mode and $3FF) and not (CurrentProcess^.Credentials.Umask and $1FF);
end;

{ --- Handle kinds ---------------------------------------------------------- }

{ The handle kind (internal) for an Abi kind that can be named and
  opened; HandleKindFree for any other. }
function HandleKindForAbiKind(Kind: LongWord): THandleKind;
begin
  case Kind of
    Abi.SystemCalls.HandleKindEvent: Result := Processes.Handles.HandleKindEvent;
    Abi.SystemCalls.HandleKindSemaphore: Result := Processes.Handles.HandleKindSemaphore;
    Abi.SystemCalls.HandleKindMutex: Result := Processes.Handles.HandleKindMutex;
    Abi.SystemCalls.HandleKindSection: Result := Processes.Handles.HandleKindSection;
    Abi.SystemCalls.HandleKindTimer: Result := Processes.Handles.HandleKindTimer;
  else
    Result := Processes.Handles.HandleKindFree;
  end;
end;

function IsNameableKind(Kind: THandleKind): Boolean;
begin
  Result := Kind in [Processes.Handles.HandleKindEvent, Processes.Handles.HandleKindSemaphore,
    Processes.Handles.HandleKindMutex, Processes.Handles.HandleKindSection, Processes.Handles.HandleKindTimer];
end;

{ --- The calls ------------------------------------------------------------- }

function PerformCreateObjectDirectory(PathAddress, Mode: QWord): Int64;
var
  Path: TObjectPath;
  Caller: TNamespaceCaller;
  Error: LongInt;
begin
  Error := BeginCall(PathAddress, Path, Caller);
  if Error = ErrorNone then
    Error := CreateObjectDirectory(@Path[0], Caller.UserId, CurrentProcess^.Credentials.EffectiveGroupId,
      MaskedMode(Mode), Caller);
  Result := Failure(Error);
end;

function PerformNameObject(Handle: Int64; PathAddress, Mode: QWord): Int64;
var
  Path: TObjectPath;
  Caller: TNamespaceCaller;
  Error: LongInt;
  Kind: THandleKind;
  Body: Pointer;
begin
  Error := BeginCall(PathAddress, Path, Caller);
  if Error <> ErrorNone then
    Exit(Failure(Error));
  Body := ReferenceHandle(Handle, Kind);
  if Body = nil then
    Exit(Failure(ErrorBadHandle));
  if not IsNameableKind(Kind) then
    Error := ErrorUnsupported
  else
    Error := InsertObjectName(Body, @Path[0], Caller.UserId, CurrentProcess^.Credentials.EffectiveGroupId,
      MaskedMode(Mode) and $1FF, Caller);
  DereferenceObject(Body);
  Result := Failure(Error);
end;

function PerformOpenNamedObject(PathAddress, Kind: QWord): Int64;
var
  Path: TObjectPath;
  Caller: TNamespaceCaller;
  Error: LongInt;
  Body: Pointer;
  OpenKind: LongWord;
  Process: PProcess;
begin
  Error := BeginCall(PathAddress, Path, Caller);
  if Error <> ErrorNone then
    Exit(Failure(Error));
  if (Kind <> 0) and (HandleKindForAbiKind(LongWord(Kind)) = Processes.Handles.HandleKindFree) then
    Exit(Failure(ErrorInvalidArgument));
  Error := LookupObjectPath(@Path[0], nil, Caller, NameAccessRead or NameAccessWrite, Body);
  if Error <> ErrorNone then
    Exit(Failure(Error));
  OpenKind := ObjectTypeOf(Body)^.OpenKind;
  if OpenKind = 0 then
    Result := Failure(ErrorUnsupported)
  else if (Kind <> 0) and (OpenKind <> Kind) then
    Result := Failure(ErrorInvalidArgument)
  else
  begin
    Process := CurrentProcess;
    AcquireMutex(Process^.Lock);
    Result := InsertHandle(Process^.Handles, HandleKindForAbiKind(OpenKind), Body, 0);
    ReleaseMutex(Process^.Lock);
    if Result < 0 then
      Result := Failure(ErrorTooManyHandles);
  end;
  DereferenceObject(Body);
end;

function PerformListObjectDirectory(PathAddress, BufferAddress, Capacity, FirstIndex: QWord): Int64;
var
  Path: TObjectPath;
  Caller: TNamespaceCaller;
  Error: LongInt;
  Entries: PAbiObjectDirectoryEntry;
  Total: LongWord;
  Filled: LongWord;
begin
  Error := BeginCall(PathAddress, Path, Caller);
  if Error <> ErrorNone then
    Exit(Failure(Error));
  if Capacity > MaximumListedEntries then
    Capacity := MaximumListedEntries;
  if FirstIndex > High(LongWord) then
    FirstIndex := High(LongWord);
  if not UserRangeIsValid(BufferAddress, Capacity * SizeOf(TAbiObjectDirectoryEntry), True) then
    Exit(Failure(ErrorBadAddress));
  Entries := nil;
  if Capacity > 0 then
  begin
    Entries := PAbiObjectDirectoryEntry(AllocateZeroedKernelMemory(Capacity * SizeOf(TAbiObjectDirectoryEntry)));
    if Entries = nil then
      Exit(Failure(ErrorOutOfMemory));
  end;
  Error := ListObjectDirectory(@Path[0], LongWord(FirstIndex), Entries, LongWord(Capacity), Total, Filled, Caller);
  if (Error = ErrorNone) and (Filled > 0) then
    Error := CopyToUser(BufferAddress, Entries, Filled * SizeOf(TAbiObjectDirectoryEntry));
  FreeKernelMemory(Entries);
  if Error <> ErrorNone then
    Exit(Failure(Error));
  Result := Total;
end;

function PerformRemoveObjectName(PathAddress: QWord): Int64;
var
  Path: TObjectPath;
  Caller: TNamespaceCaller;
  Error: LongInt;
begin
  Error := BeginCall(PathAddress, Path, Caller);
  if Error = ErrorNone then
    Error := RemoveObjectName(@Path[0], Caller);
  Result := Failure(Error);
end;

function PerformSetObjectSecurity(PathAddress: QWord; Mode, OwnerId, GroupId: Int64): Int64;
var
  Path: TObjectPath;
  Caller: TNamespaceCaller;
  Error: LongInt;
begin
  Error := BeginCall(PathAddress, Path, Caller);
  if Error = ErrorNone then
    Error := ChangeObjectSecurity(@Path[0], Mode, OwnerId, GroupId, Caller);
  Result := Failure(Error);
end;

end.
