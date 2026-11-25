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
function KernelCreatePseudoTerminal(Terminal: PAbiPseudoTerminal; Size: QWord): Int64;

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
{ The same with Map* flags (files). }
function KernelMapHandleWithFlags(Handle: Int64; Offset, Length: QWord; Flags: LongWord): Int64;
function KernelReserveMemory(ByteCount: QWord): Int64;
function KernelCommitMemory(Address: Pointer; ByteCount: QWord; Protection: LongWord): Int64;
function KernelDecommitMemory(Address: Pointer; ByteCount: QWord): Int64;
function KernelProtectMemory(Address: Pointer; ByteCount: QWord; Protection: LongWord): Int64;
function KernelQueryMemory(Address: Pointer; out Information: TAbiMemoryInformation): Int64;
function KernelSetMemoryPolicy(Flags: LongWord): Int64;
function KernelCreateEvent(Flags: LongWord): Int64;
function KernelSetEvent(Handle: Int64): Int64;
function KernelResetEvent(Handle: Int64): Int64;
function KernelCreateSemaphore(InitialCount, Limit: LongInt): Int64;
{ The count before the release, or minus an error (ErrorOverflow). }
function KernelReleaseSemaphore(Handle: Int64; ReleaseCount: LongInt): Int64;
function KernelGetSemaphoreCount(Handle: Int64): Int64;
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
{ Watching files and folders. }
function KernelCreateWatch(Path: PChar; Flags: LongWord): Int64;
function KernelReadWatch(Handle: Int64; Buffer: Pointer; Capacity: QWord): Int64;
{ Processor time and memory. Returns how many processes there are (Capacity
  records filled at most). }
