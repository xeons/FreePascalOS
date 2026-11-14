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

function KernelControlHandle(Handle: Int64; Request: LongWord; Argument: QWord): Int64;
begin
  Result := SystemCall(CallControlHandle, QWord(Handle), Request, Argument, 0, 0, 0);
end;

end.
