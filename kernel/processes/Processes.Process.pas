{
  Process objects.

  A process is a container for threads, an address space, a handle table
  and a current directory. The system process owns every kernel thread
  and has no user address space; every other process runs a user program
  (see Processes.UserProcess).

  A process object outlives the program it ran: after the program exits,
  the object keeps its exit code until the last handle to it is closed.
}
unit Processes.Process;

{$mode objfpc}

interface

uses
  Runtime.LinkedList,
  Kernel.SpinLock,
  Kernel.Mutex,
  Kernel.Events,
  Objects.Manager,
  Processes.AddressSpace,
  Processes.Handles;

const
  ProcessNameLength = 32;
  ProcessPathCapacity = 1024;

type
  PProcess = ^TProcess;
  TProcess = record
    ProcessId: QWord;
    ParentProcessId: QWord;
    Name: array[0..ProcessNameLength - 1] of Char;
    IsUserProcess: Boolean;

    PageTableRoot: QWord;
    AddressSpace: PAddressSpace;

    ThreadListLock: TSpinLock;
    Threads: TListEntry;
    ThreadCount: LongWord;

    { Protects the handle table, current directory and module list. }
    Lock: TMutex;
    Handles: THandleTable;
    { As the program sees it, for example "/home/user". }
    CurrentDirectory: array[0..ProcessPathCapacity - 1] of Char;
    { Loaded program and libraries, owned by Processes.ImageLoader. }
    Modules: Pointer;

    ExitCode: LongInt;
    HasExited: Boolean;
    ExitEvent: TEvent;
  end;

var
  ProcessObjectType: TObjectType;

procedure InitializeProcessManager;

function SystemProcess: PProcess;

function AllocateProcessOrThreadId: QWord;

{ Creates an empty user process object; the caller fills it in. }
function CreateProcessObject(Name: PChar): PProcess;

implementation

uses
  Runtime.Atomic,
  Runtime.Text,
  Memory.Arch.PageTables,
  Kernel.Panic;

var
  TheSystemProcess: PProcess;
  NextId: Int64;

procedure DeleteProcess(ObjectBody: Pointer);
var
  Process: PProcess;
begin
  Process := PProcess(ObjectBody);
  if not Process^.IsUserProcess then
    KernelPanicWithCode(PanicObjectReferenceFailure, 'the system process was deleted',
      QWord(ObjectBody), 0, 0, 0);
  { Normally released when the program exits; this covers a process that
    never started. }
  CloseAllHandles(Process^.Handles);
  DestroyAddressSpace(Process^.AddressSpace);
  Process^.AddressSpace := nil;
end;

function AllocateProcessOrThreadId: QWord;
begin
  { Process and thread ids share one counter so an id is never ambiguous. }
  Result := QWord(AtomicIncrement(NextId));
end;

procedure InitializeCommonFields(Process: PProcess; Name: PChar);
begin
  Process^.ProcessId := AllocateProcessOrThreadId;
  CopyText(@Process^.Name[0], Name, ProcessNameLength);
  InitializeSpinLock(Process^.ThreadListLock);
  InitializeListHead(Process^.Threads);
  InitializeMutex(Process^.Lock);
  InitializeHandleTable(Process^.Handles);
  InitializeEvent(Process^.ExitEvent, EventKindNotification, False);
  CopyText(@Process^.CurrentDirectory[0], '/', ProcessPathCapacity);
end;

procedure InitializeProcessManager;
begin
  NextId := 0;
  RegisterObjectType(ProcessObjectType, 'Process', SizeOf(TProcess), @DeleteProcess);

  TheSystemProcess := PProcess(CreateObject(ProcessObjectType, 'System'));
  if TheSystemProcess = nil then
    KernelPanicWithCode(PanicInitializationFailed, 'could not create the system process', 0, 0, 0, 0);
  InitializeCommonFields(TheSystemProcess, 'System');
  TheSystemProcess^.PageTableRoot := KernelPageTableRoot;
end;

function SystemProcess: PProcess;
begin
  Result := TheSystemProcess;
end;

function CreateProcessObject(Name: PChar): PProcess;
begin
  Result := PProcess(CreateObject(ProcessObjectType, nil));
  if Result = nil then
    Exit;
  InitializeCommonFields(Result, Name);
  Result^.IsUserProcess := True;
end;

end.
