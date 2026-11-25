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
  System call dispatcher, and the calls for processes, memory, time,
  libraries and system information.

  The architecture entry code hands every system call to
  DispatchSystemCall with the caller's registers in a trap frame; the
  call number is in RAX and the arguments in RDI, RSI, RDX, R10, R8, R9.
  File related calls live in Processes.FileCalls.
}
unit Processes.SystemCalls;

{$mode objfpc}
{$pointermath on}

interface

procedure InitializeSystemCalls;

implementation

uses
  Processes.ObjectCalls,
  Processes.WatchCalls,
  Processes.ProcessDetails,
  Processes.SystemUsage,
  Processes.ClockCalls,
  Processes.PowerCalls,
  Processes.KeyboardCalls,
  Processes.WaitCalls,
  Processes.NotificationCalls,
  Processes.MappingCalls,
  Processes.SocketCalls,
  Processes.NetworkCalls,
  Processes.NodeName,
  Processes.ThreadNames,
  Processes.ModuleCalls,
  Runtime.Memory,
  Runtime.Text,
  Abi.SystemCalls,
  Kernel.Arch.UserCopy,
  Kernel.Processors,
  Memory.Layout,
  Memory.KernelHeap,
  Memory.PhysicalPages,
  Kernel.Arch.TrapFrame,
  Kernel.Arch.SystemCallEntry,
  Kernel.Mutex,
  Kernel.Scheduler,
  Kernel.Clock,
  Objects.Manager,
  Processes.Process,
  Processes.AddressSpace,
  Processes.Handles,
  Processes.Paths,
  Processes.Thread,
  Processes.ImageLoader,
  Processes.UserProcess,
  Processes.UserAccess,
  Processes.Termination,
  Processes.FileCalls,
  Processes.Restrictions,
  Processes.ThreadCalls,
  Processes.TerminalCalls,
  Io.Manager,
  Io.LineDiscipline,
  { Users, permissions, process information and priorities. }
  FileSystem.Types,
  FileSystem.Files,
  FileSystem.Security,
  Processes.Security,
  Processes.SecurityCalls,
  Processes.AffinityCalls,
  Processes.LimitCalls,
  Processes.MemoryCalls,
  Processes.MappedFileCalls,
  Processes.MemoryChargeCalls,
  Processes.VirtualMemoryCalls,
  Processes.LoadedModules,
  Processes.HandlePassing,
  Processes.Shutdown,
  Processes.Suspend,
  Processes.ThreadControl,
  Processes.FileAttributeCalls,
  Processes.MountCalls,
  Processes.UserExceptions,
  { Job control. }
  Processes.Stopping,
  { The kernel's command line, for the service manager. }
  Kernel.Options,
  { What the processor is (CallGetProcessorDescription). }
  Kernel.Arch.ProcessorIdentity,
  { What the machine is (CallGetMachineModel). }
  Drivers.MachineModel,
  { The POSIX block: the C library's calls. }
  Processes.PosixMemoryCalls,
  Processes.ProgramArguments,
  Processes.Fork,
  Processes.Execution,
  Processes.ChildWaits,
  Processes.Signals;

const
  SystemName = 'FreePascalOS';
  SystemRelease = '0.2.0';
  SystemVersion = '#1 FreePascalOS kernel';

function Failure(Error: LongInt): Int64;
begin
  Result := -Int64(Error);
end;

{ --- Process creation ------------------------------------------------ }

{ The user a program is started as, when its creator names one
  (TAbiProcessCreation.Identity): only root may. Its real, effective and
  saved ids all become the user's, and its groups the ones given. }
function ApplyStartIdentity(Caller: PProcess; IdentityAddress: QWord;
  var Credentials: TProcessCredentials): LongInt;
var
  Identity: TAbiProcessIdentity;
  Index: LongWord;
begin
  if IdentityAddress = 0 then
    Exit(ErrorNone);
  if Credentials.EffectiveUserId <> RootUserId then
    Exit(ErrorNotPermitted);
  Result := CopyFromUser(@Identity, IdentityAddress, SizeOf(Identity));
  if Result <> ErrorNone then
    Exit;
  if (Identity.GroupCount > MaximumProcessGroups) or (Identity.UserId > $7FFFFFFF) or
     (Identity.GroupId > $7FFFFFFF) then
    Exit(ErrorInvalidArgument);
  Credentials.RealUserId := Identity.UserId;
  Credentials.EffectiveUserId := Identity.UserId;
  Credentials.SavedUserId := Identity.UserId;
  Credentials.RealGroupId := Identity.GroupId;
  Credentials.EffectiveGroupId := Identity.GroupId;
  Credentials.SavedGroupId := Identity.GroupId;
  Credentials.GroupCount := Identity.GroupCount;
  Index := 0;
  while Index < Identity.GroupCount do
  begin
    Credentials.Groups[Index] := Identity.Groups[Index];
    Inc(Index);
  end;
  Result := ErrorNone;
end;

const
  { The bytes of TAbiProcessCreation up to Flags: the whole record as
    programs from before ProcessPassHandles know it. }
  CreationBaseSize = 10 * SizeOf(QWord);

{ The rest of starting a program, whose file ProgramFile is open and
  checked. }
function CreateProcessFromFile(Caller: PProcess; const Creation: TAbiProcessCreation; ProgramFile: POpenFile;
  UserPath, KernelPath: PChar; const Credentials: TProcessCredentials): Int64; forward;

function PerformCreateProcess(CreationAddress: QWord): Int64;
var
  Credentials: TProcessCredentials;
  Creation: TAbiProcessCreation;
  Caller: PProcess;
  UserPath: array[0..ProcessPathCapacity - 1] of Char;
  KernelPath: array[0..ProcessPathCapacity - 1] of Char;
  ProgramFile: POpenFile;
  Error: LongInt;
begin
  { Programs from before ProcessPassHandles pass a record ending at
    Flags: the rest is read only when the flag says it is there. }
  FillMemory(@Creation, SizeOf(Creation), 0);
  Error := CopyFromUser(@Creation, CreationAddress, CreationBaseSize);
  if (Error = ErrorNone) and ((Creation.Flags and ProcessPassHandles) <> 0) then
    Error := CopyFromUser(PByte(@Creation) + CreationBaseSize, CreationAddress + CreationBaseSize,
      SizeOf(Creation) - CreationBaseSize);
  if Error = ErrorNone then
    Error := CopyStringFromUser(QWord(Creation.Path), @UserPath[0], ProcessPathCapacity);
  if Error <> ErrorNone then
    Exit(Failure(Error));
  if CallerRestricted(RestrictProcessCreation) then
    Exit(Failure(ErrorAccessDenied));

  Caller := CurrentProcess;
  Error := TranslateUserPath(Caller, @UserPath[0], @KernelPath[0], ProcessPathCapacity);
  if Error <> ErrorNone then
    Exit(Failure(Error));
  InheritCredentials(Caller, Credentials);
  Error := ApplyStartIdentity(Caller, QWord(Creation.Identity), Credentials);
  if Error <> ErrorNone then
    Exit(Failure(Error));
  { Checked and loaded from this one open file (Processes.ProgramArguments). }
  Error := OpenProgramFile(Caller, @KernelPath[0], Credentials, ProgramFile);
  if Error <> ErrorNone then
    Exit(Failure(Error));
  Result := CreateProcessFromFile(Caller, Creation, ProgramFile, @UserPath[0], @KernelPath[0], Credentials);
  CloseFile(ProgramFile);
end;

function CreateProcessFromFile(Caller: PProcess; const Creation: TAbiProcessCreation; ProgramFile: POpenFile;
  UserPath, KernelPath: PChar; const Credentials: TProcessCredentials): Int64;
var
  Startup: TProcessStartup;
  WorkingDirectory: array[0..ProcessPathCapacity - 1] of Char;
  RequestedDirectory: array[0..ProcessPathCapacity - 1] of Char;
  RootDirectory: array[0..ProcessPathCapacity - 1] of Char;
  Arguments: TStringList;
  Environment: TStringList;
  StandardHandles: array[0..2] of Int64;
  StandardIndex: Integer;
  Child: PProcess;
  Error: LongInt;
  NewTerminal: Pointer;
begin
  AcquireMutex(Caller^.Lock);
  CopyText(@WorkingDirectory[0], @Caller^.CurrentDirectory[0], ProcessPathCapacity);
  CopyText(@RootDirectory[0], @Caller^.RootDirectory[0], ProcessPathCapacity);
  ReleaseMutex(Caller^.Lock);
  if Creation.WorkingDirectory <> nil then
  begin
    Error := CopyStringFromUser(QWord(Creation.WorkingDirectory), @RequestedDirectory[0], ProcessPathCapacity);
    if Error = ErrorNone then
      Error := NormalizeUserPath(Caller, @RequestedDirectory[0], @WorkingDirectory[0], ProcessPathCapacity);
    if Error <> ErrorNone then
      Exit(Failure(Error));
  end;

  Error := CopyStringListFromUser(QWord(Creation.Arguments), Arguments);
  if Error <> ErrorNone then
    Exit(Failure(Error));
  Error := CopyStringListFromUser(QWord(Creation.Environment), Environment);
  if Error <> ErrorNone then
  begin
    FreeStringList(Arguments);
    Exit(Failure(Error));
  end;

  FillMemory(@Startup, SizeOf(Startup), 0);
  Startup.KernelPath := KernelPath;
  Startup.ProgramFile := ProgramFile;
  Startup.Name := FileNameOf(UserPath);
  Startup.Arguments := Arguments.Items;
  Startup.ArgumentCount := Arguments.Count;
  Startup.Environment := Environment.Items;
  Startup.EnvironmentCount := Environment.Count;
  Startup.WorkingDirectory := @WorkingDirectory[0];
  Startup.ParentProcessId := Caller^.ProcessId;
  Startup.Credentials := Credentials;
  { A program started inside a chroot stays inside it. }
  Startup.RootDirectory := @RootDirectory[0];
  Startup.ControllingTerminal := Caller^.ControllingTerminal;
  { 0 makes the child lead a session of its own. }
  if (Creation.Flags and ProcessNewSession) <> 0 then
    Startup.SessionId := 0
  else
    Startup.SessionId := Caller^.SessionId;
  case Creation.GroupId of
    GroupInherit: Startup.GroupId := Caller^.GroupId;
    GroupNew, GroupNewInForeground: Startup.GroupId := 0;
  else
    if Creation.GroupId < 0 then
      Exit(Failure(ErrorInvalidArgument));
    Startup.GroupId := QWord(Creation.GroupId);
  end;

  StandardHandles[0] := Creation.InputHandle;
  StandardHandles[1] := Creation.OutputHandle;
  StandardHandles[2] := Creation.ErrorHandle;
  AcquireMutex(Caller^.Lock);
  for StandardIndex := 0 to 2 do
  begin
    if not LookupHandle(Caller^.Handles, StandardHandles[StandardIndex],
      Startup.StandardKinds[StandardIndex], Startup.StandardObjects[StandardIndex]) then
      Startup.StandardObjects[StandardIndex] := nil
    else
      { Keep the objects alive while the child is being set up. }
      ReferenceObject(Startup.StandardObjects[StandardIndex]);
  end;
  { The child starts with the caller's limits. }
  Startup.HandleLimit := Caller^.Handles.Limit;
  Startup.RegionLimit := Caller^.AddressSpace^.RegionLimit;
  Startup.CommitLimitPages := Caller^.AddressSpace^.CommitLimitPages;
  Startup.ProcessCountLimit := Caller^.ProcessCountLimit;
  Startup.OomScoreAdjust := Caller^.OomScoreAdjust;
  Startup.Restrictions := Caller^.Restrictions;
  ReleaseMutex(Caller^.Lock);
  Error := ErrorNone;
  if (Creation.Flags and ProcessPassHandles) <> 0 then
    Error := CollectPassedHandles(Caller, QWord(Creation.PassedHandles), Creation.PassedHandleCount,
      Startup.PassedHandles);
  if Error <> ErrorNone then
  begin
    for StandardIndex := 0 to 2 do
      if Startup.StandardObjects[StandardIndex] <> nil then
        DereferenceObject(Startup.StandardObjects[StandardIndex]);
    FreeStringList(Arguments);
    FreeStringList(Environment);
    Exit(Failure(Error));
  end;
  { A group for the foreground: of the terminal that is its standard
    input, which becomes its controlling terminal (a terminal window's
    shell), or else of the one it inherits. }
  NewTerminal := nil;
  if Creation.GroupId = GroupNewInForeground then
  begin
    NewTerminal := TerminalDeviceOf(Startup.StandardKinds[0], Startup.StandardObjects[0]);
    if NewTerminal = nil then
      NewTerminal := Startup.ControllingTerminal;
    Startup.ControllingTerminal := NewTerminal;
  end;

  { Its user may run only so many processes at once. }
  if not UserMayStartProcess(Startup.Credentials.RealUserId, Caller^.ProcessCountLimit) then
    Error := ErrorWouldBlock
  else
    Error := CreateUserProcess(Startup, Child);
  if (Error = ErrorNone) and (NewTerminal <> nil) then
    SetTerminalForegroundGroup(PLineDiscipline(PDeviceObject(NewTerminal)^.Terminal)^, Child^.GroupId);

  for StandardIndex := 0 to 2 do
  begin
    if Startup.StandardObjects[StandardIndex] <> nil then
      DereferenceObject(Startup.StandardObjects[StandardIndex]);
  end;
  ReleasePassedHandles(Startup.PassedHandles);
  FreeStringList(Arguments);
  FreeStringList(Environment);
  if Error <> ErrorNone then
    Exit(Failure(Error));

  AcquireMutex(Caller^.Lock);
  Result := InsertHandle(Caller^.Handles, HandleKindProcess, Child, 0);
  ReleaseMutex(Caller^.Lock);
  DereferenceObject(Child);
  if Result < 0 then
    Result := Failure(ErrorTooManyHandles);
end;

{ Looks up a process handle of the caller and takes a reference. }
function ReferenceProcessHandle(Handle: Int64): PProcess;
var
  Caller: PProcess;
  Kind: THandleKind;
  ObjectBody: Pointer;
begin
  Caller := CurrentProcess;
  AcquireMutex(Caller^.Lock);
  if LookupHandle(Caller^.Handles, Handle, Kind, ObjectBody) and (Kind = HandleKindProcess) then
    ReferenceObject(ObjectBody)
  else
    ObjectBody := nil;
  ReleaseMutex(Caller^.Lock);
  Result := PProcess(ObjectBody);
end;

{ Timeout in milliseconds, or InfiniteWait. }
function PerformWaitForProcess(Handle: Int64; Timeout: Int64): Int64;
var
  Process: PProcess;
  KernelTimeout: QWord;
  ExitCode: LongInt;
  Error: LongInt;
begin
  Process := ReferenceProcessHandle(Handle);
  if Process = nil then
    Exit(Failure(ErrorNoChildProcess));
  if Timeout < 0 then
    KernelTimeout := InfiniteTimeout
  else
    KernelTimeout := QWord(Timeout);
  Error := WaitForProcessExit(Process, KernelTimeout, ExitCode);
  DereferenceObject(Process);
  if Error <> ErrorNone then
    Exit(Failure(Error));
  { Exit codes are bytes, as on Unix. }
  Result := ExitCode and $FF;
end;

{ Like PerformWaitForProcess, but also returns WaitStatusStopped once
  when the process stops. }
function PerformWaitForProcessChange(Handle: Int64; Timeout: Int64): Int64;
var
  Process: PProcess;
  KernelTimeout: QWord;
  Status: LongInt;
  Error: LongInt;
begin
  Process := ReferenceProcessHandle(Handle);
  if Process = nil then
    Exit(Failure(ErrorNoChildProcess));
  if Timeout < 0 then
    KernelTimeout := InfiniteTimeout
  else
    KernelTimeout := QWord(Timeout);
  Error := WaitForProcessChange(Process, KernelTimeout, Status);
  DereferenceObject(Process);
  if Error <> ErrorNone then
    Exit(Failure(Error));
  Result := Status;
end;

{ The id of the process behind a handle, or of the caller for NoHandle. }
function PerformGetProcessId(Handle: Int64): Int64;
var
  Process: PProcess;
begin
  if Handle = NoHandle then
    Exit(Int64(CurrentProcess^.ProcessId));
  Process := ReferenceProcessHandle(Handle);
  if Process = nil then
    Exit(Failure(ErrorBadHandle));
  Result := Int64(Process^.ProcessId);
  DereferenceObject(Process);
end;

function PerformTerminateProcess(ProcessId: QWord; ExitCode: QWord): Int64;
begin
  Result := -Int64(TerminateProcessById(ProcessId, LongInt(ExitCode and $FF)));
end;

function PerformSetInterruptIgnored(Ignored: QWord): Int64;
begin
  CurrentProcess^.IgnoresInterrupt := Ignored <> 0;
  Result := 0;
end;

function PerformSleep(Milliseconds: QWord): Int64;
begin
  if SleepAlertable(Milliseconds) then
    Result := 0
  else
    Result := Failure(ErrorInterrupted);
end;

{ --- Memory ---------------------------------------------------------- }

{ The address space has a lock of its own, and stays while one of its
  threads runs, so these do not take the process's lock. }
function PerformAllocateMemory(Length, Flags: QWord): Int64;
var
  Process: PProcess;
  Thread: PThread;
  Start: QWord;
  Error: LongInt;
begin
  if (Flags and not QWord(AllocateForThread)) <> 0 then
    Exit(Failure(ErrorInvalidArgument));
  Process := CurrentProcess;
  if (Flags and AllocateForThread) <> 0 then
  begin
    Thread := CurrentThreadObject;
    Error := AllocateThreadOwnedUserMemory(Process^.AddressSpace, Length, Thread^.ControlBlock.ThreadId, Start);
    if Error = ErrorNone then
    begin
      { More than one (dynamic TLS blocks besides the threadvar block):
        an ending thread then looks for all of them. }
      if Thread^.OwnedAllocationStart <> 0 then
        Thread^.HasSeveralOwnedAllocations := True;
      Thread^.OwnedAllocationStart := Start;
    end;
  end
  else
    Error := AllocateUserMemory(Process^.AddressSpace, Length, Start);
  if Error <> ErrorNone then
    Exit(Failure(Error));
  Result := Int64(Start);
end;

function PerformFreeMemory(Address: QWord): Int64;
var
  Thread: PThread;
begin
  Thread := CurrentThreadObject;
  if (Address <> 0) and (Thread^.OwnedAllocationStart = Address) then
    Thread^.OwnedAllocationStart := 0;
  Result := -Int64(FreeUserMemory(CurrentProcess^.AddressSpace, Address));
end;

{ --- Libraries ------------------------------------------------------- }

{ Loads the library at KernelPath into the calling process: a file the
  caller may read and run (OpenLibraryFile), loaded from the very file
  checked. }
function LoadCheckedLibrary(Process: PProcess; KernelPath: PChar; out ModuleHandle: Integer): LongInt;
var
  LibraryFile: POpenFile;
begin
  ModuleHandle := -1;
  Result := OpenLibraryFile(Process, KernelPath, LibraryFile);
  if Result <> ErrorNone then
    Exit;
  Result := LoadLibraryImage(ProcessLoadTarget(Process), LibraryFile, KernelPath, ModuleHandle);
  CloseFile(LibraryFile);
end;

function PerformLoadLibrary(PathAddress: QWord): Int64;
var
  UserPath: array[0..ProcessPathCapacity - 1] of Char;
  KernelPath: array[0..ProcessPathCapacity - 1] of Char;
  Process: PProcess;
  ModuleHandle: Integer;
  Error: LongInt;
  FolderIndex: Integer;
  BareName: Boolean;
begin
  Process := CurrentProcess;
  Error := CopyStringFromUser(PathAddress, @UserPath[0], ProcessPathCapacity);
  if Error <> ErrorNone then
    Exit(Failure(Error));

  { A bare name is looked for in /lib, then /usr/local/lib, like a
    needed library. }
  BareName := (UserPath[0] <> '/') and (UserPath[0] <> '.');
  if not BareName then
  begin
    Error := TranslateUserPath(Process, @UserPath[0], @KernelPath[0], ProcessPathCapacity);
    if Error <> ErrorNone then
      Exit(Failure(Error));
  end;

  AcquireMutex(Process^.Lock);
  if BareName then
  begin
    FolderIndex := 0;
    repeat
      LibraryFolderPath(FolderIndex, @UserPath[0], @KernelPath[0], ProcessPathCapacity);
      Error := LoadCheckedLibrary(Process, @KernelPath[0], ModuleHandle);
      Inc(FolderIndex);
    until (Error <> ErrorNotFound) or not LibraryFolderPath(FolderIndex, @UserPath[0], @KernelPath[0],
      ProcessPathCapacity);
  end
  else
    Error := LoadCheckedLibrary(Process, @KernelPath[0], ModuleHandle);
  { Its initializers wait for the runtime (CallTakeModuleInitializers). }
  if Error = ErrorNone then
    Error := NoteLibraryInitializers(Process, ModuleHandle);
  ReleaseMutex(Process^.Lock);
  if Error <> ErrorNone then
    Exit(Failure(Error));
  Result := ModuleHandle;
end;

function PerformFindSymbol(ModuleHandle: Int64; NameAddress: QWord): Int64;
var
  Name: array[0..1023] of Char;
  Process: PProcess;
  Address: QWord;
  Error: LongInt;
begin
  Process := CurrentProcess;
  Error := CopyStringFromUser(NameAddress, @Name[0], Length(Name));
  if Error <> ErrorNone then
    Exit(Failure(Error));
  AcquireMutex(Process^.Lock);
  Error := FindExportedSymbol(Process, Integer(ModuleHandle), @Name[0], Address);
  ReleaseMutex(Process^.Lock);
  if Error <> ErrorNone then
    Exit(Failure(Error));
  Result := Int64(Address);
end;

{ --- Time and system information ------------------------------------- }

function PerformGetTime(Which: QWord): Int64;
begin
  case Which of
    TimeWallClock: Result := CurrentWallClockTime;
    TimeUptimeNanoseconds: Result := Int64(ClockNanoseconds);
  else
    Result := Int64(UptimeMilliseconds);
  end;
end;

function PerformGetSystemInformation(InformationAddress: QWord): Int64;
var
  Information: TAbiSystemInformation;
  Statistics: TPhysicalMemoryStatistics;
begin
  FillMemory(@Information, SizeOf(Information), 0);
  CopyText(@Information.SystemName[0], SystemName, AbiTextCapacity);
  CopyText(@Information.Release[0], SystemRelease, AbiTextCapacity);
  CopyText(@Information.Version[0], SystemVersion, AbiTextCapacity);
  CopyText(@Information.Machine[0], MachineArchitectureName, AbiTextCapacity);
  GetNodeName(@Information.NodeName[0], AbiTextCapacity);
  GetPhysicalMemoryStatistics(Statistics);
  Information.TotalMemory := Statistics.TotalUsablePages * PageSize;
  Information.FreeMemory := Statistics.FreePages * PageSize;
  Information.UptimeMilliseconds := UptimeMilliseconds;
  Information.ProcessorCount := OnlineProcessorCount;
  GetLoadAverages(Information.LoadAverages[0], Information.LoadAverages[1],
    Information.LoadAverages[2]);
  Information.RunnableThreads := RunnableThreadCount;
  Result := -Int64(CopyToUser(InformationAddress, @Information, SizeOf(Information)));
end;

function PerformGetProcessorDescription(DescriptionAddress: QWord): Int64;
var
  Description: TAbiProcessorDescription;
begin
  DescribeProcessor(Description);
  Result := -Int64(CopyToUser(DescriptionAddress, @Description, SizeOf(Description)));
end;

{ Text into a caller's buffer of Capacity bytes (cut short and ended by a
  zero); returns the whole text's length. }
function CopyTextToUser(Text: PChar; BufferAddress, Capacity: QWord): Int64;
var
  Length: QWord;
  Copied: QWord;
  Terminator: Char;
  Error: LongInt;
begin
  Length := TextLength(Text);
  if Capacity = 0 then
    Exit(Int64(Length));
  Copied := Length;
  if Copied > Capacity - 1 then
    Copied := Capacity - 1;
  Error := CopyToUser(BufferAddress, Text, Copied);
  Terminator := #0;
  if Error = ErrorNone then
    Error := CopyToUser(BufferAddress + Copied, @Terminator, 1);
  if Error <> ErrorNone then
    Exit(Failure(Error));
  Result := Int64(Length);
end;

{ The options the system started with: the service manager reads its
  boot mode there, login the user to log in automatically. }
function PerformGetKernelOptions(BufferAddress, Capacity: QWord): Int64;
begin
  Result := CopyTextToUser(KernelCommandLine, BufferAddress, Capacity);
end;

function PerformGetMachineModel(BufferAddress, Capacity: QWord): Int64;
begin
  Result := CopyTextToUser(MachineModel, BufferAddress, Capacity);
end;

function PerformTerminateSession(SessionId: QWord; ExitCode: QWord): Int64;
begin
  Result := TerminateSession(SessionId, LongInt(ExitCode and $FF));
end;

{ --- Dispatcher ------------------------------------------------------ }

function PerformSystemCall(Number: QWord; Argument0, Argument1, Argument2, Argument3, Argument4,
  Argument5: QWord): Int64;
begin
  Result := 0;
  case Number of
    CallExit: ExitCurrentProcess(LongInt(Argument0));
    CallWrite: Result := PerformWriteHandle(Int64(Argument0), Argument1, Argument2);
    CallRead: Result := PerformReadHandle(Int64(Argument0), Argument1, Argument2);
    CallOpen: Result := PerformOpenFile(Argument0, Argument1);
    CallClose: Result := PerformCloseHandle(Int64(Argument0));
    CallSeek: Result := PerformSeekHandle(Int64(Argument0), Int64(Argument1), Argument2);
    CallGetHandleInformation: Result := PerformGetHandleInformation(Int64(Argument0), Argument1);
    CallGetPathInformation: Result := PerformGetPathInformation(Argument0, Argument1, Argument2);
    CallReadDirectory: Result := PerformReadDirectory(Int64(Argument0), Argument1);
    CallCreateDirectory: Result := PerformCreateDirectory(Argument0);
    CallRemove: Result := PerformRemovePath(Argument0);
    CallRename: Result := PerformRenamePath(Argument0, Argument1);
    CallCreateSymbolicLink: Result := PerformCreateSymbolicLink(Argument0, Argument1);
    CallReadSymbolicLink: Result := PerformReadSymbolicLink(Argument0, Argument1, Argument2);
    CallSetFileSize: Result := PerformSetFileSize(Int64(Argument0), Argument1);
    CallGetCurrentDirectory: Result := PerformGetCurrentDirectory(Argument0, Argument1);
    CallSetCurrentDirectory: Result := PerformSetCurrentDirectory(Argument0);
    CallAllocateMemory: Result := PerformAllocateMemory(Argument0, Argument1);
    CallFreeMemory: Result := PerformFreeMemory(Argument0);
    CallCreateProcess: Result := PerformCreateProcess(Argument0);
    CallWaitForProcess: Result := PerformWaitForProcess(Int64(Argument0), Int64(Argument1));
    CallGetProcessId: Result := PerformGetProcessId(Int64(Argument0));
    CallCreatePipe: Result := PerformCreatePipe(Argument0);
    CallDuplicateHandle: Result := PerformDuplicateHandle(Int64(Argument0), Int64(Argument1));
    CallSleep: Result := PerformSleep(Argument0);
    CallGetTime: Result := PerformGetTime(Argument0);
    CallLoadLibrary: Result := PerformLoadLibrary(Argument0);
    CallFindSymbol: Result := PerformFindSymbol(Int64(Argument0), Argument1);
    CallGetSystemInformation: Result := PerformGetSystemInformation(Argument0);
    CallSync: Result := PerformSync;
    CallGetHandleKind: Result := PerformGetHandleKind(Int64(Argument0));
    CallListVolumes: Result := PerformListVolumes(Argument0, Argument1);
    CallSetPathAttributes: Result := PerformSetPathAttributes(Argument0, Argument1, Argument2);
    CallCreateHardLink: Result := PerformCreateHardLink(Argument0, Argument1);
    CallTerminateProcess: Result := PerformTerminateProcess(Argument0, Argument1);
    CallSetRootDirectory: Result := PerformSetRootDirectory(Argument0);
    CallControlHandle: Result := PerformControlHandle(Int64(Argument0), Argument1, Argument2);
    CallSetInterruptIgnored: Result := PerformSetInterruptIgnored(Argument0);
    CallGetProcessGroup: Result := Int64(CurrentProcess^.GroupId);

    { Threads (Processes.ThreadCalls). }
    CallCreateThread: Result := PerformCreateThread(Argument0, Argument1, Argument2);
    CallExitThread: PerformExitThread(Argument0);
    CallWaitForThread: Result := PerformWaitForThread(Int64(Argument0), Int64(Argument1), Argument2);
    CallSetThreadPointer: Result := PerformSetThreadPointer(Argument0);
    CallGetThreadId: Result := PerformGetThreadId(Int64(Argument0));
    CallWaitOnAddress: Result := PerformWaitOnAddress(Argument0, Argument1, Int64(Argument2));
    CallWakeAddress: Result := PerformWakeAddress(Argument0, Argument1);
    { --- Users, permissions, process information and priorities --- }
    CallListProcesses: Result := PerformListProcesses(Argument0, Argument1);
    CallGetCredentials: Result := PerformGetCredentials(Argument0);
    CallSetUserIds: Result := PerformSetUserIds(Int64(Argument0), Int64(Argument1), Int64(Argument2));
    CallSetGroupIds: Result := PerformSetGroupIds(Int64(Argument0), Int64(Argument1), Int64(Argument2));
    CallSetGroups: Result := PerformSetGroups(Argument0, Argument1);
    CallSetUmask: Result := PerformSetUmask(Argument0);
    CallGetPriority: Result := PerformGetPriority(Argument0);
    CallSetPriority: Result := PerformSetPriority(Argument0, Int64(Argument1));
    CallCreateFifo: Result := PerformCreateFifo(Argument0);
    { --- Job control (Processes.Stopping) --- }
    CallStopProcesses: Result := StopProcesses(Int64(Argument0));
    CallContinueProcesses: Result := ContinueProcesses(Int64(Argument0));
    CallWaitForProcessChange: Result := PerformWaitForProcessChange(Int64(Argument0), Int64(Argument1));
    { --- Processor affinity (Processes.AffinityCalls) --- }
    CallGetAffinity: Result := PerformGetAffinity(Argument0);
    CallSetAffinity: Result := PerformSetAffinity(Argument0, Argument1);
    CallShutdown: Result := PerformShutdown(Argument0);
    CallSuspend: Result := PerformSuspend;
    CallMapHandle: Result := PerformMapHandle(Int64(Argument0), Argument1, Argument2, Argument3);

    { Objects for programs that work together (Processes.ObjectCalls,
      Processes.WaitCalls). }
    CallCreateEvent: Result := PerformCreateEvent(Argument0);
    CallSetEvent: Result := PerformSetEvent(Int64(Argument0), True);
    CallResetEvent: Result := PerformSetEvent(Int64(Argument0), False);
    CallCreateTimer: Result := PerformCreateTimer(Argument0);
    CallCreateSemaphore: Result := PerformCreateSemaphore(Int64(Argument0), Int64(Argument1));
    CallReleaseSemaphore: Result := PerformReleaseSemaphore(Int64(Argument0), Int64(Argument1));
    CallGetSemaphoreCount: Result := PerformGetSemaphoreCount(Int64(Argument0));
    CallSetTimer: Result := PerformSetTimer(Int64(Argument0), Argument1, Argument2);
    CallWaitForHandles: Result := PerformWaitForHandles(Argument0, Argument1, Int64(Argument2), Argument3);
    CallCreateSection: Result := PerformCreateSection(Argument0);
    CallCreatePort: Result := PerformCreatePort(Argument0);
    CallConnectPort: Result := PerformConnectPort(Argument0);
    CallAcceptConnection: Result := PerformAcceptConnection(Int64(Argument0));
    CallCreateChannel: Result := PerformCreateChannel(Argument0);
    CallSendMessage: Result := PerformSendMessage(Int64(Argument0), Argument1);
    CallReceiveMessage: Result := PerformReceiveMessage(Int64(Argument0), Argument1);
    { Pseudo-terminals (Processes.TerminalCalls). }
    CallCreatePseudoTerminal: Result := PerformCreatePseudoTerminal(Argument0, Argument1);
    { Startup, services and sessions. }
    CallGetKernelOptions: Result := PerformGetKernelOptions(Argument0, Argument1);
    CallGetChannelPeer: Result := PerformGetChannelPeer(Int64(Argument0), Argument1);
    CallTerminateSession: Result := PerformTerminateSession(Argument0, Argument1);
    CallWatchShutdown: Result := PerformWatchShutdown;
    { Notifications (Processes.NotificationCalls). }
    CallSelectNotifications: Result := PerformSelectNotifications(Argument0);
    CallReceiveNotification: Result := PerformReceiveNotification(Argument0);
    CallRequestEnd: Result := PerformRequestEnd(Argument0, Argument1, Argument2);
    { Watching files and folders (Processes.WatchCalls). }
    CallCreateWatch: Result := PerformCreateWatch(Argument0, Argument1);
    CallReadWatch: Result := PerformReadWatch(Int64(Argument0), Argument1, Argument2);
    { Processor time and memory (Processes.ProcessDetails,
      Processes.SystemUsage). }
    CallListProcessDetails: Result := PerformListProcessDetails(Argument0, Argument1);
    CallGetSystemUsage: Result := PerformGetSystemUsage(Argument0);
    { The clock and the time zone (Processes.ClockCalls), the keyboards
      (Processes.KeyboardCalls). }
    CallSetWallClock: Result := PerformSetWallClock(Int64(Argument0));
    CallGetTimeZone: Result := PerformGetTimeZone(Argument0, Argument1);
    CallSetTimeZone: Result := PerformSetTimeZone(Argument0);
    CallGetPreciseTime: Result := PerformGetPreciseTime(Argument0, Argument1);
    CallAdjustWallClock: Result := PerformAdjustWallClock(Int64(Argument0), Argument1, Argument2);
    { Power (Processes.PowerCalls). }
    CallGetProcessorPower: Result := PerformGetProcessorPower(Argument0);
    CallListThermalZones: Result := PerformListThermalZones(Argument0, Argument1);
    CallListBatteries: Result := PerformListBatteries(Argument0, Argument1);
    CallGetKeyboardSettings: Result := PerformGetKeyboardSettings(Argument0);
    CallSetKeyboardSettings: Result := PerformSetKeyboardSettings(Argument0);
    CallDescribeKeyboardLayout: Result := PerformDescribeKeyboardLayout(Argument0, Argument1);
    { --- Thread control (Processes.ThreadControl) --- }
    CallSuspendThread: Result := PerformSuspendThread(Int64(Argument0));
    CallResumeThread: Result := PerformResumeThread(Int64(Argument0));
    CallTerminateThread: Result := PerformTerminateThread(Int64(Argument0), Argument1);
    CallSetThreadPriority: Result := PerformSetThreadPriority(Int64(Argument0), Int64(Argument1));
    CallGetThreadPriority: Result := PerformGetThreadPriority(Int64(Argument0));
    { --- Attributes of open files and volumes (Processes.FileAttributeCalls) --- }
    CallSetHandleAttributes: Result := PerformSetHandleAttributes(Int64(Argument0), Argument1);
    CallGetVolumeInformation: Result := PerformGetVolumeInformation(Argument0, Argument1);
    { --- Processor exceptions (Processes.UserExceptions) --- }
    CallSetExceptionDispatcher: Result := PerformSetExceptionDispatcher(Argument0);
    CallExceptionDispatched: Result := PerformExceptionDispatched;
    { --- Sockets (Processes.SocketCalls) --- }
    CallCreateSocket: Result := PerformCreateSocket(Argument0, Argument1, Argument2);
    CallBindSocket: Result := PerformBindSocket(Int64(Argument0), Argument1);
    CallListenSocket: Result := PerformListenSocket(Int64(Argument0), Argument1);
    CallAcceptSocket: Result := PerformAcceptSocket(Int64(Argument0), Argument1);
    CallConnectSocket: Result := PerformConnectSocket(Int64(Argument0), Argument1);
    CallSendSocket: Result := PerformSendSocket(Int64(Argument0), Argument1, Argument2, Argument3, Argument4);
    CallReceiveSocket: Result := PerformReceiveSocket(Int64(Argument0), Argument1, Argument2, Argument3, Argument4);
    CallShutdownSocket: Result := PerformShutdownSocket(Int64(Argument0), Argument1);
    CallGetSocketOption: Result := PerformGetSocketOption(Int64(Argument0), Argument1);
    CallSetSocketOption: Result := PerformSetSocketOption(Int64(Argument0), Argument1, Int64(Argument2));
    CallGetSocketAddress: Result := PerformGetSocketAddress(Int64(Argument0), Argument1, Argument2);
    CallWaitForSocket: Result := PerformWaitForSocket(Int64(Argument0), Argument1, Int64(Argument2));
    { --- Network configuration (Processes.NetworkCalls) --- }
    CallListNetworkInterfaces: Result := PerformListNetworkInterfaces(Argument0, Argument1);
    CallConfigureNetworkInterface: Result := PerformConfigureNetworkInterface(Argument0);
    CallChangeRoute: Result := PerformChangeRoute(Argument0, Argument1);
    CallListRoutes: Result := PerformListRoutes(Argument0, Argument1);
    CallListArpEntries: Result := PerformListArpEntries(Argument0, Argument1);
    CallListNeighbors: Result := PerformListNeighbors(Argument0, Argument1);
    CallListSockets: Result := PerformListSockets(Argument0, Argument1);
    CallGetDnsServers: Result := PerformGetDnsServers(Argument0);
    CallSetDnsServers: Result := PerformSetDnsServers(Argument0);
    CallSetNodeName: Result := PerformSetNodeName(Argument0);
    CallGetProcessorDescription: Result := PerformGetProcessorDescription(Argument0);
    CallGetMachineModel: Result := PerformGetMachineModel(Argument0, Argument1);
    CallGetProcessResources: Result := PerformGetProcessResources(Argument0, Argument1);
    CallSetProcessLimit: Result := PerformSetProcessLimit(Argument0, Argument1);
    CallGetProcessModules: Result := PerformGetProcessModules(Argument0, Argument1);
    CallWatchNetworkChanges: Result := PerformWatchNetworkChanges;
    CallGetNetworkStatistics: Result := PerformGetNetworkStatistics(Argument0);
    CallSetThreadName: Result := PerformSetThreadName(Int64(Argument0), Argument1);
    CallListThreads: Result := PerformListThreads(Argument0, Argument1, Argument2);
    CallGetModuleTls: Result := PerformGetModuleTls(Int64(Argument0), Argument1);
    CallTakeModuleInitializers: Result := PerformTakeModuleInitializers(Int64(Argument0), Argument1);
    { --- Virtual memory (Processes.VirtualMemoryCalls) --- }
    CallReserveMemory: Result := PerformReserveMemory(Argument0, Argument1);
    CallCommitMemory: Result := PerformCommitMemory(Argument0, Argument1, Argument2);
    CallDecommitMemory: Result := PerformDecommitMemory(Argument0, Argument1);
    CallProtectMemory: Result := PerformProtectMemory(Argument0, Argument1, Argument2);
    CallQueryMemory: Result := PerformQueryMemory(Argument0, Argument1);
    CallSetMemoryPolicy: Result := PerformSetMemoryPolicy(Argument0);
    CallTrimVolume: Result := PerformTrimVolume(Argument0);
    CallGetBlockCacheStatistics: Result := PerformGetBlockCacheStatistics(Argument0);
    CallGetMemoryPressure: Result := PerformGetMemoryPressure(Argument0);
    CallMountVolume: Result := PerformMountVolume(Argument0);
    CallUnmountVolume: Result := PerformUnmountVolume(Argument0, Argument1);
    CallListMounts: Result := PerformListMounts(Argument0, Argument1);
    CallGetFileTimes: Result := PerformGetFileTimes(Argument0, Int64(Argument1), Argument2, Argument3);
    { File mappings (214-219). }
    CallSyncMemory: Result := PerformSyncMemory(Argument0, Argument1, Argument2);
    CallQueryMemoryResidency: Result := PerformQueryMemoryResidency(Argument0, Argument1, Argument2);
    CallGetMappedFileStatistics: Result := PerformGetMappedFileStatistics(Argument0);
    CallTrimMappedFiles: Result := PerformTrimMappedFiles(Argument0, Argument1);
    { The POSIX block (180-199). }
    CallMapMemory: Result := PerformMapMemory(Argument0, Argument1, Argument2, Argument3, Int64(Argument4),
      Argument5);
    CallUnmapMemory: Result := PerformUnmapMemory(Argument0, Argument1);
    CallCreateThreadOnStack: Result := PerformCreateThreadOnStack(Argument0, Argument1, Argument2);
    CallWaitForChild: Result := PerformWaitForChild(Int64(Argument0), Argument1, Argument2);
    CallSetSignalDispatcher: Result := PerformSetSignalDispatcher(Argument0);
    CallSendSignal: Result := PerformSendSignal(Int64(Argument0), Argument1);
    CallSetSignalMask: Result := PerformSetSignalMask(Argument0, Argument1, Argument2);
    CallSetSignalDisposition: Result := PerformSetSignalDisposition(Argument0, Argument1, Argument2, Argument3);
    CallSuspendForSignal: Result := PerformSuspendForSignal(Argument0);
    CallPendingSignals: Result := PerformPendingSignals;
    CallSetProcessGroup: Result := PerformSetProcessGroup(Argument0, Argument1);
    CallCreateSession: Result := PerformCreateSession;
    CallGetProcessGroupOf: Result := PerformGetProcessGroupOf(Argument0, Argument1);
    CallGetParentProcessId: Result := Int64(CurrentProcess^.ParentProcessId);
    { Memory and the loader (208-213). }
    CallGetProcessMemoryCharge: Result := PerformGetProcessMemoryCharge(Argument0, Argument1);
    CallGetImageCacheStatistics: Result := PerformGetImageCacheStatistics(Argument0);
  else
    Result := Failure(ErrorNotImplemented);
  end;
end;

procedure DispatchSystemCall(Frame: PTrapFrame);
var
  Number: QWord;
  Argument0: QWord;
  Argument1: QWord;
  Argument2: QWord;
  Argument3: QWord;
  Argument4: QWord;
  Argument5: QWord;
  Result: Int64;
  MustRestart: Boolean;
begin
  Number := SystemCallNumber(Frame);
  Argument0 := SystemCallArgument(Frame, 0);
  Argument1 := SystemCallArgument(Frame, 1);
  Argument2 := SystemCallArgument(Frame, 2);
  Argument3 := SystemCallArgument(Frame, 3);
  Argument4 := SystemCallArgument(Frame, 4);
  Argument5 := SystemCallArgument(Frame, 5);
  CurrentThreadObject^.SystemCallFrame := Frame;
  { A stack overflow's reserve is armed again once the stack is clear. }
  if StackReserveIsOpen then
    RearmStackReserveIfClear(TrapFrameStackPointer(Frame));

  { Continuing at a context replaces the whole frame; on success there is
    no result to return. }
  { fork works on the caller's registers (the child goes on from them). }
  if Number = CallForkProcess then
  begin
    SetSystemCallResult(Frame, PerformForkProcess(Frame));
    CurrentThreadObject^.SystemCallFrame := nil;
    EndProcessIfTerminationRequested;
    DeliverPendingSignals(Frame);
    Exit;
  end;

  { Leaving a signal handler and exec replace the whole frame too. }
  if (Number = CallContinue) or (Number = CallReturnFromSignal) or (Number = CallExecuteProgram) then
  begin
    case Number of
      CallContinue: Result := -Int64(PerformContinue(Frame, Argument0));
      CallReturnFromSignal: Result := -Int64(PerformReturnFromSignal(Frame, Argument0));
    else
      Result := -Int64(PerformExecuteProgram(Frame, Argument0));
    end;
    if Result <> 0 then
      SetSystemCallResult(Frame, Result);
    CurrentThreadObject^.SystemCallFrame := nil;
    EndProcessIfTerminationRequested;
    DeliverPendingSignals(Frame);
    Exit;
  end;

  repeat
    Result := PerformSystemCall(Number, Argument0, Argument1, Argument2, Argument3, Argument4, Argument5);
    { A call cut short because the program was asked to stop runs again
      once the program is continued, so the program never sees the stop. }
    MustRestart := (Result = Failure(ErrorInterrupted)) and
      (CurrentStopIsPending or CurrentThreadSuspendIsPending);
    StopCurrentThreadIfRequested;
    HoldCurrentThreadIfAsked;
  until not MustRestart or CurrentProcess^.TerminationRequested;

  SetSystemCallResult(Frame, Result);
  CurrentThreadObject^.SystemCallFrame := nil;
  { A program asked to end does so before it runs any further. }
  EndProcessIfTerminationRequested;
  { The call's data ran into the stack's reserve: the program learns of
    the overflow now, with the call's result in hand. }
  DeliverPendingStackOverflow(Frame);
  { A signal the program handles (Processes.Signals). }
  DeliverPendingSignals(Frame);
end;

procedure InitializeSystemCalls;
begin
  InitializeUserProcesses;
  InitializeProcessTermination;
  InitializeThreadCalls;
  InitializeWaitCalls;
  { From here on the kernel touches user memory only through checked
    copies, so SMAP can be turned on. }
  InitializeUserCopy;
  InitializeSystemCallEntry(@DispatchSystemCall);
end;

end.
