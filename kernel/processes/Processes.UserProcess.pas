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
  User processes: starting programs, ending them, and waiting for them.

  Starting a program creates a process object with its own address space,
  loads the program and its libraries, lays out the initial stack the
  same way Unix systems do (argument count, argument and environment
  pointers, auxiliary vector, then the strings), installs the standard
  handles, and creates the first thread (Processes.UserThread), which
  enters user mode at the program's entry point.

  A process ends when its last thread exits, when one of its threads
  calls the exit system call, or when one raises an exception the kernel
  cannot resolve (such as an invalid memory access). In the last two
  cases the process is marked for termination and its other threads end
  themselves at their next safe point; the last thread to go closes the
  handles, frees the address space and wakes anyone waiting on the
  process.
}
unit Processes.UserProcess;

{$mode objfpc}
{$pointermath on}

interface

uses
  FileSystem.Files,
  Processes.Process,
  Processes.AddressSpace,
  Processes.Handles,
  Processes.HandlePassing,
  Processes.ImageLoader,
  Processes.ImageInitializers;

type
  TProcessStartup = record
    KernelPath: PChar;
    { The program's file, opened and checked by the caller (who closes
      it): what is loaded. nil: opened here from KernelPath, unchecked
      (the kernel's own starts, the initial program). }
    ProgramFile: POpenFile;
    Name: PChar;
    { Strings in kernel memory; copied onto the new process's stack. }
    Arguments: PPChar;
    ArgumentCount: Integer;
    Environment: PPChar;
    EnvironmentCount: Integer;
    { Normalized user path. }
    WorkingDirectory: PChar;
    StandardKinds: array[0..2] of THandleKind;
    StandardObjects: array[0..2] of Pointer;
    ParentProcessId: QWord;
    { The program's "/" (see TProcess.RootDirectory); nil means "/". }
    RootDirectory: PChar;
    { The group to join; 0 starts a new group led by the new process. }
    GroupId: QWord;
    { The session to join; 0 starts a new session led by the new
      process. }
    SessionId: QWord;
    { Who the program runs as (what the program's auxiliary vector
      tells, AT_SECURE included), and its nice value. }
    Credentials: TProcessCredentials;
    { Its controlling terminal (a PDeviceObject; see TProcess). }
    ControllingTerminal: Pointer;
    { Its limits (see Processes.LimitCalls); 0 for the default. }
    RegionLimit: LongWord;
    HandleLimit: LongWord;
    { 0: none. }
    CommitLimitPages: QWord;
    ProcessCountLimit: LongWord;
    OomScoreAdjust: LongInt;
    { The starting process's restrictions (Processes.Restrictions). }
    Restrictions: LongWord;
    { More handles it gets, with their numbers (after the standard ones,
      so a passed 0, 1 or 2 replaces one). }
    PassedHandles: TPassedHandles;
  end;

procedure InitializeUserProcesses;

{ Lays out the initial stack (arguments, environment, auxiliary vector)
  below the stack top of Space's layout; StackPointer is where the
  program starts with it. Interpreter is the program's PT_INTERP module
  or nil. Used by exec too (Processes.Execution). }
function BuildInitialStack(Space: PAddressSpace; const Startup: TProcessStartup;
  MainModule, Interpreter: PLoadedModule; const Lists: TInitializerLists; out StackPointer: QWord): LongInt;
{ Where the first thread starts: the program's entry point, or its
  interpreter's (which then starts the program). }
function ProgramStartAddress(const Target: TLoadTarget; MainModule: PLoadedModule): QWord;
{ True if a program started with Credentials must not trust its
  environment (AT_SECURE): it runs as another user or group than the
  one that started it. }
function CredentialsAreSecure(const Credentials: TProcessCredentials): Boolean;
{ The arguments joined by spaces into Destination (what ps shows). }
procedure JoinArguments(Arguments: PPChar; Count: Integer; Destination: PChar; Capacity: QWord);

{ Starts a program. On success Process holds a reference for the caller. }
function CreateUserProcess(const Startup: TProcessStartup; out Process: PProcess): LongInt;

{ Ends the calling user process: all of its threads. Never returns. The
  exit code is the first one asked for (a termination request from
  elsewhere wins over an exit call that comes later). }
procedure ExitCurrentProcess(ExitCode: LongInt);

{ Ends the calling thread; if it was the process's last thread, the
  process ends with ExitCode. Never returns. }
procedure ExitCurrentThread(ExitCode: LongInt);

{ Waits until Process has ended (or TimeoutMilliseconds pass, or the
  waiting thread is alerted) and gives its exit code. Returns ErrorNone,
  ErrorTimedOut or ErrorInterrupted. }
function WaitForProcessExit(Process: PProcess; TimeoutMilliseconds: QWord;
  out ExitCode: LongInt): LongInt;

implementation

uses
  Runtime.Memory,
  Runtime.Text,
  Abi.SystemCalls,
  Memory.Layout,
  Memory.KernelHeap,
  Memory.Arch.PageTables,
  Kernel.Arch.TrapFrame,
  Kernel.Arch.Cpu,
  Kernel.Arch.Exceptions,
  Kernel.Arch.UserMode,
  Kernel.Clock,
  Kernel.Threads,
  Kernel.Scheduler,
  Kernel.Events,
  Kernel.Mutex,
  Kernel.Panic,
  Objects.Manager,
  FileSystem.Types,
  Processes.UserRegions,
  Processes.Thread,
  Processes.UserThread,
  Processes.UserExceptions,
  Processes.LoadedModules,
  Processes.UserBackTrace,
  Processes.OutOfMemory,
  Memory.PhysicalPages,
  Kernel.Random,
  Processes.ChildWaits,
  Debug.Output;

const
  AuxiliaryNull = 0;
  AuxiliaryProgramHeaders = 3;
  AuxiliaryProgramHeaderSize = 4;
  AuxiliaryProgramHeaderCount = 5;
  AuxiliaryPageSize = 6;
  AuxiliaryInterpreterBase = 7;
  AuxiliaryEntryPoint = 9;
  AuxiliaryUserId = 11;
  AuxiliaryEffectiveUserId = 12;
  AuxiliaryGroupId = 13;
  AuxiliaryEffectiveGroupId = 14;
  AuxiliarySecure = 23;
  AuxiliaryRandomBytes = 25;
  AuxiliaryProgramName = 31;
  AuxiliaryEntryCount = 18;
  ProgramHeaderSize = 56;
  { AT_RANDOM: bytes for the C library's stack protector and hashing. }
  RandomByteCount = 16;

{ --- Faults ---------------------------------------------------------- }

const
  PageFaultFromUserMode = 4;

function ResolvePageFault(FaultAddress: QWord; ErrorCode: QWord): Boolean;
var
  Process: PProcess;
  HitGuard: Boolean;
  Failures: QWord;
begin
  Process := CurrentProcess;
  if (Process = nil) or not Process^.IsUserProcess then
    Exit(False);
  { The kernel copying a system call's data into the stack's reserve:
    open it, so the call can complete, and raise the overflow after. }
  if ((ErrorCode and PageFaultFromUserMode) = 0) and (FaultAddress < UserSpaceLimit) then
    NoteKernelAccessToStack(FaultAddress);
  Failures := FailedPageAllocationCount;
  Result := ResolveUserPageFaultWithGuard(Process^.AddressSpace, FaultAddress, ErrorCode, HitGuard);
  if HitGuard then
  begin
    CurrentThreadObject^.GuardPageHit := True;
    Exit;
  end;
  { No page for a program's own fault: the caches shrink, or a process
    is ended (Processes.OutOfMemory). A fault of the kernel's (copying
    for a system call) fails instead: locks may be held. }
  if not Result and ((ErrorCode and PageFaultFromUserMode) <> 0) and
     (FailedPageAllocationCount <> Failures) and InterruptsAreEnabled then
    Result := ResolveFaultWithoutMemory(Process, FaultAddress, ErrorCode);
end;

procedure HandleUserException(Frame: PTrapFrame; Description: PChar; FaultAddress: QWord);
var
  Process: PProcess;
begin
  { Normally the program's exception dispatcher takes it. }
  if DispatchUserException(Frame, FaultAddress) then
    Exit;
  Process := CurrentProcess;
  DebugBeginMessage;
  DebugWriteTag('process');
  DebugWrite(@Process^.Name[0]);
  DebugWrite(' (');
  DebugWriteDecimal(Process^.ProcessId);
  DebugWrite('): ');
  DebugWrite(Description);
  DebugWrite(' at ');
  DebugWriteAddress(TrapFrameInstructionPointer(Frame));
  WriteModuleOfAddress(Process, TrapFrameInstructionPointer(Frame));
  if TrapFrameVector(Frame) = VectorPageFault then
  begin
    DebugWrite(' accessing ');
    DebugWriteAddress(FaultAddress);
    if LooksLikeStackOverflow(Frame, FaultAddress) then
      DebugWrite(' (stack overflow)');
  end;
  DebugWriteLine(', terminated');
  DebugEndMessage;

  { Exceptions arrive with interrupts off; ending the process may block,
    and so may the module list's lock and the back trace's file reads.
    The chain of calls (Processes.UserBackTrace), then where the modules
    were loaded, which makes the addresses meaningful
    (scripts/symbolize.py). }
  EnableInterrupts;
  WriteUserBackTrace(Process, Frame, 'process');
  WriteProcessModules(Process, 'process');
  { As a process killed by SIGSEGV, for a parent's waitpid. }
  Process^.Posix.EndSignal := SignalSegmentation;
  ExitCurrentProcess(ExitStatusException);
end;

procedure InitializeUserProcesses;
begin
  SetPageFaultResolver(@ResolvePageFault);
  InitializeOutOfMemoryPolicy;
  SetUserExceptionHandler(@HandleUserException);
end;

{ --- Starting -------------------------------------------------------- }

{ The arguments one after another, a space between each, cut short to
  fit Capacity (with its zero): what the task manager and ps show. }
procedure JoinArguments(Arguments: PPChar; Count: Integer; Destination: PChar; Capacity: QWord);
var
  Index: Integer;
  Used: QWord;
  Source: PChar;
begin
  Used := 0;
  for Index := 0 to Count - 1 do
  begin
    if (Index > 0) and (Used + 1 < Capacity) then
    begin
      Destination[Used] := ' ';
      Inc(Used);
    end;
    Source := Arguments[Index];
    while (Source <> nil) and (Source^ <> #0) and (Used + 1 < Capacity) do
    begin
      Destination[Used] := Source^;
      Inc(Used);
      Inc(Source);
    end;
  end;
  Destination[Used] := #0;
end;

function TotalStringBytes(Strings: PPChar; Count: Integer): QWord;
var
  Index: Integer;
begin
  Result := 0;
  for Index := 0 to Count - 1 do
    Result := Result + TextLength(Strings[Index]) + 1;
end;

{ Builds the initial stack below the stack top of the process's layout
  (less its random offset) and returns the stack pointer the program
  starts with (pointing at the argument count). }
function CredentialsAreSecure(const Credentials: TProcessCredentials): Boolean;
begin
  Result := (Credentials.RealUserId <> Credentials.EffectiveUserId) or
    (Credentials.RealGroupId <> Credentials.EffectiveGroupId);
end;

function BuildInitialStack(Space: PAddressSpace; const Startup: TProcessStartup;
  MainModule, Interpreter: PLoadedModule; const Lists: TInitializerLists; out StackPointer: QWord): LongInt;
var
  StringBytes: QWord;
  PointerSlots: QWord;
  StringsStart: QWord;
  ListsStart: QWord;
  ListPosition: QWord;
  Image: PByte;
  ImageSize: QWord;
  Slots: PQWord;
  SlotIndex: QWord;
  StringPosition: QWord;
  Index: Integer;
  Length: QWord;
  StackTop: QWord;
  ImageTop: QWord;
  RandomPosition: QWord;
  ProgramName: PChar;
  ProgramNamePosition: QWord;
  InterpreterBase: QWord;

  procedure PutSlot(Value: QWord);
  begin
    Slots[SlotIndex] := Value;
    Inc(SlotIndex);
  end;

  { Copies one string into the image and returns its user address. }
  function PlaceString(Text: PChar): QWord;
  begin
    Length := TextLength(Text) + 1;
    CopyMemory(Image + (StringPosition - StackPointer), Text, Length);
    Result := StringPosition;
    StringPosition := StringPosition + Length;
  end;

  { Copies an array of code addresses and returns its user address. }
  function PlaceList(Entries: PQWord; Count: QWord): QWord;
  begin
    Result := ListPosition;
    if Count = 0 then
      Exit;
    CopyMemory(Image + (ListPosition - StackPointer), Entries, Count * SizeOf(QWord));
    ListPosition := ListPosition + Count * SizeOf(QWord);
  end;

begin
  { AT_EXECFN: the name the program was started by. }
  if Startup.ArgumentCount > 0 then
    ProgramName := Startup.Arguments[0]
  else
    ProgramName := Startup.Name;
  StringBytes := TotalStringBytes(Startup.Arguments, Startup.ArgumentCount) +
    TotalStringBytes(Startup.Environment, Startup.EnvironmentCount) +
    TextLength(ProgramName) + 1 + RandomByteCount;
  PointerSlots := 1 + QWord(Startup.ArgumentCount) + 1 + QWord(Startup.EnvironmentCount) + 1 +
    2 * AuxiliaryEntryCount;

  StackTop := Space^.Layout.StackTop;
  ImageTop := StackTop - Space^.Layout.InitialStackOffset;
  StringsStart := (ImageTop - StringBytes) and not QWord(15);
  ListsStart := (StringsStart - (Lists.InitializerCount + Lists.FinalizerCount) * SizeOf(QWord)) and
    not QWord(15);
  StackPointer := (ListsStart - PointerSlots * SizeOf(QWord)) and not QWord(15);
  ImageSize := ImageTop - StackPointer;
  if StackTop - StackPointer > UserStackReserve div 2 then
    Exit(ErrorNameTooLong); { arguments and environment are too large }

  Image := PByte(AllocateZeroedKernelMemory(ImageSize));
  if Image = nil then
    Exit(ErrorOutOfMemory);

  Slots := PQWord(Image);
  SlotIndex := 0;
  StringPosition := StringsStart;
  ListPosition := ListsStart;

  PutSlot(QWord(Startup.ArgumentCount));
  for Index := 0 to Startup.ArgumentCount - 1 do
    PutSlot(PlaceString(Startup.Arguments[Index]));
  PutSlot(0);
  for Index := 0 to Startup.EnvironmentCount - 1 do
    PutSlot(PlaceString(Startup.Environment[Index]));
  PutSlot(0);
  ProgramNamePosition := PlaceString(ProgramName);
  RandomPosition := StringPosition;
  FillRandom(Image + (RandomPosition - StackPointer), RandomByteCount);
  StringPosition := StringPosition + RandomByteCount;
  InterpreterBase := 0;
  if Interpreter <> nil then
    InterpreterBase := Interpreter^.ImageStart;

  PutSlot(AuxiliaryProgramHeaders);
  PutSlot(MainModule^.ProgramHeaderAddress);
  PutSlot(AuxiliaryProgramHeaderSize);
  PutSlot(ProgramHeaderSize);
  PutSlot(AuxiliaryProgramHeaderCount);
  PutSlot(MainModule^.ProgramHeaderCount);
  PutSlot(AuxiliaryPageSize);
  PutSlot(PageSize);
  PutSlot(AuxiliaryEntryPoint);
  PutSlot(MainModule^.EntryPoint);
  PutSlot(AuxiliaryInterpreterBase);
  PutSlot(InterpreterBase);
  { The credentials the program runs with (exec changes them only after
    this): a set-user-ID program is secure, so its dynamic linker
    ignores LD_PRELOAD and LD_LIBRARY_PATH. }
  PutSlot(AuxiliaryUserId);
  PutSlot(Startup.Credentials.RealUserId);
  PutSlot(AuxiliaryEffectiveUserId);
  PutSlot(Startup.Credentials.EffectiveUserId);
  PutSlot(AuxiliaryGroupId);
  PutSlot(Startup.Credentials.RealGroupId);
  PutSlot(AuxiliaryEffectiveGroupId);
  PutSlot(Startup.Credentials.EffectiveGroupId);
  PutSlot(AuxiliarySecure);
  PutSlot(Ord(CredentialsAreSecure(Startup.Credentials)));
  PutSlot(AuxiliaryRandomBytes);
  PutSlot(RandomPosition);
  PutSlot(AuxiliaryProgramName);
  PutSlot(ProgramNamePosition);
  PutSlot(Abi.SystemCalls.AuxiliaryInitializers);
  PutSlot(PlaceList(Lists.Initializers, Lists.InitializerCount));
  PutSlot(Abi.SystemCalls.AuxiliaryInitializerCount);
  PutSlot(Lists.InitializerCount);
  PutSlot(Abi.SystemCalls.AuxiliaryFinalizers);
  PutSlot(PlaceList(Lists.Finalizers, Lists.FinalizerCount));
  PutSlot(Abi.SystemCalls.AuxiliaryFinalizerCount);
  PutSlot(Lists.FinalizerCount);
  PutSlot(AuxiliaryNull);
  PutSlot(0);

  Result := WriteIntoAddressSpace(Space, StackPointer, Image, ImageSize);
  FreeKernelMemory(Image);
end;

function ProgramStartAddress(const Target: TLoadTarget; MainModule: PLoadedModule): QWord;
var
  Interpreter: PLoadedModule;
begin
  Interpreter := InterpreterOf(Target, MainModule);
  if Interpreter <> nil then
    Result := Interpreter^.EntryPoint
  else
    Result := MainModule^.EntryPoint;
end;

function CreateUserProcess(const Startup: TProcessStartup; out Process: PProcess): LongInt;
var
  MainModule: PLoadedModule;
  StackPointer: QWord;
  StandardIndex: Integer;
  Lists: TInitializerLists;
  MainThread: PThread;
  StackStart: QWord;
  Space: PAddressSpace;
  Previous: PAddressSpace;
  Target: TLoadTarget;
  ProgramFile: POpenFile;
  OpenedHere: Boolean;
begin
  { The idle thread normally frees exited threads, but a busy system may
    not go idle for a long time; starting a process is a good moment to
    catch up, so finished processes do not pile up. }
  ReapTerminatedThreads;
  { Freed whatever step fails, so empty until collected. }
  FillMemory(@Lists, SizeOf(Lists), 0);

  Process := CreateProcessObject(Startup.Name);
  if Process = nil then
    Exit(ErrorOutOfMemory);
  Process^.ParentProcessId := Startup.ParentProcessId;
  CopyText(@Process^.CurrentDirectory[0], Startup.WorkingDirectory, ProcessPathCapacity);
  if Startup.RootDirectory <> nil then
    CopyText(@Process^.RootDirectory[0], Startup.RootDirectory, ProcessPathCapacity);
  if Startup.GroupId <> 0 then
    Process^.GroupId := Startup.GroupId
  else
    Process^.GroupId := Process^.ProcessId;
  if Startup.SessionId <> 0 then
    Process^.SessionId := Startup.SessionId
  else
    Process^.SessionId := Process^.ProcessId;
  Process^.Credentials := Startup.Credentials;
  Process^.ControllingTerminal := Startup.ControllingTerminal;
  JoinArguments(Startup.Arguments, Startup.ArgumentCount, @Process^.CommandLine[0], ProcessCommandLineCapacity);

  if Startup.HandleLimit <> 0 then
    SetHandleLimit(Process^.Handles, Startup.HandleLimit);
  Process^.ProcessCountLimit := Startup.ProcessCountLimit;
  Process^.OomScoreAdjust := Startup.OomScoreAdjust;
  Process^.Restrictions := Startup.Restrictions;
  Result := CreateAddressSpace(Space);
  if Result = ErrorNone then
  begin
    PublishAddressSpace(Process^.AddressSpace, Space, Previous);
    if Startup.RegionLimit <> 0 then
      SetRegionLimit(Space, Startup.RegionLimit);
    SetCommitLimit(Space, Startup.CommitLimitPages);
    Process^.PageTableRoot := Space^.Root;
    StackStart := Space^.Layout.StackTop - UserStackReserve;
    Result := AddRegion(Space, StackStart, UserStackReserve,
      RegionReadable or RegionWritable, RegionKindStack, True);
  end;
  Target := ProcessLoadTarget(Process);
  if Result = ErrorNone then
    Result := AddStackGuard(Space, StackStart);
  ProgramFile := Startup.ProgramFile;
  OpenedHere := False;
  if (Result = ErrorNone) and (ProgramFile = nil) then
  begin
    if OpenPath(Startup.KernelPath, ProgramFile) <> StatusSuccess then
      Result := ErrorNotFound
    else
      OpenedHere := True;
  end;
  if Result = ErrorNone then
    Result := LoadProgramImage(Target, ProgramFile, Startup.KernelPath, MainModule);
  if OpenedHere then
    CloseFile(ProgramFile);
  if Result = ErrorNone then
    Result := CollectInitializers(Target, Lists);
  if Result = ErrorNone then
    Result := BuildInitialStack(Space, Startup, MainModule, InterpreterOf(Target, MainModule), Lists,
      StackPointer);
  FreeInitializerLists(Lists);

  if Result = ErrorNone then
  begin
    for StandardIndex := 0 to 2 do
    begin
      if Startup.StandardObjects[StandardIndex] <> nil then
        SetHandle(Process^.Handles, StandardIndex, Startup.StandardKinds[StandardIndex],
          Startup.StandardObjects[StandardIndex]);
    end;
    Result := InstallPassedHandles(Process, Startup.PassedHandles);
  end;

  if Result = ErrorNone then
  begin
    { Registered before the thread starts, so it is always found while
      it runs. }
    RegisterRunningProcess(Process);
    Result := StartUserThread(Process, ProgramStartAddress(Target, MainModule), StackPointer, 0,
      StackStart, Startup.Name, False, MainThread);
    if Result <> ErrorNone then
      UnregisterRunningProcess(Process);
  end;

  if Result <> ErrorNone then
  begin
    ReleaseModules(Process);
    { The delete routine frees the address space and handles. }
    DereferenceObject(Process);
    Process := nil;
  end;
end;

{ --- Ending ---------------------------------------------------------- }

{ Run by the last thread of a process, after it has left the address
  space. }
procedure EndProcess(Process: PProcess; ExitCode: LongInt);
var
  Space: PAddressSpace;
begin
  UnregisterRunningProcess(Process);
  AcquireMutex(Process^.Lock);
  MarkProcessExited(Process, ExitCode);
  CloseAllHandles(Process^.Handles);
  ReleaseModules(Process);
  PublishAddressSpace(Process^.AddressSpace, nil, Space);
  ReleaseMutex(Process^.Lock);

  DestroyAddressSpace(Space);
  SignalEvent(Process^.ExitEvent);
  SignalEvent(Process^.StateChangedEvent);
  { POSIX: the children it never waited for are let go; its parent hears
    of its end (waitpid, SIGCHLD; Processes.ChildWaits). }
  ReleaseChildren(Process);
  NotifyParentOfChange(Process, False);
end;

procedure ExitCurrentThread(ExitCode: LongInt);
var
  Process: PProcess;
begin
  Process := CurrentProcess;
  if not Process^.IsUserProcess then
    KernelPanic('a kernel thread called ExitCurrentThread');

  if LeaveCurrentUserThread(ExitCode) then
  begin
    { A termination request decides the code even for the last thread. }
    if Process^.TerminationRequested then
      ExitCode := Process^.TerminationCode;
    EndProcess(Process, ExitCode);
  end;
  TerminateCurrentThread;
end;

procedure ExitCurrentProcess(ExitCode: LongInt);
var
  Process: PProcess;
  IsNewRequest: Boolean;
begin
  Process := CurrentProcess;
  if not Process^.IsUserProcess then
    KernelPanic('a kernel thread called ExitCurrentProcess');

  { The same request another program makes with TerminateProcessById
    (under the same lock): the other threads end at their next safe
    point. }
  LockProcessRegistry;
  IsNewRequest := not Process^.TerminationRequested;
  if IsNewRequest then
  begin
    Process^.TerminationCode := ExitCode;
    Process^.TerminationRequestedAt := UptimeMilliseconds;
    Process^.TerminationRequested := True;
  end;
  UnlockProcessRegistry;
  if IsNewRequest and (Process^.ActiveUserThreads > 1) then
    AlertProcessThreads(Process);

  ExitCurrentThread(Process^.TerminationCode);
end;

function WaitForProcessExit(Process: PProcess; TimeoutMilliseconds: QWord;
  out ExitCode: LongInt): LongInt;
begin
  ExitCode := 0;
  case WaitForEventWithOptions(Process^.ExitEvent, TimeoutMilliseconds, True) of
    WaitSignaled:
      begin
        ExitCode := ReadExitCode(Process);
        Result := ErrorNone;
      end;
    WaitTimedOut: Result := ErrorTimedOut;
  else
    Result := ErrorInterrupted;
  end;
end;

end.