function KernelListProcessDetails(Buffer: PAbiProcessDetails; Capacity: QWord): Int64;
function KernelGetSystemUsage(out Usage: TAbiSystemUsage): Int64;
{ What a process (0: this one) holds against its limits. }
function KernelGetProcessResources(ProcessId: QWord; out Resources: TAbiProcessResources): Int64;
{ Sets one of this process's limits (ProcessLimit*); returns the old one. }
function KernelSetProcessLimit(Limit: LongWord; Value: QWord): Int64;
{ The clock, the time zone and the keyboards (changes are root's). }
function KernelSetWallClock(Time: Int64): Int64;
{ The time to the nanosecond (TimeWallClock or TimeUptimeNanoseconds). }
function KernelGetPreciseTime(Which: LongWord; out Time: TAbiPreciseTime): Int64;
{ Moves the wall clock by OffsetNanoseconds (Adjust* flags); Remaining
  gets what a gradual adjustment still has to move. }
function KernelAdjustWallClock(OffsetNanoseconds: Int64; Flags: LongWord; out Remaining: Int64): Int64;
{ Power: the processors, the thermal zones, the batteries. }
function KernelGetProcessorPower(out Information: TAbiProcessorPower): Int64;
function KernelListThermalZones(Zones: PAbiThermalZone; Capacity: QWord): Int64;
function KernelListBatteries(Batteries: PAbiBattery; Capacity: QWord): Int64;
{ Wake sources, cooling devices and performance states (calls 228-232). }
function KernelSetWakeAlarm(Seconds: QWord): Int64;
function KernelListWakeSources(Sources: PAbiWakeSource; Capacity: QWord): Int64;
function KernelSetWakeSource(Index: QWord; Enabled: Boolean): Int64;
function KernelListCoolingDevices(Devices: PAbiCoolingDevice; Capacity: QWord): Int64;
function KernelListPerformanceStates(States: PAbiPerformanceState; Capacity: QWord): Int64;
function KernelGetTimeZone(Buffer: PChar; Capacity: QWord): Int64;
function KernelSetTimeZone(Name: PChar): Int64;
function KernelGetKeyboardSettings(out Settings: TAbiKeyboardSettings): Int64;
function KernelSetKeyboardSettings(constref Settings: TAbiKeyboardSettings): Int64;
function KernelDescribeKeyboardLayout(Index: QWord; out Layout: TAbiKeyboardLayout): Int64;
{ Job control: Target is a process id, -group, or 0 for the own group. }
function KernelStopProcesses(Target: Int64): Int64;
function KernelContinueProcesses(Target: Int64): Int64;
function KernelWaitForProcessChange(Handle: Int64; Timeout: Int64): Int64;
{ Startup, services and sessions. }
function KernelGetKernelOptions(Buffer: PChar; Capacity: QWord): Int64;
function KernelGetChannelPeer(Channel: Int64; out Peer: TAbiChannelPeer): Int64;
function KernelTerminateSession(SessionId: QWord; ExitCode: LongInt): Int64;
function KernelWatchShutdown: Int64;
function KernelSelectNotifications(Mask: LongWord): Int64;
function KernelReceiveNotification(out Notification: TAbiNotification): Int64;
function KernelRequestEnd(TargetKind: LongWord; TargetId: QWord; Reason: LongWord): Int64;

{ Networking: sockets (Sys.Sockets) and the network's configuration
  (Sys.NetworkInterfaces). Addresses are TAbiSocketAddress records. }
function KernelCreateSocket(Family, Kind, Protocol: LongWord): Int64;
function KernelBindSocket(Handle: Int64; constref Address: TAbiSocketAddress): Int64;
function KernelListenSocket(Handle: Int64; Backlog: LongWord): Int64;
{ Peer may be nil. }
function KernelAcceptSocket(Handle: Int64; Peer: PAbiSocketAddress): Int64;
function KernelConnectSocket(Handle: Int64; constref Address: TAbiSocketAddress): Int64;
{ Address nil: to the connected peer. }
function KernelSendSocket(Handle: Int64; Buffer: Pointer; Length: QWord; Flags: LongWord;
  Address: PAbiSocketAddress): Int64;
{ Address may be nil. }
function KernelReceiveSocket(Handle: Int64; Buffer: Pointer; Length: QWord; Flags: LongWord;
  Address: PAbiSocketAddress): Int64;
function KernelShutdownSocket(Handle: Int64; How: LongWord): Int64;
function KernelGetSocketOption(Handle: Int64; Option: LongWord): Int64;
function KernelSetSocketOption(Handle: Int64; Option: LongWord; Value: Int64): Int64;
function KernelGetSocketAddress(Handle: Int64; Which: LongWord; out Address: TAbiSocketAddress): Int64;
function KernelWaitForSocket(Handle: Int64; Conditions: LongWord; Timeout: Int64): Int64;
function KernelListNetworkInterfaces(Buffer: PAbiNetworkInterface; Capacity: QWord): Int64;
function KernelConfigureNetworkInterface(constref Configuration: TAbiInterfaceConfiguration): Int64;
function KernelChangeRoute(Operation: LongWord; constref Route: TAbiRoute): Int64;
function KernelListRoutes(Buffer: PAbiRoute; Capacity: QWord): Int64;
function KernelListArpEntries(Buffer: PAbiArpEntry; Capacity: QWord): Int64;
function KernelListNeighbors(Buffer: PAbiNeighborEntry; Capacity: QWord): Int64;
function KernelListSockets(Buffer: PAbiSocketInformation; Capacity: QWord): Int64;
function KernelGetDnsServers(out Servers: TAbiDnsServers): Int64;
function KernelSetDnsServers(constref Servers: TAbiDnsServers): Int64;
function KernelWatchNetworkChanges: Int64;
function KernelSetNodeName(Name: PChar): Int64;
function KernelGetNetworkStatistics(out Statistics: TAbiNetworkStatistics): Int64;

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

function KernelCreatePseudoTerminal(Terminal: PAbiPseudoTerminal; Size: QWord): Int64;
begin
  Result := SystemCall(CallCreatePseudoTerminal, QWord(Terminal), Size, 0, 0, 0, 0);
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

function KernelMapHandleWithFlags(Handle: Int64; Offset, Length: QWord; Flags: LongWord): Int64;
begin
  Result := SystemCall(CallMapHandle, QWord(Handle), Offset, Length, Flags, 0, 0);
end;

function KernelReserveMemory(ByteCount: QWord): Int64;
begin
  Result := SystemCall(CallReserveMemory, ByteCount, 0, 0, 0, 0, 0);
end;

function KernelCommitMemory(Address: Pointer; ByteCount: QWord; Protection: LongWord): Int64;
begin
  Result := SystemCall(CallCommitMemory, QWord(Address), ByteCount, Protection, 0, 0, 0);
end;

function KernelDecommitMemory(Address: Pointer; ByteCount: QWord): Int64;
begin
  Result := SystemCall(CallDecommitMemory, QWord(Address), ByteCount, 0, 0, 0, 0);
end;

function KernelProtectMemory(Address: Pointer; ByteCount: QWord; Protection: LongWord): Int64;
begin
  Result := SystemCall(CallProtectMemory, QWord(Address), ByteCount, Protection, 0, 0, 0);
end;

function KernelQueryMemory(Address: Pointer; out Information: TAbiMemoryInformation): Int64;
begin
  Result := SystemCall(CallQueryMemory, QWord(Address), QWord(@Information), 0, 0, 0, 0);
end;

function KernelSetMemoryPolicy(Flags: LongWord): Int64;
begin
  Result := SystemCall(CallSetMemoryPolicy, Flags, 0, 0, 0, 0, 0);
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

function KernelCreateSemaphore(InitialCount, Limit: LongInt): Int64;
begin
  Result := SystemCall(CallCreateSemaphore, QWord(Int64(InitialCount)), QWord(Int64(Limit)), 0, 0, 0, 0);
end;

function KernelReleaseSemaphore(Handle: Int64; ReleaseCount: LongInt): Int64;
begin
  Result := SystemCall(CallReleaseSemaphore, QWord(Handle), QWord(Int64(ReleaseCount)), 0, 0, 0, 0);
end;

function KernelGetSemaphoreCount(Handle: Int64): Int64;
begin
  Result := SystemCall(CallGetSemaphoreCount, QWord(Handle), 0, 0, 0, 0, 0);
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

function KernelCreateWatch(Path: PChar; Flags: LongWord): Int64;
begin
  Result := SystemCall(CallCreateWatch, QWord(Path), Flags, 0, 0, 0, 0);
end;

function KernelReadWatch(Handle: Int64; Buffer: Pointer; Capacity: QWord): Int64;
begin
  Result := SystemCall(CallReadWatch, QWord(Handle), QWord(Buffer), Capacity, 0, 0, 0);
end;

function KernelGetProcessResources(ProcessId: QWord; out Resources: TAbiProcessResources): Int64;
begin
  Result := SystemCall(CallGetProcessResources, ProcessId, QWord(@Resources), 0, 0, 0, 0);
end;

function KernelSetProcessLimit(Limit: LongWord; Value: QWord): Int64;
begin
  Result := SystemCall(CallSetProcessLimit, Limit, Value, 0, 0, 0, 0);
end;

function KernelListProcessDetails(Buffer: PAbiProcessDetails; Capacity: QWord): Int64;
begin
  Result := SystemCall(CallListProcessDetails, QWord(Buffer), Capacity, 0, 0, 0, 0);
end;

function KernelGetSystemUsage(out Usage: TAbiSystemUsage): Int64;
begin
  Result := SystemCall(CallGetSystemUsage, QWord(@Usage), 0, 0, 0, 0, 0);
end;

function KernelSetWallClock(Time: Int64): Int64;
begin
  Result := SystemCall(CallSetWallClock, QWord(Time), 0, 0, 0, 0, 0);
end;

function KernelGetPreciseTime(Which: LongWord; out Time: TAbiPreciseTime): Int64;
begin
  Result := SystemCall(CallGetPreciseTime, Which, QWord(@Time), 0, 0, 0, 0);
end;

function KernelAdjustWallClock(OffsetNanoseconds: Int64; Flags: LongWord; out Remaining: Int64): Int64;
begin
  Remaining := 0;
  Result := SystemCall(CallAdjustWallClock, QWord(OffsetNanoseconds), Flags, QWord(@Remaining), 0, 0, 0);
end;

function KernelGetProcessorPower(out Information: TAbiProcessorPower): Int64;
begin
  Result := SystemCall(CallGetProcessorPower, QWord(@Information), 0, 0, 0, 0, 0);
end;

function KernelListThermalZones(Zones: PAbiThermalZone; Capacity: QWord): Int64;
begin
  Result := SystemCall(CallListThermalZones, QWord(Zones), Capacity, 0, 0, 0, 0);
end;

function KernelListBatteries(Batteries: PAbiBattery; Capacity: QWord): Int64;
begin
  Result := SystemCall(CallListBatteries, QWord(Batteries), Capacity, 0, 0, 0, 0);
end;

function KernelSetWakeAlarm(Seconds: QWord): Int64;
begin
  Result := SystemCall(CallSetWakeAlarm, Seconds, 0, 0, 0, 0, 0);
end;

function KernelListWakeSources(Sources: PAbiWakeSource; Capacity: QWord): Int64;
begin
  Result := SystemCall(CallListWakeSources, QWord(Sources), Capacity, 0, 0, 0, 0);
end;

function KernelSetWakeSource(Index: QWord; Enabled: Boolean): Int64;
begin
  Result := SystemCall(CallSetWakeSource, Index, QWord(Ord(Enabled)), 0, 0, 0, 0);
end;

function KernelListCoolingDevices(Devices: PAbiCoolingDevice; Capacity: QWord): Int64;
begin
  Result := SystemCall(CallListCoolingDevices, QWord(Devices), Capacity, 0, 0, 0, 0);
end;

function KernelListPerformanceStates(States: PAbiPerformanceState; Capacity: QWord): Int64;
begin
  Result := SystemCall(CallListPerformanceStates, QWord(States), Capacity, 0, 0, 0, 0);
end;

function KernelGetTimeZone(Buffer: PChar; Capacity: QWord): Int64;
begin
  Result := SystemCall(CallGetTimeZone, QWord(Buffer), Capacity, 0, 0, 0, 0);
end;

function KernelSetTimeZone(Name: PChar): Int64;
begin
  Result := SystemCall(CallSetTimeZone, QWord(Name), 0, 0, 0, 0, 0);
end;

function KernelGetKeyboardSettings(out Settings: TAbiKeyboardSettings): Int64;
begin
  Result := SystemCall(CallGetKeyboardSettings, QWord(@Settings), 0, 0, 0, 0, 0);
end;

function KernelSetKeyboardSettings(constref Settings: TAbiKeyboardSettings): Int64;
begin
  Result := SystemCall(CallSetKeyboardSettings, QWord(@Settings), 0, 0, 0, 0, 0);
end;

function KernelDescribeKeyboardLayout(Index: QWord; out Layout: TAbiKeyboardLayout): Int64;
begin
  Result := SystemCall(CallDescribeKeyboardLayout, Index, QWord(@Layout), 0, 0, 0, 0);
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

function KernelGetKernelOptions(Buffer: PChar; Capacity: QWord): Int64;
begin
  Result := SystemCall(CallGetKernelOptions, QWord(Buffer), Capacity, 0, 0, 0, 0);
end;

function KernelGetChannelPeer(Channel: Int64; out Peer: TAbiChannelPeer): Int64;
begin
  Result := SystemCall(CallGetChannelPeer, QWord(Channel), QWord(@Peer), 0, 0, 0, 0);
end;

function KernelTerminateSession(SessionId: QWord; ExitCode: LongInt): Int64;
begin
  Result := SystemCall(CallTerminateSession, SessionId, QWord(ExitCode), 0, 0, 0, 0);
end;

function KernelWatchShutdown: Int64;
begin
  Result := SystemCall(CallWatchShutdown, 0, 0, 0, 0, 0, 0);
end;

function KernelSelectNotifications(Mask: LongWord): Int64;
begin
  Result := SystemCall(CallSelectNotifications, Mask, 0, 0, 0, 0, 0);
end;

function KernelReceiveNotification(out Notification: TAbiNotification): Int64;
begin
  Result := SystemCall(CallReceiveNotification, QWord(@Notification), 0, 0, 0, 0, 0);
end;

function KernelRequestEnd(TargetKind: LongWord; TargetId: QWord; Reason: LongWord): Int64;
begin
  Result := SystemCall(CallRequestEnd, TargetKind, TargetId, Reason, 0, 0, 0);
end;

function KernelCreateSocket(Family, Kind, Protocol: LongWord): Int64;
begin
  Result := SystemCall(CallCreateSocket, Family, Kind, Protocol, 0, 0, 0);
end;

function KernelBindSocket(Handle: Int64; constref Address: TAbiSocketAddress): Int64;
begin
  Result := SystemCall(CallBindSocket, QWord(Handle), QWord(@Address), 0, 0, 0, 0);
end;

function KernelListenSocket(Handle: Int64; Backlog: LongWord): Int64;
begin
  Result := SystemCall(CallListenSocket, QWord(Handle), Backlog, 0, 0, 0, 0);
end;

function KernelAcceptSocket(Handle: Int64; Peer: PAbiSocketAddress): Int64;
begin
  Result := SystemCall(CallAcceptSocket, QWord(Handle), QWord(Peer), 0, 0, 0, 0);
end;

function KernelConnectSocket(Handle: Int64; constref Address: TAbiSocketAddress): Int64;
begin
  Result := SystemCall(CallConnectSocket, QWord(Handle), QWord(@Address), 0, 0, 0, 0);
end;

function KernelSendSocket(Handle: Int64; Buffer: Pointer; Length: QWord; Flags: LongWord;
  Address: PAbiSocketAddress): Int64;
begin
  Result := SystemCall(CallSendSocket, QWord(Handle), QWord(Buffer), Length, Flags, QWord(Address), 0);
end;

function KernelReceiveSocket(Handle: Int64; Buffer: Pointer; Length: QWord; Flags: LongWord;
  Address: PAbiSocketAddress): Int64;
begin
  Result := SystemCall(CallReceiveSocket, QWord(Handle), QWord(Buffer), Length, Flags, QWord(Address), 0);
end;

function KernelShutdownSocket(Handle: Int64; How: LongWord): Int64;
begin
  Result := SystemCall(CallShutdownSocket, QWord(Handle), How, 0, 0, 0, 0);
end;

function KernelGetSocketOption(Handle: Int64; Option: LongWord): Int64;
begin
  Result := SystemCall(CallGetSocketOption, QWord(Handle), Option, 0, 0, 0, 0);
end;

function KernelSetSocketOption(Handle: Int64; Option: LongWord; Value: Int64): Int64;
begin
  Result := SystemCall(CallSetSocketOption, QWord(Handle), Option, QWord(Value), 0, 0, 0);
end;

function KernelGetSocketAddress(Handle: Int64; Which: LongWord; out Address: TAbiSocketAddress): Int64;
begin
  Result := SystemCall(CallGetSocketAddress, QWord(Handle), Which, QWord(@Address), 0, 0, 0);
end;

function KernelWaitForSocket(Handle: Int64; Conditions: LongWord; Timeout: Int64): Int64;
begin
  Result := SystemCall(CallWaitForSocket, QWord(Handle), Conditions, QWord(Timeout), 0, 0, 0);
end;

function KernelListNetworkInterfaces(Buffer: PAbiNetworkInterface; Capacity: QWord): Int64;
begin
  Result := SystemCall(CallListNetworkInterfaces, QWord(Buffer), Capacity, 0, 0, 0, 0);
end;

function KernelConfigureNetworkInterface(constref Configuration: TAbiInterfaceConfiguration): Int64;
begin
  Result := SystemCall(CallConfigureNetworkInterface, QWord(@Configuration), 0, 0, 0, 0, 0);
end;

function KernelChangeRoute(Operation: LongWord; constref Route: TAbiRoute): Int64;
begin
  Result := SystemCall(CallChangeRoute, Operation, QWord(@Route), 0, 0, 0, 0);
end;

function KernelListRoutes(Buffer: PAbiRoute; Capacity: QWord): Int64;
begin
  Result := SystemCall(CallListRoutes, QWord(Buffer), Capacity, 0, 0, 0, 0);
end;

function KernelListArpEntries(Buffer: PAbiArpEntry; Capacity: QWord): Int64;
begin
  Result := SystemCall(CallListArpEntries, QWord(Buffer), Capacity, 0, 0, 0, 0);
end;

function KernelListNeighbors(Buffer: PAbiNeighborEntry; Capacity: QWord): Int64;
begin
  Result := SystemCall(CallListNeighbors, QWord(Buffer), Capacity, 0, 0, 0, 0);
end;

function KernelListSockets(Buffer: PAbiSocketInformation; Capacity: QWord): Int64;
begin
  Result := SystemCall(CallListSockets, QWord(Buffer), Capacity, 0, 0, 0, 0);
end;

function KernelGetDnsServers(out Servers: TAbiDnsServers): Int64;
begin
  Result := SystemCall(CallGetDnsServers, QWord(@Servers), 0, 0, 0, 0, 0);
end;

function KernelSetDnsServers(constref Servers: TAbiDnsServers): Int64;
begin
  Result := SystemCall(CallSetDnsServers, QWord(@Servers), 0, 0, 0, 0, 0);
end;

function KernelWatchNetworkChanges: Int64;
begin
  Result := SystemCall(CallWatchNetworkChanges, 0, 0, 0, 0, 0, 0);
end;

function KernelSetNodeName(Name: PChar): Int64;
begin
  Result := SystemCall(CallSetNodeName, QWord(Name), 0, 0, 0, 0, 0);
end;

function KernelGetNetworkStatistics(out Statistics: TAbiNetworkStatistics): Int64;
begin
  Result := SystemCall(CallGetNetworkStatistics, QWord(@Statistics), 0, 0, 0, 0, 0);
end;

end.
