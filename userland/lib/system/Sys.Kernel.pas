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
  Typed wrappers around every system call.

  Each routine performs exactly one system call. Results follow the
  kernel's convention: zero or more is success, a negative value is minus
  an error code (see Sys.Errors). Higher level units build friendlier
  interfaces on top of these.
}
unit Sys.Kernel;

{$mode objfpc}

interface

uses
  Abi.SystemCalls;

procedure KernelExit(Code: LongInt);
function KernelWrite(Handle: Int64; Buffer: Pointer; ByteCount: QWord): Int64;
function KernelRead(Handle: Int64; Buffer: Pointer; ByteCount: QWord): Int64;
function KernelOpen(Path: PChar; Flags: LongWord): Int64;
function KernelClose(Handle: Int64): Int64;
function KernelSeek(Handle: Int64; Offset: Int64; Origin: LongWord): Int64;
function KernelGetHandleInformation(Handle: Int64; out Information: TAbiFileInformation): Int64;
function KernelGetPathInformation(Path: PChar; out Information: TAbiFileInformation;
  FollowLinks: Boolean): Int64;
function KernelReadDirectory(Handle: Int64; out Entry: TAbiDirectoryEntry): Int64;
function KernelCreateDirectory(Path: PChar): Int64;
function KernelRemove(Path: PChar): Int64;
function KernelRename(SourcePath, TargetPath: PChar): Int64;
function KernelCreateSymbolicLink(Target, Path: PChar): Int64;
function KernelReadSymbolicLink(Path: PChar; Buffer: PChar; Capacity: QWord): Int64;
function KernelSetFileSize(Handle: Int64; Size: QWord): Int64;
function KernelGetCurrentDirectory(Buffer: PChar; Capacity: QWord): Int64;
function KernelSetCurrentDirectory(Path: PChar): Int64;
function KernelAllocateMemory(ByteCount: QWord): Int64;
function KernelFreeMemory(Address: Pointer): Int64;
function KernelCreateProcess(const Creation: TAbiProcessCreation): Int64;
{ Timeout in milliseconds, or InfiniteWait. }
function KernelWaitForProcess(Handle: Int64; Timeout: Int64): Int64;
{ The id of the process behind Handle, or of the caller for NoHandle. }
function KernelGetProcessId(Handle: Int64): Int64;
function KernelCreatePipe(out ReadHandle, WriteHandle: Int64): Int64;
function KernelDuplicateHandle(Handle: Int64; NewHandle: Int64): Int64;
function KernelSleep(Milliseconds: QWord): Int64;
function KernelGetTime(Which: LongWord): Int64;
function KernelLoadLibrary(Path: PChar): Int64;
function KernelFindSymbol(LibraryHandle: Int64; Name: PChar): Int64;
function KernelGetSystemInformation(out Information: TAbiSystemInformation): Int64;
function KernelSync: Int64;
function KernelGetHandleKind(Handle: Int64): Int64;
function KernelListVolumes(Index: QWord; out Information: TAbiVolumeInformation): Int64;
function KernelSetPathAttributes(Path: PChar; const Changes: TAbiAttributeChanges;
  FollowLinks: Boolean): Int64;
function KernelCreateHardLink(ExistingPath, NewPath: PChar): Int64;
function KernelTerminateProcess(ProcessId: QWord; ExitCode: LongInt): Int64;
function KernelSetRootDirectory(Path: PChar): Int64;
function KernelControlHandle(Handle: Int64; Request: LongWord; Argument: QWord): Int64;
function KernelSetInterruptIgnored(Ignored: Boolean): Int64;
function KernelGetProcessGroup: Int64;

{ Users, permissions, process information and priorities. }
function KernelListProcesses(Index: QWord; out Information: TAbiProcessInformation): Int64;
function KernelGetCredentials(out Credentials: TAbiCredentials): Int64;
{ IdUnchanged leaves an id as it is. }
function KernelSetUserIds(RealId, EffectiveId, SavedId: Int64): Int64;
function KernelSetGroupIds(RealId, EffectiveId, SavedId: Int64): Int64;
function KernelSetGroups(Count: LongWord; Groups: PLongWord): Int64;
{ Returns the previous mask. }
function KernelSetUmask(Mask: LongWord): Int64;
{ Returns the nice value of a process (0: the caller), or minus an error
  code below -40. }
