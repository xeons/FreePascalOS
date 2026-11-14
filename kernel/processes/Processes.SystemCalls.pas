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
  Processes.ThreadCalls,
  { Users, permissions, process information and priorities. }
  FileSystem.Types,
  FileSystem.Files,
  FileSystem.Security,
  Processes.Security,
  Processes.SecurityCalls,
  Processes.AffinityCalls,
  { Job control. }
  Processes.Stopping;

const
  SystemName = 'FreePascalOS';
  SystemRelease = '0.2.0';
  SystemVersion = '#1 FreePascalOS kernel';
  MachineName = 'x86_64';
  NodeName = 'freepascalos';
  MaximumArgumentBytes = 64 * 1024;

function Failure(Error: LongInt): Int64;
begin
  Result := -Int64(Error);
end;

{ --- Process creation ------------------------------------------------ }

type
  { Kernel copies of an argument or environment list. }
  TStringList = record
    Items: PPChar;
    Count: Integer;
    Storage: PChar;
  end;

procedure FreeStringList(var List: TStringList);
begin
  FreeKernelMemory(List.Items);
  FreeKernelMemory(List.Storage);
  List.Items := nil;
  List.Storage := nil;
  List.Count := 0;
end;

{ Copies a nil terminated array of user strings into kernel memory. }
function CopyStringListFromUser(ListAddress: QWord; out List: TStringList): LongInt;
var
  Pointers: array[0..MaximumArguments] of QWord;
  Index: Integer;
  Used: QWord;
  Length: QWord;
begin
  List.Items := nil;
  List.Count := 0;
  List.Storage := nil;
  if ListAddress = 0 then
    Exit(ErrorNone);

  Index := 0;
  repeat
    if Index > MaximumArguments then
      Exit(ErrorNameTooLong);
    Result := CopyFromUser(@Pointers[Index], ListAddress + QWord(Index) * 8, 8);
    if Result <> ErrorNone then
      Exit;
    Inc(Index);
  until Pointers[Index - 1] = 0;
  List.Count := Index - 1;

  List.Items := PPChar(AllocateZeroedKernelMemory((List.Count + 1) * SizeOf(PChar)));
  List.Storage := PChar(AllocateKernelMemory(MaximumArgumentBytes));
  if (List.Items = nil) or (List.Storage = nil) then
  begin
    FreeStringList(List);
    Exit(ErrorOutOfMemory);
  end;

  Used := 0;
  for Index := 0 to List.Count - 1 do
  begin
    Result := CopyStringFromUser(Pointers[Index], List.Storage + Used, MaximumArgumentBytes - Used);
    if Result <> ErrorNone then
    begin
      FreeStringList(List);
      Exit;
    end;
    List.Items[Index] := List.Storage + Used;
    Length := TextLength(List.Storage + Used) + 1;
    Used := Used + Length;
  end;
  Result := ErrorNone;
end;

function FileNameOf(Path: PChar): PChar;
var
  Index: PtrUInt;
