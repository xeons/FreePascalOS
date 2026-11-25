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
  exec (CallExecuteProgram), for the C library: the calling process runs
  another program.

  The new program is loaded into a new address space while the old one
  still stands, so a program that cannot be loaded leaves the caller as
  it was (the call fails). Once it is loaded, the calling thread moves
  to the new space (a new stack, thread data and thread pointer), the
  old space and the old program's modules go, the handles listed as
  close-on-exec are closed, handled signals become default ones
  (ignored ones stay ignored, the mask stays), and the system call
  "returns" into the new program's entry point (its interpreter's, for
  a dynamically linked C program) with the new initial stack. The
  process keeps its id, parent, group, session, terminal, working
  directory and other handles; a set-user-ID program changes its
  effective user. Its other threads end first (once the program is known
  to be there), as nothing may run in the old space while the new one is
  set up.
}
unit Processes.Execution;

{$mode objfpc}

interface

uses
  Kernel.Arch.TrapFrame;

{ Returns ErrorNone with Frame leading into the new program, or an error
  with nothing changed. }
function PerformExecuteProgram(Frame: PTrapFrame; ExecutionAddress: QWord): LongInt;

implementation

uses
  Runtime.Memory,
  Runtime.Text,
  Abi.SystemCalls,
  Memory.Layout,
  Memory.KernelHeap,
  Memory.Arch.PageTables,
  Kernel.Arch.Cpu,
  Kernel.Arch.ContextSwitch,
  Kernel.Mutex,
  Kernel.Scheduler,
  Objects.Manager,
  FileSystem.Types,
  FileSystem.Files,
  Processes.Process,
  Processes.Thread,
  Processes.Handles,
  Processes.AddressSpace,
  Processes.UserRegions,
  Processes.Paths,
  Processes.ImageLoader,
  Processes.ImageInitializers,
  Processes.ThreadStorage,
  Processes.UserProcess,
  Processes.UserAccess,
  Processes.Security,
  Processes.Restrictions,
  Processes.Signals,
  Processes.ThreadControl,
  Processes.ProgramArguments,
  Processes.Arch.UserContext;

type
  { What exec takes from its caller, in kernel memory. }
  TExecRequest = record
    UserPath: array[0..ProcessPathCapacity - 1] of Char;
    KernelPath: array[0..ProcessPathCapacity - 1] of Char;
    Arguments: TStringList;
    Environment: TStringList;
    CloseOnExec: PLongInt;
    CloseOnExecCount: QWord;
    Credentials: TProcessCredentials;
  end;
  PExecRequest = ^TExecRequest;

  { The new program, loaded but not yet running. }
  TNewImage = record
    Space: PAddressSpace;
    Modules: Pointer;
    StackStart: QWord;
    StackPointer: QWord;
    StartAddress: QWord;
  end;

procedure FreeRequest(Request: PExecRequest);
begin
  FreeStringList(Request^.Arguments);
  FreeStringList(Request^.Environment);
  FreeKernelMemory(Request^.CloseOnExec);
  FreeKernelMemory(Request);
end;

function ReadRequest(Caller: PProcess; ExecutionAddress: QWord; out Request: PExecRequest): LongInt;
var
  Execution: TAbiExecution;
begin
  Request := PExecRequest(AllocateZeroedKernelMemory(SizeOf(TExecRequest)));
  if Request = nil then
    Exit(ErrorOutOfMemory);
  Result := CopyFromUser(@Execution, ExecutionAddress, SizeOf(Execution));
  if Result = ErrorNone then
    Result := CopyStringFromUser(QWord(Execution.Path), @Request^.UserPath[0], ProcessPathCapacity);
  if Result = ErrorNone then
    Result := TranslateUserPath(Caller, @Request^.UserPath[0], @Request^.KernelPath[0], ProcessPathCapacity);
  if Result = ErrorNone then
  begin
    InheritCredentials(Caller, Request^.Credentials);
    Result := CheckMayExecute(Caller, @Request^.KernelPath[0], Request^.Credentials);
  end;
  if Result = ErrorNone then
    Result := CopyStringListFromUser(QWord(Execution.Arguments), Request^.Arguments);
  if Result = ErrorNone then
    Result := CopyStringListFromUser(QWord(Execution.Environment), Request^.Environment);
  if (Result = ErrorNone) and (Execution.CloseOnExecCount > 0) then
  begin
    if Execution.CloseOnExecCount > Caller^.Handles.Limit then
      Result := ErrorInvalidArgument
    else
    begin
      Request^.CloseOnExecCount := Execution.CloseOnExecCount;
      Request^.CloseOnExec := PLongInt(AllocateKernelMemory(Execution.CloseOnExecCount * SizeOf(LongInt)));
      if Request^.CloseOnExec = nil then
        Result := ErrorOutOfMemory
      else
        Result := CopyFromUser(Request^.CloseOnExec, QWord(Execution.CloseOnExec),
          Execution.CloseOnExecCount * SizeOf(LongInt));
    end;
  end;
  if Result <> ErrorNone then
  begin
    FreeRequest(Request);
    Request := nil;
  end;
