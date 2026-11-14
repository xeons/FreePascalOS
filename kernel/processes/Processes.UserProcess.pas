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
  Processes.Process,
  Processes.Handles;

type
  TProcessStartup = record
    KernelPath: PChar;
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
    { Who the program runs as, and its nice value. }
    Credentials: TProcessCredentials;
  end;

procedure InitializeUserProcesses;

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
  Kernel.Threads,
  Kernel.Scheduler,
  Kernel.Events,
  Kernel.Mutex,
  Kernel.Panic,
  Objects.Manager,
  Processes.AddressSpace,
  Processes.ImageLoader,
  Processes.ImageInitializers,
  Processes.Thread,
  Processes.UserThread,
  Processes.UserExceptions,
  Debug.Output;

const
  AuxiliaryNull = 0;
  AuxiliaryProgramHeaders = 3;
  AuxiliaryProgramHeaderSize = 4;
  AuxiliaryProgramHeaderCount = 5;
  AuxiliaryPageSize = 6;
  AuxiliaryEntryPoint = 9;
  AuxiliaryEntryCount = 10;
  ProgramHeaderSize = 56;

{ --- Faults ---------------------------------------------------------- }

const
  PageFaultFromUserMode = 4;

function ResolvePageFault(FaultAddress: QWord; ErrorCode: QWord): Boolean;
var
  Process: PProcess;
begin
  Process := CurrentProcess;
  if (Process = nil) or not Process^.IsUserProcess then
    Exit(False);
  { The kernel copying a system call's data into the stack's reserve:
    open it, so the call can complete, and raise the overflow after. }
  if ((ErrorCode and PageFaultFromUserMode) = 0) and (FaultAddress < UserSpaceLimit) then
    NoteKernelAccessToStack(FaultAddress);
  Result := ResolveUserPageFault(Process^.AddressSpace, FaultAddress, ErrorCode);
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
  DebugWriteAddress(Frame^.Rip);
  if TrapFrameVector(Frame) = 14 then
  begin
    DebugWrite(' accessing ');
    DebugWriteAddress(FaultAddress);
    if LooksLikeStackOverflow(Frame, FaultAddress) then
      DebugWrite(' (stack overflow)');
  end;
  DebugWriteLine(', terminated');
  DebugEndMessage;

  { Exceptions arrive with interrupts off; ending the process may block. }
  EnableInterrupts;
  ExitCurrentProcess(ExitStatusException);
end;

procedure InitializeUserProcesses;
begin
  SetPageFaultResolver(@ResolvePageFault);
  SetUserExceptionHandler(@HandleUserException);
end;

{ --- Starting -------------------------------------------------------- }

function TotalStringBytes(Strings: PPChar; Count: Integer): QWord;
var
  Index: Integer;
begin
  Result := 0;
  for Index := 0 to Count - 1 do
    Result := Result + TextLength(Strings[Index]) + 1;
end;

{ Builds the initial stack below UserStackTop and returns the stack
  pointer the program starts with (pointing at the argument count). }
function BuildInitialStack(Process: PProcess; const Startup: TProcessStartup;
  MainModule: PLoadedModule; const Lists: TInitializerLists; out StackPointer: QWord): LongInt;
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
  StringBytes := TotalStringBytes(Startup.Arguments, Startup.ArgumentCount) +
    TotalStringBytes(Startup.Environment, Startup.EnvironmentCount);
  PointerSlots := 1 + QWord(Startup.ArgumentCount) + 1 + QWord(Startup.EnvironmentCount) + 1 +
    2 * AuxiliaryEntryCount;

  StringsStart := (UserStackTop - StringBytes) and not QWord(15);
  ListsStart := (StringsStart - (Lists.InitializerCount + Lists.FinalizerCount) * SizeOf(QWord)) and
    not QWord(15);
  StackPointer := (ListsStart - PointerSlots * SizeOf(QWord)) and not QWord(15);
  ImageSize := UserStackTop - StackPointer;
  if ImageSize > UserStackReserve div 2 then
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

  Result := WriteIntoAddressSpace(Process^.AddressSpace, StackPointer, Image, ImageSize);
  FreeKernelMemory(Image);
end;

function CreateUserProcess(const Startup: TProcessStartup; out Process: PProcess): LongInt;
var
  MainModule: PLoadedModule;
  StackPointer: QWord;
  StandardIndex: Integer;
  Lists: TInitializerLists;
  MainThread: PThread;
begin
  { The idle thread normally frees exited threads, but a busy system may
    not go idle for a long time; starting a process is a good moment to
    catch up, so finished processes do not pile up. }
  ReapTerminatedThreads;

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
  Process^.Credentials := Startup.Credentials;

  Result := CreateAddressSpace(Process^.AddressSpace);
  if Result = ErrorNone then
  begin
    Process^.PageTableRoot := Process^.AddressSpace^.Root;
    Result := AddRegion(Process^.AddressSpace, UserStackTop - UserStackReserve, UserStackReserve,
      RegionReadable or RegionWritable, RegionKindStack, True);
  end;
  if Result = ErrorNone then
    Result := LoadProgramImage(Process, Startup.KernelPath, MainModule);
  if Result = ErrorNone then
    Result := CollectInitializers(Process, Lists);
  if Result = ErrorNone then
    Result := BuildInitialStack(Process, Startup, MainModule, Lists, StackPointer);
  FreeInitializerLists(Lists);

  if Result = ErrorNone then
  begin
    for StandardIndex := 0 to 2 do
    begin
      if Startup.StandardObjects[StandardIndex] <> nil then
        SetHandle(Process^.Handles, StandardIndex, Startup.StandardKinds[StandardIndex],
          Startup.StandardObjects[StandardIndex]);
    end;

    { Registered before the thread starts, so it is always found while
      it runs. }
    RegisterRunningProcess(Process);
    Result := StartUserThread(Process, MainModule^.EntryPoint, StackPointer, 0,
      UserStackTop - UserStackReserve, Startup.Name, False, MainThread);
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
  Process^.ExitCode := ExitCode;
  Process^.HasExited := True;
  CloseAllHandles(Process^.Handles);
  ReleaseModules(Process);
  Space := Process^.AddressSpace;
  Process^.AddressSpace := nil;
  ReleaseMutex(Process^.Lock);

  DestroyAddressSpace(Space);
  SignalEvent(Process^.ExitEvent);
  SignalEvent(Process^.StateChangedEvent);
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
        ExitCode := Process^.ExitCode;
        Result := ErrorNone;
      end;
    WaitTimedOut: Result := ErrorTimedOut;
  else
    Result := ErrorInterrupted;
  end;
end;

end.
