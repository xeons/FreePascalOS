{
  Process objects.

  A process is a container for threads and, once user mode exists, an
  address space and a handle table. For now there is a single process,
  the system process, which owns every kernel thread.
}
unit Processes.Process;

{$mode objfpc}

interface

uses
  Runtime.LinkedList,
  Kernel.SpinLock,
  Objects.Manager;

type
  PProcess = ^TProcess;
  TProcess = record
    ProcessId: QWord;
    PageTableRoot: QWord;
    ThreadListLock: TSpinLock;
    Threads: TListEntry;
    ThreadCount: LongWord;
  end;

var
  ProcessObjectType: TObjectType;

procedure InitializeProcessManager;

function SystemProcess: PProcess;

function AllocateProcessOrThreadId: QWord;

implementation

uses
  Runtime.Atomic,
  Memory.Arch.PageTables,
  Kernel.Panic;

var
  TheSystemProcess: PProcess;
  NextId: Int64;

procedure DeleteProcess(ObjectBody: Pointer);
begin
  KernelPanicWithCode(PanicObjectReferenceFailure, 'a process object was deleted',
    QWord(ObjectBody), 0, 0, 0);
end;

function AllocateProcessOrThreadId: QWord;
begin
  { Process and thread ids share one counter so an id is never ambiguous. }
  Result := QWord(AtomicIncrement(NextId)) * 4;
end;

procedure InitializeProcessManager;
begin
  NextId := 0;
  RegisterObjectType(ProcessObjectType, 'Process', SizeOf(TProcess), @DeleteProcess);

  TheSystemProcess := PProcess(CreateObject(ProcessObjectType, 'System'));
  if TheSystemProcess = nil then
    KernelPanicWithCode(PanicInitializationFailed, 'could not create the system process', 0, 0, 0, 0);

  TheSystemProcess^.ProcessId := AllocateProcessOrThreadId;
  TheSystemProcess^.PageTableRoot := KernelPageTableRoot;
  InitializeSpinLock(TheSystemProcess^.ThreadListLock);
  InitializeListHead(TheSystemProcess^.Threads);
  TheSystemProcess^.ThreadCount := 0;
end;

function SystemProcess: PProcess;
begin
  Result := TheSystemProcess;
end;

end.