end;

{ Loads the program into a new address space, which Process holds only
  for the duration (its old space and modules are given back to it). }
function LoadNewImage(Process: PProcess; Request: PExecRequest; out Image: TNewImage): LongInt;
var
  OldSpace: PAddressSpace;
  OldModules: Pointer;
  MainModule: PLoadedModule;
  Lists: TInitializerLists;
  Startup: TProcessStartup;
begin
  FillMemory(@Image, SizeOf(Image), 0);
  FillMemory(@Lists, SizeOf(Lists), 0);
  Result := CreateAddressSpace(Image.Space);
  if Result <> ErrorNone then
    Exit;
  SetRegionLimit(Image.Space, Process^.AddressSpace^.RegionLimit);
  SetCommitLimit(Image.Space, Process^.AddressSpace^.CommitLimitPages);
  Image.StackStart := Image.Space^.Layout.StackTop - UserStackReserve;
  Result := AddRegion(Image.Space, Image.StackStart, UserStackReserve, RegionReadable or RegionWritable,
    RegionKindStack, True);
  if Result = ErrorNone then
    Result := AddStackGuard(Image.Space, Image.StackStart);

  OldSpace := Process^.AddressSpace;
  OldModules := Process^.Modules;
  Process^.AddressSpace := Image.Space;
  Process^.Modules := nil;
  if Result = ErrorNone then
    Result := LoadProgramImage(Process, @Request^.KernelPath[0], MainModule);
  if Result = ErrorNone then
    Result := CollectInitializers(Process, Lists);
  if Result = ErrorNone then
  begin
    FillMemory(@Startup, SizeOf(Startup), 0);
    Startup.KernelPath := @Request^.KernelPath[0];
    Startup.Name := FileNameOf(@Request^.UserPath[0]);
    Startup.Arguments := Request^.Arguments.Items;
    Startup.ArgumentCount := Request^.Arguments.Count;
    Startup.Environment := Request^.Environment.Items;
    Startup.EnvironmentCount := Request^.Environment.Count;
    Result := BuildInitialStack(Process, Startup, MainModule, InterpreterOf(Process, MainModule), Lists,
      Image.StackPointer);
  end;
  FreeInitializerLists(Lists);
  if Result = ErrorNone then
    Image.StartAddress := ProgramStartAddress(Process, MainModule);
  Image.Modules := Process^.Modules;
  Process^.AddressSpace := OldSpace;
  Process^.Modules := OldModules;
  if Result <> ErrorNone then
  begin
    Process^.Modules := Image.Modules;
    ReleaseModules(Process);
    Process^.Modules := OldModules;
    DestroyAddressSpace(Image.Space);
    Image.Space := nil;
  end;
end;

{ Moves the process and the calling thread into the new image; the old
  space and modules go. }
function SwitchToNewImage(Process: PProcess; Thread: PThread; const Image: TNewImage): LongInt;
var
  OldSpace: PAddressSpace;
  ThreadDataStart: QWord;
  ThreadPointer: QWord;
  WereEnabled: Boolean;
begin
  OldSpace := Process^.AddressSpace;
  ReleaseModules(Process);
  AcquireMutex(Process^.Lock);
  Process^.Modules := Image.Modules;
  Process^.AddressSpace := Image.Space;
  Process^.PageTableRoot := Image.Space^.Root;
  ReleaseMutex(Process^.Lock);

  Result := CreateThreadStorage(Process, ThreadDataStart, ThreadPointer);
  if Result = ErrorNone then
    RecordThreadId(Process, ThreadPointer, Thread^.ControlBlock.ThreadId);
  Thread^.UserStackStart := Image.StackStart;
  Thread^.ThreadDataStart := ThreadDataStart;
  Thread^.OwnedAllocationStart := 0;
  Thread^.HasSeveralOwnedAllocations := False;
  Thread^.OpenedStackReserve := 0;
  Thread^.IsDispatchingException := False;
  WereEnabled := SaveAndDisableInterrupts;
  Thread^.ControlBlock.AddressSpaceRoot := Image.Space^.Root;
  ActivateAddressSpace(Image.Space^.Root);
  Thread^.ControlBlock.UserThreadPointer := ThreadPointer;
  ArchSetUserThreadPointer(ThreadPointer);
  RestoreInterrupts(WereEnabled);
  DestroyAddressSpace(OldSpace);
end;

const
  MaximumThreadsEndedAtOnce = 256;

type
  TThreadCollection = record
    Current: PThread;
    Threads: array[0..MaximumThreadsEndedAtOnce - 1] of PThread;
    Count: Integer;
  end;
  PThreadCollection = ^TThreadCollection;