begin
  Result := Path;
  Index := 0;
  while Path[Index] <> #0 do
  begin
    if (Path[Index] = '/') and (Path[Index + 1] <> #0) then
      Result := @Path[Index + 1];
    Inc(Index);
  end;
end;

const
  ModeSetUserId = $800;
  ModeSetGroupId = $400;

{ Running a program needs execute permission (root: any execute bit). A
  set-user-ID or set-group-ID program runs as its owner or group. }
function CheckMayExecute(Caller: PProcess; KernelPath: PChar;
  var Credentials: TProcessCredentials): LongInt;
var
  Information: TNodeInformation;
begin
  Result := ErrorNone;
  if not Caller^.IsUserProcess then
    Exit;
  { A missing program is reported by the loader. }
  if DescribePath(KernelPath, True, Information) <> StatusSuccess then
    Exit;
  if (Information.Kind <> NodeKindFile) or
     not CredentialsMayAccess(Caller^.Credentials, Information, AccessExecute) then
    Exit(ErrorAccessDenied);
  if (Information.Mode and ModeSetUserId) <> 0 then
  begin
    Credentials.EffectiveUserId := Information.OwnerId;
    Credentials.SavedUserId := Information.OwnerId;
  end;
  if (Information.Mode and ModeSetGroupId) <> 0 then
  begin
    Credentials.EffectiveGroupId := Information.GroupId;
    Credentials.SavedGroupId := Information.GroupId;
  end;
end;

function PerformCreateProcess(CreationAddress: QWord): Int64;
var
  Credentials: TProcessCredentials;
  Creation: TAbiProcessCreation;
  Caller: PProcess;
  Startup: TProcessStartup;
  UserPath: array[0..ProcessPathCapacity - 1] of Char;
  KernelPath: array[0..ProcessPathCapacity - 1] of Char;
  WorkingDirectory: array[0..ProcessPathCapacity - 1] of Char;
  RequestedDirectory: array[0..ProcessPathCapacity - 1] of Char;
  RootDirectory: array[0..ProcessPathCapacity - 1] of Char;
  Arguments: TStringList;
  Environment: TStringList;
  StandardHandles: array[0..2] of Int64;
  StandardIndex: Integer;
  Child: PProcess;
  Error: LongInt;
begin
  Error := CopyFromUser(@Creation, CreationAddress, SizeOf(Creation));
  if Error = ErrorNone then
    Error := CopyStringFromUser(QWord(Creation.Path), @UserPath[0], ProcessPathCapacity);
  if Error <> ErrorNone then
    Exit(Failure(Error));

  Caller := CurrentProcess;
  Error := TranslateUserPath(Caller, @UserPath[0], @KernelPath[0], ProcessPathCapacity);
  if Error <> ErrorNone then
    Exit(Failure(Error));
  InheritCredentials(Caller, Credentials);
  Error := CheckMayExecute(Caller, @KernelPath[0], Credentials);
  if Error <> ErrorNone then
    Exit(Failure(Error));

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
  Startup.KernelPath := @KernelPath[0];
  Startup.Name := FileNameOf(@UserPath[0]);
  Startup.Arguments := Arguments.Items;
  Startup.ArgumentCount := Arguments.Count;
  Startup.Environment := Environment.Items;
  Startup.EnvironmentCount := Environment.Count;
  Startup.WorkingDirectory := @WorkingDirectory[0];
  Startup.ParentProcessId := Caller^.ProcessId;
  Startup.Credentials := Credentials;
  { A program started inside a chroot stays inside it. }
  Startup.RootDirectory := @RootDirectory[0];
  case Creation.GroupId of
    GroupInherit: Startup.GroupId := Caller^.GroupId;
    GroupNew: Startup.GroupId := 0;
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
  ReleaseMutex(Caller^.Lock);

  Error := CreateUserProcess(Startup, Child);

  for StandardIndex := 0 to 2 do
  begin
    if Startup.StandardObjects[StandardIndex] <> nil then
      DereferenceObject(Startup.StandardObjects[StandardIndex]);
  end;
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

function PerformAllocateMemory(Length: QWord): Int64;
var
  Process: PProcess;
  Start: QWord;
  Error: LongInt;
begin
  Process := CurrentProcess;
  AcquireMutex(Process^.Lock);
  Error := AllocateUserMemory(Process^.AddressSpace, Length, Start);
  ReleaseMutex(Process^.Lock);
  if Error <> ErrorNone then
    Exit(Failure(Error));
  Result := Int64(Start);
end;

function PerformFreeMemory(Address: QWord): Int64;
var
  Process: PProcess;
begin
  Process := CurrentProcess;
  AcquireMutex(Process^.Lock);
  Result := -Int64(FreeUserMemory(Process^.AddressSpace, Address));
  ReleaseMutex(Process^.Lock);
end;

{ --- Libraries ------------------------------------------------------- }

function PerformLoadLibrary(PathAddress: QWord): Int64;
var
  UserPath: array[0..ProcessPathCapacity - 1] of Char;
  KernelPath: array[0..ProcessPathCapacity - 1] of Char;
  Process: PProcess;
  ModuleHandle: Integer;
  Error: LongInt;
begin
  Process := CurrentProcess;
  Error := CopyStringFromUser(PathAddress, @UserPath[0], ProcessPathCapacity);
  if Error <> ErrorNone then
    Exit(Failure(Error));

  { A bare name is looked for in /lib, like a needed library. }
  if (UserPath[0] <> '/') and (UserPath[0] <> '.') then
  begin
    SystemVolumePath('/lib/', @KernelPath[0], ProcessPathCapacity);
    CopyText(@KernelPath[TextLength(@KernelPath[0])], @UserPath[0],
      ProcessPathCapacity - TextLength(@KernelPath[0]));
  end
  else
  begin
    Error := TranslateUserPath(Process, @UserPath[0], @KernelPath[0], ProcessPathCapacity);
    if Error <> ErrorNone then
      Exit(Failure(Error));
  end;

  AcquireMutex(Process^.Lock);
  Error := LoadLibraryImage(Process, @KernelPath[0], ModuleHandle);
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
  if Which = 0 then
    Result := CurrentWallClockTime
  else
    Result := Int64(UptimeMilliseconds);
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
  CopyText(@Information.Machine[0], MachineName, AbiTextCapacity);
  CopyText(@Information.NodeName[0], NodeName, AbiTextCapacity);
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

{ --- Dispatcher ------------------------------------------------------ }

function PerformSystemCall(Number: QWord; Argument0, Argument1, Argument2: QWord): Int64;
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
    CallAllocateMemory: Result := PerformAllocateMemory(Argument0);
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
  Result: Int64;
  MustRestart: Boolean;
begin
  Number := SystemCallNumber(Frame);
  Argument0 := SystemCallArgument(Frame, 0);
  Argument1 := SystemCallArgument(Frame, 1);
  Argument2 := SystemCallArgument(Frame, 2);

  repeat
    Result := PerformSystemCall(Number, Argument0, Argument1, Argument2);
    { A call cut short because the program was asked to stop runs again
      once the program is continued, so the program never sees the stop. }
    MustRestart := (Result = Failure(ErrorInterrupted)) and CurrentStopIsPending;
    StopCurrentThreadIfRequested;
  until not MustRestart or CurrentProcess^.TerminationRequested;

  SetSystemCallResult(Frame, Result);
  { A program asked to end does so before it runs any further. }
  EndProcessIfTerminationRequested;
end;

procedure InitializeSystemCalls;
begin
  InitializeUserProcesses;
  InitializeProcessTermination;
  InitializeThreadCalls;
  { From here on the kernel touches user memory only through checked
    copies, so SMAP can be turned on. }
  InitializeUserCopy;
  InitializeSystemCallEntry(@DispatchSystemCall);
end;

end.
