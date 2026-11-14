{
  System calls for threads and thread synchronization (40-49 in
  Abi.SystemCalls): creating, ending and waiting for threads, the thread
  pointer, and waiting on an address (the kernel half of user-mode
  locks, see Processes.AddressWait).

  A thread handle refers to a thread of the calling process; closing it
  does not affect the thread.
}
unit Processes.ThreadCalls;

{$mode objfpc}

interface

procedure InitializeThreadCalls;

function PerformCreateThread(EntryPoint, Argument, StackSize: QWord): Int64;
procedure PerformExitThread(ExitCode: QWord);
function PerformWaitForThread(Handle: Int64; Timeout: Int64; ExitCodeAddress: QWord): Int64;
function PerformSetThreadPointer(Address: QWord): Int64;
function PerformGetThreadId(Handle: Int64): Int64;
function PerformWaitOnAddress(Address: QWord; ExpectedValue: QWord; Timeout: Int64): Int64;
function PerformWakeAddress(Address: QWord; Count: QWord): Int64;

implementation

uses
  Abi.SystemCalls,
  Memory.Layout,
  Memory.Arch.PageTables,
  Kernel.Arch.Cpu,
  Kernel.Arch.ContextSwitch,
  Kernel.Mutex,
  Kernel.Scheduler,
  Objects.Manager,
  Processes.Process,
  Processes.AddressSpace,
  Processes.Handles,
  Processes.Thread,
  Processes.UserThread,
  Processes.UserProcess,
  Processes.UserAccess,
  Processes.AddressWait;

const
  { Where a new thread's stack ends: the entry point is entered as if
    called, so the stack pointer is 8 bytes off 16-byte alignment, and
    those 8 bytes hold a zero return address. }
  EntryStackOffset = 8;

function Failure(Error: LongInt): Int64;
begin
  Result := -Int64(Error);
end;

function KernelTimeoutFrom(Timeout: Int64): QWord;
begin
  if Timeout < 0 then
    Result := InfiniteTimeout
  else
    Result := QWord(Timeout);
end;

procedure InitializeThreadCalls;
begin
  InitializeAddressWaits;
end;

{ Returns a referenced thread, or nil if Handle is not a thread handle. }
function ReferenceThreadHandle(Handle: Int64): PThread;
var
  Caller: PProcess;
  Kind: THandleKind;
  ObjectBody: Pointer;
begin
  Caller := CurrentProcess;
  AcquireMutex(Caller^.Lock);
  if LookupHandle(Caller^.Handles, Handle, Kind, ObjectBody) and (Kind = HandleKindThread) then
    ReferenceObject(ObjectBody)
  else
    ObjectBody := nil;
  ReleaseMutex(Caller^.Lock);
  Result := PThread(ObjectBody);
end;

function PerformCreateThread(EntryPoint, Argument, StackSize: QWord): Int64;
var
  Process: PProcess;
  StackStart: QWord;
  Thread: PThread;
  Error: LongInt;
  Handle: Integer;
begin
  Process := CurrentProcess;
  if (EntryPoint = 0) or (EntryPoint >= UserSpaceLimit) then
    Exit(Failure(ErrorInvalidArgument));
  if StackSize = 0 then
    StackSize := DefaultThreadStackSize;
  if StackSize > MaximumThreadStackSize then
    Exit(Failure(ErrorInvalidArgument));
  StackSize := RoundUpToPage(StackSize);

  Error := AllocateGuardedUserMemory(Process^.AddressSpace, StackSize, RegionKindStack, StackStart);
  if Error <> ErrorNone then
    Exit(Failure(Error));
  Error := StartUserThread(Process, EntryPoint, StackStart + StackSize - EntryStackOffset, Argument,
    StackStart, @Process^.Name[0], True, Thread);
  if Error <> ErrorNone then
  begin
    ReleaseUserRegion(Process^.AddressSpace, StackStart);
    Exit(Failure(Error));
  end;

  AcquireMutex(Process^.Lock);
  Handle := InsertHandle(Process^.Handles, HandleKindThread, Thread, 0);
  ReleaseMutex(Process^.Lock);
  DereferenceObject(Thread);
  { The thread runs either way; without a handle nobody can wait for it. }
  if Handle < 0 then
    Exit(Failure(ErrorTooManyHandles));
  Result := Handle;
end;

procedure PerformExitThread(ExitCode: QWord);
begin
  ExitCurrentThread(LongInt(ExitCode));
end;

function PerformWaitForThread(Handle: Int64; Timeout: Int64; ExitCodeAddress: QWord): Int64;
var
  Thread: PThread;
  ExitCode: LongInt;
  Error: LongInt;
begin
  Thread := ReferenceThreadHandle(Handle);
  if Thread = nil then
    Exit(Failure(ErrorBadHandle));
  { Waiting for oneself would never end. }
  if Thread = CurrentThreadObject then
    Error := ErrorInvalidArgument
  else
    Error := WaitForThreadExit(Thread, KernelTimeoutFrom(Timeout), ExitCode);
  DereferenceObject(Thread);
  if (Error = ErrorNone) and (ExitCodeAddress <> 0) then
    Error := CopyToUser(ExitCodeAddress, @ExitCode, SizeOf(ExitCode));
  if Error <> ErrorNone then
    Exit(Failure(Error));
  Result := 0;
end;

function PerformSetThreadPointer(Address: QWord): Int64;
var
  WereEnabled: Boolean;
begin
  if Address >= UserSpaceLimit then
    Exit(Failure(ErrorInvalidArgument));
  { Together, so a switch never sees one without the other. }
  WereEnabled := SaveAndDisableInterrupts;
  CurrentThread^.UserThreadPointer := Address;
  ArchSetUserThreadPointer(Address);
  RestoreInterrupts(WereEnabled);
  Result := 0;
end;

function PerformGetThreadId(Handle: Int64): Int64;
var
  Thread: PThread;
begin
  if Handle = CurrentThreadHandle then
    Exit(Int64(CurrentThread^.ThreadId));
  Thread := ReferenceThreadHandle(Handle);
  if Thread = nil then
    Exit(Failure(ErrorBadHandle));
  Result := Int64(Thread^.ControlBlock.ThreadId);
  DereferenceObject(Thread);
end;

function PerformWaitOnAddress(Address: QWord; ExpectedValue: QWord; Timeout: Int64): Int64;
begin
  if Address >= UserSpaceLimit then
    Exit(Failure(ErrorBadAddress));
  Result := -Int64(WaitOnAddress(CurrentProcess^.AddressSpace, Address, LongWord(ExpectedValue),
    KernelTimeoutFrom(Timeout)));
end;

function PerformWakeAddress(Address: QWord; Count: QWord): Int64;
begin
  if Address >= UserSpaceLimit then
    Exit(Failure(ErrorBadAddress));
  Result := Int64(WakeAddress(CurrentProcess^.AddressSpace, Address, Count));
end;

end.