procedure CollectOtherThread(Thread: PThread; Context: Pointer);
var
  Collection: PThreadCollection;
begin
  Collection := PThreadCollection(Context);
  if (Thread = Collection^.Current) or not Thread^.IsUserThread or
     (Collection^.Count >= MaximumThreadsEndedAtOnce) then
    Exit;
  ReferenceObject(Thread);
  Collection^.Threads[Collection^.Count] := Thread;
  Inc(Collection^.Count);
end;

{ Ends every other thread of the process and waits until they are gone
  (they free their stacks in the old address space). False if the
  process is being ended meanwhile. }
function EndOtherThreads(Process: PProcess; Current: PThread): Boolean;
var
  Collection: PThreadCollection;
  Index: Integer;
begin
  while Process^.ActiveUserThreads > 1 do
  begin
    if Process^.TerminationRequested then
      Exit(False);
    Collection := PThreadCollection(AllocateZeroedKernelMemory(SizeOf(TThreadCollection)));
    if Collection = nil then
      Exit(False);
    Collection^.Current := Current;
    VisitProcessThreads(Process, @CollectOtherThread, Collection);
    for Index := 0 to Collection^.Count - 1 do
    begin
      RequestThreadExit(Collection^.Threads[Index], 0);
      DereferenceObject(Collection^.Threads[Index]);
    end;
    FreeKernelMemory(Collection);
    SleepMilliseconds(1);
  end;
  Result := True;
end;

{ The program is there: exec ends the other threads only for a program
  it can expect to start. }
function ProgramExists(Request: PExecRequest): Boolean;
var
  Information: TNodeInformation;
begin
  Result := (DescribePath(@Request^.KernelPath[0], True, Information) = StatusSuccess) and
    (Information.Kind = NodeKindFile);
end;

procedure CloseListedHandles(Process: PProcess; Request: PExecRequest);
var
  Index: QWord;
begin
  AcquireMutex(Process^.Lock);
  Index := 0;
  while Index < Request^.CloseOnExecCount do
  begin
    CloseHandle(Process^.Handles, Request^.CloseOnExec[Index]);
    Inc(Index);
  end;
  ReleaseMutex(Process^.Lock);
end;

{ The thread goes on at the new program's start: every register zero but
  the instruction and stack pointers. }
function EnterNewProgram(Frame: PTrapFrame; const Image: TNewImage): LongInt;
var
  Context: TAbiContext;
begin
  FillMemory(@Context, SizeOf(Context), 0);
{$ifdef CPUAARCH64}
  Context.Pc := Image.StartAddress;
  Context.Sp := Image.StackPointer;
{$else}
  Context.Rip := Image.StartAddress;
  Context.Rsp := Image.StackPointer;
{$endif}
  Result := RestoreUserContext(Frame, Context);
end;

function PerformExecuteProgram(Frame: PTrapFrame; ExecutionAddress: QWord): LongInt;
var
  Process: PProcess;
  Thread: PThread;
  Request: PExecRequest;
  Image: TNewImage;
begin
  Process := CurrentProcess;
  Thread := CurrentThreadObject;
  if CallerRestricted(RestrictProcessCreation) then
    Exit(ErrorAccessDenied);
  Result := ReadRequest(Process, ExecutionAddress, Request);
  if Result <> ErrorNone then
    Exit;
  { The other threads end first: nothing may run in the old space while
    the new one is set up. }
  if Process^.ActiveUserThreads > 1 then
  begin
    if not ProgramExists(Request) then
    begin
      FreeRequest(Request);
      Exit(ErrorNotFound);
    end;
    if not EndOtherThreads(Process, Thread) then
    begin
      FreeRequest(Request);
      Exit(ErrorInterrupted);
    end;
  end;
  Result := LoadNewImage(Process, Request, Image);
  if Result <> ErrorNone then
  begin
    FreeRequest(Request);
    Exit;
  end;

  { From here on the old program is gone. }
  Result := SwitchToNewImage(Process, Thread, Image);
  CloseListedHandles(Process, Request);
  Process^.ExceptionDispatcher := 0;
  ResetSignalHandlersForExec(Process);
  AcquireMutex(Process^.Lock);
  Process^.Credentials := Request^.Credentials;
  CopyText(@Process^.Name[0], FileNameOf(@Request^.UserPath[0]), ProcessNameLength);
  JoinArguments(Request^.Arguments.Items, Request^.Arguments.Count, @Process^.CommandLine[0],
    ProcessCommandLineCapacity);
  ReleaseMutex(Process^.Lock);
  FreeRequest(Request);
  if Result = ErrorNone then
    Result := EnterNewProgram(Frame, Image);
  { Too late to fail back into the old program. }
  if Result <> ErrorNone then
    ExitCurrentProcess(ExitStatusException);
end;

end.