function KernelGetPriority(ProcessId: QWord; out Nice: LongInt): Int64;
function KernelSetPriority(ProcessId: QWord; Nice: LongInt): Int64;
{ The processors process ProcessId (0: this one) may run on, bit N for
  processor N; returns the mask or minus an Abi error. }
function KernelGetAffinity(ProcessId: QWord): Int64;
function KernelSetAffinity(ProcessId: QWord; Mask: QWord): Int64;
{ Shuts the system down (Action: ShutdownPowerOff, ShutdownReboot or
  ShutdownHalt); root only. }
function KernelShutdown(Action: QWord): Int64;
{ Suspends to RAM; returns after waking (root only). }
function KernelSuspend: Int64;
{ The address of Length bytes at Offset of Handle's memory, mapped. }
function KernelMapHandle(Handle: Int64; Offset, Length: QWord): Int64;
function KernelCreateEvent(Flags: LongWord): Int64;
function KernelSetEvent(Handle: Int64): Int64;
function KernelResetEvent(Handle: Int64): Int64;
function KernelCreateTimer(Flags: LongWord): Int64;
function KernelSetTimer(Handle: Int64; DueMilliseconds, PeriodMilliseconds: QWord): Int64;
{ Timeout in milliseconds, or InfiniteWait; Flags 0 or WaitForAll. }
function KernelWaitForHandles(Handles: PInt64; Count: QWord; Timeout: Int64; Flags: QWord): Int64;
function KernelCreateSection(Length: QWord): Int64;
function KernelCreatePort(Name: PChar): Int64;
function KernelConnectPort(Name: PChar): Int64;
function KernelAcceptConnection(PortHandle: Int64): Int64;
function KernelCreateChannel(out First, Second: Int64): Int64;
function KernelSendMessage(Channel: Int64; var Message: TAbiMessage): Int64;
function KernelReceiveMessage(Channel: Int64; var Message: TAbiMessage): Int64;
function KernelCreateFifo(Path: PChar): Int64;
{ Job control: Target is a process id, -group, or 0 for the own group. }
function KernelStopProcesses(Target: Int64): Int64;
function KernelContinueProcesses(Target: Int64): Int64;
function KernelWaitForProcessChange(Handle: Int64; Timeout: Int64): Int64;

implementation

procedure KernelExit(Code: LongInt);
begin
  Halt(Code);
end;

function KernelWrite(Handle: Int64; Buffer: Pointer; ByteCount: QWord): Int64;
begin
  Result := SystemCall(CallWrite, QWord(Handle), QWord(Buffer), ByteCount, 0, 0, 0);
end;

function KernelRead(Handle: Int64; Buffer: Pointer; ByteCount: QWord): Int64;
begin
  Result := SystemCall(CallRead, QWord(Handle), QWord(Buffer), ByteCount, 0, 0, 0);
end;

function KernelOpen(Path: PChar; Flags: LongWord): Int64;
begin
  Result := SystemCall(CallOpen, QWord(Path), Flags, 0, 0, 0, 0);
end;

function KernelClose(Handle: Int64): Int64;
begin
  Result := SystemCall(CallClose, QWord(Handle), 0, 0, 0, 0, 0);
end;

function KernelSeek(Handle: Int64; Offset: Int64; Origin: LongWord): Int64;
begin
  Result := SystemCall(CallSeek, QWord(Handle), QWord(Offset), Origin, 0, 0, 0);
end;

function KernelGetHandleInformation(Handle: Int64; out Information: TAbiFileInformation): Int64;
begin
  Result := SystemCall(CallGetHandleInformation, QWord(Handle), QWord(@Information), 0, 0, 0, 0);
end;

function KernelGetPathInformation(Path: PChar; out Information: TAbiFileInformation;
  FollowLinks: Boolean): Int64;
begin
  Result := SystemCall(CallGetPathInformation, QWord(Path), QWord(@Information), Ord(FollowLinks), 0, 0, 0);
end;

function KernelReadDirectory(Handle: Int64; out Entry: TAbiDirectoryEntry): Int64;
begin
  Result := SystemCall(CallReadDirectory, QWord(Handle), QWord(@Entry), 0, 0, 0, 0);
end;

function KernelCreateDirectory(Path: PChar): Int64;
begin
  Result := SystemCall(CallCreateDirectory, QWord(Path), 0, 0, 0, 0, 0);
end;

function KernelRemove(Path: PChar): Int64;
begin
  Result := SystemCall(CallRemove, QWord(Path), 0, 0, 0, 0, 0);
end;

function KernelRename(SourcePath, TargetPath: PChar): Int64;
begin
  Result := SystemCall(CallRename, QWord(SourcePath), QWord(TargetPath), 0, 0, 0, 0);
end;

function KernelCreateSymbolicLink(Target, Path: PChar): Int64;
begin
  Result := SystemCall(CallCreateSymbolicLink, QWord(Target), QWord(Path), 0, 0, 0, 0);
end;

function KernelReadSymbolicLink(Path: PChar; Buffer: PChar; Capacity: QWord): Int64;
begin
  Result := SystemCall(CallReadSymbolicLink, QWord(Path), QWord(Buffer), Capacity, 0, 0, 0);
end;

function KernelSetFileSize(Handle: Int64; Size: QWord): Int64;
begin
  Result := SystemCall(CallSetFileSize, QWord(Handle), Size, 0, 0, 0, 0);
end;

function KernelGetCurrentDirectory(Buffer: PChar; Capacity: QWord): Int64;
begin
  Result := SystemCall(CallGetCurrentDirectory, QWord(Buffer), Capacity, 0, 0, 0, 0);
end;

function KernelSetCurrentDirectory(Path: PChar): Int64;
begin
  Result := SystemCall(CallSetCurrentDirectory, QWord(Path), 0, 0, 0, 0, 0);
end;

function KernelAllocateMemory(ByteCount: QWord): Int64;
begin
  Result := SystemCall(CallAllocateMemory, ByteCount, 0, 0, 0, 0, 0);
end;

function KernelFreeMemory(Address: Pointer): Int64;
begin
  Result := SystemCall(CallFreeMemory, QWord(Address), 0, 0, 0, 0, 0);
end;

function KernelCreateProcess(const Creation: TAbiProcessCreation): Int64;
begin
  Result := SystemCall(CallCreateProcess, QWord(@Creation), 0, 0, 0, 0, 0);
end;

function KernelWaitForProcess(Handle: Int64; Timeout: Int64): Int64;
begin
  Result := SystemCall(CallWaitForProcess, QWord(Handle), QWord(Timeout), 0, 0, 0, 0);
end;

function KernelGetProcessId(Handle: Int64): Int64;
begin
  Result := SystemCall(CallGetProcessId, QWord(Handle), 0, 0, 0, 0, 0);
end;

function KernelCreatePipe(out ReadHandle, WriteHandle: Int64): Int64;
var
  Handles: array[0..1] of Int64;
begin
  Result := SystemCall(CallCreatePipe, QWord(@Handles[0]), 0, 0, 0, 0, 0);
  ReadHandle := Handles[0];
  WriteHandle := Handles[1];
end;

function KernelDuplicateHandle(Handle: Int64; NewHandle: Int64): Int64;
begin
  Result := SystemCall(CallDuplicateHandle, QWord(Handle), QWord(NewHandle), 0, 0, 0, 0);
end;

function KernelSleep(Milliseconds: QWord): Int64;
begin
  Result := SystemCall(CallSleep, Milliseconds, 0, 0, 0, 0, 0);
end;

function KernelGetTime(Which: LongWord): Int64;
begin
  Result := SystemCall(CallGetTime, Which, 0, 0, 0, 0, 0);
end;

function KernelLoadLibrary(Path: PChar): Int64;
begin
  Result := SystemCall(CallLoadLibrary, QWord(Path), 0, 0, 0, 0, 0);
end;

function KernelFindSymbol(LibraryHandle: Int64; Name: PChar): Int64;
begin
  Result := SystemCall(CallFindSymbol, QWord(LibraryHandle), QWord(Name), 0, 0, 0, 0);
end;

function KernelGetSystemInformation(out Information: TAbiSystemInformation): Int64;
begin
  Result := SystemCall(CallGetSystemInformation, QWord(@Information), 0, 0, 0, 0, 0);
end;

function KernelSync: Int64;
begin
  Result := SystemCall(CallSync, 0, 0, 0, 0, 0, 0);
end;

function KernelGetHandleKind(Handle: Int64): Int64;
begin
  Result := SystemCall(CallGetHandleKind, QWord(Handle), 0, 0, 0, 0, 0);
end;

function KernelListVolumes(Index: QWord; out Information: TAbiVolumeInformation): Int64;
begin
  Result := SystemCall(CallListVolumes, Index, QWord(@Information), 0, 0, 0, 0);
end;

function KernelSetPathAttributes(Path: PChar; const Changes: TAbiAttributeChanges;
  FollowLinks: Boolean): Int64;
begin
  Result := SystemCall(CallSetPathAttributes, QWord(Path), QWord(@Changes), Ord(FollowLinks), 0, 0, 0);
end;

function KernelCreateHardLink(ExistingPath, NewPath: PChar): Int64;
begin
  Result := SystemCall(CallCreateHardLink, QWord(ExistingPath), QWord(NewPath), 0, 0, 0, 0);
end;

function KernelTerminateProcess(ProcessId: QWord; ExitCode: LongInt): Int64;
begin
  Result := SystemCall(CallTerminateProcess, ProcessId, QWord(ExitCode), 0, 0, 0, 0);
end;

function KernelSetRootDirectory(Path: PChar): Int64;
begin
  Result := SystemCall(CallSetRootDirectory, QWord(Path), 0, 0, 0, 0, 0);
end;

function KernelSetInterruptIgnored(Ignored: Boolean): Int64;
begin
  Result := SystemCall(CallSetInterruptIgnored, Ord(Ignored), 0, 0, 0, 0, 0);
end;

function KernelGetProcessGroup: Int64;
begin
  Result := SystemCall(CallGetProcessGroup, 0, 0, 0, 0, 0, 0);
end;

function KernelControlHandle(Handle: Int64; Request: LongWord; Argument: QWord): Int64;
begin
  Result := SystemCall(CallControlHandle, QWord(Handle), Request, Argument, 0, 0, 0);
end;

{ --- Users, permissions, process information and priorities --- }

function KernelListProcesses(Index: QWord; out Information: TAbiProcessInformation): Int64;
begin
  Result := SystemCall(CallListProcesses, Index, QWord(@Information), 0, 0, 0, 0);
end;

function KernelGetCredentials(out Credentials: TAbiCredentials): Int64;
begin
  Result := SystemCall(CallGetCredentials, QWord(@Credentials), 0, 0, 0, 0, 0);
end;

function KernelSetUserIds(RealId, EffectiveId, SavedId: Int64): Int64;
begin
  Result := SystemCall(CallSetUserIds, QWord(RealId), QWord(EffectiveId), QWord(SavedId), 0, 0, 0);
end;

function KernelSetGroupIds(RealId, EffectiveId, SavedId: Int64): Int64;
begin
  Result := SystemCall(CallSetGroupIds, QWord(RealId), QWord(EffectiveId), QWord(SavedId), 0, 0, 0);
end;

function KernelSetGroups(Count: LongWord; Groups: PLongWord): Int64;
begin
  Result := SystemCall(CallSetGroups, Count, QWord(Groups), 0, 0, 0, 0);
end;

function KernelSetUmask(Mask: LongWord): Int64;
begin
  Result := SystemCall(CallSetUmask, Mask, 0, 0, 0, 0, 0);
end;

function KernelGetPriority(ProcessId: QWord; out Nice: LongInt): Int64;
begin
  Result := SystemCall(CallGetPriority, ProcessId, 0, 0, 0, 0, 0);
  Nice := 0;
  if Result >= 0 then
  begin
    Nice := LongInt(20 - Result);
    Result := 0;
  end;
end;

function KernelSetPriority(ProcessId: QWord; Nice: LongInt): Int64;
begin
  Result := SystemCall(CallSetPriority, ProcessId, QWord(Int64(Nice)), 0, 0, 0, 0);
end;

function KernelGetAffinity(ProcessId: QWord): Int64;
begin
  Result := SystemCall(CallGetAffinity, ProcessId, 0, 0, 0, 0, 0);
end;

function KernelSetAffinity(ProcessId: QWord; Mask: QWord): Int64;
begin
  Result := SystemCall(CallSetAffinity, ProcessId, Mask, 0, 0, 0, 0);
end;

function KernelShutdown(Action: QWord): Int64;
begin
  Result := SystemCall(CallShutdown, Action, 0, 0, 0, 0, 0);
end;

function KernelSuspend: Int64;
begin
  Result := SystemCall(CallSuspend, 0, 0, 0, 0, 0, 0);
end;

function KernelCreateFifo(Path: PChar): Int64;
begin
  Result := SystemCall(CallCreateFifo, QWord(Path), 0, 0, 0, 0, 0);
end;

function KernelStopProcesses(Target: Int64): Int64;
begin
  Result := SystemCall(CallStopProcesses, QWord(Target), 0, 0, 0, 0, 0);
end;

function KernelContinueProcesses(Target: Int64): Int64;
begin
  Result := SystemCall(CallContinueProcesses, QWord(Target), 0, 0, 0, 0, 0);
end;

function KernelWaitForProcessChange(Handle: Int64; Timeout: Int64): Int64;
begin
  Result := SystemCall(CallWaitForProcessChange, QWord(Handle), QWord(Timeout), 0, 0, 0, 0);
end;

function KernelMapHandle(Handle: Int64; Offset, Length: QWord): Int64;
begin
  Result := SystemCall(CallMapHandle, QWord(Handle), Offset, Length, 0, 0, 0);
end;

function KernelCreateEvent(Flags: LongWord): Int64;
begin
  Result := SystemCall(CallCreateEvent, Flags, 0, 0, 0, 0, 0);
end;

function KernelSetEvent(Handle: Int64): Int64;
begin
  Result := SystemCall(CallSetEvent, QWord(Handle), 0, 0, 0, 0, 0);
end;

function KernelResetEvent(Handle: Int64): Int64;
begin
  Result := SystemCall(CallResetEvent, QWord(Handle), 0, 0, 0, 0, 0);
end;

function KernelCreateTimer(Flags: LongWord): Int64;
begin
  Result := SystemCall(CallCreateTimer, Flags, 0, 0, 0, 0, 0);
end;

function KernelSetTimer(Handle: Int64; DueMilliseconds, PeriodMilliseconds: QWord): Int64;
begin
  Result := SystemCall(CallSetTimer, QWord(Handle), DueMilliseconds, PeriodMilliseconds, 0, 0, 0);
end;

function KernelWaitForHandles(Handles: PInt64; Count: QWord; Timeout: Int64; Flags: QWord): Int64;
begin
  Result := SystemCall(CallWaitForHandles, QWord(Handles), Count, QWord(Timeout), Flags, 0, 0);
end;

function KernelCreateSection(Length: QWord): Int64;
begin
  Result := SystemCall(CallCreateSection, Length, 0, 0, 0, 0, 0);
end;

function KernelCreatePort(Name: PChar): Int64;
begin
  Result := SystemCall(CallCreatePort, QWord(Name), 0, 0, 0, 0, 0);
end;

function KernelConnectPort(Name: PChar): Int64;
begin
  Result := SystemCall(CallConnectPort, QWord(Name), 0, 0, 0, 0, 0);
end;

function KernelAcceptConnection(PortHandle: Int64): Int64;
begin
  Result := SystemCall(CallAcceptConnection, QWord(PortHandle), 0, 0, 0, 0, 0);
end;

function KernelCreateChannel(out First, Second: Int64): Int64;
var
  Handles: array[0..1] of Int64;
begin
  Result := SystemCall(CallCreateChannel, QWord(@Handles[0]), 0, 0, 0, 0, 0);
  First := Handles[0];
  Second := Handles[1];
end;

function KernelSendMessage(Channel: Int64; var Message: TAbiMessage): Int64;
begin
  Result := SystemCall(CallSendMessage, QWord(Channel), QWord(@Message), 0, 0, 0, 0);
end;

function KernelReceiveMessage(Channel: Int64; var Message: TAbiMessage): Int64;
begin
  Result := SystemCall(CallReceiveMessage, QWord(Channel), QWord(@Message), 0, 0, 0, 0);
end;

end.
